"""Names that a decision id has to carry, and field names that must stay distinct.

Two review rounds found the same shape of bug from opposite ends: a subject name the
finding id could not represent, so every decision about it was silently ignored; and two
different source columns resolving to one field name, so one of them silently vanished.
Both were invisible -- the converter attested a clean bundle either way.
"""

from __future__ import annotations

import json
import sqlite3

import pytest

from .conftest import decisions_for, read_inventory, write_inventory
from tools.rails import rails2zb
from tools.rails._core import escape_part, finding_id, split_id, unescape_part


def _db(source):
    return sqlite3.connect(next((source / "db").glob("*.sqlite3")))


def _add_column(source, table, name, value, type_="string", sql_type="varchar"):
    """Add a column to BOTH the inventory and the database, as Rails would have."""
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    entry["columns"].append(
        {
            "source": "observed",
            "name": name,
            "sql_type": sql_type,
            "type": type_,
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(source, "schema", schema)
    connection = _db(source)
    connection.execute(f'ALTER TABLE "{table}" ADD COLUMN "{name}" {sql_type}')
    connection.execute(f'UPDATE "{table}" SET "{name}" = ?', (value,))
    connection.commit()
    connection.close()


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


# ---------------------------------------------------------------------------
# Identity round-trip
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "part", ["posts", "legacy.posts", "a%b", "a%2Eb", "%", ".", "a.b.c"]
)
def test_an_identity_part_survives_the_round_trip(part):
    """Escaping `.` to `_` was lossy: `legacy.posts` and `legacy_posts` collided.

    Consumers split a decision id and compare the parts against raw inventory names, so
    an escape that cannot be reversed makes every one of those comparisons miss.
    """
    assert unescape_part(escape_part(part)) == part
    assert split_id(finding_id("table", part, "identifier")) == [
        "table",
        part,
        "identifier",
    ]


def test_two_names_differing_only_by_a_dot_get_different_ids():
    assert finding_id("table", "legacy.posts", "x") != finding_id(
        "table", "legacy_posts", "x"
    )


def test_a_dotted_index_name_keeps_its_reviewed_predicate(mutable_source):
    """A partial index under a custom dotted name silently vanished.

    `build_schema_document` keyed the reviewed predicate by the ESCAPED name while
    `_indexes_for` looked it up by the RAW one, so the lookup missed and the index --
    which may be a UNIQUE constraint -- was dropped entirely, with a recorded decision
    saying it had been kept.
    """
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    index = posts["indexes"][0]
    index["name"] = "idx.posts.published"
    index["where"] = "status = 'published'"
    write_inventory(mutable_source, "schema", schema)

    fid = finding_id("index", "posts", "idx.posts.published", "where")
    src, decisions = _decide(mutable_source, **{fid: ("replacement", "status = 1")})
    document = rails2zb.build_schema_document(
        rails2zb.map_tables(src, decisions), decisions
    )
    collection = next(c for c in document["collections"] if c["name"] == "posts")
    emitted = {i["name"]: i for i in collection["indexes"]}
    assert "idx.posts.published" in emitted, (
        "the index was dropped even though its predicate was reviewed"
    )
    assert emitted["idx.posts.published"]["where"] == "status = 1"


def test_a_schema_qualified_table_can_be_renamed(mutable_source):
    """Postgres sources carry names like `legacy.posts`; refusing them closed the path.

    The finding exists precisely for names ZigBase cannot accept, so its `rename` has to
    work for the dotted case -- which is the case that produces it most often.
    """
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["name"] = "legacy.events"
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute('ALTER TABLE "events" RENAME TO "legacy.events"')
    connection.commit()
    connection.close()

    fid = finding_id("table", "legacy.events", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "events")})
    mapped = rails2zb.map_tables(src, decisions)
    names = {m.collection for m in mapped}
    assert "events" in names and "legacy.events" not in names


def test_a_schema_qualified_table_can_be_omitted(mutable_source):
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["name"] = "legacy.events"
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute('ALTER TABLE "events" RENAME TO "legacy.events"')
    connection.commit()
    connection.close()

    fid = finding_id("table", "legacy.events", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    assert "legacy.events" not in {m.table for m in rails2zb.map_tables(src, decisions)}


# ---------------------------------------------------------------------------
# Distinct field names
# ---------------------------------------------------------------------------


def test_a_denormalised_column_beside_its_foreign_key_keeps_both(
    mutable_source, workspace
):
    """`author_id` and `author` both became the field `author`; one silently won.

    Records are assembled into a dict, so the loser's data never reached the NDJSON --
    and the bundle was hashed and attested as complete regardless.
    """
    _add_column(mutable_source, "posts", "author", "Ada Lovelace")
    src, decisions = _decide(mutable_source)
    mapped = rails2zb.map_tables(src, decisions)
    posts = next(m for m in mapped if m.table == "posts")
    names = [f["name"] for f in posts.fields]
    assert len(names) == len(set(names)), f"duplicate field names emitted: {names}"

    by_name = {f["name"]: f for f in posts.fields}
    assert by_name["author"]["type"] == "text"
    assert by_name["author_id"]["type"] == "relation", (
        "the relation must keep its full column name where `author` is taken"
    )

    rails2zb.extract(src, decisions, workspace / "bundle")
    rows = [
        json.loads(line)
        for line in (workspace / "bundle" / "data" / "posts.ndjson")
        .read_text()
        .splitlines()
    ]
    assert rows, "the fixture should contain posts"
    assert all(row["author"] == "Ada Lovelace" for row in rows), (
        "the denormalised column's data was dropped"
    )
    assert all(row["author_id"] for row in rows), "the relation lost its value"


def test_an_index_over_a_renamed_relation_follows_the_field(mutable_source):
    """The index must name the field the schema actually emitted, not a guess."""
    _add_column(mutable_source, "posts", "author", "Ada")
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["indexes"].append(
        {
            "source": "observed",
            "name": "index_posts_on_author_id",
            "columns": ["author_id"],
            "unique": False,
            "where": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(mutable_source)
    mapped = rails2zb.map_tables(src, decisions)
    entry = next(m for m in mapped if m.table == "posts")
    emitted = next(
        i
        for i in rails2zb._indexes_for(entry)
        if i["name"] == "index_posts_on_author_id"
    )
    assert emitted["fields"] == ["author_id"]


def test_a_column_colliding_with_an_attachment_is_refused(mutable_source):
    """The backstop, reached only when no decision covers the collision.

    A `cover` column beside `has_one_attached :cover` now raises a finding, so the
    ordinary path is to decide it; this asserts what happens if that decision is absent.
    """
    _add_column(mutable_source, "posts", "cover", "not-a-blob")
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    value["decisions"] = [
        d
        for d in value["decisions"]
        if d["id"] != finding_id("attachment", "posts", "cover", "collision")
    ]
    decisions = rails2zb.load_decisions_from_value(value)
    with pytest.raises(rails2zb.RailsError, match="attachment 'cover'"):
        rails2zb.map_tables(src, decisions)


def test_a_rejected_column_name_can_be_renamed(mutable_source, workspace):
    """A column name ZigBase cannot accept is a decision, not a late `schema apply` error.

    Nothing validated column names, so `legacy.value` shipped as a field name and the
    import failed at the target -- after the operator believed the bundle was good.
    """
    _add_column(mutable_source, "posts", "legacy.value", "kept")
    fid = finding_id("column", "posts", "legacy.value", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "legacyValue")})
    mapped = rails2zb.map_tables(src, decisions)
    posts = next(m for m in mapped if m.table == "posts")
    assert "legacyValue" in {f["name"] for f in posts.fields}
    assert "legacy.value" not in {f["name"] for f in posts.fields}

    rails2zb.extract(src, decisions, workspace / "bundle")
    rows = [
        json.loads(line)
        for line in (workspace / "bundle" / "data" / "posts.ndjson")
        .read_text()
        .splitlines()
    ]
    assert all(row["legacyValue"] == "kept" for row in rows), (
        "the renamed field must carry the source column's data"
    )


def test_a_rejected_column_name_can_be_omitted(mutable_source):
    _add_column(mutable_source, "posts", "legacy.value", "dropped")
    fid = finding_id("column", "posts", "legacy.value", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert not [f for f in posts.fields if "legacy" in f["name"]]


def test_a_column_rename_to_an_invalid_identifier_is_refused(mutable_source):
    _add_column(mutable_source, "posts", "legacy.value", "x")
    fid = finding_id("column", "posts", "legacy.value", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "still.invalid")})
    with pytest.raises(rails2zb.RailsError, match="not a usable ZigBase"):
        rails2zb.map_tables(src, decisions)


def test_two_columns_renamed_onto_one_field_are_refused(mutable_source):
    """Silently letting the second win is exactly the clobber this guard exists for."""
    _add_column(mutable_source, "posts", "legacy.value", "x")
    fid = finding_id("column", "posts", "legacy.value", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "title")})
    with pytest.raises(rails2zb.RailsError, match="both resolve to the field"):
        rails2zb.map_tables(src, decisions)


def test_every_invalid_column_name_raises_a_finding(mutable_source):
    """Not just dots: a hyphen or a leading digit fails the same gate."""
    for name in ("legacy.value", "user-name", "2fa_enabled"):
        _add_column(mutable_source, "posts", name, "x")
    src = rails2zb.load_source(mutable_source)
    rejected = {
        f.id for f in rails2zb.build_findings(src) if f.code == "ColumnNameRejected"
    }
    assert rejected == {
        finding_id("column", "posts", name, "identifier")
        for name in ("legacy.value", "user-name", "2fa_enabled")
    }


def _unmapped_column(source, table, name):
    """A column with no ZigBase type, so its only decision is `omit`."""
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    entry["columns"].append(
        {
            "source": "observed",
            "name": name,
            "sql_type": "geometry",
            "type": "geometry",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(source, "schema", schema)
    return finding_id("column", table, name, "type")


def test_an_index_over_a_dropped_column_is_not_aliased_onto_a_relation(mutable_source):
    """The nastiest shape found in review: a dropped column's index re-homed itself.

    `author` is dropped, so the relation `author_id` is free to take the name `author`.
    Resolving the index's source column by falling back to its raw name then pointed the
    source column's UNIQUE index at the RELATION field -- silently imposing one post per
    author on data that never had that constraint.
    """
    fid = _unmapped_column(mutable_source, "posts", "author")
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["indexes"].append(
        {
            "source": "observed",
            "name": "index_posts_on_author",
            "columns": ["author"],
            "unique": True,
            "where": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)

    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert entry.field_names["author_id"] == "author", (
        "with the plain column dropped, the relation may take the freed name"
    )
    emitted = {i["name"]: i for i in rails2zb._indexes_for(entry)}
    assert "index_posts_on_author" not in emitted, (
        "an index over a dropped column must be skipped, not re-pointed at a relation"
    )


def test_a_dropped_relation_column_claims_no_field_name(mutable_source):
    """A relation column dropped by a column-level decision must claim nothing.

    Otherwise it reserves a name no field will ever occupy, and can block the very
    rename or fallback that would have resolved a collision.
    """
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    next(c for c in posts["columns"] if c["name"] == "club_id")["type"] = "geometry"
    write_inventory(mutable_source, "schema", schema)
    fid = finding_id("column", "posts", "club_id", "type")
    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert "club_id" not in entry.field_names
    assert "club" not in {f["name"] for f in entry.fields}


def test_an_attachment_maps_to_itself_when_nothing_renames_it(source):
    """`field_names` carries attachments so a rename decision can be honoured.

    The mapping is source name -> emitted field name; Active Storage's own key stays the
    source name, because that is what it recorded.
    """
    src, decisions = _decide(source)
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert "cover" in posts.attachments
    assert posts.attachment_names["cover"] == "cover"
    assert "cover" not in posts.field_names, (
        "columns and attachments keep separate maps; they may share a name"
    )


def test_a_renamed_relation_column_uses_the_new_name(mutable_source, workspace):
    """A rename decision on a relation column was silently ignored."""
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    next(c for c in posts["columns"] if c["name"] == "author_id")["name"] = "author.id"
    for fk in posts["foreign_keys"]:
        if fk["column"] == "author_id":
            fk["column"] = "author.id"
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute('ALTER TABLE posts RENAME COLUMN author_id TO "author.id"')
    connection.commit()
    connection.close()

    fid = finding_id("column", "posts", "author.id", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "writer")})
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    writer = next(f for f in entry.fields if f["name"] == "writer")
    assert writer["type"] == "relation"

    rails2zb.extract(src, decisions, workspace / "bundle")
    rows = [
        json.loads(line)
        for line in (workspace / "bundle" / "data" / "posts.ndjson")
        .read_text()
        .splitlines()
    ]
    assert all(row["writer"] for row in rows), "the relation lost its value"


def test_a_renamed_enum_column_keeps_its_labels_and_its_data(mutable_source, workspace):
    """Enums are keyed by SOURCE column; a rename made the lookup miss.

    The fixture's own enum is string-backed, so a missed decode is invisible there -- the
    stored value already equals the label. This uses an INTEGER-backed enum, which is the
    shape where a missed decode ships `1` where the source meant `published`.
    """
    labels = {"draft": 0, "published": 1, "archived": 2}
    _add_column(
        mutable_source, "posts", "phase.v2", 1, type_="integer", sql_type="integer"
    )
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["enums"]["phase.v2"] = {
        "backing_type": "integer",
        "source": "observed",
        "values": labels,
    }
    write_inventory(mutable_source, "models", models)

    fid = finding_id("column", "posts", "phase.v2", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "phase")})
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    phase = next(f for f in entry.fields if f["name"] == "phase")
    assert phase["type"] == "select", "the enum must still be recognised after a rename"
    assert set(phase["options"]["values"]) == set(labels)

    rails2zb.extract(src, decisions, workspace / "bundle")
    rows = [
        json.loads(line)
        for line in (workspace / "bundle" / "data" / "posts.ndjson")
        .read_text()
        .splitlines()
    ]
    assert rows and all(row["phase"] == "published" for row in rows), (
        f"an integer-backed enum shipped undecoded: {[r['phase'] for r in rows]}"
    )


def test_two_columns_differing_only_in_case_are_refused(mutable_source):
    """ZigBase compares field names case-insensitively; `Title` beside `title` collides.

    Exact-match collision detection let both through, and the target refused the schema
    -- after the operator had a bundle that looked complete.
    """
    # Inventory only: SQLite itself refuses `Title` beside `title`, which is precisely
    # why the target compares field names the same way.
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["columns"].append(
        {
            "source": "observed",
            "name": "Title",
            "sql_type": "varchar",
            "type": "string",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(mutable_source)
    with pytest.raises(rails2zb.RailsError, match="both resolve to the field"):
        rails2zb.map_tables(src, decisions)


def test_an_index_over_an_engine_owned_auth_field_is_not_emitted(
    mutable_source, workspace
):
    """The document does not declare `email` on an auth collection, so no index may
    name it -- the engine owns that field and its uniqueness index."""
    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    users["indexes"].append(
        {
            "source": "observed",
            "name": "index_users_on_email_lower",
            "columns": ["email"],
            "unique": True,
            "where": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    document = json.loads((bundle / "schema.json").read_text())
    collection = next(c for c in document["collections"] if c["name"] == "users")
    assert "index_users_on_email_lower" not in {
        i["name"] for i in collection["indexes"]
    }


def test_a_null_foreign_key_stays_null(mutable_source):
    """`str(value)` unconditionally would ship the literal string "None" as a record id.

    The fixture has no nullable foreign key, so the row is supplied directly: this is
    the one place the conversion happens, and an unguarded `str()` here is invisible
    everywhere else.
    """
    src, decisions = _decide(mutable_source)
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    connection = _db(mutable_source)
    connection.row_factory = sqlite3.Row
    row = dict(connection.execute("SELECT * FROM posts LIMIT 1").fetchone())
    connection.close()
    assert row["club_id"] is not None, "the fixture row should have a club"

    record = rails2zb.build_record(entry, {**row, "club_id": None})
    assert record["club"] is None, f"a null relation became {record['club']!r}"
    assert rails2zb.build_record(entry, row)["club"] == str(row["club_id"])


def test_a_relation_falls_back_when_the_derived_name_differs_only_in_case(
    mutable_source,
):
    """The existing case test puts the difference on the SCALAR (`Author` beside
    `author_id`); this puts it on the DERIVED candidate."""
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    next(c for c in posts["columns"] if c["name"] == "author_id")["name"] = "Author_id"
    for fk in posts["foreign_keys"]:
        if fk["column"] == "author_id":
            fk["column"] = "Author_id"
    posts["columns"].append(
        {
            "source": "observed",
            "name": "author",
            "sql_type": "varchar",
            "type": "string",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    posts["indexes"] = [i for i in posts["indexes"] if "author_id" not in i["columns"]]
    write_inventory(mutable_source, "schema", schema)
    connection = _db(mutable_source)
    connection.execute('ALTER TABLE posts RENAME COLUMN author_id TO "Author_id"')
    connection.execute("ALTER TABLE posts ADD COLUMN author varchar")
    connection.commit()
    connection.close()

    src, decisions = _decide(mutable_source)
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert posts.field_names["Author_id"] == "Author_id", (
        "`Author` and `author` collide for ZigBase, so the relation keeps its full name"
    )


def test_an_encrypted_foreign_key_is_not_a_relation(mutable_source):
    """Ciphertext never migrates, so an encrypted foreign key emits no field at all.

    An earlier version of this test asserted the column stayed in `relations` — which
    pinned the defect rather than the behaviour: three consumers read that field, and
    with nothing to decide about an encrypted column, believing it wedged the migration.
    """
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post.setdefault("encrypted_attributes", []).append(
        {"source": "observed", "attribute": "club_id"}
    )
    write_inventory(mutable_source, "models", models)
    src, decisions = _decide(mutable_source)
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert "club_id" not in posts.relations, (
        "a skipped column is not a relation; the dangling-name, orphan-value and "
        "manifest-ordering checks all read this"
    )
    assert "club_id" not in posts.field_names
    assert "club" not in {f["name"] for f in posts.fields}
