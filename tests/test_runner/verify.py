#!/usr/bin/env python3
"""Check Zig 0.16.0 diagnostics and the shipped simple runner without patching Zig."""

import argparse
import os
from pathlib import Path
import resource
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default=shutil.which("zig"))
    args = parser.parse_args()
    if not args.zig:
        parser.error("put pinned Zig 0.16.0 on PATH or pass --zig")
    # Resolve before switching cwd; mise shims remain executable as provided.
    zig = str(Path(args.zig).absolute())
    env = dict(os.environ)
    for name in ("ZIG_BUILD_RUNNER", "ZIG_LIB_DIR", "ZIG_LOCAL_CACHE_DIR"):
        env.pop(name, None)
    version = subprocess.run([zig, "version"], env=env, capture_output=True, text=True, check=True, timeout=30)
    if version.stdout.strip() != "0.16.0":
        parser.error("this diagnostic regression targets exactly Zig 0.16.0")
    # The deliberate post-test signal must not create core dumps.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix="zigbase-runner-") as directory:
        scratch = Path(directory)
        fixture = scratch / "fixture"
        shutil.copytree(ROOT / "fixture", fixture)
        shutil.copyfile(REPO / "src/simple_runner.zig", fixture / "simple_runner.zig")
        env["ZIG_GLOBAL_CACHE_DIR"] = str(scratch / "global-cache")
        for variant in ("stock", "simple"):
            for case in ("newline", "meaningful", "assertion", "signal", "leak", "error_log", "skip"):
                command = [zig, "build", "test", "--summary", "all", "-j2", "-Dcpu=baseline",
                           f"-Dcase={case}", f"-Dsimple={'true' if variant == 'simple' else 'false'}"]
                result = subprocess.run(command, cwd=fixture, env=env, capture_output=True, text=True, timeout=120)
                output = result.stdout + result.stderr
                success = case in ("newline", "meaningful", "skip")
                expected_command = variant == "stock" or not success
                checks = [result.returncode == (0 if success else 1),
                          ("failed command:" in output) == expected_command]
                marker = {"meaningful": "issue261-meaningful-stderr", "assertion": "TestUnexpectedResult",
                          "leak": "leaked", "error_log": "runner-contract-error",
                          "skip": "1 skipped"}.get(case)
                if marker:
                    checks.append(marker in output)
                if case == "signal":
                    checks.append("SEGV" in output)
                if not all(checks):
                    raise RuntimeError(f"{variant}/{case}: unexpected exit {result.returncode} or diagnostic\n{output}")
                print(f"{variant}/{case}: exit {result.returncode}, failed-command={expected_command}", flush=True)


if __name__ == "__main__":
    main()
