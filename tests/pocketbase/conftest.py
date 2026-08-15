import json
import sqlite3

import pytest


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
                    if not field.get("system"):
                        columns.append(f'"{field["name"]}" TEXT')
                if kind == "auth":
                    columns.extend(
                        [
                            "email TEXT",
                            "emailVisibility INTEGER",
                            "verified INTEGER",
                            "passwordHash TEXT",
                            "tokenKey TEXT",
                        ]
                    )
                if kind == "view":
                    connection.execute(
                        f'CREATE VIEW "{name}" AS SELECT '  # noqa: S608 - test-only fixture
                        "'' AS id, '' AS created, '' AS updated"
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
    }
    value.update(overrides)
    return value
