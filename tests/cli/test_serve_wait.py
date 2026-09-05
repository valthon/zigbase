"""Readiness must be bounded even when the advertised HTTP listener stalls."""
import fcntl
import json
import pathlib
import socket
import subprocess
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from conftest import clean_env, free_port, run


def test_wait_observes_foreground_startup(binary, data_dir):
    proc = subprocess.Popen(
        [binary, "serve", "--insecure-cookies", "--data-dir", data_dir,
         "--http-port", str(free_port())], env=clean_env({"ZIGBASE_SERVE_BACKGROUND": "0"}),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        result = run(binary, "serve", "wait", "--json", "--timeout-ms", "10000", "--data-dir", data_dir)
        assert result.returncode == 0, result.stderr
        state = json.loads(result.stdout)
        assert state["pid"] == proc.pid
        assert state["ready"] and state["running"] and state["healthy"]
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def test_wait_times_out_without_starting_a_session(binary, data_dir):
    result = run(binary, "serve", "wait", "--json", "--timeout-ms", "100", "--data-dir", data_dir, timeout=3)
    assert result.returncode == 1
    assert json.loads(result.stdout) == {"ready": False, "reason": "timeout"}
    assert not (pathlib.Path(data_dir) / "serve.json").exists()


def test_wait_deadline_includes_stalled_http_probe(binary, tmp_path):
    # Hold the same session lock as a real process and advertise a listener
    # which accepts TCP but never sends HTTP. The timeout must cancel its read.
    with open(tmp_path / "serve.lock", "w") as lock, socket.socket() as listener:
        fcntl.flock(lock, fcntl.LOCK_EX)
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]
        (tmp_path / "serve.json").write_text(json.dumps({
            "version": 1, "pid": 999999, "host": "127.0.0.1", "port": port,
            "url": f"http://127.0.0.1:{port}", "data_dir": str(tmp_path),
            "background": False, "ephemeral": False, "started_at": "2026-09-05T00:00:00Z"}))
        started = time.monotonic()
        result = run(binary, "serve", "wait", "--timeout-ms", "150", "--data-dir", str(tmp_path), timeout=3)
        assert result.returncode == 1
        assert time.monotonic() - started < 2


@pytest.mark.parametrize("status,body", [(503, b'{"status":"ok"}'), (200, b'{"status":"failed"}'), (200, b'not JSON: "status"')])
def test_wait_rejects_unhealthy_http_responses(binary, tmp_path, status, body):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server, open(tmp_path / "serve.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        port = server.server_port
        (tmp_path / "serve.json").write_text(json.dumps({
            "version": 1, "pid": 999999, "host": "127.0.0.1", "port": port,
            "url": f"http://127.0.0.1:{port}", "data_dir": str(tmp_path),
            "background": False, "ephemeral": False, "started_at": "2026-09-05T00:00:00Z"}))
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            result = run(binary, "serve", "wait", "--json", "--timeout-ms", "150", "--data-dir", str(tmp_path), timeout=3)
            assert result.returncode == 1
            assert json.loads(result.stdout)["reason"] == "timeout"
        finally:
            server.shutdown()
            thread.join(timeout=5)
