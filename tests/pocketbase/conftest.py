import json
import os
import sqlite3
from pathlib import Path

import pytest

from tests._bin import resolve_binary


REPO = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def zigbase_binary():
    override = os.environ.get("ZIGBASE_TEST_BINARY")
    if override:
        return Path(override)
    return resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")


@pytest.fixture
def pocketbase_snapshot(tmp_path):
    def create(collections, *, hooks=False, migrations=False):
        schema = tmp_path / "pb_schema.json"
        schema.write_text(json.dumps(collections), encoding="utf-8")
        pb_data = tmp_path / "pb_data"
        pb_data.mkdir(exist_ok=True)
        connection = sqlite3.connect(pb_data / "data.db")
        try:
            for collection in collections:
                name = collection["name"]
                kind = collection.get("type") or "base"
                columns = ["id TEXT PRIMARY KEY", "created TEXT", "updated TEXT"]
                for field in collection.get("fields", []):
                    if not field.get("system") and field.get("name") not in {
                        "created",
                        "updated",
                    }:
                        storage = {
                            "bool": "INTEGER",
                            "number": "INTEGER" if field.get("onlyInt") else "REAL",
                        }.get(field["type"], "TEXT")
                        columns.append(f'"{field["name"]}" {storage}')
                if kind == "auth":
                    columns.extend(
                        [
                            "email TEXT",
                            "emailVisibility INTEGER",
                            "verified INTEGER",
                            "password TEXT",
                            "tokenKey TEXT",
                        ]
                    )
                if kind == "view":
                    connection.execute(
                        f'CREATE VIEW "{name}" AS SELECT '  # noqa: S608 - test-only fixture
                        "'view00000000001' AS id"
                    )
                else:
                    connection.execute(
                        f'CREATE TABLE "{name}" ({", ".join(columns)})'  # noqa: S608 - test fixture
                    )
            connection.commit()
        finally:
            connection.close()
        if hooks:
            hook_dir = tmp_path / "pb_hooks"
            hook_dir.mkdir(exist_ok=True)
            (hook_dir / "main.pb.js").write_text("onRecordCreateRequest(() => {})\n")
        if migrations:
            migration_dir = tmp_path / "pb_migrations"
            migration_dir.mkdir(exist_ok=True)
            (migration_dir / "1.js").write_text("migrate(() => {})\n")
        return schema, pb_data

    return create


def base_collection(**overrides):
    value = {
        "id": "posts_collection",
        "name": "posts",
        "type": "base",
        "system": False,
        "fields": [
            {
                "id": "title_field",
                "name": "title",
                "type": "text",
                "required": True,
                "system": False,
            }
        ],
        "indexes": ["CREATE UNIQUE INDEX idx_posts_title ON posts (title)"],
        "listRule": "@request.auth.id != ''",
        "viewRule": "@request.auth.id != ''",
        "createRule": None,
        "updateRule": None,
        "deleteRule": None,
        "manageRule": None,
        "authRule": "verified = true",
    }
    value.update(overrides)
    return value
