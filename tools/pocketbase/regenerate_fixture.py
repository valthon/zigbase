#!/usr/bin/env python3
"""Regenerate the pinned PocketBase v0.39.11 migration fixture.

This maintainer-only command downloads and executes PocketBase only when no local
``--pocketbase`` binary is supplied. Normal tests never invoke it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sqlite3
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path


VERSION = "0.39.11"
ASSET = f"pocketbase_{VERSION}_linux_amd64.zip"
ASSET_URL = (
    f"https://github.com/pocketbase/pocketbase/releases/download/v{VERSION}/{ASSET}"
)
ASSET_SHA256 = "08b9fcda0d5fd42cb315dc15a36dfa121c993855bd635f01d347c31b4328ec34"
BCRYPT_HASH = "$2a$04$9m5ylg8xGlUcv0SJbn8IZuhPCNsiI2KNNfiLK7pnb/VQsfnZwfe96"
FIXED_TOKEN_KEY = "fixture-token-key-not-a-real-secret-000000000000000"
REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO / "tests" / "pocketbase" / "fixtures" / f"v{VERSION}"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def acquire_pocketbase(supplied: Path | None, work: Path) -> Path:
    if supplied is not None:
        binary = supplied.resolve(strict=True)
    else:
        archive = work / ASSET
        with urllib.request.urlopen(ASSET_URL, timeout=60) as response:  # noqa: S310
            archive.write_bytes(response.read())
        if sha256(archive) != ASSET_SHA256:
            raise RuntimeError("PocketBase release asset digest mismatch")
        with zipfile.ZipFile(archive) as bundle:
            member = bundle.getinfo("pocketbase")
            if member.is_dir() or Path(member.filename).name != member.filename:
                raise RuntimeError("PocketBase release archive has an unsafe layout")
            bundle.extract(member, work)
        binary = work / "pocketbase"
        binary.chmod(0o755)
    version = subprocess.run(
        [binary, "--version"], check=True, text=True, capture_output=True
    ).stdout.strip()
    if version != f"pocketbase version {VERSION}":
        raise RuntimeError(f"expected PocketBase {VERSION}, got {version!r}")
    return binary


def rename_stored_file(
    data: Path, collection: str, record: str, old: str, new: str
) -> None:
    directory = data / "storage" / collection / record
    (directory / old).replace(directory / new)
    old_attrs = directory / f"{old}.attrs"
    if old_attrs.exists():
        old_attrs.replace(directory / f"{new}.attrs")


def normalize_snapshot(data: Path) -> None:
    database = data / "data.db"
    connection = sqlite3.connect(database)
    try:
        member = connection.execute(
            "SELECT avatar FROM members WHERE id='member000000001'"
        ).fetchone()[0]
        post = connection.execute(
            "SELECT cover, gallery FROM posts WHERE id='post00000000001'"
        ).fetchone()
        secret = connection.execute(
            "SELECT document FROM secrets WHERE id='secret000000001'"
        ).fetchone()[0]
        gallery = json.loads(post[1])
        renames = [
            ("members_fixture1", "member000000001", member, "avatar_fixture.txt"),
            ("posts_fixture001", "post00000000001", post[0], "cover_fixture.txt"),
            (
                "posts_fixture001",
                "post00000000001",
                gallery[0],
                "gallery_a_fixture.txt",
            ),
            (
                "posts_fixture001",
                "post00000000001",
                gallery[1],
                "gallery_b_fixture.txt",
            ),
            (
                "secrets_fixture1",
                "secret000000001",
                secret,
                "secret_fixture.txt",
            ),
        ]
        for collection, record, old, new in renames:
            rename_stored_file(data, collection, record, old, new)
        connection.execute(
            "UPDATE members SET password=?, tokenKey=?, avatar=?, created=?, updated=? WHERE id=?",
            (
                BCRYPT_HASH,
                FIXED_TOKEN_KEY,
                "avatar_fixture.txt",
                "2019-01-01T01:02:03.004Z",
                "2019-02-01T01:02:03.004Z",
                "member000000001",
            ),
        )
        connection.execute(
            "UPDATE posts SET cover=?, gallery=?, created=?, updated=? WHERE id=?",
            (
                "cover_fixture.txt",
                json.dumps(
                    ["gallery_a_fixture.txt", "gallery_b_fixture.txt"],
                    separators=(",", ":"),
                ),
                "2020-01-01T01:02:03.004Z",
                "2020-03-01T01:02:03.004Z",
                "post00000000001",
            ),
        )
        connection.execute(
            "UPDATE posts SET created=?, updated=? WHERE id=?",
            (
                "2020-02-01T01:02:03.004Z",
                "2020-02-02T01:02:03.004Z",
                "post00000000002",
            ),
        )
        connection.execute(
            "UPDATE secrets SET document=?, created=?, updated=? WHERE id=?",
            (
                "secret_fixture.txt",
                "2021-01-01T01:02:03.004Z",
                "2021-01-02T01:02:03.004Z",
                "secret000000001",
            ),
        )
        connection.execute("DELETE FROM _superusers")
        connection.commit()
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.execute("VACUUM")
    finally:
        connection.close()
    (data / "auxiliary.db").unlink(missing_ok=True)
    (data / "types.d.ts").unlink(missing_ok=True)


def export_schema(data: Path, destination: Path) -> None:
    connection = sqlite3.connect(data / "data.db")
    connection.row_factory = sqlite3.Row
    try:
        rows = connection.execute(
            "SELECT id, system, type, name, fields, indexes, listRule, viewRule, "
            "createRule, updateRule, deleteRule, options FROM _collections "
            "WHERE system=0 ORDER BY name"
        ).fetchall()
    finally:
        connection.close()
    collections = []
    for row in rows:
        value = {
            "id": row["id"],
            "system": bool(row["system"]),
            "type": row["type"],
            "name": row["name"],
            "fields": json.loads(row["fields"]),
            "indexes": json.loads(row["indexes"]),
            "listRule": row["listRule"],
            "viewRule": row["viewRule"],
            "createRule": row["createRule"],
            "updateRule": row["updateRule"],
            "deleteRule": row["deleteRule"],
        }
        options = json.loads(row["options"])
        for key in ("manageRule", "passwordAuth", "oauth2", "mfa", "otp"):
            if key in options:
                value[key] = options[key]
        collections.append(value)
    destination.write_text(
        json.dumps(collections, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_manifest(out: Path) -> None:
    files = []
    for path in sorted(item for item in out.rglob("*") if item.is_file()):
        if path.name == "fixture-manifest.json":
            continue
        files.append(
            {
                "path": path.relative_to(out).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
        )
    manifest = {
        "zigbasePocketBaseFixture": 1,
        "pocketbaseVersion": VERSION,
        "releaseAsset": {
            "url": ASSET_URL,
            "sha256": ASSET_SHA256,
        },
        "containsSecrets": False,
        "knownCredential": "ada@example.test / migrated-secret",
        "files": files,
    }
    (out / "fixture-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def generate_snapshot(binary: Path, migration_source: Path, work: Path) -> Path:
    migrations = work / "pb_migrations"
    migrations.mkdir(parents=True)
    shutil.copyfile(migration_source, migrations / "1700000000_fixture.js")
    data = work / "pb_data"
    subprocess.run(
        [
            binary,
            "migrate",
            "up",
            "--dir",
            data,
            "--migrationsDir",
            migrations,
            "--automigrate=false",
        ],
        check=True,
    )
    normalize_snapshot(data)
    return data


def logical_snapshot(data: Path, work: Path) -> dict[str, object]:
    schema = work / "schema.json"
    export_schema(data, schema)
    connection = sqlite3.connect(data / "data.db")
    try:
        rows = {}
        for table in ("members", "posts", "secrets"):
            columns = [
                row[1]
                for row in connection.execute(
                    f'PRAGMA table_info("{table}")'
                ).fetchall()
            ]
            rows[table] = [
                dict(zip(columns, values, strict=True))
                for values in connection.execute(
                    f'SELECT * FROM "{table}" ORDER BY "id"'
                ).fetchall()
            ]
    finally:
        connection.close()
    storage = {
        path.relative_to(data / "storage").as_posix(): sha256(path)
        for path in sorted((data / "storage").rglob("*"))
        if path.is_file()
    }
    return {
        "schema": json.loads(schema.read_text()),
        "rows": rows,
        "storage": storage,
    }


def regenerate(out: Path, supplied_binary: Path | None, force: bool) -> None:
    generated = [out / "pb_data", out / "pb_schema.json", out / "fixture-manifest.json"]
    if any(path.exists() for path in generated) and not force:
        raise RuntimeError(
            "generated fixture files already exist; pass --force to replace"
        )
    with tempfile.TemporaryDirectory(prefix="pb-fixture-") as temporary:
        work = Path(temporary)
        binary = acquire_pocketbase(supplied_binary, work)
        migration_source = out / "generation" / "1700000000_fixture.js"
        data = generate_snapshot(binary, migration_source, work / "first")
        repeated = generate_snapshot(binary, migration_source, work / "second")
        if logical_snapshot(data, work / "first") != logical_snapshot(
            repeated, work / "second"
        ):
            raise RuntimeError(
                "PocketBase fixture generation is not logically repeatable"
            )
        out.mkdir(parents=True, exist_ok=True)
        if (out / "pb_data").exists():
            shutil.rmtree(out / "pb_data")
        shutil.copytree(data, out / "pb_data")
        export_schema(out / "pb_data", out / "pb_schema.json")
        write_manifest(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--pocketbase", type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    regenerate(args.out, args.pocketbase, args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
