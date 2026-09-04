"""Refusals nothing was exercising.

A mutation sweep flipped each of these guards off and the whole suite stayed green: the
code was right, but nothing held it there. A refusal that is never triggered by a test is
indistinguishable from a refusal that was deleted.
"""

from __future__ import annotations

import json
import sqlite3

import pytest

from .conftest import (
    decisions_for,
    materialize_artifacts,
    read_inventory,
    write_inventory,
)
from tools.rails import rails2zb
from tools.rails._core import finding_id


def _decide(source, **overrides):
    src = rails2zb.load_source(source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] in overrides:
            choice, artifact = overrides[entry["id"]]
            entry["choice"] = choice
            if artifact is not None:
                entry["artifact"] = artifact
    return src, rails2zb.load_decisions_from_value(value)


def _db(source):
    connection = sqlite3.connect(next((source / "db").glob("*.sqlite3")))
    connection.row_factory = sqlite3.Row
    return connection


# ---------------------------------------------------------------------------
# The drift guard the catalogue advertises
# ---------------------------------------------------------------------------


def test_offering_a_choice_the_catalogue_does_not_declare_is_refused():
    """This is the mechanism that makes the whole choice contract meaningful."""
    code = "TableNameRejected"
    declared = (
        rails2zb.FINDING_CATALOG[code]["consumes"]
        | rails2zb.FINDING_CATALOG[code]["external"]
    )
    rails2zb._catalogued(code, tuple(sorted(declared)))  # the honest call site
    with pytest.raises(rails2zb.RailsError, match="undeclared choices"):
        rails2zb._catalogued(code, tuple(sorted(declared)) + ("invented",))


def test_a_finding_code_outside_the_catalogue_is_refused():
    with pytest.raises(rails2zb.RailsError, match="not in FINDING_CATALOG"):
        rails2zb._catalogued("NeverHeardOfIt", ("omit",))


# ---------------------------------------------------------------------------
# Access rules
# ---------------------------------------------------------------------------


def _rule(artifact):
    decision = rails2zb.Decision(
        id=finding_id("table", "posts", "rules"),
        choice="expression",
        rationale="test",
        artifact=artifact,
    )
    return rails2zb._rules_for({decision.id: decision}, "posts")


def test_a_rule_artifact_mixing_per_action_lines_with_free_text_is_refused():
    """Half a per-action block would otherwise ship as ONE literal expression.

    The resulting rule contains the text `list =` and is applied to all five actions --
    an access rule nobody wrote, on every operation.
    """
    with pytest.raises(rails2zb.RailsError, match="mixes per-action lines"):
        _rule("list = @request.auth.id != ''\nanyone who is signed in")


@pytest.mark.parametrize("typo", ["read", "lists", "LIST", "destroy"])
def test_a_misspelled_action_name_is_refused(typo):
    """A name that is nearly an action must not be honoured as a lone expression.

    `read = @public` beside four correct lines is the plausible operator typo: silently
    treating the block as one expression would apply that literal to all five actions,
    and treating it as four would leave the fifth Locked without saying so.
    """
    block = "\n".join(
        [f"{action} = @request.auth.id != ''" for action in ("list", "view")]
        + [f"{typo} = @public"]
    )
    with pytest.raises(rails2zb.RailsError, match="mixes per-action lines"):
        _rule(block)


def test_a_single_expression_containing_an_operator_is_not_read_as_an_action():
    resolved = _rule("@request.auth.id != ''")
    assert set(resolved.values()) == {"@request.auth.id != ''"}


def test_a_complete_per_action_block_is_split_per_action():
    resolved = _rule(
        "\n".join(
            f"{action} = @request.auth.id != ''" for action in rails2zb.RULE_ACTIONS
        )
    )
    assert resolved["list"] == "@request.auth.id != ''"
    assert len(resolved) == len(rails2zb.RULE_ACTIONS)


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------


def test_a_non_bcrypt_digest_is_refused(mutable_source, workspace):
    """A reset is a decision, not something extraction may make silently."""
    connection = _db(mutable_source)
    connection.execute("UPDATE users SET password_digest = 'sha1$deadbeef'")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="no supported bcrypt credential"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_two_password_digests_on_one_table_are_refused(mutable_source):
    """`has_secure_password :recovery` beside the real one: picking is not the tool's call.

    Alphabetical order would make `recovery_password_digest` the login credential and
    leave the real `password_digest` exposed as an ordinary field.
    """
    auth = read_inventory(mutable_source, "auth")
    entry = next(e for e in auth["has_secure_password"] if e["table_name"] == "users")
    # TWO secure passwords -- both have an `authenticate_*` reader, so both are real
    # credentials. Two digest COLUMNS is the ordinary case and must not refuse.
    entry["attributes"] = ["password", "recovery_password"]
    entry["digest_columns"] = ["password_digest", "recovery_password_digest"]
    write_inventory(mutable_source, "auth", auth)
    with pytest.raises(rails2zb.RailsError, match="several secure passwords"):
        rails2zb._auth_tables(rails2zb.load_source(mutable_source))


def test_an_oversized_json_document_is_refused_before_it_is_parsed(tmp_path):
    """The bound is part of the read contract, not a defensive afterthought.

    It is checked from `stat` rather than after reading, so an absurd `routes.json`
    costs one syscall instead of the memory to hold it.
    """
    document = tmp_path / "routes.json"
    document.write_text(json.dumps(["x" * 4096]))
    assert rails2zb.read_json(document, limit=1024 * 1024)
    with pytest.raises(rails2zb.RailsError, match="exceeds the 4096-byte limit"):
        rails2zb.read_json(document, limit=4096, label="routes")


def test_duplicate_json_keys_are_refused(tmp_path):
    document = tmp_path / "routes.json"
    document.write_text('{"source":"inferred","source":"observed"}\n')

    with pytest.raises(rails2zb.RailsError, match="duplicate JSON key 'source'"):
        rails2zb.read_json(document, label="routes")


def test_output_guard_checks_lexical_placement_before_following_a_leaf_symlink(
    tmp_path,
):
    source = tmp_path / "frozen"
    source.mkdir()
    external = tmp_path / "external.json"
    external.write_text("outside\n")
    planted = source / "inventory.json"
    planted.symlink_to(external)

    with pytest.raises(rails2zb.RailsError, match="outside the frozen source tree"):
        rails2zb.ensure_output_outside_source(planted, source)


def test_a_declared_secure_password_without_its_column_is_refused(mutable_source):
    """`has_secure_password :login` with no `login_digest` cannot be reconciled.

    The extractor reads the reader and the columns from the same booted app, so this
    pairing means the inventory is internally inconsistent -- and guessing which of the
    remaining digests was meant is exactly what the sibling refusal above forbids.
    """
    auth = read_inventory(mutable_source, "auth")
    entry = next(e for e in auth["has_secure_password"] if e["table_name"] == "users")
    entry["attributes"] = ["login"]
    write_inventory(mutable_source, "auth", auth)
    with pytest.raises(rails2zb.RailsError, match="contradicts itself"):
        rails2zb._auth_tables(rails2zb.load_source(mutable_source))


def test_the_canonical_rails_tutorial_user_model_inventories(mutable_source, workspace):
    """`password_digest` beside remember/activation/reset digests is the COMMON shape.

    Refusing on the count of `*_digest` columns blocked it at `inventory` itself -- exit
    1, no findings file, and so no decision an operator could record to get past it.
    """
    for name in ("remember_digest", "activation_digest", "reset_digest"):
        schema = read_inventory(mutable_source, "schema")
        users = next(t for t in schema["tables"] if t["name"] == "users")
        users["columns"].append(
            {
                "source": "observed",
                "name": name,
                "sql_type": "varchar",
                "type": "string",
                "null": True,
                "default": None,
                "default_function": None,
            }
        )
        write_inventory(mutable_source, "schema", schema)
    auth = read_inventory(mutable_source, "auth")
    entry = next(e for e in auth["has_secure_password"] if e["table_name"] == "users")
    entry["digest_columns"] = sorted(
        entry["digest_columns"]
        + ["remember_digest", "activation_digest", "reset_digest"]
    )
    write_inventory(mutable_source, "auth", auth)

    src = rails2zb.load_source(mutable_source)
    assert rails2zb._auth_tables(src)["users"] == "password_digest"

    findings = rails2zb.build_findings(src)
    credential = {f.id for f in findings if f.code == "CredentialColumnMustNotMigrate"}
    for name in ("remember_digest", "activation_digest", "reset_digest"):
        assert finding_id("column", "users", name, "credential") in credential, (
            f"{name} is a bcrypt digest of a live token and must not migrate silently"
        )
    assert (
        finding_id("column", "users", "password_digest", "credential") not in credential
    ), "the login credential travels as passwordHash; it is not an ordinary column"

    src, decisions = _decide(mutable_source)
    rails2zb.extract(src, decisions, workspace / "bundle")


def test_the_digest_column_never_becomes_an_ordinary_field(source):
    """It travels as `passwordHash` on the auth import, and nowhere else.

    Emitting it as a field too would publish every bcrypt hash through the record API.
    """
    src, decisions = _decide(source)
    users = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "users")
    assert users.digest_column == "password_digest"
    assert "password_digest" not in {f["name"] for f in users.fields}


# ---------------------------------------------------------------------------
# Renames
# ---------------------------------------------------------------------------


def test_a_rename_to_an_invalid_identifier_is_refused(mutable_source):
    """The finding exists because the OLD name failed this gate."""
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["name"] = "events-legacy"
    write_inventory(mutable_source, "schema", schema)
    fid = finding_id("table", "events-legacy", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "still-not-valid")})
    with pytest.raises(rails2zb.RailsError, match="not a usable ZigBase"):
        rails2zb.map_tables(src, decisions)


def _rename_timestampless_events(source, new_name):
    schema = read_inventory(source, "schema")
    events = next(t for t in schema["tables"] if t["name"] == "events")
    events["name"] = "events-legacy"
    events["columns"] = [
        c for c in events["columns"] if c["name"] not in ("created_at", "updated_at")
    ]
    write_inventory(source, "schema", schema)
    models = read_inventory(source, "models")
    for model in models["models"]:
        if model.get("table_name") == "events":
            model["table_name"] = "events-legacy"
        for association in model.get("associations") or []:
            if association.get("table_name") == "events":
                association["table_name"] = "events-legacy"
    write_inventory(source, "models", models)
    connection = sqlite3.connect(next((source / "db").glob("*.sqlite3")))
    connection.execute('ALTER TABLE "events" RENAME TO "events-legacy"')
    connection.commit()
    connection.close()
    return {
        finding_id("table", "events-legacy", "identifier"): ("rename", new_name),
        finding_id("table", "events-legacy", "no_timestamps"): (
            "separate-import",
            None,
        ),
    }


def test_a_renamed_timestampless_table_is_routed_under_its_new_name(
    mutable_source, workspace
):
    """The mixed-policy manifest must name the collection that actually exists.

    Routing by source table would emit an import manifest naming a collection the schema
    document never creates -- and the operator only finds out at import time.
    """
    overrides = _rename_timestampless_events(mutable_source, "gatherings")
    src, decisions = _decide(mutable_source, **overrides)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    manifest = json.loads((bundle / "manifest.json").read_text())
    gathering = next(
        entry
        for entry in manifest["collections"]
        if entry["collection"] == "gatherings"
    )
    assert gathering == {
        "collection": "gatherings",
        "file": "data/gatherings.ndjson",
        "preserveTimestamps": False,
    }
    assert (bundle / "data/gatherings.ndjson").is_file()
    assert not (bundle / "manifest-no-timestamps.json").exists()


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------


def _attach_second_blob(source, filename):
    """Give one record a second attachment that shares a filename with the first."""
    connection = _db(source)
    blob = dict(connection.execute("SELECT * FROM active_storage_blobs").fetchone())
    attachment = dict(
        connection.execute("SELECT * FROM active_storage_attachments").fetchone()
    )
    new_key = "z" * len(blob["key"])
    blob.update(id=blob["id"] + 1000, key=new_key, filename=filename)
    connection.execute(
        f"INSERT INTO active_storage_blobs ({','.join(blob)}) "
        f"VALUES ({','.join('?' * len(blob))})",
        list(blob.values()),
    )
    attachment.update(id=attachment["id"] + 1000, name="thumbnail", blob_id=blob["id"])
    connection.execute(
        f"INSERT INTO active_storage_attachments ({','.join(attachment)}) "
        f"VALUES ({','.join('?' * len(attachment))})",
        list(attachment.values()),
    )
    connection.commit()
    connection.close()
    target = source / "storage" / new_key[0:2] / new_key[2:4] / new_key
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"second blob bytes")
    # Declare it on the model too: `has_one_attached :thumbnail`. An attachment row the
    # model does not declare is deliberately left behind now.
    models = read_inventory(source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["attachments"].append(
        {"source": "observed", "name": "thumbnail", "macro": "has_one_attached"}
    )
    write_inventory(source, "models", models)
    return new_key


def test_two_attachments_sharing_a_filename_get_distinct_targets(mutable_source):
    """ZigBase resolves a file at `{collection}/{record}/{name}`; equal names collide.

    Both would install to one path: whichever ran second would overwrite the first, and
    one attachment would silently serve the other's bytes.
    """
    connection = _db(mutable_source)
    original = connection.execute(
        "SELECT filename FROM active_storage_blobs"
    ).fetchone()["filename"]
    connection.close()
    _attach_second_blob(mutable_source, original)

    src, decisions = _decide(mutable_source)
    mapped = rails2zb.map_tables(src, decisions)
    with rails2zb._connect(next((mutable_source / "db").glob("*.sqlite3"))) as conn:
        plan, _ = rails2zb.build_file_plan(src, conn, mapped)
    shared = [i for i in plan if i["filename"] == original]
    assert len(shared) == 2, "the fixture mutation should produce two same-named blobs"
    targets = {(i["collection"], i["recordId"], i["targetName"]) for i in shared}
    assert len(targets) == 2, f"both attachments install to one path: {targets}"


def test_a_blob_that_changed_since_extraction_is_refused(mutable_source, workspace):
    """The pin is the only thing standing between a stale snapshot and a silent swap."""
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    manifest = json.loads((bundle / "files/manifest.json").read_text())
    item = manifest["files"][0]
    (mutable_source / item["sourcePath"]).write_bytes(b"different bytes entirely")
    with pytest.raises(rails2zb.RailsError, match="changed since extraction"):
        rails2zb.install_files(bundle, mutable_source, workspace / "data")


def test_an_omitted_tables_blobs_are_left_behind(mutable_source, workspace):
    """A blob filed under a collection the schema never creates cannot be served.

    And it is reported as an omitted TABLE, not as a dropped attachment: the whole
    collection is gone, which `omittedTables` already says.
    """
    src, decisions = _decide(mutable_source)
    mapped = [m for m in rails2zb.map_tables(src, decisions) if m.table != "posts"]
    with rails2zb._connect(next((mutable_source / "db").glob("*.sqlite3"))) as conn:
        plan, dropped = rails2zb.build_file_plan(src, conn, mapped)
    assert "posts" not in {i["collection"] for i in plan}
    assert dropped == [], (
        "an omitted table's attachments are covered by `omittedTables`; listing them "
        "again as dropped attachments describes a decision nobody made"
    )


def test_omitting_a_table_also_forgives_its_damaged_blobs(mutable_source):
    """`omit` must be a usable route around the broken part of a snapshot."""
    src, decisions = _decide(mutable_source)
    mapped = rails2zb.map_tables(src, decisions)
    with rails2zb._connect(next((mutable_source / "db").glob("*.sqlite3"))) as conn:
        for (item,) in [(i,) for i in rails2zb.build_file_plan(src, conn, mapped)[0]]:
            (mutable_source / item["sourcePath"]).unlink()
        with pytest.raises(rails2zb.RailsError, match="missing blob"):
            rails2zb.build_file_plan(src, conn, mapped)
        kept = [m for m in mapped if m.table != "posts"]
        assert rails2zb.build_file_plan(src, conn, kept)[0] == []


# ---------------------------------------------------------------------------
# Import limits
# ---------------------------------------------------------------------------


def test_a_record_too_large_for_the_importer_is_refused(mutable_source, workspace):
    """Otherwise the bundle extracts and hashes cleanly, then fails the import."""
    connection = _db(mutable_source)
    connection.execute(
        "UPDATE posts SET body = ?", ("x" * (rails2zb.IMPORT_LINE_LIMIT + 10),)
    )
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="refuses any line over"):
        rails2zb.extract(src, decisions, workspace / "bundle")


@pytest.mark.parametrize("separator", ["\u2028", "\u2029", "\u0085"])
def test_an_oversized_record_split_by_a_unicode_separator_is_still_refused(
    mutable_source, workspace, separator
):
    """These three break `str.splitlines()` but not the importer's line reader.

    `canonical_line` writes them raw — it serializes with `ensure_ascii=False`, and
    json escapes nothing above U+001F — so a record whose fragments each fit measured
    as several short lines and sailed through. The engine reads physical newlines
    (`takeDelimiter('\n')`), so the import then died on a bundle `hashes.json` had
    already certified.
    """
    half = "x" * (rails2zb.IMPORT_LINE_LIMIT // 2 + 10)
    connection = _db(mutable_source)
    connection.execute("UPDATE posts SET body = ?", (half + separator + half,))
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="refuses any line over"):
        rails2zb.extract(src, decisions, workspace / "bundle")


# ---------------------------------------------------------------------------
# Rename contradictions
# ---------------------------------------------------------------------------


def _two_invalid_tables(source):
    schema = read_inventory(source, "schema")
    for original, replacement in (("events", "events-legacy"), ("flags", "flags-old")):
        next(t for t in schema["tables"] if t["name"] == original)["name"] = replacement
        connection = sqlite3.connect(next((source / "db").glob("*.sqlite3")))
        connection.execute(f'ALTER TABLE "{original}" RENAME TO "{replacement}"')
        connection.commit()
        connection.close()
    write_inventory(source, "schema", schema)
    models = read_inventory(source, "models")
    for model in models["models"]:
        for key, replacement in (("events", "events-legacy"), ("flags", "flags-old")):
            if model.get("table_name") == key:
                model["table_name"] = replacement
            for association in model.get("associations") or []:
                if association.get("table_name") == key:
                    association["table_name"] = replacement
    write_inventory(source, "models", models)
    return (
        finding_id("table", "events-legacy", "identifier"),
        finding_id("table", "flags-old", "identifier"),
    )


def test_two_tables_renamed_to_one_collection_are_refused(mutable_source):
    first, second = _two_invalid_tables(mutable_source)
    src, decisions = _decide(
        mutable_source,
        **{first: ("rename", "archive"), second: ("rename", "archive")},
    )
    with pytest.raises(rails2zb.RailsError, match="renamed to the same collection"):
        rails2zb.map_tables(src, decisions)


def test_a_rename_onto_an_existing_collection_is_refused(mutable_source):
    first, _ = _two_invalid_tables(mutable_source)
    src, decisions = _decide(mutable_source, **{first: ("rename", "posts")})
    with pytest.raises(rails2zb.RailsError, match="collide with existing collections"):
        rails2zb.map_tables(src, decisions)


def test_a_table_both_renamed_and_omitted_is_refused(mutable_source):
    """Two decisions that cannot both be honoured; picking one silently is a guess."""
    first, _ = _two_invalid_tables(mutable_source)
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == first:
            entry["choice"] = "rename"
            entry["artifact"] = "archive"
    value["decisions"].append(
        {
            "id": finding_id("table", "events-legacy", "no_timestamps"),
            "choice": "omit",
            "rationale": "contradiction under test",
        }
    )
    decisions = rails2zb.load_decisions_from_value(value)
    with pytest.raises(rails2zb.RailsError, match="both renamed and omitted"):
        rails2zb.map_tables(src, decisions)


def test_a_rename_artifact_is_a_name_not_a_path(mutable_source, tmp_path):
    """`reconcile` checks that an artifact PATH exists; a rename's artifact is a NAME.

    Treating it as a path made every `--artifacts` run refuse the rename it was given.
    """
    first, _ = _two_invalid_tables(mutable_source)
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == first:
            entry["choice"] = "rename"
            entry["artifact"] = "archive"
    materialize_artifacts(value, tmp_path)
    rails2zb.reconcile(
        findings, rails2zb.load_decisions_from_value(value), artifact_root=tmp_path
    )
    assert not (tmp_path / "archive").exists(), (
        "the harness must not have created a file named `archive`"
    )


# ---------------------------------------------------------------------------
# The report describes what was actually done
# ---------------------------------------------------------------------------


def test_the_report_names_public_rules_by_their_real_table_name(
    mutable_source, workspace
):
    """A dotted table was reported as `legacy%2Eevents` -- the escaped id, not a name."""
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["name"] = "legacy.events"
    write_inventory(mutable_source, "schema", schema)
    connection = sqlite3.connect(next((mutable_source / "db").glob("*.sqlite3")))
    connection.execute('ALTER TABLE "events" RENAME TO "legacy.events"')
    connection.commit()
    connection.close()

    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("table", "legacy.events", "identifier"): ("rename", "events"),
            finding_id("table", "legacy.events", "rules"): ("public", None),
        },
    )
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert "legacy.events" in report["publicRules"]
    assert not any("%" in name for name in report["publicRules"])


def test_the_report_does_not_claim_work_on_an_omitted_table(mutable_source, workspace):
    """An omitted table was still listed as `timestampMirrored`."""
    schema = read_inventory(mutable_source, "schema")
    events = next(t for t in schema["tables"] if t["name"] == "events")
    events["columns"] = [c for c in events["columns"] if c["name"] != "updated_at"]
    events["primary_key"] = "uuid"
    write_inventory(mutable_source, "schema", schema)
    fid = finding_id("table", "events", "primary_key")
    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert "events" in report["omittedTables"]
    assert "events" not in report["timestampMirrored"]


def test_an_empty_digest_reads_as_a_provider_only_account(mutable_source, workspace):
    """`""` is what a provider-only row looks like, and the message must say so.

    "Unsupported hash" would send the operator looking for an algorithm problem that
    does not exist.
    """
    connection = _db(mutable_source)
    connection.execute("UPDATE users SET password_digest = ''")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="provider-only"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_a_partial_index_predicate_survives_its_table_being_renamed(
    mutable_source, workspace
):
    """Predicates are keyed by SOURCE table; the collection it lands in is renamed."""
    schema = read_inventory(mutable_source, "schema")
    events = next(t for t in schema["tables"] if t["name"] == "events")
    events["name"] = "events-legacy"
    events["indexes"].append(
        {
            "source": "observed",
            "name": "index_events_on_starts_at",
            "columns": ["starts_at"],
            "unique": False,
            "where": "starts_at IS NOT NULL",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    models = read_inventory(mutable_source, "models")
    for model in models["models"]:
        if model.get("table_name") == "events":
            model["table_name"] = "events-legacy"
        for association in model.get("associations") or []:
            if association.get("table_name") == "events":
                association["table_name"] = "events-legacy"
    write_inventory(mutable_source, "models", models)
    connection = sqlite3.connect(next((mutable_source / "db").glob("*.sqlite3")))
    connection.execute('ALTER TABLE "events" RENAME TO "events-legacy"')
    connection.commit()
    connection.close()

    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("table", "events-legacy", "identifier"): (
                "rename",
                "gatherings",
            ),
            finding_id(
                "index", "events-legacy", "index_events_on_starts_at", "where"
            ): ("replacement", "starts_at IS NOT NULL"),
        },
    )
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    document = json.loads((bundle / "schema.json").read_text())
    collection = next(c for c in document["collections"] if c["name"] == "gatherings")
    emitted = {i["name"]: i for i in collection["indexes"]}
    assert emitted["index_events_on_starts_at"]["where"] == "starts_at IS NOT NULL"


def test_the_report_records_every_index_it_dropped(mutable_source, workspace):
    """An index can vanish for several honest reasons; all of them were silent."""
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["indexes"].append(
        {
            "source": "observed",
            "name": "index_posts_on_created_at",
            "columns": ["created_at"],
            "unique": False,
            "where": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert "posts.index_posts_on_created_at" in report["droppedIndexes"], (
        "an index over a Rails timestamp cannot be expressed, and must be reported"
    )


def test_a_digest_with_trailing_junk_is_refused(mutable_source, workspace):
    """A prefix match would ship it, and every login would then fail."""
    connection = _db(mutable_source)
    digest = connection.execute("SELECT password_digest FROM users LIMIT 1").fetchone()[
        0
    ]
    connection.execute("UPDATE users SET password_digest = ?", (digest + "\n",))
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="no supported bcrypt credential"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_the_report_records_an_index_dropped_by_the_auth_field_filter(
    source, workspace
):
    """The commonest dropped index of all: the fixture's own index on users.email."""
    src, decisions = _decide(source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert "users.index_users_on_email" in report["droppedIndexes"]


def test_an_index_kept_by_a_reviewed_predicate_is_not_reported_as_dropped(
    mutable_source, workspace
):
    """The trail must describe the document, not a parallel recomputation of it."""
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["indexes"][0]["where"] = "author_id IS NOT NULL"
    name = posts["indexes"][0]["name"]
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("index", "posts", name, "where"): (
                "replacement",
                "author IS NOT NULL",
            )
        },
    )
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert f"posts.{name}" not in report["droppedIndexes"]


def test_a_rename_colliding_only_by_case_is_refused(mutable_source):
    """SQLite and ZigBase both compare collection names case-insensitively."""
    first, _ = _two_invalid_tables(mutable_source)
    src, decisions = _decide(mutable_source, **{first: ("rename", "Posts")})
    with pytest.raises(rails2zb.RailsError, match="collide with existing collections"):
        rails2zb.map_tables(src, decisions)


def _slash_filename(source, name="a/b.png"):
    connection = _db(source)
    connection.execute("UPDATE active_storage_blobs SET filename = ?", (name,))
    connection.commit()
    connection.close()


def test_a_filename_containing_a_path_is_made_servable_at_extract_time(
    mutable_source, workspace
):
    """ZigBase serves `{collection}/{record}/{name}`; a slash is a different path.

    Active Storage keeps the client-supplied name verbatim, so this is reachable from
    any real upload form. Refusing at install time was far too late: under the
    documented order the rows naming that file are already imported.
    """
    _slash_filename(mutable_source)
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    manifest = json.loads((bundle / "files/manifest.json").read_text())
    item = next(i for i in manifest["files"] if i["filename"] == "a/b.png")
    assert "/" not in item["targetName"]
    assert item["filename"] == "a/b.png", "the source name stays on record"

    rows = [
        json.loads(line)
        for line in (bundle / "data" / "posts.ndjson").read_text().splitlines()
    ]
    named = [r["cover"] for r in rows if r.get("cover")]
    assert named and all("/" not in n for n in named), (
        "the record must name the file the target will actually serve"
    )
    rails2zb.install_files(bundle, mutable_source, workspace / "data")


def test_omitting_an_attachment_leaves_its_blobs_behind(mutable_source, workspace):
    """The decision dropped the field; the bytes were installed anyway, orphaned."""
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["attachments"].append(
        {"source": "observed", "name": "verified", "macro": "has_one_attached"}
    )
    write_inventory(mutable_source, "models", models)
    connection = _db(mutable_source)
    connection.execute("UPDATE active_storage_attachments SET name = 'verified'")
    connection.commit()
    connection.close()

    fid = finding_id("attachment", "posts", "verified", "reserved")
    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    manifest = json.loads((bundle / "files/manifest.json").read_text())
    assert manifest["files"] == [], "a dropped attachment's bytes must not travel"
    report = json.loads((bundle / "report.json").read_text())
    assert "posts.verified" in report["droppedAttachments"]


def test_an_attachment_the_model_no_longer_declares_is_left_behind(
    mutable_source, workspace
):
    """A stale Active Storage row installed a blob no record could ever reference."""
    connection = _db(mutable_source)
    connection.execute("UPDATE active_storage_attachments SET name = 'legacy_photo'")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    assert json.loads((bundle / "files/manifest.json").read_text())["files"] == []
    report = json.loads((bundle / "report.json").read_text())
    assert "posts.legacy_photo" in report["droppedAttachments"]


def test_a_rule_naming_one_action_twice_is_refused():
    """The last line silently won, discarding half a reviewed rule set."""
    with pytest.raises(rails2zb.RailsError, match="more than once"):
        _rule("list = @request.auth.id != ''\nlist = @request.auth.id = ''")


@pytest.mark.parametrize(
    ("filename", "forbidden"),
    [("../../etc/passwd", ".."), (".hidden.png", "."), ("....png", ".")],
)
def test_a_traversing_or_hidden_filename_is_made_servable(
    mutable_source, workspace, filename, forbidden
):
    """`_contained` catches traversal at install; the NAME must never carry it at all.

    A leading dot also makes the stored file hidden, which is not what the source meant
    by an uploaded attachment.
    """
    _slash_filename(mutable_source, filename)
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    manifest = json.loads((bundle / "files/manifest.json").read_text())
    target = manifest["files"][0]["targetName"]
    assert not target.startswith(forbidden), f"unservable target name {target!r}"
    assert "/" not in target
    rails2zb.install_files(bundle, mutable_source, workspace / "data")


def test_an_older_inventory_without_attributes_still_refuses_ambiguity(mutable_source):
    """Pre-1.1 extractors recorded only `digest_columns`, with nothing to disambiguate.

    There is no evidence to choose on, so the refusal has to stand for those bundles.
    """
    auth = read_inventory(mutable_source, "auth")
    entry = next(e for e in auth["has_secure_password"] if e["table_name"] == "users")
    entry.pop("attributes")
    entry["digest_columns"] = ["password_digest", "remember_digest"]
    write_inventory(mutable_source, "auth", auth)
    with pytest.raises(rails2zb.RailsError, match="several password digests"):
        rails2zb._auth_tables(rails2zb.load_source(mutable_source))


@pytest.mark.parametrize(
    ("source_name", "expected"),
    [
        # The cases ZigBase's own `sanitizeBase` test pins (src/files/naming.zig).
        ("../../etc/passwd", "passwd"),
        ("a/b/c.png", "c.png"),
        ("a\\b\\c.png", "c.png"),
        ("my file.txt", "my_file.txt"),
        ("..", "file"),
        ("", "file"),
        (".", "file"),
        ("a*b?.c", "a_b.c"),
        (".bashrc", "bashrc"),
        ("*.", "file"),
        ("*..", "file"),
        ("*.png", "png"),
        # The ones that actually bite a real Rails app.
        ("My Photo.png", "My_Photo.png"),
        ("café.png", "caf.png"),
        ("a%b.png", "a_b.png"),
        ("a#b.png", "a_b.png"),
        (". x.png", "x.png"),
        # A run of invalid characters at the END yields no trailing separator.
        ("a*", "a"),
        ("a**b", "a_b"),
        ("*", "file"),
    ],
)
def test_a_filename_is_reduced_to_what_the_target_will_serve(source_name, expected):
    """The file route byte-compares the raw path segment and never percent-decodes it.

    The SDKs build the URL with `encodeURIComponent`, so anything outside
    `[A-Za-z0-9._-]` installs cleanly and then 404s for every client. This mirrors the
    engine's own sanitizer rather than inventing a second, subtly different rule.
    """
    assert rails2zb._servable_name(source_name) == expected


@pytest.mark.parametrize(
    ("name", "keeps_extension"),
    [
        ("x" * 300 + ".png", True),
        # No extension, and an "extension" too long to be one, both fall back to a
        # straight byte truncation rather than inventing a suffix.
        ("x" * 300, False),
        ("x" * 300 + "." + "y" * 40, False),
    ],
)
def test_a_long_filename_is_bounded_without_losing_its_extension(name, keeps_extension):
    """A truncation that splits a multi-byte character must not emit invalid UTF-8."""
    bounded = rails2zb._bounded_name(name)
    assert len(bounded.encode("utf-8")) <= rails2zb.TARGET_NAME_LIMIT
    assert bounded.endswith(".png") is keeps_extension
    bounded.encode("utf-8").decode("utf-8")


def test_bounding_a_multibyte_name_never_splits_a_character():
    """`é` is two bytes; a byte-slice at the limit can land between them."""
    for length in range(90, 130):
        bounded = rails2zb._bounded_name("é" * length + ".png")
        assert len(bounded.encode("utf-8")) <= rails2zb.TARGET_NAME_LIMIT
        # Would raise if the slice had cut a character in half.
        bounded.encode("utf-8").decode("utf-8", "strict")


def test_a_rewritten_filename_still_reaches_the_record(mutable_source, workspace):
    _slash_filename(mutable_source, "My Photo.png")
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    manifest = json.loads((bundle / "files/manifest.json").read_text())
    item = manifest["files"][0]
    assert item["targetName"] == "My_Photo.png"
    assert item["filename"] == "My Photo.png", "the source name stays on record"
    rows = [
        json.loads(line)
        for line in (bundle / "data" / "posts.ndjson").read_text().splitlines()
    ]
    assert "My_Photo.png" in [r.get("cover") for r in rows]


def test_two_filenames_colliding_only_after_the_rewrite_stay_distinct(mutable_source):
    """The rewrite can CREATE a collision: `My Photo.png` and `My_Photo.png`."""
    _attach_second_blob(mutable_source, "My Photo.png")
    connection = _db(mutable_source)
    connection.execute(
        "UPDATE active_storage_blobs SET filename = 'My_Photo.png' "
        "WHERE key NOT LIKE 'zzz%'"
    )
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    mapped = rails2zb.map_tables(src, decisions)
    with rails2zb._connect(next((mutable_source / "db").glob("*.sqlite3"))) as conn:
        plan, _ = rails2zb.build_file_plan(src, conn, mapped)
    targets = {(i["collection"], i["recordId"], i["targetName"]) for i in plan}
    assert len(targets) == len(plan) == 2


def test_two_models_sharing_a_table_cannot_disagree_about_the_credential(
    mutable_source,
):
    """Judging each entry alone let the ambiguity through, decided by model name order."""
    auth = read_inventory(mutable_source, "auth")
    entry = next(e for e in auth["has_secure_password"] if e["table_name"] == "users")
    auth["has_secure_password"] = [
        {**entry, "model": "User", "attributes": ["password"]},
        {
            **entry,
            "model": "AdminUser",
            "attributes": ["recovery"],
            "digest_columns": sorted(entry["digest_columns"] + ["recovery_digest"]),
        },
    ]
    write_inventory(mutable_source, "auth", auth)
    with pytest.raises(rails2zb.RailsError, match="several secure passwords"):
        rails2zb._auth_tables(rails2zb.load_source(mutable_source))


def test_omitting_an_attachment_also_forgives_its_damaged_blob(
    mutable_source, workspace
):
    """`omit` on an attachment must be as usable an escape as `omit` on the table.

    The missing-blob refusal ran first, so an operator with one corrupt blob had to drop
    the entire table -- and its rows -- to get past it.
    """
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["attachments"].append(
        {"source": "observed", "name": "verified", "macro": "has_one_attached"}
    )
    write_inventory(mutable_source, "models", models)
    connection = _db(mutable_source)
    connection.execute("UPDATE active_storage_attachments SET name = 'verified'")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    mapped = rails2zb.map_tables(src, decisions)
    with rails2zb._connect(next((mutable_source / "db").glob("*.sqlite3"))) as conn:
        for item in rails2zb.build_file_plan(src, conn, mapped)[0]:
            (mutable_source / item["sourcePath"]).unlink()

    fid = finding_id("attachment", "posts", "verified", "reserved")
    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert "posts.verified" in report["droppedAttachments"]


def test_one_pre_1_1_entry_makes_the_whole_table_untrustworthy(mutable_source):
    """A hand-merged inventory can carry both shapes for one table.

    The entry with no `attributes` has no disambiguation behind it, so the table falls
    back to the count-based refusal rather than trusting whichever entry came last.
    """
    auth = read_inventory(mutable_source, "auth")
    entry = next(e for e in auth["has_secure_password"] if e["table_name"] == "users")
    legacy = {k: v for k, v in entry.items() if k != "attributes"}
    legacy["digest_columns"] = sorted(entry["digest_columns"] + ["remember_digest"])
    auth["has_secure_password"] = [
        {**legacy, "model": "LegacyUser"},
        {**entry, "model": "User", "attributes": ["password"]},
    ]
    write_inventory(mutable_source, "auth", auth)
    with pytest.raises(rails2zb.RailsError, match="several password digests"):
        rails2zb._auth_tables(rails2zb.load_source(mutable_source))


def test_an_absurdly_long_filename_is_bounded_before_install(mutable_source, workspace):
    """Extract-and-hash-clean then ENAMETOOLONG mid-install is the worst ordering.

    The rows naming the file are already imported by then, under the documented order.
    """
    _slash_filename(mutable_source, "x" * 300 + ".png")
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    item = json.loads((bundle / "files/manifest.json").read_text())["files"][0]
    assert len(item["targetName"].encode()) <= rails2zb.TARGET_NAME_LIMIT
    assert item["targetName"].endswith(".png"), "the extension has to survive"
    assert len(item["filename"]) == 304, "the source name stays on record"
    rails2zb.install_files(bundle, mutable_source, workspace / "data")


def _drop_created_at(source, table="posts"):
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    entry["columns"] = [c for c in entry["columns"] if c["name"] != "created_at"]
    write_inventory(source, "schema", schema)
    connection = sqlite3.connect(next((source / "db").glob("*.sqlite3")))
    connection.execute(f'ALTER TABLE "{table}" DROP COLUMN created_at')
    connection.commit()
    connection.close()


def test_a_table_with_only_updated_at_is_a_decision(mutable_source):
    """The truth table had a hole: neither-column blocked, created-only mirrored, and
    updated-only fell through both and shipped into the main manifest.

    Mirroring `updated` into `created` would fabricate a creation time -- "last touched"
    is not "made" -- so this cannot be the courtesy the opposite case gets.
    """
    _drop_created_at(mutable_source)
    src = rails2zb.load_source(mutable_source)
    finding = next(
        f for f in rails2zb.build_findings(src) if f.id == "table.posts.no_timestamps"
    )
    assert finding.severity == "blocker"
    assert finding.choices == ("separate-import", "omit")


def test_an_updated_at_only_table_disables_timestamp_preservation(
    mutable_source, workspace
):
    _drop_created_at(mutable_source, "events")
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    main = json.loads((bundle / "manifest.json").read_text())
    event = next(c for c in main["collections"] if c["collection"] == "events")
    assert event["preserveTimestamps"] is False


def test_a_timestampless_auth_file_is_named_in_the_report(mutable_source, workspace):
    """An auth file is imported on its own, so there is no second manifest for it.

    The report is the only place that can tell the operator to drop
    `--preserve-timestamps` for that one file; without it the documented command fails
    after the rest of the migration has already run.
    """
    _drop_created_at(mutable_source, "users")
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert report["authFilesNoTimestamps"] == ["auth/users.ndjson"]
    assert "auth/users.ndjson" in report["authFiles"]

    rows = [
        json.loads(line)
        for line in (bundle / "auth" / "users.ndjson").read_text().splitlines()
    ]
    assert rows and all("created" not in row for row in rows)


def _null_created_at(source, table="comments"):
    """Drop the NOT NULL and null one row, the way a Rails <= 4 schema allowed."""
    path = next((source / "db").glob("*.sqlite3"))
    connection = sqlite3.connect(path)
    ddl = connection.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)
    ).fetchone()[0]
    connection.execute("PRAGMA writable_schema = ON")
    connection.execute(
        "UPDATE sqlite_master SET sql = ? WHERE type = 'table' AND name = ?",
        (
            ddl.replace(
                '"created_at" datetime(6) NOT NULL', '"created_at" datetime(6)'
            ),
            table,
        ),
    )
    connection.execute("PRAGMA writable_schema = OFF")
    connection.commit()
    connection.close()
    connection = sqlite3.connect(path)
    connection.execute(f'UPDATE "{table}" SET created_at = NULL WHERE id = 1')
    connection.commit()
    connection.close()


def _nullable_timestamps(source, table="comments"):
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    for column in entry["columns"]:
        if column["name"] in ("created_at", "updated_at"):
            column["null"] = True
    write_inventory(source, "schema", schema)


def test_a_nullable_timestamp_column_is_a_decision(mutable_source):
    """The column-level gate saw a timestamp and waved the table through.

    Rails <= 4 wrote `t.timestamps` as nullable, and legacy apps are exactly the
    population being re-platformed — so a row with a NULL `created_at` extracted clean
    and then failed the documented `--preserve-timestamps` import.
    """
    _nullable_timestamps(mutable_source)
    src = rails2zb.load_source(mutable_source)
    finding = next(
        f
        for f in rails2zb.build_findings(src)
        if f.id == "table.comments.nullable_timestamps"
    )
    assert finding.severity == "blocker"
    assert finding.choices == ("separate-import", "omit")


def test_a_nullable_timestamp_disables_timestamp_preservation(
    mutable_source, workspace
):
    _nullable_timestamps(mutable_source)
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    main = json.loads((bundle / "manifest.json").read_text())
    comments = next(c for c in main["collections"] if c["collection"] == "comments")
    assert comments["preserveTimestamps"] is False


def test_a_row_with_no_created_value_is_refused(mutable_source, workspace):
    """The load-bearing check: an inventory claiming NOT NULL can simply be wrong.

    That drift is the kind of thing a migration exists to discover, not to ship past.
    """
    _null_created_at(mutable_source)

    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="no created timestamp"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_a_timestampless_row_is_allowed_once_routed_separately(
    mutable_source, workspace
):
    """`separate-import` is the decision that makes those rows legal to ship."""
    _nullable_timestamps(mutable_source)
    _null_created_at(mutable_source)

    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    rows = [
        json.loads(line)
        for line in (bundle / "data" / "comments.ndjson").read_text().splitlines()
    ]
    assert any("created" not in row for row in rows)


# ---------------------------------------------------------------------------
# The import contract is valued per ROW, not per column
# ---------------------------------------------------------------------------


def test_a_not_null_column_holding_empty_values_is_not_required(
    mutable_source, workspace
):
    """`t.string :x, null: false, default: ""` is idiomatic Rails.

    ZigBase's `required` rejects emptiness, not just NULL, so mapping NOT NULL straight
    onto it produced a schema the source's own rows violate — and the import died
    partway through on data that was never wrong. Refusing the row would punish correct
    data, so the mapping gives way and the report says where.
    """
    connection = _db(mutable_source)
    connection.execute("UPDATE comments SET body = '' WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    document = json.loads((bundle / "schema.json").read_text())
    comments = next(c for c in document["collections"] if c["name"] == "comments")
    body = next(f for f in comments["fields"] if f["name"] == "body")
    assert body["required"] is False
    report = json.loads((bundle / "report.json").read_text())
    assert "comments.body" in report["relaxedRequired"]


def test_a_not_null_column_with_no_empties_stays_required(source, workspace):
    src, decisions = _decide(source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    document = json.loads((bundle / "schema.json").read_text())
    comments = next(c for c in document["collections"] if c["name"] == "comments")
    assert (
        next(f for f in comments["fields"] if f["name"] == "body")["required"] is True
    )
    assert json.loads((bundle / "report.json").read_text())["relaxedRequired"] == []


def test_a_relation_pointing_at_a_missing_row_is_refused(mutable_source, workspace):
    """The row-level sibling of the foreign-key gate.

    SQLite did not enforce foreign keys for most of Rails' history, so legacy apps
    carry orphans routinely — and the target validates every relation.
    """
    connection = _db(mutable_source)
    connection.execute("PRAGMA foreign_keys = OFF")
    connection.execute("UPDATE comments SET post_id = 999999 WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="does not exist"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_text_sitting_in_a_number_column_is_refused(mutable_source, workspace):
    """SQLite's dynamic typing lets an INTEGER column hold 'banana'."""
    connection = _db(mutable_source)
    connection.execute("UPDATE events SET pages_target = 'banana' WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="not a number"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_an_infinite_float_cannot_be_written_as_json(mutable_source, workspace):
    """Python emits a bare `Infinity`, which is not JSON — and hashes.json would
    certify the malformed bytes as the bundle's own."""
    connection = _db(mutable_source)
    connection.execute("UPDATE events SET pages_target = 9e999 WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="JSON cannot represent"):
        rails2zb.extract(src, decisions, workspace / "bundle")


@pytest.mark.parametrize("bad", ["", "  ", "a b", "café", "x" * 300])
def test_an_id_the_target_will_not_accept_is_refused(mutable_source, bad):
    """A TEXT `id` column is legal in SQLite and passed every gate.

    An empty one imported cleanly WITHOUT --preserve-timestamps: the engine generated a
    fresh id and every relation pointing at that row silently dangled.
    """
    src, decisions = _decide(mutable_source)
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "events")
    connection = _db(mutable_source)
    row = dict(connection.execute("SELECT * FROM events LIMIT 1").fetchone())
    connection.close()
    with pytest.raises(rails2zb.RailsError):
        rails2zb.build_record(entry, {**row, "id": bad})


def test_a_null_id_is_refused_rather_than_stringified(mutable_source):
    """`str(None)` shipped the literal `"None"` as a record id."""
    src, decisions = _decide(mutable_source)
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "events")
    connection = _db(mutable_source)
    row = dict(connection.execute("SELECT * FROM events LIMIT 1").fetchone())
    connection.close()
    with pytest.raises(rails2zb.RailsError, match="no id"):
        rails2zb.build_record(entry, {**row, "id": None})


def test_a_serialized_null_relaxes_required_too(mutable_source, workspace):
    """Emptiness belongs to the EMITTED value, not the raw column bytes.

    A `serialize`d nil writes the literal text `null` — non-empty in SQLite, satisfying
    NOT NULL, and emitted as JSON null, which the target rejects for a required field.
    """
    connection = _db(mutable_source)
    connection.execute("UPDATE notifications SET payload = 'null' WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert "notifications.payload" in report["relaxedRequired"]


def test_text_that_merely_looks_empty_stays_required(mutable_source, workspace):
    """The reverse direction: a text column whose CONTENT is the two characters `[]`.

    Comparing raw bytes relaxed a field the engine would have accepted as required —
    weakening the emitted schema for data that was never empty.
    """
    connection = _db(mutable_source)
    connection.execute("UPDATE comments SET body = '[]' WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert "comments.body" not in report["relaxedRequired"]
    document = json.loads((bundle / "schema.json").read_text())
    comments = next(c for c in document["collections"] if c["name"] == "comments")
    assert (
        next(f for f in comments["fields"] if f["name"] == "body")["required"] is True
    )


def test_relations_crossing_timestamp_policies_both_ways_share_one_manifest(
    mutable_source, workspace
):
    """Mixed timestamp policy must not split one relation graph into two runs.

    `posts` is referenced by `comments` and itself references `clubs`. Manifest v2
    keeps all three in the same deferred-relation pass while only posts disables
    timestamp preservation.
    """
    _drop_created_at(mutable_source, "posts")
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    report = rails2zb.extract(src, decisions, bundle)
    manifest = json.loads((bundle / "manifest.json").read_text())
    policies = {
        entry["collection"]: entry["preserveTimestamps"]
        for entry in manifest["collections"]
    }
    assert policies["posts"] is False
    assert policies["comments"] is True
    assert policies["clubs"] is True
    assert report["manifestOrder"] == ["manifest.json"]


def test_duplicate_auth_emails_are_refused(mutable_source, workspace):
    """`validates_uniqueness_of` with no database index is the classic race-prone
    Rails setup, and the engine puts a UNIQUE index on an auth collection's email."""
    # The legacy shape IS the absence of the index: `validates_uniqueness_of` only.
    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    users["indexes"] = [i for i in users["indexes"] if "email" not in i["columns"]]
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    for (name,) in connection.execute(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'users'"
    ).fetchall():
        if name and not name.startswith("sqlite_"):
            connection.execute(f'DROP INDEX "{name}"')
    connection.commit()
    first, second = [
        r[0] for r in connection.execute("SELECT id FROM users ORDER BY id LIMIT 2")
    ]
    connection.execute(
        "UPDATE users SET email = (SELECT email FROM users WHERE id = ?) WHERE id = ?",
        (first, second),
    )
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="duplicate values"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_a_fractional_value_in_an_integer_column_is_refused(mutable_source, workspace):
    """SQLite keeps a REAL's storage class even inside an INTEGER column."""
    connection = _db(mutable_source)
    connection.execute("UPDATE clubs SET posts_count = 1.5 WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="fractional"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_an_attachment_on_a_deleted_record_is_left_behind(mutable_source, workspace):
    """Its bytes were installed under a record directory that will never exist."""
    connection = _db(mutable_source)
    connection.execute("UPDATE active_storage_attachments SET record_id = 999999")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    assert json.loads((bundle / "files/manifest.json").read_text())["files"] == []
    report = json.loads((bundle / "report.json").read_text())
    assert report["droppedAttachments"] == ["posts.cover"]


@pytest.mark.parametrize("stored", ["[]", "[ ]", '""'])
def test_a_json_column_emitting_an_empty_value_relaxes_required(
    mutable_source, workspace, stored
):
    """`[ ]` with a space inside parses to an empty array and never matched a raw
    byte comparison; `""` parses to an empty string."""
    connection = _db(mutable_source)
    connection.execute("UPDATE notifications SET payload = ? WHERE id = 1", (stored,))
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert "notifications.payload" in report["relaxedRequired"]


def test_a_json_column_holding_infinity_is_refused(mutable_source, workspace):
    """`json.loads('Infinity')` succeeds in Python and yields a float JSON cannot emit.

    The number branch never sees this one — it arrives through the json parse — so the
    writer's own guard is the thing that catches it.
    """
    connection = _db(mutable_source)
    connection.execute("UPDATE notifications SET payload = 'Infinity' WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="JSON cannot represent"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def _drop_timestamps(source, *tables):
    schema = read_inventory(source, "schema")
    for table in tables:
        entry = next(t for t in schema["tables"] if t["name"] == table)
        entry["columns"] = [
            c for c in entry["columns"] if c["name"] not in ("created_at", "updated_at")
        ]
    write_inventory(source, "schema", schema)


def test_an_auth_collection_is_not_a_manifest_boundary(mutable_source, workspace):
    """An auth collection rides in NEITHER manifest — it imports before both.

    Counting it as a manifest member turned every ordinary relation INTO users
    (clubs.owner_id, memberships.user_id, ...) into a boundary crossing, refusing a
    perfectly valid migration with no decision available to resolve it: only tables
    that HAVE the finding can be moved across the boundary.
    """
    _drop_timestamps(mutable_source, "users", "posts", "comments")
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)  # must not refuse
    report = json.loads((bundle / "report.json").read_text())
    assert report["manifestOrder"] == ["manifest.json"]


def test_the_reported_order_only_names_manifests_that_exist(mutable_source, workspace):
    """A timestampless AUTH table alone writes no second manifest at all."""
    _drop_timestamps(mutable_source, "users")
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    for name in report["manifestOrder"]:
        assert (bundle / name).is_file(), f"report names a missing {name}"
    assert report["authFilesNoTimestamps"] == ["auth/users.ndjson"]


@pytest.mark.parametrize("bad", ["admin", "a @b.c", "x@y.z ", "a@@b.c", "@b.c", "a@"])
def test_an_email_the_target_will_not_accept_is_refused(mutable_source, workspace, bad):
    """A legacy user table full of junk emails is ordinary.

    The auth import stops at the first one and leaves the collection empty, which then
    fails every later import that relates to it.
    """
    connection = _db(mutable_source)
    connection.execute("UPDATE users SET email = ? WHERE id = 1", (bad,))
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="as an email"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_an_empty_email_is_accepted(mutable_source, workspace):
    """The injected field is not required and its unique index is partial."""
    connection = _db(mutable_source)
    connection.execute("UPDATE users SET email = '' WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert not [name for name in report["relaxedRequired"] if name.startswith("users.")]


def test_an_integer_too_large_for_the_target_is_refused(mutable_source, workspace):
    """One step past the fractional case: an integral REAL that overflows i64."""
    connection = _db(mutable_source)
    connection.execute("UPDATE clubs SET posts_count = 1e300 WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="outside the range"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def _add_relation(source, table, column, to_table):
    """Give `table` a nullable foreign key to `to_table`, in inventory and database."""
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    entry["columns"].append(
        {
            "source": "observed",
            "name": column,
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    entry.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": column,
            "to_table": to_table,
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": f"fk_{table}_{column}",
        }
    )
    write_inventory(source, "schema", schema)
    connection = sqlite3.connect(next((source / "db").glob("*.sqlite3")))
    connection.execute(f'ALTER TABLE "{table}" ADD COLUMN "{column}" integer')
    connection.commit()
    connection.close()


def test_a_relation_from_a_separate_table_into_auth_is_not_a_crossing(
    mutable_source, workspace
):
    """`notifications` -> `users` is satisfied before either manifest runs.

    Counting it produced a "main-first" crossing that, combined with the genuine
    "separate-first" one below, refused a migration that imports perfectly well.
    """
    _add_relation(mutable_source, "clubs", "pinned_notification_id", "notifications")
    _drop_timestamps(mutable_source, "notifications")
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)  # must not refuse
    report = json.loads((bundle / "report.json").read_text())
    assert report["manifestOrder"] == ["manifest.json"]


def test_a_relation_out_of_auth_is_not_a_manifest_crossing_either(
    mutable_source, workspace
):
    """An auth collection is never in either manifest, so it cannot cross between them.

    `keep` leaves the relation in place — the operator has said they will re-establish
    the links — and that must not then be mistaken for a manifest ordering problem.
    """
    # users (auth) -> notifications (timestampless) would read as "separate-first",
    # while notifications -> clubs is a genuine "main-first". Counting the auth one
    # makes them contradict and refuses a migration that imports fine.
    _add_relation(mutable_source, "users", "pinned_notification_id", "notifications")
    _add_relation(mutable_source, "notifications", "about_club_id", "clubs")
    _drop_timestamps(mutable_source, "notifications")
    fid = finding_id("column", "users", "pinned_notification_id", "auth_relation")
    src, decisions = _decide(mutable_source, **{fid: ("keep", None)})
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)  # must not refuse
    report = json.loads((bundle / "report.json").read_text())
    assert report["manifestOrder"] == ["manifest.json"]


# ---------------------------------------------------------------------------
# Datetime components, not just datetime shape
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "stored",
    [
        "0000-00-00 00:00:00",  # the canonical legacy-MySQL zero date
        "2024-02-30 10:00:00",
        "2023-02-29 10:00:00",  # 2023 is not a leap year
        "1900-02-29 10:00:00",  # divisible by 4, but a century and not by 400
        "2024-13-01 10:00:00",
        "2024-01-15 24:00:00",
        "2024-01-15 10:60:00",
        "2024-01-15 10:00:60",
    ],
)
def test_an_impossible_datetime_is_refused(mutable_source, workspace, stored):
    """The pattern is digit-shaped only, so these hashed clean and killed the import.

    A zero date is exactly the vintage of data this converter exists for — the same
    population as the `'t'`/`'f'` booleans and the orphan foreign keys.
    """
    connection = _db(mutable_source)
    connection.execute("UPDATE events SET starts_at = ? WHERE id = 1", (stored,))
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="impossible"):
        rails2zb.extract(src, decisions, workspace / "bundle")


@pytest.mark.parametrize(
    "stored",
    [
        "2024-02-29 23:59:59",  # 2024 IS a leap year
        "2000-02-29 00:00:00",  # divisible by 400
        "0000-01-01 00:00:00",  # year zero: the engine accepts it, datetime.date cannot
        "2024-12-31 23:59:59",
    ],
)
def test_a_legal_datetime_at_the_boundary_still_converts(stored):
    """The accept side matters as much: `datetime.datetime` refuses year 0 outright,
    so validating through it would reject values the target imports happily."""
    assert rails2zb.to_rfc3339(stored).endswith("Z")


def test_a_relation_value_that_only_matches_by_affinity_is_refused(
    mutable_source, workspace
):
    """SQLite says `'01' = 1`; the engine matches record ids byte for byte.

    The anti-join agreed with SQLite, so the row passed the gate and then failed the
    import with earlier collections already committed.
    """
    connection = _db(mutable_source)
    connection.execute("PRAGMA writable_schema = ON")
    ddl = connection.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='posts'"
    ).fetchone()[0]
    connection.execute(
        "UPDATE sqlite_master SET sql = ? WHERE type='table' AND name='posts'",
        (ddl.replace('"club_id" integer', '"club_id" text'),),
    )
    connection.execute("PRAGMA writable_schema = OFF")
    connection.commit()
    connection.close()
    connection = _db(mutable_source)
    connection.execute("UPDATE posts SET club_id = '01' WHERE id = 1")
    connection.commit()
    connection.close()

    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="does not exist"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_the_timestamp_refusal_does_not_name_a_decision_that_cannot_exist(
    mutable_source, workspace
):
    """SQLite lets `''` satisfy NOT NULL on a datetime column, so the table raises no
    timestamp finding at all — and `separate-import` would be rejected as unknown."""
    connection = _db(mutable_source)
    connection.execute("UPDATE posts SET created_at = '' WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="no decision to record") as caught:
        rails2zb.extract(src, decisions, workspace / "bundle")
    assert "separate-import" not in str(caught.value)


def test_the_smallest_integer_the_target_refuses_is_refused(mutable_source, workspace):
    """The engine accumulates the magnitude before applying the sign, so the exact
    lower bound overflows on its way in."""
    connection = _db(mutable_source)
    connection.execute("UPDATE clubs SET posts_count = -9223372036854775808.0")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="outside the range"):
        rails2zb.extract(src, decisions, workspace / "bundle")


@pytest.mark.parametrize("stored", [3.0, 1e16, -1.0, 0.0])
def test_an_integral_real_the_target_accepts_still_converts(stored):
    """Only the single boundary value may tighten — nothing else."""
    assert rails2zb.coerce(stored, "number", None, number_mode="int") == stored


# ---------------------------------------------------------------------------
# Offset conversion, done on components rather than through `datetime`
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("stored", "expected"),
    [
        # A pre-1000 year: `strftime('%Y')` does not zero-pad on glibc, so this came
        # out as `499-12-31T...` — well-formed to every check upstream, malformed on
        # the way out, and rejected by the target's fixed-width parser.
        ("0499-12-31 23:30:00+01:00", "0499-12-31T22:30:00Z"),
        ("0001-01-01 00:00:00+05:00", "0000-12-31T19:00:00Z"),
        # Year zero with an offset: `datetime` refuses it outright, the engine does not.
        ("0000-01-01 09:30:15+05:00", "0000-01-01T04:30:15Z"),
        ("2024-03-01 00:30:00+01:00", "2024-02-29T23:30:00Z"),
        ("2024-01-15 09:00:00.123456-02:00", "2024-01-15T11:00:00.123456Z"),
        ("2024-01-15 09:00:00+0530", "2024-01-15T03:30:00Z"),
        # Seconds are optional in the engine's own grammar.
        ("2024-01-15 09:00", "2024-01-15T09:00:00Z"),
        ("2024-01-15 09:00-01:00", "2024-01-15T10:00:00Z"),
    ],
)
def test_an_offset_timestamp_converts_on_components(stored, expected):
    assert rails2zb.to_rfc3339(stored) == expected


def test_a_datetime_that_leaves_the_representable_range_is_refused():
    """`astimezone` raised an uncaught OverflowError here; the operator got a
    traceback mid-extraction instead of a refusal."""
    with pytest.raises(rails2zb.RailsError, match="representable range"):
        rails2zb.to_rfc3339("9999-12-31 23:59:59-05:30")


def test_a_trailing_newline_is_not_quietly_accepted():
    """`$` matches before a final newline; `\\Z` is the strict anchor."""
    with pytest.raises(rails2zb.RailsError, match="unrecognized"):
        rails2zb.to_rfc3339("2024-01-15 09:00:00\n")


def test_every_emitted_timestamp_is_one_the_target_can_parse():
    """The last gate before a timestamp leaves the converter.

    One assertion on the emitted text catches an unpadded field — and anything else
    that is well-formed going in and malformed coming out.
    """
    with pytest.raises(rails2zb.RailsError, match="not a timestamp the target"):
        rails2zb._emitted_timestamp("source", "499-12-31T22:30:00Z")
    assert rails2zb._emitted_timestamp("s", "0499-12-31T22:30:00Z")


def test_the_smallest_integer_is_accepted_from_an_integer_column(mutable_source):
    """SQLite integers are i64 by definition, and the engine binds them directly.

    Only the REAL storage class can overflow — it renders and then re-parses — so
    applying the range check to integers refused a value the target stores natively.
    """
    assert rails2zb.coerce(-(2**63), "number", None, number_mode="int") == -(2**63)
    with pytest.raises(rails2zb.RailsError, match="outside the range"):
        rails2zb.coerce(float(-(2**63)), "number", None, number_mode="int")


def test_the_civil_day_arithmetic_round_trips(mutable_source):
    """The published algorithm compensates for C's truncating division; Python floors,
    so the compensation double-counted and shifted year 0 by a day."""
    for year in (0, 1, 4, 100, 400, 1969, 1970, 2024, 9999):
        for month, day in ((1, 1), (2, 28), (3, 1), (12, 31)):
            days = rails2zb._days_from_civil(year, month, day)
            assert rails2zb._civil_from_days(days) == (year, month, day)
    assert rails2zb._days_from_civil(1970, 1, 1) == 0


@pytest.mark.parametrize(
    "stored",
    [
        "2024-01-15 09:00:00+30:00",
        "2024-01-15 09:00:00+05:99",
        "2024-01-15 09:00:00-24:00",
        # Exactly at the minute boundary: an off-by-one here would convert `+05:60`
        # as `+06:00` and move the row silently.
        "2024-01-15 09:00:00+23:60",
    ],
)
def test_an_impossible_utc_offset_is_refused(stored):
    """Silently converting a typo'd offset MOVES the row — the one thing this must
    never do. `+30:00` was refused by `fromisoformat` before the component rewrite;
    `+05:99` was never refused by anything."""
    with pytest.raises(rails2zb.RailsError, match="impossible UTC offset"):
        rails2zb.to_rfc3339(stored)


def test_the_largest_legal_offset_still_converts():
    """The accept side of the same gate."""
    assert rails2zb.to_rfc3339("2024-01-15 09:00:00+23:59") == "2024-01-14T09:01:00Z"


def test_a_fraction_without_seconds_is_refused():
    """`09:30.5` is fractional MINUTES in ISO 8601 and the engine refuses the shape.

    Emitting it as `.5` seconds would invent a meaning the source never had.
    """
    with pytest.raises(rails2zb.RailsError, match="needs a seconds field"):
        rails2zb.to_rfc3339("2024-01-15 09:30.5")


def test_a_float_foreign_key_is_refused(mutable_source):
    """SQLite renders a REAL one way and Python another, so the orphan check and the
    emitted value would disagree about the same row."""
    src, decisions = _decide(mutable_source)
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    connection = _db(mutable_source)
    row = dict(connection.execute("SELECT * FROM posts LIMIT 1").fetchone())
    connection.close()
    with pytest.raises(rails2zb.RailsError, match="cannot be a relation id"):
        rails2zb.build_record(entry, {**row, "club_id": 1.0})


def test_text_that_is_not_utf8_is_refused_rather_than_traced(mutable_source, workspace):
    """Latin-1 bytes are ordinary in an application old enough to be worth migrating.

    The driver raised mid-iteration and `main` handles only RailsError, so the operator
    got a bare traceback instead of a refusal naming the table.
    """
    connection = _db(mutable_source)
    connection.execute("UPDATE clubs SET name = CAST(X'636166E9' AS TEXT) WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="not valid UTF-8"):
        rails2zb.extract(src, decisions, workspace / "bundle")


# ---------------------------------------------------------------------------
# A refusal an operator can act on
# ---------------------------------------------------------------------------


def _first_row_value(source, table, column, value):
    connection = _db(source)
    connection.execute(f'UPDATE "{table}" SET "{column}" = ? WHERE id = 1', (value,))
    connection.commit()
    connection.close()


@pytest.mark.parametrize(
    ("table", "column", "value", "fragment"),
    [
        ("clubs", "posts_count", "banana", "not a number"),
        ("comments", "created_at", "2024-02-30 10:00:00", "impossible date"),
        ("comments", "body", b"\x00\x01\x02binary", "binary value"),
        # The guide promises both of these are refused *and located*; neither was
        # exercised, so the promise rested on reading the code.
        ("clubs", "posts_count", float("inf"), "JSON cannot represent"),
        ("clubs", "posts_count", 1e19, "outside the range"),
    ],
)
def test_a_value_refusal_names_where_to_look(
    mutable_source, workspace, table, column, value, fragment
):
    """A message with no location is unactionable on a real source.

    The binary one named not even the value, so there was nothing to search the
    database for — and every sibling refusal in the converter already names its table,
    column and row.
    """
    _first_row_value(mutable_source, table, column, value)
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError) as caught:
        rails2zb.extract(src, decisions, workspace / "bundle")
    message = str(caught.value)
    assert fragment in message
    assert f"{table}.{column}" in message, f"no location in: {message}"
    assert "row id '1'" in message, f"no row in: {message}"


def test_a_binary_refusal_shows_the_value(mutable_source, workspace):
    _first_row_value(mutable_source, "comments", "body", b"\xde\xad\xbe\xef")
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match=r"\\xde\\xad\\xbe\\xef"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_a_utf8_refusal_names_the_table(mutable_source, workspace):
    connection = _db(mutable_source)
    connection.execute("UPDATE clubs SET name = CAST(X'636166E9' AS TEXT) WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="clubs:.*not valid UTF-8"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_an_attachment_name_the_target_rejects_is_a_finding(mutable_source):
    """Ruby permits `has_one_attached :_draft`; the target requires a leading letter.

    Columns and tables were both held to this gate and attachments were not, so the
    field reached `schema apply` and failed there — after earlier collections had
    already been created, and `--dry-run` had passed.
    """
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["attachments"].append(
        {"source": "observed", "name": "_draft", "macro": "has_one_attached"}
    )
    write_inventory(mutable_source, "models", models)
    src = rails2zb.load_source(mutable_source)
    finding = next(
        f
        for f in rails2zb.build_findings(src)
        if f.id == finding_id("attachment", "posts", "_draft", "identifier")
    )
    assert finding.choices == ("rename", "omit")

    src, decisions = _decide(mutable_source, **{finding.id: ("omit", None)})
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert "_draft" not in {f["name"] for f in posts.fields}


def test_a_nullable_columns_refusal_is_located_too(mutable_source, workspace):
    """The scan pass only reads columns that could be `required`.

    A nullable column's bad value is seen for the first time in `build_record`, so that
    is the only place its location can be attached.
    """
    _first_row_value(mutable_source, "posts", "published_at", "2024-02-30 10:00:00")
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError) as caught:
        rails2zb.extract(src, decisions, workspace / "bundle")
    message = str(caught.value)
    assert "posts.published_at" in message, f"no location in: {message}"
    assert "row id '1'" in message


def _attachment(source, name, model="Post"):
    models = read_inventory(source, "models")
    entry = next(m for m in models["models"] if m["name"] == model)
    entry.setdefault("attachments", []).append(
        {"source": "observed", "name": name, "macro": "has_one_attached"}
    )
    write_inventory(source, "models", models)


def test_an_attachment_rename_is_actually_honoured(mutable_source, workspace):
    """The finding offers `rename`, so something has to consume it.

    Reconcile accepted the artifact, validated it, and then discarded it: the schema
    still named `_draft` and `schema apply` failed after earlier collections existed —
    the very failure this finding was added to prevent, now behind an explicit promise.
    """
    _attachment(mutable_source, "_draft")
    fid = finding_id("attachment", "posts", "_draft", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "draft")})
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    document = json.loads((bundle / "schema.json").read_text())
    posts = next(c for c in document["collections"] if c["name"] == "posts")
    files = {f["name"] for f in posts["fields"] if f["type"] == "file"}
    assert "draft" in files and "_draft" not in files


def test_a_renamed_attachment_still_finds_its_blobs(mutable_source, workspace):
    """Active Storage recorded the SOURCE name; only the emitted field is renamed."""
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    next(a for a in post["attachments"] if a["name"] == "cover")["name"] = "_cover"
    write_inventory(mutable_source, "models", models)
    connection = _db(mutable_source)
    connection.execute("UPDATE active_storage_attachments SET name = '_cover'")
    connection.commit()
    connection.close()

    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("attachment", "posts", "_cover", "identifier"): (
                "rename",
                "cover",
            )
        },
    )
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    rows = [
        json.loads(line)
        for line in (bundle / "data" / "posts.ndjson").read_text().splitlines()
    ]
    named = [row.get("cover") for row in rows if row.get("cover")]
    assert named, "the renamed field lost its file"
    assert all(isinstance(value, str) for value in named), (
        "`has_one_attached` must stay single-valued after a rename; looking the macro "
        "up by the NEW name misses it and emits a list"
    )
    manifest = json.loads((bundle / "files/manifest.json").read_text())
    assert manifest["files"], "the blob must still be planned"
    assert manifest["files"][0]["field"] == "_cover", (
        "the file manifest keys on what Active Storage recorded"
    )


def test_an_attachment_cannot_be_renamed_onto_an_engine_field(mutable_source):
    """A file field is never the auth collection's identity, however it is named."""
    _attachment(mutable_source, "_photo", model="User")
    fid = finding_id("attachment", "users", "_photo", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "email")})
    with pytest.raises(rails2zb.RailsError, match="not a usable ZigBase field name"):
        rails2zb.map_tables(src, decisions)


def test_a_relation_id_refusal_names_the_row(mutable_source):
    src, decisions = _decide(mutable_source)
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    connection = _db(mutable_source)
    row = dict(connection.execute("SELECT * FROM posts WHERE id = 1").fetchone())
    connection.close()
    with pytest.raises(rails2zb.RailsError, match=r"posts\.club_id, row id '1'"):
        rails2zb.build_record(entry, {**row, "club_id": 1.0})


def test_a_blob_filename_that_is_not_utf8_names_where_it_came_from(
    mutable_source, workspace
):
    """`build_file_plan` reads Active Storage before any table's rows are read, so its
    own drain has to name the source too."""
    connection = _db(mutable_source)
    connection.execute(
        "UPDATE active_storage_blobs SET filename = CAST(X'636166E9' AS TEXT)"
    )
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(
        rails2zb.RailsError, match="active_storage_attachments:.*not valid UTF-8"
    ):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_an_unsafe_attachment_name_never_reaches_the_stored_path(mutable_source):
    """`has_one_attached :"my photo"` is legal Ruby and arrives here as recorded.

    Only the collision fallback puts the field name into the stored path — so the case
    this function exists for was the one producing a path no client can fetch.
    """
    taken: set = set()
    first = rails2zb._unique_target_name(
        taken, "posts", "1", "my photo", "keyaaa", "cover.png"
    )
    taken.add(("posts", "1", first))
    second = rails2zb._unique_target_name(
        taken, "posts", "1", "my photo", "keybbb", "cover.png"
    )
    assert set(second) <= rails2zb.SERVABLE_CHARACTERS, (
        f"unservable stored name {second!r}"
    )
    assert second != first


def _text_primary_key(source, table="notifications"):
    """Rebuild a table with `create_table id: :string` — a non-alias TEXT primary key."""
    connection = _db(source)
    columns = [
        (row[1], row[2]) for row in connection.execute(f'PRAGMA table_info("{table}")')
    ]
    body = ", ".join(
        f'"{name}" {"varchar PRIMARY KEY" if name == "id" else kind}'
        for name, kind in columns
    )
    connection.execute(f'ALTER TABLE "{table}" RENAME TO "{table}_old"')
    connection.execute(f'CREATE TABLE "{table}" ({body})')
    connection.execute(f'INSERT INTO "{table}" SELECT * FROM "{table}_old"')
    connection.execute(f'DROP TABLE "{table}_old"')
    connection.execute(
        f"UPDATE \"{table}\" SET id = CAST(X'636166E9' AS TEXT) "
        f'WHERE id = (SELECT MIN(id) FROM "{table}")'
    )
    connection.commit()
    connection.close()
    # Nothing required, so the relax scan never reads this table's text first.
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    for column in entry["columns"]:
        column["null"] = True
    write_inventory(source, "schema", schema)


def test_a_non_utf8_text_primary_key_refusal_names_its_table(mutable_source, workspace):
    """`create_table id: :string` is the ordinary UUID-on-SQLite shape, and the
    converter supports TEXT ids — so this drain really can be the first to read one."""
    _text_primary_key(mutable_source)
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="notifications:.*not valid UTF-8"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_an_attachment_colliding_with_a_column_is_decidable(mutable_source, workspace):
    """A legacy `cover` column beside `has_one_attached :cover`.

    Both names are valid and unreserved, so no other gate saw them — and extraction
    then refused naming a decision that did not exist. This is the ordinary shape after
    a Paperclip or CarrierWave migration that left the old column in place.
    """
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["columns"].append(
        {
            "source": "observed",
            "name": "cover",
            "sql_type": "varchar",
            "type": "string",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute("ALTER TABLE posts ADD COLUMN cover varchar")
    connection.commit()
    connection.close()

    fid = finding_id("attachment", "posts", "cover", "collision")
    src = rails2zb.load_source(mutable_source)
    finding = next(f for f in rails2zb.build_findings(src) if f.id == fid)
    assert finding.choices == ("rename", "omit")

    # `rename` moves the ATTACHMENT's field and leaves the column alone.
    src, decisions = _decide(mutable_source, **{fid: ("rename", "coverImage")})
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    names = {f["name"]: f["type"] for f in posts.fields}
    assert names.get("coverImage") == "file"
    assert names.get("cover") == "text"

    # `omit` drops only the attachment; the column keeps its name and its data.
    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    names = {f["name"]: f["type"] for f in posts.fields}
    assert names.get("cover") == "text"
    assert "file" not in names.values()


def test_a_collision_refusal_says_which_subject_is_which(mutable_source):
    """Printing the same qualified name twice told the operator nothing."""
    _add_column_both(mutable_source, "posts", "Cover")
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    value["decisions"] = [
        d
        for d in value["decisions"]
        if not d["id"].startswith("attachment.posts.cover")
    ]
    decisions = rails2zb.load_decisions_from_value(value)
    with pytest.raises(rails2zb.RailsError, match="attachment 'cover'") as caught:
        rails2zb.map_tables(src, decisions)
    assert "column 'Cover'" in str(caught.value)


def _add_column_both(source, table, name):
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    entry["columns"].append(
        {
            "source": "observed",
            "name": name,
            "sql_type": "varchar",
            "type": "string",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(source, "schema", schema)
    connection = _db(source)
    connection.execute(f'ALTER TABLE "{table}" ADD COLUMN "{name}" varchar')
    connection.commit()
    connection.close()


def test_the_snapshot_must_agree_with_the_inventory(mutable_source, workspace):
    """Every blob is sha256-pinned against exactly this drift; the row counts were
    collected and never consulted.

    Copying `*.sqlite3` without its `-wal` sidecar — SQLite has run in WAL mode by
    default since Rails 7 — opens a pre-checkpoint image that reads perfectly well and
    is simply older than the inventory.
    """
    connection = _db(mutable_source)
    connection.execute("DELETE FROM posts WHERE id = (SELECT MAX(id) FROM posts)")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="the inventory observed"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_a_collision_differing_only_in_case_still_raises_the_finding(mutable_source):
    """ZigBase compares field names case-insensitively, so `Cover` and `cover` collide.

    Detecting the collision case-sensitively left the refusal in place but removed the
    decision that resolves it — the dead end all over again.
    """
    _add_column_both(mutable_source, "posts", "Cover")
    src = rails2zb.load_source(mutable_source)
    assert finding_id("attachment", "posts", "cover", "collision") in {
        f.id for f in rails2zb.build_findings(src)
    }


def test_extra_rows_are_as_incoherent_as_missing_ones(mutable_source, workspace):
    """A snapshot taken AFTER the inventory is drift in the other direction, and just
    as fatal to the bundle's claim about what it contains."""
    connection = _db(mutable_source)
    connection.execute(
        "INSERT INTO posts (club_id, author_id, title, body, status, created_at, "
        "updated_at) SELECT club_id, author_id, title || ' (copy)', body, status, "
        "created_at, updated_at FROM posts LIMIT 1"
    )
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="the inventory observed"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_omitting_a_column_does_not_drop_an_attachment_sharing_its_name(
    mutable_source, workspace
):
    """A column-scoped decision names a COLUMN.

    Since a column and an attachment may share a name, letting a column omit reach into
    the attachment list would silently drop a field nobody decided about.
    """
    _add_column_both(mutable_source, "posts", "cover")
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == finding_id("attachment", "posts", "cover", "collision"):
            entry["choice"] = "rename"
            entry["artifact"] = "coverImage"
    # A column-scoped omit invented for this table, as a credential finding would give.
    value["decisions"].append(
        {
            "id": finding_id("column", "posts", "cover", "credential"),
            "choice": "omit",
            "rationale": "column dropped deliberately",
        }
    )
    decisions = rails2zb.load_decisions_from_value(value)
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    names = {f["name"]: f["type"] for f in posts.fields}
    assert names.get("coverImage") == "file", "the attachment must survive"
    assert "cover" not in names, "the column was the thing omitted"


def _two_findings_on_one_attachment(source):
    """`posts.email` as an attachment beside an `email` column raises BOTH the
    collision blocker and the reserved-name one."""
    _add_column_both(source, "posts", "email")
    models = read_inventory(source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["attachments"].append(
        {"source": "observed", "name": "email", "macro": "has_one_attached"}
    )
    write_inventory(source, "models", models)
    return (
        finding_id("attachment", "posts", "email", "collision"),
        finding_id("attachment", "posts", "email", "reserved"),
    )


@pytest.mark.parametrize(
    "replacement", ["my photo", "2fast", "photo-1", "photo.jpg", "photo!"]
)
def test_an_attachment_cannot_be_renamed_to_an_invalid_field_name(
    mutable_source, replacement
):
    """The reserved-name half was pinned; the identifier half was not.

    Table and column renames both refuse a replacement that is not a usable identifier.
    An attachment's did too, but nothing tested it — `claim` downstream checks reserved
    names and collisions and never the character set, so `my photo` would have reached
    schema.json and failed at `schema apply`, after earlier collections were created.
    """
    collision, _ = _two_findings_on_one_attachment(mutable_source)
    src, decisions = _decide(mutable_source, **{collision: ("rename", replacement)})
    with pytest.raises(rails2zb.RailsError, match="not a usable ZigBase field name"):
        rails2zb.map_tables(src, decisions)


def test_renaming_and_omitting_one_subject_is_refused(mutable_source):
    """Two blockers can land on one attachment, and each is decided separately.

    Honouring one and discarding the other left the outcome to whichever consumer ran
    last. Tables have been refused for exactly this since early on.
    """
    collision, reserved = _two_findings_on_one_attachment(mutable_source)
    src, decisions = _decide(
        mutable_source,
        **{collision: ("rename", "photoA"), reserved: ("omit", None)},
    )
    findings = rails2zb.build_findings(src)
    with pytest.raises(rails2zb.RailsError, match="omitted and also .rename."):
        rails2zb.reconcile(findings, decisions)


def test_two_different_renames_on_one_subject_are_refused(mutable_source):
    """Which one applied depended purely on the order of lines in the decisions file."""
    collision, reserved = _two_findings_on_one_attachment(mutable_source)
    src, decisions = _decide(
        mutable_source,
        **{collision: ("rename", "photoA"), reserved: ("rename", "photoB")},
    )
    findings = rails2zb.build_findings(src)
    with pytest.raises(rails2zb.RailsError, match="renamed to more than one name"):
        rails2zb.reconcile(findings, decisions)


def test_the_same_rename_twice_is_accepted(mutable_source):
    """Two findings agreeing on one replacement is not a contradiction."""
    collision, reserved = _two_findings_on_one_attachment(mutable_source)
    src, decisions = _decide(
        mutable_source,
        **{collision: ("rename", "photo"), reserved: ("rename", "photo")},
    )
    rails2zb.reconcile(rails2zb.build_findings(src), decisions)
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert posts.attachment_names["email"] == "photo"


def test_a_column_rename_is_not_demoted_by_a_same_named_attachment(mutable_source):
    """`_renamed_columns` sees only real columns now.

    It was still consulting the attachment list — a leftover from when both namespaces
    were shared — and refusing a scalar rename that `_field_names` would have accepted.
    """
    _add_column_both(mutable_source, "users", "user name")
    models = read_inventory(mutable_source, "models")
    user = next(m for m in models["models"] if m["name"] == "User")
    user.setdefault("attachments", []).append(
        {"source": "observed", "name": "user name", "macro": "has_one_attached"}
    )
    write_inventory(mutable_source, "models", models)
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("column", "users", "user name", "identifier"): (
                "rename",
                "username",
            ),
            finding_id("attachment", "users", "user name", "identifier"): (
                "omit",
                None,
            ),
            finding_id("attachment", "users", "user name", "collision"): (
                "omit",
                None,
            ),
        },
    )
    users = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "users")
    assert users.field_names["user name"] == "username"


def test_a_renamed_table_reconciles_its_rows_under_the_new_name(
    mutable_source, workspace
):
    """The count check keys by COLLECTION, so a renamed table still reconciles.

    Keying by source table instead would report every renamed table as holding no rows.
    """
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["name"] = "events-legacy"
    write_inventory(mutable_source, "schema", schema)
    counts = read_inventory(mutable_source, "counts")
    next(t for t in counts["tables"] if t["table"] == "events")["table"] = (
        "events-legacy"
    )
    write_inventory(mutable_source, "counts", counts)
    models = read_inventory(mutable_source, "models")
    for model in models["models"]:
        if model.get("table_name") == "events":
            model["table_name"] = "events-legacy"
        for association in model.get("associations") or []:
            if association.get("table_name") == "events":
                association["table_name"] = "events-legacy"
    write_inventory(mutable_source, "models", models)
    connection = _db(mutable_source)
    connection.execute('ALTER TABLE "events" RENAME TO "events-legacy"')
    connection.commit()
    connection.close()

    fid = finding_id("table", "events-legacy", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "gatherings")})
    rails2zb.extract(src, decisions, workspace / "bundle")  # must not refuse

    connection = _db(mutable_source)
    connection.execute(
        'DELETE FROM "events-legacy" WHERE id = (SELECT MIN(id) FROM "events-legacy")'
    )
    connection.commit()
    connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    connection.close()
    src, decisions = _decide(mutable_source, **{fid: ("rename", "gatherings")})
    with pytest.raises(rails2zb.RailsError, match="events-legacy holds"):
        rails2zb.extract(src, decisions, workspace / "bundle2")


def _credential_and_relation_column(source):
    """A `users.token` that is both credential material and a foreign key out of auth.

    Two findings on one column, each offering `keep` beside `omit`.
    """
    _add_column_both(source, "users", "token")
    schema = read_inventory(source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    users.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "token",
            "to_table": "clubs",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_users_token",
        }
    )
    write_inventory(source, "schema", schema)
    return (
        finding_id("column", "users", "token", "credential"),
        finding_id("column", "users", "token", "auth_relation"),
    )


def test_keeping_and_omitting_one_subject_is_refused(mutable_source):
    """`keep` is as much an assertion that the column migrates as `rename` is.

    Only rename was checked, so a reviewed `keep` beside an omit was recorded and then
    silently discarded — `_omitted_columns` matches any suffix, so the omit always won.
    """
    credential, relation = _credential_and_relation_column(mutable_source)
    src, decisions = _decide(
        mutable_source, **{credential: ("keep", None), relation: ("omit", None)}
    )
    with pytest.raises(rails2zb.RailsError, match="omitted and also 'keep'"):
        rails2zb.reconcile(rails2zb.build_findings(src), decisions)


def test_agreeing_keeps_on_one_subject_are_accepted(mutable_source):
    """Two findings agreeing that the column stays is not a contradiction."""
    credential, relation = _credential_and_relation_column(mutable_source)
    src, decisions = _decide(
        mutable_source, **{credential: ("keep", None), relation: ("keep", None)}
    )
    findings = rails2zb.build_findings(src)
    assert {credential, relation} <= {f.id for f in findings}, (
        "both findings must exist, or reconcile is being handed nothing to disagree over"
    )
    rails2zb.reconcile(findings, decisions)


def test_two_agreeing_renames_may_differ_only_in_whitespace(mutable_source):
    """Every consumer strips the artifact before use, so these genuinely agree."""
    collision, reserved = _two_findings_on_one_attachment(mutable_source)
    src, decisions = _decide(
        mutable_source,
        **{collision: ("rename", "photo "), reserved: ("rename", "photo")},
    )
    rails2zb.reconcile(rails2zb.build_findings(src), decisions)
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert posts.attachment_names["email"] == "photo"


def test_a_polymorphic_omit_contradicts_a_rename_of_the_column_it_drops(
    mutable_source,
):
    """The omit reaches the column from a different namespace, so grouping by subject
    cannot see it — and the rename went silently inert."""
    schema = read_inventory(mutable_source, "schema")
    flags = next(t for t in schema["tables"] if t["name"] == "flags")
    next(c for c in flags["columns"] if c["name"] == "flaggable_id")["name"] = (
        "token_epoch"
    )
    write_inventory(mutable_source, "schema", schema)
    models = read_inventory(mutable_source, "models")
    flag = next(m for m in models["models"] if m["name"] == "Flag")
    next(a for a in flag["associations"] if a.get("polymorphic"))["foreign_key"] = (
        "token_epoch"
    )
    write_inventory(mutable_source, "models", models)
    connection = _db(mutable_source)
    connection.execute("ALTER TABLE flags RENAME COLUMN flaggable_id TO token_epoch")
    connection.commit()
    connection.close()

    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    polymorphic = next(f for f in findings if f.code == "PolymorphicAssociation")
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == polymorphic.id:
            entry["choice"] = "omit"
        if entry["id"] == finding_id("column", "flags", "token_epoch", "reserved"):
            entry["choice"] = "rename"
            entry["artifact"] = "flaggableId"
    decisions = rails2zb.load_decisions_from_value(value)
    with pytest.raises(rails2zb.RailsError, match="another decision drops that column"):
        rails2zb.map_tables(src, decisions)


def test_routing_an_omitted_table_to_its_own_import_is_refused(mutable_source):
    """`separate-import` asserts the table IS imported; the omit drops it."""
    _nullable_timestamps(mutable_source, "events")
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["primary_key"] = "uuid"
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("table", "events", "primary_key"): ("omit", None),
            finding_id("table", "events", "nullable_timestamps"): (
                "separate-import",
                None,
            ),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="routed to its own import and also"):
        rails2zb.map_tables(src, decisions)


def _omit_column_default(source, table, column):
    """Give a column a database default, so it raises a finding offering `omit`."""
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    next(c for c in entry["columns"] if c["name"] == column)["default"] = "0"
    write_inventory(source, "schema", schema)
    return finding_id("column", table, column, "default")


def test_dropping_a_target_table_and_the_referring_column_is_expressible(
    mutable_source,
):
    """The wedge: a consistent schema that the tool refused, with no way out.

    There is no decision that drops an FK-derived relation, so "omit the target table
    and the referring column" was inexpressible — the operator's only exits were to keep
    the table or omit the referrer wholesale. `relations` kept the dropped column, and
    the dangling-name check believed it.
    """
    fid = _omit_column_default(mutable_source, "comments", "post_id")
    _nullable_timestamps(mutable_source, "posts")
    src, decisions = _decide(
        mutable_source,
        **{
            fid: ("omit", None),
            finding_id("table", "posts", "nullable_timestamps"): ("omit", None),
        },
    )
    mapped = rails2zb.map_tables(src, decisions)  # must not refuse
    comments = next(m for m in mapped if m.table == "comments")
    assert "post" not in {f["name"] for f in comments.fields}
    assert "post_id" not in comments.relations, (
        "a dropped column is not a relation; three consumers read this field"
    )


def test_orphan_values_in_a_dropped_column_do_not_refuse(mutable_source, workspace):
    """`build_record` iterates fields, so a dropped column's value never travels."""
    fid = _omit_column_default(mutable_source, "comments", "post_id")
    connection = _db(mutable_source)
    connection.execute("PRAGMA foreign_keys = OFF")
    connection.execute("UPDATE comments SET post_id = 999999 WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)  # must not refuse
    rows = [
        json.loads(line)
        for line in (bundle / "data" / "comments.ndjson").read_text().splitlines()
    ]
    assert rows and all("post" not in row for row in rows)


def test_promoting_a_relation_and_omitting_its_column_is_refused(mutable_source):
    """`relation` arrives from the association namespace and reaches the same column."""
    schema = read_inventory(mutable_source, "schema")
    memberships = next(t for t in schema["tables"] if t["name"] == "memberships")
    memberships["foreign_keys"] = [
        f for f in memberships["foreign_keys"] if f["column"] != "user_id"
    ]
    write_inventory(mutable_source, "schema", schema)
    fid = _omit_column_default(mutable_source, "memberships", "user_id")
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    association = next(
        f
        for f in findings
        if f.code == "AssociationWithoutForeignKey" and "user" in f.id
    )
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == association.id:
            entry["choice"] = "relation"
        if entry["id"] == fid:
            entry["choice"] = "omit"
    decisions = rails2zb.load_decisions_from_value(value)
    with pytest.raises(rails2zb.RailsError, match="promoted to a relation, and also"):
        rails2zb.map_tables(src, decisions)


def test_cascading_a_relation_whose_action_was_dropped_is_refused(mutable_source):
    """Two recorded decisions about one relation's delete behaviour."""
    schema = read_inventory(mutable_source, "schema")
    comments = next(t for t in schema["tables"] if t["name"] == "comments")
    next(f for f in comments["foreign_keys"] if f["column"] == "post_id")[
        "on_delete"
    ] = "nullify"
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("fk", "comments", "post_id", "action"): ("omit", None),
            finding_id("model", "Post", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="not one of the relations it covers"):
        rails2zb.map_tables(src, decisions)


def test_cascading_a_relation_whose_column_was_dropped_is_refused(mutable_source):
    """The same contradiction, reached by dropping the column rather than the action."""
    fid = _omit_column_default(mutable_source, "comments", "post_id")
    src, decisions = _decide(
        mutable_source,
        **{
            fid: ("omit", None),
            finding_id("model", "Post", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="not one of the relations it covers"):
        rails2zb.map_tables(src, decisions)


def test_cascading_a_relation_dropped_for_a_bad_target_is_refused(mutable_source):
    """And by dropping the relation itself, when its key points at a non-`id` column."""
    schema = read_inventory(mutable_source, "schema")
    comments = next(t for t in schema["tables"] if t["name"] == "comments")
    next(f for f in comments["foreign_keys"] if f["column"] == "post_id")[
        "primary_key"
    ] = "slug"
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("fk", "comments", "post_id", "target_key"): ("omit", None),
            finding_id("model", "Post", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="not one of the relations it covers"):
        rails2zb.map_tables(src, decisions)


def _encrypt(source, model, attribute):
    models = read_inventory(source, "models")
    entry = next(m for m in models["models"] if m["name"] == model)
    entry.setdefault("encrypted_attributes", []).append(
        {"source": "observed", "attribute": attribute}
    )
    write_inventory(source, "models", models)


def test_an_encrypted_foreign_key_does_not_wedge_the_migration(
    mutable_source, workspace
):
    """The encrypted finding offers rekey/retire, and neither drops the relation.

    So a phantom relation on an encrypted foreign key was unresolvable by any decision:
    the orphan-value check, the dangling-name check and the manifest ordering all
    believed in a field that is never emitted.
    """
    _encrypt(mutable_source, "Comment", "post_id")
    src, decisions = _decide(mutable_source)
    assert any(
        f.code == "EncryptedAttributeCannotMigrate" and "post_id" in f.id
        for f in rails2zb.build_findings(src)
    ), "the setup must actually mark the foreign key encrypted"

    rails2zb.extract(src, decisions, workspace / "bundle")  # must not refuse

    # And the reason it does not wedge: no relation is emitted for the encrypted key,
    # so nothing downstream is left believing in a field that never arrives.
    comments = next(
        m for m in rails2zb.map_tables(src, decisions) if m.table == "comments"
    )
    # Both names, not just the relation: a regression that dropped the RELATION but let
    # the raw column through as a plain number would carry the ciphertext into the
    # bundle, and asserting only on `post` would have called that a pass.
    assert {"post", "post_id"} & {f["name"] for f in comments.fields} == set()


def test_an_encrypted_foreign_key_does_not_block_omitting_its_target(mutable_source):
    _encrypt(mutable_source, "Comment", "post_id")
    _nullable_timestamps(mutable_source, "posts")
    src, decisions = _decide(
        mutable_source,
        **{finding_id("table", "posts", "nullable_timestamps"): ("omit", None)},
    )
    mapped = rails2zb.map_tables(src, decisions)  # must not refuse
    assert "posts" not in {m.table for m in mapped}, (
        "the target was decided away; a vacuous pass here would prove nothing"
    )


def test_a_cascade_still_acting_on_another_relation_is_not_refused(mutable_source):
    """`dependent` is one model-level decision covering every child.

    Refusing per pair made "drop one child relation, cascade the rest" inexpressible.
    """
    fid = _omit_column_default(mutable_source, "memberships", "club_id")
    src, decisions = _decide(
        mutable_source,
        **{
            fid: ("omit", None),
            finding_id("model", "Club", "dependent"): ("cascade", None),
        },
    )
    mapped = rails2zb.map_tables(src, decisions)  # must not refuse
    posts = next(m for m in mapped if m.table == "posts")
    club = next(f for f in posts.fields if f["name"] == "club")
    assert club["options"]["cascadeDelete"] is True, (
        "the cascade still acts on the children that remain"
    )


def test_a_cascade_over_a_relation_with_no_database_key_is_not_refused(mutable_source):
    """The dependent finding's own text tells the operator a cascade cannot cover a
    polymorphic child; refusing that pair contradicted the finding."""
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    polymorphic = next(f for f in findings if f.code == "PolymorphicAssociation")
    value = decisions_for([f.to_dict() for f in findings])
    dependent = finding_id("model", "Post", "dependent")
    seen = set()
    for entry in value["decisions"]:
        if entry["id"] == polymorphic.id:
            entry["choice"] = "omit"
            seen.add(entry["id"])
        if entry["id"] == dependent:
            entry["choice"] = "cascade"
            seen.add(entry["id"])
    assert seen == {polymorphic.id, dependent}, (
        f"neither decision may be silently absent, or nothing is being tested: {seen}"
    )
    decisions = rails2zb.load_decisions_from_value(value)
    mapped = rails2zb.map_tables(src, decisions)  # must not refuse

    # The polymorphic child carries no cascade, and the ordinary one still does.
    flags = next(m for m in mapped if m.table == "flags")
    assert "flaggable_id" not in {f["name"] for f in flags.fields}
    comments = next(m for m in mapped if m.table == "comments")
    post = next(f for f in comments.fields if f["name"] == "post")
    assert post["options"]["cascadeDelete"] is True


def test_inert_decisions_on_a_wholly_omitted_table_are_not_refused(mutable_source):
    """`reconcile` FORCES a decision on every column finding of a table later omitted.

    Two contradictory-looking decisions about a column of a table that is going away
    entirely are inert and harmless — refusing there is noise the operator cannot act on.
    """
    # `flags.flaggable_id` is dropped by the polymorphic omit AND kept by its own
    # default decision — a real contradiction anywhere else, and inert here because the
    # whole table is going.
    keeping = _omit_column_default(mutable_source, "flags", "flaggable_id")
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "flags")["primary_key"] = "uuid"
    write_inventory(mutable_source, "schema", schema)
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    polymorphic = next(f for f in findings if f.code == "PolymorphicAssociation")
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == polymorphic.id:
            entry["choice"] = "omit"
        if entry["id"] == keeping:
            entry["choice"] = "accept-no-default"
        if entry["id"] == finding_id("table", "flags", "primary_key"):
            entry["choice"] = "omit"
    decisions = rails2zb.load_decisions_from_value(value)
    assert "flags" not in {
        m.table for m in rails2zb.map_tables(src, decisions)
    }  # must not refuse


def test_promoting_a_relation_on_an_omitted_table_is_not_refused(mutable_source):
    """The whole table is going; the promotion is inert."""
    schema = read_inventory(mutable_source, "schema")
    memberships = next(t for t in schema["tables"] if t["name"] == "memberships")
    memberships["foreign_keys"] = [
        f for f in memberships["foreign_keys"] if f["column"] != "user_id"
    ]
    memberships["primary_key"] = "uuid"
    write_inventory(mutable_source, "schema", schema)
    fid = _omit_column_default(mutable_source, "memberships", "user_id")
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    association = next(
        f
        for f in findings
        if f.code == "AssociationWithoutForeignKey" and "user" in f.id
    )
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == association.id:
            entry["choice"] = "relation"
        if entry["id"] == fid:
            entry["choice"] = "omit"
        if entry["id"] == finding_id("table", "memberships", "primary_key"):
            entry["choice"] = "omit"
    decisions = rails2zb.load_decisions_from_value(value)
    assert "memberships" not in {
        m.table for m in rails2zb.map_tables(src, decisions)
    }  # must not refuse


def test_promoting_an_encrypted_column_to_a_relation_is_refused(mutable_source):
    """Its value never travels, so the relation it asserts cannot exist."""
    schema = read_inventory(mutable_source, "schema")
    memberships = next(t for t in schema["tables"] if t["name"] == "memberships")
    memberships["foreign_keys"] = [
        f for f in memberships["foreign_keys"] if f["column"] != "user_id"
    ]
    write_inventory(mutable_source, "schema", schema)
    _encrypt(mutable_source, "Membership", "user_id")
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    association = next(
        f
        for f in findings
        if f.code == "AssociationWithoutForeignKey" and "user" in f.id
    )
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == association.id:
            entry["choice"] = "relation"
    decisions = rails2zb.load_decisions_from_value(value)
    with pytest.raises(rails2zb.RailsError, match="its value cannot travel"):
        rails2zb.map_tables(src, decisions)


def test_one_models_cascade_does_not_depend_on_another_models_choice(mutable_source):
    """Pooling every model's pairs made the refusal order- and context-dependent.

    With Club's cascade present, Post's identical (and entirely inert) decision sailed
    through, because Club's live pairs filled the same list.
    """
    schema = read_inventory(mutable_source, "schema")
    comments = next(t for t in schema["tables"] if t["name"] == "comments")
    next(f for f in comments["foreign_keys"] if f["column"] == "post_id")[
        "on_delete"
    ] = "nullify"
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("fk", "comments", "post_id", "action"): ("omit", None),
            finding_id("model", "Post", "dependent"): ("cascade", None),
            finding_id("model", "Club", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="Post is decided to cascade"):
        rails2zb.map_tables(src, decisions)


def test_a_cascade_whose_only_child_table_is_omitted_is_refused(mutable_source):
    """The omitted-table filter emptied the pool before the emptiness test ran, so
    "everything was filtered away" read as "nothing was decided"."""
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "comments")["primary_key"] = "uuid"
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("table", "comments", "primary_key"): ("omit", None),
            finding_id("model", "Post", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="not one of the relations it covers"):
        rails2zb.map_tables(src, decisions)


def test_cascade_is_not_offered_where_another_model_refuses_the_delete(mutable_source):
    """`_cascade_decisions` subtracts restrict-protected pairs, so the choice was
    offered, recorded, and silently did nothing."""
    models = read_inventory(mutable_source, "models")
    club = next(m for m in models["models"] if m["name"] == "Club")
    club["associations"].append(
        {
            "source": "observed",
            "name": "protected_comments",
            "macro": "has_many",
            "table_name": "comments",
            "foreign_key": "post_id",
            "dependent": "restrict_with_error",
            "polymorphic": False,
            "through": None,
            "class_name": "Comment",
        }
    )
    write_inventory(mutable_source, "models", models)
    src = rails2zb.load_source(mutable_source)
    finding = next(
        f
        for f in rails2zb.build_findings(src)
        if f.id == finding_id("model", "Post", "dependent")
    )
    assert "cascade" not in finding.choices
    assert "another model refuses the delete" in finding.message


def test_promoting_an_unmigratable_column_on_an_omitted_table_is_not_refused(
    mutable_source,
):
    """The exemption baked into `dropped_columns` never touched this check.

    An encrypted column on a doomed table was refused for a reason that no longer
    applies — while the same promotion of an ordinary column was tolerated.
    """
    schema = read_inventory(mutable_source, "schema")
    memberships = next(t for t in schema["tables"] if t["name"] == "memberships")
    memberships["foreign_keys"] = [
        f for f in memberships["foreign_keys"] if f["column"] != "user_id"
    ]
    memberships["primary_key"] = "uuid"
    write_inventory(mutable_source, "schema", schema)
    _encrypt(mutable_source, "Membership", "user_id")
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    association = next(
        f
        for f in findings
        if f.code == "AssociationWithoutForeignKey" and "user" in f.id
    )
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == association.id:
            entry["choice"] = "relation"
        if entry["id"] == finding_id("table", "memberships", "primary_key"):
            entry["choice"] = "omit"
    decisions = rails2zb.load_decisions_from_value(value)
    assert "memberships" not in {
        m.table for m in rails2zb.map_tables(src, decisions)
    }  # must not refuse


def test_a_foreign_key_on_the_primary_key_is_reported(mutable_source):
    """The shared-primary-key idiom is real, and this was the one relation drop with
    no operator-facing signal at all."""
    schema = read_inventory(mutable_source, "schema")
    notifications = next(t for t in schema["tables"] if t["name"] == "notifications")
    notifications.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "id",
            "to_table": "users",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_notifications_id",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    src = rails2zb.load_source(mutable_source)
    finding = next(
        f
        for f in rails2zb.build_findings(src)
        if f.id == finding_id("fk", "notifications", "id", "unmigratable")
    )
    assert finding.severity == "info", "there is nothing for an operator to choose"
    src, decisions = _decide(mutable_source)
    entry = next(
        m for m in rails2zb.map_tables(src, decisions) if m.table == "notifications"
    )
    assert "id" not in entry.relations


def test_a_restrict_protected_pair_does_not_count_as_honouring_a_cascade(
    mutable_source,
):
    """Another model refuses those deletes, so the cascade cannot act there.

    Counting it as honoured let a decision survive that does nothing at all — while the
    one relation it could have acted on had been dropped. The protected pair has to
    point at the deciding model's own table, or the target check would catch it first
    and this rule would never be exercised.
    """
    schema = read_inventory(mutable_source, "schema")
    notifications = next(t for t in schema["tables"] if t["name"] == "notifications")
    notifications["columns"].append(
        {
            "source": "observed",
            "name": "post_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": "0",
            "default_function": None,
        }
    )
    notifications.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "post_id",
            "to_table": "posts",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_notifications_post",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute("ALTER TABLE notifications ADD COLUMN post_id integer")
    connection.commit()
    connection.close()
    _association(
        mutable_source,
        "Post",
        name="alerts",
        table_name="notifications",
        foreign_key="post_id",
        dependent="destroy",
    )
    _association(
        mutable_source,
        "User",
        name="guarded_comments",
        table_name="comments",
        foreign_key="post_id",
        dependent="restrict_with_error",
    )
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("column", "notifications", "post_id", "default"): ("omit", None),
            finding_id("model", "Post", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="not one of the relations it covers"):
        rails2zb.map_tables(src, decisions)


@pytest.mark.parametrize("column", ["created_at", "updated_at"])
def test_an_empty_timestamp_on_a_declared_column_is_refused(
    mutable_source, workspace, column
):
    """Both directions, because only one of them used to be caught.

    An empty `updated_at` produced no value, and the mirror — written for the table
    that has no `updated_at` COLUMN at all — quietly filled it from `created`. The row
    had been updated; the bundle said it never was, and nothing in the report mentioned
    it, since both the finding and `timestampMirrored` are column-level.
    """
    connection = _db(mutable_source)
    connection.execute(f"UPDATE posts SET {column} = '' WHERE id = 1")
    connection.commit()
    connection.close()
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="--preserve-timestamps would fail"):
        rails2zb.extract(src, decisions, workspace / "bundle")


def test_a_table_without_an_updated_at_column_still_mirrors(mutable_source, workspace):
    """The legitimate case the mirror exists for must keep working.

    `notifications` records `created_at` and no `updated_at`, raises the
    `NoUpdatedAtColumn` finding, and is listed in `timestampMirrored` — mirroring there
    is documented, not silent.
    """
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    report = json.loads((bundle / "report.json").read_text())
    assert "notifications" in report["timestampMirrored"]
    line = json.loads(
        (bundle / "data" / "notifications.ndjson").read_text().splitlines()[0]
    )
    assert line["updated"] == line["created"]


def test_a_multi_file_field_keeps_the_order_the_source_uploaded_them(mutable_source):
    """Blob keys are random base36 tokens; attachment ids are the upload order.

    Ordering the plan by `b.key` made a `has_many_attached` gallery's array order
    arbitrary — deterministic, so no test caught it, but shuffled relative to how the
    application presents it. This is also the only coverage of the multi-file path:
    the fixture has a single attachment, so nothing exercised more than one.
    """
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["attachments"].append(
        {"source": "observed", "name": "gallery", "macro": "has_many_attached"}
    )
    write_inventory(mutable_source, "models", models)

    connection = _db(mutable_source)
    # Deliberately opposed: attachment 10 holds the key that sorts LAST, attachment 11
    # the key that sorts first. Key order and upload order disagree here, so the two
    # candidate orderings are distinguishable.
    for blob_id, key, attachment_id in (
        (10, "zzz-uploaded-first", 10),
        (11, "aaa-uploaded-second", 11),
    ):
        connection.execute(
            "INSERT INTO active_storage_blobs "
            "(id, key, filename, content_type, metadata, service_name, byte_size, "
            "checksum, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
            (
                blob_id,
                key,
                f"{key}.png",
                "image/png",
                "{}",
                "local",
                3,
                "x",
                "2024-01-15 09:00:00",
            ),
        )
        connection.execute(
            "INSERT INTO active_storage_attachments "
            "(id, name, record_type, record_id, blob_id, created_at) VALUES (?,?,?,?,?,?)",
            (attachment_id, "gallery", "Post", 1, blob_id, "2024-01-15 09:00:00"),
        )
        # Active Storage's on-disk layout: storage/<k0:2>/<k2:4>/<key>. Without the
        # bytes the converter refuses before it ever orders anything.
        blob = mutable_source / "storage" / key[0:2] / key[2:4] / key
        blob.parent.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(b"png")
    connection.commit()
    connection.close()

    src, decisions = _decide(mutable_source)
    mapped = rails2zb.map_tables(src, decisions)
    with rails2zb._connect(next((mutable_source / "db").glob("*.sqlite3"))) as conn:
        plan, _ = rails2zb.build_file_plan(src, conn, mapped)
    gallery = [i["filename"] for i in plan if i["field"] == "gallery"]
    assert gallery == ["zzz-uploaded-first.png", "aaa-uploaded-second.png"], (
        f"attachment-id order expected, got {gallery} — that is blob-key order"
    )


def _internal_fk(source, table, column, **fk_fields):
    """Give `table` a denormalized foreign key into one of Rails' own tables."""
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    entry["columns"].append(
        {
            "source": "observed",
            "name": column,
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    entry.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": column,
            "to_table": "active_storage_blobs",  # overridable via **fk_fields
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            **fk_fields,
        }
    )
    write_inventory(source, "schema", schema)


@pytest.mark.parametrize("empty", [None, ""])
def test_an_empty_foreign_key_target_is_read_as_id_everywhere(mutable_source, empty):
    """`""` and `None` both mean "the target's own id", in both readers.

    An inferred inventory is built by reading `db/schema.rb` rather than a booted app,
    so a blank here is reachable without anything being wrong. One reader treated `""`
    as a non-id target and stepped aside for a `ForeignKeyTargetsNonIdColumn` finding
    that the other reader never raised for it — leaving the relation emitted, the
    database cascade silently dropped, and no decision offered for either.
    """
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    club_fk = next(f for f in posts["foreign_keys"] if f["column"] == "club_id")
    club_fk["primary_key"] = empty
    club_fk["on_delete"] = "cascade"
    write_inventory(mutable_source, "schema", schema)
    _association(
        mutable_source,
        "User",
        name="guarded_posts",
        table_name="posts",
        foreign_key="club_id",
        dependent="restrict_with_error",
    )
    src = rails2zb.load_source(mutable_source)
    ids = {f.id for f in rails2zb.build_findings(src)}
    # Neither reader may treat it as a non-id target: no drop-it finding...
    assert "fk.posts.club_id.target_key" not in ids
    # ...and therefore the contradiction must still be surfaced.
    assert "fk.posts.club_id.cascade_vs_restrict" in ids


def test_a_cascade_into_a_rails_internal_table_raises_no_contradiction(mutable_source):
    """No relation is emitted for it, so `cascade` would have nothing to act on.

    The database really does declare ON DELETE CASCADE and a model really does declare
    `restrict_with_*`, so every other condition for the finding holds — but Rails owns
    the target table and it never becomes a collection. Offering the choice made all
    three answers emit byte-identical bundles.
    """
    _internal_fk(mutable_source, "posts", "cover_blob_id", on_delete="cascade")
    _association(
        mutable_source,
        "User",
        name="guarded_posts",
        table_name="posts",
        foreign_key="cover_blob_id",
        dependent="restrict_with_error",
    )
    src = rails2zb.load_source(mutable_source)
    assert ("posts", "cover_blob_id") in rails2zb._restrict_protected(src), (
        "the pair must really be restrict-protected, or this proves nothing"
    )
    ids = {f.id for f in rails2zb.build_findings(src)}
    assert "fk.posts.cover_blob_id.cascade_vs_restrict" not in ids
    assert "fk.posts.cover_blob_id.action" not in ids


def _belongs_to(source, model, **fields):
    models = read_inventory(source, "models")
    entry = next(m for m in models["models"] if m["name"] == model)
    entry["associations"].append(
        {
            "source": "observed",
            "macro": "belongs_to",
            "through": None,
            "polymorphic": False,
            "class_name": None,
            "dependent": None,
            **fields,
        }
    )
    write_inventory(source, "models", models)


def test_an_auth_relation_declared_by_a_belongs_to_into_a_rails_table_is_not_raised(
    mutable_source,
):
    """The realistic shape: the column carries BOTH a foreign key and a `belongs_to`.

    In real Rails the database key usually exists BECAUSE of
    `belongs_to :avatar_blob, foreign_key: true`, so filtering only the foreign-key half
    of this union left the finding firing through the association half for the ordinary
    case — the bare-foreign-key test could not see it.
    """
    _internal_fk(mutable_source, "users", "avatar_blob_id")
    _belongs_to(
        mutable_source,
        "User",
        name="avatar_blob",
        table_name="active_storage_blobs",
        foreign_key="avatar_blob_id",
    )
    src = rails2zb.load_source(mutable_source)
    ids = {f.id for f in rails2zb.build_findings(src)}
    assert "column.users.avatar_blob_id.auth_relation" not in ids
    # No assertion about `nofk` here: this column carries a real database key, so that
    # finding is skipped for that reason whether or not the internal-table filter
    # exists. The keyless case — where the filter is what decides — is
    # `test_a_belongs_to_into_a_rails_internal_table_is_not_offered_a_relation`.


@pytest.mark.parametrize(
    ("entry", "expected"),
    [
        ({}, {"id"}),
        ({"primary_key": "uuid"}, {"uuid"}),
        # The extractor's `rescue nil` path: unknown, which matches no column — and is
        # NOT the same as defaulting to `id`, which would silently claim one.
        ({"primary_key": None}, set()),
        # Rails 7.1 composite: `connection.primary_key` returns the whole array.
        ({"primary_key": ["region_id", "id"]}, {"region_id", "id"}),
    ],
)
def test_every_primary_key_shape_reads_as_a_set_of_names(entry, expected):
    assert rails2zb._primary_key_names(entry) == expected


def test_a_composite_primary_key_is_quarantined_rather_than_crashing(mutable_source):
    """Rails 7.1 composite keys reach the converter as a list, and a list is unhashable.

    Every site that put the raw value into a set died with a Python traceback, taking
    the whole findings phase down before `NonStandardPrimaryKey` — which is the right
    answer, since a ZigBase record is keyed by one `id` and there is nothing to map two
    to — could quarantine the table. A crash is loud, but it is not actionable, and
    this repository's standard is that a failure names what the operator must do.
    """
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["primary_key"] = ["club_id", "id"]
    write_inventory(mutable_source, "schema", schema)

    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    blocker = next(f for f in findings if f.id == "table.posts.primary_key")
    assert blocker.code == "NonStandardPrimaryKey"
    assert blocker.choices == ("omit",)
    # Named as a composite key, not printed as a Python list repr at the operator.
    assert "composite primary key (club_id, id)" in blocker.message
    assert "['club_id'" not in blocker.message

    # That `omit` actually drops the table is pinned by
    # `test_primary_key_omit_leaves_the_table_behind`, on a table nothing refers to;
    # omitting `posts` here would trip the dangling-relation refusal instead, which is
    # correct behavior and a different subject.


def test_renaming_a_column_with_an_internal_table_key_keeps_its_exemption(
    mutable_source,
):
    """The rename-time reader had to learn the same rule as the finding-time one.

    A column whose only key points into a Rails-owned table travels literal, so the
    auth exemption applies to it — the un-renamed column already gets that (see the
    reserved-name test). Counting the key as relation-bearing here refused the rename
    on a premise true of no relation that exists.
    """
    _internal_fk(mutable_source, "users", "avatar_blob_id")
    # A second key, to an ordinary table, as the positive control: without one this
    # would also pass if the function simply returned nothing.
    _internal_fk(mutable_source, "users", "home_club_id", to_table="clubs")
    src = rails2zb.load_source(mutable_source)

    relations = rails2zb._relation_columns(src, {}, "users")
    assert "home_club_id" in relations, "an ordinary key must still count"
    assert "avatar_blob_id" not in relations, (
        "a key into a table that never becomes a collection is not a relation column"
    )


def test_a_subclass_declared_relation_out_of_an_auth_collection_is_caught(
    mutable_source,
):
    """`model_for_table` answers with the STI base alone; findings iterate every model.

    A Devise-style `User`/`Admin` hierarchy is ordinary Rails. With the two disagreeing,
    `Admin`'s `belongs_to` was offered promotion to a relation, the promotion was
    honoured at emission, and the blocker that exists to catch a relation OUT of an auth
    collection — which no documented import order resolves — was never raised for it.
    """
    models = read_inventory(mutable_source, "models")
    base = next(m for m in models["models"] if m["name"] == "User")
    base["sti"] = {**base["sti"], "enabled": True, "subclasses": ["Admin"]}
    models["models"].append(
        {
            **{
                k: v
                for k, v in base.items()
                if k not in ("name", "sti", "associations")
            },
            "name": "Admin",
            "sti": {
                "base_class": "User",
                "enabled": True,
                "inheritance_column": "type",
                "is_base_class": False,
                "subclasses": [],
            },
            "associations": [
                {
                    "source": "observed",
                    "macro": "belongs_to",
                    "name": "club",
                    "table_name": "clubs",
                    "foreign_key": "club_id",
                    "through": None,
                    "polymorphic": False,
                    "class_name": None,
                    "dependent": None,
                }
            ],
        }
    )
    write_inventory(mutable_source, "models", models)
    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    users["columns"].append(
        {
            "source": "observed",
            "name": "club_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)

    src = rails2zb.load_source(mutable_source)
    assert src.model_for_table("users")["name"] == "User", (
        "the base must be what model_for_table answers, or this proves nothing"
    )
    ids = {f.id for f in rails2zb.build_findings(src)}
    assert "association.Admin.club.nofk" in ids, "the promotion is offered..."
    assert "column.users.club_id.auth_relation" in ids, (
        "...so the blocker that governs a relation out of an auth collection must be "
        "raised for the same column"
    )


def test_a_polymorphic_belongs_to_on_an_auth_table_raises_no_relation_blocker(
    mutable_source,
):
    """No relation can ever exist for it, so neither answer could act.

    `_association_findings` skips polymorphic associations because the `_type`/`_id`
    pair has its own finding and no promotion is offered. Raising the auth blocker
    anyway also made a legitimate pair of answers — omit the polymorphic pair, keep the
    column — read as a contradiction.
    """
    _belongs_to(
        mutable_source,
        "User",
        name="subject",
        table_name=None,
        foreign_key="subject_id",
        polymorphic=True,
    )
    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    for column in ("subject_id", "subject_type"):
        users["columns"].append(
            {
                "source": "observed",
                "name": column,
                "sql_type": "varchar" if column.endswith("_type") else "integer",
                "type": "string" if column.endswith("_type") else "integer",
                "null": True,
                "default": None,
                "default_function": None,
            }
        )
    write_inventory(mutable_source, "schema", schema)

    src = rails2zb.load_source(mutable_source)
    ids = {f.id for f in rails2zb.build_findings(src)}
    assert "association.User.subject.polymorphic" in ids, "its own finding governs it"
    assert "column.users.subject_id.auth_relation" not in ids


def test_an_auth_relation_is_not_raised_for_a_column_that_does_not_exist(
    mutable_source,
):
    """A `belongs_to` naming a column a later migration dropped.

    `_association_findings` requires the column to exist before offering promotion, so
    no relation could be emitted OR promoted — leaving a blocker whose `omit` drops
    nothing and whose `keep` keeps nothing.
    """
    _belongs_to(
        mutable_source,
        "User",
        name="ghost",
        table_name="clubs",
        foreign_key="ghost_id",
    )
    src = rails2zb.load_source(mutable_source)
    assert "ghost_id" not in {
        c["name"]
        for t in src.migratable_tables()
        if t["name"] == "users"
        for c in t["columns"]
    }, "the column must really be absent"
    assert "column.users.ghost_id.auth_relation" not in {
        f.id for f in rails2zb.build_findings(src)
    }


def test_an_internal_table_key_does_not_cost_an_auth_column_its_exemption(
    mutable_source,
):
    """The third site that decided "is this a relation", and the last to be fixed.

    `users.email` is exempt from the reserved-name blocker because it is the engine's
    own `email` field with the matching type. Counting a key into one of Rails' tables
    as relation-bearing made the column non-literal, which withdraws that exemption and
    raises a blocker demanding a rename of the collection's own identity column.
    """
    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    users.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "email",
            "to_table": "active_storage_blobs",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    src = rails2zb.load_source(mutable_source)
    assert "column.users.email.reserved" not in {
        f.id for f in rails2zb.build_findings(src)
    }


@pytest.mark.parametrize("shape", ["list", "legacy-string"])
def test_a_composite_database_key_is_reported_and_emits_no_relation(
    mutable_source, workspace, shape
):
    """It reached a dict key, a set, and finally a SQL identifier.

    The last of those quoted a column that does not exist, so a bundle that had already
    passed every check died on `sqlite3.OperationalError` — a raw driver traceback with
    no mention of composite keys. The `legacy-string` shape is what an older extractor
    produced by calling `.to_s` on the Array; it is refused too, so a stale exporter
    against a new converter cannot pass a column name that names nothing.
    """
    columns = ["region_id", "order_id"]
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    club_fk = next(f for f in posts["foreign_keys"] if f["column"] == "club_id")
    club_fk["column"] = columns if shape == "list" else str(columns)
    write_inventory(mutable_source, "schema", schema)

    src = rails2zb.load_source(mutable_source)
    assert not any(
        rails2zb._is_composite(fk.get("column"))
        for t in src.migratable_tables()
        for fk in (t.get("foreign_keys") or [])
    ), "no consumer below may ever meet a composite key"

    reported = [
        f for f in rails2zb.build_findings(src) if f.code == "CompositeKeyRelation"
    ]
    assert len(reported) == 1, "lifted, but reported — never silently dropped"
    assert reported[0].severity == "info" and reported[0].choices == ()

    # And the bundle builds. `belongs_to :club` survives the lift with its own scalar
    # foreign key, so it is offered promotion like any other keyless association —
    # declined here, because the point is that NOTHING rides the composite key.
    src, decisions = _decide(
        mutable_source, **{"association.Post.club.nofk": ("omit", None)}
    )
    rails2zb.extract(src, decisions, workspace / "bundle")
    mapped = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert "club" not in {f["name"] for f in mapped.fields}
    assert "club_id" in {f["name"] for f in mapped.fields}, (
        "the column still travels, as an ordinary number"
    )


def test_a_composite_association_key_is_reported_rather_than_skipped(mutable_source):
    """This one was silent: the graph simply flattened.

    `.to_s` on the Array produced a name matching no column, so the association failed
    the existence check and was skipped without a word — the exact silence
    `_association_findings` exists to prevent.
    """
    _belongs_to(
        mutable_source,
        "Post",
        name="line",
        table_name="clubs",
        foreign_key=["region_id", "order_id"],
    )
    src = rails2zb.load_source(mutable_source)
    assert not any(
        a["name"] == "line"
        for m in src.models["models"]
        for a in (m.get("associations") or [])
    ), "lifted out, so nothing downstream sees a list where a name belongs"
    reported = [
        f for f in rails2zb.build_findings(src) if f.code == "CompositeKeyRelation"
    ]
    assert [f.id for f in reported] == ["association.Post.line.composite"]
    assert "region_id, order_id" in reported[0].message


@pytest.mark.parametrize("decision", ["target_key", "untrusted"])
def test_a_relation_decided_away_stops_counting_as_a_relation_column(
    mutable_source, decision
):
    """`_relation_columns` reports what a relation IS, after the decisions.

    It read only the schema, so a column whose relation the operator had just dropped
    still counted — and a column counted there is non-literal, which withdraws the
    auth-mapped exemption and refuses a rename the same column would be allowed if the
    key had never been declared. Loud, but on a premise true of no relation that exists.
    """
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    club_fk = next(f for f in posts["foreign_keys"] if f["column"] == "club_id")
    if decision == "target_key":
        club_fk["primary_key"] = "slug"  # raises ForeignKeyTargetsNonIdColumn
    else:
        schema["foreign_keys_supported"] = (
            None  # raises ForeignKeyInspectionUnsupported
        )
    write_inventory(mutable_source, "schema", schema)

    src = rails2zb.load_source(mutable_source)
    fid = (
        finding_id("fk", "posts", "club_id", "target_key")
        if decision == "target_key"
        else "schema.foreign_keys.unsupported"
    )
    assert fid in {f.id for f in rails2zb.build_findings(src)}, "the setup must hold"

    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    assert "club_id" not in rails2zb._relation_columns(src, decisions, "posts"), (
        "the relation was decided away, so the column is literal now"
    )


def test_a_belongs_to_naming_a_class_that_no_longer_exists_offers_no_relation(
    mutable_source,
):
    """The extractor writes a null target when `r.klass` raises — dead-class cruft.

    `_declared_relations` drops a promotion that has no target, so `relation` was a
    choice recorded and honoured nowhere, and the catalogue's claim that it is consumed
    was untrue of this subset. On an auth table it also raised the auth blocker, whose
    `omit` would then have destroyed a perfectly good column of numbers.
    """
    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    users["columns"].append(
        {
            "source": "observed",
            "name": "legacy_owner_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    _belongs_to(
        mutable_source,
        "User",
        name="legacy_owner",
        table_name=None,
        foreign_key="legacy_owner_id",
    )
    src = rails2zb.load_source(mutable_source)
    ids = {f.id for f in rails2zb.build_findings(src)}
    assert "association.User.legacy_owner.nofk" not in ids
    assert "column.users.legacy_owner_id.auth_relation" not in ids


def test_a_key_into_a_rails_table_does_not_withhold_a_real_promotion(mutable_source):
    """The two sets that answer "is this already a relation" must agree.

    A column carrying a database key into `active_storage_blobs` AND a `belongs_to` to
    an ordinary table is model/schema drift — precisely what this tool exists to
    surface. The finding generator called it "already a relation" and offered nothing,
    while no relation is ever emitted for an internal-table key.
    """
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["columns"].append(
        {
            "source": "observed",
            "name": "owner_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    posts["foreign_keys"].append(
        {
            "source": "observed",
            "column": "owner_id",
            "to_table": "active_storage_blobs",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    _belongs_to(
        mutable_source,
        "Post",
        name="owner",
        table_name="users",
        foreign_key="owner_id",
    )
    src = rails2zb.load_source(mutable_source)
    assert "association.Post.owner.nofk" in {
        f.id for f in rails2zb.build_findings(src)
    }, "the promotion must be offered: no relation rides the internal-table key"


def test_two_models_promoting_one_column_to_different_targets_are_refused(
    mutable_source,
):
    """STI made this reachable: a base and a subclass each get their own finding.

    Assigning would let whichever decision the file lists last win. Every other
    incompatible pair in this converter is refused by name; silence here would be the
    exception.
    """
    models = read_inventory(mutable_source, "models")
    base = next(m for m in models["models"] if m["name"] == "Post")
    base["associations"].append(
        {
            "source": "observed",
            "macro": "belongs_to",
            "name": "owner",
            "table_name": "users",
            "foreign_key": "owner_id",
            "through": None,
            "polymorphic": False,
            "class_name": None,
            "dependent": None,
        }
    )
    models["models"].append(
        {
            **{k: v for k, v in base.items() if k not in ("name", "associations")},
            "name": "FeaturedPost",
            "associations": [
                {
                    "source": "observed",
                    "macro": "belongs_to",
                    "name": "owner",
                    "table_name": "clubs",
                    "foreign_key": "owner_id",
                    "through": None,
                    "polymorphic": False,
                    "class_name": None,
                    "dependent": None,
                }
            ],
        }
    )
    write_inventory(mutable_source, "models", models)
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["columns"].append(
        {
            "source": "observed",
            "name": "owner_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)

    src, decisions = _decide(
        mutable_source,
        **{
            "association.Post.owner.nofk": ("relation", None),
            "association.FeaturedPost.owner.nofk": ("relation", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="contradict each other"):
        rails2zb.map_tables(src, decisions)


def test_a_belongs_to_into_a_rails_internal_table_is_not_offered_a_relation(
    mutable_source,
):
    """`relation` here could never be honoured, so offering it is theater.

    Promoting one targets `active_storage_blobs`, which never becomes a collection, and
    `map_tables` then refuses with "omit the referring collections too, or keep the
    target" — neither of which the operator can do: nothing was omitted, and Rails owns
    the target. Without a database key the column is simply a number, which is right.
    """
    # A column with NO database foreign key: the finding only ever fires for those, so
    # reusing one that has a real key (`club_id`) would skip on the earlier check and
    # pass whether or not the internal-table filter exists.
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["columns"].append(
        {
            "source": "observed",
            "name": "cover_blob_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    _belongs_to(
        mutable_source,
        "Post",
        name="cover_blob",
        table_name="active_storage_blobs",
        foreign_key="cover_blob_id",
    )
    src = rails2zb.load_source(mutable_source)
    assert not any(
        fk.get("column") == "cover_blob_id"
        for t in src.migratable_tables()
        if t["name"] == "posts"
        for fk in (t.get("foreign_keys") or [])
    ), (
        "the column must carry no database key, or the finding is skipped for that reason"
    )
    assert "association.Post.cover_blob.nofk" not in {
        f.id for f in rails2zb.build_findings(src)
    }


def test_an_auth_relation_into_a_rails_internal_table_is_not_raised(mutable_source):
    """There is no import order to resolve and no links to re-establish.

    The finding told the operator to drop the relation or re-link it afterwards. Blobs
    never migrate as records, so neither applies — and the column travels perfectly well
    as a plain number, which is what dropping it would have thrown away.
    """
    _internal_fk(mutable_source, "users", "avatar_blob_id")
    src = rails2zb.load_source(mutable_source)
    assert "users" in rails2zb._auth_tables(src), "users must be the auth collection"
    ids = {f.id for f in rails2zb.build_findings(src)}
    assert "column.users.avatar_blob_id.auth_relation" not in ids

    decisions = rails2zb.load_decisions_from_value(
        decisions_for([f.to_dict() for f in rails2zb.build_findings(src)])
    )
    users = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "users")
    fields = {f["name"]: f for f in users.fields}
    assert fields["avatar_blob_id"]["type"] == "number", "the column still travels"


def _association(source, model, **fields):
    models = read_inventory(source, "models")
    entry = next(m for m in models["models"] if m["name"] == model)
    entry["associations"].append(
        {
            "source": "observed",
            "macro": "has_many",
            "through": None,
            "polymorphic": False,
            "class_name": None,
            **fields,
        }
    )
    write_inventory(source, "models", models)


def _finding(source, fid):
    src = rails2zb.load_source(source)
    return src, next(f for f in rails2zb.build_findings(src) if f.id == fid)


def test_a_through_dependent_is_not_this_models_cascade(mutable_source):
    """`has_many :through` delegates its foreign key to the SOURCE reflection.

    So it exports the intermediate model's own pair while its `dependent` fires when a
    different table's rows are deleted — reading the pair without the macro made it
    look like an ordinary cascade, and emitted one the source does not have.
    """
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["associations"] = [a for a in post["associations"] if a["name"] != "comments"]
    write_inventory(mutable_source, "models", models)
    _association(
        mutable_source,
        "User",
        name="commentary",
        through="posts",
        table_name="comments",
        foreign_key="post_id",
        dependent="destroy",
    )
    src, decisions = _decide(
        mutable_source, **{finding_id("model", "User", "dependent"): ("cascade", None)}
    )
    comments = next(
        m for m in rails2zb.map_tables(src, decisions) if m.table == "comments"
    )
    post_field = next(f for f in comments.fields if f["name"] == "post")
    assert post_field["options"]["cascadeDelete"] is False, (
        "deleting a post must not delete its comments; the source says nothing of "
        "the kind"
    )


def test_a_through_restrict_does_not_withhold_a_legitimate_cascade(mutable_source):
    """A user-level `restrict` guards USER deletion only.

    Landing its delegated pair in the protected set collapsed Post's own choices and
    told the operator, falsely, that another model refuses the delete.
    """
    _association(
        mutable_source,
        "User",
        name="commentary",
        through="posts",
        table_name="comments",
        foreign_key="post_id",
        dependent="restrict_with_exception",
    )
    _, finding = _finding(mutable_source, finding_id("model", "Post", "dependent"))
    assert "cascade" in finding.choices
    assert "another model refuses" not in finding.message


def test_a_belongs_to_dependent_is_not_offered_as_a_cascade(mutable_source):
    """Rails destroys the PARENT when the child goes — the opposite direction."""
    schema = read_inventory(mutable_source, "schema")
    comments = next(t for t in schema["tables"] if t["name"] == "comments")
    comments["columns"].append(
        {
            "source": "observed",
            "name": "parent_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    comments["foreign_keys"].append(
        {
            "source": "observed",
            "column": "parent_id",
            "to_table": "comments",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_comments_parent",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    _association(
        mutable_source,
        "Comment",
        name="parent",
        macro="belongs_to",
        table_name="comments",
        foreign_key="parent_id",
        dependent="destroy",
    )
    _, finding = _finding(mutable_source, finding_id("model", "Comment", "dependent"))
    assert "cascade" not in finding.choices
    assert "the other way" in finding.message


@pytest.mark.parametrize("dependent", ["destroy_async", "delete"])
def test_the_other_cascading_dependents_are_honoured(mutable_source, dependent):
    """`destroy_async` is Rails' recommendation for large associations and `delete` is
    the has_one spelling; both remove the children, and both were silently uncovered —
    absent from the honourable set AND from the caveat."""
    models = read_inventory(mutable_source, "models")
    user = next(m for m in models["models"] if m["name"] == "User")
    next(a for a in user["associations"] if a["name"] == "notifications")[
        "dependent"
    ] = dependent
    write_inventory(mutable_source, "models", models)
    src, decisions = _decide(
        mutable_source, **{finding_id("model", "User", "dependent"): ("cascade", None)}
    )
    notifications = next(
        m for m in rails2zb.map_tables(src, decisions) if m.table == "notifications"
    )
    user_field = next(f for f in notifications.fields if f["name"] == "user")
    assert user_field["options"]["cascadeDelete"] is True


def _self_referential_comment(source):
    schema = read_inventory(source, "schema")
    comments = next(t for t in schema["tables"] if t["name"] == "comments")
    comments["columns"].append(
        {
            "source": "observed",
            "name": "parent_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    comments["foreign_keys"].append(
        {
            "source": "observed",
            "column": "parent_id",
            "to_table": "comments",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_comments_parent",
        }
    )
    write_inventory(source, "schema", schema)
    connection = _db(source)
    connection.execute("ALTER TABLE comments ADD COLUMN parent_id integer")
    connection.commit()
    connection.close()


def test_a_belongs_to_dependent_never_becomes_a_cascade(mutable_source):
    """Even where the model has a real cascade to offer, the belongs_to pair is not it."""
    _self_referential_comment(mutable_source)
    _association(
        mutable_source,
        "Comment",
        name="parent",
        macro="belongs_to",
        table_name="comments",
        foreign_key="parent_id",
        dependent="destroy",
    )
    # A genuine child cascade on a DIFFERENT table, so `cascade` is offered at all --
    # anything on `parent_id` would be the very pair under test.
    schema = read_inventory(mutable_source, "schema")
    notifications = next(t for t in schema["tables"] if t["name"] == "notifications")
    notifications["columns"].append(
        {
            "source": "observed",
            "name": "comment_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    notifications.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "comment_id",
            "to_table": "comments",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_notifications_comment",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute("ALTER TABLE notifications ADD COLUMN comment_id integer")
    connection.commit()
    connection.close()
    _association(
        mutable_source,
        "Comment",
        name="alerts",
        table_name="notifications",
        foreign_key="comment_id",
        dependent="destroy",
    )
    src, decisions = _decide(
        mutable_source,
        **{finding_id("model", "Comment", "dependent"): ("cascade", None)},
    )
    comments = next(
        m for m in rails2zb.map_tables(src, decisions) if m.table == "comments"
    )
    parent = next(f for f in comments.fields if f["name"] == "parent")
    assert parent["options"]["cascadeDelete"] is False, (
        "Rails destroys the PARENT when the child goes; cascading here deletes the "
        "wrong rows"
    )


def test_a_through_pair_cannot_rescue_a_fully_inert_cascade(mutable_source):
    """The refusal must judge the model's own direct pairs.

    Counting a through association's delegated pair let a decision that acts on nothing
    look as though it still had work to do.
    """
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["associations"] = [
        a for a in post["associations"] if a["name"] not in ("comments", "flags")
    ]
    write_inventory(mutable_source, "models", models)
    # A through pair DIFFERENT from the direct one, with a real foreign key of its own —
    # otherwise it cannot be told apart from the pair it coincides with.
    _association(
        mutable_source,
        "Post",
        name="club_memberships",
        through="club",
        table_name="memberships",
        foreign_key="club_id",
        dependent="destroy",
    )
    _association(
        mutable_source,
        "Post",
        name="direct_comments",
        table_name="comments",
        foreign_key="post_id",
        dependent="destroy",
    )
    fid = _omit_column_default(mutable_source, "comments", "post_id")
    src, decisions = _decide(
        mutable_source,
        **{
            fid: ("omit", None),
            finding_id("model", "Post", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="not one of the relations it covers"):
        rails2zb.map_tables(src, decisions)


def test_the_caveat_says_a_through_association_fires_elsewhere(mutable_source):
    """ "No database foreign key" is simply untrue of a through dependent — its pair
    usually has one. Telling the operator that would misdescribe the semantics."""
    _association(
        mutable_source,
        "User",
        name="commentary",
        through="posts",
        table_name="comments",
        foreign_key="post_id",
        dependent="destroy",
    )
    _, finding = _finding(mutable_source, finding_id("model", "User", "dependent"))
    assert "commentary: it runs through another association" in finding.message
    assert "commentary: no database foreign key" not in finding.message


def test_a_shared_primary_key_cascade_is_not_offered(mutable_source):
    """Three layers disagreed about what counts as a relation.

    `add_foreign_key :flags, :comments, column: :id` is the shared-primary-key idiom.
    The finding saw a foreign key and offered `cascade`; the emission skipped the column
    because it is the primary key; the honoured check counted it anyway — so the
    decision was offered, accepted, and did nothing, in silence.
    """
    models = read_inventory(mutable_source, "models")
    comment = next(m for m in models["models"] if m["name"] == "Comment")
    comment["associations"] = [
        a for a in comment["associations"] if not a.get("dependent")
    ]
    write_inventory(mutable_source, "models", models)
    schema = read_inventory(mutable_source, "schema")
    flags = next(t for t in schema["tables"] if t["name"] == "flags")
    flags.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "id",
            "to_table": "comments",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_flags_id",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    _association(
        mutable_source,
        "Comment",
        name="shadow",
        macro="has_one",
        table_name="flags",
        foreign_key="id",
        dependent="destroy",
    )
    _, finding = _finding(mutable_source, finding_id("model", "Comment", "dependent"))
    assert "cascade" not in finding.choices
    assert "never becomes a relation" in finding.message


def test_a_cascade_does_not_reach_a_relation_into_another_table(
    mutable_source, workspace
):
    """`cascading` was a global set of bare (table, column) pairs.

    `has_many :sponsored_memberships, class_name: "Membership", foreign_key: :club_id`
    on User is legal Rails; its pair carries a foreign key to CLUBS, so a cascade
    decided on User flipped `cascadeDelete` on club deletions — which neither model's
    decision said.
    """
    _association(
        mutable_source,
        "User",
        name="sponsored_memberships",
        table_name="memberships",
        foreign_key="club_id",
        dependent="destroy",
    )
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("model", "User", "dependent"): ("cascade", None),
            finding_id("model", "Club", "dependent"): ("hook", None),
        },
    )
    memberships = next(
        m for m in rails2zb.map_tables(src, decisions) if m.table == "memberships"
    )
    club = next(f for f in memberships.fields if f["name"] == "club")
    assert club["options"]["cascadeDelete"] is False, (
        "the relation points at clubs; User's decision cannot govern it"
    )
    user = next(f for f in memberships.fields if f["name"] == "user")
    assert user["options"]["cascadeDelete"] is True, (
        "User's own child relation still cascades"
    )


def test_a_non_emitted_pair_does_not_count_as_honouring_a_cascade(mutable_source):
    """The honoured check must use the same predicate the emission does.

    A shared-primary-key pair is never emitted, so counting it let a cascade decision
    survive with nothing left to act on — the very thing the check exists to catch.
    """
    models = read_inventory(mutable_source, "models")
    comment = next(m for m in models["models"] if m["name"] == "Comment")
    comment["associations"] = [
        a for a in comment["associations"] if not a.get("dependent")
    ]
    write_inventory(mutable_source, "models", models)

    schema = read_inventory(mutable_source, "schema")
    flags = next(t for t in schema["tables"] if t["name"] == "flags")
    flags.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "id",
            "to_table": "comments",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_flags_id",
        }
    )
    notifications = next(t for t in schema["tables"] if t["name"] == "notifications")
    notifications["columns"].append(
        {
            "source": "observed",
            "name": "comment_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": "0",
            "default_function": None,
        }
    )
    notifications.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "comment_id",
            "to_table": "comments",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_notifications_comment",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute("ALTER TABLE notifications ADD COLUMN comment_id integer")
    connection.commit()
    connection.close()

    # One emitted child relation (so `cascade` is offered) and one that never is.
    _association(
        mutable_source,
        "Comment",
        name="shadow",
        macro="has_one",
        table_name="flags",
        foreign_key="id",
        dependent="destroy",
    )
    _association(
        mutable_source,
        "Comment",
        name="alerts",
        table_name="notifications",
        foreign_key="comment_id",
        dependent="destroy",
    )
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("column", "notifications", "comment_id", "default"): (
                "omit",
                None,
            ),
            finding_id("model", "Comment", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="not one of the relations it covers"):
        rails2zb.map_tables(src, decisions)


def test_a_restrict_protected_relation_is_not_cascaded_in_the_emitted_schema(
    mutable_source,
):
    """The refusal is not the only place this matters.

    Where a model has one protected child and one live one, `cascade` is rightly still
    offered — and the protected relation must not carry `cascadeDelete` into the bundle,
    because another model refuses those deletes.
    """
    schema = read_inventory(mutable_source, "schema")
    notifications = next(t for t in schema["tables"] if t["name"] == "notifications")
    notifications["columns"].append(
        {
            "source": "observed",
            "name": "post_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    notifications.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "post_id",
            "to_table": "posts",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_notifications_post",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute("ALTER TABLE notifications ADD COLUMN post_id integer")
    connection.commit()
    connection.close()
    _association(
        mutable_source,
        "Post",
        name="alerts",
        table_name="notifications",
        foreign_key="post_id",
        dependent="destroy",
    )
    _association(
        mutable_source,
        "User",
        name="guarded_comments",
        table_name="comments",
        foreign_key="post_id",
        dependent="restrict_with_error",
    )
    src, decisions = _decide(
        mutable_source, **{finding_id("model", "Post", "dependent"): ("cascade", None)}
    )
    mapped = rails2zb.map_tables(src, decisions)
    comments = next(m for m in mapped if m.table == "comments")
    post = next(f for f in comments.fields if f["name"] == "post")
    assert post["options"]["cascadeDelete"] is False, (
        "another model refuses these deletes; the cascade must not override it"
    )
    notifications = next(m for m in mapped if m.table == "notifications")
    alert = next(f for f in notifications.fields if f["name"] == "post")
    assert alert["options"]["cascadeDelete"] is True


def test_the_cascade_refusal_names_only_this_models_relations(mutable_source):
    """Pooling every model's pairs also mislabelled the message.

    An operator reading it would be told their decision covers relations belonging to a
    model they did not decide about.
    """
    schema = read_inventory(mutable_source, "schema")
    comments = next(t for t in schema["tables"] if t["name"] == "comments")
    next(f for f in comments["foreign_keys"] if f["column"] == "post_id")[
        "on_delete"
    ] = "nullify"
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("fk", "comments", "post_id", "action"): ("omit", None),
            finding_id("model", "Post", "dependent"): ("cascade", None),
            finding_id("model", "Club", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError) as caught:
        rails2zb.map_tables(src, decisions)
    message = str(caught.value)
    assert "comments.post_id" in message
    assert "memberships.club_id" not in message, (
        "that relation belongs to Club's decision, not Post's"
    )


def test_a_belongs_to_pair_cannot_rescue_a_fully_inert_cascade(mutable_source):
    """The refusal's own pair list has to exclude belongs_to, not merely the emission.

    A self-referential belongs_to points back at the deciding model's table, so the
    target check cannot catch it — only the macro can.
    """
    _self_referential_comment(mutable_source)
    schema = read_inventory(mutable_source, "schema")
    notifications = next(t for t in schema["tables"] if t["name"] == "notifications")
    notifications["columns"].append(
        {
            "source": "observed",
            "name": "comment_id",
            "sql_type": "integer",
            "type": "integer",
            "null": True,
            "default": "0",
            "default_function": None,
        }
    )
    notifications.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": "comment_id",
            "to_table": "comments",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": "fk_notifications_comment",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute("ALTER TABLE notifications ADD COLUMN comment_id integer")
    connection.commit()
    connection.close()
    _association(
        mutable_source,
        "Comment",
        name="parent",
        macro="belongs_to",
        table_name="comments",
        foreign_key="parent_id",
        dependent="destroy",
    )
    _association(
        mutable_source,
        "Comment",
        name="alerts",
        table_name="notifications",
        foreign_key="comment_id",
        dependent="destroy",
    )
    src, decisions = _decide(
        mutable_source,
        **{
            finding_id("column", "notifications", "comment_id", "default"): (
                "omit",
                None,
            ),
            finding_id("model", "Comment", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="not one of the relations it covers"):
        rails2zb.map_tables(src, decisions)


def _database_cascade_over_restrict(source):
    """The fixture already has `restrict_with_exception` on (clubs, owner_id)."""
    schema = read_inventory(source, "schema")
    clubs = next(t for t in schema["tables"] if t["name"] == "clubs")
    next(f for f in clubs["foreign_keys"] if f["column"] == "owner_id")["on_delete"] = (
        "cascade"
    )
    write_inventory(source, "schema", schema)
    return finding_id("fk", "clubs", "owner_id", "cascade_vs_restrict")


def test_a_database_cascade_cannot_silently_beat_a_restrict(mutable_source):
    """The source contradicts itself, and the target has only one layer.

    Delete through Active Record and Rails raises with the rows intact; delete through
    SQL and the database removes them. Mirroring the database discarded a protection the
    application enforces on every ordinary delete, with no finding and no decision.
    """
    fid = _database_cascade_over_restrict(mutable_source)
    src = rails2zb.load_source(mutable_source)
    finding = next(f for f in rails2zb.build_findings(src) if f.id == fid)
    assert finding.choices == ("cascade", "hook", "omit")

    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    clubs = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "clubs")
    owner = next(f for f in clubs.fields if f["name"] == "owner")
    assert owner["options"]["cascadeDelete"] is False, (
        "`omit` keeps the application's protection"
    )

    src, decisions = _decide(mutable_source, **{fid: ("cascade", None)})
    clubs = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "clubs")
    owner = next(f for f in clubs.fields if f["name"] == "owner")
    assert owner["options"]["cascadeDelete"] is True, (
        "`cascade` keeps what the database does"
    )


def test_an_uncontradicted_database_cascade_still_travels(mutable_source):
    """Only the contradiction is a decision; an ordinary ON DELETE CASCADE is not."""
    schema = read_inventory(mutable_source, "schema")
    comments = next(t for t in schema["tables"] if t["name"] == "comments")
    next(f for f in comments["foreign_keys"] if f["column"] == "post_id")[
        "on_delete"
    ] = "cascade"
    write_inventory(mutable_source, "schema", schema)
    src = rails2zb.load_source(mutable_source)
    assert not [
        f
        for f in rails2zb.build_findings(src)
        if f.code == "CascadeContradictsRestrict"
    ]
    src, decisions = _decide(mutable_source)
    comments = next(
        m for m in rails2zb.map_tables(src, decisions) if m.table == "comments"
    )
    post = next(f for f in comments.fields if f["name"] == "post")
    assert post["options"]["cascadeDelete"] is True


def test_a_cascade_under_untrusted_foreign_keys_is_refused(mutable_source):
    """`cascadeDelete` only ever rides a foreign-key-derived relation.

    With those declared untrustworthy, no relation carries one — and the finding that
    offers `cascade` reads the very arrays the blocker says cannot be trusted, so it
    cannot see this itself.
    """
    schema = read_inventory(mutable_source, "schema")
    schema.pop("foreign_keys_supported", None)
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(
        mutable_source,
        **{
            "schema.foreign_keys.unsupported": ("omit", None),
            finding_id("model", "Post", "dependent"): ("cascade", None),
        },
    )
    with pytest.raises(rails2zb.RailsError, match="decided untrustworthy"):
        rails2zb.map_tables(src, decisions)


def test_a_generated_attachment_association_is_not_declared_behaviour(source):
    """`has_one_attached :cover` generates `cover_attachment`.

    Reporting it told every model with an attachment that its deletion semantics do not
    migrate — when the file field carries that cleanup natively.
    """
    src = rails2zb.load_source(source)
    finding = next(
        f for f in rails2zb.build_findings(src) if f.id == "model.Post.dependent"
    )
    assert "cover_attachment" not in finding.message


def test_the_caveat_distinguishes_a_table_that_is_not_extracted(mutable_source):
    """ "No database foreign key" is a different fact from "that table is not here"."""
    _association(
        mutable_source,
        "Post",
        name="audits",
        table_name="audit_log",
        foreign_key="post_id",
        dependent="destroy",
    )
    _, finding = _finding(mutable_source, finding_id("model", "Post", "dependent"))
    assert "'audit_log' is not a table this migration extracts" in finding.message


@pytest.mark.parametrize("kind", ["encrypted", "digest"])
def test_a_relation_on_an_untravelled_column_is_not_cascadable(mutable_source, kind):
    """Both halves of the predicate's advertised set, not just the primary key."""
    schema = read_inventory(mutable_source, "schema")
    notifications = next(t for t in schema["tables"] if t["name"] == "notifications")
    column = "kind" if kind == "encrypted" else "password_digest"
    if kind == "digest":
        notifications["columns"].append(
            {
                "source": "observed",
                "name": column,
                "sql_type": "varchar",
                "type": "string",
                "null": True,
                "default": None,
                "default_function": None,
            }
        )
        auth = read_inventory(mutable_source, "auth")
        auth["has_secure_password"].append(
            {
                "source": "observed",
                "model": "Notification",
                "table_name": "notifications",
                "attributes": ["password"],
                "digest_columns": [column],
            }
        )
        write_inventory(mutable_source, "auth", auth)
    notifications.setdefault("foreign_keys", []).append(
        {
            "source": "observed",
            "column": column,
            "to_table": "posts",
            "primary_key": "id",
            "on_delete": None,
            "on_update": None,
            "name": f"fk_notifications_{column}",
        }
    )
    write_inventory(mutable_source, "schema", schema)
    if kind == "encrypted":
        _encrypt(mutable_source, "Notification", column)
    _association(
        mutable_source,
        "Post",
        name="alerts",
        table_name="notifications",
        foreign_key=column,
        dependent="destroy",
    )
    _, finding = _finding(mutable_source, finding_id("model", "Post", "dependent"))
    assert "never becomes a relation" in finding.message


def test_a_model_without_a_table_name_cannot_cascade_anywhere(mutable_source):
    """A falsy target must refuse, not skip the back-pointing requirement.

    The extractor has `rescue nil` paths for `table_name`, and letting one through
    reinstated the cross-table cascade the target check exists to stop.
    """
    models = read_inventory(mutable_source, "models")
    club = next(m for m in models["models"] if m["name"] == "Club")
    club["table_name"] = None
    club["associations"] = [
        {
            "source": "observed",
            "name": "stray_comments",
            "macro": "has_many",
            "through": None,
            "polymorphic": False,
            "class_name": "Comment",
            "table_name": "comments",
            "foreign_key": "post_id",
            "dependent": "destroy",
        }
    ]
    write_inventory(mutable_source, "models", models)
    src = rails2zb.load_source(mutable_source)
    finding = next(
        f for f in rails2zb.build_findings(src) if f.id == "model.Club.dependent"
    )
    assert "cascade" not in finding.choices


def test_omitting_the_contradiction_does_not_claim_to_protect(mutable_source):
    """`cascadeDelete: false` emits ON DELETE SET NULL, not a refusal.

    So `omit` drops BOTH source behaviours and substitutes a third — the parent deletes
    and the child is orphaned with a null. The finding used to promise it kept the
    application's protection, which nothing in the target can do; a hook can.
    """
    fid = _database_cascade_over_restrict(mutable_source)
    src = rails2zb.load_source(mutable_source)
    finding = next(f for f in rails2zb.build_findings(src) if f.id == fid)
    assert "hook" in finding.choices, "the only choice that can carry a refusal"
    assert "set to null" in finding.message
    assert "keep the protection" not in finding.message


def test_a_contradiction_hook_leaves_the_schema_at_the_default(mutable_source):
    """The hook lives outside the bundle, so `hook` and `omit` emit the same thing —
    which is why only `cascade` is catalogued as consuming."""
    fid = _database_cascade_over_restrict(mutable_source)
    src, decisions = _decide(mutable_source, **{fid: ("hook", None)})
    clubs = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "clubs")
    owner = next(f for f in clubs.fields if f["name"] == "owner")
    assert owner["options"]["cascadeDelete"] is False


@pytest.mark.parametrize(
    "sabotage",
    ["untrusted_foreign_keys", "non_id_target", "unmigratable_column"],
)
def test_the_contradiction_is_not_raised_where_no_answer_could_act(
    mutable_source, sabotage
):
    """A blocker whose every choice is a no-op is mandatory ceremony."""
    _database_cascade_over_restrict(mutable_source)
    schema = read_inventory(mutable_source, "schema")
    clubs = next(t for t in schema["tables"] if t["name"] == "clubs")
    fk = next(f for f in clubs["foreign_keys"] if f["column"] == "owner_id")
    if sabotage == "untrusted_foreign_keys":
        schema.pop("foreign_keys_supported", None)
    elif sabotage == "non_id_target":
        fk["primary_key"] = "slug"
    else:
        # Encrypt the SAME column, so the pair is still protected and it is the
        # unmigratable check that excludes it — moving the column instead simply made
        # the pair unprotected, which proves nothing.
        _encrypt(mutable_source, "Club", "owner_id")
    write_inventory(mutable_source, "schema", schema)
    src = rails2zb.load_source(mutable_source)
    assert not [
        f
        for f in rails2zb.build_findings(src)
        if f.code == "CascadeContradictsRestrict"
    ]


@pytest.mark.parametrize("blocker", ["action", "column"])
def test_keeping_a_database_cascade_that_cannot_ride_is_refused(
    mutable_source, blocker
):
    """Two accepted decisions saying opposite things about one ON DELETE, resolved by
    silent precedence — the shape every other refusal here exists to prevent."""
    fid = _database_cascade_over_restrict(mutable_source)
    overrides = {fid: ("cascade", None)}
    if blocker == "action":
        schema = read_inventory(mutable_source, "schema")
        clubs = next(t for t in schema["tables"] if t["name"] == "clubs")
        next(f for f in clubs["foreign_keys"] if f["column"] == "owner_id")[
            "on_update"
        ] = "cascade"
        write_inventory(mutable_source, "schema", schema)
        overrides[finding_id("fk", "clubs", "owner_id", "action")] = ("omit", None)
    else:
        overrides[_omit_column_default(mutable_source, "clubs", "owner_id")] = (
            "omit",
            None,
        )
    src, decisions = _decide(mutable_source, **overrides)
    with pytest.raises(rails2zb.RailsError, match="keep its database cascade"):
        rails2zb.map_tables(src, decisions)
