"""Self-testing guards for the distributable App Genesis skill."""

import shutil
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parents[2]
REFERENCE_NAMES = (
    "agents.md",
    "app-genesis.md",
    "deployment.md",
    "serve.md",
    "testing.md",
)


def validate_skill(repo: Path) -> list[str]:
    errors = []
    skill = repo / "skills" / "zigbase-app-genesis"
    skill_md = skill / "SKILL.md"
    if not skill.is_dir() or not skill_md.is_file():
        return ["skill.missing"]

    body = skill_md.read_text()
    if len(body.splitlines()) > 500:
        errors.append("skill.oversized")
    if not body.startswith("---\n") or "\n---\n" not in body[4:]:
        errors.append("skill.frontmatter")
    else:
        frontmatter = body.split("---\n", 2)[1]
        fields = {}
        for line in frontmatter.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                fields[key.strip()] = value.strip()
        if fields.get("name") != "zigbase-app-genesis":
            errors.append("skill.name")
        if not fields.get("description"):
            errors.append("skill.description")

    metadata = skill / "agents" / "openai.yaml"
    if not metadata.is_file():
        errors.append("skill.metadata_missing")
    else:
        ui = metadata.read_text()
        for required in ("display_name:", "short_description:", "$zigbase-app-genesis"):
            if required not in ui:
                errors.append("skill.metadata_invalid")
                break

    for name in REFERENCE_NAMES:
        canonical = repo / "docs" / name
        embedded = skill / "references" / name
        if not embedded.is_file():
            errors.append(f"reference.missing:{name}")
        elif not canonical.is_file() or embedded.read_bytes() != canonical.read_bytes():
            errors.append(f"reference.drift:{name}")
    return errors


def copy_subject(tmp_path: Path) -> Path:
    subject = tmp_path / "repo"
    (subject / "docs").mkdir(parents=True)
    (subject / "skills").mkdir()
    shutil.copytree(
        REPO / "skills" / "zigbase-app-genesis",
        subject / "skills" / "zigbase-app-genesis",
    )
    for name in REFERENCE_NAMES:
        shutil.copy(REPO / "docs" / name, subject / "docs" / name)
    return subject


def test_app_genesis_skill_is_valid_and_synced():
    assert validate_skill(REPO) == []


@pytest.mark.parametrize(
    ("mutation", "expected"),
    [
        ("missing_skill", "skill.missing"),
        ("missing_reference", "reference.missing:agents.md"),
        ("changed_reference", "reference.drift:agents.md"),
        ("wrong_name", "skill.name"),
        ("missing_description", "skill.description"),
        ("oversized", "skill.oversized"),
        ("missing_metadata", "skill.metadata_missing"),
    ],
)
def test_guard_fails_for_each_supported_drift(tmp_path, mutation, expected):
    subject = copy_subject(tmp_path)
    skill = subject / "skills" / "zigbase-app-genesis"
    if mutation == "missing_skill":
        shutil.rmtree(skill)
    elif mutation == "missing_reference":
        (skill / "references" / "agents.md").unlink()
    elif mutation == "changed_reference":
        (skill / "references" / "agents.md").write_text("stale\n")
    elif mutation == "wrong_name":
        path = skill / "SKILL.md"
        path.write_text(
            path.read_text().replace("name: zigbase-app-genesis", "name: wrong")
        )
    elif mutation == "missing_description":
        path = skill / "SKILL.md"
        lines = [
            "description:" if line.startswith("description:") else line
            for line in path.read_text().splitlines()
        ]
        path.write_text("\n".join(lines) + "\n")
    elif mutation == "oversized":
        path = skill / "SKILL.md"
        path.write_text(path.read_text() + ("extra\n" * 501))
    elif mutation == "missing_metadata":
        (skill / "agents" / "openai.yaml").unlink()

    assert expected in validate_skill(subject)
