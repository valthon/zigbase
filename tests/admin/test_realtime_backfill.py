"""Live opt-in checks: ZIGBASE_TEST_BACKFILL_BINARY must use -Drealtime-backfill=true."""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

import pytest


@pytest.fixture(scope="session")
def binary():
    path = os.environ.get("ZIGBASE_TEST_BACKFILL_BINARY")
    if not path:
        pytest.skip("requires a -Drealtime-backfill=true binary")
    assert os.path.isfile(path), path
    return path


def call(server, method, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(server + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        data = response.read()
        return response.status, json.loads(data) if data else None


def test_request_helper_bounds_stalled_connections(monkeypatch):
    def stalled(request, *, timeout):
        assert timeout == 10
        raise TimeoutError("stalled test connection")

    monkeypatch.setattr(urllib.request, "urlopen", stalled)
    with pytest.raises(TimeoutError, match="stalled test connection"):
        call("http://127.0.0.1:1", "GET", "/api/realtime/backfill?topic=notes")


def setup(server):
    status, auth = call(server, "POST", "/api/collections/_superusers/auth-with-password", {"identity": "admin@x.io", "password": "adminpassword"})
    assert status == 200, auth
    token = auth["token"]
    status, col = call(server, "POST", "/api/collections", {"name": "notes", "type": "base", "fields": [{"id": "", "name": "title", "type": "text", "options": {}}], "viewRule": "@public", "listRule": "@public"}, token)
    assert status == 201, col
    return token, col


def backfill(server, cursor=None, limit=128, token=None, topic="notes"):
    query = {"topic": topic, "limit": limit}
    if cursor is not None:
        query["cursor"] = cursor
    return call(server, "GET", "/api/realtime/backfill?" + urllib.parse.urlencode(query), token=token)


def test_checkpoint_before_snapshot_and_id_only_updates_and_delete(server):
    token, _ = setup(server)
    status, checkpoint = backfill(server)
    assert status == 200 and checkpoint["items"] == []
    status, record = call(server, "POST", "/api/collections/notes/records", {"title": "old private value"}, token)
    assert status == 201, record
    status, _ = call(server, "PATCH", "/api/collections/notes/records/" + record["id"], {"title": "current value"}, token)
    assert status == 200
    status, page = backfill(server, checkpoint["nextCursor"], limit=1)
    assert status == 200 and page["hasNext"]
    assert page["items"] == [{"type": "event", "topic": "notes", "action": "create", "record": {"id": record["id"]}}]
    status, page = backfill(server, page["nextCursor"])
    assert status == 200 and not page["hasNext"]
    assert page["items"][0]["action"] == "update"
    assert page["items"][0]["record"] == {"id": record["id"]}
    status, _ = call(server, "DELETE", "/api/collections/notes/records/" + record["id"], token=token)
    assert status == 204
    status, page = backfill(server, page["nextCursor"])
    assert status == 200
    assert page["items"] == [{"type": "event", "topic": "notes", "action": "delete", "record": {"id": record["id"]}}]


def test_current_rules_hide_retained_delete_and_empty_page_advances(server):
    token, col = setup(server)
    status, users = call(server, "POST", "/api/collections", {"name": "users", "type": "auth", "fields": []}, token)
    assert status == 201, users
    status, user = call(server, "POST", "/api/collections/users/records", {"email": "user@x.io", "password": "userpassword"}, token)
    assert status == 201, user
    status, user_auth = call(server, "POST", "/api/collections/users/auth-with-password", {"identity": "user@x.io", "password": "userpassword"})
    assert status == 200, user_auth
    _, checkpoint = backfill(server)
    _, record = call(server, "POST", "/api/collections/notes/records", {"title": "secret"}, token)
    call(server, "DELETE", "/api/collections/notes/records/" + record["id"], token=token)
    col["viewRule"] = "title = 'no match'"
    col["fields"] = col["schema"]
    status, updated = call(server, "PATCH", "/api/collections/" + col["id"], col, token)
    assert status == 200, updated
    assert backfill(server, checkpoint["nextCursor"])[0] == 403
    status, denied = backfill(server, checkpoint["nextCursor"], token=user_auth["token"])
    assert status == 200 and denied["items"] == [] and not denied["hasNext"]
    assert denied["nextCursor"] != checkpoint["nextCursor"]
    # Authenticated superuser still receives id-only invalidations. A refetch of
    # the earlier create now returns not found, which clients handle as removal.
    status, page = backfill(server, checkpoint["nextCursor"], token=token)
    assert status == 200 and not page["hasNext"]
    assert page["nextCursor"] != checkpoint["nextCursor"]
    assert all(set(item["record"]) == {"id"} for item in page["items"])
    assert backfill(server, page["nextCursor"], token="invalid")[0] == 401
    assert backfill(server, "stale:1", token=token)[0] == 409


def hidden_rule_delete_scenario(server, token, suffix=""):
    """#486 scenario, shared with the durable-journal suite (SQLite and PostgreSQL): a `viewRule`
    that compares a HIDDEN field decides a retained delete from the field's stored value. The
    record a delete hook reads strips hidden fields, so the private authorization snapshot must
    carry it; the value must never reach a backfill item. `suffix` keeps names unique on a shared
    PostgreSQL database."""
    users_name, notes_name = "husers" + suffix, "hnotes" + suffix
    status, users = call(server, "POST", "/api/collections", {"name": users_name, "type": "auth", "fields": []}, token)
    assert status == 201, users
    rule = "owner = @request.auth.id && tier = 'gold-hidden-marker'"
    status, notes = call(server, "POST", "/api/collections", {
        "name": notes_name, "type": "base",
        "fields": [{"id": "", "name": "owner", "type": "text", "options": {}},
                   {"id": "", "name": "tier", "type": "text", "hidden": True, "options": {}}],
        "listRule": rule, "viewRule": rule,
    }, token)
    assert status == 201, notes
    sessions = {}
    for name in ("alice", "bob"):
        email = f"h{name}{suffix}@x.io"
        status, user = call(server, "POST", f"/api/collections/{users_name}/records", {"email": email, "password": name + "password"}, token)
        assert status == 201, user
        status, auth = call(server, "POST", f"/api/collections/{users_name}/auth-with-password", {"identity": email, "password": name + "password"})
        assert status == 200, auth
        sessions[name] = (auth["token"], user["id"])
    (alice, alice_id), (bob, _) = sessions["alice"], sessions["bob"]
    records = f"/api/collections/{notes_name}/records"
    status, alice_checkpoint = backfill(server, token=alice, topic=notes_name)
    assert status == 200, alice_checkpoint
    status, bob_checkpoint = backfill(server, token=bob, topic=notes_name)
    assert status == 200, bob_checkpoint
    status, su_checkpoint = backfill(server, token=token, topic=notes_name)
    assert status == 200, su_checkpoint
    deleted = {}
    for tier in ("gold-hidden-marker", "bronze-hidden-marker"):
        status, row = call(server, "POST", records, {"owner": alice_id, "tier": tier}, token)
        assert status == 201, row
        assert "tier" not in row
        assert call(server, "DELETE", f"{records}/{row['id']}", token=token)[0] == 204
        deleted[tier] = row["id"]

    # Alice owns both rows; only the gold row's delete matches the rule on its hidden value. (The
    # creates are authorized against the current rows, which are gone.)
    status, page = backfill(server, alice_checkpoint["nextCursor"], token=alice, topic=notes_name)
    assert status == 200, page
    assert page["items"] == [{"type": "event", "topic": notes_name, "action": "delete", "record": {"id": deleted["gold-hidden-marker"]}}]
    assert "hidden-marker" not in json.dumps(page)
    status, page = backfill(server, bob_checkpoint["nextCursor"], token=bob, topic=notes_name)
    assert status == 200 and page["items"] == [], page
    # Superusers bypass the rule and still receive only id-only items.
    status, page = backfill(server, su_checkpoint["nextCursor"], token=token, topic=notes_name)
    assert status == 200, page
    assert [item["action"] for item in page["items"]] == ["create", "delete", "create", "delete"]
    assert "hidden-marker" not in json.dumps(page)


def test_retained_delete_with_hidden_rule_field_is_authorized_from_its_stored_value(server):
    """#486: a viewRule on a hidden field decides retained deletes for their owner."""
    token, _ = setup(server)
    hidden_rule_delete_scenario(server, token)


def test_collection_deletion_replacement_and_eviction_require_reset(server):
    token, col = setup(server)
    _, initial = backfill(server)
    for i in range(257):
        status, record = call(server, "POST", "/api/collections/notes/records", {"title": str(i)}, token)
        assert status == 201, record
    assert backfill(server, initial["nextCursor"])[0] == 409
    _, checkpoint = backfill(server)
    assert call(server, "DELETE", "/api/collections/" + col["id"], token=token)[0] == 204
    status, new_col = call(server, "POST", "/api/collections", {"name": "notes", "type": "base", "fields": [], "viewRule": "@public"}, token)
    assert status == 409 and new_col["code"] == "conflict", new_col
    assert backfill(server, checkpoint["nextCursor"])[0] == 404
    status, replacement = call(server, "POST", "/api/collections", {"name": "replacement", "type": "base", "fields": [], "viewRule": "@public"}, token)
    assert status == 201 and replacement["id"] != col["id"], replacement
    assert backfill(server, checkpoint["nextCursor"], topic="replacement")[0] == 409


def test_hot_collection_does_not_reset_or_paginate_quiet_collection(server):
    token, _ = setup(server)
    status, other = call(server, "POST", "/api/collections", {"name": "busy", "type": "base", "fields": [], "viewRule": "@public"}, token)
    assert status == 201, other
    _, checkpoint = backfill(server)
    status, quiet = call(server, "POST", "/api/collections/notes/records", {"title": "quiet"}, token)
    assert status == 201, quiet
    for _ in range(300):
        status, record = call(server, "POST", "/api/collections/busy/records", {}, token)
        assert status == 201, record
    status, page = backfill(server, checkpoint["nextCursor"], limit=1)
    assert status == 200 and not page["hasNext"], page
    assert [item["record"] for item in page["items"]] == [{"id": quiet["id"]}]
    status, empty = backfill(server, page["nextCursor"], limit=1)
    assert status == 200 and empty["items"] == [] and not empty["hasNext"]


def test_checkpoint_reads_do_not_displace_slots_but_writes_can(server):
    token, _ = setup(server)
    _, checkpoint = backfill(server)
    status, quiet = call(server, "POST", "/api/collections/notes/records", {"title": "retained"}, token)
    assert status == 201, quiet
    for i in range(16):
        name = f"topic{i}"
        status, collection = call(server, "POST", "/api/collections", {"name": name, "type": "base", "fields": [], "viewRule": "@public"}, token)
        assert status == 201, collection
        assert backfill(server, topic=name)[0] == (200 if i < 15 else 409)
    for _ in range(3):
        status, full = backfill(server, topic="topic15")
        assert status == 409 and full == {"resetRequired": True, "items": [], "nextCursor": None, "hasNext": False}
    status, page = backfill(server, checkpoint["nextCursor"])
    assert status == 200 and [item["record"] for item in page["items"]] == [{"id": quiet["id"]}]
    # Make notes oldest again, then prove an actual write can replace its slot.
    for i in range(15):
        assert backfill(server, topic=f"topic{i}")[0] == 200
    assert call(server, "POST", "/api/collections/topic15/records", {}, token)[0] == 201
    assert backfill(server, checkpoint["nextCursor"])[0] == 409
    assert backfill(server)[0] == 409  # reads cannot displace a slot to recover
    assert call(server, "POST", "/api/collections/notes/records", {"title": "new slot"}, token)[0] == 201
    assert backfill(server)[0] == 200
    assert backfill(server, checkpoint["nextCursor"])[0] == 409


def test_large_delete_snapshot_resets_only_its_collection(server):
    token, _ = setup(server)
    status, other = call(server, "POST", "/api/collections", {"name": "quiet", "type": "base", "fields": [], "viewRule": "@public"}, token)
    assert status == 201, other
    _, unaffected = backfill(server, topic="quiet")
    for _ in range(2):
        _, checkpoint = backfill(server)
        status, record = call(server, "POST", "/api/collections/notes/records", {"title": "x" * (70 * 1024)}, token)
        assert status == 201, record
        # The large create remains an id-only invalidation and fits the buffer.
        status, page = backfill(server, checkpoint["nextCursor"])
        assert status == 200 and page["items"][0]["record"] == {"id": record["id"]}
        assert call(server, "DELETE", "/api/collections/notes/records/" + record["id"], token=token)[0] == 204
        for cursor in (checkpoint["nextCursor"], page["nextCursor"]):
            status, reset = backfill(server, cursor)
            assert status == 409 and reset["resetRequired"]
        status, quiet = backfill(server, unaffected["nextCursor"], topic="quiet")
        assert status == 200 and quiet["items"] == [] and not quiet["hasNext"]


def relation_delete_scenario(server, token, suffix=""):
    """#499 scenario, shared with the durable-journal suite (SQLite and PostgreSQL). Creates an auth
    collection, two signed-in users, and a collection whose `owner` is a RELATION to the users under
    `owner = @request.auth.id`. Bob creates and deletes a row between both users' checkpoints;
    Alice then creates her own. `suffix` keeps names unique on a shared PostgreSQL database."""
    users_name, owned_name = "users" + suffix, "owned" + suffix
    status, users = call(server, "POST", "/api/collections", {"name": users_name, "type": "auth", "fields": []}, token)
    assert status == 201, users
    rule = "owner = @request.auth.id"
    status, owned = call(server, "POST", "/api/collections", {
        "name": owned_name, "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}},
                   {"id": "", "name": "owner", "type": "relation", "options": {"targetCollectionId": users["id"], "maxSelect": 1}}],
        "listRule": rule, "viewRule": rule, "createRule": rule, "deleteRule": rule,
    }, token)
    assert status == 201, owned
    sessions = {}
    for name in ("alice", "bob"):
        email = f"{name}{suffix}@x.io"
        status, user = call(server, "POST", f"/api/collections/{users_name}/records", {"email": email, "password": name + "password"}, token)
        assert status == 201, user
        status, auth = call(server, "POST", f"/api/collections/{users_name}/auth-with-password", {"identity": email, "password": name + "password"})
        assert status == 200, auth
        sessions[name] = (auth["token"], user["id"])
    (alice, alice_id), (bob, bob_id) = sessions["alice"], sessions["bob"]
    records = f"/api/collections/{owned_name}/records"

    status, alice_checkpoint = backfill(server, token=alice, topic=owned_name)
    assert status == 200, alice_checkpoint
    status, bob_checkpoint = backfill(server, token=bob, topic=owned_name)
    assert status == 200, bob_checkpoint
    status, row = call(server, "POST", records, {"title": "b-row", "owner": bob_id}, bob)
    assert status == 201, row
    assert call(server, "DELETE", f"{records}/{row['id']}", token=bob)[0] == 204
    status, own = call(server, "POST", records, {"title": "a-row", "owner": alice_id}, alice)
    assert status == 201, own

    # Alice: 200, Bob's create and delete are invisible, and her own later create arrives.
    for _ in range(2):  # a retry of the same checkpoint answers the same
        status, page = backfill(server, alice_checkpoint["nextCursor"], token=alice, topic=owned_name)
        assert status == 200, page
        assert page["items"] == [{"type": "event", "topic": owned_name, "action": "create", "record": {"id": own["id"]}}]
        assert not page["hasNext"]
    # Bob (the owner): his own delete, id-only. (His earlier create is authorized against the current
    # row, which is gone, so only the delete — authorized against its snapshot — is replayed.)
    status, page = backfill(server, bob_checkpoint["nextCursor"], token=bob, topic=owned_name)
    assert status == 200, page
    assert page["items"] == [{"type": "event", "topic": owned_name, "action": "delete", "record": {"id": row["id"]}}]
    assert "b-row" not in json.dumps(page)


def test_retained_delete_on_relation_collection_is_authorized_per_item(server):
    """#499: a retained delete snapshot on a collection with a relation field used to make every
    row-constrained replay of a checkpoint spanning it answer 500, on every retry. Now the delete is
    authorized per item: hidden from callers who could not view the row, delivered to its owner."""
    token, _ = setup(server)
    relation_delete_scenario(server, token)


def cascade_owner_scenario(server, token, suffix=""):
    """#489 scenario, shared with the durable-journal suite (SQLite and PostgreSQL). Alice and Bob
    each own a row that cascades from one project and a row whose project relation the database
    sets to null. A superuser deletes the project; each user's replay holds the delete and the
    update for their own rows only, id-only. `suffix` keeps names unique on a shared database."""
    users_name, projects_name = "users" + suffix, "projects" + suffix
    owned_name, assigned_name = "owned" + suffix, "assigned" + suffix
    status, users = call(server, "POST", "/api/collections", {"name": users_name, "type": "auth", "fields": []}, token)
    assert status == 201, users
    status, projects = call(server, "POST", "/api/collections", {"name": projects_name, "type": "base", "fields": []}, token)
    assert status == 201, projects
    rule = "owner = @request.auth.id"
    for name, cascade in ((owned_name, True), (assigned_name, False)):
        status, col = call(server, "POST", "/api/collections", {
            "name": name, "type": "base", "listRule": rule, "viewRule": rule,
            "fields": [{"id": "", "name": "label", "type": "text", "options": {}},
                       {"id": "", "name": "owner", "type": "relation", "options": {"targetCollectionId": users["id"], "maxSelect": 1}},
                       {"id": "", "name": "project", "type": "relation",
                        "options": {"targetCollectionId": projects["id"], "cascadeDelete": cascade, "maxSelect": 1}}],
        }, token)
        assert status == 201, col
    status, project = call(server, "POST", f"/api/collections/{projects_name}/records", {}, token)
    assert status == 201, project
    sessions, rows = {}, {}
    for name in ("alice", "bob"):
        email = f"cascade-{name}{suffix}@x.io"
        status, user = call(server, "POST", f"/api/collections/{users_name}/records", {"email": email, "password": name + "password"}, token)
        assert status == 201, user
        status, auth = call(server, "POST", f"/api/collections/{users_name}/auth-with-password", {"identity": email, "password": name + "password"})
        assert status == 200, auth
        sessions[name] = auth["token"]
        for topic in (owned_name, assigned_name):
            status, row = call(server, "POST", f"/api/collections/{topic}/records",
                               {"label": name + "-secret", "owner": user["id"], "project": project["id"]}, token)
            assert status == 201, row
            rows[(name, topic)] = row["id"]
    checkpoints = {}
    for name in ("alice", "bob"):
        for topic in (owned_name, assigned_name):
            status, checkpoint = backfill(server, token=sessions[name], topic=topic)
            assert status == 200, checkpoint
            checkpoints[(name, topic)] = checkpoint["nextCursor"]

    assert call(server, "DELETE", f"/api/collections/{projects_name}/records/{project['id']}", token=token)[0] == 204

    for name in ("alice", "bob"):
        for topic, action in ((owned_name, "delete"), (assigned_name, "update")):
            for _ in range(2):  # a retry of the same checkpoint answers the same
                status, page = backfill(server, checkpoints[(name, topic)], token=sessions[name], topic=topic)
                assert status == 200, page
                assert page["items"] == [{"type": "event", "topic": topic, "action": action, "record": {"id": rows[(name, topic)]}}], (name, page)
                assert "secret" not in json.dumps(page)
    # The database did both actions; the nulled relation reads back as null.
    assert call(server, "GET", f"/api/collections/{owned_name}/records/{rows[('alice', owned_name)]}", token=token)[0] == 404
    status, kept = call(server, "GET", f"/api/collections/{assigned_name}/records/{rows[('alice', assigned_name)]}", token=token)
    assert status == 200 and kept["project"] is None and kept["label"] == "alice-secret", kept


def test_fk_cascade_replay_is_authorized_per_item(server):
    """#489: rows the database deleted or nulled through a foreign key are retained as delete and
    update events, each replayed only to callers whose rule admits that row."""
    token, _ = setup(server)
    cascade_owner_scenario(server, token)
