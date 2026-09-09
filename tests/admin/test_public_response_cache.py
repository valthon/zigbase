"""Real HTTP + second SQLite connection regression coverage for opt-in caching."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import time

import pytest

from conftest import _free_port, _stop_server, _su_template_for, _wait_reachable_or_fail
from test_query_workbench import admin, call


@pytest.fixture(scope="session")
def binary():
    value = os.environ.get("ZIGBASE_TEST_PUBLIC_RESPONSE_CACHE_BINARY")
    if not value:
        pytest.skip("requires -Dpublic-response-cache=true public-response-cache-fixture")
    assert pathlib.Path(value).is_file()
    return value


@pytest.fixture
def cache_server(binary, tmp_path):
    shutil.copytree(_su_template_for(binary), tmp_path, dirs_exist_ok=True)
    port = _free_port()
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(tmp_path), "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"}
    log_path = tmp_path / "server.log"
    with log_path.open("wb") as log:
        proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        _wait_reachable_or_fail(proc, port, str(log_path))
        yield f"http://127.0.0.1:{port}", tmp_path
    finally:
        _stop_server(proc)


def setup(base, name="posts", **options):
    token = admin(base)
    definition = {"name": name, "type": "base", "viewRule": "@public", "fields": [{"id": "", "name": "title", "type": "text", "options": {}}], **options}
    code, body = call(base, "POST", "/api/collections", definition, token)
    assert code == 201, body
    code, record = call(base, "POST", f"/api/collections/{name}/records", {"title": "first"}, token)
    assert code == 201, record
    return token, f"/api/collections/{name}/records/{record['id']}"


def probe(base, token):
    code, body = call(base, "GET", "/cache-probe", token=token)
    assert code == 200, body
    return body


def test_hits_expiry_header_and_query_bypass(cache_server):
    base, _ = cache_server
    token, path = setup(base)
    for headers in [{"Authorization": "broken"}, {"Authorization": ""}, {"Cookie": "unrelated=1"}, {"Cookie": ""}]:
        assert call(base, "GET", path, headers=headers)[0] == 200
        assert probe(base, token) == {"count": 0, "next": 0}
    assert call(base, "GET", path + "?fields=id")[1].keys() == {"id"}
    assert probe(base, token) == {"count": 0, "next": 0}
    assert call(base, "GET", path)[1]["title"] == "first"
    first = probe(base, token)
    assert first == {"count": 1, "next": 1}
    for headers in [{"Authorization": "broken"}, {"Authorization": ""}, {"Cookie": "unrelated=1"}, {"Cookie": ""}]:
        assert call(base, "GET", path, headers=headers)[0] == 200
        assert probe(base, token) == first
    assert call(base, "GET", path + "?fields=id")[1].keys() == {"id"}
    assert probe(base, token) == first
    time.sleep(1.05)
    assert call(base, "GET", path)[0] == 200
    assert probe(base, token) == {"count": 1, "next": 0}


def test_http_raw_external_writes_and_private_schema_revoke(cache_server):
    base, data = cache_server
    token, path = setup(base)
    assert call(base, "GET", path)[1]["title"] == "first"
    assert call(base, "PATCH", path, {"title": "second"}, token)[0] == 200
    assert call(base, "GET", path)[1]["title"] == "second"
    # Also warm the ordinary metadata lease before directly revoking its public rule.
    assert call(base, "GET", path, headers={"Cookie": "unrelated=1"})[0] == 200
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("UPDATE posts SET title='external'")
    assert call(base, "GET", path)[1]["title"] == "external"
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute('UPDATE _collections SET "viewRule"=NULL WHERE name=\'posts\'')
    assert call(base, "GET", path)[0] == 404
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute('UPDATE _collections SET "viewRule"=\'@public\' WHERE name=\'posts\'')
    assert call(base, "GET", path)[0] == 200
    with sqlite3.connect(data / "data.db") as conn:
        fields = json.loads(conn.execute("SELECT schema FROM _collections WHERE name='posts'").fetchone()[0])
        for field in fields:
            if field["name"] == "title":
                field["hidden"] = True
        conn.execute("UPDATE _collections SET schema=? WHERE name='posts'", (json.dumps(fields),))
    assert "title" not in call(base, "GET", path)[1]
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("DELETE FROM posts")
    assert call(base, "GET", path)[0] == 404


def test_capacity_oversized_and_concurrent_readers(cache_server):
    base, _ = cache_server
    token, path = setup(base)
    paths = [path]
    for n in range(3):
        code, body = call(base, "POST", "/api/collections/posts/records", {"title": str(n)}, token)
        assert code == 201
        paths.append(f"/api/collections/posts/records/{body['id']}")
    for item in paths:
        assert call(base, "GET", item)[0] == 200
    assert probe(base, token)["count"] == 2
    with ThreadPoolExecutor(max_workers=8) as executor:
        assert list(executor.map(lambda _: call(base, "GET", path)[0], range(24))) == [200] * 24
    assert call(base, "PATCH", path, {"title": "x" * 70000}, token)[0] == 200
    assert len(call(base, "GET", path)[1]["title"]) == 70000
    assert probe(base, token)["count"] == 0


def test_locked_and_unlisted_collections_never_fill(cache_server):
    base, _ = cache_server
    token, path = setup(base, "private_posts", viewRule=None)
    assert call(base, "GET", path)[0] == 404
    assert probe(base, token)["count"] == 0
    _, path = setup(base, "unlisted")
    assert call(base, "GET", path)[0] == 200
    assert probe(base, token)["count"] == 0


def test_postgres_url_refused_before_connection(binary, tmp_path):
    env = {**os.environ, "ZIGBASE_DB_URL": "postgres://invalid:invalid@127.0.0.1:1/nope", "ZIGBASE_SERVE_BACKGROUND": "0"}
    result = subprocess.run([binary, "serve", "--data-dir", str(tmp_path)], env=env, capture_output=True, timeout=10)
    assert result.returncode != 0
    assert b"PublicResponseCacheRequiresSqlite" in result.stderr
    assert not (tmp_path / "data.db").exists()
