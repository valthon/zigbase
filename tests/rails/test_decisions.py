"""A finding is only useful if it cannot be bypassed.

The decision contract is the mechanism that stops a converter from quietly guessing, so
these tests are mostly about what it *refuses*.
"""

from __future__ import annotations

import pytest

from .conftest import decisions_for
from tools.rails import rails2zb
from tools.rails._core import Finding, RailsError


@pytest.fixture(scope="module")
def findings(source):
    return rails2zb.build_findings(rails2zb.load_source(source))


@pytest.fixture(scope="module")
def complete(findings):
    return decisions_for([f.to_dict() for f in findings])


def parse(value):
    return rails2zb.load_decisions_from_value(value)


def test_a_complete_decision_set_reconciles(findings, complete):
    rails2zb.reconcile(findings, parse(complete))


def test_an_undecided_finding_blocks_extraction(findings, complete):
    trimmed = dict(complete)
    trimmed["decisions"] = [
        d for d in complete["decisions"] if d["id"] != "model.Club.default_scope"
    ]
    with pytest.raises(RailsError, match="model.Club.default_scope"):
        rails2zb.reconcile(findings, parse(trimmed))


def test_a_decision_for_an_unknown_finding_is_refused(findings, complete):
    extra = dict(complete)
    extra["decisions"] = complete["decisions"] + [
        {"id": "model.Ghost.default_scope", "choice": "omit", "rationale": "invented"}
    ]
    with pytest.raises(RailsError, match="unknown findings"):
        rails2zb.reconcile(findings, parse(extra))


def test_a_choice_outside_the_offered_set_is_refused(findings, complete):
    bogus = dict(complete)
    bogus["decisions"] = [
        {**d, "choice": "whatever"} if d["id"] == "model.Club.default_scope" else d
        for d in complete["decisions"]
    ]
    with pytest.raises(RailsError, match="expected one of"):
        rails2zb.reconcile(findings, parse(bogus))


def test_replacing_behavior_requires_a_typed_artifact(findings, complete):
    stripped = dict(complete)
    stripped["decisions"] = [
        {k: v for k, v in d.items() if k != "artifact"}
        if d["id"] == "schema.trigger.posts_count_after_insert"
        else d
        for d in complete["decisions"]
    ]
    with pytest.raises(RailsError, match="typed artifact"):
        rails2zb.reconcile(findings, parse(stripped))


def test_omitting_behavior_needs_no_artifact():
    """`omit` is a decision to lose the behavior deliberately; there is nothing to point at."""
    finding = Finding(
        "x.y", "blocker", "Code", "message", ("replacement", "omit"), True
    )
    decisions = parse(
        {
            "zigbaseRailsDecisions": 1,
            "decisions": [{"id": "x.y", "choice": "omit", "rationale": "not needed"}],
        }
    )
    rails2zb.reconcile([finding], decisions)


def test_info_findings_need_no_decision(findings, complete):
    """There is nothing for an operator to choose, so demanding a choice is busywork."""
    info = [f for f in findings if f.severity == "info"]
    assert info, "the fixture should produce at least one info finding"
    assert not any(d["id"] == info[0].id for d in complete["decisions"])
    rails2zb.reconcile(findings, parse(complete))


def test_a_blank_rationale_is_refused():
    with pytest.raises(RailsError, match="rationale"):
        parse(
            {
                "zigbaseRailsDecisions": 1,
                "decisions": [{"id": "x.y", "choice": "omit", "rationale": ""}],
            }
        )


def test_duplicate_decisions_are_refused():
    entry = {"id": "x.y", "choice": "omit", "rationale": "first"}
    with pytest.raises(RailsError, match="duplicate"):
        parse({"zigbaseRailsDecisions": 1, "decisions": [entry, dict(entry)]})


@pytest.mark.parametrize(
    "value",
    [
        {"decisions": []},
        {"zigbaseRailsDecisions": 1},
        {"zigbaseRailsDecisions": 1, "decisions": [], "extra": True},
    ],
)
def test_a_malformed_envelope_is_refused(value):
    with pytest.raises(RailsError, match="exactly"):
        parse(value)


def test_an_unsupported_version_is_refused():
    with pytest.raises(RailsError, match="unsupported decisions version"):
        parse({"zigbaseRailsDecisions": 2, "decisions": []})


def test_findings_keep_stable_ids_when_messages_change(source):
    """A message is prose for a human; rewording one must not invalidate a decision."""
    ids = {f.id for f in rails2zb.build_findings(rails2zb.load_source(source))}
    assert "model.Club.default_scope" in ids
    assert all(" " not in fid for fid in ids)


def test_a_whitespace_only_artifact_is_refused():
    """`" "` as a rule expression resolved to Locked on all five actions, silently.

    The direction is safe, but silence is exactly what this contract is for -- and the
    `rename` path already refuses the same input loudly.
    """
    with pytest.raises(RailsError, match="non-empty string"):
        parse(
            {
                "zigbaseRailsDecisions": 1,
                "decisions": [
                    {
                        "id": "table.clubs.rules",
                        "choice": "expression",
                        "rationale": "test",
                        "artifact": "   ",
                    }
                ],
            }
        )
