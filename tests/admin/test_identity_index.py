"""A broken identity index must refuse boot before accepting requests."""
import os
import shutil
import sqlite3
import subprocess

import pytest

from conftest import _reserve_port, _su_template_for


@pytest.mark.parametrize("definition", [
    "CREATE INDEX idx_auth__superusers_email ON _superusers(email)",
    "CREATE UNIQUE INDEX idx_auth__superusers_email ON _superusers(tokenKey) WHERE email != ''",
    "CREATE UNIQUE INDEX idx_auth__superusers_email ON _superusers(email) WHERE verified = 1",
    "CREATE UNIQUE INDEX idx_auth__superusers_email ON _superusers(email)",
    "CREATE TABLE idx_auth__superusers_email(note TEXT)",
])
def test_incompatible_identity_index_refuses_boot(binary, tmp_path, definition):
    data = tmp_path / "data"
    shutil.copytree(_su_template_for(binary), data)
    database = data / "data.db"
    with sqlite3.connect(database) as conn:
        conn.execute("DROP INDEX IF EXISTS idx_auth__superusers_email")
        conn.execute(definition)
        before = conn.execute(
            "SELECT type, rootpage, sql FROM sqlite_schema WHERE name='idx_auth__superusers_email'"
        ).fetchone()
    with _reserve_port() as port:
        result = subprocess.run(
            [binary, "serve", "--insecure-cookies"],
            env={**os.environ, "ZIGBASE_DATA_DIR": str(data),
                 "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"},
            capture_output=True, text=True, timeout=15,
        )
    assert result.returncode != 0, result.stdout + result.stderr
    assert "Collection '_superusers', identity field 'email'" in result.stderr
    assert "idx_auth__superusers_email" in result.stderr
    assert "explicitly migrate" in result.stderr
    with sqlite3.connect(database) as conn:
        assert conn.execute(
            "SELECT type, rootpage, sql FROM sqlite_schema WHERE name='idx_auth__superusers_email'"
        ).fetchone() == before


@pytest.mark.parametrize("definition", [None,
    "CREATE INDEX idx_auth__superusers_username ON _superusers(username)",
    "CREATE UNIQUE INDEX idx_auth__superusers_username ON _superusers(tokenKey) WHERE username != ''",
])
def test_superuser_options_verify_identity_before_saving(binary, tmp_path, definition):
    from test_tenant_unique import Server, _admin
    from test_query_workbench import call

    data = tmp_path / "data"
    shutil.copytree(_su_template_for(binary), data)
    srv = Server(binary, data)
    srv.start()
    try:
        token = _admin(srv.base)
        with sqlite3.connect(data / "data.db") as conn:
            conn.execute("DROP INDEX IF EXISTS idx_auth__superusers_username")
            if definition:
                conn.execute(definition)
        code, body = call(srv.base, "PATCH", "/api/collections/_superusers", {
            "name": "_superusers", "type": "auth",
            "options": {"auth": {"identityFields": ["username"]}},
        }, token=token)
        assert code == (400 if definition else 200), body
        with sqlite3.connect(data / "data.db") as conn:
            sql = conn.execute("SELECT sql FROM sqlite_schema WHERE name='idx_auth__superusers_username'").fetchone()
            if definition:
                assert sql == (definition,)
                assert "idx_auth__superusers_username" in str(body)
                code, stored = call(srv.base, "GET", "/api/collections/_superusers", token=token)
                assert code == 200
                assert stored["options"]["auth"]["identityFields"] == ["email"]
            else:
                assert sql and "UNIQUE" in sql[0]
                conn.execute("INSERT INTO _superusers(id, username) VALUES('identity-a', 'duplicate')")
                with pytest.raises(sqlite3.IntegrityError):
                    conn.execute("INSERT INTO _superusers(id, username) VALUES('identity-b', 'duplicate')")
    finally:
        srv.stop()


def test_changed_declaration_under_removed_identity_name_is_refused(binary, tmp_path):
    """A preserved former-identity object must not stand in for a changed declaration."""
    import json

    from test_tenant_unique import Server, _admin
    from test_query_workbench import call

    data = tmp_path / "data"
    shutil.copytree(_su_template_for(binary), data)
    srv = Server(binary, data)
    srv.start()
    try:
        token = _admin(srv.base)
        code, col = call(srv.base, "POST", "/api/collections", {
            "name": "handles", "type": "auth",
            "fields": [
                {"id": "", "name": "handle", "type": "text", "options": {}},
                {"id": "", "name": "account", "type": "text", "options": {}},
            ],
            "options": {"auth": {"identityFields": ["handle"]}},
        }, token=token)
        assert code == 201, col
        legacy = [{"name": "idx_auth_handles_handle", "fields": ["account"], "unique": False}]
        with sqlite3.connect(data / "data.db") as conn:
            # Metadata an older release could store: a non-unique declaration on the identity name.
            conn.execute("UPDATE _collections SET indexes=? WHERE name='handles'", (json.dumps(legacy),))
            conn.execute("DROP INDEX idx_auth_handles_handle")
            conn.execute('CREATE INDEX "idx_auth_handles_handle" ON "handles" ("account")')
            before = conn.execute("SELECT sql FROM sqlite_schema WHERE name='idx_auth_handles_handle'").fetchone()
        fields = [field for field in col["schema"] if field["name"] in ("handle", "account")]
        code, body = call(srv.base, "PATCH", "/api/collections/handles", {
            "name": "handles", "type": "auth", "fields": fields,
            "indexes": [{"name": "idx_auth_handles_handle", "fields": ["account"], "unique": True}],
            "options": {"auth": {"identityFields": ["email"]}},
        }, token=token)
        assert code == 400, body
        assert "idx_auth_handles_handle" in str(body)
        assert "explicitly migrate" in str(body).lower()
        with sqlite3.connect(data / "data.db") as conn:
            assert conn.execute("SELECT sql FROM sqlite_schema WHERE name='idx_auth_handles_handle'").fetchone() == before
            indexes, options = conn.execute("SELECT indexes, options FROM _collections WHERE name='handles'").fetchone()
            assert json.loads(indexes) == legacy
            assert json.loads(options)["auth"]["identityFields"] == ["handle"]
            # The non-unique object stays in force, and nothing claims otherwise.
            conn.execute("INSERT INTO handles(id, account, handle) VALUES('a', 'shared', 'one')")
            conn.execute("INSERT INTO handles(id, account, handle) VALUES('b', 'shared', 'two')")
    finally:
        srv.stop()
