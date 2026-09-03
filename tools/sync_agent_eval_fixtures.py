#!/usr/bin/env python3
"""Synchronize repository tools intentionally vendored into agent-eval fixtures."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


COPIES = {
    "tools/rails/__init__.py": (
        "evals/agents/scenarios/rails-api/fixture/tools/rails/__init__.py",
        "evals/agents/scenarios/rails-fullstack/fixture/tools/rails/__init__.py",
        "tests/agent_evals/fixtures/rails-api/positive/tools/rails/__init__.py",
    ),
    "tools/rails/_core.py": (
        "evals/agents/scenarios/rails-api/fixture/tools/rails/_core.py",
        "evals/agents/scenarios/rails-fullstack/fixture/tools/rails/_core.py",
        "tests/agent_evals/fixtures/rails-api/positive/tools/rails/_core.py",
    ),
    "tools/rails/rails2zb.py": (
        "evals/agents/scenarios/rails-api/fixture/tools/rails/rails2zb.py",
        "tests/agent_evals/fixtures/rails-api/positive/tools/rails/rails2zb.py",
    ),
    "tools/rails/fullstack.py": (
        "evals/agents/scenarios/rails-fullstack/fixture/tools/rails/fullstack.py",
    ),
    "tools/rails/contracts/rails-handoff.v1.schema.json": (
        "evals/agents/scenarios/rails-fullstack/fixture/tools/rails/contracts/rails-handoff.v1.schema.json",
    ),
    "tools/rails/contracts/rails-presentation.v1.schema.json": (
        "evals/agents/scenarios/rails-fullstack/fixture/tools/rails/contracts/rails-presentation.v1.schema.json",
    ),
    "tools/replay/__init__.py": (
        "evals/agents/scenarios/rails-fullstack/fixture/tools/replay/__init__.py",
    ),
    "tools/replay/_contract.py": (
        "evals/agents/scenarios/rails-fullstack/fixture/tools/replay/_contract.py",
    ),
    "tools/replay/zb_replay.py": (
        "evals/agents/scenarios/rails-fullstack/fixture/tools/replay/zb_replay.py",
    ),
}


def synchronize(repo: Path, *, check: bool) -> list[str]:
    drift: list[str] = []
    for source_name, destination_names in COPIES.items():
        source = repo / source_name
        expected = source.read_bytes()
        for destination_name in destination_names:
            destination = repo / destination_name
            if not destination.is_file() or destination.read_bytes() != expected:
                drift.append(destination_name)
                if not check:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, destination)
    return drift


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    drift = synchronize(repo, check=args.check)
    if args.check and drift:
        print("agent-eval fixture tools need synchronization:")
        for path in drift:
            print(f"  {path}")
        return 1
    if not args.check:
        print(f"synchronized {sum(map(len, COPIES.values()))} agent-eval fixture files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
