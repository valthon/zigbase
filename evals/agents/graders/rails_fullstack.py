"""Artifact and live-behavior grader for the Rails full-stack migration."""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from tools.rails.fullstack import FullstackError, canonical_json, reconcile
from tools.replay import zb_replay

from ..result import EvalFailure
from . import GradeReport
from ._harness import (
    EVAL_ENVIRONMENT,
    canonical_executable,
    free_port,
    health_json,
    json_http_request,
    read_bounded_regular,
    read_regular_first_line,
    regular_file_inventory,
    require_command_success,
    served_target,
    strict_json_loads,
    strict_utf8,
)
from .genesis import (
    Commands,
    DoctorReport,
    GradeFailure,
    SubprocessCommands,
    _failure,
    _wait_http,
    load_public_inventory,
    parse_doctor_ndjson,
    prepare_grader_scratch,
)

REPO = Path(__file__).resolve().parents[3]
PINNED_SOURCE = REPO / "evals/agents/scenarios/rails-fullstack/fixture/source"
EXPECTED_PUBLIC = frozenset({("posts", "list"), ("posts", "view"), ("users", "create")})
REQUIRED_BROWSER_KINDS = {
    "navigate",
    "signup",
    "signin",
    "submit_allowed",
    "submit_denied",
    "validation_error",
    "asset",
}
MAX_JSON_ARTIFACT_BYTES = 16 * 1024 * 1024
MAX_SOURCE_FILE_BYTES = 16 * 1024 * 1024
MAX_SOURCE_TOTAL_BYTES = 64 * 1024 * 1024


def _json_bytes(path: Path, label: str) -> tuple[Any, bytes]:
    try:
        raw = read_bounded_regular(path, MAX_JSON_ARTIFACT_BYTES)
    except PermissionError as exc:
        raise GradeFailure(f"{label}.invalid", f"cannot read {label}: {exc}") from exc
    except (OSError, ValueError) as exc:
        raise GradeFailure(
            f"{label}.missing", f"{label} is missing, unsafe, or oversized: {exc}"
        ) from exc
    try:
        return strict_json_loads(strict_utf8(raw, str(path))), raw
    except (UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(f"{label}.invalid", f"{label} is not valid JSON") from exc


def _json(path: Path, label: str) -> Any:
    return _json_bytes(path, label)[0]


def _capture(path: Path, label: str) -> list[dict[str, Any]]:
    try:
        return zb_replay.load_capture(path)
    except zb_replay.ReplayError as exc:
        raise GradeFailure(f"{label}.invalid", str(exc)) from exc


def _ignored_cache(relative: Path) -> bool:
    return "__pycache__" in relative.parts or relative.suffix in {".pyc", ".pyo"}


def _source_inventory(root: Path) -> dict[Path, tuple[Path, int]]:
    try:
        return regular_file_inventory(
            root,
            ignored=_ignored_cache,
            maximum_file=MAX_SOURCE_FILE_BYTES,
            maximum_total=MAX_SOURCE_TOTAL_BYTES,
        )
    except ValueError as exc:
        raise GradeFailure("source.changed", f"source snapshot changed: {exc}") from exc
    except OSError as exc:
        raise GradeFailure(
            "source.unreadable", f"cannot inspect source snapshot: {exc}"
        ) from exc


def verify_source(source: Path) -> None:
    expected = _source_inventory(PINNED_SOURCE)
    actual = _source_inventory(source)
    if set(expected) != set(actual):
        raise GradeFailure(
            "source.changed", "source artifact set differs from the pinned fixture"
        )
    for relative, (_, expected_size) in expected.items():
        if actual[relative][1] != expected_size:
            raise GradeFailure("source.changed", f"source artifact changed: {relative}")

    try:
        for relative, (expected_path, _) in expected.items():
            content = read_bounded_regular(expected_path, MAX_SOURCE_FILE_BYTES)
            actual_content = read_bounded_regular(
                actual[relative][0], MAX_SOURCE_FILE_BYTES
            )
            if actual_content != content:
                raise GradeFailure(
                    "source.changed", f"source artifact changed: {relative}"
                )
    except GradeFailure:
        raise
    except (OSError, ValueError) as exc:
        raise GradeFailure(
            "source.unreadable", f"cannot read source snapshot: {exc}"
        ) from exc


def _expected_manifest(workspace: Path, source: Path | None = None) -> dict[str, Any]:
    source = source or workspace / "source"
    try:
        return reconcile(
            source / "backend-routes.json",
            source / "presentation.manifest.json",
            source / "presentation.handoff.json",
            source / "zigbase.openapi.json",
            workspace / "migration/fullstack-decisions.json",
            source / "backend-findings.ndjson",
            source / "backend-capture.ndjson",
        )
    except FullstackError as exc:
        raise GradeFailure("completion.reconcile", str(exc)) from exc


def inspect_completion(
    workspace: Path,
    *,
    source_verified: bool = False,
    source: Path | None = None,
) -> tuple[dict[str, Any], frozenset[tuple[str, str]]]:
    source = source or workspace / "source"
    if not source_verified:
        verify_source(source)
    expected = _expected_manifest(workspace, source)
    manifest_path = workspace / "migration/fullstack-manifest.json"
    actual, manifest_bytes = _json_bytes(manifest_path, "completion.manifest")
    canonical = canonical_json(expected)
    if manifest_bytes != canonical.encode("utf-8"):
        raise GradeFailure(
            "completion.manifest_drift", "manifest is not canonical coordinator output"
        )
    kinds = {item["kind"] for item in actual["parity"]["browser"]}
    if missing := REQUIRED_BROWSER_KINDS - kinds:
        raise GradeFailure(
            "tests.browser", f"browser parity kinds are missing: {sorted(missing)}"
        )
    reviewed = load_public_inventory(workspace / "security/public-rules.json")
    if reviewed != EXPECTED_PUBLIC:
        raise GradeFailure(
            "rules.inventory_drift",
            f"reviewed public rules are {sorted(reviewed)}, not {sorted(EXPECTED_PUBLIC)}",
        )
    return actual, reviewed


def _binary(binary_path: str | None) -> str:
    resolved = canonical_executable(
        binary_path or os.environ.get("ZIGBASE_EVAL_BINARY")
    )
    if resolved is None:
        raise GradeFailure(
            "rehearsal.binary_missing",
            "ZIGBASE_EVAL_BINARY must name a regular executable pinned ZigBase binary",
        )
    return str(resolved)


def _request(
    method: str, url: str, *, token: str | None = None, body: Any = None
) -> tuple[int, bytes, str]:
    status, payload, headers = json_http_request(method, url, token=token, body=body)
    return status, payload, headers.get("Content-Type", "")


@dataclass(frozen=True)
class PersistedState:
    email: str
    password: str
    post_id: str
    post_title: str


def _run_ok(result: Any, code: str, what: str) -> None:
    require_command_success(result, code, what, GradeFailure)


def _validate_schema_dry_run(result: Any) -> None:
    _run_ok(result, "rehearsal.schema_dry_run", "dry-running the schema")
    try:
        plan = strict_json_loads(result.stdout)
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            "rehearsal.schema_dry_run_plan",
            "schema dry-run did not return its JSON plan",
        ) from exc
    apply_order = plan.get("apply_order") if isinstance(plan, dict) else None
    if (
        not isinstance(plan, dict)
        or plan.get("zigbase_schema_apply") != 1
        or plan.get("dry_run") is not True
        or plan.get("destructive") is not False
        or plan.get("applied") != []
        or not isinstance(apply_order, list)
        or not all(isinstance(name, str) for name in apply_order)
        or sorted(apply_order) != ["posts", "users"]
    ):
        raise GradeFailure(
            "rehearsal.schema_dry_run_plan",
            "schema dry-run plan does not create the expected posts and users collections",
        )


def _collection_state(
    base: str,
    collection: str,
    token: str,
    *,
    http_request: Callable[..., tuple[int, bytes, str]],
    failure_code: str,
    context: str,
) -> str:
    status, payload, _ = http_request(
        "GET", f"{base}/api/collections/{collection}/records", token=token
    )
    try:
        response = strict_json_loads(strict_utf8(payload, "mutation state response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            failure_code,
            f"cannot inspect collection state around {context}",
        ) from exc
    items = response.get("items") if isinstance(response, dict) else None
    if status != 200 or not isinstance(items, list):
        raise GradeFailure(
            failure_code,
            f"cannot inspect collection state around {context}",
        )
    if not all(
        isinstance(item, dict) and isinstance(item.get("id"), str) for item in items
    ):
        raise GradeFailure(
            failure_code,
            "collection listing contains records without identities",
        )
    return json.dumps(response, sort_keys=True, separators=(",", ":"), allow_nan=False)


def probe_parity(
    base: str,
    handoff: dict[str, Any],
    *,
    http_request: Callable[..., tuple[int, bytes, str]] = _request,
) -> PersistedState:
    for row in handoff["parity"]:
        if row["kind"] not in {"navigate", "asset"}:
            continue
        status, _, content_type = http_request("GET", base + row["url"])
        if status != row["expect"]["status"]:
            raise GradeFailure("tests.browser_http", f"{row['id']} returned {status}")
        if row["kind"] == "asset" and (
            content_type.partition(";")[0].strip().lower()
            != row["expect"]["content_type"].strip().lower()
        ):
            raise GradeFailure(
                "tests.browser_asset", f"{row['id']} returned {content_type!r}"
            )
        if row["kind"] == "navigate":
            if content_type.partition(";")[0].strip().lower() != "text/html":
                raise GradeFailure(
                    "tests.browser_html",
                    f"{row['id']} returned {content_type!r}, not text/html",
                )

    nonce = uuid.uuid4().hex
    email, password = f"fullstack+{nonce}@example.invalid", f"migration-{nonce}"
    typed = {}
    for kind in (
        "signup",
        "signin",
        "submit_allowed",
        "submit_denied",
        "validation_error",
    ):
        matches = [row for row in handoff["parity"] if row["kind"] == kind]
        if len(matches) != 1:
            raise GradeFailure(
                "tests.browser",
                f"browser parity must contain exactly one {kind} check",
            )
        typed[kind] = matches[0]
    signup = typed["signup"]
    status, _, _ = http_request(
        "POST",
        base + signup["url"],
        body={"email": email, "password": password, "passwordConfirm": password},
    )
    if status != signup["expect"]["status"]:
        raise GradeFailure("tests.signup", f"signup returned {status}")
    signin = typed["signin"]
    status, payload, _ = http_request(
        "POST", base + signin["url"], body={"identity": email, "password": password}
    )
    try:
        signin_response = strict_json_loads(strict_utf8(payload, "signin response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure("tests.signin", "signin did not return strict JSON") from exc
    token = (
        signin_response.get("token")
        if status == signin["expect"]["status"] and isinstance(signin_response, dict)
        else None
    )
    if not token:
        raise GradeFailure("tests.signin", f"sign-in returned {status} without a token")
    denied = typed["submit_denied"]
    denied_body = {
        field["name"]: field["value"] for field in denied["expect"]["fields"]
    }
    denied_collection = denied["expect"]["collection"]
    before_denied = _collection_state(
        base,
        denied_collection,
        token,
        http_request=http_request,
        failure_code="tests.denied_state",
        context="denied mutation",
    )
    status, _, _ = http_request(
        denied["expect"]["method"], base + denied["url"], body=denied_body
    )
    if status not in denied["expect"]["statuses"]:
        raise GradeFailure("tests.denied", f"anonymous create returned {status}")
    after_denied = _collection_state(
        base,
        denied_collection,
        token,
        http_request=http_request,
        failure_code="tests.denied_state",
        context="denied mutation",
    )
    if after_denied != before_denied:
        raise GradeFailure(
            "tests.denied_state", "anonymous denied create changed collection state"
        )
    validation = typed["validation_error"]
    validation_body = {
        field["name"]: (
            field["invalid_value"]
            if field["name"] == validation["expect"]["field"]
            else field["value"]
        )
        for field in validation["expect"]["fields"]
    }
    validation_collection = validation["expect"]["collection"]
    before_validation = _collection_state(
        base,
        validation_collection,
        token,
        http_request=http_request,
        failure_code="tests.validation_state",
        context="validation failure",
    )
    status, _, _ = http_request(
        validation["expect"]["method"],
        base + validation["url"],
        token=token,
        body=validation_body,
    )
    if status != validation["expect"]["status"]:
        raise GradeFailure("tests.validation", f"invalid create returned {status}")
    after_validation = _collection_state(
        base,
        validation_collection,
        token,
        http_request=http_request,
        failure_code="tests.validation_state",
        context="validation failure",
    )
    if after_validation != before_validation:
        raise GradeFailure(
            "tests.validation_state", "invalid create changed collection state"
        )
    allowed = typed["submit_allowed"]
    allowed_body = {
        field["name"]: field["value"] for field in allowed["expect"]["fields"]
    }
    status, payload, _ = http_request(
        allowed["expect"]["method"],
        base + allowed["url"],
        token=token,
        body=allowed_body,
    )
    if status // 100 != allowed["expect"]["status_family"]:
        raise GradeFailure("tests.allowed", f"authenticated create returned {status}")
    try:
        created = strict_json_loads(strict_utf8(payload, "created post response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            "tests.allowed", "create did not return strict JSON"
        ) from exc
    post_id = created.get("id") if isinstance(created, dict) else None
    post_title = allowed_body.get("title")
    if not isinstance(post_id, str) or not post_id or not isinstance(post_title, str):
        raise GradeFailure("tests.allowed", "create returned no durable post identity")
    return PersistedState(email, password, post_id, post_title)


def probe_backend_capture(
    base: str,
    capture: list[dict[str, Any]],
    credentials: tuple[str, str],
    *,
    http_request: Callable[..., tuple[int, bytes, str]] = _request,
    send_case: Callable[..., tuple[int, Any]] = zb_replay.send_resolved,
) -> None:
    status, payload, _ = http_request(
        "POST",
        base + "/api/collections/users/auth-with-password",
        body={"identity": credentials[0], "password": credentials[1]},
    )
    try:
        response = strict_json_loads(strict_utf8(payload, "restore signin response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            "restore.signin", "signin did not return strict JSON"
        ) from exc
    token = (
        response.get("token") if status == 200 and isinstance(response, dict) else None
    )
    if not token:
        raise GradeFailure("tests.backend_setup", "backend capture setup login failed")
    capture_email = f"capture+{uuid.uuid4().hex}@example.invalid"
    capture_password = f"capture-{uuid.uuid4().hex}"
    variables = {
        "token": token,
        "email": capture_email,
        "password": capture_password,
    }

    phases: tuple[list[tuple[dict[str, Any], bool]], ...] = ([], [], [])
    for original_case in capture:
        path = original_case.get("path")
        control = (original_case.get("expect") or {}).get("control")
        signup = (
            original_case.get("method") == "POST"
            and path == "/api/collections/users/records"
            and control == "allowed"
        )
        signin = (
            original_case.get("method") == "POST"
            and path == "/api/collections/users/auth-with-password"
        )
        creates_post = (
            original_case.get("method") == "POST"
            and path == "/api/collections/posts/records"
            and control == "allowed"
        )
        body = original_case.get("body")
        if signup:
            body = {
                "email": capture_email,
                "password": capture_password,
                "passwordConfirm": capture_password,
            }
        elif signin:
            body = {
                "identity": capture_email,
                "password": (
                    "wrong-password" if control == "denied" else capture_password
                ),
            }
        case = {**original_case, "body": body}
        phase = 2 if "{{id}}" in path else 1 if signin else 0
        phases[phase].append((case, creates_post))

    for phase in phases:
        for case, creates_post in phase:
            try:
                resolved = zb_replay.substitute(case, variables)
                status, response = send_case(base, resolved, 30.0)
                finding = zb_replay.compare(resolved, status, response)
            except zb_replay.ReplayError as exc:
                raise GradeFailure(
                    "tests.backend_capture",
                    f"backend case {case['id']} could not be replayed: {exc}",
                ) from exc
            if finding["result"] != "pass":
                raise GradeFailure(
                    "tests.backend_capture",
                    f"backend case {case['id']} failed parity: "
                    f"{json.dumps(finding, sort_keys=True)}",
                )
            if creates_post:
                record_id = response.get("id") if isinstance(response, dict) else None
                if not record_id:
                    raise GradeFailure(
                        "tests.backend_capture",
                        f"backend case {case['id']} returned no record id",
                    )
                variables["id"] = str(record_id)


def _shebang_interpreter(executable: str) -> str | None:
    try:
        first = read_regular_first_line(Path(executable), 4096).decode(
            "utf-8", errors="ignore"
        )
        tokens = shlex.split(first[2:]) if first.startswith("#!") else []
    except (OSError, ValueError, IndexError):
        return None
    if not tokens:
        return None
    if Path(tokens[0]).name == "env":
        tokens = tokens[1:]
        if tokens[:1] == ["-S"]:
            tokens = tokens[1:]
        while tokens and "=" in tokens[0] and not tokens[0].startswith("-"):
            tokens = tokens[1:]
    if not tokens:
        return None
    resolved = tokens[0] if Path(tokens[0]).is_absolute() else shutil.which(tokens[0])
    if (
        resolved is None
        or re.fullmatch(
            r"(?:python|pypy)(?:\d+(?:\.\d+)*)?(?:\.exe)?",
            Path(resolved).name.lower(),
        )
        is None
    ):
        return None
    return resolved


def _python_with_playwright(
    commands: Commands,
    workspace: Path,
    configured: str | None = None,
) -> str:
    candidates = [configured or os.environ.get("PLAYWRIGHT_PYTHON"), sys.executable]
    launcher = shutil.which("playwright")
    if launcher:
        candidates.append(_shebang_interpreter(launcher))
    seen = set()
    sentinel = "zigbase-playwright-import-ok"
    for candidate in candidates:
        path = canonical_executable(candidate)
        if path is None:
            continue
        canonical = str(path)
        if canonical in seen:
            continue
        seen.add(canonical)
        try:
            result = commands.run(
                [
                    canonical,
                    "-c",
                    f"import playwright; print({sentinel!r})",
                ],
                cwd=workspace,
                env=dict(EVAL_ENVIRONMENT),
                timeout=30,
            )
        except OSError:
            continue
        if (
            result.returncode == 0
            and not result.timed_out
            and not result.output_truncated
            and sentinel in result.stdout.splitlines()
        ):
            return canonical
    raise GradeFailure(
        "environment.playwright_missing",
        "no validated Python interpreter can import Playwright",
    )


def _check_server_start(result: Any) -> None:
    _run_ok(result, "rehearsal.serve", "starting the target")


def _server_teardown_failure(result: Any) -> EvalFailure | None:
    if isinstance(result, Exception):
        return _failure(
            "rehearsal.teardown",
            f"the target server stop command failed: {type(result).__name__}: {result}",
        )
    return (
        None
        if result.returncode == 0
        else _failure("rehearsal.teardown", "the target server did not stop")
    )


def _deployment_teardown_failure(result: Any) -> EvalFailure | None:
    if isinstance(result, Exception):
        return _failure(
            "deployment.teardown",
            f"the restored server stop command failed: {type(result).__name__}: {result}",
        )
    return (
        None
        if result.returncode == 0
        else _failure("deployment.teardown", "the restored server did not stop")
    )


def _clear_rehearsal(rehearsal: Path) -> None:
    try:
        if rehearsal.is_symlink() or rehearsal.is_file():
            rehearsal.unlink()
        elif rehearsal.exists():
            shutil.rmtree(rehearsal)
    except OSError as exc:
        raise GradeFailure(
            "rehearsal.cleanup",
            f"cannot clear stale rehearsal state at {rehearsal}: {exc}",
        ) from exc


def _probe_switched_target(base: str, state: PersistedState, phase: str) -> None:
    status, payload, _ = _request(
        "GET", base + f"/api/collections/posts/records/{state.post_id}"
    )
    try:
        record = strict_json_loads(strict_utf8(payload, f"{phase} post response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            f"deployment.{phase}_post", f"{phase} post was not strict JSON"
        ) from exc
    if (
        status != 200
        or not isinstance(record, dict)
        or record.get("id") != state.post_id
        or record.get("title") != state.post_title
    ):
        raise GradeFailure(
            f"deployment.{phase}_post",
            f"{phase} did not preserve post {state.post_id}",
        )
    status, payload, _ = _request("GET", base + "/api/collections/posts/records")
    try:
        listing = strict_json_loads(strict_utf8(payload, f"{phase} post list response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            f"deployment.{phase}_list", f"{phase} post list was not strict JSON"
        ) from exc
    items = listing.get("items") if isinstance(listing, dict) else None
    if (
        status != 200
        or not isinstance(items, list)
        or not any(
            isinstance(item, dict)
            and item.get("id") == state.post_id
            and item.get("title") == state.post_title
            for item in items
        )
    ):
        raise GradeFailure(
            f"deployment.{phase}_list",
            f"{phase} post list does not contain {state.post_id}",
        )
    status, payload, _ = _request(
        "POST",
        base + "/api/collections/users/auth-with-password",
        body={"identity": state.email, "password": state.password},
    )
    try:
        response = strict_json_loads(strict_utf8(payload, f"{phase} signin response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            f"deployment.{phase}_signin", "signin did not return strict JSON"
        ) from exc
    if status != 200 or not isinstance(response, dict) or not response.get("token"):
        raise GradeFailure(
            f"deployment.{phase}_login",
            f"{phase} synthetic credential did not log in",
        )


def run_rehearsal(
    workspace: Path,
    commands: Commands,
    *,
    source: Path | None = None,
    binary_path: str | None = None,
    port_picker: Callable[[], int] = free_port,
    health_getter: Callable[..., Any] = health_json,
    parity_probe: Callable[..., PersistedState] = probe_parity,
    backend_probe: Callable[..., None] = probe_backend_capture,
    persistence_probe: Callable[..., None] = _probe_switched_target,
    playwright_python: str | None = None,
) -> tuple[
    bool,
    DoctorReport | None,
    PersistedState | None,
    list[EvalFailure],
]:
    failures: list[EvalFailure] = []
    doctor = None
    source = source or workspace / "source"
    rehearsal = workspace / ".rehearsal"
    try:
        _clear_rehearsal(rehearsal)
        binary = _binary(binary_path)
        data = rehearsal / "data"
        data.mkdir(parents=True, exist_ok=True)
        prepare_grader_scratch(workspace)
        schema = source / "presentation-target/backend.schema.json"
        schema_argv = [
            binary,
            "schema",
            "apply",
            "--data-dir",
            str(data),
        ]
        _validate_schema_dry_run(
            commands.run(
                [*schema_argv, "--dry-run", str(schema)],
                cwd=workspace,
                env=dict(EVAL_ENVIRONMENT),
            )
        )
        _run_ok(
            commands.run(
                [*schema_argv, str(schema)],
                cwd=workspace,
                env=dict(EVAL_ENVIRONMENT),
            ),
            "rehearsal.schema_apply",
            "applying the schema",
        )
        result = commands.run(
            [binary, "doctor", "--data-dir", str(data), "--production", "--json"],
            cwd=workspace,
            env=dict(EVAL_ENVIRONMENT),
        )
        _run_ok(result, "rules.doctor_failed", "running the production doctor")
        doctor = parse_doctor_ndjson(result.stdout)
        python = _python_with_playwright(commands, workspace, playwright_python)
        handoff = _json(source / "presentation.handoff.json", "tests.handoff")
        with served_target(
            commands,
            binary,
            workspace,
            data,
            port_picker(),
            health_getter,
            _wait_http,
            failures,
            _check_server_start,
            _server_teardown_failure,
            serve_static=source / "presentation-target/site",
        ) as base:
            restore_state = parity_probe(base, handoff)
            if not isinstance(restore_state, PersistedState):
                raise GradeFailure(
                    "tests.persistence",
                    "live parity did not retain the state needed for restart and restore",
                )
            backend_probe(
                base,
                _capture(source / "backend-capture.ndjson", "tests.backend_capture"),
                (restore_state.email, restore_state.password),
            )
            runner = source / "presentation-target/test/journey_playwright.py"
            _run_ok(
                commands.run(
                    [python, str(runner)],
                    cwd=workspace,
                    env={**EVAL_ENVIRONMENT, "ZIGAPAGOS_ORIGIN": base},
                    timeout=180,
                ),
                "tests.playwright",
                "the generated browser journey",
            )
        if failures:
            return False, doctor, None, failures
        with served_target(
            commands,
            binary,
            workspace,
            data,
            port_picker(),
            health_getter,
            _wait_http,
            failures,
            _check_server_start,
            _server_teardown_failure,
            serve_static=source / "presentation-target/site",
        ) as base:
            persistence_probe(base, restore_state, "restart")
        return not failures, doctor, restore_state, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except Exception as exc:
        failures.append(_failure("rehearsal.error", f"{type(exc).__name__}: {exc}"))
    return False, doctor, None, failures


def run_restore(
    workspace: Path,
    commands: Commands,
    state: PersistedState,
    *,
    source: Path | None = None,
    binary_path: str | None = None,
    port_picker: Callable[[], int] = free_port,
    health_getter: Callable[..., Any] = health_json,
) -> tuple[bool, list[EvalFailure]]:
    failures: list[EvalFailure] = []
    source = source or workspace / "source"
    try:
        binary = _binary(binary_path)
        rehearsal_data, restored = (
            workspace / ".rehearsal/data",
            workspace / ".rehearsal/restored",
        )
        if not (rehearsal_data / "data.db").is_file():
            raise GradeFailure(
                "deployment.no_target", "the rehearsal produced no database"
            )
        if restored.exists():
            shutil.rmtree(restored)
        shutil.copytree(rehearsal_data, restored)
        with served_target(
            commands,
            binary,
            workspace,
            restored,
            port_picker(),
            health_getter,
            _wait_http,
            failures,
            _check_server_start,
            _deployment_teardown_failure,
            serve_static=source / "presentation-target/site",
        ) as base:
            _probe_switched_target(base, state, "cutover")
        if failures:
            return False, failures

        with served_target(
            commands,
            binary,
            workspace,
            rehearsal_data,
            port_picker(),
            health_getter,
            _wait_http,
            failures,
            _check_server_start,
            _deployment_teardown_failure,
            serve_static=source / "presentation-target/site",
        ) as base:
            _probe_switched_target(base, state, "rollback")
        return not failures, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except Exception as exc:
        failures.append(_failure("deployment.error", f"{type(exc).__name__}: {exc}"))
    return False, failures


def grade(
    workspace: Path,
    artifacts: Path,
    *,
    commands: Commands | None = None,
    binary_path: str | None = None,
    port_picker: Callable[[], int] = free_port,
    health_getter: Callable[..., Any] = health_json,
    parity_probe: Callable[..., PersistedState] = probe_parity,
    backend_probe: Callable[..., None] = probe_backend_capture,
    persistence_probe: Callable[..., None] = _probe_switched_target,
    playwright_python: str | None = None,
) -> GradeReport:
    artifacts.mkdir(parents=True, exist_ok=True)
    artifacts.chmod(0o700)
    commands = commands or SubprocessCommands(artifacts)
    failures: list[EvalFailure] = []
    manifest = None
    reviewed = None
    source_verified = False
    source = workspace / "source"
    try:
        verify_source(source)
        source_verified = True
        manifest, reviewed = inspect_completion(
            workspace, source_verified=True, source=source
        )
        completion = True
    except GradeFailure as exc:
        completion = False
        failures.append(_failure(exc.code, str(exc)))
    except Exception as exc:
        completion = False
        failures.append(_failure("completion.error", f"{type(exc).__name__}: {exc}"))
    doctor = None
    restore_state = None
    tests_green = False
    deployed = False
    if source_verified:
        tests_green, doctor, restore_state, live_failures = run_rehearsal(
            workspace,
            commands,
            source=source,
            binary_path=binary_path,
            port_picker=port_picker,
            health_getter=health_getter,
            parity_probe=parity_probe,
            backend_probe=backend_probe,
            persistence_probe=persistence_probe,
            playwright_python=playwright_python,
        )
        failures.extend(live_failures)
    if tests_green and restore_state is not None:
        deployed, restore_failures = run_restore(
            workspace,
            commands,
            restore_state,
            source=source,
            binary_path=binary_path,
            port_picker=port_picker,
            health_getter=health_getter,
        )
        failures.extend(restore_failures)
    static_completion = manifest is not None
    doctor_clean = doctor is not None and (
        doctor.public_rules == reviewed and doctor.errors == 0 and doctor.skipped == 0
    )
    rules_locked = static_completion and doctor_clean
    if doctor is None and static_completion:
        failures.append(
            _failure(
                "rules.doctor_skipped",
                "production doctor did not run because rehearsal stopped earlier",
            )
        )
    elif static_completion and doctor is not None and doctor.skipped:
        failures.append(
            _failure(
                "rules.doctor_skipped",
                f"production doctor skipped {doctor.skipped} checks",
            )
        )
    elif static_completion and doctor is not None and not doctor_clean:
        failures.append(
            _failure("rules.doctor", "production doctor public rules or counts drifted")
        )
    return GradeReport(completion, rules_locked, tests_green, deployed, tuple(failures))
