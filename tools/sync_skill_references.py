#!/usr/bin/env python3
"""Generate distributable skill references from canonical repository docs."""

from __future__ import annotations

import argparse
import os
import re
from pathlib import Path
from urllib.parse import quote


REPOSITORY_URL = "https://github.com/valthon/zigbase/blob/main"
SKILL_REFERENCES = {
    "zigbase-app-genesis": (
        "agents.md",
        "app-genesis.md",
        "deployment.md",
        "docker.md",
        "openapi.md",
        "serve.md",
        "testing.md",
    ),
    "zigbase-migrate-pocketbase": (
        "agents.md",
        "deployment.md",
        "docker.md",
        "migrate-pocketbase.md",
        "migration-tools.md",
        "openapi.md",
        "serve.md",
    ),
    "zigbase-zigapagos-fullstack": ("zigapagos-pairing.md",),
    "zigbase-migrate-express": (
        "agents.md",
        "deployment.md",
        "docker.md",
        "migrate-express.md",
        "migration-tools.md",
        "openapi.md",
        "serve.md",
    ),
    "zigbase-migrate-laravel": (
        "agents.md",
        "deployment.md",
        "migrate-laravel.md",
        "migration-tools.md",
        "openapi.md",
    ),
    "zigbase-migrate-go": (
        "agents.md",
        "deployment.md",
        "migrate-go.md",
        "migration-tools.md",
        "openapi.md",
    ),
    "zigbase-migrate-rails-api": (
        "agents.md",
        "deployment.md",
        "docker.md",
        "migrate-rails-api.md",
        "migration-tools.md",
        "openapi.md",
        "serve.md",
    ),
    "zigbase-migrate-rails-fullstack": (
        "agents.md",
        "deployment.md",
        "docker.md",
        "migrate-rails-api.md",
        "migrate-rails-fullstack.md",
        "migration-tools.md",
        "openapi.md",
        "serve.md",
        "zigapagos-pairing.md",
    ),
}
RELATIVE_MARKDOWN_LINK = re.compile(
    r"(?P<prefix>!?\[[^\]]*\]\()(?P<target>(?![a-z][a-z0-9+.-]*:|#|/)[^\s)]+\.md(?:#[^\s)]*)?)(?P<suffix>\))",
    re.IGNORECASE,
)


def render_reference(repo: Path, name: str) -> str:
    source = repo / "docs" / name
    text = source.read_text()

    def replace(match: re.Match[str]) -> str:
        target = match.group("target")
        path_text, marker, fragment = target.partition("#")
        resolved = Path(
            os.path.normpath(source.parent.joinpath(path_text))
        ).relative_to(repo)
        url = f"{REPOSITORY_URL}/{quote(resolved.as_posix())}"
        if marker:
            url += f"#{fragment}"
        return f"{match.group('prefix')}{url}{match.group('suffix')}"

    return RELATIVE_MARKDOWN_LINK.sub(replace, text)


def sync_references(repo: Path, *, check: bool) -> list[str]:
    drift = []
    for skill, names in SKILL_REFERENCES.items():
        for name in names:
            destination = repo / "skills" / skill / "references" / name
            expected = render_reference(repo, name)
            if not destination.is_file() or destination.read_text() != expected:
                drift.append(f"{skill}/references/{name}")
                if not check:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_text(expected)
    return drift


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    drift = sync_references(repo, check=args.check)
    if args.check and drift:
        print("skill references need regeneration:")
        for path in drift:
            print(f"  {path}")
        return 1
    if not args.check:
        print(f"synchronized {sum(map(len, SKILL_REFERENCES.values()))} references")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
