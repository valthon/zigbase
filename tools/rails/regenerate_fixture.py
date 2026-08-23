#!/usr/bin/env python3
"""Regenerate the committed Rails fixture from its recorded source.

This is a **maintainer** operation and it needs Ruby and Rails. Ordinary CI never runs
it: the whole point of freezing the fixture is that the test suite works offline from a
recording, so a contributor without a Ruby toolchain can still run `pytest tests/rails`.

Run it when the fixture's application changes, when the extractor's output shape
changes, or to verify that the committed fixture is still reproducible from its source.

    python3 tools/rails/regenerate_fixture.py --check     # rebuild and diff, write nothing
    python3 tools/rails/regenerate_fixture.py             # rebuild and update the fixture

The regeneration scripts under `tools/rails/fixture/` are self-locating and expect a
working directory laid out as:

    <work>/bookclub_api/                 the Rails application
    <work>/checks/                       read-only inspection scripts
    <work>/tools_rails_export_source.rb  a copy of the repository extractor
    <work>/proof.sh, record_case.rb, freeze.rb, upload_cover.png
    <work>/frozen/                       the output tree

That directory is built in a temporary location rather than in the checkout, because
`proof.sh` boots a real server, mutates a real database, and writes a 45KB transcript --
none of which belongs in a working tree.

Two properties the scripts enforce, worth knowing before you read their output:

* `freeze.rb` refuses to run unless the database is provably the pristine seed (three
  triggers, one view, exact row counts, no signup from the HTTP transcript). Freezing a
  mid-transcript database produces an artifact that looks structurally valid and is
  wrong, so this is a precondition rather than a matter of running things in order.
* `record_case.rb --assemble` validates the recorded HTTP cases before writing them and
  exits non-zero without writing on any violation. A regeneration that can silently
  emit a wrong fixture is worse than one that fails, because the wrong artifact is
  indistinguishable from the right one.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FIXTURE = REPO / "tests" / "rails" / "fixtures" / "rails-8.1.3.1"
SCRIPTS = REPO / "tools" / "rails" / "fixture"
EXTRACTOR = REPO / "tools" / "rails" / "export_source.rb"

# Pinned deliberately: the fixture records what one exact toolchain produced, and a
# different Rails would silently record different reflections.
RUBY = "ruby@4.0.1"
RAILS_VERSION = "8.1.3.1"


def build_workspace(work: Path) -> None:
    shutil.copytree(FIXTURE / "app_source", work / "bookclub_api")
    shutil.copytree(SCRIPTS / "checks", work / "checks")
    for name in ("proof.sh", "record_case.rb", "freeze.rb", "upload_cover.png"):
        shutil.copy2(SCRIPTS / name, work / name)
    # The frozen inventory has to be reproducible from the *repository* extractor;
    # generating it from a private copy would break provenance.
    shutil.copy2(EXTRACTOR, work / "tools_rails_export_source.rb")
    (work / "proof.sh").chmod(0o755)

    # The seeded database and its blob are restored so the app boots against known
    # state; proof.sh rebuilds both from migrations and seeds before freezing anyway.
    storage = work / "bookclub_api" / "storage"
    storage.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        FIXTURE / "db" / "development.sqlite3", storage / "development.sqlite3"
    )
    for blob in (FIXTURE / "storage").rglob("*"):
        if blob.is_file():
            target = storage / blob.relative_to(FIXTURE / "storage")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(blob, target)


def run_proof(work: Path) -> None:
    subprocess.run(
        ["mise", "exec", RUBY, "--", "bundle", "install", "--quiet"],
        cwd=work / "bookclub_api",
        check=True,
    )
    subprocess.run(["bash", "proof.sh"], cwd=work, check=True)
    # proof.sh drives the transcript and leaves the database in its canonical seeded
    # state; freeze.rb is what actually assembles `frozen/`, and it refuses to run
    # unless that state is provably pristine.
    subprocess.run(
        ["mise", "exec", RUBY, "--", "ruby", "freeze.rb"], cwd=work, check=True
    )


# SQLite writes these beside the database whenever anything opens it, and the test suite
# opens it constantly. They are gitignored, so a tree that differs only by their presence
# is byte-identical as far as the repository is concerned -- comparing them made `--check`
# report a reproducible fixture as broken on any machine that had run pytest.
TRANSIENT_SUFFIXES = ("-wal", "-shm")


def tree_digest(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(p for p in root.rglob("*") if p.is_file())
        if not path.name.endswith(TRANSIENT_SUFFIXES)
    }


def report(before: dict[str, str], after: dict[str, str]) -> int:
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    changed = sorted(k for k in set(before) & set(after) if before[k] != after[k])
    for label, items in (("added", added), ("removed", removed), ("changed", changed)):
        for item in items:
            print(f"  {label}: {item}")
    if not (added or removed or changed):
        print("  fixture is reproducible: no differences")
        return 0
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="rebuild and report differences without updating the committed fixture",
    )
    parser.add_argument(
        "--work",
        type=Path,
        help="reuse an explicit working directory instead of a temporary one",
    )
    args = parser.parse_args()

    if shutil.which("mise") is None:
        print("regenerate_fixture: mise is required to pin Ruby", file=sys.stderr)
        return 1

    holder = None
    if args.work:
        work = args.work
        if work.exists():
            shutil.rmtree(work)
        work.mkdir(parents=True)
    else:
        holder = tempfile.TemporaryDirectory(prefix="zigbase-rails-fixture-")
        work = Path(holder.name)

    try:
        print(f"regenerating Rails {RAILS_VERSION} fixture in {work}")
        build_workspace(work)
        run_proof(work)

        produced = work / "frozen"
        if not produced.is_dir():
            print(
                "regenerate_fixture: proof.sh produced no frozen tree", file=sys.stderr
            )
            return 1

        before, after = tree_digest(FIXTURE), tree_digest(produced)
        status = report(before, after)
        if args.check:
            return status
        if status:
            shutil.rmtree(FIXTURE)
            shutil.copytree(produced, FIXTURE)
            print(f"updated {FIXTURE.relative_to(REPO)}")
        return 0
    finally:
        if holder is not None:
            holder.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
