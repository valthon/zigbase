"""Guards for documentation embedded in distributable ZigBase skills."""

from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SKILL_REFERENCES = REPO / "skills" / "zigbase-app-genesis" / "references"
CANONICAL_REFERENCES = {
    "agents.md": REPO / "docs" / "agents.md",
    "app-genesis.md": REPO / "docs" / "app-genesis.md",
    "deployment.md": REPO / "docs" / "deployment.md",
    "serve.md": REPO / "docs" / "serve.md",
    "testing.md": REPO / "docs" / "testing.md",
}


def test_app_genesis_skill_references_match_canonical_docs():
    """A skill release must not ship stale behavior or deployment guidance."""
    drifted = []
    for name, canonical in CANONICAL_REFERENCES.items():
        embedded = SKILL_REFERENCES / name
        if not embedded.is_file() or embedded.read_bytes() != canonical.read_bytes():
            drifted.append(name)

    assert not drifted, (
        "zigbase-app-genesis references differ from canonical docs: "
        f"{drifted}. Copy the matching docs/*.md files into "
        "skills/zigbase-app-genesis/references/."
    )
