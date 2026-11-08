"""Reservations and readiness must belong to the fixture's own HTTP process."""
from contextlib import ExitStack, nullcontext
import errno
import http.server
import importlib.util
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

import pytest
import conftest


@pytest.fixture
def harness():
    source = os.environ.get("ZIGBASE_TEST_HARNESS_SOURCE")
    if not source:
        return conftest
    spec = importlib.util.spec_from_file_location("harness_under_test", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def foreign_health():
    class Handler(http.server.BaseHTTPRequestHandler):
        calls = 0
        before_response = None
        def do_GET(self):
            Handler.calls += 1
            if Handler.before_response:
                Handler.before_response()
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass
    class Server(http.server.ThreadingHTTPServer):
        allow_reuse_address = True
    server = Server(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port, Handler
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def delayed_child(tmp_path, port, mode, prefix=b""):
    log_path = tmp_path / "child.log"
    ready_path = tmp_path / "child.ready"
    program = """
import os, pathlib, sys, time
port, ready, mode = sys.argv[1:]
if mode == 'bind_failure':
    print('error: cannot bind 127.0.0.1:' + port + ': ListenError', flush=True)
else:
    print('zigbase listening on http://127.0.0.1:' + port, flush=True)
    print('* Root pid: ' + str(os.getpid() if mode == 'own_marker' else 1), flush=True)
pathlib.Path(ready).write_text('ready')
time.sleep(20)
"""
    with log_path.open("wb") as log:
        log.write(prefix)
        log.flush()
        child = subprocess.Popen([sys.executable, "-u", "-c", program, str(port), str(ready_path), mode], stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 5
    while not ready_path.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert ready_path.exists(), log_path.read_text()
    return child, log_path


def test_rejects_foreign_health_after_own_bind_failure(harness, foreign_health, tmp_path):
    port, handler = foreign_health
    child, log_path = delayed_child(tmp_path, port, "bind_failure")
    try:
        # The child is deliberately alive after logging ListenError. Checking
        # poll() only before the healthy foreign response is not sufficient.
        assert child.poll() is None
        with pytest.raises(AssertionError, match="ListenError"):
            harness._wait_reachable_or_fail(child, port, log_path, timeout_s=0.4)
        assert child.poll() is not None
        assert handler.calls == 0
    finally:
        conftest._stop_server(child)


def test_previous_process_startup_log_cannot_establish_readiness(harness, foreign_health, tmp_path):
    port, handler = foreign_health
    child, log_path = delayed_child(tmp_path, port, "previous_marker")
    try:
        with pytest.raises(AssertionError):
            harness._wait_reachable_or_fail(child, port, log_path, timeout_s=0.3)
        assert handler.calls == 0
    finally:
        conftest._stop_server(child)


def test_process_must_still_be_alive_after_health_response(harness, foreign_health, tmp_path):
    port, handler = foreign_health
    child, log_path = delayed_child(tmp_path, port, "own_marker")
    handler.before_response = lambda: conftest._stop_server(child)
    try:
        with pytest.raises(AssertionError):
            harness._wait_reachable_or_fail(child, port, log_path, timeout_s=0.4)
        # The health response must have been requested, or this proves nothing.
        assert handler.calls >= 1
        assert child.poll() is not None
    finally:
        conftest._stop_server(child)


def test_reservations_exclude_competing_allocations_and_release_on_exception(harness):
    # The same probe runs against the old check-close-bind helper for attribution.
    reserve = harness._reserve_port if hasattr(harness, "_reserve_port") else lambda: nullcontext(harness._free_port())
    ports = []
    with ExitStack() as stack:
        for _ in range(32):
            port = stack.enter_context(reserve())
            assert port not in ports
            ports.append(port)
        with socket.socket() as competing:
            with pytest.raises(OSError) as error:
                competing.bind(("127.0.0.1", ports[0]))
            assert error.value.errno == errno.EADDRINUSE
    with socket.socket() as released:
        released.bind(("127.0.0.1", ports[0]))
    with pytest.raises(RuntimeError):
        with reserve() as failed_port:
            raise RuntimeError("injected startup failure")
    with socket.socket() as released:
        released.bind(("127.0.0.1", failed_port))


@pytest.mark.parametrize("log_format,log_level", [("text", "info"), ("json", "info"), ("text", "error"), ("json", "error")])
def test_real_facil_listener_binds_while_reservation_is_held(binary, tmp_path, log_format, log_level):
    data = tmp_path / "data"
    shutil.copytree(conftest._su_template_for(binary), data)
    log_path = tmp_path / "actual.log"
    with conftest._reserve_port() as port:
        env = {**os.environ, "ZIGBASE_DATA_DIR": str(data), "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"}
        # Restart logs may contain a previous process's bind error and banner.
        log_path.write_text(f"cannot bind 127.0.0.1:{port}: ListenError\n* Root pid: 1\n")
        log_start = log_path.stat().st_size
        with log_path.open("ab") as log:
            child = subprocess.Popen([binary, "serve", "--insecure-cookies", "--log-format", log_format, "--log-level", log_level], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            conftest._wait_reachable_or_fail(child, port, log_path, log_start=log_start)
            assert child.poll() is None
        finally:
            conftest._stop_server(child)


@pytest.mark.parametrize("fixture", ["server", "auth2_server"])
@pytest.mark.parametrize("failure", ["spawn", "readiness"])
def test_shared_fixtures_release_child_directory_and_lease_on_failure(monkeypatch, tmp_path, fixture, failure):
    seed = tmp_path / "seed"
    seed.mkdir()
    monkeypatch.setattr(conftest, "_su_template_for", lambda _: str(seed))
    captured = {}
    original_popen = subprocess.Popen
    def launch(*args, **kwargs):
        captured['data'] = kwargs['env']['ZIGBASE_DATA_DIR']
        captured['port'] = int(kwargs['env']['ZIGBASE_HTTP_PORT'])
        if failure == "spawn":
            raise OSError("injected spawn failure")
        child = original_popen([sys.executable, "-c", "import time; time.sleep(20)"], stdout=kwargs['stdout'], stderr=kwargs['stderr'])
        captured['child'] = child
        return child
    monkeypatch.setattr(conftest.subprocess, "Popen", launch)
    def fail_readiness(*args, **kwargs):
        raise AssertionError("injected readiness failure")
    monkeypatch.setattr(conftest, "_wait_reachable_or_fail", fail_readiness)
    if fixture == "server":
        request = SimpleNamespace(param=None, node=SimpleNamespace(nodeid="ownership-probe"))
        generator = conftest.server.__wrapped__("unused-binary", request)
    else:
        generator = conftest.auth2_server.__wrapped__("unused-binary")
    try:
        with pytest.raises((OSError, AssertionError), match="injected"):
            next(generator)
        assert not Path(captured['data']).exists()
        if 'child' in captured:
            assert captured['child'].poll() is not None
        with socket.socket() as released:
            released.bind(("127.0.0.1", captured['port']))
    finally:
        generator.close()
        if 'child' in captured:
            conftest._stop_server(captured['child'])


def test_restart_readiness_reads_only_new_log_bytes(harness, foreign_health, tmp_path, monkeypatch):
    port, handler = foreign_health
    prefix = b"previous launch output\n" * 65536
    child, log_path = delayed_child(tmp_path, port, "own_marker", prefix)
    original_open = Path.open
    observed = []
    class CountReads:
        def __init__(self, stream):
            self.stream = stream
        def __enter__(self):
            self.stream.__enter__()
            return self
        def __exit__(self, *args):
            return self.stream.__exit__(*args)
        def __getattr__(self, name):
            return getattr(self.stream, name)
        def read(self, *args):
            data = self.stream.read(*args)
            observed.append(len(data))
            return data
    def observe_open(path, *args, **kwargs):
        stream = original_open(path, *args, **kwargs)
        return CountReads(stream) if path == log_path else stream
    monkeypatch.setattr(Path, "open", observe_open)
    try:
        harness._wait_reachable_or_fail(child, port, log_path, timeout_s=0.4, log_start=len(prefix))
        assert handler.calls == 1
        assert 0 < sum(observed) < 16384
    finally:
        conftest._stop_server(child)


def test_unsubscribe_fixture_never_yields_an_unready_server(monkeypatch):
    import test_mail_unsubscribe as unsubscribe
    captured = {}
    original_popen = subprocess.Popen
    monkeypatch.setattr(unsubscribe, "resolve_binary", lambda *args: "unused-binary")
    monkeypatch.setattr(unsubscribe.subprocess, "run", lambda *args, **kwargs: None)
    def launch(*args, **kwargs):
        captured['data'] = kwargs['env']['ZIGBASE_DATA_DIR']
        captured['port'] = int(kwargs['env']['ZIGBASE_HTTP_PORT'])
        child = original_popen([sys.executable, "-u", "-c", "import time; print('startup intentionally delayed', flush=True); time.sleep(20)"],
                               stdout=kwargs['stdout'], stderr=kwargs['stderr'])
        captured['child'] = child
        return child
    monkeypatch.setattr(unsubscribe.subprocess, "Popen", launch)
    monkeypatch.setattr(time, "sleep", lambda _: None)
    original_wait = conftest._wait_reachable_or_fail
    def wait_briefly(proc, port, log_path, **kwargs):
        return original_wait(proc, port, log_path, timeout_s=0.05)
    monkeypatch.setattr(unsubscribe, "_wait_reachable_or_fail", wait_briefly, raising=False)
    generator = unsubscribe.unsub_server.__wrapped__()
    try:
        with pytest.raises(AssertionError, match="never became reachable"):
            next(generator)
        assert captured['child'].poll() is not None
        assert not Path(captured['data']).exists()
        with socket.socket() as released:
            released.bind(("127.0.0.1", captured['port']))
    finally:
        generator.close()
        if 'child' in captured:
            conftest._stop_server(captured['child'])
