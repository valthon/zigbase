"""Opt-in read-only inventory against actual SQLite and local/S3 storage."""
from contextlib import closing
import hashlib
import json
import os
import sqlite3
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest


@pytest.fixture
def inventory_binary():
    binary = os.environ.get("ZIGBASE_TEST_INVENTORY_BINARY")
    if not binary:
        pytest.skip("set ZIGBASE_TEST_INVENTORY_BINARY to a -Dfile-inventory=true -Ds3=true build")
    return binary


@pytest.fixture
def inventory_data(tmp_path, inventory_binary):
    # Build genuine engine metadata so new internal columns/migrations cannot
    # silently turn every reference lookup into the fail-closed unknown case.
    schema = tmp_path / "schema.json"
    schema.write_text(json.dumps({"zigbaseSchema": 1, "collections": [{
        "name": "images", "type": "base", "fields": [
            {"id": "photo", "name": "photo", "type": "file", "options": {"maxSelect": 1}},
        ], "indexes": [], "listRule": None, "viewRule": None,
        "createRule": None, "updateRule": None, "deleteRule": None, "options": {},
    }]}))
    result = subprocess.run(
        [inventory_binary, "schema", "apply", str(schema), "--data-dir", str(tmp_path)],
        env={**{key: value for key, value in os.environ.items() if not key.startswith("ZIGBASE_")},
             "ZIGBASE_JWT_SECRET": "inventory-fixture-secret-not-for-production"},
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    # Bootstrap has exited; preserve its maintenance lock outside the test root
    # so tests can choose a fresh directory or a storage-root symlink.
    (tmp_path / "storage").rename(tmp_path / "bootstrap-storage")
    with closing(sqlite3.connect(tmp_path / "data.db")) as conn, conn:
        conn.execute("INSERT INTO images VALUES ('r1','','','a.png')")
    return tmp_path


def inventory(binary, data, *args, env=None):
    result = subprocess.run([binary, "files", "inventory", "--data-dir", str(data), *args],
                            env={**os.environ, "ZIGBASE_DB_URL": "", "ZIGBASE_S3_BUCKET": "", **(env or {})},
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


@pytest.mark.parametrize("command", [("inventory",), ("reconcile",), ("reconcile", "--apply")])
@pytest.mark.parametrize("empty", [False, True])
@pytest.mark.parametrize("missing", ["rename_epoch", "storage_namespaces"])
def test_old_metadata_fails_explicitly_without_mutation(inventory_binary, inventory_data, command, empty, missing):
    data = inventory_data
    root = data / "storage" / "images" / "r1"
    root.mkdir(parents=True)
    blob = root / "a.png"
    blob.write_bytes(b"kept")
    with closing(sqlite3.connect(data / "data.db")) as conn, conn:
        if missing == "rename_epoch":
            conn.execute("ALTER TABLE _collections DROP COLUMN rename_epoch")
            conn.execute("DELETE FROM _migrations WHERE name='0027_collection_rename_epoch'")
        else:
            conn.execute("DROP TABLE _storage_namespaces")
            conn.execute("DELETE FROM _migrations WHERE name='0028_storage_namespaces'")
        if empty:
            conn.execute("DELETE FROM _collections")
    before = (data / "data.db").read_bytes()
    result = subprocess.run(
        [inventory_binary, "files", *command, "--data-dir", str(data)],
        env={**os.environ, "ZIGBASE_DB_URL": "", "ZIGBASE_S3_BUCKET": ""},
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert result.stdout == ""
    assert "CollectionMetadataUnavailable" in result.stderr
    assert "run migrations" in result.stderr
    assert (data / "data.db").read_bytes() == before
    assert blob.read_bytes() == b"kept"


def test_local_inventory_is_paginated_scoped_and_read_only(inventory_binary, inventory_data):
    data = inventory_data
    record = data / "storage" / "images" / "r1"
    record.mkdir(parents=True)
    (record / "a.png").write_bytes(b"abc")
    (record / "uncommitted.png").write_bytes(b"12345")
    (data / "outside.txt").write_bytes(b"must not be counted")
    (record / "link.txt").symlink_to(data / "outside.txt")
    (data / "storage" / "external").symlink_to(data, target_is_directory=True)
    before = hashlib.sha256((data / "data.db").read_bytes()).digest()
    first = inventory(inventory_binary, data, "--limit", "1")
    assert first["items"] == [{"key": "images/r1/a.png", "bytes": 3, "reference": "referenced"}]
    assert first["usage"]["scope"] == "page"
    assert first["usage"]["bytes"] == 3 and first["hasNext"]
    second = inventory(inventory_binary, data, "--limit", "1", "--cursor", first["nextCursor"])
    assert second["items"][0]["reference"] == "candidate_unreferenced"
    assert second["usage"]["bytes"] == 5 and not second["hasNext"]
    assert "in-flight" in second["warning"]
    assert hashlib.sha256((data / "data.db").read_bytes()).digest() == before
    assert (record / "uncommitted.png").exists()
    assert not (data / ".jwt_secret").exists()


def test_configured_storage_root_symlink_keeps_descendants_scoped(inventory_binary, inventory_data, tmp_path_factory):
    volume = tmp_path_factory.mktemp("inventory-volume")
    (volume / "images" / "r1").mkdir(parents=True)
    (volume / "images" / "r1" / "a.png").write_bytes(b"abc")
    (volume / "escape").symlink_to(inventory_data, target_is_directory=True)
    (inventory_data / "storage").symlink_to(volume, target_is_directory=True)
    result = inventory(inventory_binary, inventory_data)
    assert result["items"] == [{"key": "images/r1/a.png", "bytes": 3, "reference": "referenced"}]


def test_invalid_utf8_key_fails_without_partial_json(inventory_binary, inventory_data):
    directory = inventory_data / "storage"
    directory.mkdir()
    with open(os.fsencode(directory) + b"/bad-\xff", "wb") as output:
        output.write(b"x")
    result = subprocess.run([inventory_binary, "files", "inventory", "--data-dir", str(inventory_data)],
                            env={**os.environ, "ZIGBASE_DB_URL": "", "ZIGBASE_S3_BUCKET": ""},
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 1
    assert result.stdout == ""
    assert "not UTF-8" in result.stderr and "backend-native" in result.stderr
    assert "src/framework.zig" not in result.stderr


def test_s3_inventory_reads_one_page_without_fetching_objects(inventory_binary, inventory_data):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_HEAD(self):
            requests.append(("HEAD", self.path))
            self.send_response(404)
            self.end_headers()

        def do_GET(self):
            requests.append(("GET", self.path))
            body = b"<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>tenant/images/r1/a.png</Key><Size>3</Size></Contents><NextContinuationToken>next+/=</NextContinuationToken></ListBucketResult>"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            page = inventory(inventory_binary, inventory_data, "--limit", "1", env={
                "ZIGBASE_S3_BUCKET": "test-bucket", "ZIGBASE_S3_REGION": "us-east-1",
                "ZIGBASE_S3_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
                "ZIGBASE_S3_FORCE_PATH_STYLE": "true", "ZIGBASE_S3_KEY_PREFIX": "tenant/",
                "ZIGBASE_S3_ACCESS_KEY_ID": "synthetic-key", "ZIGBASE_S3_SECRET_ACCESS_KEY": "synthetic-secret",
            })
            assert page["items"][0]["reference"] == "referenced"
            assert page["nextCursor"] == "next+/=" and page["hasNext"]
            listings = [path for method, path in requests if method == "GET"]
            assert len(listings) == 1
            assert "max-keys=1" in listings[0] and "prefix=tenant%2F" in listings[0]
            assert not (inventory_data / "storage_cache").exists()
        finally:
            server.shutdown()
            worker.join(timeout=5)


def test_inventory_refuses_missing_database_without_creating_it(inventory_binary, tmp_path):
    result = subprocess.run([inventory_binary, "files", "inventory", "--data-dir", str(tmp_path)],
                            env={**os.environ, "ZIGBASE_DB_URL": "", "ZIGBASE_S3_BUCKET": ""},
                            capture_output=True, text=True, timeout=5)
    assert result.returncode != 0
    assert "configured database" in result.stderr and "--data-dir" in result.stderr
    assert "src/framework.zig" not in result.stderr
    assert list(tmp_path.iterdir()) == []


def test_inventory_counts_expired_hidden_file_references(inventory_binary, inventory_data):
    data = inventory_data
    record = data / "storage" / "images" / "r1"
    record.mkdir(parents=True)
    (record / "a.png").write_bytes(b"abc")
    with closing(sqlite3.connect(data / "data.db")) as conn, conn:
        conn.execute("ALTER TABLE images ADD COLUMN expires TEXT")
        conn.execute("UPDATE images SET expires='1970-01-01T00:00:00Z'")
        fields = [
            {"id": "photo", "name": "photo", "type": "file", "hidden": True, "options": {"maxSelect": 1}},
            {"id": "expires", "name": "expires", "type": "date", "options": {}},
        ]
        conn.execute("UPDATE _collections SET schema=?, options=?", (json.dumps(fields), json.dumps({"ttl": {"field": "expires"}})))
    page = inventory(inventory_binary, data)
    assert page["items"] == [{"key": "images/r1/a.png", "bytes": 3, "reference": "referenced"}]
    assert page["usage"]["candidateUnreferenced"] == 0
