"""Deterministic artifact and live-behavior grader for PocketBase migration."""

from __future__ import annotations

import hashlib
import json
import os
import socket
import sqlite3
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable

from tools.pocketbase import pb2zb

from ..result import EvalFailure
from . import GradeReport
from .genesis import (
    Commands,
    DoctorReport,
    GradeFailure,
    SubprocessCommands,
    _compose_file,
    _evaluation_environment,
    _wait_http,
    inspect_compose,
    load_public_inventory,
    parse_doctor_ndjson,
)


REPO = Path(__file__).resolve().parents[3]
MAX_JSON_BYTES = 4 * 1024 * 1024
EXPECTED_ROWS = {"members": 1, "posts": 2, "secrets": 1}
EXPECTED_FIXTURE_MANIFEST_SHA256 = (
    "4570a6a57dda6225f8c1027475ccb9e72ebc59bec79c3c7687d26f6118f9e37e"
)
EXPECTED_CONVERTER_SHA256 = (
    "bf2a8b9d832893b2b25a747495d3a8115e19fe6bc1127aab1b33d267175fec4e"
)
EXPECTED_PUBLIC = frozenset(
    {("members", "create"), ("posts", "list"), ("posts", "view")}
)
REPORT_FIELDS = {
    "zigbasePocketBaseMigrationReport",
    "sourceVersion",
    "bundle",
    "publicRules",
    "checks",
    "unresolved",
    "rollback",
}
REPORT_CHECKS = {
    "bundle",
    "rules",
    "auth",
    "signup",
    "authorization",
    "parity",
    "timestamps",
    "files",
    "restart",
    "rollback",
}


def _failure(code: str, message: str) -> EvalFailure:
    return EvalFailure(code, message)


def _json(path: Path, label: str) -> Any:
    if path.is_symlink() or not path.is_file():
        raise GradeFailure(f"{label}.missing", f"{label} is missing or unsafe")
    if path.stat().st_size > MAX_JSON_BYTES:
        raise GradeFailure(f"{label}.oversized", f"{label} exceeds the byte limit")
    try:
        return json.loads(path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise GradeFailure(f"{label}.invalid", f"{label} is not valid JSON") from exc


def _sha256(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise GradeFailure("artifact.unsafe", "artifact is missing or unsafe")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify_source(source: Path) -> dict[str, Any]:
    if _sha256(source / "fixture-manifest.json") != EXPECTED_FIXTURE_MANIFEST_SHA256:
        raise GradeFailure(
            "source.manifest_digest", "source manifest is not the pinned fixture"
        )
    manifest = _json(source / "fixture-manifest.json", "source.manifest")
    if (
        not isinstance(manifest, dict)
        or manifest.get("zigbasePocketBaseFixture") != 1
        or manifest.get("pocketbaseVersion") != "0.39.11"
        or manifest.get("containsSecrets") is not False
        or not isinstance(manifest.get("files"), list)
    ):
        raise GradeFailure(
            "source.manifest_invalid", "source manifest contract is invalid"
        )
    expected: dict[str, tuple[int, str]] = {}
    for entry in manifest["files"]:
        if not isinstance(entry, dict) or set(entry) != {"path", "bytes", "sha256"}:
            raise GradeFailure(
                "source.manifest_invalid", "source file entry is invalid"
            )
        relative = entry["path"]
        if (
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or "\\" in relative
            or relative in expected
        ):
            raise GradeFailure("source.manifest_invalid", "source file path is unsafe")
        expected[relative] = (entry["bytes"], entry["sha256"])
    actual = {
        path.relative_to(source).as_posix(): (path.stat().st_size, _sha256(path))
        for path in source.rglob("*")
        if path.is_file()
        and path.name != "fixture-manifest.json"
        and not path.is_symlink()
    }
    if actual != expected:
        raise GradeFailure(
            "source.digest_mismatch", "source snapshot differs from its manifest"
        )
    if any(path.is_symlink() for path in source.rglob("*")):
        raise GradeFailure("source.symlink", "source snapshot contains a symbolic link")
    return manifest


def _validate_report(workspace: Path) -> None:
    report = _json(workspace / "migration" / "report.json", "completion.report")
    if not isinstance(report, dict) or set(report) != REPORT_FIELDS:
        raise GradeFailure(
            "completion.report_invalid", "migration report fields are invalid"
        )
    if (
        report["zigbasePocketBaseMigrationReport"] != 1
        or report["sourceVersion"] != "0.39.11"
        or report["bundle"] != "migration/bundle"
        or report["unresolved"] != []
        or set(report["publicRules"]) != {f"{c}.{o}" for c, o in EXPECTED_PUBLIC}
        or set(report["checks"]) != REPORT_CHECKS
        or not isinstance(report["rollback"], str)
        or not report["rollback"].strip()
    ):
        raise GradeFailure(
            "completion.report_invalid", "migration report claims are incomplete"
        )
    serialized = json.dumps(report).lower()
    if any(
        secret in serialized
        for secret in ("migrated-secret", "$2a$", "$2b$", "$zblegacy$")
    ):
        raise GradeFailure(
            "completion.report_secret", "migration report contains credential material"
        )


def _schema_public_rules(schema: dict[str, Any]) -> frozenset[tuple[str, str]]:
    found = set()
    collections = schema.get("collections")
    if not isinstance(collections, list):
        raise GradeFailure(
            "completion.schema_invalid", "bundle schema collections are invalid"
        )
    for collection in collections:
        if not isinstance(collection, dict) or not isinstance(
            collection.get("name"), str
        ):
            raise GradeFailure(
                "completion.schema_invalid", "bundle schema collection is invalid"
            )
        for operation in ("list", "view", "create", "update", "delete"):
            if collection.get(f"{operation}Rule") == "@public":
                found.add((collection["name"], operation))
    return frozenset(found)


def load_reviewed_public_inventory(path: Path) -> frozenset[tuple[str, str]]:
    """Accept Genesis's rich inventory or the migration report's compact identities."""
    value = _json(path, "rules.inventory")
    if not isinstance(value, dict) or set(value) != {"zigbasePublicRules", "rules"}:
        raise GradeFailure(
            "rules.inventory_invalid", "public-rule inventory fields are invalid"
        )
    rules = value.get("rules")
    if value.get("zigbasePublicRules") != 1 or not isinstance(rules, list):
        raise GradeFailure(
            "rules.inventory_invalid", "public-rule inventory contract is invalid"
        )
    if not all(isinstance(rule, str) for rule in rules):
        return load_public_inventory(path)
    found = set()
    for rule in rules:
        pieces = rule.rsplit(".", 1)
        if (
            len(pieces) != 2
            or not pieces[0]
            or pieces[1]
            not in {
                "list",
                "view",
                "create",
                "update",
                "delete",
            }
        ):
            raise GradeFailure(
                "rules.inventory_invalid", "compact public-rule identity is invalid"
            )
        identity = (pieces[0], pieces[1])
        if identity in found:
            raise GradeFailure(
                "rules.inventory_invalid", "compact public-rule identity is duplicated"
            )
        found.add(identity)
    return frozenset(found)


def inspect_completion(
    workspace: Path,
) -> tuple[dict[str, Any] | None, tuple[EvalFailure, ...]]:
    failures: list[EvalFailure] = []
    bundle = workspace / "migration" / "bundle"
    manifest: dict[str, Any] | None = None
    try:
        verify_source(workspace / "source")
        if (
            _sha256(workspace / "tools" / "pocketbase" / "pb2zb.py")
            != EXPECTED_CONVERTER_SHA256
        ):
            raise GradeFailure(
                "source.converter_digest", "migration converter is not the pinned tool"
            )
        manifest = pb2zb.verify_bundle(bundle)
        if (
            manifest.get("sourceVersion") != "0.39.11"
            or manifest.get("collections") != 3
            or manifest.get("rows") != 4
            or manifest.get("rowCounts") != EXPECTED_ROWS
            or manifest.get("files") != 5
            or manifest.get("schemaSha256")
            != _sha256(workspace / "source" / "pb_schema.json")
            or manifest.get("databaseSha256")
            != _sha256(workspace / "source" / "pb_data" / "data.db")
            or manifest.get("decisionsSha256")
            != _sha256(workspace / "source" / "decisions.json")
        ):
            raise GradeFailure(
                "completion.bundle_shape", "bundle does not match the pinned source"
            )
        bundle_decisions = _json(bundle / "decisions.json", "rules.bundle_decisions")
        source_decisions = _json(
            workspace / "source" / "decisions.json", "rules.source_decisions"
        )

        def decision_contract(value: dict[str, Any]) -> tuple[Any, ...]:
            return (
                value.get("zigbasePocketBaseDecisions"),
                value.get("sourceVersion"),
                [
                    {key: item[key] for key in ("id", "choice", "rationale")}
                    for item in value.get("decisions", [])
                ],
            )

        if decision_contract(bundle_decisions) != decision_contract(source_decisions):
            raise GradeFailure(
                "rules.decisions_drift",
                "bundle decisions differ from reviewed source decisions",
            )
        schema = _json(bundle / "schema.json", "completion.schema")
        if _schema_public_rules(schema) != EXPECTED_PUBLIC:
            raise GradeFailure(
                "rules.bundle_public", "bundle public rules are not the reviewed set"
            )
        _validate_report(workspace)
        inventory = load_reviewed_public_inventory(
            workspace / "security" / "public-rules.json"
        )
        if inventory != EXPECTED_PUBLIC:
            raise GradeFailure("rules.inventory", "public-rule inventory is not exact")
        if not (workspace / "tests" / "test_migration.py").is_file():
            raise GradeFailure(
                "completion.client_test",
                "declared migration integration test is missing",
            )
        _compose_file(workspace)
    except (GradeFailure, pb2zb.PocketBaseError, OSError, KeyError, TypeError) as exc:
        code = (
            exc.code if isinstance(exc, GradeFailure) else "completion.bundle_invalid"
        )
        failures.append(
            _failure(code, "PocketBase migration artifacts are incomplete or invalid")
        )
    return manifest, tuple(failures)


def _parse_rule_lint(text: str) -> frozenset[tuple[str, str]]:
    found = set()
    summaries = []
    for line in text.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            continue
        if value.get("summary") is True:
            summaries.append(value)
        elif value.get("code") == "PublicRule":
            collection, rule = value.get("collection"), value.get("rule")
            if (
                not isinstance(collection, str)
                or not isinstance(rule, str)
                or not rule.endswith("Rule")
            ):
                raise GradeFailure(
                    "rules.lint_invalid", "rule lint public finding is malformed"
                )
            found.add((collection, rule.removesuffix("Rule")))
    if len(summaries) != 1 or summaries[0].get("errors") != 0:
        raise GradeFailure(
            "rules.lint_failed", "full-depth rule lint did not complete cleanly"
        )
    return frozenset(found)


def _binary() -> str:
    override = os.environ.get("ZIGBASE_EVAL_BINARY")
    candidate = Path(override) if override else REPO / "zig-out" / "bin" / "zigbase"
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise GradeFailure(
            "tests.binary_missing", "built ZigBase evaluation binary is missing"
        )
    return str(candidate.resolve())


def _run_ok(result: Any, code: str) -> None:
    if result.returncode != 0 or result.timed_out or result.output_truncated:
        raise GradeFailure(code, "fixed migration verification command failed")


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _request(
    method: str, url: str, body: dict[str, Any] | None = None, token: str | None = None
) -> tuple[int, bytes]:
    headers = {}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, response.read(MAX_JSON_BYTES)
    except urllib.error.HTTPError as error:
        return error.code, error.read(MAX_JSON_BYTES)


def _health_json(
    request: Callable[..., tuple[int, bytes]], url: str, _timeout: float
) -> dict[str, Any]:
    status, raw = request("GET", url)
    if status != 200:
        raise ValueError("endpoint is not ready")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("endpoint response is not an object")
    return value


def probe_behavior(base: str, parity: dict[str, Any], *, signup_email: str) -> None:
    status, raw = _request(
        "GET", f"{base}/api/collections/posts/records?sort=id&expand=owner,related"
    )
    if status != 200:
        raise GradeFailure(
            "tests.public_read", "anonymous migrated post listing failed"
        )
    posts = json.loads(raw).get("items", [])
    if [record.get("id") for record in posts] != parity["records"]["posts"] or posts[
        0
    ].get("expand", {}).get("owner") is not None:
        raise GradeFailure(
            "tests.parity", "public list or owner-redaction parity drifted"
        )
    status, _ = _request(
        "POST",
        f"{base}/api/collections/members/records",
        {
            "email": signup_email,
            "password": "evaluation-signup-secret",
            "passwordConfirm": "evaluation-signup-secret",
            "name": "Evaluation Signup",
        },
    )
    if status != 201:
        raise GradeFailure("tests.signup", "anonymous migrated auth signup failed")
    secret_id = parity["records"]["secret"]
    if _request("GET", f"{base}/api/collections/secrets/records/{secret_id}")[0] != 404:
        raise GradeFailure(
            "tests.authorization", "owner-only record was exposed anonymously"
        )
    credentials = parity["credentials"]
    login = f"{base}/api/collections/members/auth-with-password"
    if (
        _request(
            "POST", login, {"identity": credentials["email"], "password": "wrong"}
        )[0]
        != 400
    ):
        raise GradeFailure("tests.auth", "wrong legacy password did not fail")
    status, raw = _request(
        "POST",
        login,
        {"identity": credentials["email"], "password": credentials["password"]},
    )
    if status != 200:
        raise GradeFailure("tests.auth", "known migrated password did not authenticate")
    token = json.loads(raw).get("token")
    if not isinstance(token, str) or not token:
        raise GradeFailure("tests.auth", "migrated login did not return a token")
    status, raw = _request(
        "GET", f"{base}/api/collections/secrets/records/{secret_id}", token=token
    )
    if status != 200:
        raise GradeFailure(
            "tests.authorization", "owner could not read protected record"
        )
    secret = json.loads(raw)
    filename = urllib.parse.quote(secret["document"])
    status, raw = _request(
        "GET", f"{base}/api/files/secrets/{secret_id}/{filename}", token=token
    )
    if status != 200 or raw.decode() != parity["files"]["private"]:
        raise GradeFailure("tests.files", "protected migrated file parity failed")


def _inspect_database(
    data_dir: Path, parity: dict[str, Any], *, upgraded: bool
) -> None:
    connection = sqlite3.connect(f"file:{data_dir / 'data.db'}?mode=ro", uri=True)
    try:
        member = connection.execute(
            "SELECT passwordHash, created, updated FROM members WHERE id=?",
            (parity["records"]["member"],),
        ).fetchone()
        prefix = "$argon2" if upgraded else "$zblegacy$bcrypt$"
        if (
            member is None
            or not member[0].startswith(prefix)
            or list(member[1:]) != parity["timestamps"]["member"]
        ):
            raise GradeFailure(
                "tests.credentials",
                "credential transition or member timestamps are wrong",
            )
        for record_id in parity["records"]["posts"]:
            row = connection.execute(
                "SELECT created, updated FROM posts WHERE id=?", (record_id,)
            ).fetchone()
            if row is None or list(row) != parity["timestamps"][record_id]:
                raise GradeFailure(
                    "tests.timestamps", "source timestamps were not preserved"
                )
    finally:
        connection.close()


def run_rehearsal(
    workspace: Path,
    artifacts: Path,
    commands: Commands,
    port_picker: Callable[[], int] = _free_port,
    *,
    binary_path: str | None = None,
    behavior_probe: Callable[..., None] = probe_behavior,
    database_inspector: Callable[..., None] = _inspect_database,
    file_installer: Callable[[Path, Path], dict[str, int]] = pb2zb.install_files,
) -> tuple[bool, DoctorReport | None, tuple[EvalFailure, ...]]:
    failures: list[EvalFailure] = []
    doctor = None
    target = artifacts / "pocketbase-rehearsal-data"
    bundle = workspace / "migration" / "bundle"
    binary = ""
    started = False
    try:
        binary = binary_path or _binary()
        lint = commands.run(
            [binary, "schema", "check-rules", "--json", str(bundle / "schema.json")],
            cwd=workspace,
        )
        if (
            lint.returncode != 2
            or lint.timed_out
            or lint.output_truncated
            or _parse_rule_lint(lint.stdout) != EXPECTED_PUBLIC
        ):
            raise GradeFailure(
                "rules.syntax_lint", "schema rule lint did not match reviewed warnings"
            )
        _run_ok(
            commands.run(
                [
                    binary,
                    "schema",
                    "apply",
                    str(bundle / "schema.json"),
                    "--dry-run",
                    "--data-dir",
                    str(target),
                ],
                cwd=workspace,
            ),
            "tests.schema_dry_run",
        )
        _run_ok(
            commands.run(
                [
                    binary,
                    "schema",
                    "apply",
                    str(bundle / "schema.json"),
                    "--data-dir",
                    str(target),
                ],
                cwd=workspace,
            ),
            "tests.schema_apply",
        )
        full = commands.run(
            [binary, "schema", "check-rules", "--json", "--data-dir", str(target)],
            cwd=workspace,
        )
        if full.returncode != 2 or _parse_rule_lint(full.stdout) != EXPECTED_PUBLIC:
            raise GradeFailure(
                "rules.full_lint",
                "full-depth rule lint did not match reviewed warnings",
            )
        _run_ok(
            commands.run(
                [
                    binary,
                    "import",
                    "--collection",
                    "members",
                    "--legacy-hashes",
                    "bcrypt",
                    "--preserve-timestamps",
                    "--data-dir",
                    str(target),
                    str(bundle / "imports" / "auth" / "members.ndjson"),
                    "--json",
                ],
                cwd=workspace,
            ),
            "tests.auth_import",
        )
        manifest_file = bundle / "imports" / "manifest.json"
        _run_ok(
            commands.run(
                [
                    binary,
                    "import",
                    "--manifest",
                    str(manifest_file),
                    "--preserve-timestamps",
                    "--dry-run",
                    "--data-dir",
                    str(target),
                    "--json",
                ],
                cwd=workspace,
            ),
            "tests.manifest_dry_run",
        )
        _run_ok(
            commands.run(
                [
                    binary,
                    "import",
                    "--manifest",
                    str(manifest_file),
                    "--preserve-timestamps",
                    "--data-dir",
                    str(target),
                    "--json",
                ],
                cwd=workspace,
            ),
            "tests.manifest_import",
        )
        if file_installer(bundle, target) != {"files": 5, "installed": 5, "reused": 0}:
            raise GradeFailure(
                "tests.file_install", "bundle files were not installed exactly"
            )
        parity = _json(workspace / "source" / "parity.json", "tests.parity")
        database_inspector(target, parity, upgraded=False)
        test_result = commands.run(
            [
                "python3",
                "-m",
                "unittest",
                "discover",
                "-s",
                "tests",
                "-p",
                "test_migration.py",
            ],
            cwd=workspace,
            env={"ZIGBASE_BINARY": binary, "ZIGBASE_EVAL_BINARY": binary},
            timeout=300,
        )
        _run_ok(test_result, "tests.client_failed")
        port = port_picker()
        _run_ok(
            commands.run(
                [
                    binary,
                    "serve",
                    "--background",
                    "--insecure-cookies",
                    "--http-port",
                    str(port),
                    "--data-dir",
                    str(target),
                ],
                cwd=workspace,
            ),
            "tests.server_start",
        )
        started = True
        behavior_probe(
            f"http://127.0.0.1:{port}",
            parity,
            signup_email="rehearsal-signup@example.test",
        )
        database_inspector(target, parity, upgraded=True)
        doctor_result = commands.run(
            [binary, "doctor", "--production", "--json", "--data-dir", str(target)],
            cwd=workspace,
            env={
                "ZIGBASE_JWT_SECRET": "x" * 64,
                "ZIGBASE_SMTP_HOST": "smtp.example.invalid",
                "ZIGBASE_HTTP_HOST": "0.0.0.0",
                "ZIGBASE_PUBLIC_URL": "https://eval.invalid",
            },
        )
        if doctor_result.returncode not in {0, 2} or doctor_result.output_truncated:
            raise GradeFailure("rules.doctor_failed", "production doctor failed")
        doctor = parse_doctor_ndjson(doctor_result.stdout)
        if doctor.public_rules != EXPECTED_PUBLIC or doctor.errors or doctor.skipped:
            raise GradeFailure(
                "rules.doctor_mismatch",
                "production doctor did not match reviewed public rules",
            )
    except (
        GradeFailure,
        OSError,
        ValueError,
        KeyError,
        json.JSONDecodeError,
        pb2zb.PocketBaseError,
    ) as exc:
        code = exc.code if isinstance(exc, GradeFailure) else "tests.rehearsal_failed"
        failures.append(
            _failure(code, "PocketBase migration rehearsal verification failed")
        )
    finally:
        if started and binary:
            stopped = commands.run(
                [binary, "serve", "stop", "--data-dir", str(target)],
                cwd=workspace,
                timeout=30,
            )
            if stopped.returncode != 0:
                failures.append(
                    _failure("tests.teardown", "rehearsal server teardown failed")
                )
    tests_green = not any(f.code.startswith("tests.") for f in failures)
    return tests_green, doctor, tuple(failures)


def run_deployment(
    workspace: Path,
    artifacts: Path,
    commands: Commands,
    port_picker: Callable[[], int] = _free_port,
    *,
    binary_path: str | None = None,
    behavior_probe: Callable[..., None] = probe_behavior,
    http_request: Callable[..., tuple[int, bytes]] = _request,
    health_attempts: int = 30,
) -> tuple[bool, tuple[EvalFailure, ...]]:
    failures: list[EvalFailure] = []
    project = f"zigbase-pocketbase-{uuid.uuid4().hex[:12]}"
    compose = None
    cleanup = False
    environment: dict[str, str] = {}
    base = ["docker", "compose", "-p", project]
    override = artifacts / "pocketbase-compose.override.yml"
    try:
        binary = binary_path or _binary()
        compose = _compose_file(workspace)
        environment = _evaluation_environment(compose)
        config_result = commands.run(
            [*base, "-f", str(compose), "config", "--format", "json"],
            cwd=workspace,
            env=environment,
        )
        _run_ok(config_result, "deployment.compose_invalid")
        config = json.loads(config_result.stdout)
        service = inspect_compose(config)
        port = port_picker()
        override.write_text(
            "services:\n"
            f"  {service}:\n"
            "    ports: !override\n"
            f'      - "127.0.0.1:{port}:8090"\n'
            "    volumes:\n"
            "      - type: bind\n"
            f"        source: {json.dumps(binary)}\n"
            "        target: /zigbase-eval\n"
            "        read_only: true\n"
            "    environment:\n"
            '      ZIGBASE_HTTP_HOST: "0.0.0.0"\n'
            '      ZIGBASE_HTTP_PORT: "8090"\n'
            '      ZIGBASE_DATA_DIR: "/data"\n'
            '      ZIGBASE_COOKIE_SECURE: "true"\n'
            '      ZIGBASE_JWT_SECRET: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"\n'
            '      ZIGBASE_SMTP_HOST: "smtp.example.invalid"\n'
        )
        stack = [*base, "-f", str(compose), "-f", str(override)]
        cleanup = True
        _run_ok(
            commands.run(
                [*stack, "up", "-d", "--build", service],
                cwd=workspace,
                env=environment,
                timeout=600,
            ),
            "deployment.start_failed",
        )
        base_url = f"http://127.0.0.1:{port}"

        def getter(url: str, timeout: float) -> dict[str, Any]:
            return _health_json(http_request, url, timeout)

        _wait_http(getter, f"{base_url}/api/health", attempts=health_attempts)
        _wait_http(getter, f"{base_url}/api/meta", attempts=health_attempts)
        parity = _json(workspace / "source" / "parity.json", "deployment.parity")
        behavior_probe(base_url, parity, signup_email="deployment-signup@example.test")
        doctor_result = commands.run(
            [
                *stack,
                "exec",
                "-T",
                service,
                "/zigbase-eval",
                "doctor",
                "--production",
                "--json",
                "--data-dir",
                "/data",
            ],
            cwd=workspace,
            env=environment,
        )
        if doctor_result.returncode not in {0, 2}:
            raise GradeFailure("deployment.doctor_failed", "deployed doctor failed")
        deployed_doctor = parse_doctor_ndjson(doctor_result.stdout)
        if (
            deployed_doctor.public_rules != EXPECTED_PUBLIC
            or deployed_doctor.errors
            or deployed_doctor.skipped
        ):
            raise GradeFailure(
                "deployment.doctor_mismatch",
                "deployed doctor did not match reviewed public rules",
            )
        _run_ok(
            commands.run(
                [*stack, "restart", service],
                cwd=workspace,
                env=environment,
                timeout=120,
            ),
            "deployment.restart_failed",
        )
        _wait_http(getter, f"{base_url}/api/health", attempts=health_attempts)
        _wait_http(getter, f"{base_url}/api/meta", attempts=health_attempts)
        behavior_probe(
            base_url,
            parity,
            signup_email="deployment-restart-signup@example.test",
        )
    except (GradeFailure, OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        code = exc.code if isinstance(exc, GradeFailure) else "deployment.error"
        failures.append(
            _failure(code, "PocketBase migration deployment verification failed")
        )
    finally:
        if compose is not None and cleanup:
            stack = [*base, "-f", str(compose), "-f", str(override)]
            down = commands.run(
                [*stack, "down", "-v", "--remove-orphans"],
                cwd=workspace,
                env=environment,
                timeout=120,
            )
            ps = commands.run(
                [*stack, "ps", "-q"], cwd=workspace, env=environment, timeout=30
            )
            if down.returncode != 0 or ps.returncode != 0 or ps.stdout.strip():
                failures.append(
                    _failure("deployment.teardown", "Compose teardown was incomplete")
                )
    return not failures, tuple(failures)


def grade(
    workspace: Path,
    artifacts: Path,
    *,
    commands: Commands | None = None,
    port_picker: Callable[[], int] = _free_port,
    binary_path: str | None = None,
    behavior_probe: Callable[..., None] = probe_behavior,
    database_inspector: Callable[..., None] = _inspect_database,
    file_installer: Callable[[Path, Path], dict[str, int]] = pb2zb.install_files,
    http_request: Callable[..., tuple[int, bytes]] = _request,
    health_attempts: int = 30,
) -> GradeReport:
    artifacts.mkdir(parents=True, exist_ok=True)
    commands = commands or SubprocessCommands(artifacts)
    manifest, completion_failures = inspect_completion(workspace)
    failures = list(completion_failures)
    tests_green, doctor, rehearsal_failures = run_rehearsal(
        workspace,
        artifacts,
        commands,
        port_picker=port_picker,
        binary_path=binary_path,
        behavior_probe=behavior_probe,
        database_inspector=database_inspector,
        file_installer=file_installer,
    )
    failures.extend(rehearsal_failures)
    deployed, deployment_failures = run_deployment(
        workspace,
        artifacts,
        commands,
        port_picker=port_picker,
        binary_path=binary_path,
        behavior_probe=behavior_probe,
        http_request=http_request,
        health_attempts=health_attempts,
    )
    failures.extend(deployment_failures)
    rules_locked = (
        doctor is not None
        and doctor.public_rules == EXPECTED_PUBLIC
        and doctor.errors == 0
        and doctor.skipped == 0
        and not any(f.code.startswith("rules.") for f in failures)
    )
    completion = manifest is not None and not any(
        failure.code.startswith(("completion.", "source."))
        for failure in completion_failures
    )
    return GradeReport(completion, rules_locked, tests_green, deployed, tuple(failures))
