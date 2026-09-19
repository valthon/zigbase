"""Live consumer admission and bounded operator inspection through HTTP."""
from concurrent.futures import ThreadPoolExecutor
import os
import pathlib
import pytest
from test_query_workbench import call, admin

@pytest.fixture(scope="session")
def binary():
    value = os.environ.get("ZIGBASE_TEST_DURABLE_CAPACITY_BINARY")
    if not value:
        pytest.skip("requires durable-capacity-fixture")
    assert pathlib.Path(value).is_file()
    return value


def test_concurrent_enqueues_stop_at_retained_count(server):
    token = admin(server)
    assert call(server, "GET", "/job-budget/counted")[0] == 403
    with ThreadPoolExecutor(max_workers=8) as executor:
        statuses = list(executor.map(lambda _: call(server, "POST", "/job-budget/counted", b"{}", token)[0], range(8)))
    assert sorted(statuses) == [204] * 4 + [503] * 4
    code, stats = call(server, "GET", "/job-budget/counted", token=token)
    assert code == 200
    assert stats["retained_jobs"] == 4
    assert stats["retained_payload_bytes"] == 8
    assert stats["full"] and stats["exact"]
    assert "payload" not in stats  # no retained contents returned
    assert call(server, "POST", "/job-budget/counted", b"{}", token)[0] == 503


def test_utf8_bytes_exhaust_before_count_and_oversized_payload_is_not_stored(server):
    token = admin(server)
    path = "/job-budget/bytes"
    assert call(server, "POST", path, b"x" * 9, token)[0] == 503
    assert call(server, "GET", path, token=token)[1]["retained_jobs"] == 0
    for _ in range(2):
        assert call(server, "POST", path, "éé".encode(), token)[0] == 204
    assert call(server, "POST", path, b"x", token)[0] == 503
    stats = call(server, "GET", path, token=token)[1]
    assert stats["retained_jobs"] == 2 and stats["retained_payload_bytes"] == 8
    assert stats["limits"]["max_jobs"] == 8 and stats["full"]
