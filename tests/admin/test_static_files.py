import socket, subprocess, tempfile, time, os, pathlib, shutil, urllib.request, urllib.error

import pytest
from _bin import resolve_binary, resolve_plugins_binary

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
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>hello static</h1>")
        (pub / "assets").mkdir()
        (pub / "assets" / "app.js").write_text("console.log('hi')")
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
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
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as data:
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", "/nonexistent/static/dir"],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        assert proc.wait(timeout=20) != 0


def test_embedded_static_in_plugins_example():
    binary = resolve_plugins_binary()
    if binary is None:
        pytest.skip("npm not available and no prebuilt plugins binary; cannot build the plugins frontend")
    with tempfile.TemporaryDirectory() as data:
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data],
            # authors.private_notes is an .encrypted field -> serve requires ZIGBASE_FIELD_KEY.
            env={
                **os.environ,
                "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef",
                "ZIGBASE_FIELD_KEY": "plugins-static-test-field-key",
            },
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


def test_spa_marker_fallback():
    """Issue #183 AC1 + AC4: 'Shipped binary, public/app/.spa present: hard GET
    /app/orders/1234 -> public/app/index.html (200); /app/assets/app.js and other real
    files serve directly; / and other paths outside /app/ are unaffected.' And: 'The
    marker never rewrites a request that an API route handles.'"""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>site home</h1>")
        (pub / "app").mkdir()
        (pub / "app" / "index.html").write_text("<h1>app shell</h1>")
        (pub / "app" / ".spa").write_text("MARKER-SECRET")  # contents are ignored (presence-only)
        (pub / "app" / "assets").mkdir()
        (pub / "app" / "assets" / "app.js").write_text("console.log('real asset')")
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")

            # AC1: deep link under the marked dir -> the app shell, 200 text/html
            st, hdr, body = _get(f"{base}/app/orders/1234")
            assert st == 200 and b"app shell" in body
            assert "text/html" in _hdr(hdr, "content-type")

            # AC1: real files under the marked dir serve directly
            st, _, body = _get(f"{base}/app/assets/app.js")
            assert st == 200 and b"real asset" in body

            # an extension-bearing MISS under the root still gets the shell (200 HTML)
            st, hdr, body = _get(f"{base}/app/assets/gone.js")
            assert st == 200 and b"app shell" in body

            # AC1: / serves the real root index; misses OUTSIDE /app/ still 404
            st, _, body = _get(f"{base}/")
            assert st == 200 and b"site home" in body
            st, hdr, _ = _get(f"{base}/pricing")
            assert st == 404
            assert "application/json" not in _hdr(hdr, "content-type")
            # '/'-bounded: /application is outside the app/ subtree
            st, _, _ = _get(f"{base}/application")
            assert st == 404

            # the marker file itself is never served (falls through to the shell)
            st, _, body = _get(f"{base}/app/.spa")
            assert b"MARKER-SECRET" not in body
            assert st == 200 and b"app shell" in body

            # AC4: unknown /api paths keep the JSON 404 envelope
            st, hdr, _ = _get(f"{base}/api/definitely-missing")
            assert st == 404
            assert "application/json" in _hdr(hdr, "content-type")
        finally:
            proc.terminate(); proc.wait(timeout=10)


def test_spa_marker_live_dir_mode_no_restart():
    """Owner revision (2026-07-02): in dir mode the marker is resolved LIVE against the
    filesystem on every miss, not scanned once at startup — dropping a NEW '.spa' (+
    index.html) into the served tree after the server is already running must start
    serving the shell on the very next request, with no restart."""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>site home</h1>")
        (pub / "app").mkdir()
        (pub / "app" / "index.html").write_text("<h1>app shell</h1>")
        # deliberately NO app/.spa yet — the marker is added after boot, below
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")

            # before the marker exists: a miss under app/ is a plain 404, not the shell
            st, hdr, _ = _get(f"{base}/app/orders/1234")
            assert st == 404
            assert "application/json" not in _hdr(hdr, "content-type")

            # simulate a post-boot deploy: drop the marker WITHOUT restarting the server
            (pub / "app" / ".spa").write_text("")

            # the very next request picks it up live
            st, hdr, body = _get(f"{base}/app/orders/1234")
            assert st == 200 and b"app shell" in body
            assert "text/html" in _hdr(hdr, "content-type")

            # removing the marker again (still live, still no restart) stops the fallback
            (pub / "app" / ".spa").unlink()
            st, _, _ = _get(f"{base}/app/orders/5678")
            assert st == 404
        finally:
            proc.terminate(); proc.wait(timeout=10)


def test_spa_marker_missing_index_is_fatal_at_startup():
    """Owner revision (2026-07-02): a '.spa'-marked directory with no index.html is a
    FATAL startup error (changed from warn-and-drop) — the process must exit non-zero
    with a clear, actionable message naming the offending path."""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>site home</h1>")
        (pub / "broken").mkdir()
        (pub / "broken" / ".spa").write_text("")  # no broken/index.html
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        try:
            code = proc.wait(timeout=20)
            out = proc.stdout.read().decode("utf-8", errors="replace")
            assert code != 0, f"expected a non-zero exit; stdout/stderr was:\n{out}"
            assert "broken" in out, f"expected the offending path 'broken' named in the error; got:\n{out}"
            assert "index.html" in out, f"expected the error to mention the missing index.html; got:\n{out}"
        finally:
            if proc.poll() is None:
                proc.terminate(); proc.wait(timeout=10)


def test_spa_marker_root():
    """Issue #183 AC2 + AC4: 'public/.spa present: any miss under / -> /index.html
    (200); real files still win.' API misses keep the JSON envelope."""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>spa root shell</h1>")
        (pub / ".spa").write_text("")
        (pub / "assets").mkdir()
        (pub / "assets" / "app.js").write_text("console.log('root asset')")
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")

            # AC2: any miss -> the root shell (200)
            st, hdr, body = _get(f"{base}/some/deep/client/route")
            assert st == 200 and b"spa root shell" in body
            assert "text/html" in _hdr(hdr, "content-type")

            # AC2: real files still win
            st, _, body = _get(f"{base}/assets/app.js")
            assert st == 200 and b"root asset" in body

            # AC4: the root marker must NOT swallow the API namespace
            st, hdr, _ = _get(f"{base}/api/definitely-missing")
            assert st == 404
            assert "application/json" in _hdr(hdr, "content-type")
            st, hdr, _ = _get(f"{base}/api")
            assert st == 404
            assert "application/json" in _hdr(hdr, "content-type")

            # the admin SPA still wins over the root marker
            st, hdr, _ = _get(f"{base}/_/")
            assert st == 200 and "text/html" in _hdr(hdr, "content-type")
        finally:
            proc.terminate(); proc.wait(timeout=10)


def test_dir_static_range_seek_forms():
    """§A.2 pin: bytes=X- and bytes=-n now produce correct 206 BYTES through
    facil.io (the shim rewrites the request header; facil.io assembles the 206)."""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        blob = bytes(range(256)) * 4  # 1024 recognizable bytes
        (pathlib.Path(static) / "clip.bin").write_bytes(blob)
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")
            url = f"{base}/clip.bin"

            st, hdr, body = _get(url, {"Range": "bytes=200-"})  # open-ended seek
            assert st == 206 and body == blob[200:]
            assert _hdr(hdr, "Content-Range") == "bytes 200-1023/1024"
            st, _, body = _get(url, {"Range": "bytes=-100"})  # suffix
            assert st == 206 and body == blob[-100:]
            st, _, body = _get(url, {"Range": "bytes=100-199"})  # already canonical
            assert st == 206 and body == blob[100:200]
            st, hdr, _ = _get(url, {"Range": "bytes=5000-"})  # owned 416
            assert st == 416 and _hdr(hdr, "Content-Range") == "bytes */1024"
            st, hdr, body = _get(url)  # plain 200: Vary present, single stock Cache-Control
            assert st == 200 and body == blob
            assert _hdr(hdr, "Vary") == "Accept-Encoding"
            assert (hdr.get_all("Cache-Control") or []) == ["max-age=3600"]
        finally:
            proc.terminate(); proc.wait(timeout=5)


def test_static_cache_control_knob_flag_env_and_default():
    """§C.2 pin: --static-cache-control / ZIGBASE_STATIC_CACHE_CONTROL / their
    precedence (flag > env > the stock facil.io default), single header on the wire."""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")

    def _spin(extra_args, extra_env):
        static_dir = tempfile.mkdtemp()
        data_dir = tempfile.mkdtemp()
        try:
            (pathlib.Path(static_dir) / "asset.txt").write_text("hello knob")
            port = _free_port()
            proc = subprocess.Popen(
                [str(binary), "serve", "--http-port", str(port), "--data-dir", data_dir,
                 "--serve-static", static_dir, *extra_args],
                env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef", **extra_env},
            )
            try:
                base = f"http://127.0.0.1:{port}"
                _wait_up(f"{base}/api/health")
                st, hdr, body = _get(f"{base}/asset.txt")
                assert st == 200 and body == b"hello knob"
                return hdr.get_all("Cache-Control") or []
            finally:
                proc.terminate(); proc.wait(timeout=10)
        finally:
            shutil.rmtree(static_dir, ignore_errors=True)
            shutil.rmtree(data_dir, ignore_errors=True)

    # server A: no knob -> stock facil.io default, single header
    assert _spin([], {}) == ["max-age=3600"]
    # server B: --static-cache-control -> exact value, single header
    assert _spin(["--static-cache-control", "public, max-age=86400, immutable"], {}) == \
        ["public, max-age=86400, immutable"]
    # server C: env only (no flag) -> env value on the wire
    assert _spin([], {"ZIGBASE_STATIC_CACHE_CONTROL": "public, max-age=120"}) == \
        ["public, max-age=120"]
    # server D: both -> the FLAG value wins
    assert _spin(
        ["--static-cache-control", "public, max-age=999"],
        {"ZIGBASE_STATIC_CACHE_CONTROL": "public, max-age=1"},
    ) == ["public, max-age=999"]


def test_embedded_static_emits_cache_control_and_range():
    """§C.2/§B embedded pin: plugins example binary (embedded frontend) — GET an
    embedded asset emits Cache-Control (max-age=3600 default) + Accept-Ranges: bytes;
    Range: bytes=0-9 answers 206 with the first 10 bytes; the CRC32 ETag format
    (quoted 8-hex) is unchanged."""
    binary = resolve_plugins_binary()
    if binary is None:
        pytest.skip("npm not available and no prebuilt plugins binary; cannot build the plugins frontend")
    with tempfile.TemporaryDirectory() as data:
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data],
            env={
                **os.environ,
                "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef",
                "ZIGBASE_FIELD_KEY": "plugins-static-test-field-key",
            },
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")

            st, hdr, body = _get(f"{base}/")
            assert st == 200
            assert (hdr.get_all("Cache-Control") or []) == ["max-age=3600"]
            assert _hdr(hdr, "Accept-Ranges") == "bytes"
            etag = _hdr(hdr, "ETag")
            assert etag and etag.startswith('"') and etag.endswith('"')
            assert len(etag) == 10  # `"` + 8 hex + `"`

            st, hdr, part = _get(f"{base}/", {"Range": "bytes=0-9"})
            assert st == 206 and part == body[:10]
            assert _hdr(hdr, "Content-Range") == f"bytes 0-9/{len(body)}"

            st, _, _ = _get(f"{base}/", {"If-None-Match": etag})
            assert st == 304
        finally:
            proc.terminate(); proc.wait(timeout=10)


def test_spa_fallback_shell_no_cache_and_etag():
    """§C.3 pin: dir server with a '.spa' marker — a deep-link miss gets the shell
    with Cache-Control: no-cache + a quoted revalidation ETag (304 on repeat); a
    direct hit on the shell itself (real file, not the fallback) is NOT no-cache."""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>spa root shell</h1>")
        (pub / ".spa").write_text("")
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")

            st, hdr, body = _get(f"{base}/some/deep/client/route")
            assert st == 200 and b"spa root shell" in body
            assert _hdr(hdr, "Cache-Control") == "no-cache"
            etag = _hdr(hdr, "ETag")
            assert etag and etag.startswith('"') and etag.endswith('"')

            st, _, _ = _get(f"{base}/some/deep/client/route", {"If-None-Match": etag})
            assert st == 304

            # direct hit on the real file: delegated facil.io path, NOT no-cache
            st, hdr, _ = _get(f"{base}/index.html")
            assert st == 200
            assert _hdr(hdr, "Cache-Control") != "no-cache"
        finally:
            proc.terminate(); proc.wait(timeout=10)


def test_gz_sidecar_still_served_with_vary():
    """§A.3 pin: a '<file>.gz' sidecar next to '<file>' is still served verbatim by
    facil.io on Accept-Encoding: gzip (Content-Encoding: gzip unchanged), and now
    also carries Vary: Accept-Encoding (shared-cache correctness, added by the
    Range-normalization shim's size probe)."""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "big.txt").write_text("plain " * 100)
        (pub / "big.txt.gz").write_bytes(b"\x1f\x8b" + b"z" * 50)  # sidecar bytes, content irrelevant
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")
            url = f"{base}/big.txt"

            st, hdr, body = _get(url, {"Accept-Encoding": "gzip"})
            assert st == 200
            assert _hdr(hdr, "Content-Encoding") == "gzip"
            assert _hdr(hdr, "Vary") == "Accept-Encoding"
            assert body == b"\x1f\x8b" + b"z" * 50

            # no Accept-Encoding: the base file, no Content-Encoding
            st, hdr, body = _get(url)
            assert st == 200
            assert _hdr(hdr, "Content-Encoding") == ""
            assert body == (b"plain " * 100)
        finally:
            proc.terminate(); proc.wait(timeout=10)
