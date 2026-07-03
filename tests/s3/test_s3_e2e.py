"""S3-backed storage e2e (§D) — runs ONLY against a real S3-compatible server
(MinIO, started as a service container by CI's `s3` job; see .github/workflows/ci.yml).
Not mocked: this is the raw-HTTP proof that a `-Ds3` binary configured via
`ZIGBASE_S3_*` env serves record files byte-identically to local storage (§B —
Range/ETag/conditional/tenancy), backed by a real bucket.

Skips cleanly (module-level) when ZIGBASE_S3_TEST_ENDPOINT is unset, so the file
is inert everywhere except the `s3` CI job.
"""
import io, json, os, pathlib, shutil, socket, subprocess, tempfile, time, urllib.error, urllib.request, uuid

import pytest
from _bin import resolve_binary

REPO = pathlib.Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.skipif(
    not os.environ.get("ZIGBASE_S3_TEST_ENDPOINT"),
    reason="ZIGBASE_S3_TEST_ENDPOINT not set (MinIO CI job only)")


def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def _wait_up(url, deadline_s=20):
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                return r
        except urllib.error.HTTPError:
            return None  # server is up, request just 4xx'd
        except Exception:
            time.sleep(0.2)
    raise AssertionError("server did not come up")


def _get(url, headers=None):
    """Return (status, headers_msg, body); headers_msg is HTTPMessage (case-insensitive .get())."""
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def _hdr(msg, name):
    """Case-insensitive header access; returns first matching value or ''."""
    return msg.get(name, "")


def _post_json(url, obj, token=None, method="POST"):
    data = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method=method)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status, json.loads(r.read() or b"{}")


def _multipart(fields, file_field, filename, blob):
    b = uuid.uuid4().hex
    out = io.BytesIO()
    for k, v in fields.items():
        out.write(f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    out.write(f"--{b}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{filename}\"\r\n"
              f"Content-Type: application/octet-stream\r\n\r\n".encode())
    out.write(blob)
    out.write(f"\r\n--{b}--\r\n".encode())
    return out.getvalue(), f"multipart/form-data; boundary={b}"


def _s3_env(**overrides):
    """The ZIGBASE_S3_* config env, mapped from the ZIGBASE_S3_TEST_* values CI (or a
    local MinIO) provides. `overrides` replaces individual keys (e.g. a bad secret)."""
    env = {
        "ZIGBASE_S3_ENDPOINT": os.environ["ZIGBASE_S3_TEST_ENDPOINT"],
        "ZIGBASE_S3_BUCKET": os.environ.get("ZIGBASE_S3_TEST_BUCKET", "zbtest"),
        "ZIGBASE_S3_REGION": os.environ.get("ZIGBASE_S3_TEST_REGION", "us-east-1"),
        "ZIGBASE_S3_ACCESS_KEY_ID": os.environ.get("ZIGBASE_S3_TEST_KEY", "minioadmin"),
        "ZIGBASE_S3_SECRET_ACCESS_KEY": os.environ.get("ZIGBASE_S3_TEST_SECRET", "minioadmin"),
    }
    env.update(overrides)
    return env


@pytest.fixture()
def s3_server():
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    data = tempfile.mkdtemp(prefix="zb_s3_")
    subprocess.run([str(binary), "superuser", "create", "--email", "admin@x.io",
                    "--password", "adminpassword", "--data-dir", data], check=True)
    port = _free_port()
    env = {**os.environ, **_s3_env(), "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"}
    proc = subprocess.Popen(
        [str(binary), "serve", "--insecure-cookies", "--http-port", str(port), "--data-dir", data],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{port}"
    _wait_up(f"{base}/api/health")
    try:
        yield base
    finally:
        proc.terminate(); proc.wait(timeout=5); shutil.rmtree(data, ignore_errors=True)


def _setup_record(base, blob, view_rule="@public"):
    _, auth = _post_json(f"{base}/api/collections/_superusers/auth-with-password",
                         {"identity": "admin@x.io", "password": "adminpassword"})
    token = auth["token"]
    _post_json(f"{base}/api/collections",
               {"name": "media", "type": "base", "viewRule": view_rule,
                "fields": [{"id": "", "name": "clip", "type": "file", "options": {"maxSelect": 1}}]},
               token=token)
    body, ctype = _multipart({}, "clip", "video.mp4", blob)
    req = urllib.request.Request(f"{base}/api/collections/media/records", data=body,
                                 headers={"Content-Type": ctype, "Authorization": f"Bearer {token}"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        rec = json.loads(r.read())
    return token, rec["id"], rec["clip"]  # stored name (suffixed)


def test_s3_file_lifecycle(s3_server):
    """Upload -> full GET matches the blob -> Range 206 -> If-None-Match 304 ->
    out-of-range 416 -> delete the record -> GET 404. Byte-identical §B behavior
    over the S3 spool cache — the whole point of §D.6."""
    base = s3_server
    blob = bytes(range(256)) * 4  # 1024 recognizable bytes
    token, rid, stored = _setup_record(base, blob)
    url = f"{base}/api/files/media/{rid}/{stored}"

    st, hdr, body = _get(url)
    assert st == 200 and body == blob
    etag = _hdr(hdr, "ETag")
    assert etag.startswith('"') and etag.endswith('"')

    st, hdr, body = _get(url, {"Range": "bytes=100-199"})
    assert st == 206 and body == blob[100:200]
    assert _hdr(hdr, "Content-Range") == f"bytes 100-199/{len(blob)}"

    st, hdr, _ = _get(url, {"If-None-Match": etag})
    assert st == 304 and _hdr(hdr, "ETag") == etag

    st, hdr, _ = _get(url, {"Range": f"bytes={len(blob)}-"})
    assert st == 416 and _hdr(hdr, "Content-Range") == f"bytes */{len(blob)}"

    # Delete the record -> the storage backend deletes the S3 object; a subsequent
    # GET is a plain 404 (not a stale spool hit).
    req = urllib.request.Request(f"{base}/api/collections/media/records/{rid}", method="DELETE")
    req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=5) as r:
        assert r.status == 204

    st, _, _ = _get(url)
    assert st == 404


def test_s3_bad_credentials_refuses_to_start():
    """§D.7 fail-fast: a bad secret makes the startup HeadObject probe come back
    403 (SignatureDoesNotMatch) -> S3Storage.create refuses to start."""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    data = tempfile.mkdtemp(prefix="zb_s3_bad_")
    try:
        port = _free_port()
        env = {**os.environ, **_s3_env(ZIGBASE_S3_SECRET_ACCESS_KEY="wrong-secret"),
               "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"}
        proc = subprocess.Popen(
            [str(binary), "serve", "--insecure-cookies", "--http-port", str(port), "--data-dir", data],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        _, stderr = proc.communicate(timeout=30)
        assert proc.returncode != 0
        assert b"refusing to start" in stderr
    finally:
        shutil.rmtree(data, ignore_errors=True)
