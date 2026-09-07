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


def test_collection_recreation_and_eviction_require_reset(server):
    token, col = setup(server)
    _, initial = backfill(server)
    for i in range(257):
        status, record = call(server, "POST", "/api/collections/notes/records", {"title": str(i)}, token)
        assert status == 201, record
    assert backfill(server, initial["nextCursor"])[0] == 409
    _, checkpoint = backfill(server)
    assert call(server, "DELETE", "/api/collections/" + col["id"], token=token)[0] == 204
    status, new_col = call(server, "POST", "/api/collections", {"name": "notes", "type": "base", "fields": [], "viewRule": "@public"}, token)
    assert status == 201, new_col
    assert backfill(server, checkpoint["nextCursor"])[0] == 409


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
