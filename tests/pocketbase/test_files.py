import json
import os
import sqlite3

import pytest

from tools.pocketbase import pb2zb

from .conftest import base_collection
from .test_extract import inventory_findings, write_decisions


def file_collection():
    return base_collection(
        indexes=[],
        fields=[
            {
                "id": "cover_field",
                "name": "cover",
                "type": "file",
                "maxSelect": 1,
                "system": False,
            },
            {
                "id": "docs_field",
                "name": "docs",
                "type": "file",
                "maxSelect": 3,
                "system": False,
            },
        ],
    )


def prepare_file_snapshot(
    pocketbase_snapshot, tmp_path, *, cover="cover_ü.png", docs=None
):
    collection = file_collection()
    schema, pb_data = pocketbase_snapshot([collection])
    docs = ["a.txt", "b.txt"] if docs is None else docs
    connection = sqlite3.connect(pb_data / "data.db")
    connection.execute(
        "INSERT INTO posts VALUES (?,?,?,?,?)",
        (
            "record00000001",
            "2020-01-01T00:00:00Z",
            "2020-01-02T00:00:00Z",
            cover,
            json.dumps(docs),
        ),
    )
    connection.commit()
    connection.close()
    findings = inventory_findings([collection], pb_data)
    decisions = write_decisions(tmp_path / "decisions.json", findings)
    return collection, schema, pb_data, decisions


def write_storage_file(pb_data, collection_id, record_id, filename, contents):
    path = pb_data / "storage" / collection_id / record_id / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(contents)
    return path


def test_extracts_only_referenced_files_and_installs_idempotently(
    pocketbase_snapshot, tmp_path
):
    collection, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path
    )
    expected = {
        "cover_ü.png": b"PNG",
        "a.txt": b"alpha",
        "b.txt": b"beta",
    }
    for filename, contents in expected.items():
        write_storage_file(
            pb_data, collection["id"], "record00000001", filename, contents
        )
    write_storage_file(
        pb_data, collection["id"], "orphan0000001", "unused.txt", b"orphan"
    )

    out = tmp_path / "bundle"
    manifest = pb2zb.extract_bundle(schema, pb_data, decisions, out)
    assert manifest["files"] == 3
    assert manifest["unreferencedStorage"] == [
        "posts_collection/orphan0000001/unused.txt"
    ]
    assert [entry["path"] for entry in manifest["storageFiles"]] == [
        "storage/posts/record00000001/a.txt",
        "storage/posts/record00000001/b.txt",
        "storage/posts/record00000001/cover_ü.png",
    ]
    assert not (out / "storage/posts/orphan0000001/unused.txt").exists()

    target = tmp_path / "zb_data"
    assert pb2zb.install_files(out, target) == {
        "files": 3,
        "installed": 3,
        "reused": 0,
    }
    assert pb2zb.install_files(out, target) == {
        "files": 3,
        "installed": 0,
        "reused": 3,
    }
    for filename, contents in expected.items():
        installed = target / "storage" / "posts" / "record00000001" / filename
        assert installed.read_bytes() == contents
        assert installed.stat().st_mode & 0o777 == 0o600
    assert (target / "storage" / "posts").stat().st_mode & 0o777 == 0o700


def test_missing_referenced_file_blocks_extraction(pocketbase_snapshot, tmp_path):
    _, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path, cover="missing.png", docs=[]
    )
    out = tmp_path / "bundle"
    with pytest.raises(pb2zb.PocketBaseError, match="referenced.*missing"):
        pb2zb.extract_bundle(schema, pb_data, decisions, out)
    assert not out.exists()


def test_empty_single_file_value_is_not_a_reference(pocketbase_snapshot, tmp_path):
    _, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path, cover="", docs=[]
    )
    manifest = pb2zb.extract_bundle(schema, pb_data, decisions, tmp_path / "bundle")
    assert manifest["files"] == 0


def test_public_and_reviewed_protected_file_fields_copy_bytes(
    pocketbase_snapshot, tmp_path
):
    collection = base_collection(
        indexes=[],
        fields=[
            {
                "id": "public_field",
                "name": "public_file",
                "type": "file",
                "system": False,
            },
            {
                "id": "protected_field",
                "name": "protected_file",
                "type": "file",
                "protected": True,
                "system": False,
            },
        ],
    )
    schema, pb_data = pocketbase_snapshot([collection])
    connection = sqlite3.connect(pb_data / "data.db")
    connection.execute(
        "INSERT INTO posts VALUES (?,?,?,?,?)",
        (
            "record00000001",
            "2020-01-01T00:00:00Z",
            "2020-01-02T00:00:00Z",
            "public.txt",
            "protected.txt",
        ),
    )
    connection.commit()
    connection.close()
    finding_id = "field.posts_collection.protected_field.options"
    replacement = tmp_path / "protected-field.json"
    replacement.write_text(
        json.dumps(
            {
                "zigbasePocketBaseReplacement": 1,
                "finding": finding_id,
                "kind": "field",
                "value": {
                    "id": "protected_field",
                    "name": "protected_file",
                    "required": False,
                    "unique": False,
                    "encrypted": False,
                    "searchable": False,
                    "hidden": False,
                    "type": "file",
                    "options": {"maxSelect": 1},
                },
            }
        )
    )
    decisions = write_decisions(
        tmp_path / "decisions.json",
        inventory_findings([collection], pb_data),
        artifacts={finding_id: replacement.name},
    )
    for filename in ("public.txt", "protected.txt"):
        write_storage_file(
            pb_data, collection["id"], "record00000001", filename, filename.encode()
        )

    manifest = pb2zb.extract_bundle(schema, pb_data, decisions, tmp_path / "bundle")
    assert manifest["files"] == 2


def test_extraction_does_not_require_source_write_access(pocketbase_snapshot, tmp_path):
    collection, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path, cover="cover.png", docs=[]
    )
    source = write_storage_file(
        pb_data, collection["id"], "record00000001", "cover.png", b"PNG"
    )
    source.chmod(0o444)
    try:
        manifest = pb2zb.extract_bundle(schema, pb_data, decisions, tmp_path / "bundle")
    finally:
        source.chmod(0o600)
    assert manifest["files"] == 1


@pytest.mark.parametrize("filename", ["../escape", "/absolute", "nested/file", "a\\b"])
def test_unsafe_file_references_are_rejected(pocketbase_snapshot, tmp_path, filename):
    _, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path, cover=filename, docs=[]
    )
    with pytest.raises(pb2zb.PocketBaseError, match="unsafe stored filename"):
        pb2zb.extract_bundle(schema, pb_data, decisions, tmp_path / "bundle")


def test_empty_filename_inside_multi_file_value_is_rejected(
    pocketbase_snapshot, tmp_path
):
    _, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path, cover="", docs=[""]
    )
    with pytest.raises(pb2zb.PocketBaseError, match="unsafe stored filename"):
        pb2zb.extract_bundle(schema, pb_data, decisions, tmp_path / "bundle")


@pytest.mark.parametrize("level", ["storage", "collection", "record", "file"])
def test_source_storage_symlinks_are_rejected(pocketbase_snapshot, tmp_path, level):
    collection, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path, cover="cover.png", docs=[]
    )
    external = tmp_path / "external"
    external.mkdir()
    (external / "cover.png").write_bytes(b"PNG")
    storage = pb_data / "storage"
    collection_dir = storage / collection["id"]
    record_dir = collection_dir / "record00000001"
    if level == "storage":
        storage.symlink_to(external, target_is_directory=True)
    elif level == "collection":
        storage.mkdir()
        collection_dir.symlink_to(external, target_is_directory=True)
    elif level == "record":
        collection_dir.mkdir(parents=True)
        record_dir.symlink_to(external, target_is_directory=True)
    else:
        record_dir.mkdir(parents=True)
        (record_dir / "cover.png").symlink_to(external / "cover.png")

    with pytest.raises(pb2zb.PocketBaseError, match="symbolic link"):
        pb2zb.extract_bundle(schema, pb_data, decisions, tmp_path / "bundle")


def test_collision_is_validated_before_any_file_is_written(
    pocketbase_snapshot, tmp_path
):
    collection, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path
    )
    for filename in ("cover_ü.png", "a.txt", "b.txt"):
        write_storage_file(
            pb_data, collection["id"], "record00000001", filename, filename.encode()
        )
    out = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, out)
    target = tmp_path / "target"
    collision = target / "storage/posts/record00000001/cover_ü.png"
    collision.parent.mkdir(parents=True)
    collision.write_bytes(b"different")

    with pytest.raises(pb2zb.PocketBaseError, match="different file already exists"):
        pb2zb.install_files(out, target)
    assert not (target / "storage/posts/record00000001/a.txt").exists()


@pytest.mark.parametrize("level", ["root", "storage", "collection", "record", "file"])
def test_target_symlinks_are_rejected(pocketbase_snapshot, tmp_path, level):
    collection, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path, cover="cover.png", docs=[]
    )
    write_storage_file(pb_data, collection["id"], "record00000001", "cover.png", b"PNG")
    out = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, out)
    external = tmp_path / "external-target"
    external.mkdir()
    target = tmp_path / "target"
    storage = target / "storage"
    collection_dir = storage / "posts"
    record_dir = collection_dir / "record00000001"
    if level == "root":
        target.symlink_to(external, target_is_directory=True)
    elif level == "storage":
        target.mkdir()
        storage.symlink_to(external, target_is_directory=True)
    elif level == "collection":
        storage.mkdir(parents=True)
        collection_dir.symlink_to(external, target_is_directory=True)
    elif level == "record":
        collection_dir.mkdir(parents=True)
        record_dir.symlink_to(external, target_is_directory=True)
    else:
        record_dir.mkdir(parents=True)
        (record_dir / "cover.png").symlink_to(external / "cover.png")

    with pytest.raises(pb2zb.PocketBaseError, match="symbolic link"):
        pb2zb.install_files(out, target)


def test_duplicate_destinations_and_tampered_bundles_are_rejected(
    pocketbase_snapshot, tmp_path
):
    collection, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path, cover="cover.png", docs=[]
    )
    write_storage_file(pb_data, collection["id"], "record00000001", "cover.png", b"PNG")
    duplicate = tmp_path / "duplicate"
    pb2zb.extract_bundle(schema, pb_data, decisions, duplicate)
    manifest_path = duplicate / "zigbase-pocketbase-bundle.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["storageFiles"].append(dict(manifest["storageFiles"][0]))
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(pb2zb.PocketBaseError, match="duplicate"):
        pb2zb.install_files(duplicate, tmp_path / "target-a")

    tampered = tmp_path / "tampered"
    pb2zb.extract_bundle(schema, pb_data, decisions, tampered)
    (tampered / "storage/posts/record00000001/cover.png").write_bytes(b"tampered")
    with pytest.raises(pb2zb.PocketBaseError, match="digest mismatch"):
        pb2zb.install_files(tampered, tmp_path / "target-b")


def test_install_files_cli_reports_counts(pocketbase_snapshot, tmp_path, capsys):
    collection, schema, pb_data, decisions = prepare_file_snapshot(
        pocketbase_snapshot, tmp_path, cover="cover.png", docs=[]
    )
    write_storage_file(pb_data, collection["id"], "record00000001", "cover.png", b"PNG")
    bundle = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, bundle)
    target = tmp_path / "target"
    assert (
        pb2zb.main(
            [
                "install-files",
                "--bundle",
                os.fspath(bundle),
                "--target-data-dir",
                os.fspath(target),
            ]
        )
        == 0
    )
    assert json.loads(capsys.readouterr().out) == {
        "zigbase_pocketbase_file_install": 1,
        "files": 1,
        "installed": 1,
        "reused": 0,
    }
