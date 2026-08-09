"""End-to-end coverage for `zigbase schema dump` / `zigbase schema apply`.

Drives the REAL CLI against a REAL data dir: a genuine boot (migrations + provisioning),
then verifies the resulting physical schema by opening the SQLite file directly. No browser
needed — subprocess + sqlite3 + json only.

The load-bearing property is the ROUND TRIP: dump -> apply must be a no-op. If it is not,
every migration built on this machinery drifts.

Stdout keys from `schema apply`/`schema dump --json` are snake_case (e.g. `dry_run`,
`apply_order`) — that's the settled convention for everything the CLI PRINTS. The schema
document FILE format (what `write_doc`/`doc`/`collection`/`field` build below) stays
camelCase (`zigbaseSchema`, `listRule`, ...) since it round-trips through `schema.zig`'s
JSON (de)serialization. Do not mix the two up.
"""
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import tempfile

import pytest


@pytest.fixture()
def data_dir():
    d = tempfile.mkdtemp(prefix="zb_schema_cli_")
    yield d
    shutil.rmtree(d, ignore_errors=True)


def run(binary, data, *args):
    return subprocess.run(
        [binary, *args, "--data-dir", data],
        env={**os.environ, "ZIGBASE_DATA_DIR": data},
        capture_output=True,
        text=True,
    )


def write_doc(data, name, doc):
    p = os.path.join(data, name)
    pathlib.Path(p).write_text(json.dumps(doc))
    return p


def field(name, ftype="text", **kw):
    f = {"id": "", "name": name, "type": ftype}
    f.update(kw)
    return f


def collection(name, fields, **kw):
    c = {
        "name": name, "type": "base", "fields": fields, "indexes": [],
        "listRule": None, "viewRule": None, "createRule": None,
        "updateRule": None, "deleteRule": None, "options": {},
    }
    c.update(kw)
    return c


def doc(*cols):
    return {"zigbaseSchema": 1, "collections": list(cols)}


def columns(data, table):
    con = sqlite3.connect(os.path.join(data, "data.db"))
    try:
        return [r[1] for r in con.execute(f'PRAGMA table_info("{table}")').fetchall()]
    finally:
        con.close()


def indexes(data, table):
    """{index name: is_unique} straight from SQLite, so the assertion is about the physical
    index rather than about what `_collections` claims."""
    con = sqlite3.connect(os.path.join(data, "data.db"))
    try:
        return {r[1]: bool(r[2]) for r in con.execute(f'PRAGMA index_list("{table}")').fetchall()}
    finally:
        con.close()


def test_apply_creates_collections_in_relation_order(binary, data_dir):
    """`posts` references `authors`, but is listed first: apply must still order the
    creates so the FK target exists."""
    path = write_doc(data_dir, "s.json", doc(
        collection("posts", [
            field("title"),
            field("author", "relation", options={"targetCollectionId": "authors", "maxSelect": 1}),
        ]),
        collection("authors", [field("nom", required=True)]),
    ))
    r = run(binary, data_dir, "schema", "apply", path)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["apply_order"] == ["authors", "posts"]
    assert sorted(out["applied"]) == ["authors", "posts"]
    assert out["destructive"] is False
    assert "author" in columns(data_dir, "posts")
    assert "nom" in columns(data_dir, "authors")


def test_dump_then_apply_is_a_no_op(binary, data_dir):
    """The round-trip property. Also proves the dumped document is re-appliable at all."""
    path = write_doc(data_dir, "s.json", doc(
        collection("authors", [field("nom")]),
        collection("posts", [
            field("title", required=True),
            field("views", "number", options={"mode": "int"}),
            field("author", "relation", options={"targetCollectionId": "authors", "maxSelect": 1}),
        ], viewRule="@public"),
    ))
    assert run(binary, data_dir, "schema", "apply", path).returncode == 0

    d1 = run(binary, data_dir, "schema", "dump", "--json")
    assert d1.returncode == 0, d1.stderr
    dumped = os.path.join(data_dir, "dump1.json")
    pathlib.Path(dumped).write_text(d1.stdout)

    dry = run(binary, data_dir, "schema", "apply", dumped, "--dry-run")
    assert dry.returncode == 0, dry.stderr
    assert json.loads(dry.stdout)["changes"] == [], dry.stdout

    # Applying it for real changes nothing, and a second dump is byte-identical.
    apply_real = run(binary, data_dir, "schema", "apply", dumped)
    assert apply_real.returncode == 0
    assert json.loads(apply_real.stdout)["applied"] == []
    d2 = run(binary, data_dir, "schema", "dump", "--json")
    assert d2.stdout == d1.stdout


def test_reapplying_a_converged_document_is_a_true_no_op(binary, data_dir):
    """Sanctioned addition (review-driven fix, task-5 controller note): applying the SAME
    document twice must not just report an empty diff — it must not touch the DB at all.
    No table rebuild, and `_collections.updated` must not move on the second apply. This
    pins the idempotency invariant that made re-applying a converged document (acyclic or
    cyclic) a true no-op, not merely a no-op diff."""
    path = write_doc(data_dir, "s.json", doc(
        collection("authors", [field("nom")]),
        collection("posts", [
            field("title", required=True),
            field("author", "relation", options={"targetCollectionId": "authors", "maxSelect": 1}),
        ]),
    ))
    first = run(binary, data_dir, "schema", "apply", path)
    assert first.returncode == 0, first.stderr

    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        before = dict(con.execute(
            'SELECT name, updated FROM "_collections" WHERE name IN ("authors", "posts")'
        ).fetchall())
    finally:
        con.close()
    assert set(before) == {"authors", "posts"}

    d1 = run(binary, data_dir, "schema", "dump", "--json")
    assert d1.returncode == 0, d1.stderr

    second = run(binary, data_dir, "schema", "apply", path)
    assert second.returncode == 0, second.stderr
    out = json.loads(second.stdout)
    assert out["changes"] == [], second.stdout
    assert out["destructive"] is False
    assert out["applied"] == [], second.stdout

    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        after = dict(con.execute(
            'SELECT name, updated FROM "_collections" WHERE name IN ("authors", "posts")'
        ).fetchall())
    finally:
        con.close()
    assert after == before, "re-applying a converged document must not touch _collections.updated"

    d2 = run(binary, data_dir, "schema", "dump", "--json")
    assert d2.returncode == 0, d2.stderr
    assert d2.stdout == d1.stdout


def test_additive_apply_preserves_existing_rows(binary, data_dir):
    """Adding a field rebuilds the SQLite table; the data must survive (stable field ids)."""
    v1 = write_doc(data_dir, "v1.json", doc(collection("notes", [field("body")])))
    assert run(binary, data_dir, "schema", "apply", v1).returncode == 0

    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    con.execute('INSERT INTO "notes" ("id","created","updated","body") VALUES (?,?,?,?)',
                ("note00000000001", "2026-01-01 00:00:00", "2026-01-01 00:00:00", "keep me"))
    con.commit()
    con.close()

    dumped = os.path.join(data_dir, "v1dump.json")
    pathlib.Path(dumped).write_text(run(binary, data_dir, "schema", "dump").stdout)
    d = json.loads(pathlib.Path(dumped).read_text())
    d["collections"][0]["fields"].append(field("pinned", "bool"))
    pathlib.Path(dumped).write_text(json.dumps(d))

    r = run(binary, data_dir, "schema", "apply", dumped)
    assert r.returncode == 0, r.stderr
    assert [c["kind"] for c in json.loads(r.stdout)["changes"]] == ["add_field"]

    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        rows = con.execute('SELECT id, body FROM "notes"').fetchall()
    finally:
        con.close()
    assert rows == [("note00000000001", "keep me")]
    assert "pinned" in columns(data_dir, "notes")


def test_destructive_changes_need_the_flag_and_dry_run_exits_2(binary, data_dir):
    v1 = write_doc(data_dir, "v1.json", doc(collection("notes", [field("body"), field("scrap")])))
    assert run(binary, data_dir, "schema", "apply", v1).returncode == 0

    dumped = os.path.join(data_dir, "d.json")
    pathlib.Path(dumped).write_text(run(binary, data_dir, "schema", "dump").stdout)
    d = json.loads(pathlib.Path(dumped).read_text())
    d["collections"][0]["fields"] = [f for f in d["collections"][0]["fields"] if f["name"] != "scrap"]
    pathlib.Path(dumped).write_text(json.dumps(d))

    dry = run(binary, data_dir, "schema", "apply", dumped, "--dry-run")
    assert dry.returncode == 2, dry.stdout + dry.stderr
    out = json.loads(dry.stdout)
    assert out["destructive"] is True
    assert out["applied"] == []
    assert [c["kind"] for c in out["changes"]] == ["drop_field"]
    assert "scrap" in columns(data_dir, "notes")  # dry run changed nothing

    refused = run(binary, data_dir, "schema", "apply", dumped)
    assert refused.returncode == 1
    assert "--allow-destructive" in refused.stderr
    assert "scrap" in columns(data_dir, "notes")

    allowed = run(binary, data_dir, "schema", "apply", dumped, "--allow-destructive")
    assert allowed.returncode == 0, allowed.stderr
    assert "scrap" not in columns(data_dir, "notes")


def test_untracked_collections_are_left_alone_unless_pruned(binary, data_dir):
    both = write_doc(data_dir, "both.json", doc(
        collection("keepme", [field("a")]), collection("dropme", [field("b")])))
    assert run(binary, data_dir, "schema", "apply", both).returncode == 0

    partial = write_doc(data_dir, "partial.json", doc(collection("keepme", [field("a")])))
    r = run(binary, data_dir, "schema", "apply", partial)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["untracked"] == ["dropme"]
    assert out["changes"] == []
    assert columns(data_dir, "dropme")  # still there

    assert run(binary, data_dir, "schema", "apply", partial, "--prune").returncode == 1
    pruned = run(binary, data_dir, "schema", "apply", partial, "--prune", "--allow-destructive")
    assert pruned.returncode == 0, pruned.stderr
    assert [c["kind"] for c in json.loads(pruned.stdout)["changes"]] == ["drop_collection"]
    assert columns(data_dir, "dropme") == []


def test_apply_rejects_a_bad_document_and_reports_validation_details(binary, data_dir):
    bad = os.path.join(data_dir, "bad.json")
    pathlib.Path(bad).write_text('{"collections": []}')  # no version
    r = run(binary, data_dir, "schema", "apply", bad)
    assert r.returncode == 1
    assert "InvalidDocument" in r.stderr

    # A structurally valid document the ENGINE rejects: an invalid identifier.
    invalid = write_doc(data_dir, "inv.json", doc(collection("9bad", [field("x")])))
    r2 = run(binary, data_dir, "schema", "apply", invalid)
    assert r2.returncode == 1
    assert "validation_invalid_name" in r2.stderr, r2.stderr


def stored_rule(data, name, rule="listRule"):
    """The rule string as `_collections` actually holds it — the thing a request would parse."""
    con = sqlite3.connect(os.path.join(data, "data.db"))
    try:
        row = con.execute(
            f'SELECT "{rule}" FROM "_collections" WHERE name = ?', (name,)).fetchone()
        return None if row is None else row[0]
    finally:
        con.close()


def test_an_unparseable_rule_refuses_the_whole_apply_and_writes_nothing(binary, data_dir):
    """`apply` is the last chokepoint before a typo'd rule ships: nothing validates a rule at
    write time, and at request time a rule that fails to parse fails CLOSED (500).

    The bar here is STATE, not the exit code. The bad document both MODIFIES an existing,
    working collection (adds a field, replaces its good rule with garbage) and CREATES a new
    one — so if the gate were absent or partial, the database would show it: `extra` would
    appear on `notes`, `brandnew` would exist, and `_collections.listRule` would hold an
    expression no request can parse.
    """
    good = write_doc(data_dir, "good.json", doc(
        collection("notes", [field("body"), field("scrap")], listRule='body != ""')))
    assert run(binary, data_dir, "schema", "apply", good).returncode == 0
    assert stored_rule(data_dir, "notes") == 'body != ""'
    before = columns(data_dir, "notes")

    # `body = ` lexes fine and dies in the parser: an operator with no right operand.
    bad = write_doc(data_dir, "bad.json", doc(
        collection("notes", [field("body"), field("scrap"), field("extra")], listRule="body = "),
        collection("brandnew", [field("x")])))

    r = run(binary, data_dir, "schema", "apply", bad)
    assert r.returncode == 1, r.stdout + r.stderr
    # The refusal names what to fix, on stderr (stdout stays the JSON channel).
    assert "notes" in r.stderr and "listRule" in r.stderr and "BadOperand" in r.stderr, r.stderr

    # Nothing was written — not the new collection, not the field, not the rule.
    assert columns(data_dir, "brandnew") == []
    assert columns(data_dir, "notes") == before
    assert "extra" not in columns(data_dir, "notes")
    assert stored_rule(data_dir, "notes") == 'body != ""'

    # Precedence: a document that is ALSO destructive (drops `scrap`) still exits 1 under
    # --dry-run, not 2. An invalid document is invalid before it is destructive.
    both = write_doc(data_dir, "both.json", doc(
        collection("notes", [field("body")], listRule="body = "),
        collection("brandnew", [field("x")])))
    dry = run(binary, data_dir, "schema", "apply", both, "--dry-run")
    assert dry.returncode == 1, dry.stdout + dry.stderr
    assert "BadOperand" in dry.stderr, dry.stderr
    assert "scrap" in columns(data_dir, "notes")
    assert stored_rule(data_dir, "notes") == 'body != ""'

    # And the same document with the rule fixed applies, proving the refusal was about the
    # rule and not about anything else in the document.
    fixed = write_doc(data_dir, "fixed.json", doc(
        collection("notes", [field("body"), field("scrap"), field("extra")], listRule='body != ""'),
        collection("brandnew", [field("x")])))
    ok = run(binary, data_dir, "schema", "apply", fixed)
    assert ok.returncode == 0, ok.stderr
    assert "extra" in columns(data_dir, "notes")
    assert columns(data_dir, "brandnew")


def test_changing_an_index_definition_is_seen_and_applied(binary, data_dir):
    """Indexes were diffed by NAME only, so flipping `unique` produced an empty plan: exit 0,
    `changes: []`, and a dry run reporting "settled" while the live index kept its old shape.
    Assert both halves — the diff SEES it, and the apply actually rewrites the SQLite index."""
    def with_index(unique):
        return doc(collection("posts", [field("slug")],
                              indexes=[{"name": "idx_posts_slug", "fields": ["slug"], "unique": unique}]))

    v1 = write_doc(data_dir, "v1.json", with_index(False))
    assert run(binary, data_dir, "schema", "apply", v1).returncode == 0
    assert indexes(data_dir, "posts")["idx_posts_slug"] is False

    v2 = write_doc(data_dir, "v2.json", with_index(True))
    dry = run(binary, data_dir, "schema", "apply", v2, "--dry-run")
    assert dry.returncode == 0, dry.stderr
    out = json.loads(dry.stdout)
    assert [c["kind"] for c in out["changes"]] == ["modify_index"], dry.stdout
    assert out["changes"][0]["detail"] == "idx_posts_slug"
    assert out["destructive"] is False  # rewriting an index drops no data
    assert indexes(data_dir, "posts")["idx_posts_slug"] is False  # dry run changed nothing

    real = run(binary, data_dir, "schema", "apply", v2)
    assert real.returncode == 0, real.stderr
    assert json.loads(real.stdout)["applied"] == ["posts"]
    assert indexes(data_dir, "posts")["idx_posts_slug"] is True

    # And the new state is converged: re-applying is a no-op, not a perpetual modify_index.
    again = run(binary, data_dir, "schema", "apply", v2)
    assert json.loads(again.stdout)["changes"] == [], again.stdout


def test_a_relation_cycle_applies_in_two_passes_and_reconverges(binary, data_dir):
    """The advertised two-pass cyclic apply, executed end to end: `a.toB -> b` and
    `b.toA -> a` cannot both be created in one pass. Pass 1 creates the back-edge collection
    without its relation field, pass 2 fills it in. Both columns must exist afterwards, and a
    re-apply must be a TRUE no-op — `plan.deferred` stays non-empty on every run (it is
    structural), so an ungated pass 2 would rebuild the table forever."""
    path = write_doc(data_dir, "cyc.json", doc(
        collection("a", [field("toB", "relation",
                               options={"targetCollectionId": "b", "maxSelect": 1})]),
        collection("b", [field("toA", "relation",
                               options={"targetCollectionId": "a", "maxSelect": 1})]),
    ))
    first = run(binary, data_dir, "schema", "apply", path)
    assert first.returncode == 0, first.stderr
    out = json.loads(first.stdout)
    assert out["deferred_relations"], first.stdout
    assert sorted(out["applied"]) == ["a", "b"]
    # Both back-edge columns exist: pass 2 really backfilled the one pass 1 held back.
    assert "toB" in columns(data_dir, "a")
    assert "toA" in columns(data_dir, "b")

    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        before = dict(con.execute(
            'SELECT name, updated FROM "_collections" WHERE name IN ("a", "b")').fetchall())
    finally:
        con.close()
    assert set(before) == {"a", "b"}

    second = run(binary, data_dir, "schema", "apply", path)
    assert second.returncode == 0, second.stderr
    out2 = json.loads(second.stdout)
    assert out2["changes"] == [], second.stdout
    assert out2["applied"] == [], second.stdout
    assert out2["deferred_relations"], "the cycle is structural; it does not disappear once applied"

    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        after = dict(con.execute(
            'SELECT name, updated FROM "_collections" WHERE name IN ("a", "b")').fetchall())
    finally:
        con.close()
    assert after == before, "re-applying a converged cyclic document must not rebuild either table"


def ndjson(stdout):
    """Parse `schema check-rules` stdout as strict NDJSON: every line is its own JSON
    object, no stripping, no leading/trailing noise. Returns (findings, summary)."""
    lines = stdout.split("\n")
    assert lines[-1] == "", "output must end with exactly one newline"
    objs = [json.loads(line) for line in lines[:-1]]
    assert objs, "at least the summary must be printed"
    summary = objs[-1]
    assert summary.get("summary") is True, stdout
    assert list(summary)[0] == "summary", "the discriminator must be the first key"
    assert not any("summary" in o for o in objs[:-1]), "exactly one summary object"
    return objs[:-1], summary


def test_check_rules_document_mode_reports_syntax_depth_and_flags_a_broken_rule(binary, data_dir):
    """The gap this closes: nothing validates a rule when it is written. A malformed rule
    must be caught here rather than by the first 500 in production."""
    path = write_doc(data_dir, "bad.json", doc(
        collection("posts", [field("title")], listRule="title = "),
        collection("notes", [field("body")], viewRule='body = "ok'),
    ))
    r = run(binary, data_dir, "schema", "check-rules", path)
    assert r.returncode == 1, r.stdout + r.stderr

    findings, summary = ndjson(r.stdout)
    assert summary["depth"] == "syntax"
    assert summary["collections"] == 2
    assert summary["rules_checked"] == 2
    assert summary["errors"] == 2
    assert summary["warnings"] == 0

    assert {(f["collection"], f["rule"], f["severity"]) for f in findings} == {
        ("posts", "listRule", "error"), ("notes", "viewRule", "error")}
    codes = {f["collection"]: f["code"] for f in findings}
    # The codes are the real pipeline's own error names, not codes the linter invented.
    assert codes == {"posts": "BadOperand", "notes": "UnterminatedString"}


def test_check_rules_is_silent_and_exits_0_on_a_clean_document(binary, data_dir):
    """No per-rule "ok" lines — a clean run prints ONLY the summary, whose rules_checked
    is what tells a reader the silence covered something."""
    path = write_doc(data_dir, "ok.json", doc(
        collection("posts", [field("title")],
                   listRule='title != ""',
                   viewRule='@request.auth.id != ""'),
        collection("locked", [field("x")]),  # all-null rules: Locked, never a finding
        collection("blank", [field("x")], listRule="", viewRule=""),  # "" is Locked too
    ))
    r = run(binary, data_dir, "schema", "check-rules", path)
    assert r.returncode == 0, r.stdout + r.stderr
    findings, summary = ndjson(r.stdout)
    assert findings == []
    assert summary["depth"] == "syntax"
    assert summary["collections"] == 3
    assert summary["rules_checked"] == 2  # blank/null rules are Locked, not rules
    assert summary["errors"] == 0 and summary["warnings"] == 0


def test_check_rules_warns_on_public_and_exits_2(binary, data_dir):
    """`@public` is the only allow-all. It is a warning, not an error: the command
    succeeded, it found a judgment call an operator must confirm."""
    path = write_doc(data_dir, "pub.json", doc(
        collection("posts", [field("title")], listRule="@public", viewRule="@public")))
    r = run(binary, data_dir, "schema", "check-rules", path)
    assert r.returncode == 2, r.stdout + r.stderr
    findings, summary = ndjson(r.stdout)
    assert summary["errors"] == 0 and summary["warnings"] == 2
    assert summary["rules_checked"] == 2
    assert {f["rule"] for f in findings} == {"listRule", "viewRule"}
    assert {f["severity"] for f in findings} == {"warn"}
    assert {f["code"] for f in findings} == {"PublicRule"}


def test_check_rules_live_mode_is_full_depth_and_sees_what_syntax_depth_cannot(binary, data_dir):
    """The honesty of the two-depth design, end to end. `nope = "x"` is well-formed
    syntax, so the document check passes it; only the live check — which resolves field
    names against the real schema through the request path's own compiler — knows the
    field does not exist. It also proves the premise: `schema apply` accepts the broken
    rule without complaint, because rules are never validated at write time."""
    path = write_doc(data_dir, "s.json", doc(
        collection("posts", [field("title")], listRule='nope = "x"', viewRule='title != ""')))

    offline = run(binary, data_dir, "schema", "check-rules", path)
    assert offline.returncode == 0, offline.stdout + offline.stderr
    off_findings, off_summary = ndjson(offline.stdout)
    assert off_findings == []
    assert off_summary["depth"] == "syntax"

    assert run(binary, data_dir, "schema", "apply", path).returncode == 0

    live = run(binary, data_dir, "schema", "check-rules")
    assert live.returncode == 1, live.stdout + live.stderr
    findings, summary = ndjson(live.stdout)
    assert summary["depth"] == "full"
    assert summary["collections"] == 1
    assert summary["rules_checked"] == 2
    assert summary["errors"] == 1
    assert [(f["collection"], f["rule"], f["code"]) for f in findings] == [
        ("posts", "listRule", "UnknownField")]


def test_check_rules_live_mode_is_clean_on_a_sound_schema(binary, data_dir):
    """Negative control for the test above: full depth must not report rules that work."""
    path = write_doc(data_dir, "s.json", doc(
        collection("authors", [field("nom")], listRule='nom != ""'),
        collection("posts", [
            field("title"),
            field("author", "relation", options={"targetCollectionId": "authors", "maxSelect": 1}),
        ], listRule='author.nom != ""', viewRule='title != ""'),
    ))
    assert run(binary, data_dir, "schema", "apply", path).returncode == 0

    r = run(binary, data_dir, "schema", "check-rules")
    assert r.returncode == 0, r.stdout + r.stderr
    findings, summary = ndjson(r.stdout)
    assert findings == []
    assert summary["depth"] == "full"
    assert summary["collections"] == 2
    assert summary["rules_checked"] == 3


def test_stdout_is_only_json(binary, data_dir):
    """Every emitted stdout must parse as exactly one JSON object — logs live on stderr."""
    path = write_doc(data_dir, "s.json", doc(collection("t", [field("x")])))
    for args in (("schema", "apply", path, "--dry-run"), ("schema", "apply", path), ("schema", "dump")):
        r = run(binary, data_dir, *args)
        assert r.returncode == 0, r.stderr
        json.loads(r.stdout)  # raises if anything else leaked onto stdout
