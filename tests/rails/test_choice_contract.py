"""No decision theater: every offered choice must mean something.

Seven review rounds found the same defect repeatedly — a finding offers a choice, the
operator records it believing it was acted on, and nothing consumes it.

An earlier version of this file enumerated findings from the committed fixture. That was
not enough: the fixture triggers only a fraction of the codes, so a reviewer reinstated a
flagship bug in an untriggered one and all 140 tests stayed green. This version is
**code-bounded** — it iterates `rails2zb.FINDING_CATALOG`, so a finding must declare
itself and be exercised even when no fixture happens to produce it.
"""

from __future__ import annotations

import hashlib
import importlib
import json
import shutil
import sqlite3

import pytest

from .conftest import (
    add_external_auth_fixture,
    decisions_for,
    read_inventory,
    write_inventory,
)
from tools.rails import rails2zb


def _add_column(source, table, name, **kw):
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    entry["columns"].append(
        {
            "source": "observed",
            "name": name,
            "sql_type": kw.get("sql_type", "varchar"),
            "type": kw.get("type", "string"),
            "null": True,
            "default": kw.get("default"),
            "default_function": None,
        }
    )
    write_inventory(source, "schema", schema)


# Already produced by the untouched fixture.
_NATIVE = {
    "SingleTableInheritance",
    "PolymorphicAssociation",
    "SerializedAttribute",
    "AccessRulesRequireReview",
    "ColumnDefaultNotReproduced",
    "DependentBehaviorNotReproduced",
}


def _mutate(source, code):
    """Make the fixture produce `code`. False when no synthesizer exists."""
    if code in _NATIVE:
        return True
    schema = read_inventory(source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    if code == "CredentialColumnMustNotMigrate":
        _add_column(source, "users", "reset_password_token")
    elif code == "TableNameRejected":
        # Rename the table AND every reference to it. A half-renamed inventory is one
        # Rails could never emit, and it made both choices refuse identically for a
        # reason that had nothing to do with the choices.
        posts["name"] = "posts-legacy"
        for table in schema["tables"]:
            for fk in table.get("foreign_keys") or []:
                if fk.get("to_table") == "posts":
                    fk["to_table"] = "posts-legacy"
        write_inventory(source, "schema", schema)
        models = read_inventory(source, "models")
        for model in models["models"]:
            if model.get("table_name") == "posts":
                model["table_name"] = "posts-legacy"
            for association in model.get("associations") or []:
                if association.get("table_name") == "posts":
                    association["table_name"] = "posts-legacy"
        write_inventory(source, "models", models)
        # The inventory and the database must agree: `mutable_source` is a full copy,
        # so rename it there too rather than describing a table that is not present.
        connection = sqlite3.connect(next((source / "db").glob("*.sqlite3")))
        connection.execute('ALTER TABLE "posts" RENAME TO "posts-legacy"')
        connection.commit()
        connection.close()
    elif code == "ColumnTypeUnmapped":
        _add_column(source, "posts", "weird", type="geometry", sql_type="geometry")
    elif code == "NonStandardPrimaryKey":
        # `events` is referenced by nothing. Omitting a REFERENCED table correctly
        # refuses, which would prove nothing about whether omit is honoured.
        next(x for x in schema["tables"] if x["name"] == "events")["primary_key"] = (
            "uuid"
        )
        write_inventory(source, "schema", schema)
    elif code == "ForeignKeyTargetsNonIdColumn":
        next(f for f in posts["foreign_keys"] if f["column"] == "club_id")[
            "primary_key"
        ] = "slug"
        write_inventory(source, "schema", schema)
    elif code == "AssociationWithoutForeignKey":
        posts["foreign_keys"] = [
            f for f in posts["foreign_keys"] if f["column"] != "author_id"
        ]
        write_inventory(source, "schema", schema)
    elif code == "TableHasNoTimestamps":
        # `events` is a simple fixture for checking the manifest-v2 entry policy without
        # involving a relation cycle (covered separately by the importer regression).
        events = next(t for t in schema["tables"] if t["name"] == "events")
        events["columns"] = [
            c
            for c in events["columns"]
            if c["name"] not in ("created_at", "updated_at")
        ]
        write_inventory(source, "schema", schema)
    elif code == "PartialIndexPredicate":
        posts["indexes"][0]["where"] = "status = 'published'"
        write_inventory(source, "schema", schema)
    elif code == "ForeignKeysUnreadable":
        next(x for x in schema["tables"] if x["name"] == "events")["foreign_keys"] = (
            None
        )
        write_inventory(source, "schema", schema)
    elif code == "ForeignKeyActionUnsupported":
        fk = next(f for f in posts["foreign_keys"] if f["column"] == "author_id")
        fk["on_delete"] = "cascade"
        fk["on_update"] = "cascade"
        write_inventory(source, "schema", schema)
    elif code == "CascadeContradictsRestrict":
        # `User has_many :owned_clubs, dependent: :restrict_with_exception` already
        # protects (clubs, owner_id) in the fixture; give the database the opposite.
        clubs = next(t for t in schema["tables"] if t["name"] == "clubs")
        next(f for f in clubs["foreign_keys"] if f["column"] == "owner_id")[
            "on_delete"
        ] = "cascade"
        write_inventory(source, "schema", schema)
    elif code == "AttachmentNameCollision":
        # A Paperclip/CarrierWave column left beside the attachment that replaced it.
        _add_column(source, "posts", "cover")
    elif code == "AuthCollectionRelation":
        users = next(t for t in schema["tables"] if t["name"] == "users")
        users["columns"].append(
            {
                "source": "observed",
                "name": "sponsor_club_id",
                "sql_type": "integer",
                "type": "integer",
                "null": True,
                "default": None,
                "default_function": None,
            }
        )
        users.setdefault("foreign_keys", []).append(
            {
                "source": "observed",
                "column": "sponsor_club_id",
                "to_table": "clubs",
                "primary_key": "id",
                "on_delete": None,
                "on_update": None,
                "name": "fk_users_sponsor_club",
            }
        )
        write_inventory(source, "schema", schema)
        connection = sqlite3.connect(next((source / "db").glob("*.sqlite3")))
        connection.execute("ALTER TABLE users ADD COLUMN sponsor_club_id integer")
        connection.commit()
        connection.close()
    elif code == "NullableTimestampColumn":
        # Rails <= 4 wrote `t.timestamps` exactly this way.
        for column in next(t for t in schema["tables"] if t["name"] == "events")[
            "columns"
        ]:
            if column["name"] in ("created_at", "updated_at"):
                column["null"] = True
        write_inventory(source, "schema", schema)
    elif code == "ReservedFieldName":
        # `contacts.email` is an utterly ordinary Rails column; `posts` is a base table.
        _add_column(source, "posts", "email")
    elif code == "ColumnNameRejected":
        _add_column(source, "posts", "legacy.value")
    elif code == "ForeignKeyInspectionUnsupported":
        # An inventory from an older extractor: the per-table arrays are populated but
        # nothing says the adapter could actually read them.
        schema.pop("foreign_keys_supported", None)
        write_inventory(source, "schema", schema)
    elif code == "DevisePepperBreaksImport":
        auth = read_inventory(source, "auth")
        auth["devise"] = {"present": True, "pepper_configured": True, "models": []}
        write_inventory(source, "auth", auth)
    elif code == "ExternalIdentitiesRequireMapping":
        add_external_auth_fixture(source)
    else:
        return False
    return True


CONSUMING_CODES = sorted(
    code for code, entry in rails2zb.FINDING_CATALOG.items() if entry["consumes"]
)


# Every consuming code must have a targeted semantic test below. The generic probe
# cannot cover single-choice findings (there is no sibling to differ from), and that is
# exactly where three broken `omit` consumers hid while the suite stayed green.
TARGETED = {
    "AssociationWithoutForeignKey": "test_relation_choice_emits_an_actual_relation",
    "TableNameRejected": "test_rename_choice_renames_the_collection_and_its_referrers",
    "ForeignKeyTargetsNonIdColumn": "test_target_key_omit_drops_the_untrustworthy_relation",
    "TableHasNoTimestamps": "test_separate_import_sets_an_entry_local_timestamp_policy",
    "SingleTableInheritance": "test_sti_omit_drops_the_table",
    "PolymorphicAssociation": "test_polymorphic_omit_drops_the_recorded_columns",
    "DependentBehaviorNotReproduced": "test_cascade_choice_sets_cascade_delete",
    "NonStandardPrimaryKey": "test_primary_key_omit_leaves_the_table_behind",
    "ForeignKeysUnreadable": "test_unreadable_foreign_keys_omit_drops_the_table",
    "ColumnTypeUnmapped": "test_unmapped_column_omit_drops_only_that_column",
    "ColumnDefaultNotReproduced": "test_default_column_omit_drops_the_column",
    "CredentialColumnMustNotMigrate": "test_a_credential_column_omit_actually_drops_it",
    "AccessRulesRequireReview": "test_all_five_access_rules_can_be_expressed",
    "SerializedAttribute": "test_the_serialized_decision_reaches_the_schema",
    "PartialIndexPredicate": "test_a_reviewed_partial_predicate_is_used",
    "ForeignKeyActionUnsupported": "test_fk_action_omit_clears_cascade_delete",
    "DevisePepperBreaksImport": "test_reset_passwords_suppresses_the_digest",
    "ColumnNameRejected": "test_a_rejected_column_name_can_be_renamed",
    "ReservedFieldName": "test_a_column_named_for_an_engine_field_must_be_decided",
    "NullableTimestampColumn": "test_a_nullable_timestamp_disables_timestamp_preservation",
    "AuthCollectionRelation": "test_an_auth_relation_omit_drops_the_unimportable_field",
    "AttachmentNameCollision": "test_an_attachment_colliding_with_a_column_is_decidable",
    "CascadeContradictsRestrict": "test_a_database_cascade_cannot_silently_beat_a_restrict",
    "ForeignKeyInspectionUnsupported": (
        "test_untrusted_foreign_keys_omit_drops_every_derived_relation"
    ),
    "ExternalIdentitiesRequireMapping": (
        "test_external_auth_mapping_emits_only_reviewed_provider_linkage"
    ),
}


def _emit_digest(src, base, finding, choice, tmp_path):
    """Digest the WHOLE bundle emitted when `finding` is decided `choice`.

    Not just the schema: a schema-only probe cannot see consumption that lives in data,
    auth or manifest emission — `reset-passwords` suppresses credentials in the auth
    NDJSON and would have looked inert, certifying a choice the pipeline honours.
    """
    value = json.loads(json.dumps(base))
    for entry in value["decisions"]:
        if entry["id"] == finding.id:
            entry["choice"] = choice
            entry["artifact"] = (
                "people"
                if choice == "rename"
                else "users"
                if choice == "external-auths"
                else "docs/replacements/probe.md"
            )
    out = tmp_path / f"bundle-{choice}"
    try:
        decisions = rails2zb.load_decisions_from_value(value)
        rails2zb.extract(src, decisions, out)
    except rails2zb.RailsError as exc:
        return f"REFUSED:{exc}"
    digest = hashlib.sha256()
    for path in sorted(q for q in out.rglob("*") if q.is_file()):
        digest.update(path.relative_to(out).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def test_every_consuming_code_has_a_targeted_test():
    """A generic 'the choices differ' probe certified a consumer that only crashed.

    Difference is not correctness, and single-choice findings have nothing to differ
    from — so each consuming code must be pinned by a test that asserts its EFFECT.
    """
    missing = sorted(
        code
        for code, entry in rails2zb.FINDING_CATALOG.items()
        if entry["consumes"] and code not in TARGETED
    )
    assert not missing, f"consuming codes with no targeted semantic test: {missing}"


def test_every_targeted_test_name_exists():
    """The registry is names, not references, so a renamed test would rot silently.

    It did: a code was registered against a test that had not been written yet, and the
    guard passed.
    """
    import inspect
    import sys

    module = sys.modules[__name__]
    here = {name for name, _ in inspect.getmembers(module, inspect.isfunction)}
    elsewhere = set()
    for sibling in (
        "test_extract",
        "test_identity",
        "test_refusals",
        "test_decisions",
        "test_reserved_names",
    ):
        imported = importlib.import_module(f".{sibling}", __package__)
        elsewhere |= {n for n, _ in inspect.getmembers(imported, inspect.isfunction)}
    missing = sorted(t for t in TARGETED.values() if t not in here | elsewhere)
    assert not missing, f"TARGETED names no test defines: {missing}"


def test_no_choice_is_declared_both_consuming_and_external():
    for code, entry in sorted(rails2zb.FINDING_CATALOG.items()):
        overlap = entry["consumes"] & entry["external"]
        assert not overlap, f"{code}: {sorted(overlap)} declared both ways"


def test_every_consuming_code_can_be_exercised(fixture_root, tmp_path):
    """A consuming choice nobody can trigger cannot be proven to do anything.

    This is exactly what the fixture-bounded version missed: it silently skipped ten of
    sixteen consuming codes, which is how a reintroduced bug passed the whole suite.
    """
    missing = []
    for index, code in enumerate(CONSUMING_CODES):
        fresh = tmp_path / f"src{index}"
        shutil.copytree(fixture_root, fresh)
        if not _mutate(fresh, code):
            missing.append(code)
    assert not missing, (
        f"these consuming codes have no synthesizer, so their choices are uncertified: "
        f"{missing}"
    )


@pytest.mark.parametrize("code", CONSUMING_CODES)
def test_each_consuming_choice_changes_the_output(mutable_source, tmp_path, code):
    """Choosing differently must change what the converter emits, or refuse."""
    assert _mutate(mutable_source, code), f"no synthesizer for {code}"
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    subjects = [f for f in findings if f.code == code and len(f.choices) > 1]
    if not subjects:
        pytest.skip(f"{code} produced no multi-choice finding")
    base = decisions_for([f.to_dict() for f in findings])
    finding = subjects[0]

    outputs = {
        c: _emit_digest(src, base, finding, c, tmp_path) for c in finding.choices
    }
    consuming = set(finding.choices) & rails2zb.FINDING_CATALOG[code]["consumes"]
    for choice in sorted(consuming):
        siblings = {v for k, v in outputs.items() if k != choice}
        assert outputs[choice] not in siblings, (
            f"{finding.id}:{choice} emits exactly what a sibling choice emits — "
            f"the decision is theater"
        )


# ---------------------------------------------------------------------------
# The mirror: `external` must be true as well.
#
# `consumes` is proven above. `external` was not proven anywhere, and it is load-bearing
# in the dangerous direction: `test_every_consuming_code_has_a_targeted_test` only
# demands a semantic test for codes with a non-empty `consumes`, so moving a choice into
# `external` SILENCES that guard. A reviewer did exactly that once (see the note on
# `test_untrusted_foreign_keys_omit_drops_every_derived_relation`). If a choice called
# external actually changes the bundle, the operator is told to implement the behavior
# themselves while the converter is quietly doing something of its own.

MULTI_EXTERNAL_CODES = sorted(
    code
    for code, entry in rails2zb.FINDING_CATALOG.items()
    if len(entry["external"]) >= 2
)

# Codes the fixture neither produces nor `_mutate` synthesizes, so the probe below has
# nothing to run against. Frozen deliberately: a skip that grows silently is how the
# fixture-bounded version of this file came to certify nothing.
EXTERNAL_WITHOUT_A_SUBJECT = {
    "ActionTextContentNotMigrated",
    "AuthMechanismUnrecognized",
    "CatalogInspectionUnsupported",
    "CheckConstraintNeedsReplacement",
    "CheckConstraintsUnreadable",
    "DeviseModuleBehaviorNotReproduced",
    "InventoryIsInferred",
}


def test_the_uncovered_external_codes_are_the_recorded_ones(fixture_root, tmp_path):
    """Every other multi-external code must be reachable, now and later."""
    uncovered = []
    for index, code in enumerate(MULTI_EXTERNAL_CODES):
        fresh = tmp_path / f"ext{index}"
        shutil.copytree(fixture_root, fresh)
        # Not `_mutate(...) and ...`: `_mutate` returns False for any code it has no
        # branch for, including ones the untouched fixture already produces.
        _mutate(fresh, code)
        if not any(
            f.code == code for f in rails2zb.build_findings(rails2zb.load_source(fresh))
        ):
            uncovered.append(code)
    assert set(uncovered) == EXTERNAL_WITHOUT_A_SUBJECT, (
        f"the set of unprovable external codes moved: {sorted(uncovered)}"
    )


@pytest.mark.parametrize(
    "code", [c for c in MULTI_EXTERNAL_CODES if c not in EXTERNAL_WITHOUT_A_SUBJECT]
)
def test_external_choices_emit_the_same_bundle(mutable_source, tmp_path, code):
    """Choices the operator implements outside the bundle must not change the bundle."""
    _mutate(mutable_source, code)
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    subjects = [f for f in findings if f.code == code]
    assert subjects, f"{code} produced no finding"
    base = decisions_for([f.to_dict() for f in findings])
    finding = subjects[0]

    external = sorted(set(finding.choices) & rails2zb.FINDING_CATALOG[code]["external"])
    # Asserted, not skipped: the catalogue promises two, so a subject offering fewer
    # means the offered set and the catalogue have drifted. Skipping there would drop
    # this code's coverage silently, which is the failure this whole file exists to stop.
    assert len(external) >= 2, (
        f"{finding.id} offers {sorted(finding.choices)}, of which only {external} are "
        f"declared external, yet the catalogue declares "
        f"{sorted(rails2zb.FINDING_CATALOG[code]['external'])}"
    )
    digests = {c: _emit_digest(src, base, finding, c, tmp_path) for c in external}

    # A refusal is not proof of sameness: two choices that both refuse would pass this
    # while emitting nothing at all.
    refused = {c: d for c, d in digests.items() if d.startswith("REFUSED:")}
    assert not refused, f"{finding.id}: external choices refused to extract: {refused}"
    assert len(set(digests.values())) == 1, (
        f"{finding.id}: these choices are declared external yet emit different "
        f"bundles, so the converter acts on them after all: {sorted(digests)}"
    )


# ---------------------------------------------------------------------------
# Targeted semantics: what each consuming choice must actually DO
#
# The contract above proves choices are classified and distinguishable. It cannot prove
# they are CORRECT: a broken consumer that refuses still "differs" from its sibling, so
# reintroducing an inverted relation map passed the whole suite. These assert the effect.
# ---------------------------------------------------------------------------


def _mapped(source, code, fid_suffix, choice, artifact=None):
    assert _mutate(source, code)
    src = rails2zb.load_source(source)
    findings = rails2zb.build_findings(src)
    finding = next(f for f in findings if f.id.endswith(fid_suffix) and f.code == code)
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == finding.id:
            entry["choice"] = choice
            if artifact:
                entry["artifact"] = artifact
    decisions = rails2zb.load_decisions_from_value(value)
    return src, decisions, rails2zb.map_tables(src, decisions)


def test_relation_choice_emits_an_actual_relation(mutable_source):
    """The inverted relation map made this choice crash; it still `differed`."""
    _, _, mapped = _mapped(
        mutable_source, "AssociationWithoutForeignKey", "author.nofk", "relation"
    )
    posts = next(m for m in mapped if m.table == "posts")
    author = next(f for f in posts.fields if f["name"] == "author")
    assert author["type"] == "relation"
    assert author["options"]["targetCollectionId"] == "users"


def test_rename_choice_renames_the_collection_and_its_referrers(mutable_source):
    _, _, mapped = _mapped(
        mutable_source, "TableNameRejected", "identifier", "rename", artifact="people"
    )
    names = {m.collection for m in mapped}
    assert "people" in names and "posts-legacy" not in names
    comments = next(m for m in mapped if m.table == "comments")
    post = next(f for f in comments.fields if f["name"] == "post")
    assert post["options"]["targetCollectionId"] == "people", (
        "a referrer must point at the new name, not the old table"
    )


def test_target_key_omit_drops_the_untrustworthy_relation(mutable_source):
    _, _, mapped = _mapped(
        mutable_source, "ForeignKeyTargetsNonIdColumn", "club_id.target_key", "omit"
    )
    posts = next(m for m in mapped if m.table == "posts")
    assert "club" not in {f["name"] for f in posts.fields}


def test_separate_import_sets_an_entry_local_timestamp_policy(mutable_source, tmp_path):
    src, decisions, _ = _mapped(
        mutable_source, "TableHasNoTimestamps", "no_timestamps", "separate-import"
    )
    report = rails2zb.extract(src, decisions, tmp_path / "bundle")
    assert report["separateManifest"] is None
    main = json.loads((tmp_path / "bundle" / "manifest.json").read_text())
    event = next(
        entry for entry in main["collections"] if entry["collection"] == "events"
    )
    assert event["preserveTimestamps"] is False
    assert not (tmp_path / "bundle" / "manifest-no-timestamps.json").exists()
    assert report["manifestOrder"] == ["manifest.json"]


def test_sti_omit_drops_the_table(mutable_source):
    _, _, mapped = _mapped(
        mutable_source, "SingleTableInheritance", "Event.sti", "omit"
    )
    assert "events" not in {m.table for m in mapped}


def test_polymorphic_omit_drops_the_recorded_columns(mutable_source):
    _, _, mapped = _mapped(
        mutable_source, "PolymorphicAssociation", "flaggable.polymorphic", "omit"
    )
    flags = next(m for m in mapped if m.table == "flags")
    names = {f["name"] for f in flags.fields}
    assert "flaggable_id" not in names and "flaggable_type" not in names


def test_cascade_choice_sets_cascade_delete(mutable_source):
    _, _, mapped = _mapped(
        mutable_source, "DependentBehaviorNotReproduced", "Post.dependent", "cascade"
    )
    comments = next(m for m in mapped if m.table == "comments")
    post = next(f for f in comments.fields if f["name"] == "post")
    assert post["options"]["cascadeDelete"] is True


def test_cascade_never_inverts_a_restrict_declaration(mutable_source):
    """`restrict_with_exception` means Rails REFUSES the delete; cascading it destroys
    rows the source protects."""
    src = rails2zb.load_source(mutable_source)
    user = next(m for m in src.models["models"] if m["name"] == "User")
    restricting = [
        a["name"]
        for a in user.get("associations") or []
        if str(a.get("dependent") or "").startswith("restrict")
    ]
    if not restricting:
        pytest.skip("fixture has no restrict_with_* association")
    _, _, mapped = _mapped(
        mutable_source, "DependentBehaviorNotReproduced", "User.dependent", "cascade"
    )
    clubs = next(m for m in mapped if m.table == "clubs")
    owner = next(f for f in clubs.fields if f["name"] == "owner")
    assert owner["options"]["cascadeDelete"] is False


def test_primary_key_omit_leaves_the_table_behind(mutable_source):
    _, _, mapped = _mapped(
        mutable_source, "NonStandardPrimaryKey", "events.primary_key", "omit"
    )
    assert "events" not in {m.table for m in mapped}


def test_unreadable_foreign_keys_omit_drops_the_table(mutable_source):
    """Absence of foreign keys here is UNKNOWN; keeping the table flattens relations."""
    _, _, mapped = _mapped(
        mutable_source, "ForeignKeysUnreadable", "events.foreign_keys", "omit"
    )
    assert "events" not in {m.table for m in mapped}


def test_unmapped_column_omit_drops_only_that_column(mutable_source):
    _, _, mapped = _mapped(mutable_source, "ColumnTypeUnmapped", "weird.type", "omit")
    posts = next(m for m in mapped if m.table == "posts")
    assert "weird" not in {f["name"] for f in posts.fields}
    assert "title" in {f["name"] for f in posts.fields}, "only that column"


def test_default_column_omit_drops_the_column(mutable_source):
    _, _, mapped = _mapped(
        mutable_source, "ColumnDefaultNotReproduced", "users.role.default", "omit"
    )
    users = next(m for m in mapped if m.table == "users")
    assert "role" not in {f["name"] for f in users.fields}


def test_fk_action_omit_clears_cascade_delete(mutable_source):
    """Recording a decision to drop the action while keeping ON DELETE CASCADE is the
    opposite of what was asked."""
    _, _, mapped = _mapped(
        mutable_source, "ForeignKeyActionUnsupported", "author_id.action", "omit"
    )
    posts = next(m for m in mapped if m.table == "posts")
    author = next(f for f in posts.fields if f["name"] == "author")
    assert author["options"]["cascadeDelete"] is False


def test_renaming_a_table_keeps_its_attachments(mutable_source, tmp_path):
    """The file plan named collections by the raw table, so a rename detached every
    attachment and installed blobs under a collection that did not exist."""
    src, decisions, mapped = _mapped(
        mutable_source, "TableNameRejected", "identifier", "rename", artifact="people"
    )
    report = rails2zb.extract(src, decisions, tmp_path / "bundle")
    assert report["files"] >= 1
    plan = json.loads((tmp_path / "bundle" / "files" / "manifest.json").read_text())
    assert {e["collection"] for e in plan["files"]} == {"people"}
    rows = [
        json.loads(line)
        for line in (tmp_path / "bundle" / "data" / "people.ndjson")
        .read_text()
        .splitlines()
        if line.strip()
    ]
    assert any(r.get("cover") for r in rows), "the record must still name its file"


def test_no_timestamps_omit_leaves_the_table_behind(mutable_source):
    """`separate-import` had a targeted test and `omit` did not, so removing
    `no_timestamps` from TABLE_OMITTING_FINDINGS passed the whole suite."""
    schema = read_inventory(mutable_source, "schema")
    events = next(x for x in schema["tables"] if x["name"] == "events")
    events["columns"] = [
        c for c in events["columns"] if c["name"] not in ("created_at", "updated_at")
    ]
    write_inventory(mutable_source, "schema", schema)

    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    finding = next(f for f in findings if f.id == "table.events.no_timestamps")
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == finding.id:
            entry["choice"] = "omit"
    decisions = rails2zb.load_decisions_from_value(value)
    assert "events" not in {m.table for m in rails2zb.map_tables(src, decisions)}


def test_untrusted_foreign_keys_omit_drops_every_derived_relation(mutable_source):
    """The blocker says no relation in the schema can be trusted; `omit` must mean it.

    The decision was recorded and then ignored: every relation was still emitted from
    exactly the foreign-key arrays the finding declared untrustworthy, and because the
    catalogue called the choice external, the targeted-test guard was satisfied by the
    inaction.
    """
    _, _, mapped = _mapped(
        mutable_source,
        "ForeignKeyInspectionUnsupported",
        "foreign_keys.unsupported",
        "omit",
    )
    emitted = [
        f"{m.collection}.{f['name']}"
        for m in mapped
        for f in m.fields
        if f["type"] == "relation"
    ]
    assert emitted == [], (
        f"relations were derived from foreign keys the operator declared untrusted: "
        f"{emitted}"
    )


def test_a_table_finding_outside_the_omitting_set_does_not_drop_the_table(
    mutable_source,
):
    """`omit` is scoped by finding, not by shape of id.

    Dropping the table for ANY `table.<t>.<code>: omit` would make
    `table.users.check_constraints: omit` -- "I inventoried the constraints by hand" --
    silently delete the users table and everything referring to it.
    """
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["check_constraints"] = (
        None
    )
    write_inventory(mutable_source, "schema", schema)
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    finding = next(f for f in findings if f.id == "table.events.check_constraints")
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == finding.id:
            entry["choice"] = "omit"
    mapped = rails2zb.map_tables(src, rails2zb.load_decisions_from_value(value))
    assert "events" in {m.table for m in mapped}, (
        "an unreadable-check-constraints decision dropped the whole table"
    )


def _dependent_cascade(source, model_name):
    src = rails2zb.load_source(source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == f"model.{model_name}.dependent":
            entry["choice"] = "cascade"
    decisions = rails2zb.load_decisions_from_value(value)
    return rails2zb.map_tables(src, decisions)


def test_cascade_never_inverts_a_restrict_declared_by_another_model(mutable_source):
    """A restrict on a (table, column) protects it whoever else asks to cascade.

    Guarding only inside the decided model let a second model's `dependent: :destroy`
    cascade rows the first explicitly refuses to delete -- silent data loss on delete,
    from a decision that said nothing about those rows.
    """
    models = read_inventory(mutable_source, "models")
    club = next(m for m in models["models"] if m["name"] == "Club")
    # User already declares `has_many :owned_clubs, dependent: :restrict_with_exception`
    # on exactly this (table, column).
    club["associations"].append(
        {
            "source": "observed",
            "name": "owned_clubs",
            "macro": "has_many",
            "table_name": "clubs",
            "foreign_key": "owner_id",
            "dependent": "destroy",
            "polymorphic": False,
            "through": None,
            "class_name": "Club",
        }
    )
    write_inventory(mutable_source, "models", models)
    clubs = next(
        m for m in _dependent_cascade(mutable_source, "Club") if m.table == "clubs"
    )
    owner = next(f for f in clubs.fields if f["name"] == "owner")
    assert owner["options"]["cascadeDelete"] is False, (
        "another model's restrict_with_exception was overridden by this cascade"
    )


def test_delete_all_is_cascaded_like_destroy(mutable_source):
    """`delete_all` removes the children too -- only `restrict_*` means keep them."""
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    next(a for a in post["associations"] if a["name"] == "comments")["dependent"] = (
        "delete_all"
    )
    write_inventory(mutable_source, "models", models)
    comments = next(
        m for m in _dependent_cascade(mutable_source, "Post") if m.table == "comments"
    )
    post_field = next(f for f in comments.fields if f["name"] == "post")
    assert post_field["options"]["cascadeDelete"] is True


def test_nullable_timestamps_omit_leaves_the_table_behind(mutable_source):
    """`omit` on this finding drops the table, exactly as its sibling's does.

    `events` is referenced by nothing; omitting a REFERENCED table correctly refuses,
    which would prove nothing about whether omit is honoured.
    """
    _, _, mapped = _mapped(
        mutable_source, "NullableTimestampColumn", "nullable_timestamps", "omit"
    )
    assert "events" not in {m.table for m in mapped}


def test_an_auth_relation_omit_drops_the_unimportable_field(mutable_source):
    """No documented import order resolves a relation out of an auth collection.

    Auth files are imported one at a time, with none of the manifest importer's
    strip-then-patch ordering: auth-first fails on the target row, and manifest-first
    fails because ordinary rows relate back to the auth collection.
    """
    _, _, mapped = _mapped(
        mutable_source,
        "AuthCollectionRelation",
        "sponsor_club_id.auth_relation",
        "omit",
    )
    users = next(m for m in mapped if m.table == "users")
    assert "sponsor_club" not in {f["name"] for f in users.fields}
    assert "sponsor_club_id" not in {f["name"] for f in users.fields}
