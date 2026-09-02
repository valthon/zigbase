"""Artifact and live-behavior grader for the Rails full-stack migration."""

from __future__ import annotations

import copy
import json
import os
import shutil
import socket
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator

from tools.rails.fullstack import (
    FullstackError,
    _read_ndjson,
    canonical_json,
    reconcile,
)
from tools.replay import zb_replay

from ..result import EvalFailure
from . import GradeReport
from .genesis import (
    Commands,
    DoctorReport,
    GradeFailure,
    SubprocessCommands,
    _failure,
    _wait_http,
    load_public_inventory,
    parse_doctor_ndjson,
)

REPO = Path(__file__).resolve().parents[3]
PINNED_SOURCE = REPO / "evals/agents/scenarios/rails-fullstack/fixture/source"
EXPECTED_PUBLIC = frozenset({("posts", "list"), ("posts", "view"), ("users", "create")})
EXPECTED_REVIEWED_RULES = sorted(
    f"{collection}.{action}" for collection, action in EXPECTED_PUBLIC
)
EXPECTED_WARNINGS = ["posts.listRule", "posts.viewRule", "users.createRule"]
EXPECTED_UNSUPPORTED = [
    "RAILS_COMPONENT_VUE_UNSUPPORTED",
    "RAILS_HELPER_UNKNOWN",
    "RAILS_ROUTE_DYNAMIC_SEGMENT",
    "RAILS_ROUTE_HELPER_UNKNOWN",
    "RAILS_TEMPLATE_ENGINE_UNSUPPORTED",
    "RAILS_TEMPLATE_PARSE_ERROR",
]
EVAL_ENVIRONMENT = {
    "ZIGBASE_JWT_SECRET": "x" * 64,
    "ZIGBASE_SMTP_HOST": "smtp.example.invalid",
    "ZIGBASE_PUBLIC_URL": "https://eval.invalid",
}
REPORT_FIELDS = {
    "zigbaseRailsFullstackReport",
    "source",
    "manifest",
    "unresolved",
    "checks",
    "sameOrigin",
    "reviewedPublicRules",
    "doctorErrors",
    "doctorWarnings",
    "restart",
    "restore",
    "rollback",
    "cutover",
    "unsupported",
}
REQUIRED_CHECKS = {
    "contracts",
    "route-map",
    "backend-parity",
    "browser-parity",
    "authorization",
    "doctor",
    "restart",
    "restore",
    "rollback",
    "cutover",
}
REQUIRED_BROWSER_KINDS = {
    "navigate",
    "signup",
    "signin",
    "submit_allowed",
    "submit_denied",
    "validation_error",
    "asset",
}


def _json(path: Path, label: str) -> Any:
    if (
        path.is_symlink()
        or not path.is_file()
        or path.stat().st_size > 16 * 1024 * 1024
    ):
        raise GradeFailure(
            f"{label}.missing", f"{label} is missing, unsafe, or oversized"
        )
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise GradeFailure(f"{label}.invalid", f"{label} is not valid JSON") from exc


def _ndjson(path: Path, label: str) -> list[dict[str, Any]]:
    try:
        rows = _read_ndjson(path, label)
    except FullstackError as exc:
        raise GradeFailure(f"{label}.invalid", str(exc)) from exc
    seen: set[str] = set()
    parsed = []
    for line_number, row in rows:
        case_id = row.get("id")
        if not isinstance(case_id, str) or not case_id.strip():
            raise GradeFailure(
                f"{label}.invalid",
                f"{label} line {line_number} must name a non-empty case id",
            )
        if case_id in seen:
            raise GradeFailure(
                f"{label}.invalid", f"{label} has duplicate case id {case_id!r}"
            )
        seen.add(case_id)
        parsed.append(row)
    return parsed


def _ignored_cache(relative: Path) -> bool:
    return "__pycache__" in relative.parts or relative.suffix in {".pyc", ".pyo"}


def _source_files(root: Path) -> dict[Path, bytes]:
    files: dict[Path, bytes] = {}
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if _ignored_cache(relative):
            continue
        if path.is_symlink():
            raise GradeFailure(
                "source.changed", f"source contains a symlink: {relative}"
            )
        if path.is_file():
            files[relative] = path.read_bytes()
    return files


def verify_source(source: Path) -> None:
    expected = _source_files(PINNED_SOURCE)
    actual = _source_files(source)
    if set(expected) != set(actual):
        raise GradeFailure(
            "source.changed", "source artifact set differs from the pinned fixture"
        )
    for relative, content in expected.items():
        if actual[relative] != content:
            raise GradeFailure("source.changed", f"source artifact changed: {relative}")


def _expected_manifest(workspace: Path) -> dict[str, Any]:
    source = workspace / "source"
    try:
        return reconcile(
            source / "backend-routes.json",
            source / "presentation.manifest.json",
            source / "presentation.handoff.json",
            source / "zigbase.openapi.json",
            workspace / "migration/fullstack-decisions.json",
            source / "backend-replay.json",
            source / "backend-findings.ndjson",
            source / "backend-capture.ndjson",
        )
    except FullstackError as exc:
        raise GradeFailure("completion.reconcile", str(exc)) from exc


def _report(workspace: Path) -> dict[str, Any]:
    report = _json(workspace / "migration/report.json", "completion.report")
    if not isinstance(report, dict) or set(report) != REPORT_FIELDS:
        raise GradeFailure(
            "completion.report_fields", "report fields do not match the contract"
        )
    checks = report["checks"]
    evidence_fields = ("restart", "restore", "rollback", "cutover")
    claims = (
        report["zigbaseRailsFullstackReport"] == 1,
        report["source"] == "source",
        report["manifest"] == "migration/fullstack-manifest.json",
        report["unresolved"] == [],
        isinstance(checks, list)
        and all(isinstance(check, str) for check in checks)
        and REQUIRED_CHECKS.issubset(checks),
        report["sameOrigin"] is True,
        report["reviewedPublicRules"] == EXPECTED_REVIEWED_RULES,
        report["doctorErrors"] == 0,
        report["doctorWarnings"] == EXPECTED_WARNINGS,
        report["unsupported"] == EXPECTED_UNSUPPORTED,
        all(
            isinstance(report[field], str) and report[field].strip()
            for field in evidence_fields
        ),
    )
    if not all(claims):
        raise GradeFailure(
            "completion.report_claims",
            "report completion claims are incomplete or drifted",
        )
    return report


def inspect_completion(
    workspace: Path,
) -> tuple[dict[str, Any], dict[str, Any], frozenset[tuple[str, str]]]:
    verify_source(workspace / "source")
    expected = _expected_manifest(workspace)
    manifest_path = workspace / "migration/fullstack-manifest.json"
    actual = _json(manifest_path, "completion.manifest")
    canonical = canonical_json(expected)
    if actual != expected or manifest_path.read_text(encoding="utf-8") != canonical:
        raise GradeFailure(
            "completion.manifest_drift", "manifest is not canonical coordinator output"
        )
    kinds = {item["kind"] for item in actual["parity"]["browser"]}
    if missing := REQUIRED_BROWSER_KINDS - kinds:
        raise GradeFailure(
            "tests.browser", f"browser parity kinds are missing: {sorted(missing)}"
        )
    report = _report(workspace)
    reviewed = load_public_inventory(workspace / "security/public-rules.json")
    if reviewed != EXPECTED_PUBLIC:
        raise GradeFailure(
            "rules.inventory_drift",
            f"reviewed public rules are {sorted(reviewed)}, not {sorted(EXPECTED_PUBLIC)}",
        )
    return actual, report, reviewed


def _binary(binary_path: str | None) -> str:
    resolved = binary_path or os.environ.get("ZIGBASE_EVAL_BINARY")
    if not resolved or not Path(resolved).is_file():
        raise GradeFailure(
            "rehearsal.binary_missing",
            "ZIGBASE_EVAL_BINARY must name the pinned ZigBase binary",
        )
    return resolved


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _request(
    method: str, url: str, *, token: str | None = None, body: Any = None
) -> tuple[int, bytes, str]:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return (
                response.status,
                response.read(),
                response.headers.get("Content-Type", ""),
            )
    except urllib.error.HTTPError as error:
        return error.code, error.read(), error.headers.get("Content-Type", "")


def _health(url: str, timeout: float) -> Any:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read())


def _run_ok(result: Any, code: str, what: str) -> None:
    if result.returncode != 0:
        raise GradeFailure(
            code,
            f"{what} failed ({result.returncode}): {(result.stderr or result.stdout)[-400:]}",
        )


def _validate_schema_dry_run(result: Any) -> None:
    _run_ok(result, "rehearsal.schema_dry_run", "dry-running the schema")
    try:
        plan = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError) as exc:
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


def probe_parity(
    base: str,
    handoff: dict[str, Any],
    *,
    http_request: Callable[..., tuple[int, bytes, str]] = _request,
) -> tuple[str, str]:
    for row in handoff["parity"]:
        if row["kind"] not in {"navigate", "asset"}:
            continue
        status, payload, content_type = http_request("GET", base + row["url"])
        if status != row["expect"]["status"]:
            raise GradeFailure("tests.browser_http", f"{row['id']} returned {status}")
        if row["kind"] == "asset" and not content_type.startswith(
            row["expect"]["content_type"]
        ):
            raise GradeFailure(
                "tests.browser_asset", f"{row['id']} returned {content_type!r}"
            )
        if row["kind"] == "navigate":
            text = payload.decode(errors="replace")
            for tag in ("title", "h1"):
                expected = row["expect"].get(tag)
                if expected is not None and f"<{tag}>{expected}</{tag}>" not in text:
                    raise GradeFailure(
                        f"tests.browser_{tag}", f"{row['id']} {tag} drifted"
                    )
            for link in row["expect"]["links"]:
                if f'href="{link}"' not in text:
                    raise GradeFailure(
                        "tests.browser_links", f"{row['id']} links drifted"
                    )

    nonce = uuid.uuid4().hex
    email, password = f"fullstack+{nonce}@example.invalid", f"migration-{nonce}"
    typed = {
        row["kind"]: row
        for row in handoff["parity"]
        if row["kind"] not in {"navigate", "asset"}
    }
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
    token = (
        json.loads(payload).get("token")
        if status == signin["expect"]["status"]
        else None
    )
    if not token:
        raise GradeFailure("tests.signin", f"sign-in returned {status} without a token")
    denied = typed["submit_denied"]
    denied_body = {
        field["name"]: field["value"] for field in denied["expect"]["fields"]
    }
    status, _, _ = http_request(
        denied["expect"]["method"], base + denied["url"], body=denied_body
    )
    if status not in denied["expect"]["statuses"]:
        raise GradeFailure("tests.denied", f"anonymous create returned {status}")
    validation = typed["validation_error"]
    validation_body = {
        field["name"]: (
            field["invalid_value"]
            if field["name"] == validation["expect"]["field"]
            else field["value"]
        )
        for field in validation["expect"]["fields"]
    }
    status, _, _ = http_request(
        validation["expect"]["method"],
        base + validation["url"],
        token=token,
        body=validation_body,
    )
    if status != validation["expect"]["status"]:
        raise GradeFailure("tests.validation", f"invalid create returned {status}")
    allowed = typed["submit_allowed"]
    allowed_body = {
        field["name"]: field["value"] for field in allowed["expect"]["fields"]
    }
    status, _, _ = http_request(
        allowed["expect"]["method"],
        base + allowed["url"],
        token=token,
        body=allowed_body,
    )
    if status // 100 != allowed["expect"]["status_family"]:
        raise GradeFailure("tests.allowed", f"authenticated create returned {status}")
    return email, password


def probe_backend_capture(
    base: str,
    capture: list[dict[str, Any]],
    credentials: tuple[str, str],
    *,
    http_request: Callable[..., tuple[int, bytes, str]] = _request,
    send_case: Callable[..., tuple[int, Any]] = zb_replay.send,
) -> None:
    status, payload, _ = http_request(
        "POST",
        base + "/api/collections/users/auth-with-password",
        body={"identity": credentials[0], "password": credentials[1]},
    )
    token = json.loads(payload).get("token") if status == 200 else None
    if not token:
        raise GradeFailure("tests.backend_setup", "backend capture setup login failed")
    capture_email = f"capture+{uuid.uuid4().hex}@example.invalid"
    capture_password = f"capture-{uuid.uuid4().hex}"
    variables = {
        "token": token,
        "email": capture_email,
        "password": capture_password,
    }

    def semantics(case: dict[str, Any]) -> tuple[bool, bool, bool]:
        method = case.get("method")
        path = case.get("path")
        control = case.get("expect", {}).get("control")
        return (
            method == "POST"
            and path == "/api/collections/users/records"
            and control == "allowed",
            method == "POST" and path == "/api/collections/users/auth-with-password",
            method == "POST"
            and path == "/api/collections/posts/records"
            and control == "allowed",
        )

    def dependency_order(case: dict[str, Any]) -> int:
        signup, signin, creates_post = semantics(case)
        if signup or creates_post:
            return 0
        if "{{id}}" in json.dumps(case, sort_keys=True):
            return 2
        return 1 if signin else 0

    for original_case in sorted(capture, key=dependency_order):
        case = copy.deepcopy(original_case)
        body = case.get("body")
        signup, signin, creates_post = semantics(case)
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
                    "wrong-password"
                    if case.get("expect", {}).get("control") == "denied"
                    else capture_password
                ),
            }
        case["body"] = body
        resolved = zb_replay.substitute(case, variables)
        try:
            status, response = send_case(base, case, variables, 30.0)
        except zb_replay.ReplayError as exc:
            raise GradeFailure("tests.backend_capture", str(exc)) from exc
        finding = zb_replay.compare(resolved, status, response)
        if finding["result"] != "pass":
            raise GradeFailure(
                "tests.backend_capture",
                f"backend case {case['id']} returned {status}, not "
                f"{case['expect']['status']}",
            )
        if creates_post:
            record_id = response.get("id") if isinstance(response, dict) else None
            if not record_id:
                raise GradeFailure(
                    "tests.backend_capture",
                    f"backend case {case['id']} returned no record id",
                )
            variables["id"] = str(record_id)


def _python_with_playwright() -> str:
    configured = os.environ.get("PLAYWRIGHT_PYTHON")
    if configured and Path(configured).is_file():
        return configured
    executable = shutil.which("playwright")
    if executable:
        first = (
            Path(executable)
            .read_text(encoding="utf-8", errors="ignore")
            .splitlines()[0]
        )
        if first.startswith("#!") and Path(first[2:]).is_file():
            return first[2:]
    raise GradeFailure(
        "tests.playwright_missing",
        "PLAYWRIGHT_PYTHON must provide Playwright and Chrome",
    )


def _serve(
    commands: Commands, binary: str, workspace: Path, data: Path, port: int
) -> None:
    argv = [
        binary,
        "serve",
        "--background",
        "--insecure-cookies",
        "--http-port",
        str(port),
        "--data-dir",
        str(data),
        "--serve-static",
        str(workspace / "source/presentation-target/site"),
    ]
    _run_ok(
        commands.run(argv, cwd=workspace, env=dict(EVAL_ENVIRONMENT), timeout=60),
        "rehearsal.serve",
        "starting the target",
    )


def _stop(
    commands: Commands, binary: str, workspace: Path, data: Path
) -> EvalFailure | None:
    result = commands.run(
        [binary, "serve", "stop", "--data-dir", str(data)],
        cwd=workspace,
        env=dict(EVAL_ENVIRONMENT),
        timeout=30,
    )
    return (
        None
        if result.returncode == 0
        else _failure("rehearsal.teardown", "the target server did not stop")
    )


@contextmanager
def _served(
    commands: Commands,
    binary: str,
    workspace: Path,
    data: Path,
    port: int,
    health_getter: Callable[..., Any],
    failures: list[EvalFailure],
) -> Iterator[str]:
    started = False
    try:
        _serve(commands, binary, workspace, data, port)
        started = True
        base = f"http://127.0.0.1:{port}"
        _wait_http(health_getter, f"{base}/api/health")
        yield base
    finally:
        if started and (failure := _stop(commands, binary, workspace, data)):
            failures.append(failure)


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


def _probe_switched_target(base: str, credentials: dict[str, Any], phase: str) -> None:
    for path in ("/", "/api/collections/posts/records"):
        status, _, _ = _request("GET", base + path)
        if status != 200:
            raise GradeFailure(
                f"deployment.{phase}_probe", f"{phase} {path} returned {status}"
            )
    status, payload, _ = _request(
        "POST",
        base + "/api/collections/users/auth-with-password",
        body={"identity": credentials["email"], "password": credentials["password"]},
    )
    if status != 200 or not json.loads(payload).get("token"):
        raise GradeFailure(
            f"deployment.{phase}_login",
            f"{phase} synthetic credential did not log in",
        )


def run_rehearsal(
    workspace: Path,
    artifacts: Path,
    commands: Commands,
    *,
    binary_path: str | None = None,
    port_picker: Callable[[], int] = _free_port,
    health_getter: Callable[..., Any] = _health,
    parity_probe: Callable[..., None] = probe_parity,
    backend_probe: Callable[..., None] = probe_backend_capture,
    playwright_python: str | None = None,
) -> tuple[bool, DoctorReport | None, list[EvalFailure]]:
    failures: list[EvalFailure] = []
    doctor = None
    rehearsal = workspace / ".rehearsal"
    try:
        _clear_rehearsal(rehearsal)
        binary = _binary(binary_path)
        data = rehearsal / "data"
        data.mkdir(parents=True, exist_ok=True)
        for scaffold in (".home", ".tmp"):
            (workspace / scaffold).mkdir(exist_ok=True)
        schema = workspace / "source/presentation-target/backend.schema.json"
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
        if result.output_truncated:
            raise GradeFailure("rules.doctor_truncated", "doctor output was truncated")
        doctor = parse_doctor_ndjson(result.stdout)
        handoff = _json(workspace / "source/presentation.handoff.json", "tests.handoff")
        with _served(
            commands, binary, workspace, data, port_picker(), health_getter, failures
        ) as base:
            restore_credentials = parity_probe(base, handoff)
            if (
                not isinstance(restore_credentials, tuple)
                or len(restore_credentials) != 2
            ):
                raise GradeFailure(
                    "tests.credentials",
                    "live parity did not retain restore credentials",
                )
            backend_probe(
                base,
                _ndjson(
                    workspace / "source/backend-capture.ndjson", "tests.backend_capture"
                ),
                restore_credentials,
            )
            (workspace / ".rehearsal/restore-probe.json").write_text(
                json.dumps(
                    {
                        "email": restore_credentials[0],
                        "password": restore_credentials[1],
                    }
                )
            )
            python = playwright_python or _python_with_playwright()
            runner = workspace / "source/presentation-target/test/journey_playwright.py"
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
            return False, doctor, failures
        with _served(
            commands, binary, workspace, data, port_picker(), health_getter, failures
        ) as base:
            parity_probe(base, handoff)
        return not failures, doctor, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("rehearsal.error", f"{type(exc).__name__}: {exc}"))
    return False, doctor, failures


def run_restore(
    workspace: Path,
    commands: Commands,
    *,
    binary_path: str | None = None,
    port_picker: Callable[[], int] = _free_port,
    health_getter: Callable[..., Any] = _health,
) -> tuple[bool, list[EvalFailure]]:
    failures: list[EvalFailure] = []
    try:
        binary = _binary(binary_path)
        source, restored = (
            workspace / ".rehearsal/data",
            workspace / ".rehearsal/restored",
        )
        if not (source / "data.db").is_file():
            raise GradeFailure(
                "deployment.no_target", "the rehearsal produced no database"
            )
        if restored.exists():
            shutil.rmtree(restored)
        shutil.copytree(source, restored)
        credentials = _json(
            workspace / ".rehearsal/restore-probe.json", "deployment.credentials"
        )
        with _served(
            commands,
            binary,
            workspace,
            restored,
            port_picker(),
            health_getter,
            failures,
        ) as base:
            _probe_switched_target(base, credentials, "cutover")
        if failures:
            return False, failures

        with _served(
            commands,
            binary,
            workspace,
            source,
            port_picker(),
            health_getter,
            failures,
        ) as base:
            _probe_switched_target(base, credentials, "rollback")
        return not failures, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("deployment.error", f"{type(exc).__name__}: {exc}"))
    return False, failures


def grade(
    workspace: Path,
    artifacts: Path,
    *,
    commands: Commands | None = None,
    binary_path: str | None = None,
    port_picker: Callable[[], int] = _free_port,
    health_getter: Callable[..., Any] = _health,
    parity_probe: Callable[..., None] = probe_parity,
    backend_probe: Callable[..., None] = probe_backend_capture,
    playwright_python: str | None = None,
) -> GradeReport:
    artifacts.mkdir(parents=True, exist_ok=True)
    commands = commands or SubprocessCommands(artifacts)
    failures: list[EvalFailure] = []
    manifest = None
    reviewed = None
    try:
        manifest, _, reviewed = inspect_completion(workspace)
        completion = True
    except GradeFailure as exc:
        completion = False
        failures.append(_failure(exc.code, str(exc)))
    tests_green, doctor, live_failures = run_rehearsal(
        workspace,
        artifacts,
        commands,
        binary_path=binary_path,
        port_picker=port_picker,
        health_getter=health_getter,
        parity_probe=parity_probe,
        backend_probe=backend_probe,
        playwright_python=playwright_python,
    )
    failures.extend(live_failures)
    if tests_green:
        deployed, restore_failures = run_restore(
            workspace,
            commands,
            binary_path=binary_path,
            port_picker=port_picker,
            health_getter=health_getter,
        )
        failures.extend(restore_failures)
    else:
        deployed = False
    static_rules_locked = manifest is not None
    rules_locked = (
        static_rules_locked
        and doctor is not None
        and (
            doctor.public_rules == reviewed
            and doctor.errors == 0
            and doctor.skipped == 0
        )
    )
    if doctor is None and static_rules_locked:
        failures.append(
            _failure(
                "rules.doctor_skipped",
                "production doctor did not run because rehearsal stopped earlier",
            )
        )
    elif doctor is not None and doctor.skipped:
        failures.append(
            _failure(
                "rules.doctor_skipped",
                f"production doctor skipped {doctor.skipped} checks",
            )
        )
    elif doctor is not None and not rules_locked:
        failures.append(
            _failure("rules.doctor", "production doctor public rules or counts drifted")
        )
    return GradeReport(completion, rules_locked, tests_green, deployed, tuple(failures))
