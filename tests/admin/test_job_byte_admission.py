"""Byte-only admission has no HTTP request cap or counting."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path

import pytest

from test_admission import call, ready_call, token
from test_health import assert_liveness_ignores_multipart
from test_shared_admission import gate, wait_for  # noqa: F401 - shared autouse barrier


@pytest.fixture(scope="session")
def binary():
    configured = os.environ.get("ZIGBASE_TEST_JOB_BYTE_ADMISSION_BINARY")
    if not configured:
        pytest.skip("requires job-byte-admission-fixture -Dcoordinated-admission=true")
    path = Path(configured).resolve()
    assert path.is_file(), path
    return str(path)


def test_byte_only_admission_never_reserves_http_capacity(server, gate):
    admin = token(server)
    assert ready_call(server, "/submit", method="POST")[0] == 204
    wait_for(gate / "job-entered")
    with ThreadPoolExecutor(max_workers=3) as executor:
        requests = [executor.submit(call, server, f"/hold/{name}") for name in ("one", "two", "three")]
        try:
            for name in ("one", "two", "three"):
                wait_for(gate / name)
            status, _, body = call(server, "/api/admission/stats", token=admin)
            assert status == 200, body
            stats = json.loads(body)
            assert stats["limit"] is None
            assert stats["active"] == stats["high_water"] == stats["rejected"] == 0
            assert stats["work_limit"] is None
            assert stats["jobs"] == stats["work_high_water"] == 0
            assert stats["job_bytes"] == stats["job_bytes_limit"] == 4
        finally:
            (gate / "release").touch()
        assert [request.result()[0] for request in requests] == [204, 204, 204]


def test_byte_only_liveness_ignores_multipart(server):
    assert_liveness_ignores_multipart(server)
