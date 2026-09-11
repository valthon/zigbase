"""Real HTTP authorization, representation and bounded-thumbnail recovery checks."""
import json
import os
import shutil
import sqlite3
import struct
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.request
import zlib

import pytest
from conftest import _free_port, _su_template_for, _wait_reachable_or_fail
from test_file_range import _multipart


PNG = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000002000000010806000000f4227f8a0000000d49444154780163f8cfc00046000efa02fe076ecf5b0000000049454e44ae426082")


def call(base, method, path, body=None, token=None, headers=None):
    headers = dict(headers or {})
    if token:
        headers["Authorization"] = "Bearer " + token
    if body is not None and not isinstance(body, bytes):
        body = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=body, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as exc:
        response = exc
    with response:
        data = response.read()
        if data and response.headers.get("Content-Type", "").startswith("application/json"):
            data = json.loads(data)
        return response.status, response.headers, data


@pytest.fixture()
def thumbnail_server(tmp_path):
    binary = os.environ.get("ZIGBASE_TEST_THUMBNAILS_BINARY")
    if not binary:
        pytest.skip("requires thumbnails-fixture built with -Dimage-thumbnails=true")
    data = tmp_path / "data"
    shutil.copytree(_su_template_for(binary), data)
    port = _free_port()
    env = {**os.environ, "ZIGBASE_SERVE_BACKGROUND": "false"}
    log = (tmp_path / "server.log").open("w+")
    process = subprocess.Popen([binary, "serve", "--insecure-cookies", "--http-port", str(port), "--data-dir", str(data)], env=env, stdout=log, stderr=log)
    base = f"http://127.0.0.1:{port}"
    try:
        _wait_reachable_or_fail(process, port, tmp_path / "server.log")
        yield base, data
    finally:
        process.terminate()
        process.wait(timeout=10)
        log.close()


def admin(base):
    status, headers, body = call(base, "POST", "/api/collections/_superusers/auth-with-password", {"identity": "admin@x.io", "password": "adminpassword"})
    assert status == 200, body
    return body["token"], headers


def setup(base, view="@public", tenant=False):
    token, _ = admin(base)
    fields = [{"id": "", "name": "image", "type": "file", "options": {"maxSelect": 1}}]
    if tenant:
        fields.append({"id": "", "name": "account", "type": "text"})
    body = {"name": "images", "type": "base", "fields": fields, "viewRule": view}
    if tenant:
        body["options"] = {"tenant": {"field": "account"}}
    status, _, result = call(base, "POST", "/api/collections", body, token)
    assert status == 201, result
    return token


def upload(base, token, content=PNG, filename="source.png", fields=None):
    body, content_type = _multipart(fields or {}, "image", filename, content)
    status, _, record = call(base, "POST", "/api/collections/images/records", body, token, {"Content-Type": content_type})
    assert status == 201, record
    original = f"/api/files/images/{record['id']}/{record['image']}"
    return original, original + "/thumbnail/tiny", record


def control(base, token, mode="reset"):
    status, _, result = call(base, "POST", "/api/thumbnail-test-control", {"mode": mode}, token)
    assert status == 200, result
    return result


def test_representation_head_ranges_and_no_artifacts(thumbnail_server):
    base, data = thumbnail_server
    token = setup(base)
    original, path, _ = upload(base, token)
    before = sorted(str(p.relative_to(data / "storage")) for p in (data / "storage").rglob("*"))
    status, headers, body = call(base, "GET", path)
    assert status == 200 and struct.unpack(">II", body[16:24]) == (1, 1)
    assert headers["Content-Type"] == "image/png"
    assert headers["Cache-Control"] == "private, max-age=0, must-revalidate" and headers["Accept-Ranges"] == "none"
    assert len(headers.get_all("Cache-Control")) == 1
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert headers["Referrer-Policy"] == "no-referrer"
    assert headers["Content-Security-Policy"] == "default-src 'none'; sandbox"
    assert headers["Content-Disposition"] == 'inline; filename="thumbnail.png"'
    assert headers["ETag"].startswith('W/"') and headers.get("Content-Range") is None
    head = call(base, "HEAD", path)
    assert head[0] == 200 and head[2] == b""
    assert head[1]["Content-Length"] == str(len(body))
    conditional = call(base, "GET", path, headers={"Range": "bytes=0-0", "If-None-Match": "*", "If-Range": '"anything"'})
    assert conditional[0] == 304 and conditional[2] == b""
    assert conditional[1]["Content-Type"] == "image/png"
    assert call(base, "GET", path, headers={"Range": "bytes=0-0"})[0] == 200
    assert call(base, "GET", original)[2] == PNG
    assert call(base, "GET", original, headers={"Range": "bytes=0-0"})[0] == 206
    assert call(base, "GET", path.replace("/tiny", "/unknown"))[0] == 404
    assert before == sorted(str(p.relative_to(data / "storage")) for p in (data / "storage").rglob("*"))


def test_auth_cookie_file_token_and_reference_checks(thumbnail_server):
    base, _ = thumbnail_server
    token = setup(base, view="")
    _, path, _ = upload(base, token)
    before = control(base, token)["before"]
    denied = call(base, "GET", path)
    assert denied[0] == 404 and denied[1]["Cache-Control"] == "no-store"
    assert call(base, "HEAD", path)[0] == 404
    assert control(base, token)["before"] == before  # denied requests never run hooks
    assert call(base, "GET", path, token=token)[0] == 200
    _, cookies = admin(base)
    cookie = "; ".join(x.split(";", 1)[0] for x in cookies.get_all("Set-Cookie", []))
    assert cookie
    assert call(base, "GET", path, headers={"Cookie": cookie})[0] == 200
    status, _, result = call(base, "POST", "/api/files/token", {}, token)
    assert status == 200, result
    assert call(base, "GET", path + "?token=" + result["token"])[0] == 200
    assert call(base, "GET", path + "?token=" + token)[0] == 404
    assert call(base, "GET", path.replace("/thumbnail/", "extra/thumbnail/"), token=token)[0] == 404


def test_hook_denial_mutation_and_storage_replacement(thumbnail_server):
    base, _ = thumbnail_server
    token = setup(base)
    _, denied, _ = upload(base, token, filename="deny.png")
    _, mutated, _ = upload(base, token, filename="mutate.png")
    _, replaced, _ = upload(base, token, filename="replace.png")
    assert call(base, "GET", denied)[0] == 404
    assert call(base, "GET", mutated)[0] == 200
    status, _, body = call(base, "GET", replaced)
    assert status == 501 and body["code"] == "not_implemented"
    control(base, token)
    assert call(base, "GET", mutated)[0] == 200


@pytest.mark.parametrize("mode,status,code", [("busy", 503, "thumbnail_busy"), ("input", 413, "payload_too_large"), ("output", 413, "payload_too_large"), ("pixels", 413, "payload_too_large"), ("custom", 501, "not_implemented"), ("missing", 503, "internal")])
def test_budgets_and_capacity_recover(thumbnail_server, mode, status, code):
    base, _ = thumbnail_server
    token = setup(base)
    _, path, _ = upload(base, token)
    control(base, token, mode)
    result, headers, body = call(base, "GET", path)
    assert (result, body["code"]) == (status, code)
    assert headers["Cache-Control"] == "no-store"
    if mode == "busy":
        assert headers["Retry-After"] == "1"
        # Only this test owns an artificial permit; release it explicitly.
        assert control(base, token)["active"] == 1
        assert control(base, token, "release_busy")["active"] == 0
    else:
        # Resetting configuration must not repair a leaked real permit.
        assert control(base, token)["active"] == 0
    assert call(base, "GET", path)[0] == 200
    assert control(base, token)["active"] == 0


def test_malformed_sources_and_no_follow(thumbnail_server):
    base, data = thumbnail_server
    token = setup(base)
    for blob in [b"not a PNG", PNG[:20]]:
        _, path, _ = upload(base, token, content=blob)
        status, _, body = call(base, "GET", path)
        assert status == 422 and body["code"] == "invalid_image"
        assert call(base, "GET", path, headers={"If-None-Match": "*"})[0] == 422
        assert control(base, token)["active"] == 0
    _, path, record = upload(base, token)
    source = data / "storage" / "images" / record["id"] / record["image"]
    assert source.exists()
    source.unlink()
    assert call(base, "GET", path)[0] == 404
    assert control(base, token)["active"] == 0
    source.symlink_to(data / "data.db")
    assert call(base, "GET", path)[0] == 404
    assert control(base, token)["active"] == 0
    source.unlink()
    source.mkdir()
    assert call(base, "GET", path)[0] == 404
    assert control(base, token)["active"] == 0
    source.rmdir()
    os.mkfifo(source)
    assert call(base, "GET", path)[0] == 404
    assert control(base, token)["active"] == 0


def test_tenant_scope_preserved(thumbnail_server):
    base, data = thumbnail_server
    token = setup(base, tenant=True)
    status, _, user = call(base, "POST", "/api/collections/users/records", {"email": "member@example.com", "password": "memberpassword"}, token)
    assert status == 201, user
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("INSERT INTO _accounts(id,created,updated,slug) VALUES('acct-a','t','t','a')")
        conn.execute("INSERT INTO _memberships(id,created,updated,account,user_collection,user,role,status) VALUES('mem-a','t','t','acct-a','users',?,'viewer','active')", (user["id"],))
    status, _, session = call(base, "POST", "/api/collections/users/auth-with-password", {"identity": "member@example.com", "password": "memberpassword"})
    assert status == 200, session
    _, path, _ = upload(base, token, fields={"account": "acct-a"})
    assert call(base, "GET", path)[0] == 404
    assert call(base, "GET", path, token=session["token"], headers={"X-Account-Id": "acct-a"})[0] == 200
    assert call(base, "GET", path, token=session["token"], headers={"X-Account-Id": "acct-b"})[0] == 404


def test_animated_png_is_rejected(thumbnail_server):
    base, _ = thumbnail_server
    token = setup(base)
    def chunk(tag, payload):
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload))
    blob = PNG[:33] + chunk(b"acTL", struct.pack(">II", 2, 0)) + PNG[33:]
    _, path, _ = upload(base, token, content=blob)
    assert call(base, "GET", path)[0] == 422
    assert control(base, token)["active"] == 0


def wait_for_waiters(base, token, count):
    deadline = time.monotonic() + 0.8
    while time.monotonic() < deadline:
        state = control(base, token, "status")
        if state["waiting"] == count:
            return
        time.sleep(0.01)
    pytest.fail(f"expected {count} parked requests; got {state}")


def test_gallery_waits_and_conditional_requests_bypass_capacity(thumbnail_server):
    base, _ = thumbnail_server
    token = setup(base, view="")
    _, path, _ = upload(base, token)
    status, headers, _ = call(base, "GET", path, token=token)
    assert status == 200
    etag = headers["ETag"]
    before = control(base, token, "busy")["before"]
    assert call(base, "GET", path, headers={"If-None-Match": etag})[0] == 404
    cached = call(base, "GET", path, token=token, headers={"If-None-Match": etag})
    assert cached[0] == 304 and cached[2] == b""
    assert cached[1]["Content-Type"] == "image/png"
    assert control(base, token, "status")["before"] == before + 1
    before_unknown = control(base, token, "status")["before"]
    assert call(base, "GET", path.replace("/tiny", "/unknown"), token=token)[0] == 404
    assert control(base, token, "status")["before"] == before_unknown
    # The real server has four HTTP workers; leave capacity for the test-only
    # release endpoint instead of deadlocking our artificial holder.
    with ThreadPoolExecutor(max_workers=2) as executor:
        pending = [executor.submit(call, base, "GET", path, token=token) for _ in range(2)]
        wait_for_waiters(base, token, 2)
        control(base, token, "release_busy")
        assert [request.result()[0] for request in pending] == [200] * 2
    assert control(base, token, "status")["active"] == 0
    control(base, token, "busy")
    control(base, token, "failfast")
    assert call(base, "GET", path, token=token)[0] == 503
    assert control(base, token, "status")["waiting"] == 0
    control(base, token, "release_busy")


def test_full_waiting_queue_refuses_excess_without_losing_parked_request(thumbnail_server):
    base, _ = thumbnail_server
    token = setup(base)
    _, path, _ = upload(base, token)
    control(base, token, "busy")
    control(base, token, "queue_one")
    with ThreadPoolExecutor(max_workers=1) as executor:
        pending = executor.submit(call, base, "GET", path)
        wait_for_waiters(base, token, 1)
        assert call(base, "GET", path)[0] == 503
        assert control(base, token, "status")["waiting"] == 1
        control(base, token, "release_busy")
        assert pending.result()[0] == 200
    assert control(base, token, "status")["active"] == 0


def test_source_replacement_while_waiting_is_not_cached(thumbnail_server):
    base, data = thumbnail_server
    token = setup(base)
    _, path, record = upload(base, token)
    old_etag = call(base, "GET", path)[1]["ETag"]
    source = data / "storage" / "images" / record["id"] / record["image"]
    control(base, token, "busy")
    with ThreadPoolExecutor(max_workers=1) as executor:
        pending = executor.submit(call, base, "GET", path)
        wait_for_waiters(base, token, 1)
        replacement = source.with_suffix(".replacement")
        replacement.write_bytes(PNG)
        replacement.replace(source)
        control(base, token, "release_busy")
        assert pending.result()[0] == 404
    response = call(base, "GET", path, headers={"If-None-Match": old_etag})
    assert response[0] == 200 and response[1]["ETag"] != old_etag


@pytest.mark.parametrize("fmt,magic", [("jpeg", b"\xff\xd8\xff"), ("webp", b"RIFF")])
def test_real_input_and_output_formats_and_cover(thumbnail_server, fmt, magic):
    base, _ = thumbnail_server
    token = setup(base)
    converted = subprocess.run(["/usr/bin/convert", "png:-", fmt + ":-"], input=PNG, capture_output=True, check=True).stdout
    _, path, _ = upload(base, token, content=converted, filename="source." + fmt)
    response = call(base, "GET", path.replace("/tiny", "/" + fmt))
    assert response[0] == 200 and response[2].startswith(magic)
    assert response[1]["Content-Type"] == "image/" + fmt
    covered = call(base, "GET", path.replace("/tiny", "/cover"))
    assert covered[0] == 200 and struct.unpack(">II", covered[2][16:24]) == (16, 16)


def test_missing_backend_only_blocks_serving_not_offline_schema_apply(tmp_path):
    binary = os.environ.get("ZIGBASE_TEST_THUMBNAILS_BINARY")
    if not binary:
        pytest.skip("requires thumbnails fixture")
    data = tmp_path / "offline"
    schema = tmp_path / "schema.json"
    schema.write_text(json.dumps({"zigbaseSchema": 1, "collections": []}))
    env = {**os.environ, "ZIGBASE_IMAGEMAGICK_EXECUTABLE": str(tmp_path / "missing-convert")}
    applied = subprocess.run([binary, "schema", "apply", str(schema), "--data-dir", str(data)], env=env, capture_output=True, text=True, timeout=20)
    assert applied.returncode == 0, applied.stdout + applied.stderr
    assert (data / "data.db").exists()
    served = subprocess.run([binary, "serve", "--http-port", str(_free_port()), "--data-dir", str(data)], env=env, capture_output=True, text=True, timeout=20)
    assert served.returncode != 0 and "ImageExecutableUnavailable" in served.stderr
    env["ZIGBASE_IMAGEMAGICK_EXECUTABLE"] = "convert"
    invalid = subprocess.run([binary, "serve", "--data-dir", str(data)], env=env, capture_output=True, text=True, timeout=20)
    assert invalid.returncode != 0 and "ZIGBASE_IMAGEMAGICK_EXECUTABLE" in invalid.stderr
