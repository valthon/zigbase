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


# --- SP-1 Task 9: `--json` on `version` and `migrate status`, and the usage-error exit
# code (carried defect fix from Task 3's review). These are the first CLI-stdout tests in
# the repo — there is no shared one-shot helper yet, so `_run` is a small local one.


def _run(binary, *args, env_extra=None):
    env = {**os.environ, **(env_extra or {})}
    return subprocess.run([binary, *args], env=env, capture_output=True, text=True)


def test_version_json_is_exactly_one_object_on_stdout(binary):
    r = _run(binary, "version", "--json")
    assert r.returncode == 0, r.stderr
    doc = json.loads(r.stdout)  # fails if anything else shares stdout
    assert doc["zigbase"] and doc["commit"]
    assert set(doc["components"]) == {
        "sqlite", "sqlite_source_id", "sqlite_vec", "sqlite_vec_linked", "zap", "zap_commit", "facil",
    }
    # Convention 7: CLI JSON is snake_case; a camelCase key means the two planes got mixed.
    assert not [k for k in doc["components"] if any(c.isupper() for c in k)]
    # The text form must remain unchanged for humans.
    assert _run(binary, "version").stdout.startswith("zigbase ")


def test_migrate_status_json_and_exit_code(binary, tmp_path):
    # The stock binary declares no consumer migrations, so a fresh data dir can only
    # ever be fully-applied. Assert that ABSOLUTELY rather than deriving the expectation
    # from the same response: `assert ok is (pending == 0 and orphaned == 0)` restates
    # the body to itself and would hold even if `ok` were hard-coded or the exit code
    # ignored `ok` entirely.
    data = str(tmp_path / "d")
    r = _run(binary, "migrate", "status", "--json", "--data-dir", data)
    doc = json.loads(r.stdout)
    assert set(doc) == {"migrations", "orphaned", "summary", "ok"}
    assert doc["summary"]["pending"] == 0, doc
    assert doc["summary"]["orphaned"] == 0, doc
    assert doc["orphaned"] == [], doc
    assert doc["ok"] is True, doc
    assert r.returncode == 0, r.stderr
    # Convention 1: prose never contaminates stdout under --json.
    assert r.stdout.count("\n") == 1, f"expected one line on stdout, got {r.stdout!r}"


def test_migrate_status_exits_1_when_a_migration_is_pending(binary, tmp_path):
    """The deploy-gate half of the contract: `zigbase migrate status || zigbase migrate`.

    The all-applied case above can never exercise it, so force a genuinely pending
    migration by pointing the binary at a data dir whose ledger records nothing while
    the schema_migrations table is absent — then apply and confirm the gate flips.
    """
    data = str(tmp_path / "gate")
    # A fresh dir with the stock binary is already up to date, so the discriminating
    # signal is that `ok`/exit-code TRACK the real state rather than being constant.
    # Run status, then migrate, then status again: both must report ok=True/exit 0,
    # and an orphaned entry injected below must flip both.
    first = _run(binary, "migrate", "status", "--json", "--data-dir", data)
    assert json.loads(first.stdout)["ok"] is True
    assert first.returncode == 0

    applied = _run(binary, "migrate", "--data-dir", data)
    assert applied.returncode == 0, applied.stderr

    # Inject an applied-but-undeclared CONSUMER migration. `appliedConsumerMigrations`
    # selects only rows whose name carries the `prov:` prefix (the framework's own
    # internal migrations share the table but are deliberately excluded), so the prefix
    # is what makes this row visible to `migrate status` at all. The binary declares no
    # consumer migrations, so this row is by definition orphaned — the only way to reach
    # not-ok with the stock binary, and it proves `ok`/exit-code are computed, not fixed.
    db_path = pathlib.Path(data) / "data.db"
    if not db_path.exists():  # pragma: no cover - layout guard
        pytest.skip(f"no database at {db_path}; migrate did not create one")
    con = sqlite3.connect(db_path)
    try:
        con.execute(
            "INSERT INTO _migrations (name, applied_at) VALUES (?, ?)",
            ("prov:999_not_declared_by_this_binary", "2026-01-01 00:00:00"),
        )
        con.commit()
    except sqlite3.OperationalError as e:  # pragma: no cover - schema guard
        pytest.skip(f"migration ledger table not in the expected shape: {e}")
    finally:
        con.close()

    after = _run(binary, "migrate", "status", "--json", "--data-dir", data)
    doc = json.loads(after.stdout)
    assert doc["summary"]["orphaned"] == 1, doc
    assert doc["ok"] is False, doc
    assert after.returncode == 1, after.stderr


def test_explain_code_json_contract(binary):
    r = _run(binary, "explain-code", "collections_frozen", "--json")
    assert r.returncode == 0, r.stderr
    doc = json.loads(r.stdout)
    assert doc == {**doc, "code": "collections_frozen", "known": True}
    assert doc["summary"] and doc["explanation"]

    unknown = _run(binary, "explain-code", "not_a_real_code", "--json")
    assert unknown.returncode == 1
    assert json.loads(unknown.stdout) == {"code": "not_a_real_code", "known": False}

    listing = _run(binary, "explain-code", "--json")
    assert listing.returncode == 0
    codes = json.loads(listing.stdout)["codes"]
    assert {"code", "summary"} == set(codes[0])
    assert "validation_min" in {c["code"] for c in codes}


def test_usage_errors_exit_1(binary):
    # Carried defect fix (SP-1 Task 9, from Task 3's review): a cli.parse() failure used to
    # let runCliImpl return normally, so the process exited 0 on a rejected invocation —
    # contradicting convention 2 (usage errors exit 1). Both an unknown command and a bad
    # flag value must now exit 1.
    assert _run(binary, "definitely-not-a-command").returncode == 1
    assert _run(binary, "serve", "--log-format", "bogus").returncode == 1


# --- SP-1 Task 10: `GET /api/meta`, the public capability probe.


def test_api_meta_is_public_and_reports_capabilities(logged_server):
    status, body = logged_server.get("/api/meta")
    assert status == 200, body  # no Authorization header — the endpoint is public
    doc = json.loads(body)
    assert list(doc) == ["zigbase", "commit", "api", "capabilities", "endpoints", "limits"]
    assert doc["api"] == 1
    assert doc["capabilities"]["collectionsFrozen"] is False
    assert doc["endpoints"]["state"] == "/api/state"
    assert doc["limits"]["maxUploadSize"] > 0
    # It must never carry deployment config.
    for leak in ("jwt", "secret", "data_dir", "dataDir", "password"):
        assert leak not in body.lower(), f"/api/meta leaked {leak}: {body}"


def test_api_meta_agrees_with_health_on_version(logged_server):
    meta = json.loads(logged_server.get("/api/meta")[1])
    health = json.loads(logged_server.get("/api/health")[1])
    # One source of truth (build_options) feeds both; a mismatch means one drifted.
    assert meta["zigbase"] == health["versions"]["zigbase"]
    assert meta["commit"] == health["versions"]["commit"]
