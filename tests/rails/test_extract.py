"""Extraction must preserve what the issue requires and drop what must never travel.

The properties under test are the ones a migration is judged on afterwards: ids,
timestamps, relations, enum meaning, files, credentials — plus the two things that must
NOT appear, namely rows hidden by a default scope going missing and ciphertext arriving.
"""

from __future__ import annotations

import hashlib
import json

import pytest

from .conftest import decisions_for, read_inventory, write_inventory
from tools.rails import rails2zb
from tools.rails._core import RailsError


@pytest.fixture(scope="module")
def bundle(source, tmp_path_factory):
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    decisions = rails2zb.load_decisions_from_value(decisions_for(findings))
    out = tmp_path_factory.mktemp("bundle")
    rails2zb.extract(src, decisions, out)
    return out


def ndjson(bundle, relative):
    return [
        json.loads(line)
        for line in (bundle / relative).read_text().splitlines()
        if line.strip()
    ]


def tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


# ---------------------------------------------------------------------------
# Determinism
# ---------------------------------------------------------------------------


def test_extraction_is_byte_identical_across_runs(source, tmp_path):
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    decisions = rails2zb.load_decisions_from_value(decisions_for(findings))
    first, second = tmp_path / "a", tmp_path / "b"
    rails2zb.extract(src, decisions, first)
    rails2zb.extract(src, decisions, second)
    assert tree_digest(first) == tree_digest(second)


def test_hashes_cover_every_output_but_themselves(bundle):
    recorded = json.loads((bundle / "hashes.json").read_text())["outputs"]
    listed = {entry["path"] for entry in recorded}
    on_disk = {
        p.relative_to(bundle).as_posix()
        for p in bundle.rglob("*")
        if p.is_file() and p.name != "hashes.json"
    }
    assert listed == on_disk
    for entry in recorded:
        actual = hashlib.sha256((bundle / entry["path"]).read_bytes()).hexdigest()
        assert actual == entry["sha256"], entry["path"]


# ---------------------------------------------------------------------------
# What must be preserved
# ---------------------------------------------------------------------------


def test_default_scope_hidden_rows_are_extracted(bundle):
    """The archived club is invisible through the model. Losing it is silent data loss."""
    clubs = ndjson(bundle, "data/clubs.ndjson")
    assert [c["id"] for c in clubs] == ["1", "2", "3"]
    archived = next(c for c in clubs if c["id"] == "3")
    assert archived["slug"] == "retired-readers"
    assert archived["archived_at"] == "2024-02-01T00:00:00Z"


def test_rails_integer_ids_are_preserved_verbatim(bundle):
    posts = ndjson(bundle, "data/posts.ndjson")
    assert [p["id"] for p in posts] == ["1", "2", "3", "4"]


def test_relations_reference_target_ids(bundle):
    posts = {p["id"]: p for p in ndjson(bundle, "data/posts.ndjson")}
    assert posts["1"]["club"] == "1"
    assert posts["1"]["author"] == "1"
    assert posts["4"]["club"] == "3", (
        "a relation into a default-scoped row must survive"
    )


def test_timestamps_are_preserved_as_rfc3339(bundle):
    clubs = {c["id"]: c for c in ndjson(bundle, "data/clubs.ndjson")}
    assert clubs["1"]["created"] == "2024-01-15T10:00:00Z"
    assert clubs["3"]["updated"] == "2024-02-01T00:00:00Z"


def test_integer_backed_enums_are_decoded_to_labels(bundle):
    """The ordinal is storage; the label is the meaning."""
    users = {u["id"]: u for u in ndjson(bundle, "auth/users.ndjson")}
    assert users["1"]["role"] == "admin"
    assert users["2"]["role"] == "member"
    assert users["3"]["role"] == "moderator"


def test_string_backed_enums_pass_through(bundle):
    posts = {p["id"]: p for p in ndjson(bundle, "data/posts.ndjson")}
    assert {posts[i]["status"] for i in posts} == {"published", "draft", "archived"}


def test_attachments_name_their_file(bundle):
    posts = {p["id"]: p for p in ndjson(bundle, "data/posts.ndjson")}
    assert posts["1"]["cover"] == "morning-pages-cover.png"
    assert posts["2"]["cover"] is None, "has_one_attached with nothing attached is null"


def test_missing_updated_at_mirrors_created(bundle):
    rows = ndjson(bundle, "data/notifications.ndjson")
    assert rows[0]["created"] == rows[0]["updated"]


# ---------------------------------------------------------------------------
# What must never travel
# ---------------------------------------------------------------------------


def test_ciphertext_never_appears_in_the_bundle(bundle):
    """Active Record ciphertext is bound to the source key and is meaningless here."""
    users = ndjson(bundle, "auth/users.ndjson")
    assert all("phone" not in user for user in users)
    blob = (bundle / "auth" / "users.ndjson").read_text()
    assert '"iv"' not in blob and '"at"' not in blob


def test_encrypted_columns_are_absent_from_the_schema(bundle):
    document = json.loads((bundle / "schema.json").read_text())
    users = next(c for c in document["collections"] if c["name"] == "users")
    assert "phone" not in {f["name"] for f in users["fields"]}


def test_credentials_are_bcrypt_and_isolated_from_the_manifest(bundle):
    users = ndjson(bundle, "auth/users.ndjson")
    assert len(users) == 4
    for user in users:
        assert rails2zb.BCRYPT.fullmatch(user["passwordHash"])
        assert "password" not in user, "a row with both is refused by the importer"

    manifest = json.loads((bundle / "manifest.json").read_text())
    named = {entry["collection"] for entry in manifest["collections"]}
    assert "users" not in named, (
        "--legacy-hashes applies to every manifest entry, so an auth import "
        "must be its own run"
    )


def test_manifest_paths_resolve_against_the_manifest_directory(bundle):
    manifest = json.loads((bundle / "manifest.json").read_text())
    for entry in manifest["collections"]:
        assert not entry["file"].startswith("..")
        assert (bundle / entry["file"]).is_file()


# ---------------------------------------------------------------------------
# Schema document
# ---------------------------------------------------------------------------


def test_rules_default_to_locked(bundle):
    document = json.loads((bundle / "schema.json").read_text())
    for collection in document["collections"]:
        assert collection["listRule"] is None
        assert collection["createRule"] is None


def test_a_public_decision_emits_the_exact_sentinel(source, tmp_path):
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    value = decisions_for(findings, **{"table.clubs.rules": "public"})
    decisions = rails2zb.load_decisions_from_value(value)
    out = tmp_path / "bundle"
    report = rails2zb.extract(src, decisions, out)

    document = json.loads((out / "schema.json").read_text())
    clubs = next(c for c in document["collections"] if c["name"] == "clubs")
    assert clubs["listRule"] == "@public"
    assert report["publicRules"] == ["clubs"]


def test_relation_fields_target_the_right_collection(bundle):
    document = json.loads((bundle / "schema.json").read_text())
    posts = next(c for c in document["collections"] if c["name"] == "posts")
    club = next(f for f in posts["fields"] if f["name"] == "club")
    assert club["type"] == "relation"
    assert club["options"]["targetCollectionId"] == "clubs"


def test_auth_collection_is_typed_auth(bundle):
    document = json.loads((bundle / "schema.json").read_text())
    kinds = {c["name"]: c["type"] for c in document["collections"]}
    assert kinds["users"] == "auth"
    assert kinds["posts"] == "base"


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------


def test_file_plan_resolves_blobs_to_their_sharded_path(bundle, source):
    plan = json.loads((bundle / "files" / "manifest.json").read_text())["files"]
    assert len(plan) == 1
    entry = plan[0]
    assert entry["collection"] == "posts"
    assert entry["recordId"] == "1"
    assert entry["filename"] == "morning-pages-cover.png"
    assert (source / entry["sourcePath"]).is_file()


def _installed_path(bundle, data_dir):
    """Where the plan says the blob lands, rather than a hard-coded guess."""
    item = json.loads((bundle / "files" / "manifest.json").read_text())["files"][0]
    return (
        data_dir
        / "storage"
        / item["collection"]
        / item["recordId"]
        / (item.get("targetName") or item["filename"])
    )


def test_installing_files_is_idempotent(bundle, source, tmp_path):
    data_dir = tmp_path / "zb_data"
    first = rails2zb.install_files(bundle, source, data_dir)
    assert first == {"files": 1, "installed": 1, "reused": 0}
    second = rails2zb.install_files(bundle, source, data_dir)
    assert second == {"files": 1, "installed": 0, "reused": 1}
    assert _installed_path(bundle, data_dir).is_file()


def test_two_attachments_sharing_a_filename_do_not_collide(bundle, source, tmp_path):
    """`cover` and `thumbnail` on one record may both be `image.png`."""
    plan = json.loads((bundle / "files" / "manifest.json").read_text())
    first = plan["files"][0]
    twin = dict(first)
    twin["field"] = "thumbnail"
    twin["key"] = first["key"].replace("cover", "twin1")
    twin["targetName"] = f"thumbnail-{first['filename']}"
    plan["files"].append(twin)

    doctored = _doctor_manifest(bundle, tmp_path)
    (doctored / "files" / "manifest.json").write_text(json.dumps(plan))
    staged = tmp_path / "src"
    for item in source.rglob("*"):
        if item.is_file():
            target = staged / item.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(item.read_bytes())
    twin_blob = staged / twin["sourcePath"]
    twin_blob.parent.mkdir(parents=True, exist_ok=True)
    twin_blob.write_bytes((staged / first["sourcePath"]).read_bytes())

    result = rails2zb.install_files(doctored, staged, tmp_path / "zb_data")
    assert result == {"files": 2, "installed": 2, "reused": 0}


def test_a_colliding_file_with_different_content_is_refused(bundle, source, tmp_path):
    data_dir = tmp_path / "zb_data"
    rails2zb.install_files(bundle, source, data_dir)
    target = _installed_path(bundle, data_dir)
    target.write_bytes(b"not the same bytes")
    with pytest.raises(RailsError, match="refusing to overwrite"):
        rails2zb.install_files(bundle, source, data_dir)


def test_mapping_without_the_decision_an_unmapped_type_requires_is_refused(
    mutable_source,
):
    """`map_tables` is called directly by tests and by internal callers.

    `reconcile` is what normally guarantees the `omit`, so this is the invariant check
    at that boundary: reached without one, the column has no ZigBase type and must stop
    the run rather than reach the target as some silently chosen default.
    """
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["columns"].append(
        {
            "source": "observed",
            "name": "location",
            "sql_type": "geometry",
            "type": "geometry",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)

    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    fid = "column.posts.location.type"
    assert any(f.id == fid for f in findings), "the fixture must produce the finding"
    value = decisions_for([f.to_dict() for f in findings])
    value["decisions"] = [d for d in value["decisions"] if d["id"] != fid]
    without = rails2zb.load_decisions_from_value(value)

    with pytest.raises(RailsError, match="unmapped column type 'geometry'"):
        rails2zb.map_tables(src, without)


def test_a_foreign_key_into_a_rails_internal_table_becomes_no_relation(mutable_source):
    """A denormalized `blob_id` on a user table points at a table that never migrates.

    Rails' own tables are excluded from the bundle, so a relation derived from one would
    name a collection that does not exist. The column itself still travels as a plain
    number — dropping it would lose data the application wrote.

    The decisive part is the FINDING: without the skip the operator is asked to choose
    an on-delete behavior for `posts.cover_blob_id`, and no answer to that question can
    reach the bundle, because no relation is ever emitted for it either way.
    """
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
    posts["foreign_keys"].append(
        {
            "source": "observed",
            "column": "cover_blob_id",
            "to_table": "active_storage_blobs",
            "primary_key": "id",
            # A non-default action, so an `fk.*.action` finding WOULD be raised for an
            # ordinary table; with `None` the two paths agree and prove nothing.
            "on_delete": "restrict",
            "on_update": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)

    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    assert not [f for f in findings if f.id == "fk.posts.cover_blob_id.action"], (
        "a decision was demanded about a relation that is never emitted"
    )
    decisions = rails2zb.load_decisions_from_value(
        decisions_for([f.to_dict() for f in findings])
    )
    mapped = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    fields = {f["name"]: f for f in mapped.fields}
    assert "cover_blob_id" in fields, "the column must still travel"
    assert fields["cover_blob_id"]["type"] == "number"
    assert not any(
        f.get("options", {}).get("targetCollectionId") == "active_storage_blobs"
        for f in mapped.fields
    ), "no relation may point at a table the bundle never emits"


@pytest.mark.parametrize("where", ["inside", "the-source-itself", "ancestor"])
def test_a_bundle_cannot_be_written_over_or_around_the_source(
    mutable_source, tmp_path, where
):
    """The frozen source is the one thing extraction must not be able to damage.

    An output inside it would be swept into `hashes.json`, and an output ABOVE it makes
    the bundle contain the very snapshot it claims to have converted — so the attested
    tree and the evidence for it stop being separable.
    """
    # A COPY, deliberately: if this guard ever regresses the test must corrupt a
    # temporary tree rather than the committed fixture it would otherwise write into.
    src = rails2zb.load_source(mutable_source)
    decisions = rails2zb.load_decisions_from_value(
        decisions_for([f.to_dict() for f in rails2zb.build_findings(src)])
    )
    out = {
        "inside": mutable_source / "bundle",
        "the-source-itself": mutable_source,
        "ancestor": mutable_source.parent,
    }[where]
    expected = (
        "ancestor of the source tree"
        if where == "ancestor"
        else "outside the frozen source tree"
    )
    with pytest.raises(RailsError, match=expected):
        rails2zb.extract(src, decisions, out)


def test_a_bundle_naming_a_blob_that_is_not_there_is_refused(bundle, source, tmp_path):
    """A plan entry with nothing behind it must stop the install, not skip the file.

    Skipping would return a success count that says every file arrived while the
    record still points at one the operator does not have.
    """
    doctored = _doctor_manifest(bundle, tmp_path, sourcePath="storage/nothing/here")
    with pytest.raises(RailsError, match="missing blob"):
        rails2zb.install_files(doctored, source, tmp_path / "zb_data")


def test_a_blob_whose_size_disagrees_with_the_bundle_is_refused(
    bundle, source, tmp_path
):
    """The size check only decides when no digest was recorded.

    With a `sha256` present any size change trips the digest first, so this guards the
    older or hand-written manifest that carries `bytes` alone.
    """
    staged = tmp_path / "src"
    for item in source.rglob("*"):
        if item.is_file():
            target = staged / item.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(item.read_bytes())
    entry = json.loads((bundle / "files" / "manifest.json").read_text())["files"][0]
    blob = staged / entry["sourcePath"]
    blob.write_bytes(blob.read_bytes() + b"appended")
    doctored = _doctor_manifest(bundle, tmp_path, sha256=None)

    with pytest.raises(RailsError, match=r"bytes; the bundle recorded"):
        rails2zb.install_files(doctored, staged, tmp_path / "zb_data")


def test_a_blob_that_changed_since_extraction_is_refused(bundle, source, tmp_path):
    """The plan pins the bytes; installing whatever is there now defeats the point."""
    staged = tmp_path / "src"
    for item in source.rglob("*"):
        if item.is_file():
            target = staged / item.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(item.read_bytes())
    plan = json.loads((bundle / "files" / "manifest.json").read_text())["files"][0]
    (staged / plan["sourcePath"]).write_bytes(b"tampered")

    with pytest.raises(RailsError, match="changed since extraction|recorded"):
        rails2zb.install_files(bundle, staged, tmp_path / "zb_data")


# ---------------------------------------------------------------------------
# Review findings on #376 — each of these shipped silently, so each gets a test
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("2024-01-15 09:00:00", "2024-01-15T09:00:00Z"),
        ("2024-01-15T09:00:00Z", "2024-01-15T09:00:00Z"),
        # Sub-second precision is data, not noise.
        ("2024-01-15 09:00:00.123456", "2024-01-15T09:00:00.123456Z"),
        # An offset must be CONVERTED. Relabelling +05:00 as Z moves the row 5 hours.
        ("2024-01-15T09:00:00+05:00", "2024-01-15T04:00:00Z"),
        ("2024-01-15T09:00:00-08:00", "2024-01-15T17:00:00Z"),
        ("2024-01-15T09:00:00.5+05:00", "2024-01-15T04:00:00.5Z"),
    ],
)
def test_timestamps_convert_rather_than_relabel(value, expected):
    assert rails2zb.to_rfc3339(value) == expected


def _posts_partial_index(source):
    """Make the fixture's posts index partial, in the INVENTORY.

    Earlier versions hand-built a `Mapped` and called `_indexes_for` with a hand-built
    predicate key. That cannot see a producer/consumer disagreement -- and the producer
    and the consumer did in fact key the predicate differently, which dropped the index
    entirely while the decision recorded that it had been kept.
    """
    schema = read_inventory(source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["indexes"][0]["where"] = "author_id IS NOT NULL"
    posts["indexes"][0]["unique"] = True
    write_inventory(source, "schema", schema)
    return posts["indexes"][0]["name"]


def _posts_indexes(source, choice, artifact=None):
    src = rails2zb.load_source(source)
    findings = rails2zb.build_findings(src)
    finding = next(f for f in findings if f.code == "PartialIndexPredicate")
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == finding.id:
            entry["choice"] = choice
            if artifact is not None:
                entry["artifact"] = artifact
    decisions = rails2zb.load_decisions_from_value(value)
    document = rails2zb.build_schema_document(
        rails2zb.map_tables(src, decisions), decisions
    )
    collection = next(c for c in document["collections"] if c["name"] == "posts")
    return {i["name"]: i for i in collection["indexes"]}


def test_a_partial_predicate_is_never_copied_verbatim(mutable_source):
    """`author_id` is renamed to `author` and enums are decoded, so source SQL does not
    transfer. Copying it can emit an index that is invalid, or valid and subtly wrong."""
    name = _posts_partial_index(mutable_source)
    emitted = _posts_indexes(mutable_source, "omit")
    assert name not in emitted, (
        "without a reviewed predicate the partial index must be omitted, not copied"
    )


def test_a_reviewed_partial_predicate_is_used(mutable_source):
    name = _posts_partial_index(mutable_source)
    emitted = _posts_indexes(mutable_source, "replacement", "author IS NOT NULL")
    assert emitted[name]["where"] == "author IS NOT NULL"
    assert emitted[name]["unique"] is True


def test_every_partial_index_raises_a_finding(source):
    """Neither copying nor dropping may happen silently."""
    src = rails2zb.load_source(source)
    tables = src.schema["tables"]
    posts = next(x for x in tables if x["name"] == "posts")
    posts["indexes"][0]["where"] = "author_id IS NOT NULL"
    ids = {f.id for f in rails2zb.build_findings(src)}
    assert f"index.posts.{posts['indexes'][0]['name']}.where" in ids


def test_indexes_for_does_not_corrupt_later_iterations(source, tmp_path):
    """Regression: the emitted dict once shadowed the Mapped it was built from."""
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    decisions = rails2zb.load_decisions_from_value(decisions_for(findings))
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert len(posts.indexes) > 1, "fixture must have several indexes to catch this"
    assert len(rails2zb._indexes_for(posts)) == len(posts.indexes)


def test_an_expression_rule_without_an_artifact_is_refused(source):
    """Silently shipping Locked in place of a reviewed rule inverts the decision."""
    src = rails2zb.load_source(source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    # Only the rules decision is altered; stripping every artifact would trip the
    # generic requires_artifact guard on some unrelated finding instead.
    value["decisions"] = [
        (
            {k: v for k, v in d.items() if k != "artifact"} | {"choice": "expression"}
            if d["id"] == "table.clubs.rules"
            else d
        )
        for d in value["decisions"]
    ]
    with pytest.raises(RailsError, match="asserts a replacement exists"):
        rails2zb.reconcile(findings, rails2zb.load_decisions_from_value(value))


@pytest.mark.parametrize(
    "evil",
    ["../../etc/passwd", "/etc/passwd", "..", "a/../../../b"],
)
def test_file_install_refuses_paths_that_escape(bundle, source, tmp_path, evil):
    """Manifest components are data on disk that nothing re-validates at install time."""
    manifest = json.loads((bundle / "files" / "manifest.json").read_text())
    # `targetName` is what the destination is built from; poisoning `filename` alone
    # would no longer exercise the containment check at all.
    manifest["files"][0]["targetName"] = evil
    manifest["files"][0]["filename"] = evil
    doctored = tmp_path / "doctored"
    doctored.mkdir()
    (doctored / "files").mkdir()
    for item in bundle.rglob("*"):
        if item.is_file():
            target = doctored / item.relative_to(bundle)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(item.read_bytes())
    (doctored / "files" / "manifest.json").write_text(json.dumps(manifest))

    with pytest.raises(RailsError, match="unsafe path component|escapes"):
        rails2zb.install_files(doctored, source, tmp_path / "zb_data")


def _doctor_manifest(bundle, tmp_path, **overrides):
    """A copy of `bundle` whose first file entry carries the given overrides."""
    manifest = json.loads((bundle / "files" / "manifest.json").read_text())
    manifest["files"][0].update(overrides)
    doctored = tmp_path / "doctored"
    for item in bundle.rglob("*"):
        if item.is_file():
            target = doctored / item.relative_to(bundle)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(item.read_bytes())
    (doctored / "files" / "manifest.json").write_text(json.dumps(manifest))
    return doctored


@pytest.mark.parametrize(
    "evil",
    ["../../../etc/passwd", "/etc/passwd", "storage/../../../../etc/passwd"],
)
def test_file_install_refuses_a_source_path_that_escapes(
    bundle, source, tmp_path, evil
):
    """The READ side needs containment too: sourcePath is manifest data like any other.

    Covered separately from the destination case because they are enforced by two
    different calls, and a test that only poisons `filename` leaves this one unguarded.
    """
    doctored = _doctor_manifest(bundle, tmp_path, sourcePath=evil)
    with pytest.raises(RailsError, match="unsafe path component|escapes"):
        rails2zb.install_files(doctored, source, tmp_path / "zb_data")


def test_a_non_sqlite_source_still_yields_an_inventory(mutable_source):
    """Postgres and MySQL operators need the findings and decisions; only row extraction
    is SQLite-bound, and gating `load_source` would deny them the half that works."""
    from .conftest import read_inventory, write_inventory

    versions = read_inventory(mutable_source, "versions")
    versions["adapter"] = "PostgreSQL"
    write_inventory(mutable_source, "versions", versions)

    src = rails2zb.load_source(mutable_source)
    inventory = rails2zb.build_inventory(src)
    assert inventory["summary"]["blockers"] > 0

    with pytest.raises(RailsError, match="frozen SQLite file"):
        rails2zb.require_sqlite(src)


def test_a_leaf_symlink_in_the_source_is_refused(bundle, source, tmp_path):
    """Resolving only the parent let a leaf symlink escape: `blob -> /etc/passwd`
    satisfied containment and was then read."""
    staged = tmp_path / "source"
    for item in source.rglob("*"):
        if item.is_file():
            target = staged / item.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(item.read_bytes())

    plan = json.loads((bundle / "files" / "manifest.json").read_text())["files"][0]
    planted = staged / plan["sourcePath"]
    planted.unlink()
    planted.symlink_to("/etc/passwd")

    with pytest.raises(RailsError, match="escapes|unsafe path component"):
        rails2zb.install_files(bundle, staged, tmp_path / "zb_data")


def test_a_destination_whose_leaf_does_not_exist_is_still_allowed(tmp_path):
    """The write side must keep working: its leaf legitimately does not exist yet."""
    got = rails2zb._contained(tmp_path / "data", "storage", "posts", "1", "cover.png")
    assert got.name == "cover.png"


# ---------------------------------------------------------------------------
# Round five: decisions must reach the output, and unsupported shapes must refuse
# ---------------------------------------------------------------------------


def test_a_date_column_extracts(source):
    """`date` is advertised in TYPE_MAP; raising on every value made it unusable."""
    assert rails2zb.to_rfc3339("2024-01-15") == "2024-01-15T00:00:00Z"


def test_json_columns_become_objects_not_strings(source):
    assert rails2zb.coerce('{"a": 1}', "json", None) == {"a": 1}
    with pytest.raises(RailsError, match="not JSON"):
        rails2zb.coerce("not json at all", "json", None)


def test_the_serialized_decision_reaches_the_schema(source):
    """Reading a decision and emitting the raw type made the choice a formality."""
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    decisions = rails2zb.load_decisions_from_value(decisions_for(findings))
    mapped = next(
        m for m in rails2zb.map_tables(src, decisions) if m.table == "notifications"
    )
    payload = next(f for f in mapped.fields if f["name"] == "payload")
    assert payload["type"] == "json"


def test_all_five_access_rules_can_be_expressed(source):
    """One expression on list+view could not represent an authenticated write."""
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    value = decisions_for(findings)
    value["decisions"] = [
        (
            {
                **d,
                "choice": "expression",
                "artifact": "list=@public\nview=@public\ncreate=@request.auth.id != ''",
            }
            if d["id"] == "table.clubs.rules"
            else d
        )
        for d in value["decisions"]
    ]
    decisions = rails2zb.load_decisions_from_value(value)
    document = rails2zb.build_schema_document(
        rails2zb.map_tables(src, decisions), decisions
    )
    clubs = next(c for c in document["collections"] if c["name"] == "clubs")
    assert clubs["listRule"] == "@public"
    assert clubs["createRule"] == "@request.auth.id != ''"
    assert clubs["deleteRule"] is None, "an unnamed action stays locked"


def test_omitting_constraints_does_not_drop_the_whole_table(source):
    """`table.users.check_constraints: omit` once removed the users table entirely."""
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    value = decisions_for(findings)
    value["decisions"] = [
        ({**d, "choice": "omit"} if d["id"].endswith(".check_constraints") else d)
        for d in value["decisions"]
    ]
    decisions = rails2zb.load_decisions_from_value(value)
    tables = {m.table for m in rails2zb.map_tables(src, decisions)}
    assert "users" in tables


def test_omitting_a_referenced_table_is_refused(source):
    """Dropping `users` left six collections pointing at a collection that is gone."""
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    value = decisions_for(findings)
    value["decisions"] = [
        ({**d, "choice": "omit"} if d["id"] == "table.users.primary_key" else d)
        for d in value["decisions"]
    ] + [
        {
            "id": "table.users.identifier",
            "choice": "omit",
            "rationale": "probe",
        }
    ]
    # The synthetic decision has no matching finding, so drive map_tables directly.
    decisions = {
        d["id"]: rails2zb.Decision(d["id"], d["choice"], d["rationale"], None)
        for d in value["decisions"]
    }
    with pytest.raises(RailsError, match="pointing at nothing"):
        rails2zb.map_tables(src, decisions)


def test_reset_passwords_suppresses_the_digest(source):
    """A peppered migration must not ship credentials guaranteed to reject every login."""
    src = rails2zb.load_source(source)
    entry = next(m for m in rails2zb.map_tables(src, {}) if m.table == "users")
    row = {"id": "1", "email": "a@b.c", "password_digest": "$2a$04$" + "x" * 53}
    kept = rails2zb.build_auth_record(entry, row, None, emit_credentials=False)
    assert "passwordHash" not in kept


def test_extraction_refuses_a_dirty_output_directory(source, tmp_path):
    """Stale files would be attested in hashes.json as if this run produced them."""
    out = tmp_path / "bundle"
    out.mkdir()
    (out / "leftover.ndjson").write_text("{}\n")
    src = rails2zb.load_source(source)
    with pytest.raises(RailsError, match="not empty"):
        rails2zb.extract(src, {}, out)


def test_nested_inferred_records_are_refused(mutable_source):
    """Checking only the top-level marker let a guess ride one level down."""
    from .conftest import read_inventory, write_inventory

    models = read_inventory(mutable_source, "models")
    models["models"][0]["source"] = "inferred"
    write_inventory(mutable_source, "models", models)
    with pytest.raises(RailsError, match="must not be mixed"):
        rails2zb.load_source(mutable_source)


# ---------------------------------------------------------------------------
# Round six: every offered choice must actually do something
# ---------------------------------------------------------------------------


def _with_choice(source, fid, choice, artifact=None):
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    value = decisions_for(findings)
    value["decisions"] = [
        ({**d, "choice": choice, **({"artifact": artifact} if artifact else {})})
        if d["id"] == fid
        else d
        for d in value["decisions"]
    ]
    return src, rails2zb.load_decisions_from_value(value)


def test_a_credential_column_omit_actually_drops_it(mutable_source):
    """The finding exists because these must never migrate; omit was a no-op."""
    from .conftest import read_inventory, write_inventory

    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    users["columns"].append(
        {
            "source": "observed",
            "name": "reset_password_token",
            "sql_type": "varchar",
            "type": "string",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)

    src, decisions = _with_choice(
        mutable_source, "column.users.reset_password_token.credential", "omit"
    )
    mapped = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "users")
    assert "reset_password_token" not in {f["name"] for f in mapped.fields}


def test_a_single_expression_rule_containing_an_operator_works(source):
    """Nearly every real rule contains `=`; dispatching on that broke the documented form."""
    src, decisions = _with_choice(
        source, "table.clubs.rules", "expression", "@request.auth.id != ''"
    )
    document = rails2zb.build_schema_document(
        rails2zb.map_tables(src, decisions), decisions
    )
    clubs = next(c for c in document["collections"] if c["name"] == "clubs")
    assert clubs["listRule"] == "@request.auth.id != ''"
    assert clubs["deleteRule"] == "@request.auth.id != ''"


def test_a_missing_blob_is_refused_at_extraction(source, tmp_path):
    """Recording a null digest disabled the pinning on exactly the damaged snapshots
    it was added to catch."""
    staged = tmp_path / "src"
    for item in source.rglob("*"):
        if item.is_file():
            target = staged / item.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(item.read_bytes())
    for blob in (staged / "storage").rglob("*"):
        if blob.is_file():
            blob.unlink()

    src = rails2zb.load_source(staged)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    decisions = rails2zb.load_decisions_from_value(decisions_for(findings))
    with pytest.raises(RailsError, match="missing blob"):
        rails2zb.extract(src, decisions, tmp_path / "out")


@pytest.mark.parametrize("evil", ["a/b.png", "nested/deep/file.png", "back\\slash.png"])
def test_a_stored_name_must_be_one_path_component(evil, tmp_path):
    """`a/b.png` installs two levels deep, where the file API can never match it."""
    with pytest.raises(RailsError, match="single path component"):
        rails2zb._contained(tmp_path, "storage", "posts", "1", evil)


@pytest.mark.parametrize(
    ("stored", "expected"),
    [
        ("t", True),
        ("f", False),
        ("true", True),
        ("false", False),
        (1, True),
        (0, False),
        # Padding is ignored on the TRUE side only: every padded spelling is true to
        # Rails too, so nothing is being decided on the operator's behalf here.
        ("T ", True),
        ("  true  ", True),
        # NOT `("", False)`: see the null case below.
        ("f", False),
    ],
)
def test_legacy_text_booleans_are_read_correctly(stored, expected):
    """`bool('f')` is True, which inverts every false value in an upgraded app."""
    assert rails2zb.coerce(stored, "bool", None) is expected


def test_an_empty_boolean_is_null_not_false():
    """`ActiveModel::Type::Boolean#cast_value` returns nil for `""`.

    It checks the empty string BEFORE consulting FALSE_VALUES, so the application read
    such a row as unset. Folding it to `false` picks a side on the one column whose
    entire content is which side it is on, and picks it silently, because `false` is a
    perfectly ordinary value to see in the output.
    """
    assert rails2zb.coerce("", "bool", None) is None
    assert rails2zb.coerce("   ", "bool", None) is None


@pytest.mark.parametrize(
    "stored",
    [
        # Case Rails does not accept: FALSE_VALUES holds `false` and `FALSE`, not these.
        "False",
        "fALSE",
        "Off",
        # Padding Rails does not strip: `cast_value(" false ")` is not `""` and is not a
        # member, so the application read every one of these as TRUE as well.
        " false ",
        "\tf",
        " OFF ",
    ],
)
def test_a_false_word_rails_would_read_as_true_is_refused(stored):
    """The application read these as TRUE; writing False for them is an inversion.

    Same direction as the `bool('f')` bug this branch opens by warning about, and just
    as silent, because `false` is an ordinary value to see in the output. Matched on
    the DISTINCT message, so this cannot be satisfied by the generic refusal.
    """
    with pytest.raises(RailsError, match="does not recognize as false"):
        rails2zb.coerce(stored, "bool", None)


@pytest.mark.parametrize(
    ("stored", "expected"),
    [("off", False), ("OFF", False), ("on", True), ("ON", True), ("F", False)],
)
def test_the_canonical_rails_spellings_are_honoured(stored, expected):
    """`off`/`OFF` really are false to Rails, and `on` is just a non-false string."""
    assert rails2zb.coerce(stored, "bool", None) is expected


@pytest.mark.parametrize("stored", ["maybe", "yes", "2", "-1", "null", "F ALSE"])
def test_an_unrecognized_boolean_is_refused(stored):
    """The fallback is `bool(value)`, under which every one of these is True.

    Guessing here is how `'f'` became True in the first place; a value the mapping does
    not know must stop the extraction rather than pick a side.
    """
    with pytest.raises(RailsError, match="unrecognized boolean"):
        rails2zb.coerce(stored, "bool", None)


def test_an_artifact_that_does_not_exist_is_refused(source, tmp_path):
    """A path to nothing documents a replacement nobody built."""
    src = rails2zb.load_source(source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    decisions = rails2zb.load_decisions_from_value(value)
    with pytest.raises(RailsError, match="does not exist"):
        rails2zb.reconcile(findings, decisions, artifact_root=tmp_path)


def test_a_reviewed_partial_predicate_is_not_treated_as_a_path(source, tmp_path):
    """Its artifact is the predicate TEXT; a path check would reject every one."""
    src = rails2zb.load_source(source)
    tables = src.schema["tables"]
    posts = next(x for x in tables if x["name"] == "posts")
    posts["indexes"][0]["where"] = "status = 'published'"
    findings = rails2zb.build_findings(src)
    fid = f"index.posts.{posts['indexes'][0]['name']}.where"
    value = decisions_for([f.to_dict() for f in findings])
    assert any(d["id"] == fid for d in value["decisions"]), (
        f"{fid} must be among the decisions, or the replacement below is never applied "
        f"and reconcile is handed an ordinary decision set"
    )
    value["decisions"] = [
        ({**d, "choice": "replacement", "artifact": "status = 'published'"})
        if d["id"] == fid
        else d
        for d in value["decisions"]
    ]
    from .conftest import materialize_artifacts

    materialize_artifacts(value, tmp_path)
    rails2zb.reconcile(
        findings, rails2zb.load_decisions_from_value(value), artifact_root=tmp_path
    )
