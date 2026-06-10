import socket, subprocess, tempfile, time, os, pathlib, shutil, urllib.request, urllib.error

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]


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


def test_serve_static_runtime_mode():
    subprocess.run(ZIG + ["build"], cwd=REPO, check=True)
    binary = REPO / "zig-out" / "bin" / "zigbase"
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>hello static</h1>")
        (pub / "assets").mkdir()
        (pub / "assets" / "app.js").write_text("console.log('hi')")
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")

            # index.html at /
            st, hdr, body = _get(f"{base}/")
            assert st == 200 and b"hello static" in body
            assert "text/html" in _hdr(hdr, "content-type")

            # asset with content type + ETag, then 304
            st, hdr, body = _get(f"{base}/assets/app.js")
            assert st == 200 and b"console.log" in body
            # dir mode delegates caching to facil.io's sendFile: one (unquoted,
            # base64) etag header, If-None-Match/304 answered by the transport
            etag_values = hdr.get_all("etag") or []
            assert len(etag_values) == 1, f"expected exactly one etag header, got: {etag_values}"
            etag = etag_values[0]
            st, _, _ = _get(f"{base}/assets/app.js", {"If-None-Match": etag})
            assert st == 304

            # static miss -> plain 404 (not the JSON envelope)
            st, hdr, _ = _get(f"{base}/missing.css")
            assert st == 404
            assert "application/json" not in _hdr(hdr, "content-type")

            # /api/ miss keeps the JSON envelope
            st, hdr, body = _get(f"{base}/api/definitely-missing")
            assert st == 404
            assert "application/json" in _hdr(hdr, "content-type")

            # bare /api (no trailing slash) also stays in the API namespace
            st, hdr, _ = _get(f"{base}/api")
            assert st == 404
            assert "application/json" in _hdr(hdr, "content-type")

            # traversal blocked
            st, _, _ = _get(f"{base}/..%2f..%2fetc%2fpasswd")
            assert st in (400, 404)

            # admin UI still wins over static
            st, hdr, _ = _get(f"{base}/_/")
            assert st == 200 and "text/html" in _hdr(hdr, "content-type")
        finally:
            proc.terminate(); proc.wait(timeout=10)


def test_serve_static_missing_dir_is_fatal():
    subprocess.run(ZIG + ["build"], cwd=REPO, check=True)
    binary = REPO / "zig-out" / "bin" / "zigbase"
    with tempfile.TemporaryDirectory() as data:
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", "/nonexistent/static/dir"],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default"},
        )
        assert proc.wait(timeout=20) != 0


def test_embedded_static_in_plugins_example():
    if shutil.which("npm") is None:
        pytest.skip("npm not available; cannot build the plugins frontend")
    plugins = REPO / "examples" / "plugins"
    fe = plugins / "frontend"
    if not (fe / "dist" / "index.html").exists():
        subprocess.run(["npm", "install", "--no-audit", "--no-fund"], cwd=fe, check=True)
        subprocess.run(["npm", "run", "build"], cwd=fe, check=True)
    subprocess.run(ZIG + ["build"], cwd=plugins, check=True)
    binary = plugins / "zig-out" / "bin" / "plugins"
    with tempfile.TemporaryDirectory() as data:
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")
            st, hdr, body = _get(f"{base}/")
            assert st == 200 and b"one binary" in body.lower()
            assert "text/html" in _hdr(hdr, "Content-Type")
            etag = _hdr(hdr, "ETag")
            assert etag and etag.startswith('"')
            st, _, _ = _get(f"{base}/", {"If-None-Match": etag})
            assert st == 304
        finally:
            proc.terminate(); proc.wait(timeout=10)
