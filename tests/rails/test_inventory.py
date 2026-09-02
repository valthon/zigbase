"""The inventory must surface every trait that cannot be converted mechanically.

These tests are deliberately specific about *which* findings appear. A converter that
silently stops noticing an encrypted column or a default scope still produces a bundle,
still imports cleanly, and is still wrong — so "some findings were produced" is not a
property worth asserting.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from .conftest import read_inventory, write_inventory
from tools.rails import _core, rails2zb
from tools.rails._core import RailsError, install_file_atomic, sha256_file


def test_hash_reader_has_no_arbitrary_total_size_cap():
    class ApparentlyLargeChunk(bytes):
        def __len__(self):
            return 1024 * 1024 * 1024 + 1

    class Stream:
        chunks = iter((ApparentlyLargeChunk(b"x"), b""))

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def read(self, _size):
            return next(self.chunks)

    class Source:
        def open(self, _mode):
            return Stream()

    assert sha256_file(Source()) == hashlib.sha256(b"x").hexdigest()


def test_install_reports_parent_creation_failure(tmp_path, monkeypatch):
    source = tmp_path / "source"
    source.write_bytes(b"payload")
    destination = tmp_path / "missing" / "destination"
    digest = sha256_file(source)

    def fail_mkdir(_self, *args, **kwargs):
        raise PermissionError("mkdir denied")

    monkeypatch.setattr(Path, "mkdir", fail_mkdir)

    with pytest.raises(RailsError, match="cannot install .*mkdir denied"):
        install_file_atomic(source, destination, digest)


def test_private_directory_creation_translates_os_errors(tmp_path, monkeypatch):
    def fail_mkdir(_self, *args, **kwargs):
        raise PermissionError("mkdir denied")

    monkeypatch.setattr(Path, "mkdir", fail_mkdir)
    with pytest.raises(RailsError, match="cannot prepare private directory.*mkdir denied"):
        _core._private_parent(tmp_path / "private")


def test_install_reports_temporary_file_creation_failure(tmp_path, monkeypatch):
    source = tmp_path / "source"
    source.write_bytes(b"payload")
    destination = tmp_path / "destination"
    digest = sha256_file(source)

    def fail_mkstemp(*args, **kwargs):
        raise PermissionError("temporary file denied")

    monkeypatch.setattr(_core.tempfile, "mkstemp", fail_mkstemp)

    with pytest.raises(RailsError, match="cannot install .*temporary file denied"):
        install_file_atomic(source, destination, digest)


def test_install_hashes_while_copying_and_leaves_no_bad_destination(tmp_path):
    source = tmp_path / "source"
    source.write_bytes(b"payload")
    destination = tmp_path / "destination"

    with pytest.raises(RailsError, match="does not match its recorded digest"):
        install_file_atomic(source, destination, "0" * 64)

    assert not destination.exists()


def test_extract_preflights_output_before_loading_source(tmp_path, monkeypatch):
    (tmp_path / "source").mkdir()

    def refuse(_path):
        raise RailsError("cannot prepare private directory: denied")

    monkeypatch.setattr(rails2zb, "_private_parent", refuse)
    monkeypatch.setattr(
        rails2zb,
        "load_source",
        lambda _path: pytest.fail("source loaded before output preflight"),
    )
    args = SimpleNamespace(
        out=tmp_path / "blocked" / "bundle",
        source=tmp_path / "source",
        decisions=tmp_path / "decisions.json",
    )
    with pytest.raises(RailsError, match="cannot prepare private directory"):
        rails2zb.cmd_extract(args)


def test_extract_rejects_an_output_file_before_loading_source(tmp_path, monkeypatch):
    source = tmp_path / "source"
    source.mkdir()
    output = tmp_path / "bundle"
    output.write_text("not a directory")
    monkeypatch.setattr(
        rails2zb,
        "load_source",
        lambda _path: pytest.fail("source loaded before output preflight"),
    )
    args = SimpleNamespace(
        out=output,
        source=source,
        decisions=tmp_path / "decisions.json",
    )
    with pytest.raises(RailsError, match="must be a directory"):
        rails2zb.cmd_extract(args)

    with pytest.raises(RailsError, match="must be a directory"):
        rails2zb.extract(SimpleNamespace(root=source), {}, output)


def test_extract_rejects_a_dirty_output_before_loading_inputs(tmp_path, monkeypatch):
    source = tmp_path / "source"
    source.mkdir()
    output = tmp_path / "bundle"
    output.mkdir()
    (output / "stale").write_text("stale")
    monkeypatch.setattr(
        rails2zb,
        "load_source",
        lambda _path: pytest.fail("source loaded before output preflight"),
    )
    monkeypatch.setattr(
        rails2zb,
        "load_decisions",
        lambda _path: pytest.fail("decisions loaded before output preflight"),
    )
    args = SimpleNamespace(
        out=output,
        source=source,
        decisions=tmp_path / "decisions.json",
    )
    with pytest.raises(RailsError, match="not empty"):
        rails2zb.cmd_extract(args)


@pytest.fixture(scope="module")
def inventory(source):
    return rails2zb.build_inventory(rails2zb.load_source(source))


@pytest.fixture(scope="module")
def by_id(inventory):
    return {f["id"]: f for f in inventory["findings"]}


def test_source_is_observed_not_inferred(inventory):
    assert inventory["sourceMode"] == "observed"
    assert inventory["railsVersion"] == "8.1.3.1"


@pytest.mark.parametrize(
    ("finding_id", "code", "severity"),
    [
        ("model.Club.default_scope", "DefaultScopeHidesRows", "blocker"),
        ("model.User.encrypted.phone", "EncryptedAttributeCannotMigrate", "blocker"),
        ("model.Event.sti", "SingleTableInheritance", "blocker"),
        ("association.Flag.flaggable.polymorphic", "PolymorphicAssociation", "blocker"),
        ("schema.view.published_post_counts", "DatabaseView", "blocker"),
        ("model.Notification.serialized.payload", "SerializedAttribute", "decision"),
    ],
)
def test_fidelity_boundaries_are_reported(by_id, finding_id, code, severity):
    assert finding_id in by_id, f"{finding_id} disappeared from the inventory"
    assert by_id[finding_id]["code"] == code
    assert by_id[finding_id]["severity"] == severity


def test_every_trigger_is_reported(by_id):
    triggers = {k for k in by_id if k.startswith("schema.trigger.")}
    assert triggers == {
        "schema.trigger.posts_count_after_club_change",
        "schema.trigger.posts_count_after_delete",
        "schema.trigger.posts_count_after_insert",
    }


def test_default_scope_hidden_rows_are_counted(inventory):
    """The archived club is invisible to the model and must still be visible here."""
    clubs = next(c for c in inventory["collections"] if c["table"] == "clubs")
    assert clubs["rows"] == 3
    assert clubs["rowsHiddenByDefaultScope"] == 1


def test_rails_internal_tables_are_not_collections(inventory):
    tables = {c["table"] for c in inventory["collections"]}
    assert tables == {
        "clubs",
        "comments",
        "events",
        "flags",
        "memberships",
        "notifications",
        "posts",
        "users",
    }
    assert not any(t.startswith("active_storage_") for t in tables)
    assert "schema_migrations" not in tables


def test_framework_generated_validators_are_not_reported_as_code(by_id):
    """`belongs_to_required_by_default` synthesizes a conditional presence validator for
    every association. Reporting those buries the ones a human wrote."""
    conditional = {k for k in by_id if k.startswith("validator.")}
    assert conditional == {"validator.Post.body.presence"}
    assert "published?" in by_id["validator.Post.body.presence"]["message"]


def test_access_rules_are_never_inferred(by_id, inventory):
    """Every collection must force an explicit rule decision."""
    tables = {c["table"] for c in inventory["collections"]}
    assert {f"table.{t}.rules" for t in tables} <= set(by_id)


def test_bcrypt_credentials_are_recognized_without_devise(by_id):
    assert "auth.mechanism.unknown" not in by_id
    assert "auth.devise.pepper" not in by_id
    assert "auth.omniauth.identities" not in by_id


def test_created_at_without_updated_at_is_reported(by_id):
    finding = by_id["table.notifications.updated_at"]
    assert finding["severity"] == "info"
    assert finding["code"] == "NoUpdatedAtColumn"


def test_inventory_exit_code_signals_judgment_required(source, tmp_path):
    out = tmp_path / "findings.json"
    code = rails2zb.main(
        ["inventory", "--source", str(source), "--out", str(out)],
    )
    assert code == 2, "a source with findings must exit 2, not 0"
    assert json.loads(out.read_text())["summary"]["blockers"] > 0


# ---------------------------------------------------------------------------
# The observed/inferred boundary
# ---------------------------------------------------------------------------


def test_a_mixed_inventory_is_refused(mutable_source):
    """One inferred record in an observed inventory would let a guess ride along."""
    models = read_inventory(mutable_source, "models")
    models["source"] = "inferred"
    write_inventory(mutable_source, "models", models)
    with pytest.raises(RailsError, match="must not be mixed"):
        rails2zb.load_source(mutable_source)


def test_an_inferred_inventory_is_itself_a_blocker(mutable_source):
    from .conftest import set_mode_everywhere

    for name in rails2zb.INVENTORY_FILES:
        payload = set_mode_everywhere(read_inventory(mutable_source, name), "inferred")
        write_inventory(mutable_source, name, payload)
    findings = rails2zb.build_findings(rails2zb.load_source(mutable_source))
    blocker = next(f for f in findings if f.id == "source.inferred")
    assert blocker.severity == "blocker"


def test_an_unknown_source_mode_is_refused(mutable_source):
    from .conftest import set_mode_everywhere

    for name in rails2zb.INVENTORY_FILES:
        payload = set_mode_everywhere(read_inventory(mutable_source, name), "inferred")
        payload["source"] = "assumed"
        write_inventory(mutable_source, name, payload)
    with pytest.raises(RailsError, match="observed"):
        rails2zb.load_source(mutable_source)


@pytest.mark.parametrize("bad_source", [[], {}, 7, None])
def test_a_non_string_source_mode_is_refused_cleanly(mutable_source, bad_source):
    schema = read_inventory(mutable_source, "schema")
    schema["source"] = bad_source
    write_inventory(mutable_source, "schema", schema)
    with pytest.raises(RailsError, match="does not declare source"):
        rails2zb.load_source(mutable_source)


def test_nested_source_named_application_data_is_not_provenance(mutable_source):
    models = read_inventory(mutable_source, "models")
    model = models["models"][0]
    model["source"] = "assumed"
    model["enums"] = {"source": {"web": 0}}
    model["defaults"] = {"source": "web"}
    model["constraints"] = {
        "source": {"type": "regexp", "source": "csv|json", "options": ""}
    }
    write_inventory(mutable_source, "models", models)

    assert rails2zb.load_source(mutable_source).mode == "observed"


def test_an_incomplete_inventory_is_refused(mutable_source):
    (mutable_source / "inventory" / "auth.json").unlink()
    with pytest.raises(RailsError, match="incomplete"):
        rails2zb.load_source(mutable_source)


# ---------------------------------------------------------------------------
# Fidelity gaps: things captured by the extractor but dropped on the way out
# ---------------------------------------------------------------------------


def test_column_defaults_raise_a_decision(by_id):
    """Imported rows keep their values; writes after cutover lose the default."""
    finding = by_id["column.users.role.default"]
    assert finding["code"] == "ColumnDefaultNotReproduced"
    assert "0" in finding["message"]


def test_every_defaulted_column_is_reported(by_id, inventory):
    reported = {k for k in by_id if k.startswith("column.") and k.endswith(".default")}
    assert reported == {
        "column.clubs.posts_count.default",
        "column.clubs.visibility.default",
        "column.memberships.role.default",
        "column.notifications.payload.default",
        "column.posts.status.default",
        "column.users.role.default",
    }


def test_an_unreadable_catalog_is_a_blocker_not_an_empty_list(mutable_source):
    """On Postgres the extractor cannot read triggers; [] there means UNKNOWN."""
    from .conftest import read_inventory, write_inventory

    schema = read_inventory(mutable_source, "schema")
    schema["catalog_supported"] = False
    schema["triggers"] = []
    schema["views"] = []
    write_inventory(mutable_source, "schema", schema)

    findings = rails2zb.build_findings(rails2zb.load_source(mutable_source))
    blocker = next(f for f in findings if f.id == "schema.catalog.unsupported")
    assert blocker.severity == "blocker"


def test_a_check_constraint_raises_a_blocker(mutable_source):
    from .conftest import read_inventory, write_inventory

    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    users["check_constraints"] = [
        {"source": "observed", "name": "role_range", "expression": "role >= 0"}
    ]
    write_inventory(mutable_source, "schema", schema)

    ids = {f.id for f in rails2zb.build_findings(rails2zb.load_source(mutable_source))}
    assert "constraint.users.role_range" in ids


def test_unreadable_check_constraints_are_not_read_as_none(mutable_source):
    from .conftest import read_inventory, write_inventory

    schema = read_inventory(mutable_source, "schema")
    next(t for t in schema["tables"] if t["name"] == "users")["check_constraints"] = (
        None
    )
    write_inventory(mutable_source, "schema", schema)

    ids = {f.id for f in rails2zb.build_findings(rails2zb.load_source(mutable_source))}
    assert "table.users.check_constraints" in ids


def test_on_delete_cascade_reaches_the_relation(mutable_source):
    """A source cascade must survive, not be flattened to False."""
    from .conftest import read_inventory, write_inventory
    from .conftest import decisions_for

    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    next(f for f in posts["foreign_keys"] if f["column"] == "club_id")["on_delete"] = (
        "cascade"
    )
    write_inventory(mutable_source, "schema", schema)

    src = rails2zb.load_source(mutable_source)
    decisions = rails2zb.load_decisions_from_value(
        decisions_for([f.to_dict() for f in rails2zb.build_findings(src)])
    )
    mapped = next(m for m in rails2zb.map_tables(src, decisions) if m.table == "posts")
    club = next(f for f in mapped.fields if f["name"] == "club")
    assert club["options"]["cascadeDelete"] is True


def test_an_unsupported_foreign_key_action_is_a_blocker(mutable_source):
    from .conftest import read_inventory, write_inventory

    schema = read_inventory(mutable_source, "schema")
    posts = next(t for t in schema["tables"] if t["name"] == "posts")
    next(f for f in posts["foreign_keys"] if f["column"] == "club_id")["on_delete"] = (
        "nullify"
    )
    write_inventory(mutable_source, "schema", schema)

    ids = {f.id for f in rails2zb.build_findings(rails2zb.load_source(mutable_source))}
    assert "fk.posts.club_id.action" in ids


def test_a_legacy_inventory_without_the_catalog_key_still_blocks(mutable_source):
    """An older extractor recorded no `catalog_supported`; silence is not consent."""
    from .conftest import read_inventory, write_inventory

    schema = read_inventory(mutable_source, "schema")
    del schema["catalog_supported"]
    schema["triggers"] = []
    schema["views"] = []
    write_inventory(mutable_source, "schema", schema)

    ids = {f.id for f in rails2zb.build_findings(rails2zb.load_source(mutable_source))}
    assert "schema.catalog.unsupported" in ids


def test_two_unnamed_check_constraints_get_distinct_ids(mutable_source):
    """Both collapsing to `constraint.<table>.None` would let one decision cover two."""
    from .conftest import read_inventory, write_inventory

    schema = read_inventory(mutable_source, "schema")
    users = next(t for t in schema["tables"] if t["name"] == "users")
    users["check_constraints"] = [
        {"source": "observed", "name": None, "expression": "role >= 0"},
        {"source": "observed", "name": None, "expression": "length(email) > 3"},
    ]
    write_inventory(mutable_source, "schema", schema)

    ids = [
        f.id
        for f in rails2zb.build_findings(rails2zb.load_source(mutable_source))
        if f.id.startswith("constraint.users.")
    ]
    assert len(ids) == 2 and len(set(ids)) == 2, ids


def test_duplicate_finding_ids_are_refused(source):
    """A collision would let one decision silently answer two different findings."""
    from tools.rails._core import Finding

    dupe = Finding("x.y", "blocker", "Code", "message", ("omit",))
    with pytest.raises(RailsError, match="duplicate finding id"):
        rails2zb._reject_duplicate_ids([dupe, dupe])


def test_a_hook_decision_must_name_its_implementation(source):
    """`hook` asserts something was built; recording one with no artifact documents a
    migration nobody performed."""
    from .conftest import decisions_for

    src = rails2zb.load_source(source)
    findings = rails2zb.build_findings(src)
    value = decisions_for([f.to_dict() for f in findings])
    value["decisions"] = [
        (
            {k: v for k, v in d.items() if k != "artifact"}
            if d["id"] == "column.users.role.default"
            else d
        )
        for d in value["decisions"]
    ]
    with pytest.raises(RailsError, match="asserts a replacement exists"):
        rails2zb.reconcile(findings, rails2zb.load_decisions_from_value(value))


# ---------------------------------------------------------------------------
# Extractor ↔ fixture contract
#
# CI never installs Ruby, so `export_source.rb` is the one component in this pull
# request that no test executes. A change there that renames or adds an output would
# leave the frozen fixture describing a shape the extractor no longer produces, and
# every test here would stay green while a real operator got an inventory the converter
# mishandles. This reads the extractor's own output map statically and ties the three
# records — extractor, freeze manifest, fixture — to each other.


def _extractor_source() -> str:
    from .conftest import REPO

    return (REPO / "tools" / "rails" / "export_source.rb").read_text(encoding="utf-8")


def _extractor_outputs() -> set[str]:
    """The filenames `export_source.rb` writes, read from its output map."""
    import re

    return set(re.findall(r'"([A-Za-z0-9_]+\.json)"\s*=>', _extractor_source()))


def test_the_extractor_writes_its_outputs_only_through_the_map(fixture_root):
    """The map is the single write site, which is what makes reading it sufficient.

    `_extractor_outputs` reads the `written` hash. That covers the extractor only while
    every output goes through it — a later `write_json(out, "extra.json", …)` called
    directly would be a real output that the guard below could not see, and its absence
    from the frozen fixture would go unnoticed for want of Ruby in CI.
    """
    import re

    source = _extractor_source()
    # Two checks, because the precise one has a blind spot. A paren-less call —
    # `write_json out, "extra.json", data`, ordinary Ruby style and therefore the
    # likely form of a future direct write — is invisible to a regex anchored on `(`,
    # and so is `send(:write_json, ...)`. Counting bare occurrences catches both, at
    # the cost of also tripping on a comment that mentions the name, which is the loud
    # direction and a one-line fix.
    assert len(re.findall(r"\bwrite_json\b", source)) == 2, (
        "write_json is named somewhere other than its definition and the single call "
        "that iterates the output map"
    )
    # `(?<!def )` so the definition itself is not counted as a call site.
    calls = re.findall(r"(?<!def )write_json\(([^)]*)\)", source)
    assert calls == ["out, name, payload"], (
        f"write_json is called somewhere other than the output map: {calls}"
    )


def test_the_extractor_writes_exactly_what_the_freeze_manifest_records(fixture_root):
    freeze = json.loads((fixture_root / "freeze.json").read_text(encoding="utf-8"))
    recorded = set(freeze["extractor"]["outputs"])
    written = _extractor_outputs()
    assert written, "the output map could not be read; this guard would pass vacuously"
    assert written == recorded, (
        f"the extractor writes {sorted(written)} but the fixture was frozen from one "
        f"that wrote {sorted(recorded)}; regenerate the fixture "
        f"(tools/rails/regenerate_fixture.py) or correct freeze.json"
    )


def test_the_frozen_inventory_holds_exactly_those_files(fixture_root):
    freeze = json.loads((fixture_root / "freeze.json").read_text(encoding="utf-8"))
    on_disk = {p.name for p in (fixture_root / "inventory").glob("*.json")}
    assert on_disk == set(freeze["extractor"]["outputs"]), (
        f"the frozen inventory holds {sorted(on_disk)}, which is not what the manifest "
        f"says the extractor produced"
    )
