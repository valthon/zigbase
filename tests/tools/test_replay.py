"""Unit tests for the parity-replay harness. Pure functions only — no network."""
import importlib.util
import json
import pathlib

import pytest

SPEC = pathlib.Path(__file__).resolve().parents[2] / "tools" / "replay" / "zb_replay.py"
spec = importlib.util.spec_from_file_location("zb_replay", SPEC)
zr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zr)


def test_subset_matches_extra_keys_but_not_missing_or_different():
    assert zr.diff_subset({"a": 1}, {"a": 1, "b": 2}) == []
    assert zr.diff_subset({}, {"a": 1}) == []
    assert zr.diff_subset({"a": 1}, {"a": 2}) == [{"path": "a", "expected": 1, "actual": 2}]
    assert zr.diff_subset({"a": 1}, {"b": 1}) == [
        {"path": "a", "expected": 1, "actual": None, "message": "missing key"}
    ]


def test_null_expectation_passes_only_when_the_key_is_actually_present():
    # (a) expected null, key present and null -> no diff: a real null survived the migration.
    assert zr.diff_subset({"deletedAt": None}, {"deletedAt": None}) == []
    # (b) expected null, key absent entirely -> a diff: dict.get(k) would silently return
    # None for a missing key too, so without the sentinel a dropped nullable field passes.
    assert zr.diff_subset({"deletedAt": None}, {}) == [
        {"path": "deletedAt", "expected": None, "actual": None, "message": "missing key"}
    ]
    # (c) same absent-vs-null distinction nested inside an object inside an array.
    exp = {"items": [{"title": "x", "deletedAt": None}]}
    assert zr.diff_subset(exp, {"items": [{"title": "x", "deletedAt": None}]}) == []
    assert zr.diff_subset(exp, {"items": [{"title": "x"}]}) == [
        {"path": "items.0.deletedAt", "expected": None, "actual": None, "message": "missing key"}
    ]


def test_subset_recurses_into_objects_and_arrays():
    exp = {"items": [{"title": "x"}, {"title": "y"}]}
    assert zr.diff_subset(exp, {"items": [{"title": "x", "id": "1"}, {"title": "y", "id": "2"}]}) == []
    d = zr.diff_subset(exp, {"items": [{"title": "x"}, {"title": "ZZ"}]})
    assert d == [{"path": "items.1.title", "expected": "y", "actual": "ZZ"}]


def test_a_shorter_actual_array_is_a_failure_but_a_longer_one_is_not():
    assert zr.diff_subset({"i": [1, 2]}, {"i": [1, 2, 3]}) == []
    d = zr.diff_subset({"i": [1, 2]}, {"i": [1]})
    assert d == [{"path": "i.1", "expected": 2, "actual": None, "message": "missing key"}]


def test_a_missing_null_array_element_is_a_failure_not_a_silent_pass():
    # A `None` element is a legitimate expectation (e.g. a nullable array entry survived the
    # migration as-is). Without the `_MISSING` sentinel, `actual[i] if i < len(actual) else
    # None` collapses "index absent" and "index holds null" — a migration that drops the
    # element entirely would satisfy an expectation of `[None]` against `[]`. It must not.
    assert zr.diff_subset({"i": [None]}, {"i": []}) == [
        {"path": "i.0", "expected": None, "actual": None, "message": "missing key"}
    ]
    assert zr.diff_subset({"i": [None]}, {"i": [None]}) == []


def test_volatile_keys_are_stripped_recursively():
    got = zr.strip_volatile(
        {"id": "x", "title": "t", "items": [{"id": "y", "created": "now", "n": 1}]},
        zr.DEFAULT_VOLATILE,
    )
    assert got == {"title": "t", "items": [{"n": 1}]}


def test_placeholders_resolve_from_vars_and_an_unknown_one_raises():
    assert zr.substitute("Bearer {{token}}", {"token": "abc"}) == "Bearer abc"
    assert zr.substitute({"h": "{{a}}/{{b}}"}, {"a": "1", "b": "2"}) == {"h": "1/2"}
    with pytest.raises(zr.ReplayError):
        zr.substitute("{{missing}}", {})


def test_a_var_value_containing_a_placeholder_does_not_loop_forever():
    # `substitute` re-scans the string after every expansion (so "{{a}}" -> "{{b}}" -> "c"
    # resolves in one call). A --var value that itself contains a literal "{{...}}" would
    # otherwise re-match on every pass and never terminate — it must raise instead of hang.
    with pytest.raises(zr.ReplayError):
        zr.substitute("{{a}}", {"a": "{{a}}"})
    with pytest.raises(zr.ReplayError):
        zr.substitute("{{a}}", {"a": "{{b}}", "b": "{{a}}"})
    # A legitimate multi-hop chain that DOES bottom out still resolves, well under the cap.
    assert zr.substitute("{{a}}", {"a": "{{b}}", "b": "{{c}}", "c": "done"}) == "done"


def test_many_distinct_placeholders_in_one_string_resolve_without_hitting_the_cap():
    # The pass cap bounds nesting DEPTH, not the number of distinct placeholders expanded —
    # a captured URL or body can legitimately contain more of them than MAX_SUBSTITUTION_PASSES.
    variables = {f"v{i}": str(i) for i in range(15)}
    template = "".join(f"{{{{v{i}}}}}" for i in range(15))
    expected = "".join(str(i) for i in range(15))
    assert zr.substitute(template, variables) == expected

    # A self-referential var among otherwise-fine placeholders still raises: it's genuine
    # non-convergence, not just "many placeholders".
    with pytest.raises(zr.ReplayError):
        zr.substitute("{{x}}", {"x": "{{x}}"})


def test_parse_capture_rejects_a_case_without_an_id_or_with_a_duplicate(tmp_path):
    p = tmp_path / "c.ndjson"
    p.write_text(json.dumps({"method": "GET", "path": "/x"}) + "\n")
    with pytest.raises(zr.ReplayError):
        zr.load_capture(str(p))
    p.write_text("\n".join([
        json.dumps({"id": "a", "method": "GET", "path": "/x"}),
        json.dumps({"id": "a", "method": "GET", "path": "/y"}),
    ]) + "\n")
    with pytest.raises(zr.ReplayError):
        zr.load_capture(str(p))


def test_compare_builds_a_finding_with_status_and_body_differences():
    case = {"id": "c1", "expect": {"status": 200, "bodySubset": {"a": 1}}}
    ok = zr.compare(case, 200, {"a": 1, "b": 9})
    assert ok["result"] == "pass" and ok["diff"] == []
    bad = zr.compare(case, 404, {"a": 2})
    assert bad["result"] == "fail"
    assert bad["status"] == {"expected": 200, "actual": 404}
    assert bad["diff"] == [{"path": "a", "expected": 1, "actual": 2}]


def test_replay_exits_1_when_every_case_dies_in_transport(tmp_path, monkeypatch, capsys):
    # The tool ran, but the target never answered a single request — there's nothing to
    # judge, so this is a tool/environment failure (exit 1), not a parity finding.
    cap = tmp_path / "cap.ndjson"
    cap.write_text(json.dumps({"id": "c1", "method": "GET", "path": "/x",
                                "expect": {"status": 200}}) + "\n")
    out = tmp_path / "findings.ndjson"

    def fake_send(base_url, case, variables, timeout):
        raise zr.ReplayError(f"{case['id']}: connection refused")

    monkeypatch.setattr(zr, "send", fake_send)
    rc = zr.main(["replay", str(cap), "--base-url", "http://dead.invalid", "--out", str(out)])

    assert rc == 1
    captured = capsys.readouterr()
    summary = json.loads(captured.out)
    assert summary["total"] == 1 and summary["passed"] == 0
    assert summary["failed"] == 0 and summary["errors"] == 1
    assert "unreachable" in captured.err


def test_replay_exits_2_when_some_cases_pass_and_one_dies_in_transport(tmp_path, monkeypatch, capsys):
    # A vanished endpoint alongside working ones is parity signal, not a tool failure —
    # the run exercised the target and found something a human should look at (exit 2).
    cap = tmp_path / "cap.ndjson"
    cap.write_text("\n".join([
        json.dumps({"id": "c1", "method": "GET", "path": "/ok", "expect": {"status": 200}}),
        json.dumps({"id": "c2", "method": "GET", "path": "/gone", "expect": {"status": 200}}),
    ]) + "\n")
    out = tmp_path / "findings.ndjson"

    def fake_send(base_url, case, variables, timeout):
        if case["id"] == "c1":
            return 200, {}
        raise zr.ReplayError(f"{case['id']}: connection refused")

    monkeypatch.setattr(zr, "send", fake_send)
    rc = zr.main(["replay", str(cap), "--base-url", "http://mixed.invalid", "--out", str(out)])

    assert rc == 2
    summary = json.loads(capsys.readouterr().out)
    assert summary["total"] == 2
    assert summary["passed"] == 1 and summary["failed"] == 0 and summary["errors"] == 1
