"""End-to-end tests for the public one-click unsubscribe endpoint (#154 round 2, RFC 8058).

`POST /api/mail/unsubscribe?t=<token>` is UNAUTHENTICATED (the signed token is the
authorization) and must:
  - 204 on a valid token, suppressing the recipient for LIST mail (not transactional),
    idempotently (repeat POST -> 204, one row);
  - 400, byte-identically, for any invalid token (empty/garbage/wrong-secret) — no
    oracle distinguishing failure reasons;
  - never mutate on GET (prefetch-safe confirmation page).

This exercises the real route table + env-config path (`ZIGBASE_UNSUBSCRIBE_BASE_URL`,
Task 6) and the records-API read of `_suppressions`/`_mail_batches`/`_mail_batch_recipients`
as Locked system collections (superuser-only) — what the Zig integration tests (Task
3/6/7, which cover the full sendBulk -> pollOnce -> CaptureMailer + suppression path)
cannot prove: live HTTP semantics and superuser-vs-anonymous authz through the records API.
"""

import base64
import hashlib
import hmac
import json
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time

import pytest
import urllib.error
import urllib.request

from _bin import resolve_binary

REPO = pathlib.Path(__file__).resolve().parents[2]
JWT_SECRET = "e2e-unsub-secret-0123456789abcdef"


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _http(method, url, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def mint_token(secret: str, account: str, list_name: str, recipient: str) -> str:
    # Mirrors src/mail/unsubscribe.zig: key = HMAC-SHA256(jwt_secret, label);
    # payload = "v1\0account\0list\0recipient"; token = b64url(payload).b64url(mac).
    key = hmac.new(secret.encode(), b"zigbase.mail.unsub.v1", hashlib.sha256).digest()
    payload = b"v1\x00" + account.encode() + b"\x00" + list_name.encode() + b"\x00" + recipient.encode()
    mac = hmac.new(key, payload, hashlib.sha256).digest()
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    return f"{b64(payload)}.{b64(mac)}"


@pytest.fixture(scope="module")
def unsub_server():
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    data = tempfile.mkdtemp(prefix="zb_unsub_")
    env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_JWT_SECRET": JWT_SECRET}
    subprocess.run([binary, "superuser", "create", "--email", "admin@x.io",
                    "--password", "adminpassword", "--data-dir", data], check=True, env=env)
    port = _free_port()
    env["ZIGBASE_HTTP_PORT"] = str(port)
    env["ZIGBASE_UNSUBSCRIBE_BASE_URL"] = f"http://127.0.0.1:{port}"
    proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            time.sleep(0.1)
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        shutil.rmtree(data, ignore_errors=True)


def _su_token(base):
    status, body = _http("POST", f"{base}/api/collections/_superusers/auth-with-password",
                          body={"identity": "admin@x.io", "password": "adminpassword"})
    assert status == 200, body
    return json.loads(body)["token"]


def test_one_click_post_writes_unsubscribe_suppression(unsub_server):
    t = mint_token(JWT_SECRET, "", "newsletter", "reader@example.com")
    status, body = _http("POST", f"{unsub_server}/api/mail/unsubscribe?t={t}")
    assert status == 204, body
    # Repeat POST: still 204 (idempotent, no already-existed oracle).
    status, _ = _http("POST", f"{unsub_server}/api/mail/unsubscribe?t={t}")
    assert status == 204
    # Verify through the superuser records API — _suppressions is a Locked system
    # collection (this ALSO proves the 0019 `updated` retrofit: the base-column
    # SELECT no longer errors).
    su = _su_token(unsub_server)
    status, body = _http("GET", f"{unsub_server}/api/collections/_suppressions/records", token=su)
    assert status == 200, body
    items = json.loads(body)["items"]
    rows = [r for r in items if r["email"] == "reader@example.com"]
    assert len(rows) == 1
    assert rows[0]["reason"] == "unsubscribe"
    assert rows[0]["source"] == "one_click:newsletter"


def test_get_renders_confirmation_without_mutating(unsub_server):
    t = mint_token(JWT_SECRET, "", "digest", "getonly@example.com")
    status, body = _http("GET", f"{unsub_server}/api/mail/unsubscribe?t={t}")
    assert status == 200
    assert 'method="post"' in body  # a prefetcher following the link changes nothing
    su = _su_token(unsub_server)
    _, body = _http("GET", f"{unsub_server}/api/collections/_suppressions/records", token=su)
    assert all(r["email"] != "getonly@example.com" for r in json.loads(body)["items"])


def test_invalid_token_is_generic_400(unsub_server):
    for bad in ["", "garbage", "a.b", mint_token("wrong-secret", "", "l", "x@y.io")]:
        status, body = _http("POST", f"{unsub_server}/api/mail/unsubscribe?t={bad}")
        assert status == 400, (bad, status, body)


def test_bulk_report_collections_exist_and_are_locked(unsub_server):
    su = _su_token(unsub_server)
    # Superuser can list the (empty) send-report collections; anonymous cannot (Locked
    # -> 403, same as any other Locked collection, see api/records.zig's `forbidden`).
    for col in ("_mail_batches", "_mail_batch_recipients"):
        status, body = _http("GET", f"{unsub_server}/api/collections/{col}/records", token=su)
        assert status == 200, (col, body)
        assert json.loads(body)["items"] == []
        status, _ = _http("GET", f"{unsub_server}/api/collections/{col}/records")
        assert status == 403
