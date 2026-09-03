"""Provider-neutral agent evaluation runner.

Run from the repository root, for example:

    ZIGBASE_AGENT_COMMAND_JSON='["codex","exec","-C","{workspace}","-"]' \
      python -m evals.agents.run genesis
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import sys
import tempfile
import time
import uuid
from collections.abc import Callable, Sequence
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from .graders import GradeReport, grade
from .process import run_process
from .result import EvalFailure, EvalResult, ResultError, resolve_output_path
from .scenario import AgentScenario, ScenarioError


REPO = Path(__file__).resolve().parents[2]
SCENARIOS = Path(__file__).resolve().parent / "scenarios"
BASE_ENV_NAMES = (
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
)
MAX_PASSED_ENV = 32
MAX_ENV_VALUE_BYTES = 64 * 1024
MAX_PROMPT_BYTES = 256 * 1024


class HarnessError(RuntimeError):
    """The runner could not safely execute or grade the scenario."""


def _atomic_result_copy(path: Path, rendered: str) -> None:
    payload = (rendered + "\n").encode("utf-8")
    path = path.absolute()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def parse_agent_command(raw: str | None, maximum_bytes: int) -> list[str]:
    if raw is None:
        raise HarnessError("ZIGBASE_AGENT_COMMAND_JSON is not set")
    if len(raw.encode()) > maximum_bytes:
        raise HarnessError("agent command exceeds the scenario byte limit")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HarnessError(f"agent command is not valid JSON: {exc.msg}") from exc
    if (
        not isinstance(value, list)
        or not value
        or len(value) > 128
        or not all(isinstance(arg, str) and arg and "\0" not in arg for arg in value)
    ):
        raise HarnessError(
            "agent command must be a non-empty JSON array of safe strings"
        )
    return value


def substitute_command(argv: Sequence[str], workspace: Path, prompt: Path) -> list[str]:
    substitutions = {"{workspace}": str(workspace), "{prompt}": str(prompt)}
    return [substitutions.get(arg, arg) for arg in argv]


def child_environment(
    workspace: Path, passed_names: Sequence[str], source: dict[str, str] | None = None
) -> dict[str, str]:
    source = os.environ if source is None else source
    if len(passed_names) > MAX_PASSED_ENV or len(set(passed_names)) != len(
        passed_names
    ):
        raise HarnessError("explicit environment pass list is duplicated or too large")
    for name in passed_names:
        if not name or not name.replace("_", "a").isalnum() or not name[0].isalpha():
            raise HarnessError(f"invalid environment name: {name!r}")
        if name.startswith("ZIGBASE_AGENT_"):
            raise HarnessError(
                f"runner control variable cannot be passed through: {name}"
            )

    env = {name: source[name] for name in BASE_ENV_NAMES if name in source}
    for name in passed_names:
        if name not in source:
            raise HarnessError(f"requested environment variable is not set: {name}")
        if len(source[name].encode()) > MAX_ENV_VALUE_BYTES:
            raise HarnessError(f"environment variable is too large: {name}")
        env[name] = source[name]
    env.update(
        {
            "HOME": str(workspace / ".home"),
            "TMPDIR": str(workspace / ".tmp"),
            "ZIGBASE_AGENT_EVAL": "1",
        }
    )
    return env


def copy_fixture(fixture: Path, workspace: Path) -> None:
    for path in fixture.rglob("*"):
        if path.is_symlink():
            raise HarnessError(
                f"fixture contains a symlink: {path.relative_to(fixture)}"
            )
    shutil.copytree(fixture, workspace, dirs_exist_ok=True)


def install_skills(names: Sequence[str], workspace: Path) -> None:
    destination_root = workspace / ".agents" / "skills"
    for name in names:
        source = REPO / "skills" / name
        if not source.is_dir() or source.is_symlink():
            raise HarnessError(f"scenario skill is missing or symlinked: {name}")
        for path in source.rglob("*"):
            if path.is_symlink():
                raise HarnessError(
                    f"scenario skill contains a symlink: {name}/{path.relative_to(source)}"
                )
        shutil.copytree(source, destination_root / name)


def repository_commit() -> str:
    import subprocess

    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPO,
        text=True,
        capture_output=True,
        check=False,
    )
    return completed.stdout.strip() if completed.returncode == 0 else "unknown"


def cleanup_workspace(workspace: Path) -> None:
    """Remove only the runner-created path, without following a replacement symlink."""
    try:
        if workspace.is_symlink():
            workspace.unlink()
        else:
            shutil.rmtree(workspace)
    except FileNotFoundError:
        pass


def directory_identity(path: Path) -> tuple[int, int]:
    metadata = os.lstat(path)
    if not stat.S_ISDIR(metadata.st_mode):
        raise HarnessError(f"runner directory was replaced: {path}")
    return metadata.st_dev, metadata.st_ino


def require_directory_identity(path: Path, expected: tuple[int, int]) -> None:
    if directory_identity(path) != expected:
        raise HarnessError(f"runner directory was replaced: {path}")


def reset_grader_scratch(workspace: Path) -> None:
    """Discard agent-controlled HOME/TMPDIR contents before grader commands run."""
    for name in (".home", ".tmp"):
        path = workspace / name
        try:
            metadata = os.lstat(path)
        except FileNotFoundError:
            pass
        else:
            if stat.S_ISDIR(metadata.st_mode):
                shutil.rmtree(path)
            else:
                path.unlink()
        path.mkdir(mode=0o700)


def execute(
    *,
    scenario: AgentScenario,
    scenario_root: Path,
    command_raw: str | None,
    artifacts_root: Path,
    agent_name: str,
    interventions: int,
    passed_env: Sequence[str],
    grader: Callable[[tuple[str, ...], Path, Path], GradeReport] = grade,
    work_root: Path | None = None,
) -> tuple[EvalResult, int]:
    started = datetime.now(UTC)
    start_clock = time.monotonic()
    evaluation_commit = repository_commit()
    run_id = (
        f"{scenario.name}-{started.strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
    )
    artifacts = artifacts_root.resolve() / run_id
    artifacts.mkdir(parents=True, exist_ok=False)
    artifacts.chmod(0o700)
    workspace = Path(
        tempfile.mkdtemp(prefix="zigbase-agent-eval-", dir=work_root)
    ).resolve()
    (workspace / ".home").mkdir()
    (workspace / ".tmp").mkdir()
    artifacts_identity = directory_identity(artifacts)
    workspace_identity = directory_identity(workspace)
    process_exit = -1
    timed_out = False

    try:
        argv = parse_agent_command(command_raw, scenario.max_command_bytes)
        prompt = (scenario_root / scenario.prompt).resolve()
        prompt_bytes = prompt.read_bytes()
        if len(prompt_bytes) > MAX_PROMPT_BYTES:
            raise HarnessError("scenario prompt exceeds the runner byte limit")
        if scenario.fixture is not None:
            copy_fixture((scenario_root / scenario.fixture).resolve(), workspace)
        install_skills(scenario.skills, workspace)
        env = child_environment(workspace, passed_env)
        env["ZIGBASE_EVAL_COMMIT"] = evaluation_commit
        completed = run_process(
            substitute_command(argv, workspace, prompt),
            cwd=workspace,
            env=env,
            stdin=prompt_bytes if "-" in argv else None,
            stdout_path=artifacts / "agent.stdout.log",
            stderr_path=artifacts / "agent.stderr.log",
            timeout_seconds=scenario.timeout_seconds,
            term_grace_seconds=scenario.term_grace_seconds,
            max_output_bytes=scenario.max_output_bytes,
            read_output=False,
        )
        process_exit = completed.exit_code
        timed_out = completed.timed_out
        require_directory_identity(workspace, workspace_identity)
        require_directory_identity(artifacts, artifacts_identity)
        failures: tuple[EvalFailure, ...] = ()
        if completed.interrupted:
            failures = (
                EvalFailure("agent.interrupted", "agent command was interrupted"),
            )
        elif completed.timed_out:
            failures = (
                EvalFailure(
                    "agent.timeout", "agent command exceeded the scenario timeout"
                ),
            )
        elif completed.exit_code != 0:
            failures = (
                EvalFailure("agent.nonzero", "agent command exited unsuccessfully"),
            )
        elif completed.output_truncated:
            failures = (
                EvalFailure(
                    "agent.output_limit", "captured agent output exceeded the limit"
                ),
            )

        if failures:
            report = GradeReport(False, False, False, False, failures)
            exit_code = 1
        else:
            reset_grader_scratch(workspace)
            report = grader(scenario.graders, workspace, artifacts)
            exit_code = (
                0
                if all(
                    (
                        report.completion,
                        report.rules_locked,
                        report.tests_green,
                        report.deployed,
                    )
                )
                else 2
            )
    except (HarnessError, OSError, ValueError) as exc:
        report = GradeReport(
            False,
            False,
            False,
            False,
            (EvalFailure("harness.error", str(exc)),),
        )
        exit_code = 1
    finally:
        try:
            cleanup_workspace(workspace)
        except OSError as exc:
            report = replace(
                report,
                failures=(
                    *report.failures,
                    EvalFailure("harness.cleanup", str(exc)),
                ),
            )
            exit_code = 1

    grades = (
        report.completion,
        report.rules_locked,
        report.tests_green,
        report.deployed,
    )
    result = EvalResult(
        zigbaseAgentEval=1,
        scenario=scenario.name,
        commit=evaluation_commit,
        agent=agent_name,
        started_at=started.isoformat().replace("+00:00", "Z"),
        duration_ms=round((time.monotonic() - start_clock) * 1000),
        agent_exit=process_exit,
        timed_out=timed_out,
        interventions=interventions,
        completion=report.completion,
        rules_locked=report.rules_locked,
        tests_green=report.tests_green,
        deployed=report.deployed,
        score=sum(grades),
        failures=report.failures,
    )
    return result, exit_code


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("scenario")
    value.add_argument("--agent", default="user-supplied")
    value.add_argument("--interventions", type=int, default=0)
    value.add_argument(
        "--artifacts-dir",
        type=Path,
        default=Path(tempfile.gettempdir()) / "zigbase-agent-evals",
    )
    value.add_argument("--out", type=Path)
    value.add_argument("--pass-env", action="append", default=[])
    return value


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    started = datetime.now(UTC)
    try:
        if args.interventions < 0:
            raise HarnessError("--interventions must be non-negative")
        scenario_path = SCENARIOS / args.scenario / "scenario.json"
        scenario = AgentScenario.load(scenario_path)
        result, exit_code = execute(
            scenario=scenario,
            scenario_root=scenario_path.parent,
            command_raw=os.environ.get("ZIGBASE_AGENT_COMMAND_JSON"),
            artifacts_root=args.artifacts_dir,
            agent_name=args.agent,
            interventions=args.interventions,
            passed_env=args.pass_env,
        )
    except (HarnessError, ScenarioError, ResultError, OSError) as exc:
        result = EvalResult(
            zigbaseAgentEval=1,
            scenario=args.scenario,
            commit=repository_commit(),
            agent=args.agent,
            started_at=started.isoformat().replace("+00:00", "Z"),
            duration_ms=0,
            agent_exit=-1,
            timed_out=False,
            interventions=max(args.interventions, 0),
            completion=False,
            rules_locked=False,
            tests_green=False,
            deployed=False,
            score=0,
            failures=(EvalFailure("harness.error", str(exc)),),
        )
        exit_code = 1

    rendered = result.to_json()
    if args.out is not None:
        try:
            output = resolve_output_path(args.out, args.artifacts_dir)
            _atomic_result_copy(output, rendered)
        except (ResultError, OSError) as exc:
            # Stdout remains authoritative when the optional copy cannot be
            # written; never emit a second object or a transcript.
            result = replace(
                result,
                failures=(*result.failures, EvalFailure("harness.output", str(exc))),
            )
            rendered = result.to_json()
            exit_code = 1
    print(rendered)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
