import json
from pathlib import Path

import pytest

from evals.agents.result import (
    EvalFailure,
    EvalResult,
    ResultError,
    resolve_output_path,
)
from evals.agents.scenario import AgentScenario, ScenarioError


REPO = Path(__file__).resolve().parents[2]
GENESIS = REPO / "evals" / "agents" / "scenarios" / "genesis" / "scenario.json"
GENESIS_PROMPT = GENESIS.with_name("prompt.md")
GENESIS_EVIDENCE = (
    REPO / "evals" / "agents" / "evidence" / "genesis" / "2026-08-15-3f3224d5"
)
POCKETBASE_EVIDENCE = (
    REPO / "evals" / "agents" / "evidence" / "pocketbase" / "2026-08-16-9a72b656"
)
DOCKER_REFERENCE = REPO / "skills" / "zigbase-app-genesis" / "references" / "docker.md"
GENESIS_REFERENCE = (
    REPO / "skills" / "zigbase-app-genesis" / "references" / "app-genesis.md"
)


def result_dict():
    return {
        "zigbaseAgentEval": 1,
        "scenario": "genesis",
        "commit": "abc123",
        "agent": "fake-agent",
        "started_at": "2026-08-15T12:00:00Z",
        "duration_ms": 123,
        "agent_exit": 0,
        "timed_out": False,
        "interventions": 0,
        "completion": True,
        "rules_locked": True,
        "tests_green": True,
        "deployed": True,
        "score": 4,
        "failures": [],
    }


def scenario_dict():
    return json.loads(GENESIS.read_text())


def test_result_round_trip_and_stable_field_order():
    result = EvalResult.from_dict(result_dict())
    assert EvalResult.from_json(result.to_json()) == result
    assert list(json.loads(result.to_json())) == list(EvalResult.FIELDS)


def test_result_round_trip_with_structured_failure():
    value = result_dict()
    value.update(
        completion=False,
        score=3,
        failures=[{"code": "app.missing", "message": "missing"}],
    )
    assert EvalResult.from_dict(value).failures == (
        EvalFailure("app.missing", "missing"),
    )


@pytest.mark.parametrize("mutation", ["missing", "unknown", "future"])
def test_result_rejects_contract_drift(mutation):
    value = result_dict()
    if mutation == "missing":
        value.pop("agent")
    elif mutation == "unknown":
        value["agents"] = value.pop("agent")
    else:
        value["zigbaseAgentEval"] = 2
    with pytest.raises(ResultError):
        EvalResult.from_dict(value)


def test_result_rejects_inconsistent_score():
    value = result_dict()
    value["score"] = 3
    with pytest.raises(ResultError, match="score"):
        EvalResult.from_dict(value)


def test_first_genesis_release_evidence_is_three_clean_consecutive_runs():
    files = sorted(GENESIS_EVIDENCE.glob("run-*.json"))
    assert [path.name for path in files] == ["run-1.json", "run-2.json", "run-3.json"]

    results = [EvalResult.from_json(path.read_text()) for path in files]
    assert {result.commit for result in results} == {
        "3f3224d50d2bc8e45b3888011ac118397103cd75"
    }
    assert all(
        result.scenario == "genesis"
        and result.agent == "codex-cli-0.147-default"
        and result.agent_exit == 0
        and not result.timed_out
        and result.interventions == 0
        and result.completion
        and result.rules_locked
        and result.tests_green
        and result.deployed
        and result.score == 4
        and result.failures == ()
        for result in results
    )


def test_first_pocketbase_release_evidence_is_three_clean_consecutive_runs():
    files = sorted(POCKETBASE_EVIDENCE.glob("run-*.json"))
    assert [path.name for path in files] == ["run-1.json", "run-2.json", "run-3.json"]

    results = [EvalResult.from_json(path.read_text()) for path in files]
    assert {result.commit for result in results} == {
        "9a72b656b7df8cc732aa249b7ba9f84ddd89dba6"
    }
    assert all(
        result.scenario == "pocketbase"
        and result.agent == "codex-cli-0.147-default"
        and result.agent_exit == 0
        and not result.timed_out
        and result.interventions == 0
        and result.completion
        and result.rules_locked
        and result.tests_green
        and result.deployed
        and result.score == 4
        and result.failures == ()
        for result in results
    )


def test_output_path_stays_below_selected_root(tmp_path):
    assert resolve_output_path(Path("results/run.json"), tmp_path) == (
        tmp_path / "results" / "run.json"
    )
    with pytest.raises(ResultError):
        resolve_output_path(Path("../escaped.json"), tmp_path)


def test_genesis_scenario_loads():
    scenario = AgentScenario.load(GENESIS)
    assert scenario.name == "genesis"
    assert scenario.skills == ("zigbase-app-genesis",)
    assert scenario.graders == ("genesis",)


def test_genesis_prompt_states_product_boundaries_exercised_by_the_grader():
    prompt = GENESIS_PROMPT.read_text().lower()
    required = (
        "anonymous visitors can browse",
        "relation-expanded listing",
        "workspace root",
        "framework-mode application",
        "zigbase.testing",
        "zigbase_eval_commit",
        '"zigbasepublicrules": 1',
        "format version",
        "not substitutes",
        "client or browser integration test",
        "production-shaped docker compose",
        "secure cookies enabled",
        "configure mail delivery",
        "environment interpolation",
    )
    assert all(boundary in prompt for boundary in required)


def test_genesis_docker_reference_requires_a_runtime_compatible_build_target():
    reference = DOCKER_REFERENCE.read_text()
    assert "-Dtarget=x86_64-linux-musl" in reference
    assert "no such file or directory" in reference
    assert "real `serve` command" in reference


def test_genesis_reference_distinguishes_public_sentinel_from_filtered_access():
    reference = GENESIS_REFERENCE.read_text()
    assert "`@public` is a complete rule sentinel" in reference
    assert "rather than `@public && published = true`" in reference
    assert "only those exact sentinel rules" in reference


@pytest.mark.parametrize("mutation", ["missing", "unknown", "future"])
def test_scenario_rejects_contract_drift(mutation):
    value = scenario_dict()
    if mutation == "missing":
        value.pop("prompt")
    elif mutation == "unknown":
        value["prompts"] = value.pop("prompt")
    else:
        value["zigbaseAgentScenario"] = 2
    with pytest.raises(ScenarioError):
        AgentScenario.from_dict(value)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("timeout_seconds", -1),
        ("max_command_bytes", 0),
        ("max_output_bytes", 20 * 1024 * 1024),
    ],
)
def test_scenario_rejects_invalid_resource_bounds(field, value):
    manifest = scenario_dict()
    manifest[field] = value
    with pytest.raises(ScenarioError):
        AgentScenario.from_dict(manifest)


@pytest.mark.parametrize("field", ["prompt", "fixture"])
def test_scenario_rejects_path_escape(field):
    manifest = scenario_dict()
    manifest[field] = "../outside"
    with pytest.raises(ScenarioError, match="below"):
        AgentScenario.from_dict(manifest)


def test_scenario_rejects_symlinked_prompt(tmp_path):
    outside = tmp_path / "outside.md"
    outside.write_text("prompt")
    scenario_dir = tmp_path / "scenario"
    scenario_dir.mkdir()
    (scenario_dir / "prompt.md").symlink_to(outside)
    manifest = scenario_dict()
    (scenario_dir / "scenario.json").write_text(json.dumps(manifest))
    with pytest.raises(ScenarioError, match="symlinks"):
        AgentScenario.load(scenario_dir / "scenario.json")


def test_scenario_rejects_symlinked_root(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    (real / "prompt.md").write_text("prompt")
    (real / "scenario.json").write_text(json.dumps(scenario_dict()))
    linked = tmp_path / "linked"
    linked.symlink_to(real, target_is_directory=True)
    with pytest.raises(ScenarioError, match="symlinks"):
        AgentScenario.load(linked / "scenario.json")
