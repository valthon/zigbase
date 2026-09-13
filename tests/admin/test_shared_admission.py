"""Opt-in shared work ceiling: real HTTP, lazy memory worker, external barrier."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import time

import pytest

from test_admission import call, ready_call, token


@pytest.fixture(scope="session")
def binary():
    configured = os.environ.get("ZIGBASE_TEST_SHARED_ADMISSION_BINARY")
    if not configured:
        pytest.skip("requires shared-admission-fixture -Dcoordinated-admission=true")
    path = Path(configured).resolve()
    assert path.is_file(), path
    return str(path)


@pytest.fixture(autouse=True)
def gate(tmp_path, monkeypatch):
    monkeypatch.setenv("ZIGBASE_TEST_GATE", str(tmp_path))
    yield tmp_path
    (tmp_path / "release").touch()


def wait_for(path):
    deadline = time.monotonic() + 5
    while not path.exists():
        assert time.monotonic() < deadline, path
        time.sleep(.01)


def test_jobs_and_http_share_capacity_and_recover(server, gate):
    admin = token(server)
    status, _, body = ready_call(server, "/submit", method="POST")
    assert (status, body) == (200, b"second-job-rejected")
    wait_for(gate / "entered")
    status, _, body = ready_call(server, "/api/admission/stats", token=admin)
    assert status == 200, body
    value = json.loads(body)
    assert value["jobs"] == 1
    assert value["work_limit"] == 2
    assert value["jobs_rejected"] == 1
    assert value["work_high_water"] == 2
    with ThreadPoolExecutor(max_workers=1) as executor:
        request = executor.submit(ready_call, server, "/hold")
        try:
            wait_for(gate / "http-entered")
            # Only ONE HTTP request is active (max_requests is TWO): the memory
            # job consumes the other shared slot and causes this rejection.
            status, headers, body = call(server, "/api/admission/stats", token=admin)
            assert status == 503
            assert headers["Retry-After"] == "1"
            assert json.loads(body)["code"] == "overloaded"
            assert call(server, "/api/health")[0] == 200
        finally:
            (gate / "release").touch()
        assert request.result()[0] == 204
    deadline = time.monotonic() + 5
    while True:
        status, _, body = ready_call(server, "/api/admission/stats", token=admin)
        assert status == 200, body
        value = json.loads(body)
        if value["jobs"] == 0:
            break
        assert time.monotonic() < deadline, value
        time.sleep(.01)
    assert value["active"] == 1
    assert value["rejected"] >= 1
