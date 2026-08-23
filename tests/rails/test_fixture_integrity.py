"""The frozen fixture must stay frozen.

These guard the artifact itself rather than the converter: a fixture that drifts, or
that ships state it should not, makes every other test in this directory meaningless.
"""

from __future__ import annotations

import hashlib
import json
import subprocess

from .conftest import REPO


def test_the_frozen_database_ships_without_wal_sidecars():
    """Reading the fixture creates `-wal`/`-shm`; COMMITTING one corrupts it.

    SQLite replays a stale WAL on open, so a tracked sidecar silently changes what the
    fixture contains depending on who ran the tests before it was committed. They are
    gitignored — this asserts the ignore actually held, because `git add -A` after a
    test run is exactly how they got in the first time.
    """
    tracked = subprocess.run(
        ["git", "ls-files", "tests/rails/fixtures/rails-8.1.3.1/db/"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    stray = [f for f in tracked if f.endswith(("-wal", "-shm"))]
    assert not stray, f"WAL sidecars must never be committed: {stray}"


def test_the_manifest_accounts_for_every_frozen_file(fixture_root):
    """Both directions, plus the recorded sizes.

    Checking only the listed paths verifies nothing about completeness: an extra frozen
    file, a stale build artifact, or a sidecar outside the dedicated DB check would all
    pass while the test's name promised otherwise.
    """
    manifest = json.loads((fixture_root / "fixture-manifest.json").read_text())
    listed = {entry["path"]: entry for entry in manifest["files"]}

    # Compare against what git TRACKS, not what happens to be on disk: reading the
    # fixture creates `-wal`/`-shm` beside the database, and those are gitignored
    # precisely so they never ship. A disk-based comparison would fail on any machine
    # that had run the suite, which is every machine that matters.
    prefix = fixture_root.relative_to(REPO).as_posix() + "/"
    tracked = subprocess.run(
        ["git", "ls-files", "--", str(fixture_root.relative_to(REPO))],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    on_disk = {
        f[len(prefix) :]
        for f in tracked
        if f.startswith(prefix) and not f.endswith("fixture-manifest.json")
    }
    # The manifest cannot hash itself, so it is excluded from both sides rather than
    # special-cased on one.
    assert on_disk - set(listed) == set(), "tracked files missing from the manifest"
    assert set(listed) - on_disk == set(), "manifest lists untracked files"

    for path, entry in sorted(listed.items()):
        blob = (fixture_root / path).read_bytes()
        assert hashlib.sha256(blob).hexdigest() == entry["sha256"], path
        assert len(blob) == entry["bytes"], path

    assert manifest["count"] == len(listed)
    assert manifest["total_bytes"] == sum(e["bytes"] for e in listed.values())
