"""Real SQLite/local upload recovery, including actual process death around commit."""
import http.client
import json
import os
import shutil
import sqlite3
import subprocess
import urllib.error

import pytest
from conftest import _free_port, _su_template_for, _wait_reachable_or_fail
import test_resumable_uploads as network


@pytest.fixture(scope="session")
def binary():
    path = os.environ.get("ZIGBASE_TEST_DURABLE_UPLOADS_BINARY")
    if not path:
        pytest.skip("requires durable-uploads-fixture with both upload build flags")
    assert os.path.isfile(path)
    return path


@pytest.fixture()
def running(binary, tmp_path):
    data = tmp_path / "data"
    shutil.copytree(_su_template_for(binary), data)
    port = _free_port()
    base = f"http://127.0.0.1:{port}"
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(data), "ZIGBASE_HTTP_PORT": str(port),
           "ZIGBASE_SERVE_BACKGROUND": "0"}
    log_path = tmp_path / "server.log"
    processes = []

    def start(*, ready=True, other_port=None):
        launch_env = {**env, "ZIGBASE_HTTP_PORT": str(other_port or port)}
        args = [binary, "serve", "--insecure-cookies"]
        if other_port:
            args.append("--ignore-lock")  # Exercise upload ownership, not CLI tracking.
        with log_path.open("ab") as log:
            proc = subprocess.Popen(args, env=launch_env,
                                    stdout=log, stderr=subprocess.STDOUT)
        processes.append(proc)
        if ready:
            _wait_reachable_or_fail(proc, other_port or port, str(log_path))
        return proc

    proc = start()
    try:
        yield base, data, proc, start, log_path
    finally:
        for child in processes:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=10)


def kill(proc):
    proc.kill()
    proc.wait(timeout=10)


def test_failed_record_rollback_terminates_before_finish(running):
    base, data, proc, start, log = running
    admin, tokens, _, record = network.setup(base)
    code, upload = network.begin(base, tokens[0], record, filename="rollbackfail.txt")
    assert code == 201, upload
    path = "/api/uploads/" + upload["id"]
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    with pytest.raises((http.client.RemoteDisconnected, urllib.error.URLError, ConnectionResetError)):
        network.call(base, "POST", path + "/commit", token=tokens[0])
    assert proc.wait(timeout=10) != 0
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT state,offset,coalesce(length(payload),0) FROM _upload_sessions s LEFT JOIN _upload_payloads p ON p.session=s.id WHERE id=?",
                            (upload["id"],)).fetchone() == ("committing", 4, 4)
    assert "record update rollback failed" in log.read_text()
    assert "restart required" in log.read_text()
    start()
    assert network.call(base, "GET", path, token=tokens[0])[1]["state"] == "failed"
    assert network.call(base, "GET", "/api/upload-probe", token=admin)[1] == {"before": 0, "after": 0}


def test_legacy_layout_is_rejected_without_mutation(running):
    base, data, proc, start, log = running
    _, tokens, _, record = network.setup(base)
    assert network.begin(base, tokens[0], record)[0] == 201
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        conn.executescript("""
            ALTER TABLE _upload_sessions RENAME TO _split_sessions;
            CREATE TABLE _upload_sessions(id TEXT PRIMARY KEY, metadata TEXT NOT NULL,
              length INTEGER NOT NULL, offset INTEGER NOT NULL, expires INTEGER NOT NULL,
              state TEXT NOT NULL, payload BLOB NOT NULL);
            INSERT INTO _upload_sessions SELECT s.*,p.payload FROM _split_sessions s
              JOIN _upload_payloads p ON p.session=s.id;
            DROP TABLE _upload_payloads;
            DROP TABLE _split_sessions;
            UPDATE _upload_settings SET version=1;
        """)
        before = conn.execute("SELECT * FROM _upload_sessions").fetchall()
    assert start(ready=False).wait(timeout=10) != 0
    assert "UnsupportedUploadStoreVersion" in log.read_text()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT * FROM _upload_sessions").fetchall() == before
        assert conn.execute("SELECT version FROM _upload_settings").fetchone() == (1,)
        assert conn.execute("SELECT name FROM sqlite_schema WHERE name='_upload_payloads'").fetchone() is None


def test_equivalent_budget_json_does_not_invalidate_live_sessions(running):
    base, data, proc, start, _ = running
    _, tokens, _, record = network.setup(base)
    _, upload = network.begin(base, tokens[0], record)
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        limits = json.loads(conn.execute("SELECT limits FROM _upload_settings").fetchone()[0])
        # An absent field with the same default and a different serialization
        # are semantically identical to the configured typed budgets.
        assert limits.pop("max_sessions_per_principal") == 2
        conn.execute("UPDATE _upload_settings SET limits=?", (json.dumps(limits, sort_keys=True, indent=2),))
    start()
    assert network.call(base, "GET", "/api/uploads/" + upload["id"], token=tokens[0])[0] == 200


def test_automatic_record_rollback_leaves_writer_usable(running):
    base, data, _, _, log = running
    admin, tokens, _, record = network.setup(base)
    code, upload = network.begin(base, tokens[0], record)
    assert code == 201, upload
    path = "/api/uploads/" + upload["id"]
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("CREATE TRIGGER automatic_rollback BEFORE UPDATE ON uploads "
                     "BEGIN SELECT RAISE(ROLLBACK, 'injected automatic rollback'); END")
    assert network.call(base, "POST", path + "/commit", token=tokens[0])[0] >= 400
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("DROP TRIGGER automatic_rollback")
    code, status = network.call(base, "GET", path, token=tokens[0])
    assert code == 200 and status["state"] == "failed", (code, status)
    assert network.call(base, "PATCH", "/api/collections/uploads/records/" + record["id"],
                        {"title": "writer-still-usable"}, admin)[0] == 200
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT state,offset,coalesce(length(payload),0) FROM _upload_sessions s LEFT JOIN _upload_payloads p ON p.session=s.id WHERE id=?",
                            (upload["id"],)).fetchone() == ("failed", 4, 0)
        assert conn.execute("SELECT title,file FROM uploads WHERE id=?",
                            (record["id"],)).fetchone() == ("writer-still-usable", None)
    assert "record update rollback failed" not in log.read_text()
    assert "ConnectionQuarantined" not in log.read_text()


@pytest.mark.parametrize("trigger", [
    "BEFORE UPDATE ON _upload_sessions WHEN NEW.state='completed'",
    "BEFORE DELETE ON _upload_payloads WHEN "
    "(SELECT state FROM _upload_sessions WHERE id=OLD.session)='completed'",
])
@pytest.mark.parametrize("raise_expr", ["ABORT, 'receipt write failed'", "IGNORE"])
def test_completion_receipt_failure_is_503_without_poisoning_clean_store(running, trigger, raise_expr):
    base, data, _, _, _ = running
    admin, tokens, _, record = network.setup(base)
    code, upload = network.begin(base, tokens[0], record)
    assert code == 201, upload
    path = "/api/uploads/" + upload["id"]
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute(f"CREATE TRIGGER reject_receipt {trigger} "
                     f"BEGIN SELECT RAISE({raise_expr}); END")
    code, body = network.call(base, "POST", path + "/commit", token=tokens[0])
    assert code == 503 and body["code"] == "internal", (code, body)
    assert "restart required" not in body["message"]
    code, status = network.call(base, "GET", path, token=tokens[0])
    assert code == 200 and status["state"] == "failed", (code, status)
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT file FROM uploads WHERE id=?", (record["id"],)).fetchone() == (None,)
        assert conn.execute("SELECT state,offset,coalesce(length(payload),0) FROM _upload_sessions s LEFT JOIN _upload_payloads p ON p.session=s.id WHERE id=?",
                            (upload["id"],)).fetchone() == ("failed", 4, 0)
        conn.execute("DROP TRIGGER reject_receipt")
    assert network.call(base, "PATCH", "/api/collections/uploads/records/" + record["id"],
                        {"title": "writer-still-usable"}, admin)[0] == 200
    code, replacement = network.begin(base, tokens[0], record)
    assert code == 201, replacement
    replacement_path = "/api/uploads/" + replacement["id"]
    assert network.call(base, "PATCH", replacement_path, b"abcd", tokens[0], 0)[0] == 204
    assert network.call(base, "POST", replacement_path + "/commit", token=tokens[0])[0] == 204


@pytest.mark.parametrize("offset", [0, 3, 5])
def test_completion_rechecks_full_offset_in_record_transaction(running, offset):
    base, data, proc, start, _ = running
    _, tokens, _, record = network.setup(base)
    code, upload = network.begin(base, tokens[0], record)
    assert code == 201, upload
    path = "/api/uploads/" + upload["id"]
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    with sqlite3.connect(data / "data.db") as conn:
        # Like a trusted before-hook, this executes inside the record writer's
        # transaction. The receipt must recheck its invariant before commit.
        conn.execute("CREATE TRIGGER change_upload_offset BEFORE UPDATE ON uploads "
                     f"BEGIN UPDATE _upload_sessions SET offset={offset} WHERE state='committing'; END")
    code, body = network.call(base, "POST", path + "/commit", token=tokens[0])
    assert code == 503, (code, body)
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT file FROM uploads WHERE id=?", (record["id"],)).fetchone() == (None,)
        assert conn.execute("SELECT state,offset,coalesce(length(payload),0) FROM _upload_sessions s LEFT JOIN _upload_payloads p ON p.session=s.id WHERE id=?",
                            (upload["id"],)).fetchone() == ("failed", 4, 0)
        conn.execute("DROP TRIGGER change_upload_offset")
    kill(proc)
    start()
    code, status = network.call(base, "GET", path, token=tokens[0])
    assert code == 200 and status["state"] == "failed" and status["offset"] == 4, (code, status)


def test_acknowledged_chunks_and_completed_receipts_survive_sigkill(running):
    base, _, proc, start, _ = running
    admin, tokens, _, record = network.setup(base)
    code, upload = network.begin(base, tokens[0], record)
    assert code == 201 and upload["durability"] == "sqlite-restart", upload
    path = "/api/uploads/" + upload["id"]
    assert network.call(base, "PATCH", path, b"ab", tokens[0], 0)[0] == 204
    kill(proc)
    proc = start()
    assert network.call(base, "GET", path, token=tokens[0])[1]["offset"] == 2
    assert network.call(base, "GET", path, token=tokens[1])[0] == 404
    assert network.call(base, "PATCH", path, b"ab", tokens[0], 0)[0] == 204
    assert network.call(base, "PATCH", path, b"zz", tokens[0], 0)[0] == 409
    assert network.call(base, "PATCH", path, b"bc", tokens[0], 1)[0] == 409
    assert network.call(base, "PATCH", path, b"cd", tokens[0], 2)[0] == 204
    assert network.call(base, "POST", path + "/commit", token=tokens[0])[0] == 204
    kill(proc)
    start()
    assert network.call(base, "POST", path + "/commit", token=tokens[0])[0] == 204
    assert network.call(base, "GET", "/api/upload-probe", token=admin)[1] == {"before": 0, "after": 0}
    saved = network.call(base, "GET", "/api/collections/uploads/records/" + record["id"])[1]
    assert network.call(base, "GET", f"/api/files/uploads/{record['id']}/{saved['file']}")[1] == b"abcd"


@pytest.mark.parametrize("filename,state,retry", [("crashbefore.txt", "failed", 409),
                                                  ("crashafter.txt", "completed", 204)])
def test_crash_during_commit_never_reexecutes_hooks(running, filename, state, retry):
    base, _, proc, start, _ = running
    admin, tokens, _, record = network.setup(base)
    code, upload = network.begin(base, tokens[0], record, filename=filename)
    assert code == 201, upload
    path = "/api/uploads/" + upload["id"]
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    with pytest.raises((http.client.RemoteDisconnected, urllib.error.URLError, ConnectionResetError)):
        network.call(base, "POST", path + "/commit", token=tokens[0])
    assert proc.wait(timeout=10) == -9
    start()
    assert network.call(base, "GET", path, token=tokens[0])[1]["state"] == state
    assert network.call(base, "POST", path + "/commit", token=tokens[0])[0] == retry
    assert network.call(base, "GET", "/api/upload-probe", token=admin)[1] == {"before": 0, "after": 0}
    saved = network.call(base, "GET", "/api/collections/uploads/records/" + record["id"])[1]
    assert bool(saved.get("file")) == (state == "completed")


def test_append_failure_rolls_back_bytes_and_offset_and_requires_restart(running):
    base, data, proc, start, _ = running
    _, tokens, _, record = network.setup(base)
    _, upload = network.begin(base, tokens[0], record)
    path = "/api/uploads/" + upload["id"]
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("CREATE TRIGGER reject_offset BEFORE UPDATE OF offset ON _upload_sessions BEGIN SELECT RAISE(ABORT,'test failure after blob write'); END")
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 503
    assert network.call(base, "GET", path, token=tokens[0])[0] == 503
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT offset,payload FROM _upload_sessions s JOIN _upload_payloads p ON p.session=s.id").fetchone() == (0, b"\0" * 4)
        conn.execute("DROP TRIGGER reject_offset")
    start()
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    assert network.call(base, "POST", path + "/commit", token=tokens[0])[0] == 204


def test_owner_lock_and_persisted_principal_quota(running):
    base, _, proc, start, log_path = running
    _, tokens, _, record = network.setup(base)
    assert network.begin(base, tokens[0], record, 64)[0] == 201
    assert network.begin(base, tokens[0], record, 64)[0] == 201
    competing = start(ready=False, other_port=_free_port())
    assert competing.wait(timeout=10) != 0
    assert "WouldBlock" in log_path.read_text()
    kill(proc)
    start()
    assert network.begin(base, tokens[0], record)[0] == 429
    assert network.begin(base, tokens[1], record)[0] == 429


def test_competing_owner_cannot_run_startup_cleanup(running):
    _, data, proc, start, log_path = running
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("INSERT INTO _authChallenges VALUES(?,?,?,?,?,?,?,?)",
                     ("startup-marker", "users", "probe", "marker", "{}", 0, 0, "2000-01-01"))
    competing = start(ready=False, other_port=_free_port())
    assert competing.wait(timeout=10) != 0
    assert "WouldBlock" in log_path.read_text()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT id FROM _authChallenges WHERE id='startup-marker'").fetchone() == ("startup-marker",)
    kill(proc)
    start()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT id FROM _authChallenges WHERE id='startup-marker'").fetchone() is None


@pytest.mark.parametrize("mutation,expected", [
    ("UPDATE _upload_settings SET limits=json_set(limits,'$.ttl_seconds',61)", "DurableUploadBudgetsChanged"),
    ("UPDATE _upload_settings SET version=9000", "UnsupportedUploadStoreVersion"),
    ("UPDATE _upload_sessions SET offset=999", "InvalidUploadStore"),
    ("UPDATE _upload_sessions SET state='completed',offset=length-1; DELETE FROM _upload_payloads", "InvalidUploadStore"),
    ("UPDATE _upload_sessions SET metadata='{'", "InvalidUploadStore"),
    ("UPDATE _upload_sessions SET metadata=json_set(metadata,'$.unexpected',1)", "InvalidUploadStore"),
])
def test_startup_refuses_incompatible_or_corrupt_state(running, mutation, expected):
    base, data, proc, start, log_path = running
    _, tokens, _, record = network.setup(base)
    assert network.begin(base, tokens[0], record)[0] == 201
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        conn.executescript(mutation)
        before = conn.execute("SELECT * FROM _upload_sessions ORDER BY id").fetchall()
        payloads_before = conn.execute("SELECT * FROM _upload_payloads ORDER BY rowid").fetchall()
        settings_before = conn.execute("SELECT * FROM _upload_settings ORDER BY id").fetchall()
    restarted = start(ready=False)
    assert restarted.wait(timeout=10) != 0
    assert expected in log_path.read_text()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT * FROM _upload_sessions ORDER BY id").fetchall() == before
        assert conn.execute("SELECT * FROM _upload_payloads ORDER BY rowid").fetchall() == payloads_before
        assert conn.execute("SELECT * FROM _upload_settings ORDER BY id").fetchall() == settings_before


@pytest.mark.parametrize("table", ["sessions", "payloads"])
def test_recovery_rejects_duplicate_keys_without_constraints(running, table):
    base, data, proc, start, log = running
    _, tokens, _, record = network.setup(base)
    assert network.begin(base, tokens[0], record)[0] == 201
    kill(proc)
    name = "_upload_" + table
    with sqlite3.connect(data / "data.db") as conn:
        conn.executescript(f"CREATE TABLE copy AS SELECT * FROM {name}; DROP TABLE {name}; "
                           f"ALTER TABLE copy RENAME TO {name}; INSERT INTO {name} SELECT * FROM {name};")
        before = conn.execute(f"SELECT * FROM {name}").fetchall()
    assert start(ready=False).wait(timeout=10) != 0
    assert "InvalidUploadStore" in log.read_text()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute(f"SELECT * FROM {name}").fetchall() == before


@pytest.mark.parametrize("bad_id", ["1.0", 1.5, b"1", "x" * 1048576], ids=["text", "real", "blob", "oversized-text"])
def test_settings_key_requires_integer_storage_without_mutation(running, bad_id):
    _, data, proc, start, log = running
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        settings = conn.execute("SELECT version,limits FROM _upload_settings").fetchone()
        conn.executescript("DROP TABLE _upload_settings; CREATE TABLE _upload_settings(id UNIQUE,version INTEGER,limits TEXT);")
        conn.execute("INSERT INTO _upload_settings VALUES(?,?,?)", (bad_id, *settings))
    assert start(ready=False).wait(timeout=10) != 0
    assert "InvalidUploadStore" in log.read_text()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT * FROM _upload_settings").fetchall() == [(bad_id, *settings)]


@pytest.mark.parametrize("mutation", [
    "DELETE FROM _upload_settings",
    "DROP TABLE _upload_settings",
    "DROP TABLE _upload_payloads; ALTER TABLE _upload_sessions ADD COLUMN payload BLOB; DELETE FROM _upload_settings",
])
def test_empty_existing_store_without_marker_is_not_initialized(running, mutation):
    _, data, proc, start, log = running
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        conn.executescript(mutation)
        before = conn.execute("SELECT name,sql FROM sqlite_schema WHERE name LIKE '_upload_%' ORDER BY name").fetchall()
    assert start(ready=False).wait(timeout=10) != 0
    assert "InvalidUploadStore" in log.read_text()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT name,sql FROM sqlite_schema WHERE name LIKE '_upload_%' ORDER BY name").fetchall() == before
        if any(name == "_upload_settings" for name, _ in before):
            assert conn.execute("SELECT * FROM _upload_settings").fetchall() == []


@pytest.mark.parametrize("operation", ["INSERT", "UPDATE"])
def test_ignored_settings_save_rolls_back_recovery(running, operation):
    base, data, proc, start, log = running
    _, tokens, _, record = network.setup(base)
    assert network.begin(base, tokens[0], record)[0] == 201
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("UPDATE _upload_sessions SET expires=0")
        before = conn.execute("SELECT * FROM _upload_sessions").fetchall()
        payloads = conn.execute("SELECT * FROM _upload_payloads").fetchall()
        settings = conn.execute("SELECT * FROM _upload_settings").fetchall()
        conn.execute(f"CREATE TRIGGER ignore_settings BEFORE {operation} ON _upload_settings BEGIN SELECT RAISE(IGNORE); END")
    assert start(ready=False).wait(timeout=10) != 0
    assert "InvalidUploadStore" in log.read_text()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT * FROM _upload_sessions").fetchall() == before
        assert conn.execute("SELECT * FROM _upload_payloads").fetchall() == payloads
        assert conn.execute("SELECT * FROM _upload_settings").fetchall() == settings


def test_expiry_removes_payloads_without_foreign_key_constraint(running):
    base, data, proc, start, _ = running
    _, tokens, _, record = network.setup(base)
    assert network.begin(base, tokens[0], record)[0] == 201
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        conn.executescript("CREATE TABLE copy(rowid INTEGER PRIMARY KEY,session TEXT UNIQUE,payload BLOB); "
                           "INSERT INTO copy SELECT * FROM _upload_payloads; DROP TABLE _upload_payloads; "
                           "ALTER TABLE copy RENAME TO _upload_payloads; UPDATE _upload_sessions SET expires=0;")
    proc = start()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT * FROM _upload_sessions").fetchall() == []
        assert conn.execute("SELECT * FROM _upload_payloads").fetchall() == []
    kill(proc)
    start()


def test_ignored_offset_update_does_not_acknowledge_or_persist_chunk(running):
    base, data, proc, start, _ = running
    _, tokens, _, record = network.setup(base)
    code, upload = network.begin(base, tokens[0], record)
    assert code == 201
    path = "/api/uploads/" + upload["id"]
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("CREATE TRIGGER ignore_offset BEFORE UPDATE OF offset ON _upload_sessions BEGIN SELECT RAISE(IGNORE); END")
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 503
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT offset,payload FROM _upload_sessions s JOIN _upload_payloads p ON p.session=s.id").fetchone() == (0, bytes(4))
        conn.execute("DROP TRIGGER ignore_offset")
    kill(proc)
    start()
    assert network.call(base, "GET", path, token=tokens[0])[1]["offset"] == 0
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204


@pytest.mark.parametrize("expired", [False, True])
def test_all_recovery_invariants_precede_sweeps(running, expired):
    base, data, proc, start, log_path = running
    _, tokens, _, record = network.setup(base)
    assert network.begin(base, tokens[0], record)[0] == 201
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        original = list(conn.execute("SELECT * FROM _upload_sessions").fetchone())
        original_payload = conn.execute("SELECT * FROM _upload_payloads").fetchone()
        settings = conn.execute("SELECT * FROM _upload_settings").fetchone()
    if expired:
        original[4] = 0
    mutations = [
        "UPDATE _upload_sessions SET state='committing',offset=length-1",
        "UPDATE _upload_sessions SET metadata='{'",
        "UPDATE _upload_sessions SET id='short'",
        "UPDATE _upload_sessions SET id=printf('%032d',0)||'x'",
        "UPDATE _upload_sessions SET id=char(0)||substr(id,2)",
        "UPDATE _upload_sessions SET id=NULL",
        "UPDATE _upload_sessions SET id=CAST(id AS BLOB)",
        "UPDATE _upload_sessions SET id=CAST(zeroblob(1048576) AS TEXT)",
        "UPDATE _upload_sessions SET id=zeroblob(1048576)",
        "UPDATE _upload_sessions SET metadata=CAST(metadata AS BLOB)",
        "UPDATE _upload_sessions SET metadata=json_set(metadata,'$.unexpected',1)",
        "UPDATE _upload_sessions SET metadata=json_remove(metadata,'$.binding')",
        "UPDATE _upload_sessions SET metadata=json_set(metadata,'$.binding.principal',5)",
        "UPDATE _upload_sessions SET metadata=json_set(metadata,'$.binding.collection_id','')",
        "UPDATE _upload_sessions SET metadata=json_set(metadata,'$.target.filename',printf('%0256d',0))",
        "UPDATE _upload_sessions SET length=4.5",
        "UPDATE _upload_sessions SET length='invalid'",
        "UPDATE _upload_sessions SET length=CAST(length AS BLOB)",
        "UPDATE _upload_sessions SET length=0",
        "UPDATE _upload_sessions SET length=65; UPDATE _upload_payloads SET payload=zeroblob(65)",
        "UPDATE _upload_sessions SET offset=0.5",
        "UPDATE _upload_sessions SET offset=CAST(offset AS BLOB)",
        "UPDATE _upload_sessions SET offset=-1",
        "UPDATE _upload_sessions SET offset=length+1",
        "UPDATE _upload_sessions SET expires=0.5",
        "UPDATE _upload_sessions SET expires='invalid'",
        "UPDATE _upload_sessions SET expires=CAST(expires AS BLOB)",
        "UPDATE _upload_sessions SET state='unknown'",
        "UPDATE _upload_sessions SET state=CAST(state AS BLOB)",
        "UPDATE _upload_sessions SET state=CAST(zeroblob(1048576) AS TEXT)",
        "UPDATE _upload_sessions SET state=zeroblob(1048576)",
        "UPDATE _upload_payloads SET payload=CAST(payload AS TEXT)",
        "UPDATE _upload_payloads SET payload=zeroblob(3)",
        "UPDATE _upload_sessions SET state='completed',offset=length-1; DELETE FROM _upload_payloads",
        "UPDATE _upload_sessions SET state='completed',offset=length",
        "UPDATE _upload_sessions SET state='failed'",
        "UPDATE _upload_settings SET version=1.5",
        "UPDATE _upload_settings SET version='invalid'",
        "UPDATE _upload_settings SET version=CAST(version AS BLOB)",
        "UPDATE _upload_settings SET limits=CAST(limits AS BLOB)",
        "UPDATE _upload_settings SET limits='{'",
        "DELETE FROM _upload_settings",
        "DELETE FROM _upload_payloads",
        "UPDATE _upload_payloads SET session='orphan'",
        "UPDATE _upload_payloads SET session=CAST(session AS BLOB)",
        "UPDATE _upload_payloads SET session=CAST(zeroblob(1048576) AS TEXT)",
        "UPDATE _upload_sessions SET state='failed'; UPDATE _upload_payloads SET payload=zeroblob(0)",
        "INSERT INTO _upload_payloads(session,payload) VALUES('orphan',zeroblob(4))",
        "PRAGMA ignore_check_constraints=ON; INSERT INTO _upload_settings SELECT 2,version,limits FROM _upload_settings",
        "INSERT INTO _upload_sessions SELECT printf('%032d',1),metadata,length,offset,expires,state FROM _upload_sessions; "
        "INSERT INTO _upload_sessions SELECT printf('%032d',2),metadata,length,offset,expires,state FROM _upload_sessions LIMIT 1; "
        "INSERT INTO _upload_payloads(session,payload) SELECT id,zeroblob(length) FROM _upload_sessions WHERE id NOT IN (SELECT session FROM _upload_payloads)",
        "UPDATE _upload_sessions SET length=64; UPDATE _upload_payloads SET payload=zeroblob(64); "
        "INSERT INTO _upload_sessions SELECT printf('%032d',1),json_set(metadata,'$.binding.principal','other1'),length,offset,expires,state FROM _upload_sessions; "
        "INSERT INTO _upload_sessions SELECT printf('%032d',2),json_set(metadata,'$.binding.principal','other2'),length,offset,expires,state FROM _upload_sessions LIMIT 1; "
        "INSERT INTO _upload_payloads(session,payload) SELECT id,zeroblob(length) FROM _upload_sessions WHERE id NOT IN (SELECT session FROM _upload_payloads)",
    ]
    # Reuse the fixture database rather than spawning a new auth setup per case.
    # Every mutation starts from the same valid row/settings and boot must refuse
    # without modifying either, even if expiry would otherwise discard the row.
    for mutation in mutations:
        with sqlite3.connect(data / "data.db") as conn:
            conn.execute("DELETE FROM _upload_payloads")
            conn.execute("INSERT INTO _upload_payloads VALUES(?,?,?)", original_payload)
            conn.execute("DELETE FROM _upload_sessions")
            conn.execute("INSERT INTO _upload_sessions VALUES(?,?,?,?,?,?)", original)
            conn.execute("DELETE FROM _upload_settings")
            conn.execute("INSERT INTO _upload_settings VALUES(?,?,?)", settings)
            conn.executescript(mutation)
            before = conn.execute("SELECT * FROM _upload_sessions ORDER BY id").fetchall()
            payloads_before = conn.execute("SELECT * FROM _upload_payloads ORDER BY rowid").fetchall()
            settings_before = conn.execute("SELECT * FROM _upload_settings ORDER BY id").fetchall()
        log_offset = log_path.stat().st_size
        assert start(ready=False).wait(timeout=10) != 0, mutation
        assert "InvalidUploadStore" in log_path.read_text()[log_offset:], mutation
        with sqlite3.connect(data / "data.db") as conn:
            assert conn.execute("SELECT * FROM _upload_sessions ORDER BY id").fetchall() == before, mutation
            assert conn.execute("SELECT * FROM _upload_payloads ORDER BY rowid").fetchall() == payloads_before
            assert conn.execute("SELECT * FROM _upload_settings ORDER BY id").fetchall() == settings_before, mutation


@pytest.mark.parametrize("state,offset", [("receiving", 0), ("receiving", 4), ("committing", 4), ("completed", 4), ("failed", 0), ("failed", 4)])
@pytest.mark.parametrize("expired", [False, True])
def test_valid_recovery_states_remain_accepted(running, state, offset, expired):
    base, data, proc, start, _ = running
    _, tokens, _, record = network.setup(base)
    _, upload = network.begin(base, tokens[0], record)
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("UPDATE _upload_sessions SET state=?,offset=?", (state, offset))
        if state not in ("receiving", "committing"):
            conn.execute("DELETE FROM _upload_payloads")
        if expired:
            conn.execute("UPDATE _upload_sessions SET expires=0")
    start()
    code, status = network.call(base, "GET", "/api/uploads/" + upload["id"], token=tokens[0])
    if expired:
        assert code == 404
        return
    assert code == 200
    assert status["state"] == ("failed" if state == "committing" else state)
    assert status["offset"] == offset


def test_framework_tables_describe_opt_in_restart_persistence():
    from pathlib import Path

    text = (Path(__file__).resolve().parents[2] / "docs/framework.md").read_text()
    files = next(line for line in text.splitlines() if line.startswith("| `files` |"))
    base_flag = next(line for line in text.splitlines() if line.startswith("| `-Dresumable-uploads` |"))
    for row in (files, base_flag):
        assert "durable = true" in row and "-Ddurable-resumable-uploads" in row
    assert "no restart or cross-instance durability" not in base_flag


def test_agent_entrypoints_and_protocol_distinguish_durability_modes():
    from pathlib import Path

    root = Path(__file__).resolve().parents[2]
    entries = [root / "docs/agents.md", *root.glob("skills/zigbase-*/references/agents.md")]
    assert len(entries) > 1
    for entry in entries:
        text = entry.read_text()
        assert "Default RAM sessions are process-local" in text
        assert "SQLite/local durability preserves sessions across process restarts" in text
        assert "not restart-durable streaming" not in text
    protocol = (root / "docs/resumable-uploads.md").read_text()
    creation = next(line for line in protocol.splitlines() if line.startswith("1. `POST"))
    status = next(line for line in protocol.splitlines() if line.startswith("3. `GET"))
    assert "`process-local` for RAM sessions or `sqlite-restart`" in creation
    assert "`404` for RAM sessions" in status
    assert "SQLite persistence restores unexpired sessions after restart" in status


def test_restart_expires_and_releases_persisted_payloads(running):
    base, data, proc, start, _ = running
    _, tokens, _, record = network.setup(base)
    _, upload = network.begin(base, tokens[0], record, 64)
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("UPDATE _upload_sessions SET expires=0")
    start()
    assert network.call(base, "GET", "/api/uploads/" + upload["id"], token=tokens[0])[0] == 404
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT count(*) FROM _upload_payloads").fetchone() == (0,)
    code, replacement = network.begin(base, tokens[0], record, 64)
    assert code == 201
    assert network.call(base, "DELETE", "/api/uploads/" + replacement["id"], token=tokens[0])[0] == 204
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT count(*) FROM _upload_sessions").fetchone() == (0,)
        assert conn.execute("SELECT count(*) FROM _upload_payloads").fetchone() == (0,)


def test_recovery_bounds_precede_cleanup_and_unknown_version_mutations(running):
    base, data, proc, start, log_path = running
    _, tokens, _, record = network.setup(base)
    assert network.begin(base, tokens[0], record)[0] == 201
    kill(proc)
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("UPDATE _upload_sessions SET state='committing',expires=0")
        conn.execute("UPDATE _upload_settings SET version=9000")
    assert start(ready=False).wait(timeout=10) != 0
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT state FROM _upload_sessions").fetchone() == ("committing",)
        conn.execute("UPDATE _upload_settings SET version=2")
        for i in range(4):
            conn.execute("INSERT INTO _upload_sessions SELECT ?,metadata,length,offset,expires,state FROM _upload_sessions LIMIT 1", (f"{i:032x}",))
    assert start(ready=False).wait(timeout=10) != 0
    assert "InvalidUploadStore" in log_path.read_text()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT count(*) FROM _upload_sessions").fetchone() == (5,)


def test_recovery_metadata_budget_counts_bytes_even_after_embedded_nul(running):
    base, data, proc, start, log_path = running
    _, tokens, _, record = network.setup(base)
    assert network.begin(base, tokens[0], record)[0] == 201
    kill(proc)
    oversized = "{}\0" + "x" * 16384
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("UPDATE _upload_sessions SET metadata=?,expires=0", (oversized,))
    assert start(ready=False).wait(timeout=10) != 0
    assert "InvalidUploadStore" in log_path.read_text()
    with sqlite3.connect(data / "data.db") as conn:
        assert conn.execute("SELECT metadata FROM _upload_sessions").fetchone() == (oversized,)


def test_current_auth_constraints_and_concurrency(server):
    network.test_token_revocation_and_current_file_constraints(server)


def test_concurrent_calls(server):
    network.test_concurrent_identical_chunk_and_commit_are_once(server)


def test_current_rule_gate(server):
    network.test_begin_authorizes_before_field_shape_and_record_probes(server, None, 403)


def test_restart_preserves_stable_auth_collection_binding(running):
    base, data, proc, start, _ = running
    _, tokens, _, record = network.setup(base)
    _, upload = network.begin(base, tokens[0], record)
    kill(proc)
    # Preserve the principal and tokenKey deliberately: a name/principal-only
    # binding would incorrectly accept the old session in this replacement.
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("UPDATE _collections SET id='replacementauth' WHERE name='users'")
    start()
    code, fresh = network.call(base, "POST", "/api/collections/users/auth-with-password",
                               {"identity": "one@x.io", "password": "userpassword"})
    assert code == 200, fresh
    assert network.call(base, "GET", "/api/uploads/" + upload["id"], token=fresh["token"])[0] == 404


def test_recovered_upload_commit_checks_current_rules(running):
    base, _, proc, start, _ = running
    admin, tokens, col, record = network.setup(base)
    _, upload = network.begin(base, tokens[0], record)
    path = "/api/uploads/" + upload["id"]
    assert network.call(base, "PATCH", path, b"abcd", tokens[0], 0)[0] == 204
    kill(proc)
    start()
    col["fields"] = col["schema"]
    col["updateRule"] = None
    assert network.call(base, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    assert network.call(base, "POST", path + "/commit", token=tokens[0])[0] == 403
    assert network.call(base, "GET", path, token=tokens[0])[1]["state"] == "failed"
    assert network.call(base, "GET", "/api/upload-probe", token=admin)[1] == {"before": 0, "after": 0}
