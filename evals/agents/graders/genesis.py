"""Deterministic artifact and live-behavior grader for the Genesis scenario."""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Protocol

from ..process import run_process
from ..result import EvalFailure
from . import GradeReport


MAX_SOURCE_BYTES = 4 * 1024 * 1024
MAX_COMMAND_OUTPUT_BYTES = 1024 * 1024
RULE_OPERATIONS = {"list", "view", "create", "update", "delete"}
COMPOSE_VARIABLE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}")


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""
    timed_out: bool = False
    output_truncated: bool = False


class Commands(Protocol):
    def run(
        self,
        argv: list[str],
        *,
        cwd: Path,
        env: dict[str, str] | None = None,
        timeout: int = 300,
    ) -> CommandResult: ...


def _resolve_mise_executable(spec: str, relative: str) -> str:
    """Resolve a pinned mise tool before commands enter the isolated HOME."""
    mise = shutil.which("mise")
    if mise is None:
        conventional = Path.home() / ".local" / "bin" / "mise"
        if conventional.is_file() and os.access(conventional, os.X_OK):
            mise = str(conventional)
    if mise is None:
        raise OSError("mise is required to resolve the Genesis grader toolchain")

    completed = subprocess.run(
        [mise, "where", spec],
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0 or not completed.stdout.strip():
        detail = completed.stderr.strip() or "tool is not installed"
        raise OSError(f"cannot resolve {spec} with mise: {detail}")
    executable = Path(completed.stdout.strip()) / relative
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise OSError(f"mise resolved {spec}, but {relative} is not executable")
    return str(executable)


class SubprocessCommands:
    def __init__(
        self,
        artifacts: Path,
        tool_resolver: Callable[[str, str], str] = _resolve_mise_executable,
    ) -> None:
        self.artifacts = artifacts
        self.index = 0
        self.tool_resolver = tool_resolver
        self.tools: dict[str, str] = {}

    def _resolve_command(self, argv: list[str]) -> list[str]:
        pins = {
            "zig": ("zig@0.16.0", "zig"),
            "npm": ("node@24", "bin/npm"),
        }
        if argv[0] not in pins:
            return argv
        if argv[0] not in self.tools:
            self.tools[argv[0]] = self.tool_resolver(*pins[argv[0]])
        return [self.tools[argv[0]], *argv[1:]]

    def run(
        self,
        argv: list[str],
        *,
        cwd: Path,
        env: dict[str, str] | None = None,
        timeout: int = 300,
    ) -> CommandResult:
        argv = self._resolve_command(argv)
        self.index += 1
        stem = f"grader-{self.index:02d}-{re.sub(r'[^a-z0-9]+', '-', Path(argv[0]).name.lower())}"
        stdout_path = self.artifacts / f"{stem}.stdout.log"
        stderr_path = self.artifacts / f"{stem}.stderr.log"
        child_env = _grader_environment(cwd)
        if env:
            child_env.update(env)
        if Path(argv[0]).is_absolute():
            child_env["PATH"] = os.pathsep.join(
                (str(Path(argv[0]).parent), child_env.get("PATH", ""))
            )
        result = run_process(
            argv,
            cwd=cwd,
            env=child_env,
            stdin=None,
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            timeout_seconds=timeout,
            term_grace_seconds=5,
            max_output_bytes=MAX_COMMAND_OUTPUT_BYTES,
        )
        return CommandResult(
            returncode=result.exit_code,
            stdout=stdout_path.read_text(errors="replace"),
            stderr=stderr_path.read_text(errors="replace"),
            timed_out=result.timed_out,
            output_truncated=result.output_truncated,
        )


@dataclass(frozen=True)
class DoctorReport:
    public_rules: frozenset[tuple[str, str]]
    errors: int
    warnings: int
    skipped: int


class GradeFailure(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _failure(code: str, message: str) -> EvalFailure:
    return EvalFailure(code, message)


def _grader_environment(workspace: Path) -> dict[str, str]:
    allowed = (
        "PATH",
        "LANG",
        "LC_ALL",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "NODE_EXTRA_CA_CERTS",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "NO_PROXY",
        "https_proxy",
        "http_proxy",
        "no_proxy",
        "DOCKER_HOST",
        "DOCKER_CONTEXT",
    )
    env = {name: os.environ[name] for name in allowed if name in os.environ}
    env.update({"HOME": str(workspace / ".home"), "TMPDIR": str(workspace / ".tmp")})
    return env


def load_public_inventory(path: Path) -> frozenset[tuple[str, str]]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            "rules.inventory_invalid", f"cannot read public-rule inventory: {exc}"
        ) from exc
    if not isinstance(value, dict) or set(value) != {"zigbasePublicRules", "rules"}:
        raise GradeFailure(
            "rules.inventory_invalid",
            "inventory must contain zigbasePublicRules and rules",
        )
    if (
        isinstance(value["zigbasePublicRules"], bool)
        or value["zigbasePublicRules"] != 1
        or not isinstance(value["rules"], list)
    ):
        raise GradeFailure(
            "rules.inventory_invalid",
            "unsupported inventory version or rules is not an array",
        )

    found: set[tuple[str, str]] = set()
    for entry in value["rules"]:
        if not isinstance(entry, dict) or set(entry) != {
            "collection",
            "operation",
            "rule",
            "rationale",
        }:
            raise GradeFailure(
                "rules.inventory_invalid",
                "every inventory entry must use the four frozen fields",
            )
        collection = entry["collection"]
        operation = entry["operation"]
        if not isinstance(collection, str) or not collection:
            raise GradeFailure(
                "rules.inventory_invalid", "inventory collection must be non-empty"
            )
        if (
            not isinstance(operation, str)
            or operation not in RULE_OPERATIONS
            or entry["rule"] != "@public"
        ):
            raise GradeFailure(
                "rules.inventory_invalid", "inventory operation or rule is invalid"
            )
        if not isinstance(entry["rationale"], str) or not entry["rationale"].strip():
            raise GradeFailure(
                "rules.inventory_invalid", "every public rule needs a rationale"
            )
        identity = (collection, operation)
        if identity in found:
            raise GradeFailure(
                "rules.inventory_duplicate",
                f"duplicate inventory identity: {collection}.{operation}",
            )
        found.add(identity)
    return frozenset(found)


def parse_doctor_ndjson(text: str) -> DoctorReport:
    summaries: list[dict[str, Any]] = []
    public_rules: set[tuple[str, str]] = set()
    for line in text.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            continue
        if value.get("summary") is True:
            summaries.append(value)
            continue
        if value.get("check") != "public-rules-enumerated":
            continue
        subject = value.get("subject")
        severity = value.get("severity")
        if subject is None and severity == "ok":
            continue
        if not isinstance(subject, str) or severity not in {"warn", "error"}:
            raise GradeFailure(
                "rules.doctor_invalid", "public-rule finding is skipped or malformed"
            )
        match = re.fullmatch(r"(.+)\.(list|view|create|update|delete)Rule", subject)
        if match is None:
            raise GradeFailure(
                "rules.doctor_invalid", f"unknown public-rule subject: {subject}"
            )
        identity = (match.group(1), match.group(2))
        if identity in public_rules:
            raise GradeFailure(
                "rules.doctor_duplicate", f"duplicate doctor identity: {subject}"
            )
        public_rules.add(identity)

    if len(summaries) != 1:
        raise GradeFailure(
            "rules.doctor_summary", "doctor output must contain exactly one summary"
        )
    summary = summaries[0]
    expected = {"summary", "production", "checks", "errors", "warnings", "skipped"}
    if set(summary) != expected or summary["production"] is not True:
        raise GradeFailure(
            "rules.doctor_summary",
            "doctor summary fields or production mode are invalid",
        )
    counts = [summary[name] for name in ("checks", "errors", "warnings", "skipped")]
    if not all(
        isinstance(value, int) and not isinstance(value, bool) and value >= 0
        for value in counts
    ):
        raise GradeFailure(
            "rules.doctor_summary",
            "doctor summary counts must be non-negative integers",
        )
    return DoctorReport(frozenset(public_rules), *counts[1:])


def compare_public_rules(
    inventory: frozenset[tuple[str, str]], doctor: DoctorReport
) -> None:
    missing = doctor.public_rules - inventory
    stale = inventory - doctor.public_rules
    if missing:
        raise GradeFailure(
            "rules.inventory_missing",
            f"doctor rules missing from inventory: {sorted(missing)}",
        )
    if stale:
        raise GradeFailure(
            "rules.inventory_stale",
            f"inventory rules absent from doctor: {sorted(stale)}",
        )
    if doctor.errors:
        raise GradeFailure(
            "rules.doctor_errors", f"production doctor reported {doctor.errors} errors"
        )
    if doctor.skipped:
        raise GradeFailure(
            "rules.doctor_skipped", f"production doctor skipped {doctor.skipped} checks"
        )


def _source_text(workspace: Path) -> str:
    pieces = []
    total = 0
    ignored = {
        ".agents",
        ".git",
        ".zig-cache",
        "zig-pkg",
        "zig-out",
        "node_modules",
        "zb_data",
        ".home",
        ".tmp",
    }
    suffixes = {".zig", ".ts", ".tsx", ".js", ".jsx", ".json", ".md"}
    for path in workspace.rglob("*"):
        if (
            path.is_symlink()
            or any(part in ignored for part in path.parts)
            or not path.is_file()
        ):
            continue
        if path.suffix not in suffixes:
            continue
        size = path.stat().st_size
        total += size
        if total > MAX_SOURCE_BYTES:
            raise GradeFailure(
                "completion.source_limit",
                "project source exceeds the grading byte limit",
            )
        pieces.append(path.read_text(errors="replace"))
    return "\n".join(pieces).lower()


def inspect_completion(workspace: Path) -> tuple[EvalFailure, ...]:
    failures = []
    required = [
        (
            workspace / "build.zig",
            "completion.framework_missing",
            "framework build.zig is missing",
        ),
        (
            workspace / "src" / "main.zig",
            "completion.app_missing",
            "src/main.zig is missing",
        ),
        (
            workspace / "security" / "public-rules.json",
            "completion.inventory_missing",
            "public-rule inventory is missing",
        ),
        (
            workspace / "package.json",
            "completion.client_missing",
            "client test package.json is missing",
        ),
    ]
    for path, code, message in required:
        if not path.is_file():
            failures.append(_failure(code, message))
    try:
        _compose_file(workspace)
    except GradeFailure as exc:
        failures.append(_failure("completion.compose_missing", str(exc)))
    try:
        text = _source_text(workspace)
    except GradeFailure as exc:
        return tuple([*failures, _failure(exc.code, str(exc))])
    checks = [
        (
            ("equipment" in text or "listing" in text or "gear" in text),
            "completion.equipment_missing",
            "equipment/listing model is missing",
        ),
        (
            "request" in text,
            "completion.requests_missing",
            "request workflow is missing",
        ),
        (
            ("member" in text or "user" in text),
            "completion.members_missing",
            "member auth model is missing",
        ),
        (
            (".relation" in text or '"type": "relation"' in text),
            "completion.relation_missing",
            "no relation model was found",
        ),
        (
            ("beforecreate" in text or "beforeupdate" in text or ".routes" in text),
            "completion.server_logic_missing",
            "no trusted hook or route was found",
        ),
        (
            "cursor" in text,
            "completion.cursor_missing",
            "cursor pagination is not exercised",
        ),
        (
            "expand" in text,
            "completion.expand_missing",
            "relation expansion is not exercised",
        ),
    ]
    failures.extend(
        _failure(code, message) for passed, code, message in checks if not passed
    )
    return tuple(failures)


def _package_test_script(workspace: Path) -> str:
    try:
        package = json.loads((workspace / "package.json").read_text())
        scripts = package["scripts"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        raise GradeFailure(
            "tests.package_invalid", f"cannot read package test scripts: {exc}"
        ) from exc
    for name in ("test:e2e", "test:browser", "test:integration", "test:client"):
        if (
            isinstance(scripts, dict)
            and isinstance(scripts.get(name), str)
            and scripts[name].strip()
        ):
            return name
    raise GradeFailure(
        "tests.client_missing",
        "package.json must declare a client, browser, integration, or e2e test",
    )


def run_build_and_tests(
    workspace: Path, commands: Commands
) -> tuple[bool, bool, tuple[EvalFailure, ...]]:
    failures = []
    build = commands.run(["zig", "build"], cwd=workspace)
    completion = (
        build.returncode == 0 and not build.timed_out and not build.output_truncated
    )
    if not completion:
        failures.append(
            _failure("completion.build_failed", "zig build failed or timed out")
        )

    unit = commands.run(["zig", "build", "test"], cwd=workspace)
    tests_green = (
        unit.returncode == 0 and not unit.timed_out and not unit.output_truncated
    )
    if not tests_green:
        failures.append(
            _failure("tests.unit_failed", "zig build test failed or timed out")
        )
    try:
        script = _package_test_script(workspace)
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
        tests_green = False
    else:
        client = commands.run(["npm", "run", script], cwd=workspace)
        if client.returncode != 0 or client.timed_out or client.output_truncated:
            failures.append(
                _failure("tests.client_failed", f"npm run {script} failed or timed out")
            )
            tests_green = False
    return completion, tests_green, tuple(failures)


def _compose_file(workspace: Path) -> Path:
    for name in (
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
    ):
        path = workspace / name
        if path.is_file():
            return path
    raise GradeFailure("deployment.compose_missing", "no Compose file was found")


def _compose_service(config: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    services = config.get("services")
    if not isinstance(services, dict) or not services:
        raise GradeFailure(
            "deployment.compose_invalid", "Compose config has no services"
        )
    if "zigbase" in services:
        name = "zigbase"
    else:
        candidates = []
        for candidate, value in services.items():
            if not isinstance(value, dict):
                continue
            environment = value.get("environment", {})
            if isinstance(environment, dict) and any(
                str(key).startswith("ZIGBASE_") for key in environment
            ):
                candidates.append(candidate)
        if len(candidates) == 1:
            name = candidates[0]
        elif len(services) == 1:
            name = next(iter(services))
        else:
            raise GradeFailure(
                "deployment.compose_invalid",
                "Compose must identify one service with ZigBase configuration",
            )
    service = services[name]
    if not isinstance(service, dict):
        raise GradeFailure(
            "deployment.compose_invalid", "ZigBase service config is not an object"
        )
    return name, service


def inspect_compose(config: dict[str, Any]) -> str:
    name, service = _compose_service(config)
    mounts = service.get("volumes", [])
    if not any(
        isinstance(mount, dict)
        and mount.get("type") == "volume"
        and mount.get("target") == "/data"
        for mount in mounts
    ):
        raise GradeFailure(
            "deployment.data_not_persistent",
            "ZigBase service needs a named volume at /data",
        )
    image = service.get("image")
    if isinstance(image, str) and (image.endswith(":latest") or ":" not in image):
        raise GradeFailure(
            "deployment.image_unpinned", "deployment image must use an exact version"
        )
    if not image and "build" not in service:
        raise GradeFailure(
            "deployment.image_missing", "service must declare an image or build"
        )
    environment = service.get("environment", {})
    if not isinstance(environment, dict):
        raise GradeFailure(
            "deployment.environment_invalid", "service environment must be a mapping"
        )
    if str(environment.get("ZIGBASE_COOKIE_SECURE", "true")).lower() in {"false", "0"}:
        raise GradeFailure(
            "deployment.insecure_cookies", "production Compose disables secure cookies"
        )
    public_url = str(environment.get("ZIGBASE_PUBLIC_URL", ""))
    if not public_url.startswith("https://"):
        raise GradeFailure(
            "deployment.public_url", "production Compose needs an HTTPS public URL"
        )
    if not environment.get("ZIGBASE_SMTP_HOST") and not environment.get(
        "ZIGBASE_SENDMAIL_COMMAND"
    ):
        raise GradeFailure(
            "deployment.mailer", "production Compose does not configure mail delivery"
        )
    return name


def _evaluation_environment(compose: Path) -> dict[str, str]:
    environment = {
        "ZIGBASE_JWT_SECRET": "x" * 64,
        "ZIGBASE_SMTP_HOST": "smtp.example.invalid",
        "ZIGBASE_PUBLIC_URL": "https://eval.invalid",
    }
    text = compose.read_text(errors="replace")
    if len(text.encode()) > MAX_SOURCE_BYTES:
        raise GradeFailure(
            "deployment.compose_invalid", "Compose file exceeds the grading limit"
        )
    for name in COMPOSE_VARIABLE.findall(text):
        if name in environment:
            continue
        upper = name.upper()
        if "DOMAIN" in upper:
            value = "eval.invalid"
        elif "URL" in upper:
            value = "https://eval.invalid"
        elif any(part in upper for part in ("PASSWORD", "SECRET", "TOKEN", "KEY")):
            value = "x" * 64
        elif any(part in upper for part in ("EMAIL", "FROM", "USERNAME")):
            value = "eval@example.invalid"
        elif "PORT" in upper:
            value = "587"
        elif "TLS" in upper:
            value = "starttls"
        else:
            value = "eval"
        environment[name] = value
    return environment


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _http_json(url: str, timeout: float) -> dict[str, Any]:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        if response.status != 200:
            raise urllib.error.HTTPError(
                url, response.status, "not healthy", response.headers, None
            )
        value = json.loads(response.read())
    if not isinstance(value, dict):
        raise ValueError("response is not a JSON object")
    return value


def _wait_http(getter, url: str, attempts: int = 30) -> dict[str, Any]:
    import time

    last: Exception | None = None
    for _ in range(attempts):
        try:
            return getter(url, 1.0)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            last = exc
            time.sleep(1)
    raise GradeFailure(
        "deployment.health_timeout", f"endpoint did not become healthy: {last}"
    )


def run_deployment(
    workspace: Path,
    artifacts: Path,
    commands: Commands,
    http_get=_http_json,
    port_picker=_free_port,
    health_attempts: int = 30,
) -> tuple[bool, DoctorReport | None, tuple[EvalFailure, ...]]:
    failures = []
    project = f"zigbase-genesis-{uuid.uuid4().hex[:12]}"
    compose = None
    override = artifacts / "genesis-compose.override.yml"
    base = ["docker", "compose", "-p", project]
    environment: dict[str, str] = {}
    doctor = None
    deployed = False
    cleanup_required = False
    try:
        compose = _compose_file(workspace)
        environment = _evaluation_environment(compose)
        config_result = commands.run(
            [*base, "-f", str(compose), "config", "--format", "json"],
            cwd=workspace,
            env=environment,
        )
        if config_result.returncode != 0 or config_result.output_truncated:
            raise GradeFailure(
                "deployment.compose_invalid", "docker compose config failed"
            )
        try:
            config = json.loads(config_result.stdout)
        except json.JSONDecodeError as exc:
            raise GradeFailure(
                "deployment.compose_invalid", "Compose config did not return JSON"
            ) from exc
        service = inspect_compose(config)
        port = port_picker()
        override.write_text(
            "services:\n"
            f"  {service}:\n"
            "    ports: !override\n"
            f'      - "127.0.0.1:{port}:8090"\n'
            "    environment:\n"
            '      ZIGBASE_HTTP_HOST: "0.0.0.0"\n'
            '      ZIGBASE_HTTP_PORT: "8090"\n'
            '      ZIGBASE_DATA_DIR: "/data"\n'
            '      ZIGBASE_COOKIE_SECURE: "true"\n'
            '      ZIGBASE_TRUST_PROXY: "false"\n'
            '      ZIGBASE_PUBLIC_URL: "https://eval.invalid"\n'
            '      ZIGBASE_JWT_SECRET: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"\n'
            '      ZIGBASE_SMTP_HOST: "smtp.example.invalid"\n'
        )
        stack = [*base, "-f", str(compose), "-f", str(override)]
        cleanup_required = True
        up = commands.run(
            [*stack, "up", "-d", "--build", service],
            cwd=workspace,
            env=environment,
            timeout=600,
        )
        if up.returncode != 0 or up.timed_out or up.output_truncated:
            raise GradeFailure(
                "deployment.start_failed", "Docker Compose failed to start"
            )
        _wait_http(
            http_get,
            f"http://127.0.0.1:{port}/api/health",
            attempts=health_attempts,
        )
        _wait_http(
            http_get,
            f"http://127.0.0.1:{port}/api/meta",
            attempts=health_attempts,
        )
        doctor_result = commands.run(
            [
                *stack,
                "exec",
                "-T",
                service,
                "/proc/1/exe",
                "doctor",
                "--production",
                "--json",
                "--data-dir",
                "/data",
            ],
            cwd=workspace,
            env=environment,
        )
        if (
            doctor_result.returncode not in {0, 2}
            or doctor_result.timed_out
            or doctor_result.output_truncated
        ):
            raise GradeFailure("deployment.doctor_failed", "production doctor failed")
        doctor = parse_doctor_ndjson(doctor_result.stdout)
        deployed = doctor.errors == 0 and doctor.skipped == 0
    except (GradeFailure, OSError, ValueError) as exc:
        code = exc.code if isinstance(exc, GradeFailure) else "deployment.error"
        failures.append(_failure(code, str(exc)))
    finally:
        if compose is not None and cleanup_required:
            stack = (
                [*base, "-f", str(compose), "-f", str(override)]
                if override.exists()
                else [*base, "-f", str(compose)]
            )
            down = commands.run(
                [*stack, "down", "-v", "--remove-orphans"],
                cwd=workspace,
                env=environment,
                timeout=120,
            )
            if down.returncode != 0 or down.timed_out or down.output_truncated:
                failures.append(
                    _failure(
                        "deployment.teardown_failed", "Docker Compose teardown failed"
                    )
                )
                deployed = False
            ps = commands.run(
                [*stack, "ps", "-q"], cwd=workspace, env=environment, timeout=30
            )
            if ps.returncode != 0 or ps.output_truncated or ps.stdout.strip():
                failures.append(
                    _failure(
                        "deployment.teardown_incomplete",
                        "scenario containers remain after teardown",
                    )
                )
                deployed = False
    return deployed, doctor, tuple(failures)


def grade(
    workspace: Path,
    artifacts: Path,
    *,
    commands: Commands | None = None,
    http_get=_http_json,
    port_picker=_free_port,
    health_attempts: int = 30,
) -> GradeReport:
    artifacts.mkdir(parents=True, exist_ok=True)
    commands = commands or SubprocessCommands(artifacts)
    failures = list(inspect_completion(workspace))
    build_ok, tests_green, command_failures = run_build_and_tests(workspace, commands)
    failures.extend(command_failures)
    deployed, doctor, deployment_failures = run_deployment(
        workspace,
        artifacts,
        commands,
        http_get=http_get,
        port_picker=port_picker,
        health_attempts=health_attempts,
    )
    failures.extend(deployment_failures)

    rules_locked = False
    try:
        inventory = load_public_inventory(workspace / "security" / "public-rules.json")
        if doctor is None:
            raise GradeFailure(
                "rules.doctor_missing", "production doctor output is unavailable"
            )
        compare_public_rules(inventory, doctor)
        rules_locked = True
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))

    completion = (
        not any(failure.code.startswith("completion.") for failure in failures)
        and build_ok
    )
    return GradeReport(completion, rules_locked, tests_green, deployed, tuple(failures))
