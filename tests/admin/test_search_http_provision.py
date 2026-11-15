"""A collection created or changed over the collections API gets its full-text index (#507).

Before the fix only startup provisioning built the SQLite FTS5 shadow table and its sync
triggers, so `?search=` on a collection created over HTTP answered 500 until the next restart,
and changing which fields are searchable over HTTP left the index stale. These tests drive
create / update (field made searchable, searchable field added, renamed and removed, search
turned off) / delete over HTTP and check both the search results and the catalog.
"""
import json
import os
import shutil
import sqlite3
import subprocess
import urllib.error
import urllib.parse
import urllib.request

import pytest

from conftest import _reserve_port, _stop_server, _su_template_for, _wait_reachable_or_fail


@pytest.fixture()
def app(binary, tmp_path):
    shutil.copytree(_su_template_for(binary), tmp_path, dirs_exist_ok=True)
    with _reserve_port() as port:
        env = {k: v for k, v in os.environ.items() if not k.startswith("ZIGBASE_")}
        env.update(ZIGBASE_DATA_DIR=str(tmp_path), ZIGBASE_HTTP_PORT=str(port), ZIGBASE_SERVE_BACKGROUND="0")
        log_path = tmp_path / "server.log"
        with log_path.open("wb") as log:
            proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            _wait_reachable_or_fail(proc, port, str(log_path))
            base = f"http://127.0.0.1:{port}"
            status, login = call(base, "POST", "/api/collections/_superusers/auth-with-password",
                                 {"identity": "admin@x.io", "password": "adminpassword"})
            assert status == 200, login
            yield base, login["token"], tmp_path / "data.db"
        finally:
            _stop_server(proc)


def call(base, method, path, data=None, token=None):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(base + path, data=body, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read()
        return response.status, json.loads(raw) if raw else None


def search(base, token, name, term):
    """Return (status, sorted titles) for `?search=term` on collection `name`."""
    query = urllib.parse.urlencode({"search": term, "perPage": 50})
    status, body = call(base, "GET", f"/api/collections/{name}/records?{query}", token=token)
    if status != 200:
        return status, body
    return status, sorted(item.get("title") or item.get("headline") for item in body["items"])


def fts_objects(database, name):
    with sqlite3.connect(database) as db:
        rows = db.execute("SELECT name FROM sqlite_master WHERE substr(name,1,length(?1))=?1 ORDER BY name",
                          (f"{name}_fts",)).fetchall()
    return [row[0] for row in rows]


def add(base, token, name, **fields):
    status, rec = call(base, "POST", f"/api/collections/{name}/records", fields, token)
    assert status == 201, rec
    return rec["id"]


def put_fields(base, token, col, fields):
    definition = {key: col[key] for key in ("name", "type", "listRule", "viewRule", "createRule", "updateRule", "deleteRule")}
    definition["fields"] = fields
    status, updated = call(base, "PATCH", f"/api/collections/{col['id']}", definition, token)
    assert status == 200, updated
    return updated


RULES = {"listRule": "@public", "viewRule": "@public", "createRule": "@public", "updateRule": "@public", "deleteRule": "@public"}


def test_collection_created_searchable_over_http_is_searchable(app):
    base, token, database = app
    status, col = call(base, "POST", "/api/collections", {
        "name": "notes", "type": "base", **RULES,
        "fields": [{"id": "", "name": "title", "type": "text", "searchable": True, "options": {}}],
    }, token)
    assert status == 201, col
    assert fts_objects(database, "notes") != []
    add(base, token, "notes", title="alpha one")
    add(base, token, "notes", title="bravo two")
    assert search(base, token, "notes", "alpha") == (200, ["alpha one"])


def test_searchable_fields_changed_over_http_reshape_the_index(app):
    base, token, database = app
    status, col = call(base, "POST", "/api/collections", {
        "name": "notes", "type": "base", **RULES,
        "fields": [
            {"id": "", "name": "title", "type": "text", "options": {}},
            {"id": "", "name": "body", "type": "text", "options": {}},
        ],
    }, token)
    assert status == 201, col
    assert fts_objects(database, "notes") == []
    add(base, token, "notes", title="alpha one", body="bravo one")
    title, body = (dict(field) for field in col["schema"])  # responses name the field list `schema`

    # A field becomes searchable: the existing row is backfilled.
    title["searchable"] = True
    col = put_fields(base, token, col, [title, body])
    assert search(base, token, "notes", "alpha") == (200, ["alpha one"])
    add(base, token, "notes", title="alpha two", body="x")
    assert search(base, token, "notes", "alpha") == (200, ["alpha one", "alpha two"])

    # A second searchable field joins the index.
    body["searchable"] = True
    col = put_fields(base, token, col, [title, body])
    assert search(base, token, "notes", "bravo") == (200, ["alpha one"])

    # The searchable field is renamed: the index follows it, and new writes stay in sync.
    title["name"] = "headline"
    col = put_fields(base, token, col, [title, body])
    assert search(base, token, "notes", "alpha") == (200, ["alpha one", "alpha two"])
    rid = add(base, token, "notes", headline="charlie", body="y")
    assert search(base, token, "notes", "charlie") == (200, ["charlie"])
    status, _ = call(base, "PATCH", f"/api/collections/notes/records/{rid}", {"headline": "delta"}, token)
    assert status == 200
    assert search(base, token, "notes", "charlie") == (200, [])
    assert search(base, token, "notes", "delta") == (200, ["delta"])

    # A searchable field is removed: its text leaves the index.
    col = put_fields(base, token, col, [title])
    assert search(base, token, "notes", "bravo") == (200, [])
    assert search(base, token, "notes", "alpha") == (200, ["alpha one", "alpha two"])

    # Search turned off: the index is dropped and ?search= is refused, not a 500.
    title["searchable"] = False
    col = put_fields(base, token, col, [title])
    assert fts_objects(database, "notes") == []
    status, _ = search(base, token, "notes", "alpha")
    assert status == 400


def test_deleting_a_searchable_collection_drops_its_index(app):
    base, token, database = app
    status, col = call(base, "POST", "/api/collections", {
        "name": "notes", "type": "base", **RULES,
        "fields": [{"id": "", "name": "title", "type": "text", "searchable": True, "options": {}}],
    }, token)
    assert status == 201, col
    add(base, token, "notes", title="alpha")
    assert fts_objects(database, "notes") != []
    status, _ = call(base, "DELETE", f"/api/collections/{col['id']}", token=token)
    assert status == 204
    assert fts_objects(database, "notes") == []
