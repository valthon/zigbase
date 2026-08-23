"""The skill must not promise a narrower scope gate than the guide it is built from.

`references/` is byte-synced and guarded; SKILL.md's own prose is not, so it drifted:
the guide offered three recorded scopes and called the third — a partial migration of the
JSON API subset of a view-rendering monolith — the common one, while the skill offered
only two. An agent driving the common case had no sanctioned lane for it.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SKILL = REPO / "skills" / "zigbase-migrate-rails-api" / "SKILL.md"
GUIDE = REPO / "docs" / "migrate-rails-api.md"


@pytest.fixture(scope="module")
def skill() -> str:
    return SKILL.read_text()


@pytest.fixture(scope="module")
def guide() -> str:
    return GUIDE.read_text()


def _gate(text: str) -> str:
    """The scope-gate section, whichever heading level the document uses."""
    match = re.search(r"\n#+ \d+\. Gate the scope[^\n]*\n(.*?)\n#+ \d+\. ", text, re.S)
    assert match, "both documents must open with a scope gate"
    return match.group(1)


def test_the_skill_offers_every_scope_the_guide_does(skill, guide):
    def options(text: str) -> int:
        return len(re.findall(r"^\d+\. ", _gate(text), re.M))

    assert options(skill) == options(guide), (
        "the skill's scope gate must enumerate the same recorded options as the guide"
    )


def test_the_skill_carries_the_partial_migration_lane(skill):
    gate = _gate(skill)
    assert "partial" in gate.lower()
    assert "system of record" in gate.lower(), (
        "a partial migration shares state; without a recorded owner per table, two "
        "stacks write the same rows"
    )


def test_the_completion_contract_cannot_imply_the_frontend_moved(skill):
    """Pin the sentences, not the words.

    Asserting that "never" and "migrated" appear SOMEWHERE was satisfied by unrelated
    prose — "Never edit the source" alone carried the first half — so the guard would
    have survived deleting the contract it was written to protect.
    """
    lowered = " ".join(skill.lower().split())

    # The completion report must state the negative outright, not merely omit the claim.
    assert "rails views and frontend behavior were not migrated" in lowered, (
        "the report must say plainly that the frontend did not come with the backend"
    )
    assert "name the retained frontend if one exists" in lowered

    # And the discovery step must classify what it finds as retained, never migrated.
    assert "report them as retained findings" in lowered
    assert "never describe them as migrated" in lowered

    # The description a dispatcher reads has to carry the same limit, since that is all
    # it sees before choosing this skill.
    assert "never claims rails views or frontend behavior were migrated" in lowered
