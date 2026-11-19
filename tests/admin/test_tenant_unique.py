"""Field-level `unique` on a tenant-owned base collection is per tenant (#498).

A table-wide unique let one request per guess learn whether ANY other tenant held a value
(409 vs 201) and let a tenant squat values. Runs against the dating-server fixture, which has
tenancy enabled with `profiles` as the auth collection.
"""
import json
import os
import shutil
import sqlite3
import subprocess

import pytest

from _bin import REPO, resolve_binary
from conftest import _reserve_port, _stop_server, _su_template_for, _wait_reachable_or_fail
from test_query_workbench import call


@pytest.fixture(scope="module")
def dating_binary():
    return resolve_binary("ZIGBASE_TEST_DATING_BINARY", REPO, "dating-server")


class Server:
    def __init__(self, binary, data_dir):
        self.binary = binary
        self.data_dir = data_dir
        self.proc = None
        self.base = None

    def start(self):
        with _reserve_port() as port:
            env = {k: v for k, v in os.environ.items() if not k.startswith("ZIGBASE_")}
            env["ZIGBASE_FAKE_HASH"] = "1"
            env.update(ZIGBASE_DATA_DIR=str(self.data_dir), ZIGBASE_HTTP_PORT=str(port), ZIGBASE_SERVE_BACKGROUND="0")
            log_path = self.data_dir / "server.log"
            start = log_path.stat().st_size if log_path.exists() else 0
            with log_path.open("ab") as log:
                self.proc = subprocess.Popen([self.binary, "serve", "--insecure-cookies"], env=env, stdout=log, stderr=subprocess.STDOUT)
            _wait_reachable_or_fail(self.proc, port, str(log_path), log_start=start)
        self.base = f"http://127.0.0.1:{port}"

    def stop(self):
        if self.proc is not None:
            _stop_server(self.proc)
            self.proc = None


@pytest.fixture()
def server(dating_binary, tmp_path):
    shutil.copytree(_su_template_for(dating_binary), tmp_path, dirs_exist_ok=True)
    srv = Server(dating_binary, tmp_path)
    srv.start()
    try:
        yield srv
    finally:
        srv.stop()


def _admin(base):
    code, body = call(base, "POST", "/api/collections/_superusers/auth-with-password",
                      {"identity": "admin@x.io", "password": "adminpassword"})
    assert code == 200, body
    return body["token"]


def _member(base, admin, database, email, account):
    """A `profiles` user who is an active owner of `account` (created if missing)."""
    code, user = call(base, "POST", "/api/collections/profiles/records", {"email": email, "password": "password12345"}, admin)
    assert code == 201, user
    with sqlite3.connect(database) as db:
        db.execute("INSERT OR IGNORE INTO _accounts(id,created,updated,slug) VALUES(?,?,?,?)", (account, "2026-01-01", "2026-01-01", account))
        db.execute("INSERT INTO _memberships(id,created,updated,account,user_collection,user,role,status) VALUES(?,?,?,?,?,?,?,?)",
                   ("m-" + email, "2026-01-01", "2026-01-01", account, "profiles", user["id"], "owner", "active"))
    code, login = call(base, "POST", "/api/collections/profiles/auth-with-password", {"identity": email, "password": "password12345"})
    assert code == 200, login
    return {"Authorization": "Bearer " + login["token"], "X-Account-Id": account}


def _create_collection(base, admin, name, indexes=()):
    code, col = call(base, "POST", "/api/collections", {
        "name": name, "type": "base",
        "listRule": '@request.auth.id != ""', "viewRule": '@request.auth.id != ""',
        "createRule": '@request.auth.id != ""', "updateRule": '@request.auth.id != ""',
        "options": {"tenant": {"field": "account"}},
        "fields": [
            {"id": "", "name": "slug", "type": "text", "required": True, "unique": True, "options": {}},
            {"id": "", "name": "account", "type": "text", "options": {}},
        ],
        "indexes": list(indexes),
    }, admin)
    assert code == 201, col
    return col


def _post(base, name, headers, slug):
    return call(base, "POST", f"/api/collections/{name}/records", {"slug": slug}, headers=headers)


def test_unique_field_is_scoped_to_the_tenant(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    _create_collection(base, admin, "slugs")
    a = _member(base, admin, database, "a@example.com", "acct-a")
    b = _member(base, admin, database, "b@example.com", "acct-b")

    code, held = _post(base, "slugs", b, "acme-corp")
    assert code == 201, held
    # B holding the value no longer decides A's status code.
    code, mine = _post(base, "slugs", a, "acme-corp")
    assert code == 201 and mine["account"] == "acct-a", mine
    # Uniqueness still holds inside A's own tenant.
    code, dup = _post(base, "slugs", a, "acme-corp")
    assert code == 409, dup
    # Update path: renaming A's other row to a value only B holds succeeds as well.
    code, other = _post(base, "slugs", a, "zeta-labs")
    assert code == 201, other
    code, body = call(base, "PATCH", f"/api/collections/slugs/records/{other['id']}", {"slug": "only-b-has-this"}, headers=a)
    assert code == 200, body
    assert _post(base, "slugs", b, "only-b-has-this")[0] == 201


def test_explicit_unique_index_keeps_global_uniqueness(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    _create_collection(base, admin, "slugs2", indexes=[{"name": "idx_slugs2_slug_global", "fields": ["slug"], "unique": True}])
    a = _member(base, admin, database, "a@example.com", "acct-a")
    b = _member(base, admin, database, "b@example.com", "acct-b")
    assert _post(base, "slugs2", b, "acme-corp")[0] == 201
    assert _post(base, "slugs2", a, "acme-corp")[0] == 409


def test_restart_converges_a_pre_498_table(server):
    """A table created before #498 (inline, table-wide UNIQUE) is converged at startup."""
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    _create_collection(base, admin, "slugs")
    a = _member(base, admin, database, "a@example.com", "acct-a")
    b = _member(base, admin, database, "b@example.com", "acct-b")
    code, held = _post(base, "slugs", b, "acme-corp")
    assert code == 201, held
    server.stop()
    with sqlite3.connect(database) as db:
        db.execute("ALTER TABLE slugs RENAME TO slugs_old")
        db.execute('CREATE TABLE slugs ("id" TEXT PRIMARY KEY, "created" TEXT, "updated" TEXT, "slug" TEXT UNIQUE, "account" TEXT)')
        db.execute("INSERT INTO slugs SELECT id, created, updated, slug, account FROM slugs_old")
        db.execute("DROP TABLE slugs_old")
    with sqlite3.connect(database) as db, pytest.raises(sqlite3.IntegrityError):
        # The legacy shape really is table-wide before the restart.
        db.execute("INSERT INTO slugs VALUES ('probe', '', '', 'acme-corp', 'acct-a')")
    server.start()
    base = server.base
    a = {**a, "Authorization": _relogin(base, "a@example.com")}
    code, mine = _post(base, "slugs", a, "acme-corp")
    assert code == 201, mine
    assert _post(base, "slugs", a, "acme-corp")[0] == 409
    # B's row survived the rebuild.
    code, listed = call(base, "GET", "/api/collections/slugs/records", headers={**b, "Authorization": _relogin(base, "b@example.com")})
    assert code == 200 and [r["slug"] for r in listed["items"]] == ["acme-corp"], listed


def _relogin(base, email):
    code, login = call(base, "POST", "/api/collections/profiles/auth-with-password", {"identity": email, "password": "password12345"})
    assert code == 200, login
    return "Bearer " + login["token"]


@pytest.mark.parametrize("kind", ["base", "auth"])
def test_schema_editor_displays_unique_scope(server, _browser, kind):
    from conftest import login
    admin = _admin(server.base)
    if kind == "base":
        _create_collection(server.base, admin, "scope_hints")
    else:
        col = _auth_collection(server.base, admin, "scope_hints", ["email"])
        code, body = call(server.base, "PATCH", "/api/collections/scope_hints", {
            "name": "scope_hints", "type": "auth", "fields": col["schema"],
            "options": {"tenant": {"field": "account"}},
        }, admin)
        assert code == 200, body
    context = _browser.new_context(base_url=server.base)
    try:
        page = context.new_page()
        login(page)
        page.goto("/_/#/collections/scope_hints")
        page.wait_for_selector('[data-test=field-row]')
        rows = {row.locator('[data-test=field-name]').input_value(): row
                for row in page.locator('[data-test=field-row]').all()}
        assert rows["slug"].locator('[data-test=unique-scope]').inner_text() == ("global" if kind == "auth" else "per tenant (account)")
        assert rows["account"].locator('[data-test=unique-scope]').inner_text() == "global"
    finally:
        context.close()


def _auth_collection(base, admin, name, identities):
    code, col = call(base, "POST", "/api/collections", {
        "name": name, "type": "auth",
        "fields": [
            {"id": "", "name": "slug", "type": "text", "unique": True, "options": {}},
            {"id": "", "name": "account", "type": "text", "options": {}},
        ],
        "options": {"auth": {"identityFields": identities}},
    }, admin)
    assert code == 201, col
    return col


def test_empty_identity_fields_default_persists_and_boots(server):
    base = server.base
    admin = _admin(base)
    col = _auth_collection(base, admin, "tenant_members", ["email"])
    code, patched = call(base, "PATCH", "/api/collections/tenant_members", {
        "name": "tenant_members", "type": "auth", "fields": col["schema"],
        "options": {"tenant": {"field": "account"}, "auth": {"identityFields": []}},
    }, admin)
    assert code == 200, patched
    assert patched["options"]["auth"]["identityFields"] == ["email"]
    server.stop()
    server.start()
    admin = _admin(server.base)
    code, persisted = call(server.base, "GET", "/api/collections/tenant_members", token=admin)
    assert code == 200, persisted
    assert persisted["options"]["auth"]["identityFields"] == ["email"]
    for account, expected in (("acct-a", 201), ("acct-b", 409)):
        code, row = call(server.base, "POST", "/api/collections/tenant_members/records", {
            "account": account, "slug": "shared", "password": "password12345",
        }, admin)
        assert code == expected, row
    # The default identity retains email uniqueness across tenants.
    for account, expected in (("acct-a", 201), ("acct-b", 409)):
        code, row = call(server.base, "POST", "/api/collections/tenant_members/records", {
            "account": account, "email": "shared@example.com", "password": "password12345",
        }, admin)
        assert code == expected, row


def test_removed_identity_index_is_not_restored_as_migration_sql(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _auth_collection(base, admin, "identity_repro", ["slug"])
    code, row = call(base, "POST", "/api/collections/identity_repro/records", {
        "slug": "shared", "email": "first@example.com", "password": "password12345",
    }, admin)
    assert code == 201, row
    with sqlite3.connect(database) as db:
        # Similar naming is not ownership: only the exact configured identity index is engine-owned.
        db.execute("CREATE INDEX idx_auth_identity_repro_migration ON identity_repro(slug)")
        db.execute("CREATE TABLE identity_audit(value TEXT)")
        db.execute("CREATE TRIGGER idx_auth_identity_repro_slug AFTER INSERT ON identity_repro BEGIN INSERT INTO identity_audit VALUES(NEW.slug); END")
    fields = [field for field in col["schema"] if field["name"] in ("slug", "account")]
    for field in fields:
        if field["name"] == "slug":
            field["unique"] = False
    code, patched = call(base, "PATCH", "/api/collections/identity_repro", {
        "name": "identity_repro", "type": "auth",
        "fields": fields, "options": {"auth": {"identityFields": ["email"]}},
    }, admin)
    assert code == 200, patched
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_auth_identity_repro_slug'").fetchone() is None
        assert db.execute("SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_auth_identity_repro_email'").fetchone()
        assert db.execute("SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_auth_identity_repro_migration'").fetchone()
    code, duplicate = call(base, "POST", "/api/collections/identity_repro/records", {
        "slug": "shared", "email": "second@example.com", "password": "password12345",
    }, admin)
    assert code == 201, duplicate
    code, duplicate_email = call(base, "POST", "/api/collections/identity_repro/records", {
        "slug": "other", "email": "second@example.com", "password": "password12345",
    }, admin)
    assert code == 409, duplicate_email
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT value FROM identity_audit").fetchall() == [("shared",)]


def test_tenant_field_rename_regenerates_engine_index(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    code, col = call(base, "GET", "/api/collections/notes", token=admin)
    assert code == 200, col
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT 1 FROM sqlite_master WHERE name='idx_notes_account_tenant'").fetchone()
        db.execute("INSERT INTO notes(id,created,updated,account) VALUES('kept','','','acct-a')")
    fields = col["schema"]
    for field in fields:
        if field["name"] == "account":
            field["name"] = "new_account"
    code, updated = call(base, "PATCH", "/api/collections/notes", {
        "name": "notes", "type": col["type"], "fields": fields,
        "options": {**col["options"], "tenant": {"field": "new_account"}},
    }, admin)
    assert code == 200, updated
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT new_account FROM notes WHERE id='kept'").fetchone() == ("acct-a",)
        assert db.execute("SELECT 1 FROM sqlite_master WHERE name='idx_notes_account_tenant'").fetchone() is None
        assert db.execute("SELECT name FROM pragma_index_info('idx_notes_new_account_tenant')").fetchall() == [("new_account",)]


def test_exact_engine_index_name_does_not_claim_migration_sql(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _auth_collection(base, admin, "custom_identity", ["slug"])
    with sqlite3.connect(database) as db:
        db.execute("DROP INDEX idx_auth_custom_identity_slug")
        db.execute('CREATE UNIQUE INDEX "idx_auth_custom_identity_slug" ON "custom_identity" ("account")')
        before = db.execute("SELECT sql FROM sqlite_master WHERE name='idx_auth_custom_identity_slug'").fetchone()[0]
    fields = [f for f in col["schema"] if f["name"] in ("slug", "account")]
    for field in fields:
        field["unique"] = False
    code, updated = call(base, "PATCH", "/api/collections/custom_identity", {
        "name": "custom_identity", "type": "auth", "fields": fields,
        "options": {"auth": {"identityFields": ["email"]}},
    }, admin)
    assert code == 200, updated
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT sql FROM sqlite_master WHERE name='idx_auth_custom_identity_slug'").fetchone() == (before,)
        db.execute("INSERT INTO custom_identity(id,account,slug) VALUES('a','acct-a','one')")
        with pytest.raises(sqlite3.IntegrityError):
            db.execute("INSERT INTO custom_identity(id,account,slug) VALUES('b','acct-a','two')")


@pytest.mark.parametrize("kind", ["index", "trigger", "trigger_singlequote", "view", "external_trigger"])
def test_migration_object_on_renamed_column_is_refused_before_ddl(server, kind):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _create_collection(base, admin, "migration_dependency")
    object_name = "migration_" + kind
    with sqlite3.connect(database) as db:
        db.execute("INSERT INTO migration_dependency(id,created,updated,account,slug) VALUES('kept','','','acct-a','one')")
        if kind == "index":
            db.execute('CREATE INDEX migration_index ON migration_dependency("account")')
        elif kind == "view":
            db.execute(f'CREATE VIEW {object_name} AS SELECT account FROM migration_dependency')
        elif kind == "external_trigger":
            db.execute("CREATE TABLE migration_source(n INTEGER)")
            db.execute(f'CREATE TRIGGER {object_name} AFTER INSERT ON migration_source BEGIN SELECT account FROM migration_dependency; END')
        else:
            column = "'account'" if kind == "trigger_singlequote" else '"account"'
            db.execute(f'CREATE TRIGGER {object_name} AFTER UPDATE OF {column} ON migration_dependency BEGIN SELECT 1; END')
        before = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
    for field in col["schema"]:
        if field["name"] == "account":
            field["name"] = "new_account"
    code, error = call(base, "PATCH", "/api/collections/migration_dependency", {
        "name": "migration_dependency", "type": "base", "fields": col["schema"],
        "options": {"tenant": {"field": "new_account"}},
    }, admin)
    assert code == 400, error
    assert object_name in error["message"] and "account" in error["message"], error
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall() == before
        assert db.execute("SELECT account,slug FROM migration_dependency WHERE id='kept'").fetchone() == ("acct-a", "one")


@pytest.mark.parametrize("line_end", ["\n", "\r\n"])
def test_migration_index_comment_newline_is_not_engine_whitespace(server, line_end):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _create_collection(base, admin, "comment_owned", indexes=[{
        "name": "idx_comment_account", "fields": ["account"], "unique": True,
        "where": "account IS NOT NULL -- guard" + line_end + " AND slug = 'protected'",
    }])
    with sqlite3.connect(database) as db:
        generated = db.execute("SELECT sql FROM sqlite_master WHERE name='idx_comment_account'").fetchone()[0]
        replacement = generated.replace("-- guard" + line_end, "-- guard" + ("\r" if line_end == "\r\n" else " "))
        assert replacement != generated
        db.execute("DROP INDEX idx_comment_account")
        db.execute(replacement)
    code, updated = call(base, "PATCH", "/api/collections/comment_owned", {
        "name": "comment_owned", "type": "base", "fields": col["schema"],
        "indexes": [], "options": col["options"],
    }, admin)
    assert code == 200, updated
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT sql FROM sqlite_master WHERE name='idx_comment_account'").fetchone() == (replacement,)
        db.execute("INSERT INTO comment_owned(id,account,slug) VALUES('a','acct-a','first')")
        with pytest.raises(sqlite3.IntegrityError):
            db.execute("INSERT INTO comment_owned(id,account,slug) VALUES('b','acct-a','second')")


def test_case_variant_engine_name_collision_is_refused_before_ddl(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _create_collection(base, admin, "case_collision")
    with sqlite3.connect(database) as db:
        db.execute("CREATE INDEX IDX_CASE_COLLISION_ACCOUNT_TENANT ON case_collision(slug)")
        before = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
    code, error = call(base, "PATCH", "/api/collections/case_collision", {
        "name": "case_collision", "type": "base", "options": col["options"],
        "fields": col["schema"] + [{"id": "", "name": "extra", "type": "text", "options": {}}],
    }, admin)
    assert code == 400, error
    assert "IDX_CASE_COLLISION_ACCOUNT_TENANT" in error["message"], error
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall() == before


def test_incoming_migration_foreign_key_blocks_parent_column_rename(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _create_collection(base, admin, "fk_parent", indexes=[{
        "name": "idx_parent_account_global", "fields": ["account"], "unique": True,
    }])
    with sqlite3.connect(database) as db:
        db.execute("INSERT INTO fk_parent(id,account,slug) VALUES('parent','acct-a','one')")
        db.execute("CREATE TABLE migration_audit(account TEXT REFERENCES fk_parent(account))")
        before = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
    for field in col["schema"]:
        if field["name"] == "account":
            field["name"] = "new_account"
    code, error = call(base, "PATCH", "/api/collections/fk_parent", {
        "name": "fk_parent", "type": "base", "fields": col["schema"],
        "options": {"tenant": {"field": "new_account"}},
        "indexes": [{"name": "idx_parent_account_global", "fields": ["new_account"], "unique": True}],
    }, admin)
    assert code == 400, error
    assert "migration_audit" in error["message"] and "account" in error["message"], error
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall() == before
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("INSERT INTO migration_audit VALUES('acct-a')")


def test_engine_index_name_on_another_table_is_refused_before_ddl(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _auth_collection(base, admin, "people", ["slug"])
    with sqlite3.connect(database) as db:
        db.execute("CREATE TABLE migration_elsewhere(value TEXT)")
        db.execute("CREATE INDEX idx_auth_people_email ON migration_elsewhere(value)")
        before = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
    code, error = call(base, "PATCH", "/api/collections/people", {
        "name": "people", "type": "auth", "fields": col["schema"],
        "options": {"auth": {"identityFields": ["email"]}},
    }, admin)
    assert code == 400, error
    assert "idx_auth_people_email" in error["message"], error
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall() == before
    code, unchanged = call(base, "GET", "/api/collections/people", token=admin)
    assert code == 200 and unchanged["options"]["auth"]["identityFields"] == ["slug"], unchanged


@pytest.mark.parametrize("physical,offender", [
    ("ALTER TABLE guarded ADD COLUMN migration_column TEXT", "migration_column"),
    ("ALTER TABLE guarded ADD COLUMN migration_column TEXT DEFAULT 'kept'", "migration_column"),
    ("CREATE TABLE guarded(id TEXT PRIMARY KEY,created TEXT,updated TEXT,slug TEXT,account TEXT,CHECK(length(slug)>0),UNIQUE(account,slug))", "CHECK"),
    ("CREATE TABLE guarded(id TEXT PRIMARY KEY,created TEXT,updated TEXT,slug TEXT DEFAULT 'kept',account TEXT,UNIQUE(account,slug))", "DEFAULT"),
    ("CREATE TABLE guarded(id TEXT PRIMARY KEY,created TEXT,updated TEXT,slug TEXT,account TEXT,UNIQUE(account,slug),UNIQUE(created))", "sqlite_autoindex"),
])
def test_unsafe_rebuild_returns_actionable_400(server, physical, offender):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _create_collection(base, admin, "guarded")
    with sqlite3.connect(database) as db:
        if physical.startswith("CREATE TABLE"):
            db.execute("DROP TABLE guarded")
        db.execute(physical)
        db.execute("INSERT INTO guarded(id,slug,account) VALUES('kept','one','acct-a')")
        before = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
        generation = db.execute("SELECT generation FROM _schema_state").fetchone()
    code, error = call(base, "PATCH", "/api/collections/guarded", {
        "name": "guarded", "type": "base", "options": col["options"],
        "fields": col["schema"] + [{"id": "", "name": "extra", "type": "text", "options": {}}],
    }, admin)
    assert code == 400, error
    assert offender in error["message"] and "migration" in error["message"].lower(), error
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall() == before
        assert db.execute("SELECT generation FROM _schema_state").fetchone() == generation
        assert db.execute("SELECT slug FROM guarded WHERE id='kept'").fetchone() == ("one",)


@pytest.mark.parametrize("dependency", ["wildcard", "qualified", "positional", "view", "external_trigger"])
@pytest.mark.parametrize("change", ["add", "remove", "reorder"])
def test_layout_dependencies_refused_before_ddl(server, dependency, change):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _create_collection(base, admin, "layout_guard")
    with sqlite3.connect(database) as db:
        db.execute("CREATE TABLE audit AS SELECT * FROM layout_guard")
        if dependency == "view":
            db.execute("CREATE VIEW migration_layout AS SELECT * FROM layout_guard")
        elif dependency == "external_trigger":
            db.execute("CREATE TRIGGER migration_layout AFTER INSERT ON audit BEGIN SELECT * FROM layout_guard; END")
        else:
            body = {
                "wildcard": "INSERT INTO audit SELECT * FROM layout_guard WHERE id=NEW.id",
                "qualified": "INSERT INTO audit SELECT g.* FROM layout_guard g WHERE id=NEW.id",
                "positional": "INSERT INTO layout_guard VALUES('copy','','','copy','acct-b')",
            }[dependency]
            db.execute(f"CREATE TRIGGER migration_layout AFTER INSERT ON layout_guard BEGIN {body}; END")
        before = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
        generation = db.execute("SELECT generation FROM _schema_state").fetchone()
    fields = col["schema"]
    if change == "add":
        fields = fields + [{"id": "", "name": "extra", "type": "text", "options": {}}]
    elif change == "remove":
        fields = [field for field in fields if field["name"] != "slug"]
    else:
        fields = list(reversed(fields))
    code, error = call(base, "PATCH", "/api/collections/layout_guard", {
        "name": "layout_guard", "type": "base", "options": col["options"], "fields": fields,
    }, admin)
    assert code == 400, error
    assert "migration_layout" in error["message"] and "migrat" in error["message"], error
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall() == before
        assert db.execute("SELECT generation FROM _schema_state").fetchone() == generation


@pytest.mark.parametrize("operation", ["boot", "update"])
def test_main_auth_duplicate_usernames_keep_constraints(server, operation):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _auth_collection(base, admin, "global_members", ["email"])
    # main 7c964a72 creates this physical shape: inline UNIQUE(slug), and a
    # partial identity index on email only. Tenancy does not change auth DDL.
    server.stop()
    with sqlite3.connect(database) as db:
        options = db.execute("SELECT options FROM _collections WHERE name='global_members'").fetchone()[0]
        options = json.loads(options)
        options["tenant"] = {"field": "account"}
        db.execute("UPDATE _collections SET options=? WHERE name='global_members'", (json.dumps(options),))
        for key, account in (("first", "acct-a"), ("second", "acct-b")):
            db.execute("INSERT INTO global_members(id,email,username,slug,account) VALUES(?,?,?,?,?)",
                       (key, key + "@example.com", "sameuser", key, account))
        before = db.execute("SELECT type,name,sql FROM sqlite_master WHERE tbl_name='global_members' AND (type='table' OR (type='index' AND (sql IS NULL OR sql LIKE 'CREATE UNIQUE INDEX%'))) ORDER BY type,name").fetchall()
        assert [name for kind, name, sql in before if kind == "index" and sql] == ["idx_auth_global_members_email"]
        assert '"slug" TEXT UNIQUE' in next(sql for kind, name, sql in before if kind == "table")
        assert '"username" TEXT UNIQUE' not in next(sql for kind, name, sql in before if kind == "table")
    server.start()
    admin = _admin(server.base)
    if operation == "update":
        code, patched = call(server.base, "PATCH", "/api/collections/global_members", {
            "name": "global_members", "type": "auth", "fields": col["schema"],
            "options": {"tenant": {"field": "account"}, "auth": {"identityFields": ["email"]}},
        }, admin)
        assert code == 200, patched
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT type,name,sql FROM sqlite_master WHERE tbl_name='global_members' AND (type='table' OR (type='index' AND (sql IS NULL OR sql LIKE 'CREATE UNIQUE INDEX%'))) ORDER BY type,name").fetchall() == before
        assert db.execute("SELECT username FROM global_members ORDER BY id").fetchall() == [("sameuser",), ("sameuser",)]


def test_auth_migration_composite_unique_is_refused_before_ddl(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _auth_collection(base, admin, "guarded_members", ["email"])
    code, col = call(base, "PATCH", "/api/collections/guarded_members", {
        "name": "guarded_members", "type": "auth", "fields": col["schema"],
        "options": {"tenant": {"field": "account"}},
    }, admin)
    assert code == 200, col
    with sqlite3.connect(database) as db:
        sql = db.execute("SELECT sql FROM sqlite_master WHERE name='guarded_members'").fetchone()[0]
        objects = db.execute("SELECT sql FROM sqlite_master WHERE tbl_name='guarded_members' AND type='index' AND sql IS NOT NULL").fetchall()
        db.execute("DROP TABLE guarded_members")
        db.execute(sql.rsplit(")", 1)[0] + ", UNIQUE(account,slug))")
        for (index_sql,) in objects:
            db.execute(index_sql)
        db.execute("INSERT INTO guarded_members(id,slug,account) VALUES('kept','one','acct-a')")
        before = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
        generation = db.execute("SELECT generation FROM _schema_state").fetchone()
    for field in col["schema"]:
        if field["name"] == "slug":
            field["unique"] = False
    code, error = call(base, "PATCH", "/api/collections/guarded_members", {
        "name": "guarded_members", "type": "auth", "fields": col["schema"], "options": col["options"],
    }, admin)
    assert code == 400, error
    assert "unowned unique constraint" in error["message"], error
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall() == before
        assert db.execute("SELECT generation FROM _schema_state").fetchone() == generation
        assert db.execute("SELECT slug,account FROM guarded_members WHERE id='kept'").fetchone() == ("one", "acct-a")
    code, unchanged = call(base, "GET", "/api/collections/guarded_members", token=admin)
    assert code == 200, unchanged
    assert next(f for f in unchanged["schema"] if f["name"] == "slug")["unique"] is True


def test_bom_index_dependency_refuses_index_removal(server):
    base, database = server.base, server.data_dir / "data.db"
    admin = _admin(base)
    col = _create_collection(base, admin, "bom_slugs", indexes=[{
        "name": "idx_slugs_account", "fields": ["account"],
    }])
    with sqlite3.connect(database) as db:
        db.execute("CREATE TRIGGER migration_bom AFTER INSERT ON bom_slugs BEGIN SELECT account FROM bom_slugs INDEXED \ufeffBY idx_slugs_account; END")
        # SQLite accepts this token separator and the trigger is executable.
        db.execute("INSERT INTO bom_slugs(id,slug,account) VALUES('kept','one','acct-a')")
        before = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
        generation = db.execute("SELECT generation FROM _schema_state").fetchone()
    code, error = call(base, "PATCH", "/api/collections/bom_slugs", {
        "name": "bom_slugs", "type": "base", "fields": col["schema"],
        "options": col["options"], "indexes": [],
    }, admin)
    assert code == 400, error
    assert "migration_bom" in error["message"] and "idx_slugs_account" in error["message"], error
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall() == before
        assert db.execute("SELECT generation FROM _schema_state").fetchone() == generation
        db.execute("INSERT INTO bom_slugs(id,slug,account) VALUES('still_valid','two','acct-a')")
    code, unchanged = call(base, "GET", "/api/collections/bom_slugs", token=admin)
    assert code == 200 and unchanged["indexes"] == col["indexes"], unchanged
