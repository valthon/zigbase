"""Live checks for the optional PostgreSQL Rails row source."""

from __future__ import annotations

import datetime
import decimal
import hashlib
import os
import shutil
import uuid
from types import SimpleNamespace
from urllib.parse import quote

import pytest

from tools.rails import rails2zb
from .conftest import (
    decisions_for,
    materialize_artifacts,
    read_inventory,
    write_inventory,
)


POSTGRES_URL = os.environ.get("ZIGBASE_RAILS_PG_TEST_URL")


def _tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def _postgres_type(column):
    return {
        "integer": "BIGINT",
        "bigint": "BIGINT",
        "float": "DOUBLE PRECISION",
        "decimal": "NUMERIC",
        "boolean": "BOOLEAN",
        "datetime": "TIMESTAMP",
        "timestamp": "TIMESTAMP",
        "date": "DATE",
        "json": "JSONB",
        "jsonb": "JSONB",
        "uuid": "UUID",
    }.get(column["type"], "TEXT")


@pytest.mark.skipif(not POSTGRES_URL, reason="no Rails PostgreSQL test URL")
def test_postgres_source_is_typed_and_read_only():
    source = SimpleNamespace(versions={"adapter": "PostgreSQL"})
    with rails2zb._connect_source(source, POSTGRES_URL) as conn:
        row = conn.execute(
            "SELECT 42::bigint AS integer_value, "
            "12.50::numeric AS decimal_value, "
            "DATE '2024-01-15' AS date_value, "
            "TIMESTAMPTZ '2024-01-15 09:30:00-05:00' AS timestamp_value, "
            "'12345678-1234-5678-1234-567812345678'::uuid AS uuid_value, "
            "'{\"answer\":42}'::jsonb AS json_value"
        ).fetchone()
        assert row["integer_value"] == 42
        assert row["decimal_value"] == decimal.Decimal("12.50")
        assert row["date_value"] == datetime.date(2024, 1, 15)
        assert row["timestamp_value"].utcoffset() is not None
        assert (
            rails2zb._record_id(
                SimpleNamespace(table="examples"), {"id": row["uuid_value"]}
            )
            == "12345678-1234-5678-1234-567812345678"
        )
        assert row["json_value"] == {"answer": 42}
        with pytest.raises(Exception, match="read-only transaction"):
            conn.execute("CREATE TABLE rails2zb_must_not_write (id bigint)")


@pytest.mark.skipif(not POSTGRES_URL, reason="no Rails PostgreSQL test URL")
def test_postgres_connection_error_does_not_echo_the_url():
    secret_url = (
        "postgresql://rails2zb:do-not-print@127.0.0.1:1/missing?connect_timeout=1"
    )
    source = SimpleNamespace(versions={"adapter": "PostgreSQL"})
    with pytest.raises(Exception) as caught:
        with rails2zb._connect_source(source, secret_url):
            pass
    assert secret_url not in str(caught.value)
    assert "do-not-print" not in str(caught.value)


@pytest.mark.skipif(not POSTGRES_URL, reason="no Rails PostgreSQL test URL")
def test_postgres_extract_emits_a_deterministic_bundle(fixture_root, tmp_path):
    """Exercise the real extraction path, not only the connection adapter."""
    import psycopg
    from psycopg import sql

    source = tmp_path / "source"
    shutil.copytree(fixture_root, source)
    shutil.rmtree(source / "db")
    versions = read_inventory(source, "versions")
    versions["adapter"] = "PostgreSQL"
    write_inventory(source, "versions", versions)
    counts = read_inventory(source, "counts")
    for table in counts["tables"]:
        table["scoped_count"] = 0 if table["model"] else None
        table["unscoped_count"] = 1 if table["table"] == "users" else 0
        table["hidden_by_default_scope"] = 0 if table["model"] else None
    write_inventory(source, "counts", counts)

    schema_name = f"rails2zb_{uuid.uuid4().hex}"
    separator = "&" if "?" in POSTGRES_URL else "?"
    source_url = (
        f"{POSTGRES_URL}{separator}options="
        f"{quote(f'-csearch_path={schema_name}', safe='')}"
    )
    inventory_schema = read_inventory(source, "schema")
    with psycopg.connect(POSTGRES_URL, autocommit=True) as setup:
        setup.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema_name)))
        try:
            for table in inventory_schema["tables"]:
                columns = sql.SQL(", ").join(
                    sql.SQL("{} {}").format(
                        sql.Identifier(column["name"]),
                        sql.SQL(_postgres_type(column)),
                    )
                    for column in table["columns"]
                )
                setup.execute(
                    sql.SQL("CREATE TABLE {}.{} ({})").format(
                        sql.Identifier(schema_name),
                        sql.Identifier(table["name"]),
                        columns,
                    )
                )
            setup.execute(
                sql.SQL(
                    "INSERT INTO {}.users "
                    "(id, email, password_digest, display_name, role, created_at, updated_at) "
                    "VALUES (1, %s, %s, %s, 0, %s, %s)"
                ).format(sql.Identifier(schema_name)),
                (
                    "person@example.test",
                    "$2b$12$G/L9JzELG9A40PFakYVkNuVxZB4vN51xKQpsVmljK1ONPvW42nWSK",
                    "Person",
                    datetime.datetime(2024, 1, 15, 14, 30),
                    datetime.datetime(2024, 1, 15, 14, 30),
                ),
            )

            src = rails2zb.load_source(source)
            findings = [finding.to_dict() for finding in rails2zb.build_findings(src)]
            decision_value = materialize_artifacts(decisions_for(findings), tmp_path)
            decisions = rails2zb.load_decisions_from_value(decision_value)
            first, second = tmp_path / "bundle-a", tmp_path / "bundle-b"
            one = rails2zb.extract(src, decisions, first, database_url=source_url)
            two = rails2zb.extract(src, decisions, second, database_url=source_url)

            assert one["databaseAdapter"] == "PostgreSQL"
            assert sum(item["rows"] for item in one["collections"]) == 1
            assert one == two
            assert _tree_digest(first) == _tree_digest(second)
        finally:
            setup.execute(
                sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema_name))
            )
