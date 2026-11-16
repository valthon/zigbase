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

from conftest import _reserve_port, _stop_server, _su_template_for, _wait_reachable_or_fail
from test_realtime_backfill import backfill, call, cascade_owner_scenario, hidden_cursor_scenario, hidden_paging_scenario, hidden_rule_delete_scenario, relation_delete_scenario, setup
from test_realtime_backfill import (
    test_checkpoint_before_snapshot_and_id_only_updates_and_delete,
    test_current_rules_hide_retained_delete_and_empty_page_advances,
    test_fk_cascade_replay_is_authorized_per_item,
    test_cursor_does_not_count_hidden_writes,
    test_page_count_and_has_next_do_not_count_hidden_writes,
    test_retained_delete_on_relation_collection_is_authorized_per_item,
    test_retained_delete_with_hidden_rule_field_is_authorized_from_its_stored_value,
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
    with _reserve_port() as port:
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


def test_postgres_retained_delete_with_hidden_rule_field(binary, tmp_path):
    """#486 on the PostgreSQL durable journal: a hidden rule field rides the private snapshot."""
    url = os.environ.get("ZIGBASE_PG_TEST_URL")
    if not url:
        pytest.skip("requires disposable PostgreSQL database and -Dpostgres=true binary")
    suffix = "_" + uuid.uuid4().hex[:10]
    identity = "hid" + suffix + "@x.io"
    extra = {"ZIGBASE_DB_URL": url, "ZIGBASE_JWT_SECRET": "durable-replay-test-shared-secret-32bytes"}
    subprocess.run([binary, "superuser", "create", "--email", identity, "--password", "adminpassword"],
                   env={**os.environ, **extra, "ZIGBASE_DATA_DIR": str(tmp_path)},
                   check=True, capture_output=True, timeout=30)
    with running(binary, tmp_path, extra) as server:
        code, auth = call(server, "POST", "/api/collections/_superusers/auth-with-password", {"identity": identity, "password": "adminpassword"})
        assert code == 200, auth
        hidden_rule_delete_scenario(server, auth["token"], suffix)


def test_postgres_retained_delete_on_relation_collection(binary, tmp_path):
    """#499 on the PostgreSQL durable journal (the only PostgreSQL backfill)."""
    url = os.environ.get("ZIGBASE_PG_TEST_URL")
    if not url:
        pytest.skip("requires disposable PostgreSQL database and -Dpostgres=true binary")
    suffix = "_" + uuid.uuid4().hex[:10]
    identity = "rel" + suffix + "@x.io"
    extra = {"ZIGBASE_DB_URL": url, "ZIGBASE_JWT_SECRET": "durable-replay-test-shared-secret-32bytes"}
    subprocess.run([binary, "superuser", "create", "--email", identity, "--password", "adminpassword"],
                   env={**os.environ, **extra, "ZIGBASE_DATA_DIR": str(tmp_path)},
                   check=True, capture_output=True, timeout=30)
    with running(binary, tmp_path, extra) as server:
        code, auth = call(server, "POST", "/api/collections/_superusers/auth-with-password", {"identity": identity, "password": "adminpassword"})
        assert code == 200, auth
        relation_delete_scenario(server, auth["token"], suffix)


def test_postgres_fk_cascade_replay_is_authorized_per_item(binary, tmp_path):
    """#489 on the PostgreSQL durable journal: row-constrained replay of FK-cascaded deletes and
    SET NULL updates (the snapshot travels through the PostgreSQL snapshot store)."""
    url = os.environ.get("ZIGBASE_PG_TEST_URL")
    if not url:
        pytest.skip("requires disposable PostgreSQL database and -Dpostgres=true binary")
    suffix = "_" + uuid.uuid4().hex[:10]
    identity = "cas" + suffix + "@x.io"
    extra = {"ZIGBASE_DB_URL": url, "ZIGBASE_JWT_SECRET": "durable-replay-test-shared-secret-32bytes"}
    subprocess.run([binary, "superuser", "create", "--email", identity, "--password", "adminpassword"],
                   env={**os.environ, **extra, "ZIGBASE_DATA_DIR": str(tmp_path)},
                   check=True, capture_output=True, timeout=30)
    with running(binary, tmp_path, extra) as server:
        code, auth = call(server, "POST", "/api/collections/_superusers/auth-with-password", {"identity": identity, "password": "adminpassword"})
        assert code == 200, auth
        cascade_owner_scenario(server, auth["token"], suffix)


def test_fk_cascade_and_set_null_are_journaled_with_the_delete(binary, tmp_path):
    """#489: deleting a parent journals a delete for each FK-cascaded row and an update for each
    row the database set to null, in the delete's transaction. Controls: a REST delete and a
    REST update on the same collections."""
    shutil.copytree(_su_template_for(binary), tmp_path, dirs_exist_ok=True)
    with running(binary, tmp_path) as server:
        token, notes = setup(server)
        public = {"listRule": "@public", "viewRule": "@public"}
        for name, cascade in (("items", True), ("tasks", False)):
            code, col = call(server, "POST", "/api/collections", {"name": name, "type": "base", "fields": [
                {"id": "", "name": "note", "type": "relation",
                 "options": {"targetCollectionId": notes["id"], "cascadeDelete": cascade, "maxSelect": 1}},
                {"id": "", "name": "label", "type": "text", "options": {}}], **public}, token)
            assert code == 201, col
        note = call(server, "POST", "/api/collections/notes/records", {"title": "N"}, token)[1]["id"]
        item, item2 = (call(server, "POST", "/api/collections/items/records", {"note": note}, token)[1]["id"] for _ in range(2))
        task = call(server, "POST", "/api/collections/tasks/records", {"note": note}, token)[1]["id"]
        task2 = call(server, "POST", "/api/collections/tasks/records", {"label": "unrelated"}, token)[1]["id"]
        checkpoints = {topic: backfill(server, topic=topic)[1]["nextCursor"] for topic in ("items", "tasks")}
        assert call(server, "DELETE", "/api/collections/items/records/" + item2, token=token)[0] == 204
        assert call(server, "PATCH", "/api/collections/tasks/records/" + task2, {"label": "control"}, token)[0] == 200
        assert call(server, "DELETE", "/api/collections/notes/records/" + note, token=token)[0] == 204
        code, replay = backfill(server, checkpoints["items"], topic="items")
        assert code == 200, replay
        assert [(i["action"], i["record"]["id"]) for i in replay["items"]] == [("delete", item2), ("delete", item)]
        code, replay = backfill(server, checkpoints["tasks"], topic="tasks")
        assert code == 200, replay
        assert [(i["action"], i["record"]["id"]) for i in replay["items"]] == [("update", task2), ("update", task)]
        assert call(server, "GET", "/api/collections/items/records/" + item, token=token)[0] == 404
        assert call(server, "GET", "/api/collections/tasks/records/" + task, token=token)[1]["note"] is None


def test_postgres_fk_cascade_replay_across_instances(binary, tmp_path):
    """#489 on PostgreSQL: a parent delete on one instance journals the FK-cascaded delete and
    the SET NULL update; another instance replays both."""
    url = os.environ.get("ZIGBASE_PG_TEST_URL")
    if not url:
        pytest.skip("requires disposable PostgreSQL database and -Dpostgres=true binary")
    identity = "cascade-" + uuid.uuid4().hex + "@x.io"
    prefix = "fk" + uuid.uuid4().hex[:10]
    notes, items, tasks = (f"{prefix}_{n}" for n in ("notes", "items", "tasks"))
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
        public = {"listRule": "@public", "viewRule": "@public"}
        code, notes_col = call(first, "POST", "/api/collections", {"name": notes, "type": "base", "fields": [], **public}, token)
        assert code == 201, notes_col
        created = []
        for name, cascade in ((items, True), (tasks, False)):
            code, col = call(first, "POST", "/api/collections", {"name": name, "type": "base", "fields": [
                {"id": "", "name": "note", "type": "relation",
                 "options": {"targetCollectionId": notes_col["id"], "cascadeDelete": cascade, "maxSelect": 1}}], **public}, token)
            assert code == 201, col
            created.append(col)
        note = call(first, "POST", f"/api/collections/{notes}/records", {}, token)[1]["id"]
        item = call(first, "POST", f"/api/collections/{items}/records", {"note": note}, token)[1]["id"]
        task = call(first, "POST", f"/api/collections/{tasks}/records", {"note": note}, token)[1]["id"]
        checkpoints = {topic: backfill(second, topic=topic)[1]["nextCursor"] for topic in (items, tasks)}
        assert call(first, "DELETE", f"/api/collections/{notes}/records/{note}", token=token)[0] == 204
        code, replay = backfill(second, checkpoints[items], topic=items)
        assert code == 200 and [(i["action"], i["record"]["id"]) for i in replay["items"]] == [("delete", item)], replay
        code, replay = backfill(second, checkpoints[tasks], topic=tasks)
        assert code == 200 and [(i["action"], i["record"]["id"]) for i in replay["items"]] == [("update", task)], replay
        assert call(second, "GET", f"/api/collections/{tasks}/records/{task}", token=token)[1]["note"] is None
        for col in created + [notes_col]:
            assert call(first, "DELETE", "/api/collections/" + col["id"], token=token)[0] == 204


def test_postgres_hidden_writes_change_neither_cursor_nor_paging(binary, tmp_path):
    """#496/#501 on the PostgreSQL durable journal: another user's writes the caller may not see
    change neither the shape of its cursor nor its page count and `hasNext`."""
    url = os.environ.get("ZIGBASE_PG_TEST_URL")
    if not url:
        pytest.skip("requires disposable PostgreSQL database and -Dpostgres=true binary")
    suffix = "_" + uuid.uuid4().hex[:10]
    identity = "hidden" + suffix + "@x.io"
    extra = {"ZIGBASE_DB_URL": url, "ZIGBASE_JWT_SECRET": "durable-replay-test-shared-secret-32bytes"}
    subprocess.run([binary, "superuser", "create", "--email", identity, "--password", "adminpassword"],
                   env={**os.environ, **extra, "ZIGBASE_DATA_DIR": str(tmp_path)},
                   check=True, capture_output=True, timeout=30)
    with running(binary, tmp_path, extra) as server:
        code, auth = call(server, "POST", "/api/collections/_superusers/auth-with-password", {"identity": identity, "password": "adminpassword"})
        assert code == 200, auth
        hidden_cursor_scenario(server, auth["token"], suffix)
        hidden_paging_scenario(server, auth["token"], suffix)


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
