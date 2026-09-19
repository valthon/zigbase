"""Transactional replay survives process replacement; shared delivery authorization."""
import contextlib
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import uuid

import pytest

from conftest import _free_port, _stop_server, _su_template_for, _wait_reachable_or_fail
from test_realtime_backfill import backfill, call, setup
from test_realtime_backfill import (
    test_checkpoint_before_snapshot_and_id_only_updates_and_delete,
    test_current_rules_hide_retained_delete_and_empty_page_advances,
)


@pytest.fixture(scope="session")
def binary():
    path = os.environ.get("ZIGBASE_TEST_DURABLE_REALTIME_BINARY")
    if not path:
        pytest.skip("requires -Ddurable-realtime=true")
    assert pathlib.Path(path).is_file()
    return path


@contextlib.contextmanager
def running(binary, data, extra_env=None):
    port = _free_port()
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(data), "ZIGBASE_HTTP_PORT": str(port),
           "ZIGBASE_SERVE_BACKGROUND": "0", **(extra_env or {})}
    log_path = data / "server.log"
    with log_path.open("wb") as log:
        proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env,
                                stdout=log, stderr=subprocess.STDOUT)
    try:
        _wait_reachable_or_fail(proc, port, str(log_path))
        yield f"http://127.0.0.1:{port}"
    finally:
        _stop_server(proc)


def test_restart_retains_cursor_and_authorization(binary, tmp_path):
    shutil.copytree(_su_template_for(binary), tmp_path, dirs_exist_ok=True)
    with running(binary, tmp_path) as first:
        token, col = setup(first)
        _, initial = backfill(first)
        code, record = call(first, "POST", "/api/collections/notes/records", {"title": "private snapshot"}, token)
        assert code == 201, record
        assert call(first, "DELETE", "/api/collections/notes/records/" + record["id"], token=token)[0] == 204
    with running(binary, tmp_path) as second:
        code, replay = backfill(second, initial["nextCursor"])
        assert code == 200, replay
        assert replay["items"][-1] == {"type": "event", "topic": "notes", "action": "delete", "record": {"id": record["id"]}}
        assert "private snapshot" not in str(replay)
        col["viewRule"] = None
        col["fields"] = col["schema"]
        assert call(second, "PATCH", "/api/collections/" + col["id"], col, token)[0] == 200
        assert backfill(second, initial["nextCursor"])[0] == 403
        assert backfill(second, initial["nextCursor"], token=token)[0] == 200


def test_capture_failure_rolls_back_record_and_expiry_requires_reset(binary, tmp_path):
    shutil.copytree(_su_template_for(binary), tmp_path, dirs_exist_ok=True)
    with running(binary, tmp_path) as server:
        token, _ = setup(server)
        _, initial = backfill(server)
        databases = list(tmp_path.glob("*.db"))
        assert len(databases) == 1, databases
        with sqlite3.connect(databases[0]) as db:
            db.execute("CREATE TRIGGER reject_replay BEFORE INSERT ON _replay_events BEGIN SELECT RAISE(ABORT,'test journal unavailable'); END")
        code, _ = call(server, "POST", "/api/collections/notes/records", {"title": "must roll back"}, token)
        assert code == 500
        assert call(server, "GET", "/api/collections/notes/records", token=token)[1]["items"] == []
        assert backfill(server, initial["nextCursor"])[1]["items"] == []
        with sqlite3.connect(databases[0]) as db:
            db.execute("DROP TRIGGER reject_replay")
        code, record = call(server, "POST", "/api/collections/notes/records", {"title": "commits"}, token)
        assert code == 201, record
        with sqlite3.connect(databases[0]) as db:
            db.execute("CREATE TRIGGER reject_replay BEFORE INSERT ON _replay_events BEGIN SELECT RAISE(ABORT,'test journal unavailable'); END")
        endpoint = "/api/collections/notes/records/" + record["id"]
        assert call(server, "PATCH", endpoint, {"title": "must roll back"}, token)[0] == 500
        assert call(server, "DELETE", endpoint, token=token)[0] == 500
        assert call(server, "GET", endpoint, token=token)[1]["title"] == "commits"
        with sqlite3.connect(databases[0]) as db:
            db.execute("DROP TRIGGER reject_replay")
            db.execute("UPDATE _replay_events SET expires=0")
        assert backfill(server, initial["nextCursor"])[0] == 409
        assert backfill(server)[0] == 200


def test_postgres_cross_instance_replay(binary, tmp_path):
    url = os.environ.get("ZIGBASE_PG_TEST_URL")
    if not url:
        pytest.skip("requires disposable PostgreSQL database and -Dpostgres=true binary")
    identity = "replay-" + uuid.uuid4().hex + "@x.io"
    topic = "replay_" + uuid.uuid4().hex[:12]
    first_dir, second_dir = tmp_path / "first", tmp_path / "second"
    first_dir.mkdir()
    second_dir.mkdir()
    extra = {"ZIGBASE_DB_URL": url, "ZIGBASE_JWT_SECRET": "durable-replay-test-shared-secret-32bytes"}
    subprocess.run([binary, "superuser", "create", "--email", identity, "--password", "adminpassword"],
                   env={**os.environ, **extra, "ZIGBASE_DATA_DIR": str(first_dir)},
                   check=True, capture_output=True, timeout=30)
    with running(binary, first_dir, extra) as first, running(binary, second_dir, extra) as second:
        code, auth = call(first, "POST", "/api/collections/_superusers/auth-with-password", {"identity": identity, "password": "adminpassword"})
        assert code == 200, auth
        token = auth["token"]
        code, col = call(first, "POST", "/api/collections", {"name": topic, "type": "base", "fields": [], "viewRule": "@public"}, token)
        assert code == 201, col
        code, initial = backfill(second, topic=topic)
        assert code == 200, initial
        assert initial["retention"]["maxEntries"] == 4096
        assert call(second, "GET", "/api/meta")[1]["capabilities"]["durableRealtime"] is True
        code, rec = call(first, "POST", f"/api/collections/{topic}/records", {}, token)
        assert code == 201, rec
        code, replay = backfill(second, initial["nextCursor"], topic=topic)
        assert code == 200 and len(replay["items"]) == 1, replay
        assert replay["items"][0]["record"] == {"id": rec["id"]}
        assert call(first, "DELETE", f"/api/collections/{topic}/records/{rec['id']}", token=token)[0] == 204
        code, deleted = backfill(second, replay["nextCursor"], topic=topic)
        assert code == 200 and deleted["items"][0]["action"] == "delete", deleted
        assert call(first, "DELETE", "/api/collections/" + col["id"], token=token)[0] == 204
        assert backfill(second, initial["nextCursor"], topic=topic)[0] == 404


def test_retained_frame_over_current_budget_returns_reset_without_partial_page(binary, tmp_path):
    """An older writer's larger retained frame is recoverable after lowering budgets."""
    shutil.copytree(_su_template_for(binary), tmp_path, dirs_exist_ok=True)
    with running(binary, tmp_path) as server:
        token, _ = setup(server)
        code, initial = backfill(server)
        assert code == 200
        for title in ("fits current budget", "older larger frame"):
            code, record = call(server, "POST", "/api/collections/notes/records", {"title": title}, token)
            assert code == 201, record
        databases = list(tmp_path.glob("*.db"))
        assert len(databases) == 1, databases
        # Seed the on-disk state a previous build with a larger frame allowance
        # could leave. The reader must reject before buffering or decoding it.
        oversized = json.dumps({"type": "event", "topic": "notes", "action": "delete", "record": {
            "id": record["id"], "_deleteSnapshot": {"id": record["id"],
            "title": "x" * initial["retention"]["maxFrameBytes"]}}})
        with sqlite3.connect(databases[0]) as db:
            db.execute("UPDATE _replay_events SET frame=?,bytes=? WHERE sequence=(SELECT MAX(sequence) FROM _replay_events)",
                       (oversized, len(oversized)))
        code, reset = backfill(server, initial["nextCursor"])
        assert code == 409
        assert reset == {"resetRequired": True, "items": [], "nextCursor": None, "hasNext": False}
        # No partial first item/cursor escapes. A new checkpoint plus REST reload
        # recovers without getting stuck on the retained oversized frame.
        code, fresh = backfill(server)
        assert code == 200 and fresh["items"] == []
        assert len(call(server, "GET", "/api/collections/notes/records", token=token)[1]["items"]) == 2
        code, record = call(server, "POST", "/api/collections/notes/records", {"title": "new event"}, token)
        assert code == 201, record
        code, replay = backfill(server, fresh["nextCursor"])
        assert code == 200 and [item["record"] for item in replay["items"]] == [{"id": record["id"]}]
