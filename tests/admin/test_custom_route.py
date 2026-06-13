import json, socket, subprocess, time, urllib.request, os, signal, tempfile, pathlib

REPO = pathlib.Path(__file__).resolve().parents[2]
BLOG = REPO / "examples" / "blog"

def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def test_custom_public_route_responds():
    # Build the example consumer against the working-tree zigbase module.
    subprocess.run(["mise", "exec", "zig@0.16.0", "--", "zig", "build"], cwd=BLOG, check=True)
    blog = BLOG / "zig-out" / "bin" / "blog"
    assert blog.exists()
    with tempfile.TemporaryDirectory() as data:
        port = _free_port()
        proc = subprocess.Popen(
            [str(blog), "serve", "--http-port", str(port), "--data-dir", data],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        try:
            url = f"http://127.0.0.1:{port}/api/blog/ping"
            deadline = time.time() + 20
            status, body = None, None
            while time.time() < deadline:
                try:
                    with urllib.request.urlopen(url, timeout=1) as r:
                        status = r.status; body = r.read().decode(); break
                except Exception:
                    time.sleep(0.2)
            assert body is not None, "server did not come up / route did not respond"
            assert status == 200, f"status={status} body={body}"
            assert json.loads(body) == {"pong": True}, f"unexpected body: {body}"
        finally:
            try: proc.send_signal(signal.SIGINT)
            except Exception: pass
            try: proc.terminate()
            except Exception: pass
            proc.wait(timeout=10)
