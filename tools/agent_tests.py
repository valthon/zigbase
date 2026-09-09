#!/usr/bin/env python3
"""Bounded, allowlisted pytest selection for a trusted ZigBase checkout.

Inventory uses syntax trees, never pytest collection/import. Execution is not a
sandbox: repository tests, conftest, the pinned toolchain and dependencies run
with the caller's authority. No execution API is added to an embedded binary.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
MODULES = (
    "tests/tools/test_bin_resolver.py",
    "tests/admin/test_agent_diagnostics.py",
    "tests/admin/test_capabilities.py",
    "tests/admin/test_routes_cli.py",
    "tests/admin/test_tuning.py",
    "tests/admin/test_schema.py",
    "tests/admin/test_files.py",
    "tests/admin/test_realtime.py",
)
DEFAULT_TIMEOUT = 120
MAX_TIMEOUT = 900
DEFAULT_OUTPUT_BYTES = 65536
MAX_OUTPUT_BYTES = 1048576
MAX_SOURCE_BYTES = 1048576
MAX_ITEMS = 2048
PREFIX = (
    "mise",
    "exec",
    "python@3.13",
    "--",
    "python",
    "-m",
    "pytest",
    "-q",
    "-o",
    "addopts=",
)
BROWSER_MODULES = {
    "tests/admin/test_schema.py",
    "tests/admin/test_files.py",
    "tests/admin/test_realtime.py",
}
RUN_PREFIX = (
    "mise",
    "exec",
    "python@3.13",
    "--",
    "python",
    "tools/agent_tests.py",
    "run",
)


class ContractError(Exception):
    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ContractError("invalid_arguments", message)


def command(selector: str) -> list[str]:
    """Called only after exact inventory membership validation by run()."""
    return [*PREFIX, "--", selector]


def inventory() -> dict:
    items = []
    for module in MODULES:
        path = ROOT / module
        if not path.resolve().is_relative_to(ROOT):
            raise ContractError(
                "invalid_inventory", "An allowlisted source escapes the checkout."
            )
        try:
            with path.open("rb") as source:
                raw = source.read(MAX_SOURCE_BYTES + 1)
            if len(raw) > MAX_SOURCE_BYTES:
                raise ContractError(
                    "invalid_inventory",
                    "An allowlisted source exceeds the inventory size limit.",
                )
            tree = ast.parse(raw, filename=module)
        except (OSError, SyntaxError, ValueError) as error:
            raise ContractError(
                "invalid_inventory",
                f"Cannot inventory {module}: {type(error).__name__}.",
            ) from error
        entries = [(module, "module")]
        entries.extend(
            (f"{module}::{node.name}", "function")
            for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name.startswith("test_")
        )
        for identifier, kind in entries:
            items.append(
                {
                    "id": identifier,
                    "kind": kind,
                    "module": module,
                    "argv": [*RUN_PREFIX, "--selector", identifier],
                    "effect": "may_write_and_access_network",
                    "requirements": {
                        "tools": {
                            "python": "3.13",
                            "zig": "0.16.0" if "/admin/" in module else None,
                        },
                        "python_packages": ["pytest", "playwright"]
                        if "/admin/" in module
                        else ["pytest"],
                        "browser": "chromium" if module in BROWSER_MODULES else None,
                        "binary": {
                            "build_if_missing": "/admin/" in module,
                            "prebuilt_override": "ZIGBASE_TEST_BINARY"
                            if "/admin/" in module
                            else None,
                        },
                        "notes": "Module-level conservative prerequisites, not dependency introspection; runtime fixtures may build additional binaries.",
                    },
                }
            )
        if len(items) > MAX_ITEMS:
            raise ContractError(
                "invalid_inventory", "The inventory exceeds its item limit."
            )
    if len({item["id"] for item in items}) != len(items):
        raise ContractError(
            "invalid_inventory", "Duplicate test identifiers in an allowlisted source."
        )
    return {
        "items": items,
        "coverage": "Allowlisted pytest modules and directly declared top-level test functions; not collected test cases. Function selectors include all parametrizations. Class methods, dynamic cases, Zig and SDK suites are not individually inventoried.",
        "execution": {
            "argv_prefix": list(RUN_PREFIX),
            "selector_flag": "--selector",
            "cwd": "repository_root",
            "shell": False,
            "timeout_seconds": {
                "default": DEFAULT_TIMEOUT,
                "minimum": 1,
                "maximum": MAX_TIMEOUT,
            },
            "output_limit_bytes": {
                "default": DEFAULT_OUTPUT_BYTES,
                "minimum": 1,
                "maximum": MAX_OUTPUT_BYTES,
            },
        },
        "notes": "Static source inspection does not import tests or prove collectability. Run executes trusted repository code, including conftest and dependencies. Limits cover time and captured stdout/stderr, not memory, disk, network or escaped descendants.",
    }


def child_environment() -> dict[str, str]:
    # Keep the caller's PATH/toolchain and explicit binary overrides, but prevent
    # accidental pytest argument/plugin injection from changing the selection.
    env = dict(os.environ)
    env.pop("PYTEST_ADDOPTS", None)
    env.pop("PYTEST_PLUGINS", None)
    env["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    env["MISE_AUTO_INSTALL"] = "false"
    env["ZIGBASE_SERVE_BACKGROUND"] = "0"
    return env


def execute(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: float,
    output_limit: int,
) -> dict:
    """Run a resolved argv; retain at most output_limit raw bytes in total.

    start_new_session gives normal children one process group to terminate on
    timeout/output overflow and clean up on completion. This cannot contain
    untrusted code that escapes its group. A killed child gets 2s to be reaped.
    """
    started = time.monotonic()
    captured = {"stdout": bytearray(), "stderr": bytearray()}
    total = 0
    outcome = "completed"
    returncode = None
    proc = None
    cleanup_error = False
    failure = None
    with selectors.DefaultSelector() as ready:
        try:
            proc = subprocess.Popen(
                argv,
                cwd=cwd,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
                shell=False,
            )
            for name in captured:
                pipe = getattr(proc, name)
                os.set_blocking(pipe.fileno(), False)
                ready.register(pipe, selectors.EVENT_READ, name)
            deadline = started + timeout
            while ready.get_map() or proc.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    outcome = "timed_out"
                    break
                for event, _ in ready.select(min(remaining, 0.1)):
                    chunk = os.read(event.fileobj.fileno(), 8192)
                    if not chunk:
                        ready.unregister(event.fileobj)
                        continue
                    kept = chunk[: max(0, output_limit - total)]
                    captured[event.data].extend(kept)
                    total += len(kept)
                    if len(kept) != len(chunk):
                        outcome = "output_limit"
                        break
                if outcome != "completed":
                    break
            returncode = proc.poll()
        except OSError as error:
            outcome = "execution_error"
            failure = {
                "code": "spawn_failed" if proc is None else "capture_failed",
                "errno": error.errno,
            }
        finally:
            if proc is not None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except OSError:
                    cleanup_error = True
                try:
                    returncode = proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    cleanup_error = True
                for name in captured:
                    getattr(proc, name).close()
    truncated = outcome == "output_limit"
    if outcome == "completed":
        outcome = "passed" if returncode == 0 else "failed"
    if cleanup_error and outcome == "passed":
        outcome = "cleanup_error"
    return {
        "outcome": outcome,
        "child_exit_code": returncode,
        "duration_ms": round((time.monotonic() - started) * 1000),
        "stdout": captured["stdout"].decode("utf-8", errors="replace"),
        "stderr": captured["stderr"].decode("utf-8", errors="replace"),
        "captured_bytes": total,
        "output_truncated": truncated,
        "cleanup_failed": cleanup_error,
        "failure": failure,
        "test_counts": None,
        "notes": "Outcome reflects process exit, not per-test results: passed can include skips. Output is untrusted test/toolchain text and may contain deployment information.",
    }


def run(selector: str, timeout: int, output_limit: int) -> dict:
    if os.name != "posix":
        raise ContractError(
            "unsupported_platform",
            "Execution requires POSIX process groups (Linux/macOS).",
        )
    if not 1 <= timeout <= MAX_TIMEOUT or not 1 <= output_limit <= MAX_OUTPUT_BYTES:
        raise ContractError(
            "invalid_arguments", "Time/output limits are outside the advertised bounds."
        )
    catalog = inventory()
    if selector not in {item["id"] for item in catalog["items"]}:
        raise ContractError(
            "invalid_selector",
            "Selector must exactly match an inventory id; arbitrary paths, expressions and arguments are not accepted.",
        )
    argv = command(selector)
    result = execute(
        argv,
        cwd=ROOT,
        env=child_environment(),
        timeout=timeout,
        output_limit=output_limit,
    )
    return {
        "selector": selector,
        "argv": argv,
        "limits": {"timeout_seconds": timeout, "output_limit_bytes": output_limit},
        **result,
    }


def main(argv: list[str] | None = None) -> int:
    envelope = {"protocol_version": 1, "scope": "repository-focused-tests"}
    try:
        parser = Parser(description=__doc__, allow_abbrev=False)
        sub = parser.add_subparsers(dest="action", required=True, parser_class=Parser)
        sub.add_parser("inventory", allow_abbrev=False)
        runner = sub.add_parser("run", allow_abbrev=False)
        runner.add_argument("--selector", required=True)
        runner.add_argument("--timeout-seconds", type=int, default=DEFAULT_TIMEOUT)
        runner.add_argument(
            "--output-limit-bytes", type=int, default=DEFAULT_OUTPUT_BYTES
        )
        args = parser.parse_args(argv)
        if args.action == "inventory":
            envelope.update(status="complete", **inventory())
            code = 0
        else:
            result = run(args.selector, args.timeout_seconds, args.output_limit_bytes)
            envelope.update(status="complete", **result)
            code = 0 if result["outcome"] == "passed" else 1
    except ContractError as error:
        envelope.update(
            status="error", failure={"code": error.code, "message": str(error)}
        )
        code = 2
    envelope["exit_code"] = code
    print(json.dumps(envelope, ensure_ascii=True, separators=(",", ":")))
    return code


if __name__ == "__main__":
    sys.exit(main())
