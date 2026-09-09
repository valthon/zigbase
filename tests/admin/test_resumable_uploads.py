"""Real HTTP network-resume checks; explicitly use the small-budget fixture."""
import concurrent.futures
import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.request

import pytest
from conftest import _free_port, _su_template_for, _wait_reachable_or_fail


@pytest.fixture(scope="session")
def binary():
    path = os.environ.get("ZIGBASE_TEST_RESUMABLE_BINARY")
    if not path:
        pytest.skip("requires resumable-uploads-fixture built with -Dresumable-uploads=true")
    assert os.path.isfile(path)
    return path


def call(server, method, path, body=None, token=None, offset=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if isinstance(body, bytes):
        data = body
        headers["Content-Type"] = "application/octet-stream"
    else:
        data = None if body is None else json.dumps(body).encode()
    if offset is not None:
        headers["Upload-Offset"] = str(offset)
    request = urllib.request.Request(server + path, data=data, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        data = response.read()
        if data and response.headers.get("Content-Type", "").startswith("application/json"):
            data = json.loads(data)
        return response.status, data


def setup(server):
    code, result = call(server, "POST", "/api/collections/_superusers/auth-with-password", {"identity": "admin@x.io", "password": "adminpassword"})
    assert code == 200, result
    admin = result["token"]
    code, users = call(server, "POST", "/api/collections", {"name": "users", "type": "auth", "fields": []}, admin)
    assert code == 201, users
    tokens = []
    for email in ("one@x.io", "two@x.io"):
        code, user = call(server, "POST", "/api/collections/users/records", {"email": email, "password": "userpassword"}, admin)
        assert code == 201, user
        code, session = call(server, "POST", "/api/collections/users/auth-with-password", {"identity": email, "password": "userpassword"})
        assert code == 200, session
        tokens.append(session["token"])
    code, col = call(server, "POST", "/api/collections", {"name": "uploads", "type": "base", "fields": [{"id": "", "name": "file", "type": "file", "options": {"maxSelect": 1, "maxSize": 64}}, {"id": "", "name": "title", "type": "text", "options": {}}], "updateRule": "@public", "viewRule": "@public"}, admin)
    assert code == 201, col
    code, record = call(server, "POST", "/api/collections/uploads/records", {"title": "before"}, admin)
    assert code == 201, record
    return admin, tokens, col, record


def begin(server, token, record, length=4, filename="a.txt"):
    return call(server, "POST", f"/api/collections/uploads/records/{record['id']}/uploads", {"field": "file", "filename": filename, "length": length, "mimetype": "text/plain"}, token)


def test_resume_current_record_and_completed_retry(server):
    admin, tokens, _, record = setup(server)
    code, upload = begin(server, tokens[0], record)
    assert code == 201 and len(upload["id"]) == 32 and upload["durability"] == "process-local", upload
    path = "/api/uploads/" + upload["id"]
    assert call(server, "PATCH", path, b"ab", tokens[0], 0)[0] == 204
    assert call(server, "GET", path, token=tokens[0])[1]["offset"] == 2
    assert call(server, "PATCH", path, b"ab", tokens[0], 0)[0] == 204
    assert call(server, "PATCH", path, b"bc", tokens[0], 1)[0] == 409
    assert call(server, "PATCH", path, b"zz", tokens[0], 0)[0] == 409
    assert call(server, "PATCH", path, b"d", tokens[0], 3)[0] == 409
    assert call(server, "POST", path + "/commit", token=tokens[0])[0] == 409
    assert call(server, "PATCH", path, b"cd", tokens[0], 2)[0] == 204
    record_path = "/api/collections/uploads/records/" + record["id"]
    assert call(server, "PATCH", record_path, {"title": "latest"}, admin)[0] == 200
    before = call(server, "GET", "/api/upload-probe", token=admin)[1]
    assert call(server, "POST", path + "/commit", token=tokens[0])[0] == 204
    saved = call(server, "GET", record_path)[1]
    assert saved["title"] == "latest"
    assert call(server, "GET", f"/api/files/uploads/{record['id']}/{saved['file']}")[1] == b"abcd"
    # A caller that missed the commit acknowledgement may attempt cancellation.
    # Reject it without destroying the acknowledgement or repeating side effects.
    assert call(server, "DELETE", path, token=tokens[0])[0] == 409
    assert call(server, "POST", path + "/commit", token=tokens[0])[0] == 204
    assert call(server, "GET", record_path)[1] == saved
    assert call(server, "GET", path, token=tokens[0])[1]["state"] == "completed"
    assert call(server, "GET", "/api/upload-probe", token=admin)[1] == {"before": before["before"] + 1, "after": before["after"] + 1}


def test_current_collection_identity_and_hook_failure_are_terminal(server):
    admin, tokens, col, record = setup(server)
    _, upload = begin(server, tokens[0], record)
    path = "/api/uploads/" + upload["id"]
    assert call(server, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    assert call(server, "DELETE", "/api/collections/" + col["id"], token=admin)[0] == 204
    body = {"name": "uploads", "type": "base", "fields": col["schema"], "updateRule": "@public", "viewRule": "@public"}
    code, replacement = call(server, "POST", "/api/collections", body, admin)
    assert code == 201 and replacement["id"] != col["id"], replacement
    code, recreated = call(server, "POST", "/api/collections/uploads/records", {"title": "new collection"}, admin)
    assert code == 201, recreated
    assert call(server, "POST", path + "/commit", token=tokens[0])[0] == 409
    assert call(server, "GET", path, token=tokens[0])[1]["state"] == "failed"
    assert not call(server, "GET", "/api/collections/uploads/records/" + recreated["id"])[1]["file"]

    code, rejected = call(server, "POST", "/api/collections/uploads/records", {"title": "reject"}, admin)
    assert code == 201, rejected
    _, upload = begin(server, tokens[1], rejected, filename="reject.txt")
    path = "/api/uploads/" + upload["id"]
    assert call(server, "PATCH", path, b"abcd", tokens[1], 0)[0] == 204
    before = call(server, "GET", "/api/upload-probe", token=admin)[1]
    assert call(server, "POST", path + "/commit", token=tokens[1])[0] == 400
    assert call(server, "DELETE", path, token=tokens[1])[0] == 409
    assert call(server, "GET", path, token=tokens[1])[1]["state"] == "failed"
    assert call(server, "POST", path + "/commit", token=tokens[1])[0] == 409
    assert call(server, "GET", "/api/upload-probe", token=admin)[1] == {"before": before["before"] + 1, "after": before["after"]}


def test_principal_required_for_every_operation_and_revocation(server):
    admin, tokens, col, record = setup(server)
    assert begin(server, None, record)[0] == 401
    code, upload = begin(server, tokens[0], record)
    assert code == 201, upload
    path = "/api/uploads/" + upload["id"]
    for method, suffix, body, offset in [("GET", "", None, None), ("PATCH", "", b"abcd", 0), ("DELETE", "", None, None), ("POST", "/commit", None, None)]:
        assert call(server, method, path + suffix, body, tokens[1], offset)[0] == 404
        assert call(server, method, path + suffix, body, None, offset)[0] == 401
    assert call(server, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    col["fields"] = col["schema"]
    col["updateRule"] = None
    assert call(server, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    assert call(server, "POST", path + "/commit", token=tokens[0])[0] == 403
    assert call(server, "GET", path, token=tokens[0])[1]["state"] == "failed"
    col["updateRule"] = "@public"
    assert call(server, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    assert call(server, "POST", path + "/commit", token=tokens[0])[0] == 409
    assert not call(server, "GET", "/api/collections/uploads/records/" + record["id"])[1]["file"]


def test_abort_expiry_and_configured_limits(server):
    _, tokens, _, record = setup(server)
    assert begin(server, tokens[0], record, 65)[0] == 413
    _, first = begin(server, tokens[0], record, 64)
    path = "/api/uploads/" + first["id"]
    assert call(server, "PATCH", path, b"x" * 9, tokens[0], 0)[0] == 400
    _, second = begin(server, tokens[0], record, 64)
    assert begin(server, tokens[0], record)[0] == 429
    assert begin(server, tokens[1], record)[0] == 429  # aggregate bytes, another principal
    assert call(server, "DELETE", path, token=tokens[0])[0] == 204
    assert call(server, "GET", path, token=tokens[0])[0] == 404
    assert begin(server, tokens[1], record)[0] == 201
    time.sleep(5.2)
    assert call(server, "GET", "/api/uploads/" + second["id"], token=tokens[0])[0] == 404
    assert begin(server, tokens[0], record, 64)[0] == 201


def test_token_revocation_and_current_file_constraints(server):
    admin, tokens, col, record = setup(server)
    _, upload = begin(server, tokens[0], record)
    path = "/api/uploads/" + upload["id"]
    assert call(server, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    users = call(server, "GET", "/api/collections/users/records", token=admin)[1]["items"]
    user = next(user for user in users if user["email"] == "one@x.io")
    assert call(server, "PATCH", "/api/collections/users/records/" + user["id"], {"password": "replacementpassword"}, admin)[0] == 200
    for method, suffix, body, offset in [("GET", "", None, None), ("PATCH", "", b"abcd", 0), ("DELETE", "", None, None), ("POST", "/commit", None, None)]:
        assert call(server, method, path + suffix, body, tokens[0], offset)[0] == 401
    code, refreshed = call(server, "POST", "/api/collections/users/auth-with-password", {"identity": "one@x.io", "password": "replacementpassword"})
    assert code == 200, refreshed
    col["fields"] = col["schema"]
    next(field for field in col["fields"] if field["name"] == "file")["options"]["maxSize"] = 2
    assert call(server, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    assert call(server, "POST", path + "/commit", token=refreshed["token"])[0] == 413
    assert call(server, "GET", path, token=refreshed["token"])[1]["state"] == "failed"


def test_declared_field_limit_rejected_before_reserving_slots_or_bytes(server):
    admin, tokens, col, record = setup(server)
    col["fields"] = col["schema"]
    file = next(field for field in col["fields"] if field["name"] == "file")
    file["options"]["maxSize"] = 2
    assert call(server, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    for _ in range(3):
        code, error = begin(server, tokens[0], record, 3)
        assert code == 413 and error["code"] == "payload_too_large", error
    # Rejected requests must consume neither the two principal slots nor any
    # aggregate payload bytes: both complete 64-byte reservations still fit.
    file["options"]["maxSize"] = 64
    assert call(server, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    assert begin(server, tokens[0], record, 64)[0] == 201
    assert begin(server, tokens[0], record, 64)[0] == 201
    assert begin(server, tokens[1], record)[0] == 429


def test_declared_store_limit_is_rejected_when_field_allows_more(server):
    admin, tokens, col, record = setup(server)
    col["fields"] = col["schema"]
    next(field for field in col["fields"] if field["name"] == "file")["options"]["maxSize"] = 128
    assert call(server, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    # The field permits 65 bytes; only the fixture's max_upload_bytes=64 rejects it.
    for _ in range(3):
        code, error = begin(server, tokens[0], record, 65)
        assert code == 400 and error["code"] == "bad_request", error
    assert begin(server, tokens[0], record, 64)[0] == 201
    assert begin(server, tokens[0], record, 64)[0] == 201


@pytest.mark.parametrize("rule,denied", [(None, 403), ("title = 'private'", 404)])
def test_begin_authorizes_before_field_shape_and_record_probes(server, rule, denied):
    admin, tokens, col, record = setup(server)
    col["fields"] = col["schema"]
    col["updateRule"] = rule
    assert call(server, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    responses = []
    for rid in [record["id"], "missingrecord"]:
        for field in ["file", "title", "missingfield"]:
            responses.append(call(server, "POST",
                f"/api/collections/uploads/records/{rid}/uploads",
                {"field": field, "filename": "a.txt", "length": 4}, tokens[0]))
    assert all(code == denied for code, _ in responses), responses
    assert all(body == responses[0][1] for _, body in responses), responses


def test_terminal_sessions_retain_slot_quota_until_expiry(server):
    _, tokens, _, record = setup(server)
    for filename, expected in [("ok.txt", 204), ("reject.txt", 400)]:
        code, upload = begin(server, tokens[0], record, filename=filename)
        assert code == 201, upload
        path = "/api/uploads/" + upload["id"]
        assert call(server, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
        assert call(server, "POST", path + "/commit", token=tokens[0])[0] == expected
        assert call(server, "DELETE", path, token=tokens[0])[0] == 409
    assert begin(server, tokens[0], record)[0] == 429
    # Terminal payloads are freed immediately, despite retained session slots.
    assert begin(server, tokens[1], record, 64)[0] == 201
    assert begin(server, tokens[1], record, 64)[0] == 201
    time.sleep(5.2)
    assert begin(server, tokens[0], record, 64)[0] == 201


def test_removed_file_field_does_not_acknowledge_a_noop(server):
    admin, tokens, col, record = setup(server)
    _, upload = begin(server, tokens[0], record)
    path = "/api/uploads/" + upload["id"]
    assert call(server, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    col["fields"] = [field for field in col["schema"] if field["name"] != "file"]
    assert call(server, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    assert call(server, "POST", path + "/commit", token=tokens[0])[0] == 409
    assert call(server, "GET", path, token=tokens[0])[1]["state"] == "failed"
    assert call(server, "GET", "/api/upload-probe", token=admin)[1] == {"before": 0, "after": 0}


def test_concurrent_identical_chunk_and_commit_are_once(server):
    admin, tokens, _, record = setup(server)
    _, upload = begin(server, tokens[0], record)
    path = "/api/uploads/" + upload["id"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: call(server, "PATCH", path, b"abcd", tokens[0], 0)[0], range(2)))
        assert results == [204, 204]
        results = list(pool.map(lambda _: call(server, "POST", path + "/commit", token=tokens[0])[0], range(2)))
        assert 204 in results and set(results) <= {204, 409}
    assert call(server, "GET", path, token=tokens[0])[1]["state"] == "completed"
    saved = call(server, "GET", "/api/collections/uploads/records/" + record["id"])[1]
    assert saved["file"]
    assert call(server, "GET", "/api/upload-probe", token=admin)[1] == {"before": 1, "after": 1}


def test_disabled_http_routes(tmp_path):
    off = os.environ.get("ZIGBASE_TEST_UPLOADS_OFF_BINARY")
    if not off:
        pytest.skip("requires a default-build negative control")
    port = _free_port()
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(tmp_path / "off"), "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"}
    log_path = tmp_path / "off.log"
    with log_path.open("wb") as log:
        proc = subprocess.Popen([off, "serve", "--insecure-cookies"], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        _wait_reachable_or_fail(proc, port, str(log_path))
        server = f"http://127.0.0.1:{port}"
        for method, path in [("POST", "/api/collections/x/records/y/uploads"), ("GET", "/api/uploads/x"), ("PATCH", "/api/uploads/x"), ("DELETE", "/api/uploads/x"), ("POST", "/api/uploads/x/commit")]:
            assert call(server, method, path)[0] == 404
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def test_restart_invalidates_sessions_without_staging_files(binary, tmp_path):
    data = tmp_path / "data"
    shutil.copytree(_su_template_for(binary), data)
    port = _free_port()
    server = f"http://127.0.0.1:{port}"
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(data), "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"}
    log_path = tmp_path / "server.log"
    def start():
        with log_path.open("ab") as log:
            proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env, stdout=log, stderr=subprocess.STDOUT)
        _wait_reachable_or_fail(proc, port, str(log_path))
        return proc
    proc = start()
    try:
        _, tokens, _, record = setup(server)
        _, upload = begin(server, tokens[0], record)
        path = "/api/uploads/" + upload["id"]
        assert call(server, "PATCH", path, b"ab", tokens[0], 0)[0] == 204
    finally:
        proc.terminate()
        proc.wait(timeout=10)
    proc = start()
    try:
        assert call(server, "GET", path, token=tokens[0])[0] == 404
        assert not list((data / "storage").rglob("a.txt"))
    finally:
        proc.terminate()
        proc.wait(timeout=10)
