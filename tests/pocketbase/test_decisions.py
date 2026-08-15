import json

import pytest

from tools.pocketbase import pb2zb


def finding(*, requires_artifact=False):
    return pb2zb.Finding(
        "field.locations.point.geoPoint",
        "decision",
        "GeoPointRequiresMapping",
        "mapping required",
        ("json", "omit"),
        requires_artifact,
    )


def write_decisions(tmp_path, decisions, **overrides):
    value = {
        "zigbasePocketBaseDecisions": 1,
        "sourceVersion": "0.39.11",
        "decisions": decisions,
    }
    value.update(overrides)
    path = tmp_path / "decisions.json"
    path.write_text(json.dumps(value))
    return path


def test_exact_decision_reconciles(tmp_path):
    path = write_decisions(
        tmp_path,
        [
            {
                "id": "field.locations.point.geoPoint",
                "choice": "json",
                "rationale": "Coordinates are displayed but never queried spatially.",
            }
        ],
    )
    version, decisions = pb2zb.load_decisions(path)
    assert version == "0.39.11"
    pb2zb.reconcile_decisions([finding()], decisions)


@pytest.mark.parametrize(
    "decisions, match",
    [
        ([], "unacknowledged"),
        (
            [{"id": "stale", "choice": "json", "rationale": "old"}],
            "unknown or stale",
        ),
        (
            [
                {
                    "id": "field.locations.point.geoPoint",
                    "choice": "text",
                    "rationale": "x",
                }
            ],
            "choice must be one of",
        ),
    ],
)
def test_reconciliation_rejects_missing_stale_and_bad_choices(
    tmp_path, decisions, match
):
    _, loaded = pb2zb.load_decisions(write_decisions(tmp_path, decisions))
    with pytest.raises(pb2zb.PocketBaseError, match=match):
        pb2zb.reconcile_decisions([finding()], loaded)


def test_decisions_reject_duplicates_blank_rationale_and_contract_drift(tmp_path):
    item = {
        "id": "field.locations.point.geoPoint",
        "choice": "json",
        "rationale": "because",
    }
    with pytest.raises(pb2zb.PocketBaseError, match="duplicate"):
        pb2zb.load_decisions(write_decisions(tmp_path, [item, item]))
    with pytest.raises(pb2zb.PocketBaseError, match="blank"):
        pb2zb.load_decisions(write_decisions(tmp_path, [{**item, "rationale": "  "}]))
    with pytest.raises(pb2zb.PocketBaseError, match="sourceVersion"):
        pb2zb.load_decisions(write_decisions(tmp_path, [item], sourceVersion="0.40.0"))
    with pytest.raises(pb2zb.PocketBaseError, match="unknown"):
        pb2zb.load_decisions(write_decisions(tmp_path, [item], typo=True))


def test_replacement_requires_safe_relative_artifact(tmp_path):
    replacement = pb2zb.Finding(
        "rule.posts.listRule.replacement",
        "blocker",
        "PocketBaseRuleRequiresReplacement",
        "replacement required",
        ("replacement",),
        True,
    )
    base = {
        "id": replacement.id,
        "choice": "replacement",
        "rationale": "Ported as a tested hook.",
    }
    _, missing = pb2zb.load_decisions(write_decisions(tmp_path, [base]))
    with pytest.raises(pb2zb.PocketBaseError, match="requires a replacement artifact"):
        pb2zb.reconcile_decisions([replacement], missing)
    _, escaped = pb2zb.load_decisions(
        write_decisions(tmp_path, [{**base, "artifact": "../outside.zig"}])
    )
    with pytest.raises(pb2zb.PocketBaseError, match="safe relative"):
        pb2zb.reconcile_decisions([replacement], escaped)
    _, windows_escape = pb2zb.load_decisions(
        write_decisions(tmp_path, [{**base, "artifact": "..\\outside.zig"}])
    )
    with pytest.raises(pb2zb.PocketBaseError, match="safe relative"):
        pb2zb.reconcile_decisions([replacement], windows_escape)
    _, valid = pb2zb.load_decisions(
        write_decisions(tmp_path, [{**base, "artifact": "replacements/posts.zig"}])
    )
    pb2zb.reconcile_decisions([replacement], valid)
