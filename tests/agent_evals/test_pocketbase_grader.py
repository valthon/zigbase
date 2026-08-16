import json
import shutil
from pathlib import Path

import pytest

from evals.agents.graders.genesis import CommandResult, GradeFailure
from evals.agents.graders.pocketbase import grade, inspect_completion
from evals.agents.scenario import AgentScenario


REPO = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).parent / "fixtures" / "pocketbase" / "positive"
SCENARIO = REPO / "evals" / "agents" / "scenarios" / "pocketbase" / "scenario.json"


def lint_output():
    lines = [
        {
            "code": "PublicRule",
            "collection": collection,
            "rule": f"{operation}Rule",
        }
        for collection, operation in (
            ("members", "create"),
            ("posts", "list"),
            ("posts", "view"),
        )
    ]
    lines.append({"summary": True, "errors": 0, "warnings": 3})
    return "\n".join(json.dumps(line) for line in lines)


def doctor_output():
    lines = [
        {
            "check": "public-rules-enumerated",
            "severity": "warn",
            "subject": f"{collection}.{operation}Rule",
            "message": "reviewed public rule",
        }
        for collection, operation in (
            ("members", "create"),
            ("posts", "list"),
            ("posts", "view"),
        )
    ]
    lines.append(
        {
            "summary": True,
            "production": True,
            "checks": 11,
            "errors": 0,
            "warnings": 3,
            "skipped": 0,
        }
    )
    return "\n".join(json.dumps(line) for line in lines)


def compose_config():
    return {
        "services": {
            "zigbase": {
                "image": "ghcr.io/valthon/zigbase:0.13.0",
                "environment": {
                    "ZIGBASE_PUBLIC_URL": "https://eval.invalid",
                    "ZIGBASE_SMTP_HOST": "smtp.example.invalid",
                },
                "volumes": [
                    {"type": "volume", "source": "data", "target": "/data"}
                ],
            }
        },
        "volumes": {"data": {}},
    }


class FakeCommands:
    def __init__(
        self,
        *,
        fail_client=False,
        fail_restart=False,
        fail_down=False,
        timeout_up=False,
    ):
        self.fail_client = fail_client
        self.fail_restart = fail_restart
        self.fail_down = fail_down
        self.timeout_up = timeout_up
        self.calls = []

    def run(self, argv, *, cwd, env=None, timeout=300):
        self.calls.append(argv)
        if "check-rules" in argv:
            return CommandResult(2, lint_output())
        if "doctor" in argv:
            return CommandResult(2, doctor_output())
        if "config" in argv:
            return CommandResult(0, json.dumps(compose_config()))
        if argv[:5] == ["python3", "-m", "unittest", "discover", "-s"]:
            return CommandResult(1 if self.fail_client else 0)
        if "restart" in argv:
            return CommandResult(1 if self.fail_restart else 0)
        if "up" in argv and self.timeout_up:
            return CommandResult(1, timed_out=True)
        if "down" in argv:
            return CommandResult(1 if self.fail_down else 0)
        return CommandResult(0)


def workspace(tmp_path):
    target = tmp_path / "workspace"
    shutil.copytree(FIXTURE, target)
    return target


def no_probe(*_args, **_kwargs):
    return None


def no_database(*_args, **_kwargs):
    return None


def install_files(_bundle, _target):
    return {"files": 5, "installed": 5, "reused": 0}


def http_request(_method, url):
    if url.endswith("/api/health"):
        return 200, b'{"status":"ok"}'
    return 200, b'{"title":"Public first"}'


def grade_fixture(target, artifacts, commands=None, **kwargs):
    return grade(
        target,
        artifacts,
        commands=commands or FakeCommands(),
        port_picker=lambda: 18081,
        binary_path="zigbase",
        behavior_probe=kwargs.pop("behavior_probe", no_probe),
        database_inspector=kwargs.pop("database_inspector", no_database),
        file_installer=install_files,
        http_request=http_request,
        **kwargs,
    )


def test_pocketbase_scenario_loads_and_names_only_the_migration_skill():
    scenario = AgentScenario.load(SCENARIO)
    assert scenario.name == "pocketbase"
    assert scenario.fixture == "fixture"
    assert scenario.skills == ("zigbase-migrate-pocketbase",)
    assert scenario.graders == ("pocketbase",)


def test_prompt_requires_open_signup_and_warning_not_error():
    prompt = SCENARIO.with_name("prompt.md").read_text().lower()
    for boundary in (
        "anonymous signup must work",
        "members.createrule",
        "warning rather than an error",
        "named durable",
        "survive",
        "down -v --remove-orphans",
    ):
        assert boundary in prompt


def test_scenario_source_and_converter_are_exact_pinned_copies():
    scenario_fixture = SCENARIO.parent / "fixture"
    canonical_source = REPO / "tests" / "pocketbase" / "fixtures" / "v0.39.11"
    expected = {
        path.relative_to(canonical_source).as_posix(): path.read_bytes()
        for path in canonical_source.rglob("*")
        if path.is_file()
    }
    actual = {
        path.relative_to(scenario_fixture / "source").as_posix(): path.read_bytes()
        for path in (scenario_fixture / "source").rglob("*")
        if path.is_file()
    }
    assert actual == expected
    assert (
        scenario_fixture / "tools" / "pocketbase" / "pb2zb.py"
    ).read_bytes() == (REPO / "tools" / "pocketbase" / "pb2zb.py").read_bytes()
    assert (
        FIXTURE / "tools" / "pocketbase" / "pb2zb.py"
    ).read_bytes() == (REPO / "tools" / "pocketbase" / "pb2zb.py").read_bytes()
    schema = json.loads((scenario_fixture / "source" / "pb_schema.json").read_text())
    members = next(collection for collection in schema if collection["name"] == "members")
    assert members["createRule"] == ""


def test_positive_fixture_scores_four_and_tears_down(tmp_path):
    commands = FakeCommands()
    report = grade_fixture(workspace(tmp_path), tmp_path / "artifacts", commands)
    assert (
        report.completion,
        report.rules_locked,
        report.tests_green,
        report.deployed,
    ) == (True, True, True, True)
    assert report.failures == ()
    assert any("restart" in call for call in commands.calls)
    assert any("down" in call for call in commands.calls)
    assert any("ps" in call for call in commands.calls)


@pytest.mark.parametrize(
    ("grade_name", "mutation"),
    [
        ("completion", "missing_report"),
        ("rules_locked", "stale_public_inventory"),
        ("tests_green", "failed_client"),
        ("deployed", "failed_restart"),
    ],
)
def test_one_isolated_failure_per_grade(tmp_path, grade_name, mutation):
    target = workspace(tmp_path)
    commands = FakeCommands(
        fail_client=mutation == "failed_client",
        fail_restart=mutation == "failed_restart",
    )
    if mutation == "missing_report":
        (target / "migration" / "report.json").unlink()
    elif mutation == "stale_public_inventory":
        inventory = json.loads((target / "security" / "public-rules.json").read_text())
        inventory["rules"].pop()
        (target / "security" / "public-rules.json").write_text(json.dumps(inventory))
    report = grade_fixture(target, tmp_path / "artifacts", commands)
    assert getattr(report, grade_name) is False


@pytest.mark.parametrize(
    "mutation",
    ["wrong_version", "extra_field", "unresolved", "secret", "missing_check"],
)
def test_malformed_or_forged_report_is_rejected(tmp_path, mutation):
    target = workspace(tmp_path)
    path = target / "migration" / "report.json"
    value = json.loads(path.read_text())
    if mutation == "wrong_version":
        value["zigbasePocketBaseMigrationReport"] = 2
    elif mutation == "extra_field":
        value["evidence"] = "trust me"
    elif mutation == "unresolved":
        value["unresolved"] = ["view SQL"]
    elif mutation == "secret":
        value["rollback"] = "migrated-secret"
    else:
        value["checks"].remove("signup")
    path.write_text(json.dumps(value))
    _, failures = inspect_completion(target)
    assert any(failure.code.startswith("completion.report") for failure in failures)


@pytest.mark.parametrize("mutation", ["stale", "extra", "duplicate"])
def test_public_rule_inventory_drift_is_rejected(tmp_path, mutation):
    target = workspace(tmp_path)
    path = target / "security" / "public-rules.json"
    value = json.loads(path.read_text())
    if mutation == "stale":
        value["rules"].pop()
    elif mutation == "extra":
        value["rules"].append(
            {
                "collection": "secrets",
                "operation": "view",
                "rule": "@public",
                "rationale": "bad",
            }
        )
    else:
        value["rules"].append(value["rules"][0])
    path.write_text(json.dumps(value))
    report = grade_fixture(target, tmp_path / "artifacts")
    assert report.rules_locked is False


@pytest.mark.parametrize("mutation", ["bundle", "source", "missing_file", "decisions"])
def test_hash_and_decision_tampering_is_rejected_without_leaking_values(tmp_path, mutation):
    target = workspace(tmp_path)
    if mutation == "bundle":
        path = target / "migration" / "bundle" / "schema.json"
        path.write_text(path.read_text() + " ")
    elif mutation == "source":
        path = target / "source" / "pb_schema.json"
        path.write_text(path.read_text() + " ")
    elif mutation == "missing_file":
        storage = target / "migration" / "bundle" / "storage"
        next(path for path in storage.rglob("*") if path.is_file()).unlink()
    else:
        path = target / "migration" / "bundle" / "decisions.json"
        path.write_text(path.read_text().replace("reviewed", "stale", 1))
    report = grade_fixture(target, tmp_path / "artifacts")
    assert report.completion is False
    text = json.dumps([failure.message for failure in report.failures]).lower()
    assert "migrated-secret" not in text
    assert "$2a$" not in text
    assert not any(len(word) == 64 for word in text.split())


@pytest.mark.parametrize("failure_code", ["tests.parity", "tests.credentials", "tests.timestamps", "tests.files"])
def test_behavior_parity_rehash_timestamp_and_file_failures_are_tests_grade(tmp_path, failure_code):
    target = workspace(tmp_path)

    def fail_check(*_args, **_kwargs):
        raise GradeFailure(failure_code, "synthetic mismatch")

    kwargs = (
        {"database_inspector": fail_check}
        if failure_code in {"tests.credentials", "tests.timestamps"}
        else {"behavior_probe": fail_check}
    )
    report = grade_fixture(
        target,
        tmp_path / "artifacts",
        **kwargs,
    )
    assert report.tests_green is False
    assert any(failure.code == failure_code for failure in report.failures)


@pytest.mark.parametrize("mutation", ["timeout", "restart", "teardown"])
def test_docker_timeout_restart_and_teardown_fail_closed(tmp_path, mutation):
    commands = FakeCommands(
        timeout_up=mutation == "timeout",
        fail_restart=mutation == "restart",
        fail_down=mutation == "teardown",
    )
    report = grade_fixture(workspace(tmp_path), tmp_path / "artifacts", commands)
    assert report.deployed is False
    assert any(failure.code.startswith("deployment.") for failure in report.failures)


def test_failure_text_never_contains_transcript_credentials_or_hashes(tmp_path):
    target = workspace(tmp_path)
    (target / "migration" / "report.json").write_text(
        '{"password":"migrated-secret","hash":"' + "a" * 64 + '"}'
    )
    report = grade_fixture(target, tmp_path / "artifacts")
    serialized = json.dumps([failure.message for failure in report.failures]).lower()
    assert "migrated-secret" not in serialized
    assert "a" * 64 not in serialized
