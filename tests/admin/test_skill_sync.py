"""Self-testing guards for ZigBase's distributable official skills."""

import shutil
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parents[2]
REFERENCE_NAMES = (
    "agents.md",
    "app-genesis.md",
    "deployment.md",
    "docker.md",
    "openapi.md",
    "serve.md",
    "testing.md",
)
MIGRATION_REFERENCE_NAMES = (
    "agents.md",
    "deployment.md",
    "docker.md",
    "migrate-pocketbase.md",
    "migration-tools.md",
    "openapi.md",
    "serve.md",
)
PAIRING_REFERENCE_NAMES = ("zigapagos-pairing.md",)


def validate_skill(repo: Path) -> list[str]:
    errors = []
    skill = repo / "skills" / "zigbase-app-genesis"
    skill_md = skill / "SKILL.md"
    if not skill.is_dir() or not skill_md.is_file():
        return ["skill.missing"]

    body = skill_md.read_text()
    if len(body.splitlines()) > 500:
        errors.append("skill.oversized")
    if "references/docker.md" not in body:
        errors.append("skill.docker_reference")
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


def validate_migration_skill(repo: Path) -> list[str]:
    errors = []
    skill = repo / "skills" / "zigbase-migrate-pocketbase"
    skill_md = skill / "SKILL.md"
    if not skill.is_dir() or not skill_md.is_file():
        return ["skill.missing"]
    body = skill_md.read_text()
    if len(body.splitlines()) > 500:
        errors.append("skill.oversized")
    if "references/migrate-pocketbase.md" not in body:
        errors.append("skill.guide_reference")
    if not body.startswith("---\n") or "\n---\n" not in body[4:]:
        errors.append("skill.frontmatter")
    else:
        frontmatter = body.split("---\n", 2)[1]
        fields = {}
        for line in frontmatter.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                fields[key.strip()] = value.strip()
        if set(fields) != {"name", "description"}:
            errors.append("skill.frontmatter_fields")
        if fields.get("name") != "zigbase-migrate-pocketbase":
            errors.append("skill.name")
        if not fields.get("description"):
            errors.append("skill.description")

    metadata = skill / "agents" / "openai.yaml"
    if not metadata.is_file():
        errors.append("skill.metadata_missing")
    else:
        ui = metadata.read_text()
        for required in (
            "display_name:",
            "short_description:",
            "$zigbase-migrate-pocketbase",
        ):
            if required not in ui:
                errors.append("skill.metadata_invalid")
                break

    expected_markdown = {"SKILL.md"} | {
        f"references/{name}" for name in MIGRATION_REFERENCE_NAMES
    }
    actual_markdown = {
        path.relative_to(skill).as_posix() for path in skill.rglob("*.md")
    }
    if actual_markdown != expected_markdown:
        errors.append("skill.unexpected_markdown")
    for name in MIGRATION_REFERENCE_NAMES:
        canonical = repo / "docs" / name
        embedded = skill / "references" / name
        if not embedded.is_file():
            errors.append(f"reference.missing:{name}")
        elif not canonical.is_file() or embedded.read_bytes() != canonical.read_bytes():
            errors.append(f"reference.drift:{name}")
    return errors


def copy_migration_subject(tmp_path: Path) -> Path:
    subject = tmp_path / "repo"
    (subject / "docs").mkdir(parents=True)
    (subject / "skills").mkdir()
    shutil.copytree(
        REPO / "skills" / "zigbase-migrate-pocketbase",
        subject / "skills" / "zigbase-migrate-pocketbase",
    )
    for name in MIGRATION_REFERENCE_NAMES:
        shutil.copy(REPO / "docs" / name, subject / "docs" / name)
    return subject


def validate_pairing_skill(repo: Path) -> list[str]:
    errors = []
    skill = repo / "skills" / "zigbase-zigapagos-fullstack"
    skill_md = skill / "SKILL.md"
    if not skill.is_dir() or not skill_md.is_file():
        return ["skill.missing"]

    body = skill_md.read_text()
    if len(body.splitlines()) > 500:
        errors.append("skill.oversized")
    if "references/zigapagos-pairing.md" not in body:
        errors.append("skill.guide_reference")
    if not body.startswith("---\n") or "\n---\n" not in body[4:]:
        errors.append("skill.frontmatter")
    else:
        frontmatter = body.split("---\n", 2)[1]
        fields = {}
        for line in frontmatter.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                fields[key.strip()] = value.strip()
        if set(fields) != {"name", "description"}:
            errors.append("skill.frontmatter_fields")
        if fields.get("name") != "zigbase-zigapagos-fullstack":
            errors.append("skill.name")
        if not fields.get("description"):
            errors.append("skill.description")

    metadata = skill / "agents" / "openai.yaml"
    if not metadata.is_file():
        errors.append("skill.metadata_missing")
    else:
        ui = metadata.read_text()
        for required in (
            "display_name:",
            "short_description:",
            "$zigbase-zigapagos-fullstack",
        ):
            if required not in ui:
                errors.append("skill.metadata_invalid")
                break

    expected_markdown = {"SKILL.md"} | {
        f"references/{name}" for name in PAIRING_REFERENCE_NAMES
    }
    actual_markdown = {
        path.relative_to(skill).as_posix() for path in skill.rglob("*.md")
    }
    if actual_markdown != expected_markdown:
        errors.append("skill.unexpected_markdown")
    for name in PAIRING_REFERENCE_NAMES:
        canonical = repo / "docs" / name
        embedded = skill / "references" / name
        if not embedded.is_file():
            errors.append(f"reference.missing:{name}")
        elif not canonical.is_file() or embedded.read_bytes() != canonical.read_bytes():
            errors.append(f"reference.drift:{name}")
    return errors


def copy_pairing_subject(tmp_path: Path) -> Path:
    subject = tmp_path / "repo"
    (subject / "docs").mkdir(parents=True)
    (subject / "skills").mkdir()
    shutil.copytree(
        REPO / "skills" / "zigbase-zigapagos-fullstack",
        subject / "skills" / "zigbase-zigapagos-fullstack",
    )
    for name in PAIRING_REFERENCE_NAMES:
        shutil.copy(REPO / "docs" / name, subject / "docs" / name)
    return subject


def test_app_genesis_skill_is_valid_and_synced():
    assert validate_skill(REPO) == []


def test_pocketbase_migration_skill_is_valid_and_synced():
    assert validate_migration_skill(REPO) == []


def test_zigapagos_pairing_skill_is_valid_and_synced():
    assert validate_pairing_skill(REPO) == []


@pytest.mark.parametrize(
    ("mutation", "expected"),
    [
        ("missing_reference", "reference.missing:zigapagos-pairing.md"),
        ("changed_reference", "reference.drift:zigapagos-pairing.md"),
        ("unexpected_markdown", "skill.unexpected_markdown"),
        ("wrong_name", "skill.name"),
        ("extra_frontmatter", "skill.frontmatter_fields"),
        ("bad_metadata", "skill.metadata_invalid"),
        ("missing_guide", "skill.guide_reference"),
    ],
)
def test_pairing_guard_rejects_drift(tmp_path, mutation, expected):
    subject = copy_pairing_subject(tmp_path)
    skill = subject / "skills" / "zigbase-zigapagos-fullstack"
    if mutation == "missing_reference":
        (skill / "references" / "zigapagos-pairing.md").unlink()
    elif mutation == "changed_reference":
        (skill / "references" / "zigapagos-pairing.md").write_text("stale\n")
    elif mutation == "unexpected_markdown":
        (skill / "README.md").write_text("unexpected\n")
    elif mutation == "wrong_name":
        path = skill / "SKILL.md"
        path.write_text(
            path.read_text().replace("name: zigbase-zigapagos-fullstack", "name: wrong")
        )
    elif mutation == "extra_frontmatter":
        path = skill / "SKILL.md"
        path.write_text(path.read_text().replace("---\n\n#", "extra: no\n---\n\n#", 1))
    elif mutation == "bad_metadata":
        path = skill / "agents" / "openai.yaml"
        path.write_text(path.read_text().replace("$zigbase-zigapagos-fullstack", "$wrong"))
    elif mutation == "missing_guide":
        path = skill / "SKILL.md"
        path.write_text(
            path.read_text().replace(
                "references/zigapagos-pairing.md", "references/missing.md"
            )
        )
    assert expected in validate_pairing_skill(subject)


@pytest.mark.parametrize(
    ("mutation", "expected"),
    [
        ("missing_reference", "reference.missing:migrate-pocketbase.md"),
        ("changed_reference", "reference.drift:migrate-pocketbase.md"),
        ("unexpected_markdown", "skill.unexpected_markdown"),
        ("wrong_name", "skill.name"),
        ("extra_frontmatter", "skill.frontmatter_fields"),
        ("bad_metadata", "skill.metadata_invalid"),
    ],
)
def test_pocketbase_guard_rejects_drift(tmp_path, mutation, expected):
    subject = copy_migration_subject(tmp_path)
    skill = subject / "skills" / "zigbase-migrate-pocketbase"
    if mutation == "missing_reference":
        (skill / "references" / "migrate-pocketbase.md").unlink()
    elif mutation == "changed_reference":
        (skill / "references" / "migrate-pocketbase.md").write_text("stale\n")
    elif mutation == "unexpected_markdown":
        (skill / "README.md").write_text("unexpected\n")
    elif mutation == "wrong_name":
        path = skill / "SKILL.md"
        path.write_text(
            path.read_text().replace(
                "name: zigbase-migrate-pocketbase", "name: wrong"
            )
        )
    elif mutation == "extra_frontmatter":
        path = skill / "SKILL.md"
        path.write_text(path.read_text().replace("---\n\n#", "extra: no\n---\n\n#", 1))
    elif mutation == "bad_metadata":
        path = skill / "agents" / "openai.yaml"
        path.write_text(path.read_text().replace("$zigbase-migrate-pocketbase", "$wrong"))
    assert expected in validate_migration_skill(subject)


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
        ("missing_docker_guidance", "skill.docker_reference"),
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
    elif mutation == "missing_docker_guidance":
        path = skill / "SKILL.md"
        path.write_text(path.read_text().replace("references/docker.md", "references/deployment.md"))

    assert expected in validate_skill(subject)
