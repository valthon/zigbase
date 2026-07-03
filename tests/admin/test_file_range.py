import io, json, socket, subprocess, tempfile, time, os, pathlib, shutil, urllib.request, urllib.error, uuid

import pytest
from _bin import resolve_binary

REPO = pathlib.Path(__file__).resolve().parents[2]


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


def _post_json(url, obj, token=None):
    data = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
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


@pytest.fixture()
def file_server():
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    data = tempfile.mkdtemp(prefix="zb_files_")
    subprocess.run([str(binary), "superuser", "create", "--email", "admin@x.io",
                    "--password", "adminpassword", "--data-dir", data], check=True)
    port = _free_port()
    proc = subprocess.Popen(
        [str(binary), "serve", "--insecure-cookies", "--http-port", str(port), "--data-dir", data],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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


def test_record_file_range_matrix(file_server):
    """206 for bytes=a-b / bytes=X- / bytes=-n, Accept-Ranges, EXACTLY ONE Cache-Control,
    quoted ETag -> 304, If-Range, 416, HEAD parity — the §B wire pin."""
    blob = bytes(range(256)) * 4  # 1024 recognizable bytes
    base = file_server
    _, rid, stored = _setup_record(base, blob)
    url = f"{base}/api/files/media/{rid}/{stored}"

    st, hdr, body = _get(url)
    assert st == 200 and body == blob
    # exactly one Cache-Control on the wire (the duplicate-header regression pin)
    assert len(hdr.get_all("Cache-Control") or []) == 1
    assert _hdr(hdr, "Accept-Ranges") == "bytes"
    etag = _hdr(hdr, "ETag")
    assert etag.startswith('"') and etag.endswith('"')

    st, hdr, body = _get(url, {"Range": "bytes=100-199"})
    assert st == 206 and body == blob[100:200]
    assert _hdr(hdr, "Content-Range") == f"bytes 100-199/{len(blob)}"

    st, _, body = _get(url, {"Range": "bytes=1000-"})  # open-ended video-seek form
    assert st == 206 and body == blob[1000:]
    st, _, body = _get(url, {"Range": "bytes=-24"})  # suffix form
    assert st == 206 and body == blob[-24:]

    st, hdr, _ = _get(url, {"If-None-Match": etag})
    assert st == 304 and _hdr(hdr, "ETag") == etag

    st, _, body = _get(url, {"Range": "bytes=0-9", "If-Range": etag})
    assert st == 206 and body == blob[:10]
    st, _, body = _get(url, {"Range": "bytes=0-9", "If-Range": '"stale"'})
    assert st == 200 and body == blob  # mismatched validator ignores the Range

    st, hdr, _ = _get(url, {"Range": f"bytes={len(blob)}-"})
    assert st == 416 and _hdr(hdr, "Content-Range") == f"bytes */{len(blob)}"

    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req, timeout=5) as r:
        assert r.status == 200
        assert r.headers.get("Content-Length") == str(len(blob))
        assert len(r.read()) == 0


def test_locked_collection_file_stays_private_single_header(file_server):
    """A non-public collection's file: superuser-token GET serves with Cache-Control:
    private (tenancy/cacheability invariant is requester-independent), exactly once."""
    base = file_server
    token, rid, stored = _setup_record(base, b"secret-bytes", view_rule="")
    url = f"{base}/api/files/media/{rid}/{stored}"
    st, _, _ = _get(url)
    assert st == 404  # blank rule = Locked; anonymous never sees it
    st, hdr, body = _get(url, {"Authorization": f"Bearer {token}"})
    assert st == 200 and body == b"secret-bytes"
    ccs = hdr.get_all("Cache-Control") or []
    assert ccs == ["private"]
