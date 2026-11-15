"""Full-text search ranking must not depend on another tenant's rows (#495).

On SQLite the FTS5 shadow table indexes every tenant's rows of a collection. Ranking with
bm25 made the ORDER of one tenant's (correctly scoped) results move with the text other
tenants stored, so a member could rank two of their own records and learn whether another
tenant's searchable text contained a word. Search now ranks with a row-local score; these
tests replay the issue's repros over HTTP with real tenancy (`X-Account-Id`) and require
byte-identical responses whatever the other tenant stores.

The other tenant's text is changed IN PLACE (PATCH) rather than on a fresh data dir, so both
responses see the same record ids — ties are broken by id, and fresh ids would make two
fresh-dir runs differ by chance, not by leak.
"""
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import urllib.error
import urllib.request

import pytest

from _bin import resolve_binary
from conftest import _reserve_port, _stop_server, _su_template_for, _wait_reachable_or_fail

REPO = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def tenancy_binary():
    # dating-server enables tenancy (auth collection `profiles`); the stock binary does not.
    return resolve_binary("ZIGBASE_TEST_DATING_BINARY", REPO, "dating-server")


@pytest.fixture()
def app(tenancy_binary, tmp_path):
    shutil.copytree(_su_template_for(tenancy_binary), tmp_path, dirs_exist_ok=True)
    with _reserve_port() as port:
        env = {k: v for k, v in os.environ.items() if not k.startswith("ZIGBASE_")}
        env.update(ZIGBASE_DATA_DIR=str(tmp_path), ZIGBASE_HTTP_PORT=str(port), ZIGBASE_SERVE_BACKGROUND="0")
        log_path = tmp_path / "server.log"
        with log_path.open("wb") as log:
            proc = subprocess.Popen([tenancy_binary, "serve", "--insecure-cookies"], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            _wait_reachable_or_fail(proc, port, str(log_path))
            yield f"http://127.0.0.1:{port}", tmp_path / "data.db"
        finally:
            _stop_server(proc)


def call(base, method, path, data=None, token=None, account=None):
    """Return (status, raw body bytes)."""
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if account:
        headers["X-Account-Id"] = account
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
        return response.status, response.read()


def call_json(*args, **kwargs):
    status, raw = call(*args, **kwargs)
    return status, json.loads(raw) if raw else None


def two_tenants(base, database):
    """Two members of two accounts and a tenant-owned, searchable `memos` collection."""
    status, login = call_json(base, "POST", "/api/collections/_superusers/auth-with-password",
                              {"identity": "admin@x.io", "password": "adminpassword"})
    assert status == 200, login
    admin = login["token"]
    tokens = {}
    for name in ("a", "b"):
        email = f"{name}@example.com"
        status, user = call_json(base, "POST", "/api/collections/profiles/records",
                                 {"email": email, "password": "password12345", "passwordConfirm": "password12345"}, admin)
        assert status == 201, user
        with sqlite3.connect(database) as db:
            db.execute("INSERT INTO _accounts(id,created,updated,slug) VALUES(?,?,?,?)", (f"acct-{name}", "2026-01-01", "2026-01-01", f"acct-{name}"))
            db.execute("INSERT INTO _memberships(id,created,updated,account,user_collection,user,role,status) VALUES(?,?,?,?,?,?,?,?)",
                       (f"member-{name}", "2026-01-01", "2026-01-01", f"acct-{name}", "profiles", user["id"], "owner", "active"))
        status, auth = call_json(base, "POST", "/api/collections/profiles/auth-with-password",
                                 {"identity": email, "password": "password12345"})
        assert status == 200, auth
        tokens[name] = auth["token"]
    authed = '@request.auth.id != ""'
    status, col = call_json(base, "POST", "/api/collections", {
        "name": "memos", "type": "base",
        "listRule": "@public", "viewRule": "@public", "createRule": authed, "updateRule": authed,
        "options": {"tenant": {"field": "account"}},
        "fields": [
            {"id": "", "name": "account", "type": "text", "options": {}},
            {"id": "", "name": "title", "type": "text", "searchable": True, "options": {}},
        ],
    }, admin)
    assert status == 201, col
    provision_search_index(database)
    return tokens


def provision_search_index(database):
    """Create the engine's FTS5 objects for `memos` (same DDL as `fts.ensureIndexSqliteImpl`).

    A collection created over HTTP is not search-provisioned today (only startup provisioning
    of comptime collections and `provisionMetadata` call `fts.ensureIndex`), and the only
    tenancy-enabled fixture with no extra build flags (dating-server) has no tenant-owned
    searchable collection. Under test here is the READ path — ranking over a shared index with
    real HTTP tenancy — so the index is built directly, before any row exists.
    """
    with sqlite3.connect(database) as db:
        db.executescript("""
            CREATE VIRTUAL TABLE "memos_fts" USING fts5("title", content="memos");
            CREATE TRIGGER "memos_fts_ai" AFTER INSERT ON "memos" BEGIN
              INSERT INTO "memos_fts"(rowid, "title") VALUES (new.rowid, new."title"); END;
            CREATE TRIGGER "memos_fts_ad" AFTER DELETE ON "memos" BEGIN
              INSERT INTO "memos_fts"("memos_fts", rowid, "title") VALUES ('delete', old.rowid, old."title"); END;
            CREATE TRIGGER "memos_fts_au" AFTER UPDATE ON "memos" BEGIN
              INSERT INTO "memos_fts"("memos_fts", rowid, "title") VALUES ('delete', old.rowid, old."title");
              INSERT INTO "memos_fts"(rowid, "title") VALUES (new.rowid, new."title"); END;
        """)


def create(base, tokens, tenant, title):
    status, rec = call_json(base, "POST", "/api/collections/memos/records", {"title": title}, tokens[tenant], f"acct-{tenant}")
    assert status == 201, rec
    assert rec["account"] == f"acct-{tenant}", rec
    return rec["id"]


def retitle(base, tokens, tenant, rid, title):
    status, rec = call_json(base, "PATCH", f"/api/collections/memos/records/{rid}", {"title": title}, tokens[tenant], f"acct-{tenant}")
    assert status == 200, rec


def search_a(base, tokens, query):
    status, raw = call(base, "GET", f"/api/collections/memos/records?search={query}&fields=title", token=tokens["a"], account="acct-a")
    assert status == 200, raw
    assert json.loads(raw)["totalItems"] == 2, raw
    return raw


def test_other_tenants_text_does_not_reorder_search_results(app):
    """The issue's first repro: B's five notes contain `alpha` (case 1) or `bravo` (case 2)."""
    base, database = app
    tokens = two_tenants(base, database)
    create(base, tokens, "a", "alpha alpha bravo")
    create(base, tokens, "a", "alpha bravo bravo")
    b_ids = [create(base, tokens, "b", f"alpha filler{i}") for i in range(5)]
    case1 = search_a(base, tokens, "alpha+bravo")
    for i, rid in enumerate(b_ids):
        retitle(base, tokens, "b", rid, f"bravo filler{i}")
    case2 = search_a(base, tokens, "alpha+bravo")
    assert case1 == case2


def test_search_order_is_not_a_word_presence_oracle(app):
    """The issue's word-presence variant: does B's note contain `zebrasecret`?"""
    base, database = app
    tokens = two_tenants(base, database)
    secret = create(base, tokens, "b", "zebrasecret merger plan")
    for i in range(4):
        create(base, tokens, "b", f"filler note {i}")
    create(base, tokens, "a", "zebrasecret pad")
    create(base, tokens, "a", "qqcontrolqq pad")
    with_word = search_a(base, tokens, "zebrasecret+OR+qqcontrolqq")
    retitle(base, tokens, "b", secret, "ordinary merger plan")
    without_word = search_a(base, tokens, "zebrasecret+OR+qqcontrolqq")
    assert with_word == without_word
