import json
import sqlite3
from pathlib import Path

import pytest

from tools.pocketbase import pb2zb

from .conftest import base_collection


def test_clean_inventory_is_deterministic_and_returns_zero(
    pocketbase_snapshot, tmp_path, capsys
):
    schema, pb_data = pocketbase_snapshot([base_collection()])
    out = tmp_path / "inventory.json"
    assert (
        pb2zb.main(
            [
                "inventory",
                "--schema",
                str(schema),
                "--pb-data",
                str(pb_data),
                "--out",
                str(out),
            ]
        )
        == 0
    )
    first = out.read_bytes()
    assert (
        pb2zb.main(
            [
                "inventory",
                "--schema",
                str(schema),
                "--pb-data",
                str(pb_data),
                "--out",
                str(out),
            ]
        )
        == 0
    )
    assert out.read_bytes() == first
    inventory = json.loads(first)
    assert inventory["zigbasePocketBaseInventory"] == 1
    assert inventory["sourceVersion"] == "0.39.11"
    assert inventory["findings"] == []
    assert inventory["summary"] == {
        "collections": 1,
        "decisions": 0,
        "blockers": 0,
        "info": 0,
    }
    summaries = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert summaries[-1]["zigbase_pocketbase_inventory"] == 1


def test_inventory_emits_stable_judgment_findings(pocketbase_snapshot, tmp_path):
    collection = base_collection(
        fields=[
            {"id": "point_field", "name": "point", "type": "geoPoint", "system": False},
            {"id": "future_field", "name": "future", "type": "vector", "system": False},
            {
                "id": "system_password",
                "name": "password",
                "type": "password",
                "system": True,
            },
        ],
        indexes=["CREATE INDEX expression_idx ON posts (lower(point))"],
        listRule="@collection.teams.owner = @request.auth.id",
        manageRule="@request.auth.id != ''",
    )
    schema, pb_data = pocketbase_snapshot([collection], hooks=True, migrations=True)
    out = tmp_path / "inventory.json"
    assert (
        pb2zb.main(
            [
                "inventory",
                "--schema",
                str(schema),
                "--pb-data",
                str(pb_data),
                "--out",
                str(out),
            ]
        )
        == 2
    )
    findings = json.loads(out.read_text())["findings"]
    assert [finding["id"] for finding in findings] == sorted(
        finding["id"] for finding in findings
    )
    by_code = {finding["code"] for finding in findings}
    assert by_code == {
        "ComplexIndexRequiresReplacement",
        "GeoPointRequiresMapping",
        "PocketBaseHooksRequireReplacement",
        "PocketBaseMigrationsPresent",
        "PocketBaseRuleRequiresReplacement",
        "UnknownFieldTypeRequiresReplacement",
    }
    assert (
        sum(
            finding["code"] == "PocketBaseRuleRequiresReplacement"
            for finding in findings
        )
        == 2
    )
    assert not any("system_password" in finding["id"] for finding in findings)


def test_finding_ids_use_schema_identity_and_survive_renames(pocketbase_snapshot):
    original = base_collection(
        indexes=[],
        fields=[
            {
                "id": "stable_point_id",
                "name": "point",
                "type": "geoPoint",
                "system": False,
            }
        ],
    )
    renamed = {**original, "name": "articles"}
    renamed["fields"] = [{**original["fields"][0], "name": "coordinates"}]
    _, pb_data = pocketbase_snapshot([original])
    first_ids = [finding.id for finding in pb2zb.collect_findings([original], pb_data)]
    second_ids = [finding.id for finding in pb2zb.collect_findings([renamed], pb_data)]
    assert (
        first_ids == second_ids == ["field.posts_collection.stable_point_id.geoPoint"]
    )


def test_view_and_system_collections_require_explicit_decisions(
    pocketbase_snapshot, tmp_path
):
    view = base_collection(
        id="summary_collection",
        name="summary",
        type="view",
        system=False,
        fields=[],
        indexes=[],
        viewQuery="SELECT 1",
    )
    system = base_collection(
        id="superusers_collection",
        name="_superusers",
        type="auth",
        system=True,
        fields=[],
        indexes=[],
    )
    schema, pb_data = pocketbase_snapshot([view, system])
    inventory = pb2zb.build_inventory(schema, pb_data)
    codes = {finding["code"] for finding in inventory["findings"]}
    assert "ViewCollectionRequiresReplacement" in codes
    assert "SystemCollectionRequiresOmission" in codes
    assert "CollectionIdentifierRequiresReplacement" not in codes


@pytest.mark.parametrize(
    "mutation, message",
    [
        (lambda value: {"items": value}, "JSON array"),
        (lambda value: [value[0], value[0]], "duplicate collection id"),
        (lambda value: [{**value[0], "type": "future"}], "unsupported"),
        (
            lambda value: [{**value[0], "fields": [value[0]["fields"][0]] * 2}],
            "duplicate field id",
        ),
    ],
)
def test_schema_contract_rejects_bad_shapes(
    pocketbase_snapshot, tmp_path, mutation, message
):
    schema, pb_data = pocketbase_snapshot([base_collection()])
    schema.write_text(json.dumps(mutation([base_collection()])))
    out = tmp_path / "inventory.json"
    assert (
        pb2zb.main(
            [
                "inventory",
                "--schema",
                str(schema),
                "--pb-data",
                str(pb_data),
                "--out",
                str(out),
            ]
        )
        == 1
    )
    assert not out.exists()
    with pytest.raises(pb2zb.PocketBaseError, match=message):
        pb2zb.build_inventory(schema, pb_data)


@pytest.mark.parametrize("suffix", ["-wal", "-shm"])
def test_hot_sqlite_sidecars_are_refused(pocketbase_snapshot, tmp_path, suffix):
    schema, pb_data = pocketbase_snapshot([base_collection()])
    Path(f"{pb_data / 'data.db'}{suffix}").write_bytes(b"hot")
    with pytest.raises(pb2zb.PocketBaseError, match="consistent backup"):
        pb2zb.build_inventory(schema, pb_data)
    assert not (tmp_path / "inventory.json").exists()


def test_mismatched_snapshot_table_shape_is_refused(pocketbase_snapshot):
    schema, pb_data = pocketbase_snapshot([base_collection()])
    connection = sqlite3.connect(pb_data / "data.db")
    connection.execute("ALTER TABLE posts DROP COLUMN title")
    connection.commit()
    connection.close()
    with pytest.raises(pb2zb.PocketBaseError, match="missing exported columns: title"):
        pb2zb.build_inventory(schema, pb_data)


def test_inventory_never_modifies_source_snapshot(pocketbase_snapshot):
    schema, pb_data = pocketbase_snapshot([base_collection()])
    before_paths = sorted(
        path.relative_to(schema.parent) for path in schema.parent.rglob("*")
    )
    before = {path: path.read_bytes() for path in (schema, pb_data / "data.db")}
    pb2zb.build_inventory(schema, pb_data)
    assert {path: path.read_bytes() for path in before} == before
    assert (
        sorted(path.relative_to(schema.parent) for path in schema.parent.rglob("*"))
        == before_paths
    )


@pytest.mark.parametrize("target", ["schema", "database", "nested"])
def test_cli_refuses_inventory_output_inside_source(pocketbase_snapshot, target):
    schema, pb_data = pocketbase_snapshot([base_collection()])
    outputs = {
        "schema": schema,
        "database": pb_data / "data.db",
        "nested": pb_data / "reports" / "inventory.json",
    }
    before = {path: path.read_bytes() for path in (schema, pb_data / "data.db")}
    assert (
        pb2zb.main(
            [
                "inventory",
                "--schema",
                str(schema),
                "--pb-data",
                str(pb_data),
                "--out",
                str(outputs[target]),
            ]
        )
        == 1
    )
    assert {path: path.read_bytes() for path in before} == before


def test_custom_go_root_is_a_blocker(pocketbase_snapshot, tmp_path):
    schema, pb_data = pocketbase_snapshot([base_collection()])
    (tmp_path / "go.mod").write_text("module example.invalid/app\n")
    findings = pb2zb.build_inventory(schema, pb_data)["findings"]
    assert any(
        finding["code"] == "PocketBaseGoCodeRequiresReplacement" for finding in findings
    )


def test_auth_and_file_operational_choices_require_review(pocketbase_snapshot):
    auth = base_collection(
        id="members_collection",
        name="members",
        type="auth",
        indexes=[],
        fields=[
            {
                "id": "avatar_field",
                "name": "avatar",
                "type": "file",
                "system": False,
            },
            {
                "id": "password_field",
                "name": "password",
                "type": "password",
                "system": True,
            },
        ],
    )
    schema, pb_data = pocketbase_snapshot([auth])
    findings = pb2zb.build_inventory(schema, pb_data)["findings"]
    assert {finding["code"] for finding in findings} == {
        "AuthCollectionConfigurationRequiresReview",
        "EmailVisibilityRequiresReview",
        "FileStorageSnapshotRequiresConfirmation",
    }


def test_schema_ids_must_be_stable_pocketbase_identifiers(pocketbase_snapshot):
    schema, pb_data = pocketbase_snapshot([base_collection()])
    value = json.loads(schema.read_text())
    value[0]["fields"][0]["id"] = "unsafe.id"
    schema.write_text(json.dumps(value))
    with pytest.raises(pb2zb.PocketBaseError, match="PocketBase identifier"):
        pb2zb.build_inventory(schema, pb_data)


def test_relation_targets_must_exist_in_the_export(pocketbase_snapshot):
    posts = base_collection(
        fields=[
            {
                "id": "author_field",
                "name": "author",
                "type": "relation",
                "collectionId": "missing_collection",
                "system": False,
            }
        ],
        indexes=[],
    )
    schema, pb_data = pocketbase_snapshot([posts])
    with pytest.raises(pb2zb.PocketBaseError, match="unknown exported collection id"):
        pb2zb.build_inventory(schema, pb_data)


def test_public_rules_are_durable_review_findings_including_auth_signup(
    pocketbase_snapshot,
):
    auth = base_collection(
        id="members_collection",
        name="members",
        type="auth",
        fields=[],
        indexes=[],
        listRule=None,
        viewRule=None,
        createRule="",
        updateRule="@request.auth.id = id",
    )
    posts = base_collection(updateRule="", deleteRule="")
    schema, pb_data = pocketbase_snapshot([auth, posts])
    findings = pb2zb.build_inventory(schema, pb_data)["findings"]
    public = [
        finding for finding in findings if finding["code"] == "PublicRuleRequiresReview"
    ]
    assert [(finding["id"], finding["choices"]) for finding in public] == [
        ("rule.members_collection.createRule.public", ["public"]),
        ("rule.posts_collection.deleteRule.public", ["public"]),
        ("rule.posts_collection.updateRule.public", ["public"]),
    ]


def test_auth_rule_hidden_email_visibility_and_reserved_fields_are_not_silent(
    pocketbase_snapshot,
):
    auth = base_collection(
        id="members_collection",
        name="members",
        type="auth",
        authRule="banned = false",
        listRule="@request.auth.id != ''",
        viewRule="@request.auth.id != ''",
        indexes=[],
        fields=[
            {
                "id": "role_field",
                "name": "role",
                "type": "select",
                "values": ["member", "admin"],
                "hidden": True,
                "system": False,
            },
            {
                "id": "password_field",
                "name": "password",
                "type": "password",
                "min": 14,
                "hidden": True,
                "system": True,
            },
            {
                "id": "email_field",
                "name": "email",
                "type": "email",
                "onlyDomains": ["example.test"],
                "system": True,
            },
        ],
    )
    ordinary = base_collection(
        fields=[
            {
                "id": "reserved_field",
                "name": "Email",
                "type": "text",
                "system": False,
            }
        ],
        indexes=[],
    )
    schema, pb_data = pocketbase_snapshot([auth, ordinary])
    codes = [
        finding["code"]
        for finding in pb2zb.build_inventory(schema, pb_data)["findings"]
    ]
    assert "AuthRuleRequiresReplacement" in codes
    assert "EmailVisibilityRequiresReview" in codes
    assert "HiddenFieldWriteProtectionRequiresReplacement" in codes
    assert "FieldOptionsRequireReplacement" in codes
    assert "FieldIdentifierRequiresReplacement" in codes


@pytest.mark.parametrize(
    "rule",
    [
        '@request.body.role = "admin"',
        "@request.query.preview:isset = true",
        'tags ?= "public"',
        "@now > created",
        '@request.auth.collectionName = "staff"',
        "@request.auth.verified = true",
    ],
)
def test_pocketbase_only_rule_surface_requires_replacement(pocketbase_snapshot, rule):
    collection = base_collection(listRule=rule, indexes=[])
    schema, pb_data = pocketbase_snapshot([collection])
    findings = pb2zb.build_inventory(schema, pb_data)["findings"]
    assert any(
        finding["id"] == "rule.posts_collection.listRule.replacement"
        and finding["code"] == "PocketBaseRuleRequiresReplacement"
        for finding in findings
    )
