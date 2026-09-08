"""Real concurrent HTTP capacity tests; barriers, not sleeps, establish overlap."""
from concurrent.futures import ThreadPoolExecutor
import json
import pathlib
import time
import urllib.error
import urllib.request

import pytest
from _bin import resolve_binary

REPO = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def binary():
    return resolve_binary("ZIGBASE_TEST_ADMISSION_BINARY", REPO, "admission-fixture")


@pytest.fixture(autouse=True)
def gate(tmp_path, monkeypatch):
    monkeypatch.setenv("ZIGBASE_TEST_GATE", str(tmp_path))
    yield tmp_path
    (tmp_path / "release").touch()


def call(base, path, method="GET", data=None, token=None, headers=None):
    headers = dict(headers or {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(base + path, data=data, method=method, headers=headers)
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def ready_call(*args, **kwargs):
    # Receiving bytes need not mean the preceding callback has finished teardown.
    deadline = time.monotonic() + 5
    while True:
        result = call(*args, **kwargs)
        if result[0] != 503:
            return result
        assert time.monotonic() < deadline, "capacity did not recover"
        time.sleep(.02)


def token(base):
    status, _, body = ready_call(base, "/api/collections/_superusers/auth-with-password", "POST",
                          {"identity": "admin@x.io", "password": "adminpassword"})
    assert status == 200, body
    return json.loads(body)["token"]


def test_reject_before_parsing_head_and_recover(server, gate):
    admin = token(server)
    with ThreadPoolExecutor(max_workers=1) as executor:
        held = executor.submit(ready_call, server, "/hold")
        try:
            deadline = time.monotonic() + 5
            while not (gate / "entered").exists():
                assert not held.done(), held.result() if held.done() else None
                assert time.monotonic() < deadline, "handler did not reach barrier"
                time.sleep(.01)
            status, headers, body = call(server, "/api/health", data=b"invalid multipart",
                headers={"Content-Type": "multipart/form-data; boundary=broken"})
            assert status == 200
            assert json.loads(body)["status"] == "ok"
            assert "Retry-After" not in headers
            for path, method in (("/api/health/", "GET"), ("/api/health-extra", "GET"),
                                 ("/api/health", "HEAD"), ("/api/health", "POST")):
                status, headers, body = call(
                    server, path, method, b"invalid multipart" if method == "POST" else None,
                    headers={"Content-Type": "multipart/form-data; boundary=broken"})
                assert status == 503
                assert headers["Retry-After"] == "1"
                assert body == b"" if method == "HEAD" else json.loads(body)["code"] == "overloaded"
            # Diagnostics are not an unbounded bypass of admission.
            assert call(server, "/api/admission/stats", token=admin)[0] == 503
        finally:
            (gate / "release").touch()
        assert held.result()[0] == 200
    status, _, body = ready_call(server, "/api/admission/stats", token=admin)
    assert status == 200
    stats = json.loads(body)
    assert stats["limit"] == stats["active"] == stats["high_water"] == 1
    assert stats["rejected"] >= 4
    assert ready_call(server, "/api/health")[0] == 200


def test_error_and_unauthorized_requests_release_permit(server):
    admin = token(server)
    assert ready_call(server, "/fail")[0] == 500
    assert ready_call(server, "/api/admission/stats")[0] == 401
    assert ready_call(server, "/api/admission/stats", token="invalid")[0] == 401
    assert ready_call(server, "/missing")[0] == 404
    status, _, body = ready_call(server, "/api/admission/stats", token=admin)
    assert status == 200
    assert json.loads(body)["active"] == 1


def test_file_exits_release_and_stats_deny_non_superuser(server, gate):
    admin = token(server)
    assert ready_call(server, "/file")[0] == 404
    (gate / "payload").write_bytes(b"abc")
    assert ready_call(server, "/file")[2] == b"abc"
    assert ready_call(server, "/file", "HEAD")[2] == b""
    status, _, body = ready_call(server, "/api/collections/members/records", "POST",
        {"email": "member@x.io", "password": "memberpassword", "passwordConfirm": "memberpassword"}, token=admin)
    assert status in (200, 201), body
    status, _, body = ready_call(server, "/api/collections/members/auth-with-password", "POST",
        {"identity": "member@x.io", "password": "memberpassword"})
    assert status == 200, body
    member = json.loads(body)["token"]
    assert ready_call(server, "/api/admission/stats", token=member)[0] == 403
    assert ready_call(server, "/api/health")[0] == 200
