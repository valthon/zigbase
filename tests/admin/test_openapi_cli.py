"""End-to-end contract for `zigbase openapi` against real SQLite metadata."""
import json
import os
import pathlib
import subprocess

import pytest


REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]


@pytest.fixture(scope="session")
def dating_binary():
    override = os.environ.get("ZIGBASE_TEST_DATING_BINARY")
    if override:
        path = pathlib.Path(override)
        if not path.exists():
            raise FileNotFoundError(f"ZIGBASE_TEST_DATING_BINARY={override} does not exist")
        return str(path)
    subprocess.run(ZIG + ["build", "dating-server"], cwd=REPO, check=True)
    path = REPO / "zig-out" / "bin" / "dating-server"
    assert path.exists()
    return str(path)


def run(binary, *args):
    return subprocess.run([binary, *map(str, args)], capture_output=True, text=True)


def provision(binary, data_dir):
    schema = data_dir / "schema.json"
    schema.write_text(json.dumps({
        "zigbaseSchema": 1,
        "collections": [{
            "name": "notes",
            "type": "base",
            "fields": [{
                "id": "",
                "name": "body",
                "type": "text",
                "required": True,
                "options": {"min": 2, "max": 200},
            }],
            "indexes": [],
            "listRule": "@public",
            "viewRule": "@public",
            "createRule": None,
            "updateRule": "owner = @request.auth.id",
            "deleteRule": None,
            "options": {},
        }],
    }))
    result = run(binary, "schema", "apply", schema, "--data-dir", data_dir)
    assert result.returncode == 0, result.stderr


def test_stdout_metadata_collections_and_database_is_unchanged(binary, tmp_path):
    provision(binary, tmp_path)
    database = tmp_path / "data.db"
    before = database.read_bytes()
    result = run(
        binary, "openapi", "--data-dir", tmp_path,
        "--title", "Example API", "--api-version", "2026-08",
        "--server", "https://api.example.test",
    )
    assert result.returncode == 0, result.stderr
    doc = json.loads(result.stdout)
    assert doc["openapi"] == "3.1.2"
    assert doc["info"] == {"title": "Example API", "version": "2026-08"}
    assert doc["servers"] == [{"url": "https://api.example.test"}]
    assert "/api/collections/notes/records" in doc["paths"]
    assert doc["paths"]["/api/collections/notes/records"]["get"]["security"] == []
    assert doc["paths"]["/api/collections/notes/records"]["post"]["x-zigbase-access"] == "locked"
    assert doc["paths"]["/api/collections/notes/records/{id}"]["patch"]["x-zigbase-rule"] == "owner = @request.auth.id"
    assert doc["x-zigbase-coverage"]["consumerRoutes"] is False
    assert database.read_bytes() == before, "OpenAPI inspection must not mutate data.db"


def test_out_creates_parents_and_atomically_replaces_existing_file(binary, tmp_path):
    provision(binary, tmp_path)
    output = tmp_path / "generated" / "api" / "openapi.json"
    output.parent.mkdir(parents=True)
    output.write_text("old artifact")
    result = run(binary, "openapi", "--data-dir", tmp_path, "--out", output)
    assert result.returncode == 0, result.stderr
    doc = json.loads(output.read_text())
    assert doc["openapi"] == "3.1.2"
    assert not list(output.parent.glob("openapi.json.tmp-*"))


def test_framework_binary_includes_its_comptime_routes(binary, dating_binary, tmp_path):
    provision(binary, tmp_path)
    result = run(dating_binary, "openapi", "--data-dir", tmp_path)
    assert result.returncode == 0, result.stderr
    doc = json.loads(result.stdout)
    assert doc["x-zigbase-coverage"]["consumerRoutes"] is True
    route = doc["paths"]["/api/echo/{id}/ping"]["post"]
    assert route["operationId"] == "echoPing"
    assert route["x-zigbase-auth"] == "public"
    assert "requestBody" not in route
    publish = doc["paths"]["/api/testing/publish"]["post"]
    assert publish["requestBody"]["content"]["application/json"]["schema"]["type"] == "object"


def test_missing_database_fails_without_creating_it(binary, tmp_path):
    missing = tmp_path / "does-not-exist"
    result = run(binary, "openapi", "--data-dir", missing)
    assert result.returncode == 1
    assert "cannot inspect ZigBase database" in result.stderr
    assert "FileNotFound" in result.stderr
    assert "src/framework.zig" not in result.stderr
    assert not missing.exists()


def test_help_is_dedicated_and_side_effect_free(binary, tmp_path):
    data_dir = tmp_path / "no-data"
    result = run(binary, "openapi", "--help", "--data-dir", data_dir)
    assert result.returncode == 0
    assert "zigbase openapi" in result.stdout
    assert not data_dir.exists()
