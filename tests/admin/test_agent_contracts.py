"""SP-1 "contracts-core" Task 7: per-request access logging.

Exercises `onRequest`'s access-log `defer` end-to-end against a REAL server process,
because the unit tests in `src/logging.zig` only prove the formatting is correct, not
that every response path in `server.zig` actually calls it. Uses its own launcher
(`LoggedServer`) rather than the shared `server` fixture in conftest.py, because that
fixture sends stdout/stderr to `DEVNULL` (conftest.py:52) and this test needs to read
the log stream.
"""
import json, os, pathlib, shutil, socket, sqlite3, subprocess, tempfile, time, urllib.request, urllib.error
import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]


def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


class LoggedServer:
    """A `zigbase serve` whose stderr is captured to a file, so a test can assert on
    the log stream. The shared `server` fixture DEVNULLs both streams, so logging
    tests cannot use it."""

    def __init__(self, base, proc, log_path, data):
        self.base, self.proc, self.log_path, self.data = base, proc, log_path, data

    def log_lines(self):
        return self.log_path.read_text().splitlines()

    def get(self, path):
        try:
            with urllib.request.urlopen(f"{self.base}{path}", timeout=5) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()


@pytest.fixture()
def logged_server(binary, request):
    flags = list(getattr(request, "param", []) or [])
    data = tempfile.mkdtemp(prefix="zb_logged_")
    port = _free_port()
    log_path = pathlib.Path(data) / "server.log"
    env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_HTTP_PORT": str(port)}
    with open(log_path, "w") as log:
        proc = subprocess.Popen(
            [binary, "serve", "--insecure-cookies", *flags],
            env=env, stdout=log, stderr=subprocess.STDOUT,
        )
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            proc.terminate()
            pytest.fail(f"server never became reachable; log:\n{log_path.read_text()}")
        try:
            yield LoggedServer(f"http://127.0.0.1:{port}", proc, log_path, data)
        finally:
            proc.terminate(); proc.wait(timeout=5); shutil.rmtree(data, ignore_errors=True)


@pytest.mark.parametrize("logged_server", [["--log-format", "json"]], indirect=True)
def test_request_logging_json_is_one_object_per_line(logged_server):
    status, _ = logged_server.get("/api/health")
    assert status == 200
    status, _ = logged_server.get("/api/definitely-not-here")
    assert status == 404
    time.sleep(0.3)  # the line is written after the response is sent

    # EVERY line that looks like ours (starts with `{`) must be a JSON object — that is
    # the NDJSON contract for our own output. The vendored facil.io C library also writes
    # its own startup banner ("INFO: Listening on port …", "* Root pid: …", …) to the same
    # fd (`.log = false` on the listener only silences facil.io's per-request access log,
    # not its one-time boot banner); those lines don't start with `{` and are not ours to
    # validate, so they're skipped rather than asserted on. This still catches a broken
    # escape in OUR json (which would fail to parse), just not facil.io's prose.
    records = []
    for line in logged_server.log_lines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        doc = json.loads(line)  # a non-JSON `{`-prefixed line is a hard failure for OUR own output
        assert set(doc) >= {"ts", "level", "scope", "msg"}, doc
        records.append(doc)

    reqs = [r for r in records if r.get("msg") == "request"]
    by_path = {r["path"]: r for r in reqs}
    assert by_path["/api/health"]["status"] == 200
    assert by_path["/api/health"]["method"] == "GET"
    assert isinstance(by_path["/api/health"]["duration_ms"], int)
    # The 404 fall-through path logs too — not just the happy path.
    assert by_path["/api/definitely-not-here"]["status"] == 404


@pytest.mark.parametrize("logged_server", [["--log-format", "json", "--no-request-log"]], indirect=True)
def test_no_request_log_suppresses_access_lines_but_not_startup_lines(logged_server):
    assert logged_server.get("/api/health")[0] == 200
    time.sleep(0.3)
    docs = [json.loads(l) for l in logged_server.log_lines() if l.strip().startswith("{")]
    assert not [d for d in docs if d.get("msg") == "request"], "access lines should be suppressed"
    # Discriminating negative control: the server still logged SOMETHING, so an empty
    # log (a broken server) cannot make this test pass.
    assert docs, "startup lines should still be present"

