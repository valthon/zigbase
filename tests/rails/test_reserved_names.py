"""Field names the ZigBase engine owns.

`schema apply` DROPS a field whose name is reserved rather than refusing it
(src/schema.zig `isSystemFieldName`, and the parse path at the `freeFieldOwned` branch),
and the importer then discards that column's values while reporting success. So a
`contacts.email` column -- an utterly ordinary Rails column -- migrated to nothing, with
a clean exit status at every step and a bundle attesting the data was converted.

These names are therefore a decision, never something the converter emits and hopes for.
"""

from __future__ import annotations

import json
import sqlite3

import pytest

from .conftest import decisions_for, read_inventory, write_inventory
from tools.rails import rails2zb
from tools.rails._core import finding_id


def _add_column(source, table, name, value, type_="string", sql_type="varchar"):
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
    connection = sqlite3.connect(next((source / "db").glob("*.sqlite3")))
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


def _findings(source, code):
    src = rails2zb.load_source(source)
    return [f for f in rails2zb.build_findings(src) if f.code == code]


# ---------------------------------------------------------------------------
# A reserved name on an ordinary table is a decision
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "name", ["email", "username", "verified", "created", "updated"]
)
def test_a_reserved_column_on_a_base_table_raises_a_finding(mutable_source, name):
    _add_column(mutable_source, "posts", name, "value")
    found = _findings(mutable_source, "ReservedFieldName")
    assert [f.id for f in found] == [finding_id("column", "posts", name, "reserved")], (
        f"{name} must be decided, not silently dropped by the target"
    )
    assert found[0].choices == ("rename", "omit")


def test_the_check_is_case_insensitive(mutable_source):
    """SQLite column names collide case-insensitively, and so does ZigBase's check."""
    _add_column(mutable_source, "posts", "EMail", "value")
    assert [f.id for f in _findings(mutable_source, "ReservedFieldName")] == [
        finding_id("column", "posts", "EMail", "reserved")
    ]


def test_a_column_named_for_an_engine_field_must_be_decided(mutable_source, workspace):
    """The targeted semantics: `rename` keeps the data under a name that survives."""
    _add_column(mutable_source, "posts", "email", "ada@example.com")
    fid = finding_id("column", "posts", "email", "reserved")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "contactEmail")})
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)

    document = json.loads((bundle / "schema.json").read_text())
    posts = next(c for c in document["collections"] if c["name"] == "posts")
    names = {f["name"] for f in posts["fields"]}
    assert "contactEmail" in names and "email" not in names

    rows = [
        json.loads(line)
        for line in (bundle / "data" / "posts.ndjson").read_text().splitlines()
    ]
    assert all(row["contactEmail"] == "ada@example.com" for row in rows)


def test_a_reserved_column_can_be_omitted_instead(mutable_source):
    _add_column(mutable_source, "posts", "email", "ada@example.com")
    fid = finding_id("column", "posts", "email", "reserved")
    src, decisions = _decide(mutable_source, **{fid: ("omit", None)})
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert "email" not in {f["name"] for f in posts.fields}


def test_an_undecided_reserved_name_is_refused_rather_than_emitted(mutable_source):
    """The backstop: nothing may reach the schema document under an engine-owned name."""
    _add_column(mutable_source, "posts", "email", "ada@example.com")
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    value["decisions"] = [
        d
        for d in value["decisions"]
        if d["id"] != finding_id("column", "posts", "email", "reserved")
    ]
    decisions = rails2zb.load_decisions_from_value(value)
    with pytest.raises(rails2zb.RailsError, match="the ZigBase engine owns"):
        rails2zb.map_tables(src, decisions)


# ---------------------------------------------------------------------------
# An auth collection legitimately carries three of them
# ---------------------------------------------------------------------------


def test_an_auth_table_may_keep_its_email_column(source):
    """`users.email` is exactly what an auth collection is for; a finding would be noise."""
    assert not [
        f
        for f in _findings(source, "ReservedFieldName")
        if f.id.startswith("column.users.")
    ]


def test_the_auth_email_value_still_reaches_the_import(source, workspace):
    src, decisions = _decide(source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    rows = [
        json.loads(line)
        for line in (bundle / "auth" / "users.ndjson").read_text().splitlines()
    ]
    assert rows and all("@" in row["email"] for row in rows)


def test_the_auth_schema_does_not_redeclare_engine_fields(source, workspace):
    """The engine injects them. Declaring them again relies on `apply` dropping the
    duplicate silently -- a leniency the bundle must not depend on."""
    src, decisions = _decide(source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    document = json.loads((bundle / "schema.json").read_text())
    users = next(c for c in document["collections"] if c["name"] == "users")
    assert users["type"] == "auth"
    declared = {f["name"].lower() for f in users["fields"]}
    assert not declared & {"email", "username", "verified"}


def test_an_engine_owned_name_is_reserved_even_on_an_auth_table(mutable_source):
    """`email` is data on an auth collection; `passwordHash` never is."""
    _add_column(mutable_source, "users", "passwordHash", "x")
    assert [f.id for f in _findings(mutable_source, "ReservedFieldName")] == [
        finding_id("column", "users", "passwordHash", "reserved")
    ]


# ---------------------------------------------------------------------------
# Renaming ONTO a reserved name
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("target", ["id", "created", "updated", "email"])
def test_a_rename_onto_an_engine_field_is_refused(mutable_source, target):
    """Renaming to `id` replaced every record's primary id with the column's data.

    The rename gate checked the charset only, so these were accepted and the corruption
    happened in the NDJSON -- before `schema apply` ever had a chance to object.
    """
    _add_column(mutable_source, "posts", "legacy.value", "EVIL")
    fid = finding_id("column", "posts", "legacy.value", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", target)})
    with pytest.raises(rails2zb.RailsError, match="not a usable ZigBase field name"):
        rails2zb.map_tables(src, decisions)


def test_renaming_onto_passwordhash_is_refused_on_an_auth_table(mutable_source):
    _add_column(mutable_source, "users", "legacy.value", "EVIL")
    fid = finding_id("column", "users", "legacy.value", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "passwordHash")})
    with pytest.raises(rails2zb.RailsError, match="not a usable ZigBase field name"):
        rails2zb.map_tables(src, decisions)


def test_renaming_onto_email_is_allowed_on_an_auth_table(mutable_source):
    """The auth import maps it, so this one is a legitimate destination."""
    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    next(c for c in users["columns"] if c["name"] == "email")["name"] = "email_address"
    write_inventory(mutable_source, "schema", schema)
    connection = sqlite3.connect(next((mutable_source / "db").glob("*.sqlite3")))
    connection.execute("ALTER TABLE users RENAME COLUMN email TO email_address")
    connection.commit()
    connection.close()
    _add_column(mutable_source, "users", "legacy.value", "x")
    fid = finding_id("column", "users", "legacy.value", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "email")})
    users = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "users")
    assert "email" in {f["name"] for f in users.fields}


# ---------------------------------------------------------------------------
# Collection names
# ---------------------------------------------------------------------------


def test_a_table_whose_name_ends_in_fts_raises_a_finding(mutable_source):
    """A searchable collection provisions a `<name>_fts` shadow table."""
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["name"] = "events_fts"
    write_inventory(mutable_source, "schema", schema)
    ids = {f.id for f in _findings(mutable_source, "TableNameRejected")}
    assert finding_id("table", "events_fts", "identifier") in ids


def test_renaming_a_table_onto_the_fts_suffix_is_refused(mutable_source):
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["name"] = "events-legacy"
    write_inventory(mutable_source, "schema", schema)
    fid = finding_id("table", "events-legacy", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "events_fts")})
    with pytest.raises(
        rails2zb.RailsError, match="not a usable ZigBase collection name"
    ):
        rails2zb.map_tables(src, decisions)


# ---------------------------------------------------------------------------
# A DERIVED name never inherits the auth exemption
# ---------------------------------------------------------------------------


def _fk_column(source, table, column, to_table="clubs", type_="integer"):
    """Give `table` a foreign key whose stripped name lands on a reserved word.

    `type_` matters: a string key (a uuid key, say) is type-compatible with `email`, so
    it isolates the RELATION rule from the type rule -- an integer key is refused by the
    type rule alone, which would mask whether the relation rule works at all.
    """
    schema = read_inventory(source, "schema")
    entry = next(t for t in schema["tables"] if t["name"] == table)
    entry["columns"].append(
        {
            "source": "observed",
            "name": column,
            "sql_type": type_,
            "type": type_,
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
    connection.execute(f'ALTER TABLE "{table}" ADD COLUMN "{column}" {type_}')
    connection.execute(f'UPDATE "{table}" SET "{column}" = 1')
    connection.commit()
    connection.close()


@pytest.mark.parametrize("column", ["verified_id", "username_id", "email_id"])
def test_a_relation_on_an_auth_table_never_claims_an_engine_name(
    mutable_source, workspace, column
):
    """`verified_id` is a foreign key, not the auth `verified` flag.

    Keying the exemption on the RESOLVED name let the relation claim it: the field was
    then filtered out of the declared schema, every record carried a target id under a
    key the engine reads as a boolean (src/import.zig ignores a non-bool `verified`),
    and the linkage was lost end to end with a clean exit at every step.
    """
    _fk_column(mutable_source, "users", column)
    src, decisions = _decide(mutable_source)
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "users")
    assert entry.field_names[column] == column, (
        "the relation must keep its full column name, not the engine's"
    )
    relation = next(f for f in entry.fields if f["name"] == column)
    assert relation["type"] == "relation"

    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    document = json.loads((bundle / "schema.json").read_text())
    users = next(c for c in document["collections"] if c["name"] == "users")
    assert column in {f["name"] for f in users["fields"]}, (
        "the relation must survive into the declared schema"
    )
    rows = [
        json.loads(line)
        for line in (bundle / "auth" / "users.ndjson").read_text().splitlines()
    ]
    assert all(row[column] for row in rows)
    assert all(row.get("verified") is None for row in rows), (
        "nothing may smuggle a relation id into the engine's `verified`"
    )


def test_a_relation_literally_named_for_an_engine_field_raises_a_finding(
    mutable_source,
):
    """No `_id` to strip, so there is no fallback -- it has to be a decision."""
    _fk_column(mutable_source, "users", "verified")
    found = _findings(mutable_source, "ReservedFieldName")
    assert [f.id for f in found] == [
        finding_id("column", "users", "verified", "reserved")
    ]


def test_a_derived_name_on_a_base_table_falls_back_instead_of_dead_ending(
    mutable_source, workspace
):
    """`posts.email_id` raised no finding and then refused at extract time, telling the
    operator to record a decision that `reconcile` would reject as unknown."""
    _fk_column(mutable_source, "posts", "email_id", to_table="users")
    src, decisions = _decide(mutable_source)
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert entry.field_names["email_id"] == "email_id"
    rails2zb.extract(src, decisions, workspace / "bundle")


def test_an_attachment_named_for_an_engine_field_must_be_decided(mutable_source):
    """An attachment has no second name of its own — but once a rename is carried
    through to the emitted schema, the operator can keep the data instead."""
    models = read_inventory(mutable_source, "models")
    post = next(m for m in models["models"] if m["name"] == "Post")
    post["attachments"].append(
        {"source": "observed", "name": "email", "macro": "has_one_attached"}
    )
    write_inventory(mutable_source, "models", models)
    found = _findings(mutable_source, "ReservedFieldName")
    assert [f.id for f in found] == [
        finding_id("attachment", "posts", "email", "reserved")
    ]
    # Once a rename is carried through to the emitted schema, the operator can keep the
    # attachment's data instead of losing it.
    assert found[0].choices == ("rename", "omit")

    src, decisions = _decide(mutable_source, **{found[0].id: ("omit", None)})
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert "email" not in {f["name"] for f in posts.fields}

    src, decisions = _decide(mutable_source, **{found[0].id: ("rename", "coverEmail")})
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert "coverEmail" in {f["name"] for f in posts.fields}


def test_an_auth_identity_column_travels_under_the_engines_spelling(
    mutable_source, workspace
):
    """The engine matches record keys with `std.mem.eql`, so `Email` never arrives."""
    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    next(c for c in users["columns"] if c["name"] == "email")["name"] = "Email"
    write_inventory(mutable_source, "schema", schema)
    connection = sqlite3.connect(next((mutable_source / "db").glob("*.sqlite3")))
    connection.execute('ALTER TABLE users RENAME COLUMN email TO "Email"')
    connection.commit()
    connection.close()

    src, decisions = _decide(mutable_source)
    bundle = workspace / "bundle"
    rails2zb.extract(src, decisions, bundle)
    rows = [
        json.loads(line)
        for line in (bundle / "auth" / "users.ndjson").read_text().splitlines()
    ]
    assert rows and all("@" in row["email"] for row in rows), (
        f"the auth identity must travel as `email`: {sorted(rows[0])}"
    )
    assert all("Email" not in row for row in rows)


@pytest.mark.parametrize("name", ["tokenKey", "token_epoch", "passwordHash"])
def test_engine_owned_names_are_reserved_on_an_auth_table_too(mutable_source, name):
    _add_column(mutable_source, "users", name, "x")
    assert [f.id for f in _findings(mutable_source, "ReservedFieldName")] == [
        finding_id("column", "users", name, "reserved")
    ]


@pytest.mark.parametrize(
    ("name", "type_", "value"),
    [
        ("email", "string", "ada@example.com"),
        ("username", "string", "ada"),
        ("verified", "boolean", 1),
    ],
)
def test_the_three_mapped_names_stay_exempt_on_an_auth_table(
    mutable_source, name, type_, value
):
    """These are what an auth collection is FOR; a finding here would be noise."""
    if name != "email":  # `email` is already present in the fixture
        _add_column(mutable_source, "users", name, value, type_=type_, sql_type=type_)
    assert not [
        f
        for f in _findings(mutable_source, "ReservedFieldName")
        if f.id == finding_id("column", "users", name, "reserved")
    ]


@pytest.mark.parametrize("type_", ["integer", "string", "datetime"])
def test_an_auth_name_carrying_the_wrong_type_is_not_exempt(mutable_source, type_):
    """The engine reads `verified` only as a boolean (src/import.zig).

    An integer `verified` -- a counter, a foreign key, a Rails enum -- travelled under
    that key and was then silently ignored: the same loss as the name collision, one
    layer down.
    """
    _add_column(mutable_source, "users", "verified", 1, type_=type_, sql_type=type_)
    assert [f.id for f in _findings(mutable_source, "ReservedFieldName")] == [
        finding_id("column", "users", "verified", "reserved")
    ]


def test_a_model_with_both_auth_stacks_is_refused(mutable_source):
    """Two credentials, one login: as unknowable as two digests, and it was guessed."""
    auth = read_inventory(mutable_source, "auth")
    auth["devise"] = {
        "present": True,
        "pepper_configured": False,
        "models": [{"source": "observed", "model": "User", "table_name": "users"}],
    }
    write_inventory(mutable_source, "auth", auth)
    with pytest.raises(rails2zb.RailsError, match="carries both"):
        rails2zb._auth_tables(rails2zb.load_source(mutable_source))


def test_a_table_keyed_by_a_reserved_name_is_not_double_reported(mutable_source):
    """The primary key never becomes a field, so it is the other finding's business."""
    _add_column(mutable_source, "events", "email", "someone@example.com")
    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "events")["primary_key"] = "email"
    write_inventory(mutable_source, "schema", schema)
    src = rails2zb.load_source(mutable_source)
    codes = {f.code for f in rails2zb.build_findings(src) if ".events." in f.id}
    assert "NonStandardPrimaryKey" in codes
    assert "ReservedFieldName" not in codes


def test_a_relation_falls_back_when_the_collision_differs_only_in_case(mutable_source):
    """`Author` beside `author_id`: the collision is real to SQLite and to ZigBase."""
    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    posts["columns"].append(
        {
            "source": "observed",
            "name": "Author",
            "sql_type": "varchar",
            "type": "string",
            "null": True,
            "default": None,
            "default_function": None,
        }
    )
    write_inventory(mutable_source, "schema", schema)
    src, decisions = _decide(mutable_source)
    posts = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    assert posts.field_names["author_id"] == "author_id", (
        "stripping `_id` must not collide case-insensitively with `Author`"
    )


# ---------------------------------------------------------------------------
# The two routes that bypassed the derived-name rule
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("target", ["verified", "email", "username"])
def test_a_relation_cannot_be_RENAMED_onto_an_engine_field(mutable_source, target):
    """A renamed relation is still a relation.

    The rename gate checked the replacement against the SCALAR rule, so the corruption
    the derived-name rule exists to prevent could be re-entered through a decision the
    operator was invited to record.
    """
    _fk_column(mutable_source, "users", "legacy.ref")
    fid = finding_id("column", "users", "legacy.ref", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", target)})
    with pytest.raises(rails2zb.RailsError, match="not a usable ZigBase field name"):
        rails2zb.map_tables(src, decisions)


def test_a_belongs_to_without_a_database_key_still_counts_as_a_relation(mutable_source):
    """Both branches of the resulting finding were broken.

    `relation` dead-ended at extract naming a decision `reconcile` rejects as unknown,
    and `omit` shipped the raw foreign-key integer under the engine's boolean key.
    """
    _add_column(
        mutable_source, "users", "verified", 1, type_="integer", sql_type="integer"
    )
    models = read_inventory(mutable_source, "models")
    user = next(m for m in models["models"] if m["name"] == "User")
    user["associations"].append(
        {
            "source": "observed",
            "name": "verified",
            "macro": "belongs_to",
            "table_name": "clubs",
            "foreign_key": "verified",
            "dependent": None,
            "polymorphic": False,
            "through": None,
            "class_name": "Club",
        }
    )
    write_inventory(mutable_source, "models", models)
    assert finding_id("column", "users", "verified", "reserved") in {
        f.id for f in _findings(mutable_source, "ReservedFieldName")
    }, "the column must be actionable, whichever way the association is decided"


def test_a_derived_name_differing_only_in_case_still_falls_back(mutable_source):
    """`Verified_id` strips to `Verified`, which the engine owns just the same."""
    _fk_column(mutable_source, "users", "Verified_id")
    src, decisions = _decide(mutable_source)
    entry = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "users")
    assert entry.field_names["Verified_id"] == "Verified_id"


def test_a_reserved_attachment_on_an_auth_table_is_also_a_finding(mutable_source):
    """An attachment is never the auth collection's identity, whatever it is called."""
    models = read_inventory(mutable_source, "models")
    user = next(m for m in models["models"] if m["name"] == "User")
    user.setdefault("attachments", []).append(
        {"source": "observed", "name": "verified", "macro": "has_one_attached"}
    )
    write_inventory(mutable_source, "models", models)
    assert [f.id for f in _findings(mutable_source, "ReservedFieldName")] == [
        finding_id("attachment", "users", "verified", "reserved")
    ]


def test_a_type_compatible_relation_still_cannot_be_renamed_onto_an_engine_field(
    mutable_source,
):
    """Isolates the relation rule: a string key is a legal `email` as far as TYPE goes.

    With an integer key the type rule refuses first and the relation rule is never
    exercised -- which is precisely how this route stayed open.
    """
    _fk_column(mutable_source, "users", "legacy.ref", type_="string")
    fid = finding_id("column", "users", "legacy.ref", "identifier")
    src, decisions = _decide(mutable_source, **{fid: ("rename", "email")})
    with pytest.raises(rails2zb.RailsError, match="not a usable ZigBase field name"):
        rails2zb.map_tables(src, decisions)


def _belongs_to_without_key(
    source, table, model_name, column, type_="string", add_column=True
):
    if add_column:
        _add_column(source, table, column, "x", type_=type_, sql_type=type_)
    models = read_inventory(source, "models")
    model = next(m for m in models["models"] if m["name"] == model_name)
    model["associations"].append(
        {
            "source": "observed",
            "name": f"{column}_owner",
            "macro": "belongs_to",
            "table_name": "clubs",
            "foreign_key": column,
            "dependent": None,
            "polymorphic": False,
            "through": None,
            "class_name": "Club",
        }
    )
    write_inventory(source, "models", models)


def test_a_type_compatible_belongs_to_column_is_still_not_exempt(mutable_source):
    """A string `email` column that is really a foreign key: type says fine, role says no."""
    # The fixture's `users.email` is already a string column: declaring a belongs_to on
    # it is what turns it from the collection's identity into a foreign key.
    _belongs_to_without_key(mutable_source, "users", "User", "email", add_column=False)
    assert finding_id("column", "users", "email", "reserved") in {
        f.id for f in _findings(mutable_source, "ReservedFieldName")
    }


def test_a_declared_relation_cannot_be_renamed_onto_an_engine_field(mutable_source):
    """`_relation_columns` must count the relations an operator DECIDED, too."""
    _belongs_to_without_key(mutable_source, "users", "User", "legacy.ref")
    src = rails2zb.load_source(mutable_source)
    findings = rails2zb.build_findings(src)
    association = next(
        f
        for f in findings
        if f.code == "AssociationWithoutForeignKey" and "legacy" in f.id
    )
    value = decisions_for([f.to_dict() for f in findings])
    for entry in value["decisions"]:
        if entry["id"] == association.id:
            entry["choice"] = "relation"
        if entry["id"] == finding_id("column", "users", "legacy.ref", "identifier"):
            entry["choice"] = "rename"
            entry["artifact"] = "email"
    decisions = rails2zb.load_decisions_from_value(value)
    with pytest.raises(rails2zb.RailsError, match="not a usable ZigBase field name"):
        rails2zb.map_tables(src, decisions)
