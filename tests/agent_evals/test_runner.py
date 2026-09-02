import json
import os
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

from evals.agents import run as run_module
from evals.agents.graders import GradeReport
from evals.agents.process import run_process
from evals.agents.run import (
    HarnessError,
    _atomic_result_copy,
    child_environment,
    execute,
    parse_agent_command,
    substitute_command,
)
from evals.agents.scenario import AgentScenario


REPO = Path(__file__).resolve().parents[2]
FAKE_AGENT = Path(__file__).parent / "fixtures" / "fake_agent.py"


def test_result_copy_is_private_and_atomic(tmp_path, monkeypatch):
    output = tmp_path / "results/latest.json"
    _atomic_result_copy(output, '{"ok":true}')
    assert stat.S_IMODE(output.stat().st_mode) == 0o600

    output.write_text("prior\n")
    monkeypatch.setattr(
        run_module.os,
        "replace",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(OSError("replace denied")),
    )
    with pytest.raises(OSError, match="replace denied"):
        _atomic_result_copy(output, '{"ok":false}')
    assert output.read_text() == "prior\n"


def scenario(**overrides):
    values = {
        "zigbaseAgentScenario": 1,
        "name": "runner-test",
        "prompt": "prompt.md",
        "fixture": None,
        "skills": ["zigbase-app-genesis"],
        "graders": ["genesis"],
        "timeout_seconds": 2,
        "term_grace_seconds": 1,
        "max_command_bytes": 4096,
        "max_output_bytes": 4096,
    }
    values.update(overrides)
    return AgentScenario.from_dict(values)


def make_scenario_root(tmp_path):
    root = tmp_path / "scenario"
    root.mkdir()
    (root / "prompt.md").write_text("build the test app")
    return root


def passing_grader(names, workspace, artifacts):
    assert names == ("genesis",)
    payload = json.loads((workspace / "agent-result.json").read_text())
    assert payload["stdin"] == "build the test app"
    assert payload["home"] == str(workspace / ".home")
    assert len(payload["evaluation_commit"]) == 40
    assert (
        workspace / ".agents" / "skills" / "zigbase-app-genesis" / "SKILL.md"
    ).is_file()
    assert artifacts.is_dir()
    return GradeReport(True, True, True, True)


def test_execute_success_sends_prompt_and_grades(tmp_path):
    root = make_scenario_root(tmp_path)
    result, exit_code = execute(
        scenario=scenario(),
        scenario_root=root,
        command_raw=json.dumps([sys.executable, str(FAKE_AGENT), "success", "-"]),
        artifacts_root=tmp_path / "artifacts",
        agent_name="fake",
        interventions=0,
        passed_env=[],
        grader=passing_grader,
        work_root=tmp_path,
    )
    assert exit_code == 0
    assert result.score == 4
    assert result.failures == ()
    assert result.commit == run_module.repository_commit()
    run_directory = next((tmp_path / "artifacts").iterdir())
    assert stat.S_IMODE(run_directory.stat().st_mode) == 0o700
    assert stat.S_IMODE((run_directory / "agent.stdout.log").stat().st_mode) == 0o600
    assert stat.S_IMODE((run_directory / "agent.stderr.log").stat().st_mode) == 0o600


def test_cleanup_failure_preserves_grade_and_adds_harness_finding(
    tmp_path, monkeypatch
):
    root = make_scenario_root(tmp_path)

    def fail_cleanup(_workspace):
        raise PermissionError("workspace remains owned by container uid")

    monkeypatch.setattr(run_module, "cleanup_workspace", fail_cleanup)
    result, exit_code = execute(
        scenario=scenario(),
        scenario_root=root,
        command_raw=json.dumps([sys.executable, str(FAKE_AGENT), "success", "-"]),
        artifacts_root=tmp_path / "artifacts",
        agent_name="fake",
        interventions=0,
        passed_env=[],
        grader=passing_grader,
        work_root=tmp_path,
    )
    assert exit_code == 1
    assert result.score == 4
    assert result.failures[-1].code == "harness.cleanup"


def test_execute_copies_fixture_before_agent_runs(tmp_path):
    root = make_scenario_root(tmp_path)
    fixture = root / "fixture"
    fixture.mkdir()
    (fixture / "seed.txt").write_text("seeded")

    def fixture_grader(names, workspace, artifacts):
        assert (workspace / "seed.txt").read_text() == "seeded"
        return passing_grader(names, workspace, artifacts)

    result, exit_code = execute(
        scenario=scenario(fixture="fixture"),
        scenario_root=root,
        command_raw=json.dumps([sys.executable, str(FAKE_AGENT), "success", "-"]),
        artifacts_root=tmp_path / "artifacts",
        agent_name="fake",
        interventions=0,
        passed_env=[],
        grader=fixture_grader,
        work_root=tmp_path,
    )
    assert exit_code == 0
    assert result.score == 4


def test_completed_agent_with_failing_grade_exits_two(tmp_path):
    root = make_scenario_root(tmp_path)
    result, exit_code = execute(
        scenario=scenario(),
        scenario_root=root,
        command_raw=json.dumps([sys.executable, str(FAKE_AGENT), "success", "-"]),
        artifacts_root=tmp_path / "artifacts",
        agent_name="fake",
        interventions=0,
        passed_env=[],
        grader=lambda _names, _workspace, _artifacts: GradeReport(
            True, True, True, False
        ),
        work_root=tmp_path,
    )
    assert exit_code == 2
    assert result.score == 3


@pytest.mark.parametrize(
    ("mode", "expected_code", "timed_out"),
    [("nonzero", "agent.nonzero", False), ("sleep", "agent.timeout", True)],
)
def test_execute_reports_nonzero_and_timeout(tmp_path, mode, expected_code, timed_out):
    root = make_scenario_root(tmp_path)
    result, exit_code = execute(
        scenario=scenario(timeout_seconds=1),
        scenario_root=root,
        command_raw=json.dumps([sys.executable, str(FAKE_AGENT), mode]),
        artifacts_root=tmp_path / "artifacts",
        agent_name="fake",
        interventions=0,
        passed_env=[],
        work_root=tmp_path,
    )
    assert exit_code == 1
    assert result.timed_out is timed_out
    assert result.failures[0].code == expected_code


def test_execute_fails_closed_when_declared_skill_is_missing(tmp_path):
    root = make_scenario_root(tmp_path)
    result, exit_code = execute(
        scenario=scenario(skills=["missing-skill"]),
        scenario_root=root,
        command_raw=json.dumps([sys.executable, str(FAKE_AGENT), "success"]),
        artifacts_root=tmp_path / "artifacts",
        agent_name="fake",
        interventions=0,
        passed_env=[],
        work_root=tmp_path,
    )
    assert exit_code == 1
    assert result.agent_exit == -1
    assert result.failures[0].code == "harness.error"
    assert "missing-skill" in result.failures[0].message


def test_execute_caps_combined_output(tmp_path):
    root = make_scenario_root(tmp_path)
    result, exit_code = execute(
        scenario=scenario(max_output_bytes=1024),
        scenario_root=root,
        command_raw=json.dumps([sys.executable, str(FAKE_AGENT), "flood"]),
        artifacts_root=tmp_path / "artifacts",
        agent_name="fake",
        interventions=0,
        passed_env=[],
        work_root=tmp_path,
    )
    logs = list((tmp_path / "artifacts").glob("*/*.log"))
    assert sum(path.stat().st_size for path in logs) == 1024
    assert exit_code == 1
    assert result.failures[0].code == "agent.output_limit"


def test_process_kills_grandchild_and_never_invokes_a_shell(tmp_path):
    result = run_process(
        [sys.executable, str(FAKE_AGENT), "spawn", "$(touch hacked)", ";touch hacked2"],
        cwd=tmp_path,
        env=child_environment(tmp_path, [], {"PATH": os.environ["PATH"]}),
        stdin=None,
        stdout_path=tmp_path / "stdout.log",
        stderr_path=tmp_path / "stderr.log",
        timeout_seconds=2,
        term_grace_seconds=1,
        max_output_bytes=4096,
    )
    assert result.exit_code == 0
    assert not (tmp_path / "hacked").exists()
    assert not (tmp_path / "hacked2").exists()
    child_pid = int((tmp_path / "child.pid").read_text())
    for _ in range(20):
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        pytest.fail("agent grandchild survived process-group cleanup")


def test_process_logs_are_private(tmp_path):
    stdout = tmp_path / "stdout.log"
    stderr = tmp_path / "stderr.log"
    result = run_process(
        [sys.executable, "-c", "print('private')"],
        cwd=tmp_path,
        env=child_environment(tmp_path, [], {"PATH": os.environ["PATH"]}),
        stdin=None,
        stdout_path=stdout,
        stderr_path=stderr,
        timeout_seconds=2,
        term_grace_seconds=1,
        max_output_bytes=4096,
    )
    assert result.exit_code == 0
    assert stat.S_IMODE(stdout.stat().st_mode) == 0o600
    assert stat.S_IMODE(stderr.stat().st_mode) == 0o600


def test_process_can_leave_captured_output_in_logs_without_reading_it_back(tmp_path):
    stdout = tmp_path / "stdout.log"
    stderr = tmp_path / "stderr.log"
    result = run_process(
        [
            sys.executable,
            "-c",
            "import sys; print('out'); print('err', file=sys.stderr)",
        ],
        cwd=tmp_path,
        env=child_environment(tmp_path, [], {"PATH": os.environ["PATH"]}),
        stdin=None,
        stdout_path=stdout,
        stderr_path=stderr,
        timeout_seconds=2,
        term_grace_seconds=1,
        max_output_bytes=4096,
        read_output=False,
    )

    assert result.stdout == ""
    assert result.stderr == ""
    assert stdout.read_text() == "out\n"
    assert stderr.read_text() == "err\n"


def test_timeout_still_applies_when_agent_does_not_read_large_stdin(tmp_path):
    started = time.monotonic()
    result = run_process(
        [sys.executable, str(FAKE_AGENT), "sleep"],
        cwd=tmp_path,
        env=child_environment(tmp_path, [], {"PATH": os.environ["PATH"]}),
        stdin=b"x" * 200_000,
        stdout_path=tmp_path / "stdout.log",
        stderr_path=tmp_path / "stderr.log",
        timeout_seconds=1,
        term_grace_seconds=1,
        max_output_bytes=4096,
    )
    assert result.timed_out is True
    assert time.monotonic() - started < 3


def test_cli_interrupt_cleans_up_agent_and_emits_stable_result(tmp_path):
    env = os.environ.copy()
    env["ZIGBASE_AGENT_COMMAND_JSON"] = json.dumps(
        [sys.executable, str(FAKE_AGENT), "sleep"]
    )
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "evals.agents.run",
            "genesis",
            "--artifacts-dir",
            str(tmp_path / "artifacts"),
        ],
        cwd=REPO,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 5
    while not list((tmp_path / "artifacts").glob("*/agent.stderr.log")):
        assert process.poll() is None
        if time.monotonic() >= deadline:
            process.kill()
            pytest.fail("runner did not start the agent before the test deadline")
        time.sleep(0.05)

    process.send_signal(signal.SIGINT)
    stdout, stderr = process.communicate(timeout=5)

    assert process.returncode == 1
    payload = json.loads(stdout)
    assert payload["failures"][0]["code"] == "agent.interrupted"
    assert payload["timed_out"] is False
    assert "Traceback" not in stderr


def test_paths_with_spaces_are_literal(tmp_path):
    workspace = tmp_path / "workspace with spaces"
    prompt = tmp_path / "prompt with spaces.md"
    assert substitute_command(
        ["tool", "{workspace}", "{prompt}"], workspace, prompt
    ) == [
        "tool",
        str(workspace),
        str(prompt),
    ]


def test_command_parser_rejects_invalid_and_oversized_json():
    with pytest.raises(HarnessError):
        parse_agent_command("not-json", 100)
    with pytest.raises(HarnessError):
        parse_agent_command(json.dumps(["x" * 100]), 20)
    with pytest.raises(HarnessError):
        parse_agent_command(json.dumps("tool"), 100)


def test_environment_is_allowlisted_and_explicit(tmp_path):
    source = {
        "PATH": "/bin",
        "UNRELATED_SECRET": "hidden",
        "FAKE_AGENT_SECRET": "passed",
    }
    env = child_environment(tmp_path, ["FAKE_AGENT_SECRET"], source)
    assert env["FAKE_AGENT_SECRET"] == "passed"
    assert "UNRELATED_SECRET" not in env
    with pytest.raises(HarnessError):
        child_environment(tmp_path, ["MISSING"], source)


def test_cli_prints_exactly_one_result_object(tmp_path):
    env = os.environ.copy()
    env["ZIGBASE_AGENT_COMMAND_JSON"] = json.dumps(
        [sys.executable, str(FAKE_AGENT), "nonzero"]
    )
    completed = subprocess.run(
        [
            sys.executable,
            "-m",
            "evals.agents.run",
            "genesis",
            "--artifacts-dir",
            str(tmp_path / "artifacts"),
            "--out",
            "results/result.json",
        ],
        cwd=REPO,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert completed.returncode == 1
    lines = completed.stdout.splitlines()
    assert len(lines) == 1
    assert json.loads(lines[0])["failures"][0]["code"] == "agent.nonzero"
    assert (
        tmp_path / "artifacts" / "results" / "result.json"
    ).read_text().strip() == lines[0]


def test_cli_harness_failure_uses_stable_result_contract(tmp_path):
    completed = subprocess.run(
        [
            sys.executable,
            "-m",
            "evals.agents.run",
            "missing-scenario",
            "--artifacts-dir",
            str(tmp_path / "artifacts"),
        ],
        cwd=REPO,
        text=True,
        capture_output=True,
        check=False,
    )
    assert completed.returncode == 1
    payload = json.loads(completed.stdout)
    assert list(payload) == [
        "zigbaseAgentEval",
        "scenario",
        "commit",
        "agent",
        "started_at",
        "duration_ms",
        "agent_exit",
        "timed_out",
        "interventions",
        "completion",
        "rules_locked",
        "tests_green",
        "deployed",
        "score",
        "failures",
    ]
    assert payload["failures"][0]["code"] == "harness.error"


def test_cli_output_escape_fails_closed_in_the_single_result(tmp_path):
    env = os.environ.copy()
    env["ZIGBASE_AGENT_COMMAND_JSON"] = json.dumps(
        [sys.executable, str(FAKE_AGENT), "nonzero"]
    )
    completed = subprocess.run(
        [
            sys.executable,
            "-m",
            "evals.agents.run",
            "genesis",
            "--artifacts-dir",
            str(tmp_path / "artifacts"),
            "--out",
            "../escaped.json",
        ],
        cwd=REPO,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert completed.returncode == 1
    assert not (tmp_path / "escaped.json").exists()
    payload = json.loads(completed.stdout)
    assert [failure["code"] for failure in payload["failures"]] == [
        "agent.nonzero",
        "harness.output",
    ]
