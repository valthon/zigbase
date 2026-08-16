import json
import shutil
from pathlib import Path

import pytest

from evals.agents.graders.genesis import (
    CommandResult,
    GradeFailure,
    SubprocessCommands,
    _evaluation_environment,
    _client_test_sources,
    compare_public_rules,
    grade,
    inspect_compose,
    load_public_inventory,
    parse_doctor_ndjson,
    run_build_and_tests,
)


FIXTURES = Path(__file__).parent / "fixtures" / "genesis"


def doctor_output(
    *, duplicate=False, subject="equipment.listRule", errors=0, skipped=0
):
    finding = {
        "check": "public-rules-enumerated",
        "severity": "warn",
        "subject": subject,
        "message": "public",
    }
    lines = ["non-json startup log", json.dumps(finding)]
    if duplicate:
        lines.append(json.dumps(finding))
    lines.append(
        json.dumps(
            {
                "summary": True,
                "production": True,
                "checks": 9,
                "errors": errors,
                "warnings": 1,
                "skipped": skipped,
            }
        )
    )
    return "\n".join(lines)


def compose_config():
    return {
        "services": {
            "zigbase": {
                "image": "ghcr.io/valthon/zigbase:0.13.0",
                "environment": {
                    "ZIGBASE_PUBLIC_URL": "https://gear.example.com",
                    "ZIGBASE_SMTP_HOST": "smtp.example.com",
                },
                "volumes": [{"type": "volume", "source": "data", "target": "/data"}],
            }
        },
        "volumes": {"data": {}},
    }


class FakeCommands:
    def __init__(
        self,
        *,
        fail_unit=False,
        fail_up=False,
        fail_config=False,
        config=None,
        doctor=None,
    ):
        self.fail_unit = fail_unit
        self.fail_up = fail_up
        self.fail_config = fail_config
        self.config = config or compose_config()
        self.doctor = doctor or doctor_output()
        self.calls = []

    def run(self, argv, *, cwd, env=None, timeout=300):
        self.calls.append(argv)
        if argv[-4:] == ["zig", "build", "test"] or (
            "zig" in argv and argv[-2:] == ["build", "test"]
        ):
            return CommandResult(1 if self.fail_unit else 0)
        if "config" in argv:
            return CommandResult(
                1 if self.fail_config else 0,
                "" if self.fail_config else json.dumps(self.config),
            )
        if "up" in argv:
            return CommandResult(1 if self.fail_up else 0)
        if "doctor" in argv:
            return CommandResult(2, self.doctor)
        if "ps" in argv:
            return CommandResult(0, "")
        return CommandResult(0)


def workspace(tmp_path, overlay=None):
    target = tmp_path / "workspace"
    shutil.copytree(FIXTURES / "positive", target)
    (target / ".home").mkdir()
    (target / ".tmp").mkdir()
    if overlay == "completion_failure":
        shutil.copy(FIXTURES / overlay / "main.zig", target / "src" / "main.zig")
    elif overlay == "rules_failure":
        shutil.copy(
            FIXTURES / overlay / "public-rules.json",
            target / "security" / "public-rules.json",
        )
    elif overlay == "tests_failure":
        shutil.copy(FIXTURES / overlay / "package.json", target / "package.json")
    elif overlay == "deployment_failure":
        shutil.copy(
            FIXTURES / overlay / "docker-compose.yml", target / "docker-compose.yml"
        )
    return target


def healthy(_url, _timeout):
    return {"ok": True}


def grade_fixture(workspace_path, artifacts, **kwargs):
    return grade(
        workspace_path,
        artifacts,
        http_get=healthy,
        port_picker=lambda: 18080,
        **kwargs,
    )


def test_positive_fixture_scores_four_and_always_tears_down(tmp_path):
    commands = FakeCommands()
    artifacts = tmp_path / "artifacts"
    report = grade_fixture(workspace(tmp_path), artifacts, commands=commands)
    assert (
        report.completion,
        report.rules_locked,
        report.tests_green,
        report.deployed,
    ) == (
        True,
        True,
        True,
        True,
    )
    assert report.failures == ()
    assert any("down" in call for call in commands.calls)
    assert any("ps" in call for call in commands.calls)
    assert "zigbase_eval" in (artifacts / "genesis-compose.override.yml").read_text()


def test_named_request_collection_counts_as_request_workflow(tmp_path):
    target = workspace(tmp_path)
    main = target / "src" / "main.zig"
    main.write_text(main.read_text().replace(".requests =", ".loan_requests ="))

    report = grade_fixture(target, tmp_path / "artifacts", commands=FakeCommands())

    assert report.completion is True
    assert not any(
        failure.code == "completion.requests_missing" for failure in report.failures
    )


@pytest.mark.parametrize(
    ("overlay", "false_grade", "failure_prefix"),
    [
        ("completion_failure", "completion", "completion."),
        ("rules_failure", "rules_locked", "rules."),
        ("tests_failure", "tests_green", "tests."),
        ("deployment_failure", "deployed", "deployment."),
    ],
)
def test_one_fixture_failure_per_grade(tmp_path, overlay, false_grade, failure_prefix):
    commands = FakeCommands()
    if overlay == "deployment_failure":
        commands = FakeCommands(
            config={"services": {"zigbase": {"image": "zigbase:latest"}}}
        )
    report = grade_fixture(
        workspace(tmp_path, overlay),
        tmp_path / "artifacts",
        commands=commands,
    )
    assert getattr(report, false_grade) is False
    assert any(failure.code.startswith(failure_prefix) for failure in report.failures)


def test_command_failures_are_independent(tmp_path):
    unit = grade_fixture(
        workspace(tmp_path),
        tmp_path / "artifacts",
        commands=FakeCommands(fail_unit=True),
    )
    assert unit.completion is True
    assert unit.tests_green is False
    assert unit.deployed is True


def test_keyword_bait_and_noop_client_script_cannot_score_completion(tmp_path):
    target = workspace(tmp_path)
    (target / "src" / "main.zig").write_text(
        'const equipment = "equipment";\n'
        'const members = "members";\n'
        'const requests = "requests";\n'
        'const cursor = "cursor";\n'
        'const expand = "expand";\n'
    )
    (target / "package.json").write_text(
        json.dumps({"scripts": {"test:e2e": "exit 0"}})
    )
    shutil.rmtree(target / "tests")
    report = grade_fixture(target, tmp_path / "artifacts", commands=FakeCommands())
    assert report.completion is False
    assert report.tests_green is False
    assert any(
        failure.code in {"completion.client_test_missing", "tests.client_invalid"}
        for failure in report.failures
    )


def test_subprocess_commands_resolve_pinned_tools_before_home_isolation(tmp_path):
    workspace_path = tmp_path / "workspace"
    workspace_path.mkdir()
    (workspace_path / ".home").mkdir()
    (workspace_path / ".tmp").mkdir()
    artifacts = tmp_path / "artifacts"
    artifacts.mkdir()
    tool_dir = tmp_path / "trusted-tools"
    (tool_dir / "bin").mkdir(parents=True)
    zig = tool_dir / "zig"
    npm = tool_dir / "bin" / "npm"
    zig.write_text("#!/bin/sh\nprintf 'zig-direct\\n'\n")
    npm.write_text("#!/bin/sh\nprintf 'npm-direct\\n'\n")
    zig.chmod(0o755)
    npm.chmod(0o755)
    resolved = []

    def resolver(spec, relative):
        resolved.append((spec, relative))
        return str(tool_dir / relative)

    commands = SubprocessCommands(artifacts, tool_resolver=resolver)
    assert commands.run(["zig", "version"], cwd=workspace_path).stdout == "zig-direct\n"
    assert (
        commands.run(["npm", "--version"], cwd=workspace_path).stdout == "npm-direct\n"
    )
    assert resolved == [("zig@0.16.0", "zig"), ("node@24", "bin/npm")]


def test_health_timeout_still_tears_down(tmp_path):
    commands = FakeCommands()

    def unhealthy(_url, _timeout):
        raise OSError("not ready")

    report = grade(
        workspace(tmp_path),
        tmp_path / "artifacts",
        commands=commands,
        http_get=unhealthy,
        port_picker=lambda: 18080,
        health_attempts=1,
    )
    assert report.deployed is False
    assert any(
        failure.code == "deployment.health_timeout" for failure in report.failures
    )
    assert any("logs" in call for call in commands.calls)
    assert any("down" in call for call in commands.calls)
    assert any("ps" in call for call in commands.calls)


def test_invalid_compose_config_does_not_report_false_teardown_failures(tmp_path):
    commands = FakeCommands(fail_config=True)

    report = grade_fixture(
        workspace(tmp_path), tmp_path / "artifacts", commands=commands
    )

    assert any(
        failure.code == "deployment.compose_invalid" for failure in report.failures
    )
    assert not any(
        failure.code.startswith("deployment.teardown") for failure in report.failures
    )
    assert not any("down" in call or "ps" in call for call in commands.calls)


def test_doctor_parser_skips_logs_and_rejects_duplicate_or_unknown_subjects():
    report = parse_doctor_ndjson(doctor_output())
    assert report.public_rules == frozenset({("equipment", "list")})
    with pytest.raises(GradeFailure, match="duplicate"):
        parse_doctor_ndjson(doctor_output(duplicate=True))
    with pytest.raises(GradeFailure, match="unknown"):
        parse_doctor_ndjson(doctor_output(subject="equipment.publishRule"))


def test_doctor_parser_requires_exactly_one_summary():
    with pytest.raises(GradeFailure, match="exactly one"):
        parse_doctor_ndjson("not json")
    duplicate_summary = json.dumps(
        {
            "summary": True,
            "production": True,
            "checks": 9,
            "errors": 0,
            "warnings": 1,
            "skipped": 0,
        }
    )
    with pytest.raises(GradeFailure, match="exactly one"):
        parse_doctor_ndjson(doctor_output() + "\n" + duplicate_summary)


def test_inventory_rejects_duplicate_empty_rationale_and_unknown_keys(tmp_path):
    base = {
        "collection": "equipment",
        "operation": "list",
        "rule": "@public",
        "rationale": "catalog",
    }
    cases = [
        [base, base],
        [{**base, "rationale": ""}],
        [{**base, "extra": True}],
    ]
    for rules in cases:
        path = tmp_path / f"inventory-{len(list(tmp_path.iterdir()))}.json"
        path.write_text(json.dumps({"zigbasePublicRules": 1, "rules": rules}))
        with pytest.raises(GradeFailure):
            load_public_inventory(path)


def test_rules_grade_accepts_filtered_anonymous_read_without_public_inventory(tmp_path):
    target = workspace(tmp_path)
    (target / "security" / "public-rules.json").write_text(
        json.dumps(
            {
                "zigbasePublicRules": 1,
                "rules": [
                    {
                        "collection": "members",
                        "operation": "create",
                        "rule": "@public",
                        "rationale": "open signup",
                    }
                ],
            }
        )
    )
    commands = FakeCommands(doctor=doctor_output(subject="members.createRule"))

    report = grade_fixture(target, tmp_path / "artifacts", commands=commands)

    assert report.rules_locked is True
    assert not any(failure.code.startswith("rules.") for failure in report.failures)


def test_completion_source_limit_ignores_downloaded_zig_packages(tmp_path):
    target = workspace(tmp_path)
    package = target / "zig-pkg" / "dependency"
    package.mkdir(parents=True)
    (package / "large.zig").write_text("x" * (5 * 1024 * 1024))

    report = grade_fixture(target, tmp_path / "artifacts", commands=FakeCommands())

    assert not any(
        failure.code == "completion.source_limit" for failure in report.failures
    )


@pytest.mark.parametrize("script", ["test:integration", "test:journey"])
def test_client_integration_script_is_an_accepted_project_test(tmp_path, script):
    target = workspace(tmp_path)
    (target / "package.json").write_text(
        json.dumps({"scripts": {script: "node --test"}})
    )
    commands = FakeCommands()

    _, tests_green, failures = run_build_and_tests(target, commands)

    assert tests_green is True
    assert failures == ()
    assert ["npm", "run", script] in commands.calls


def test_client_source_in_singular_test_directory_is_discovered(tmp_path):
    target = tmp_path / "workspace"
    source = target / "test" / "client-journey.mjs"
    source.parent.mkdir(parents=True)
    source.write_text('import assert from "node:assert/strict"; assert.ok(true);')

    assert _client_test_sources(target) == (source,)


def test_compose_finds_application_beside_tls_proxy():
    config = compose_config()
    config["services"] = {
        "gearshare": config["services"].pop("zigbase"),
        "caddy": {
            "image": "caddy:2.10.0-alpine",
            "volumes": [{"type": "volume", "source": "caddy", "target": "/data"}],
        },
    }

    assert inspect_compose(config) == "gearshare"


def test_compose_evaluation_environment_satisfies_declared_secret_names(tmp_path):
    compose = tmp_path / "compose.yaml"
    compose.write_text(
        "environment:\n"
        "  ZIGBASE_PUBLIC_URL: https://${APP_DOMAIN:?set domain}\n"
        "  ZIGBASE_SMTP_PASSWORD: ${ZIGBASE_SMTP_PASSWORD:?set password}\n"
        "  ZIGBASE_SMTP_USERNAME: ${SMTP_USERNAME:-sender@example.invalid}\n"
        "  image: ${GEARSHARE_IMAGE:-gearshare:0.1.0}\n"
    )

    environment = _evaluation_environment(compose)

    assert environment["APP_DOMAIN"] == "eval.invalid"
    assert environment["ZIGBASE_SMTP_PASSWORD"] == "x" * 64
    assert "SMTP_USERNAME" not in environment
    assert "GEARSHARE_IMAGE" not in environment


def test_public_rule_comparison_rejects_stale_extra_and_doctor_errors():
    inventory = frozenset({("equipment", "list")})
    with pytest.raises(GradeFailure, match="missing"):
        compare_public_rules(frozenset(), parse_doctor_ndjson(doctor_output()))
    with pytest.raises(GradeFailure, match="absent"):
        compare_public_rules(
            frozenset({("equipment", "list"), ("members", "view")}),
            parse_doctor_ndjson(doctor_output()),
        )
    with pytest.raises(GradeFailure, match="errors"):
        compare_public_rules(inventory, parse_doctor_ndjson(doctor_output(errors=1)))
    with pytest.raises(GradeFailure, match="skipped"):
        compare_public_rules(inventory, parse_doctor_ndjson(doctor_output(skipped=1)))
