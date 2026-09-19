"""Combined tenancy, transactional receipts, and durable replay contracts."""
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess

import pytest

from conftest import _free_port, _stop_server, _su_template_for, _wait_reachable_or_fail
from test_query_workbench import call
from test_rest_idempotency import setup
from test_realtime_backfill import backfill


@pytest.fixture()
def app(tmp_path):
    binary = os.environ.get("ZIGBASE_TEST_REST_REPLAY_BINARY")
    if not binary:
        pytest.skip("requires REST idempotency fixture with durable realtime and tenancy")
    assert Path(binary).is_file()
    shutil.copytree(_su_template_for(binary), tmp_path, dirs_exist_ok=True)
    port = _free_port()
    env = {k: v for k, v in os.environ.items() if not k.startswith("ZIGBASE_")}
    env.update(ZIGBASE_DATA_DIR=str(tmp_path), ZIGBASE_HTTP_PORT=str(port), ZIGBASE_SERVE_BACKGROUND="0")
    log_path = tmp_path / "server.log"
    with log_path.open("wb") as log:
        proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        _wait_reachable_or_fail(proc, port, str(log_path))
        yield f"http://127.0.0.1:{port}", tmp_path / "data.db"
    finally:
        _stop_server(proc)


def test_retries_do_not_duplicate_journal_entries_and_capture_failure_rolls_back_receipt(app):
    base, database = app
    admin, token, _, _ = setup(base)
    path = "/api/collections/posts/records"
    code, checkpoint = backfill(base, topic="posts")
    assert code == 200, checkpoint
    with sqlite3.connect(database) as db:
        db.execute("CREATE TRIGGER reject_journal BEFORE INSERT ON _replay_events BEGIN SELECT RAISE(ABORT,'test journal failure'); END")
    headers = {"Idempotency-Key": "atomic-create"}
    assert call(base, "POST", path, {"title": "atomic"}, token, headers)[0] >= 400
    assert call(base, "GET", path, token=admin)[1]["items"] == []
    with sqlite3.connect(database) as db:
        # The ledger itself may have been rolled back on its first use.
        if db.execute("SELECT 1 FROM sqlite_master WHERE name='_idempotency_receipts'").fetchone():
            assert db.execute("SELECT COUNT(*) FROM _idempotency_receipts").fetchone()[0] == 0
        db.execute("DROP TRIGGER reject_journal")
    created = call(base, "POST", path, {"title": "atomic"}, token, headers)
    assert created[0] == 201, created
    assert call(base, "POST", path, {"title": "atomic"}, token, headers) == created
    rid = created[1]["id"]
    code, events = backfill(base, checkpoint["nextCursor"], topic="posts")
    assert code == 200 and [row["action"] for row in events["items"]] == ["create"], events
    for method, action, body, expected in [("PATCH", "update", {"title": "updated"}, 200), ("DELETE", "delete", None, 204)]:
        checkpoint = events
        headers = {"Idempotency-Key": action + "-once"}
        first = call(base, method, path + "/" + rid, body, token, headers)
        assert first[0] == expected, first
        assert call(base, method, path + "/" + rid, body, token, headers) == first
        code, events = backfill(base, checkpoint["nextCursor"], topic="posts")
        assert code == 200 and [row["action"] for row in events["items"]] == [action], events
        assert events["items"][0]["record"] == {"id": rid}


def test_tenant_stamping_transfer_refusal_and_membership_revocation_on_retry(app):
    base, database = app
    admin, token, user, _ = setup(base)
    with sqlite3.connect(database) as db:
        for account in ("accountA", "accountB"):
            db.execute("INSERT INTO _accounts(id,created,updated,slug) VALUES(?,?,?,?)", (account, "2026-01-01", "2026-01-01", account))
            db.execute("INSERT INTO _memberships(id,created,updated,account,user_collection,user,role,status) VALUES(?,?,?,?,?,?,?,?)",
                       ("member" + account, "2026-01-01", "2026-01-01", account, "users", user["id"], "owner", "active"))
    code, col = call(base, "POST", "/api/collections", {
        "name": "tasks", "type": "base", "createRule": "@public", "viewRule": "@public", "updateRule": "@public", "deleteRule": "@public",
        "options": {"tenant": {"field": "account"}},
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}}, {"id": "", "name": "account", "type": "text", "options": {}}],
    }, admin)
    assert code == 201, col
    path = "/api/collections/tasks/records"
    headers = {"Idempotency-Key": "tenant-create", "X-Account-Id": "accountA"}
    body = {"title": "owned", "account": "accountB"}
    created = call(base, "POST", path, body, token, headers)
    assert created[0] == 201 and created[1]["account"] == "accountA", created
    assert call(base, "POST", path, body, token, headers) == created
    assert call(base, "POST", path, body, token, {**headers, "X-Account-Id": "accountB"})[0] == 409
    target = path + "/" + created[1]["id"]
    assert call(base, "PATCH", target, {"title": "foreign"}, token, {"Idempotency-Key": "foreign", "X-Account-Id": "accountB"})[0] == 404
    assert call(base, "PATCH", target, {"account": "accountB"}, token, {"Idempotency-Key": "move", "X-Account-Id": "accountA"})[0] == 403
    # A deleted row cannot establish current tenant/predicate authorization on replay.
    assert call(base, "DELETE", target, token=token, headers={"Idempotency-Key": "tenant-delete", "X-Account-Id": "accountA"})[0] == 400
    assert call(base, "GET", target, token=admin)[1]["account"] == "accountA"
    with sqlite3.connect(database) as db:
        db.execute("UPDATE _memberships SET status='inactive' WHERE account='accountA'")
    assert call(base, "POST", path, body, token, headers)[0] == 403
    assert len(call(base, "GET", path, token=admin)[1]["items"]) == 1


@pytest.mark.parametrize("body_has_account", [True, False])
def test_tenant_stamp_preserves_original_request_data_on_first_attempt_and_replay(app, body_has_account):
    base, database = app
    admin, token, user, _ = setup(base)
    with sqlite3.connect(database) as db:
        db.execute("INSERT INTO _accounts(id,created,updated,slug) VALUES('accountA','','','accountA')")
        db.execute("INSERT INTO _memberships(id,created,updated,account,user_collection,user,role,status) VALUES('memberA','','','accountA','users',?,'owner','active')", (user["id"],))
    expected = "client-account" if body_has_account else ""
    code, col = call(base, "POST", "/api/collections", {
        "name": "tasks", "type": "base",
        "createRule": f'@request.data.account = "{expected}"', "viewRule": "@public",
        "options": {"tenant": {"field": "account"}},
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}},
                   {"id": "", "name": "account", "type": "text", "options": {}}],
    }, admin)
    assert code == 201, col
    body = {"title": "original input"}
    if body_has_account:
        body["account"] = "client-account"
    path = "/api/collections/tasks/records"
    headers = {"Idempotency-Key": "stamp-policy", "X-Account-Id": "accountA"}
    created = call(base, "POST", path, body, token, headers)
    assert created[0] == 201 and created[1]["account"] == "accountA", created
    assert call(base, "POST", path, body, token, headers) == created
    assert len(call(base, "GET", path, token=admin)[1]["items"]) == 1
