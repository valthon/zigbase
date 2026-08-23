"""Shared fixtures for the Rails converter suite.

Every test runs against the committed, frozen Rails 8.1 fixture. Nothing here boots
Rails or needs Ruby: the fixture was recorded once from a real application and the
converter's whole job is to work offline from that recording.
"""

from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

import pytest

from tools.rails import _core, rails2zb  # noqa: F401

REPO = Path(__file__).resolve().parents[2]
FIXTURE = REPO / "tests" / "rails" / "fixtures" / "rails-8.1.3.1"


@pytest.fixture(scope="session")
def fixture_root() -> Path:
    if not FIXTURE.is_dir():
        pytest.skip(f"Rails fixture is not present at {FIXTURE}")
    return FIXTURE


@pytest.fixture(scope="session")
def source(fixture_root: Path) -> Path:
    return fixture_root


@pytest.fixture
def workspace(tmp_path: Path) -> Path:
    out = tmp_path / "work"
    out.mkdir()
    return out


@pytest.fixture
def mutable_source(fixture_root: Path, tmp_path: Path) -> Path:
    """A writable copy, for tests that need to corrupt the source deliberately.

    The committed fixture is never modified: a test that mutates it would leave the
    repository dirty and make every later test depend on execution order.
    """
    target = tmp_path / "source"
    shutil.copytree(fixture_root, target)
    return target


def read_inventory(source: Path, name: str) -> dict:
    return json.loads((source / "inventory" / f"{name}.json").read_text())


def set_mode_everywhere(value, mode: str):
    """Flip every provenance marker, at any depth.

    A genuinely inferred inventory has no observed record anywhere in it, so a helper
    that flips only the top level produces a file the loader correctly rejects as mixed.
    """
    if isinstance(value, dict):
        return {
            k: (
                mode
                if k == "source" and v in ("observed", "inferred")
                else set_mode_everywhere(v, mode)
            )
            for k, v in value.items()
        }
    if isinstance(value, list):
        return [set_mode_everywhere(v, mode) for v in value]
    return value


def write_inventory(source: Path, name: str, value: dict) -> None:
    (source / "inventory" / f"{name}.json").write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n"
    )


def materialize_artifacts(value: dict, root: Path) -> dict:
    """Create every artifact a decision set names, under `root`.

    `reconcile` refuses a decision whose artifact does not exist, because a path to
    nothing documents a replacement nobody built. A harness that fabricates paths would
    therefore fail — correctly. So the harness creates them, exactly as an operator who
    actually wrote the hook would have.
    """
    for entry in value["decisions"]:
        artifact = entry.get("artifact")
        if not artifact or rails2zb._artifact_is_inline(entry["id"], entry["choice"]):
            continue  # the artifact IS the text (a name, a rule, a predicate)
        if "\n" in artifact or artifact.startswith("@"):
            continue  # inline rule text, not a path
        target = root / artifact
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            target.write_text(
                f"# Replacement for {entry['id']}\n\nChosen: {entry['choice']}\n"
            )
    return value


def decisions_for(findings: list[dict], **overrides: str) -> dict:
    """Build a complete decision set, so tests exercise extraction not reconciliation.

    `overrides` maps a finding id to a chosen value; everything else takes the first
    declared choice, which keeps the helper honest about what a finding actually offers.
    """
    entries = []
    for finding in findings:
        if finding["severity"] not in ("blocker", "decision"):
            continue
        # Prefer a choice that KEEPS data. `omit` is a decision to lose something, and a
        # default harness that silently picks it would quietly shrink the migration --
        # and mask exactly the consumers these tests exist to exercise.
        offered = list(finding.get("choices") or ["omit"])
        keeping = [c for c in offered if c != "omit"]
        choice = overrides.get(finding["id"]) or (keeping or offered)[0]
        entry = {
            "id": finding["id"],
            "choice": choice,
            "rationale": "covered by the Rails converter test suite",
        }
        # Mirror the converter's own contract rather than a looser version of it: any
        # choice claiming a replacement exists must name one. The harness previously
        # supplied artifacts only for `requiresArtifact` findings, which let it record
        # six `hook` decisions pointing at nothing -- a fixture asserting a migration
        # nobody built.
        needs_artifact = choice in rails2zb.IMPLEMENTATION_CHOICES or (
            finding.get("requiresArtifact") and choice not in ("omit", "out-of-scope")
        )
        if choice == "rename":
            # A rename's artifact is the new NAME, and the finding exists because the
            # old one was not a usable identifier -- so a path here is never valid
            # input. Deriving it from the subject keeps two renames from colliding.
            subject = _core.split_id(finding["id"])[-2]
            entry["artifact"] = "renamed_" + re.sub(r"[^A-Za-z0-9_]", "_", subject)
        elif needs_artifact:
            entry["artifact"] = f"docs/replacements/{finding['id']}.md"
        entries.append(entry)
    return {"zigbaseRailsDecisions": 1, "decisions": entries}
