import os
import shutil
from pathlib import Path

import pytest

from evals.agents.graders.genesis import SubprocessCommands, run_deployment


FIXTURE = Path(__file__).parent / "fixtures" / "genesis" / "positive"


@pytest.mark.skipif(
    os.environ.get("ZIGBASE_DOCKER_EVAL_TEST") != "1",
    reason="set ZIGBASE_DOCKER_EVAL_TEST=1 to run the live Compose grader test",
)
def test_live_compose_health_doctor_and_teardown(tmp_path):
    workspace = tmp_path / "workspace"
    shutil.copytree(FIXTURE, workspace)
    (workspace / ".home").mkdir()
    (workspace / ".tmp").mkdir()
    artifacts = tmp_path / "artifacts"
    artifacts.mkdir()

    deployed, doctor, failures = run_deployment(
        workspace,
        artifacts,
        SubprocessCommands(artifacts),
        health_attempts=60,
    )

    assert deployed is True, failures
    assert doctor is not None
    assert doctor.errors == 0
    assert doctor.skipped == 0
    assert failures == ()
