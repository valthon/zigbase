import json
import sqlite3
import subprocess

import pytest

from tools.pocketbase import pb2zb

from .conftest import base_collection


def write_decisions(path, findings, choices=None, artifacts=None):
    choices = choices or {}
    artifacts = artifacts or {}
    decisions = []
    for finding in findings:
        if not finding.choices:
            continue
        choice = choices.get(finding.id, finding.choices[0])
        value = {
            "id": finding.id,
            "choice": choice,
            "rationale": f"Reviewed {finding.code} for the synthetic migration fixture.",
        }
        if finding.id in artifacts:
            value["artifact"] = artifacts[finding.id]
        decisions.append(value)
    path.write_text(
        json.dumps(
            {
                "zigbasePocketBaseDecisions": 1,
                "sourceVersion": "0.39.11",
                "decisions": decisions,
            }
        )
    )
    return path


def inventory_findings(collections, pb_data):
    return pb2zb.collect_findings(collections, pb_data)


def tree_bytes(root):
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def test_wal_snapshot_is_repeatable_and_never_mutates_source(
    pocketbase_snapshot, tmp_path
):
    collections = [base_collection(indexes=[])]
    schema, pb_data = pocketbase_snapshot(collections)
    database = pb_data / "data.db"
    connection = sqlite3.connect(database)
    assert connection.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    connection.execute(
        "INSERT INTO posts VALUES (?,?,?,?)",
        ("post0000000001", "2021-01-01 00:00:00.123Z", "2021-01-02 00:00:00Z", "First"),
    )
    connection.commit()
    connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    connection.close()
    assert database.read_bytes()[18:20] == b"\x02\x02"

    findings = inventory_findings(collections, pb_data)
    decisions = write_decisions(tmp_path / "decisions.json", findings)
    before = tree_bytes(pb_data)

    first_inventory = pb2zb.build_inventory(schema, pb_data)
    second_inventory = pb2zb.build_inventory(schema, pb_data)
    first_bundle = pb2zb.extract_bundle(
        schema, pb_data, decisions, tmp_path / "bundle-a"
    )
    second_bundle = pb2zb.extract_bundle(
        schema, pb_data, decisions, tmp_path / "bundle-b"
    )

    assert first_inventory == second_inventory
    assert first_bundle["databaseSha256"] == second_bundle["databaseSha256"]
    assert tree_bytes(pb_data) == before


def test_extract_maps_schema_rows_relations_and_public_rules_deterministically(
    pocketbase_snapshot, tmp_path, zigbase_binary
):
    authors = base_collection(
        id="authors_collection",
        name="authors",
        indexes=[],
        fields=[{"id": "author_name", "name": "name", "type": "text", "system": False}],
    )
    posts = base_collection(
        listRule="",
        indexes=["CREATE UNIQUE INDEX idx_posts_title ON posts (title)"],
        fields=[
            {"id": "title_field", "name": "title", "type": "text", "system": False},
            {"id": "live_field", "name": "live", "type": "bool", "system": False},
            {
                "id": "score_field",
                "name": "score",
                "type": "number",
                "onlyInt": True,
                "system": False,
            },
            {"id": "meta_field", "name": "meta", "type": "json", "system": False},
            {
                "id": "tags_field",
                "name": "tags",
                "type": "select",
                "values": ["a", "b"],
                "maxSelect": 2,
                "system": False,
            },
            {
                "id": "author_field",
                "name": "author",
                "type": "relation",
                "collectionId": "authors_collection",
                "maxSelect": 1,
                "system": False,
            },
        ],
    )
    collections = [posts, authors]
    schema, pb_data = pocketbase_snapshot(collections)
    connection = sqlite3.connect(pb_data / "data.db")
    connection.execute(
        "INSERT INTO authors VALUES (?,?,?,?)",
        ("author000000001", "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z", "Ada"),
    )
    connection.execute(
        "INSERT INTO posts VALUES (?,?,?,?,?,?,?,?,?)",
        (
            "post0000000001",
            "2021-01-01T00:00:00.123Z",
            "2021-01-02T00:00:00Z",
            "First",
            1,
            42,
            '{"nested":true}',
            '["a","b"]',
            "author000000001",
        ),
    )
    connection.commit()
    connection.close()
    findings = inventory_findings(collections, pb_data)
    decisions = write_decisions(tmp_path / "decisions.json", findings)

    first = tmp_path / "bundle-a"
    second = tmp_path / "bundle-b"
    manifest = pb2zb.extract_bundle(schema, pb_data, decisions, first)
    pb2zb.extract_bundle(schema, pb_data, decisions, second)
    assert tree_bytes(first) == tree_bytes(second)
    assert pb2zb.verify_bundle(first) == manifest

    target_schema = json.loads((first / "schema.json").read_text())
    checked = subprocess.run(
        [
            str(zigbase_binary),
            "schema",
            "check-rules",
            "--json",
            str(first / "schema.json"),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    # The deliberate public list rule is a warning/judgment exit, never a parse error.
    assert checked.returncode == 2, checked.stderr
    summary = [json.loads(line) for line in checked.stdout.splitlines()][-1]
    assert summary["summary"] is True
    assert summary["errors"] == 0
    by_name = {
        collection["name"]: collection for collection in target_schema["collections"]
    }
    assert "id" not in by_name["posts"]
    assert by_name["posts"]["listRule"] == "@public"
    assert by_name["posts"]["indexes"] == [
        {"fields": ["title"], "name": "idx_posts_title", "unique": True}
    ]
    author_field = next(
        field for field in by_name["posts"]["fields"] if field["name"] == "author"
    )
    assert author_field["id"] == "author_field"
    assert author_field["options"]["targetCollectionId"] == "authors"

    row = json.loads((first / "imports" / "posts.ndjson").read_text())
    assert row == {
        "author": "author000000001",
        "created": "2021-01-01T00:00:00.123Z",
        "id": "post0000000001",
        "live": True,
        "meta": {"nested": True},
        "score": 42,
        "tags": ["a", "b"],
        "title": "First",
        "updated": "2021-01-02T00:00:00Z",
    }
    import_manifest = json.loads((first / "imports" / "manifest.json").read_text())
    assert import_manifest == {
        "zigbaseImportManifest": 1,
        "collections": [
            {"collection": "authors", "file": "authors.ndjson"},
            {"collection": "posts", "file": "posts.ndjson"},
        ],
    }
    target_data = tmp_path / "target-data"
    applied = subprocess.run(
        [
            str(zigbase_binary),
            "schema",
            "apply",
            str(first / "schema.json"),
            "--data-dir",
            str(target_data),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert applied.returncode == 0, applied.stderr
    imported = subprocess.run(
        [
            str(zigbase_binary),
            "import",
            "--manifest",
            str(first / "imports" / "manifest.json"),
            "--preserve-timestamps",
            "--data-dir",
            str(target_data),
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert imported.returncode == 0, imported.stderr
    target = sqlite3.connect(target_data / "data.db")
    migrated = target.execute(
        "SELECT created, updated, author, live, score FROM posts WHERE id=?",
        ("post0000000001",),
    ).fetchone()
    target.close()
    assert migrated == (
        "2021-01-01T00:00:00Z",
        "2021-01-02T00:00:00Z",
        "author000000001",
        1,
        42,
    )


def test_backtick_index_and_empty_optional_values_preserve_target_semantics(
    pocketbase_snapshot, tmp_path
):
    authors = base_collection(
        id="authors_collection", name="authors", indexes=[], fields=[]
    )
    posts = base_collection(
        indexes=["CREATE UNIQUE INDEX `idx_posts_title` ON `posts` (`title`)"],
        fields=[
            {
                "id": "title_field",
                "name": "title",
                "type": "text",
                "required": True,
                "system": False,
            },
            {
                "id": "status_field",
                "name": "status",
                "type": "select",
                "values": ["draft", "published"],
                "required": False,
                "system": False,
            },
            {
                "id": "author_field",
                "name": "author",
                "type": "relation",
                "collectionId": "authors_collection",
                "required": False,
                "system": False,
            },
        ],
    )
    schema, pb_data = pocketbase_snapshot([posts, authors])
    connection = sqlite3.connect(pb_data / "data.db")
    connection.execute(
        "INSERT INTO posts VALUES (?,?,?,?,?,?)",
        (
            "post0000000001",
            "2021-01-01 00:00:00Z",
            "2021-01-02 00:00:00Z",
            "First",
            "",
            "",
        ),
    )
    connection.commit()
    connection.close()
    findings = inventory_findings([posts, authors], pb_data)
    decisions = write_decisions(tmp_path / "decisions.json", findings)
    out = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, out)
    document = json.loads((out / "schema.json").read_text())
    posts_schema = next(c for c in document["collections"] if c["name"] == "posts")
    assert posts_schema["indexes"] == [
        {"fields": ["title"], "name": "idx_posts_title", "unique": True}
    ]
    row = json.loads((out / "imports" / "posts.ndjson").read_text())
    assert row["status"] is None
    assert row["author"] is None


def test_verified_auth_rule_and_password_field_minimum_map_to_auth_options(
    pocketbase_snapshot, tmp_path
):
    members = base_collection(
        id="members_collection",
        name="members",
        type="auth",
        authRule=" verified = true ",
        indexes=[],
        fields=[
            {
                "id": "password_field",
                "name": "password",
                "type": "password",
                "min": 14,
                "hidden": True,
                "system": True,
            }
        ],
    )
    schema, pb_data = pocketbase_snapshot([members])
    decisions = write_decisions(
        tmp_path / "decisions.json", inventory_findings([members], pb_data)
    )
    out = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, out)
    document = json.loads((out / "schema.json").read_text())
    assert document["collections"][0]["options"]["auth"] == {
        "identityFields": ["email"],
        "minPasswordLength": 14,
        "require_verified": True,
    }


def test_materialized_view_without_source_timestamps_can_be_extracted(
    pocketbase_snapshot, tmp_path
):
    view = base_collection(
        id="summary_collection",
        name="summary",
        type="view",
        fields=[],
        indexes=[],
    )
    schema, pb_data = pocketbase_snapshot([view])
    replacement = tmp_path / "summary.json"
    replacement.write_text(
        json.dumps(
            {
                "zigbasePocketBaseReplacement": 1,
                "finding": "collection.summary_collection.view",
                "kind": "collection",
                "value": {
                    "name": "summary",
                    "type": "base",
                    "fields": [],
                    "indexes": [],
                    "listRule": None,
                    "viewRule": None,
                    "createRule": None,
                    "updateRule": None,
                    "deleteRule": None,
                    "options": {},
                },
            }
        )
    )
    findings = inventory_findings([view], pb_data)
    decisions = write_decisions(
        tmp_path / "decisions.json",
        findings,
        choices={"collection.summary_collection.view": "materialize"},
        artifacts={"collection.summary_collection.view": replacement.name},
    )
    out = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, out)
    assert json.loads((out / "imports" / "summary.ndjson").read_text()) == {
        "id": "view00000000001"
    }


def test_replacement_collection_cannot_reintroduce_a_reserved_field_name():
    with pytest.raises(pb2zb.PocketBaseError, match="invalid or duplicate fields"):
        pb2zb._validate_target_schema_links(  # noqa: SLF001 - converter invariant
            {
                "collections": [
                    {
                        "name": "contacts",
                        "fields": [{"name": "Email", "type": "text"}],
                        "indexes": [],
                    }
                ]
            }
        )


def test_extract_separates_auth_rows_and_preserves_only_migratable_credentials(
    pocketbase_snapshot, tmp_path, zigbase_binary
):
    members = base_collection(
        id="members_collection",
        name="members",
        type="auth",
        indexes=[],
        fields=[{"id": "bio_field", "name": "bio", "type": "text", "system": False}],
    )
    schema, pb_data = pocketbase_snapshot([members])
    bcrypt_hash = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy"
    connection = sqlite3.connect(pb_data / "data.db")
    connection.execute(
        "INSERT INTO members VALUES (?,?,?,?,?,?,?,?,?)",
        (
            "member00000001",
            "2019-01-01T00:00:00Z",
            "2019-01-02T00:00:00Z",
            "hello",
            "user@example.test",
            0,
            1,
            bcrypt_hash,
            "source-token-key-must-not-leak",
        ),
    )
    connection.commit()
    connection.close()
    decisions = write_decisions(
        tmp_path / "decisions.json", inventory_findings([members], pb_data)
    )
    out = tmp_path / "bundle"
    manifest = pb2zb.extract_bundle(schema, pb_data, decisions, out)
    row = json.loads((out / "imports" / "auth" / "members.ndjson").read_text())
    assert row["passwordHash"] == bcrypt_hash
    assert row["verified"] is True
    assert row["email"] == "user@example.test"
    assert "tokenKey" not in row
    assert "emailVisibility" not in row
    assert manifest["authImports"] == [
        {
            "collection": "members",
            "file": "imports/auth/members.ndjson",
            "rows": 1,
        }
    ]
    assert (
        json.loads((out / "imports" / "manifest.json").read_text())["collections"] == []
    )
    target_data = tmp_path / "target-auth-data"
    applied = subprocess.run(
        [
            str(zigbase_binary),
            "schema",
            "apply",
            str(out / "schema.json"),
            "--data-dir",
            str(target_data),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert applied.returncode == 0, applied.stderr
    imported = subprocess.run(
        [
            str(zigbase_binary),
            "import",
            "--collection",
            "members",
            "--legacy-hashes",
            "bcrypt",
            "--preserve-timestamps",
            "--data-dir",
            str(target_data),
            str(out / "imports" / "auth" / "members.ndjson"),
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert imported.returncode == 0, imported.stderr
    target = sqlite3.connect(target_data / "data.db")
    migrated = target.execute(
        'SELECT "passwordHash", "verified", "created", "updated", "tokenKey" '
        'FROM "members" WHERE "id"=?',
        ("member00000001",),
    ).fetchone()
    target.close()
    assert migrated[0].startswith("$zblegacy$bcrypt$")
    assert migrated[1:4] == (
        1,
        "2019-01-01T00:00:00Z",
        "2019-01-02T00:00:00Z",
    )
    assert migrated[4] != "source-token-key-must-not-leak"


def test_extract_refuses_bad_bcrypt_without_leaking_it(pocketbase_snapshot, tmp_path):
    members = base_collection(
        id="members_collection", name="members", type="auth", indexes=[], fields=[]
    )
    schema, pb_data = pocketbase_snapshot([members])
    bad_hash = "$2b$10$not-a-valid-secret-hash"
    connection = sqlite3.connect(pb_data / "data.db")
    connection.execute(
        "INSERT INTO members VALUES (?,?,?,?,?,?,?,?)",
        (
            "member00000002",
            "2019-01-01",
            "2019-01-02",
            "user@example.test",
            0,
            0,
            bad_hash,
            "token",
        ),
    )
    connection.commit()
    connection.close()
    decisions = write_decisions(
        tmp_path / "decisions.json", inventory_findings([members], pb_data)
    )
    out = tmp_path / "bundle"
    with pytest.raises(pb2zb.PocketBaseError) as caught:
        pb2zb.extract_bundle(schema, pb_data, decisions, out)
    assert "bcrypt credential" in str(caught.value)
    assert bad_hash not in str(caught.value)
    assert not out.exists()


def test_geo_point_requires_and_honors_json_or_omit_decision(
    pocketbase_snapshot, tmp_path
):
    locations = base_collection(
        id="locations_collection",
        name="locations",
        indexes=[],
        fields=[
            {"id": "point_field", "name": "point", "type": "geoPoint", "system": False}
        ],
    )
    schema, pb_data = pocketbase_snapshot([locations])
    connection = sqlite3.connect(pb_data / "data.db")
    connection.execute(
        "INSERT INTO locations VALUES (?,?,?,?)",
        ("location0000001", "2020-01-01", "2020-01-02", '{"lon":1.5,"lat":2.5}'),
    )
    connection.commit()
    connection.close()
    findings = inventory_findings([locations], pb_data)
    finding_id = "field.locations_collection.point_field.geoPoint"

    json_decisions = write_decisions(
        tmp_path / "json-decisions.json", findings, {finding_id: "json"}
    )
    json_out = tmp_path / "json-bundle"
    pb2zb.extract_bundle(schema, pb_data, json_decisions, json_out)
    target_field = json.loads((json_out / "schema.json").read_text())["collections"][0][
        "fields"
    ][0]
    assert target_field["type"] == "json"
    assert json.loads((json_out / "imports" / "locations.ndjson").read_text())[
        "point"
    ] == {
        "lon": 1.5,
        "lat": 2.5,
    }

    omit_decisions = write_decisions(
        tmp_path / "omit-decisions.json", findings, {finding_id: "omit"}
    )
    omit_out = tmp_path / "omit-bundle"
    pb2zb.extract_bundle(schema, pb_data, omit_decisions, omit_out)
    assert (
        json.loads((omit_out / "schema.json").read_text())["collections"][0]["fields"]
        == []
    )
    assert "point" not in json.loads(
        (omit_out / "imports" / "locations.ndjson").read_text()
    )


def test_user_autodate_requires_history_preserving_date_decision(
    pocketbase_snapshot, tmp_path
):
    events = base_collection(
        id="events_collection",
        name="events",
        indexes=[],
        fields=[
            {
                "id": "happened_field",
                "name": "happened",
                "type": "autodate",
                "onCreate": True,
                "onUpdate": True,
                "system": False,
            }
        ],
    )
    schema, pb_data = pocketbase_snapshot([events])
    connection = sqlite3.connect(pb_data / "data.db")
    connection.execute(
        "INSERT INTO events VALUES (?,?,?,?)",
        ("event000000001", "2020-01-01", "2020-01-02", "2010-03-04T05:06:07Z"),
    )
    connection.commit()
    connection.close()
    findings = inventory_findings([events], pb_data)
    assert [finding.code for finding in findings] == ["AutoDateRequiresMapping"]
    decisions = write_decisions(tmp_path / "decisions.json", findings)
    out = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, out)
    field = json.loads((out / "schema.json").read_text())["collections"][0]["fields"][0]
    assert field["type"] == "date"
    assert json.loads((out / "imports" / "events.ndjson").read_text())["happened"] == (
        "2010-03-04T05:06:07Z"
    )


def test_conventional_pocketbase_timestamps_are_system_import_seams(
    pocketbase_snapshot, tmp_path
):
    timestamps = [
        {
            "id": "created_field_1",
            "name": "created",
            "type": "autodate",
            "onCreate": True,
            "onUpdate": False,
            "system": False,
        },
        {
            "id": "updated_field_1",
            "name": "updated",
            "type": "autodate",
            "onCreate": True,
            "onUpdate": True,
            "system": False,
        },
    ]
    collection = base_collection(fields=[*timestamps, *base_collection()["fields"]])
    schema, pb_data = pocketbase_snapshot([collection])
    assert inventory_findings([collection], pb_data) == []
    decisions = write_decisions(tmp_path / "decisions.json", [])
    out = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, out)
    fields = json.loads((out / "schema.json").read_text())["collections"][0]["fields"]
    assert [field["name"] for field in fields] == ["title"]


def test_omitting_a_relation_target_refuses_a_dangling_target_schema(
    pocketbase_snapshot, tmp_path
):
    authors = base_collection(
        id="authors_collection", name="authors", indexes=[], fields=[]
    )
    posts = base_collection(
        indexes=[],
        fields=[
            {
                "id": "author_field",
                "name": "author",
                "type": "relation",
                "collectionId": "authors_collection",
                "system": False,
            }
        ],
    )
    # An invalid target collection name creates a replace-or-omit decision.
    authors["name"] = "bad-name"
    schema, pb_data = pocketbase_snapshot([authors, posts])
    findings = inventory_findings([authors, posts], pb_data)
    omit_id = "collection.authors_collection.identifier"
    decisions = write_decisions(
        tmp_path / "decisions.json", findings, {omit_id: "omit"}
    )
    with pytest.raises(pb2zb.PocketBaseError, match="omitted/unknown collection"):
        pb2zb.extract_bundle(schema, pb_data, decisions, tmp_path / "bundle")


def test_replacement_artifact_is_typed_copied_and_applied(
    pocketbase_snapshot, tmp_path
):
    posts = base_collection(listRule="@collection.teams.owner = @request.auth.id")
    schema, pb_data = pocketbase_snapshot([posts])
    findings = inventory_findings([posts], pb_data)
    finding_id = "rule.posts_collection.listRule.replacement"
    replacement = tmp_path / "list-rule.json"
    replacement.write_text(
        json.dumps(
            {
                "zigbasePocketBaseReplacement": 1,
                "finding": finding_id,
                "kind": "rule",
                "value": "@request.auth.id != ''",
            }
        )
    )
    decisions = write_decisions(
        tmp_path / "decisions.json",
        findings,
        artifacts={finding_id: replacement.name},
    )
    out = tmp_path / "bundle"
    manifest = pb2zb.extract_bundle(schema, pb_data, decisions, out)
    assert json.loads((out / "schema.json").read_text())["collections"][0][
        "listRule"
    ] == ("@request.auth.id != ''")
    assert manifest["replacementArtifacts"][0]["finding"] == finding_id
    assert (
        out / manifest["replacementArtifacts"][0]["path"]
    ).read_bytes() == replacement.read_bytes()
    bundled_decisions = json.loads((out / "decisions.json").read_text())
    bundled = next(
        value for value in bundled_decisions["decisions"] if value["id"] == finding_id
    )
    assert bundled["artifact"] == manifest["replacementArtifacts"][0]["path"]


def test_extract_refuses_symlinked_database(pocketbase_snapshot, tmp_path):
    collection = base_collection()
    schema, pb_data = pocketbase_snapshot([collection])
    findings = inventory_findings([collection], pb_data)
    database = pb_data / "data.db"
    real_database = tmp_path / "snapshot.db"
    database.replace(real_database)
    database.symlink_to(real_database)

    decisions = write_decisions(tmp_path / "decisions.json", findings)
    with pytest.raises(pb2zb.PocketBaseError, match="symbolic link"):
        pb2zb.extract_bundle(schema, pb_data, decisions, tmp_path / "bundle")


def test_extract_refuses_symlinked_replacement_artifact(pocketbase_snapshot, tmp_path):
    collection = base_collection(listRule="@collection.teams.owner != ''")
    schema, pb_data = pocketbase_snapshot([collection])
    findings = inventory_findings([collection], pb_data)
    finding_id = "rule.posts_collection.listRule.replacement"
    real_artifact = tmp_path / "real-rule.json"
    real_artifact.write_text(
        json.dumps(
            {
                "zigbasePocketBaseReplacement": 1,
                "finding": finding_id,
                "kind": "rule",
                "value": "@request.auth.id != ''",
            }
        )
    )
    linked_artifact = tmp_path / "linked-rule.json"
    linked_artifact.symlink_to(real_artifact)
    decisions = write_decisions(
        tmp_path / "decisions.json",
        findings,
        artifacts={finding_id: linked_artifact.name},
    )

    with pytest.raises(pb2zb.PocketBaseError, match="missing, unsafe"):
        pb2zb.extract_bundle(schema, pb_data, decisions, tmp_path / "bundle")


def test_bundle_digest_detects_tampering_and_unmanifested_files(
    pocketbase_snapshot, tmp_path
):
    collection = base_collection()
    schema, pb_data = pocketbase_snapshot([collection])
    decisions = write_decisions(
        tmp_path / "decisions.json", inventory_findings([collection], pb_data)
    )
    out = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, out)
    (out / "schema.json").write_text("{}\n")
    with pytest.raises(pb2zb.PocketBaseError, match="digest mismatch"):
        pb2zb.verify_bundle(out)

    clean = tmp_path / "clean"
    pb2zb.extract_bundle(schema, pb_data, decisions, clean)
    (clean / "extra.txt").write_text("not manifested")
    with pytest.raises(pb2zb.PocketBaseError, match="unmanifested"):
        pb2zb.verify_bundle(clean)


def test_bundle_verification_refuses_symlinked_output(pocketbase_snapshot, tmp_path):
    collection = base_collection()
    schema, pb_data = pocketbase_snapshot([collection])
    decisions = write_decisions(
        tmp_path / "decisions.json", inventory_findings([collection], pb_data)
    )
    out = tmp_path / "bundle"
    pb2zb.extract_bundle(schema, pb_data, decisions, out)
    bundled_schema = out / "schema.json"
    external = tmp_path / "external-schema.json"
    external.write_bytes(bundled_schema.read_bytes())
    bundled_schema.unlink()
    bundled_schema.symlink_to(external)

    with pytest.raises(pb2zb.PocketBaseError, match="missing or unsafe"):
        pb2zb.verify_bundle(out)

    clean = tmp_path / "clean-symlink"
    pb2zb.extract_bundle(schema, pb_data, decisions, clean)
    external_directory = tmp_path / "external-directory"
    external_directory.mkdir()
    (clean / "unmanifested-link").symlink_to(
        external_directory, target_is_directory=True
    )
    with pytest.raises(pb2zb.PocketBaseError, match="symbolic link"):
        pb2zb.verify_bundle(clean)


def test_extract_refuses_unacknowledged_findings_and_nonempty_output(
    pocketbase_snapshot, tmp_path
):
    collection = base_collection(listRule="")
    schema, pb_data = pocketbase_snapshot([collection])
    empty_decisions = write_decisions(tmp_path / "decisions.json", [])
    with pytest.raises(pb2zb.PocketBaseError, match="unacknowledged"):
        pb2zb.extract_bundle(schema, pb_data, empty_decisions, tmp_path / "bundle")

    valid = write_decisions(
        tmp_path / "valid.json", inventory_findings([collection], pb_data)
    )
    out = tmp_path / "existing"
    out.mkdir()
    (out / "keep.txt").write_text("keep")
    with pytest.raises(pb2zb.PocketBaseError, match="must not exist"):
        pb2zb.extract_bundle(schema, pb_data, valid, out)
    assert (out / "keep.txt").read_text() == "keep"
