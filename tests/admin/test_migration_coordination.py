"""Separate-process SQLite consumer batches: contention, retry and crash release."""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import sqlite3
import subprocess
import time

import pytest


@pytest.fixture(scope="module")
def migration_binary():
    value = os.environ.get("ZIGBASE_TEST_MIGRATION_COORDINATION_BINARY")
    if not value:
        pytest.skip("requires migration-coordination-fixture")
    assert Path(value).is_file()
    return value


def command(binary, directory, reverse=False):
    return [binary, "migrate", *(["rollback", "1"] if reverse else []),
            "--data-dir", str(directory)]


def environment():
    return {key: value for key, value in os.environ.items() if not key.startswith("ZIGBASE_")}


def run(binary, directory, reverse=False):
    return subprocess.run(command(binary, directory, reverse), env=environment(),
                          capture_output=True, text=True, timeout=15)


def sql(directory, query, parameters=()):
    with sqlite3.connect(directory / "data.db", timeout=2) as db:
        return db.execute(query, parameters).fetchall()


def prepare(directory, *, hold=1, fail=0):
    sql(directory, "CREATE TABLE coordination_control (hold INTEGER, fail INTEGER)")
    sql(directory, "INSERT INTO coordination_control VALUES (?, ?)", (hold, fail))


@contextmanager
def paused(binary, directory, *, reverse=False, count=1):
    process = subprocess.Popen(command(binary, directory, reverse), env=environment(),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            assert process.poll() is None, process.communicate()
            try:
                if sql(directory, "SELECT count(*) FROM coordination_events")[0][0] == count:
                    break
            except sqlite3.OperationalError as error:
                if "no such table" not in str(error):
                    raise
            time.sleep(0.01)
        else:
            pytest.fail("migration callback did not reach its gate")
        yield process
    finally:
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)


@pytest.mark.parametrize("reverse", [False, True])
def test_busy_batch_rechecks_ledger_after_retry(migration_binary, tmp_path, reverse):
    prepare(tmp_path, hold=0 if reverse else 1)
    if reverse:
        initial = run(migration_binary, tmp_path)
        assert initial.returncode == 0, initial.stderr
        sql(tmp_path, "UPDATE coordination_control SET hold=1")
    with paused(migration_binary, tmp_path, reverse=reverse, count=2 if reverse else 1) as holder:
        lock = tmp_path / "data.db.migrations.lock"
        inode = lock.stat().st_ino
        assert sql(tmp_path, "SELECT count(*) FROM _migrations WHERE name='prov:coordination_seed'") == [(1,)]
        # Both apply and reverse must refuse before consulting the consumer ledger.
        for other_reverse in [False, True]:
            other = run(migration_binary, tmp_path, other_reverse)
            assert other.returncode != 0
            assert "MigrationBusy" in other.stderr
        # Alias spelling shares the canonical main database's sidecar.
        alias = tmp_path / "alias"
        alias.mkdir()
        (alias / "data.db").symlink_to(tmp_path / "data.db")
        other = run(migration_binary, alias, reverse)
        assert other.returncode != 0 and "MigrationBusy" in other.stderr
        sql(tmp_path, "UPDATE coordination_control SET hold=0")
        _, stderr = holder.communicate(timeout=5)
        assert holder.returncode == 0, stderr
    assert lock.stat().st_ino == inode  # release never unlinks the permanent file
    if reverse:
        # A second rollback selects the now-newest seed (irreversible), not the
        # already reversed callback. Preflight refusal must release the lock too.
        again = run(migration_binary, tmp_path, reverse=True)
        assert again.returncode != 0 and "MigrationNotReversible" in again.stderr
        with (tmp_path / "data.db.migrations.lock").open("rb") as lock_file:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    else:
        again = run(migration_binary, tmp_path)
        assert again.returncode == 0, again.stderr
    assert sql(tmp_path, "SELECT direction FROM coordination_events") == ([(1,), (-1,)] if reverse else [(1,)])


def test_crash_releases_lock_but_does_not_undo_nontransactional_callback(migration_binary, tmp_path):
    prepare(tmp_path)
    with paused(migration_binary, tmp_path) as holder:
        holder.kill()
        holder.communicate(timeout=5)
    sql(tmp_path, "UPDATE coordination_control SET hold=0")
    again = run(migration_binary, tmp_path)
    assert again.returncode == 0, again.stderr
    # The first callback committed its own work but not the receipt: a retry
    # legitimately executes it again. The batch lock is not exactly-once I/O.
    assert sql(tmp_path, "SELECT direction FROM coordination_events") == [(1,), (1,)]
    assert sql(tmp_path, "SELECT count(*) FROM _migrations WHERE name='prov:coordination_pause'") == [(1,)]


def test_callback_failure_releases_lock_for_later_process(migration_binary, tmp_path):
    prepare(tmp_path, hold=0, fail=1)
    failed = run(migration_binary, tmp_path)
    assert failed.returncode != 0 and "CoordinationFixtureFailure" in failed.stderr
    sql(tmp_path, "UPDATE coordination_control SET fail=0")
    again = run(migration_binary, tmp_path)
    assert again.returncode == 0, again.stderr


def test_unavailable_sidecar_is_not_reported_as_busy(migration_binary, tmp_path):
    prepare(tmp_path, hold=0)
    (tmp_path / "data.db.migrations.lock").mkdir()
    failed = run(migration_binary, tmp_path)
    assert failed.returncode != 0
    assert "IsDir" in failed.stderr and "MigrationBusy" not in failed.stderr
    assert sql(tmp_path, "SELECT count(*) FROM sqlite_master WHERE name='_migrations'") == [(0,)]


@pytest.mark.parametrize("mode", ["apply", "rollback", "serve"])
def test_transactional_holder_refuses_before_framework_setup(migration_binary, tmp_path, mode):
    env = {**environment(), "ZIGBASE_TEST_TRANSACTIONAL": "1"}
    holder = subprocess.Popen(command(migration_binary, tmp_path), env=env, cwd=tmp_path,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 8
        while not (tmp_path / "entered").exists():
            assert holder.poll() is None, holder.communicate()
            assert time.monotonic() < deadline, "transactional migration never entered"
            time.sleep(0.01)
        args = command(migration_binary, tmp_path, mode == "rollback")
        if mode == "serve":
            args = [migration_binary, "serve", "--data-dir", str(tmp_path)]
        started = time.monotonic()
        other = subprocess.run(args, env=env, cwd=tmp_path, capture_output=True, text=True, timeout=8)
        elapsed = time.monotonic() - started
        (tmp_path / "contender.stderr").write_text(other.stderr)
        assert other.returncode != 0 and "MigrationBusy" in other.stderr, (elapsed, other.stderr)
        assert elapsed < 2, (elapsed, other.stderr)
        assert holder.poll() is None
        assert sql(tmp_path, "SELECT count(*) FROM coordination_events") == [(0,)]
        (tmp_path / "release").touch()
        _, stderr = holder.communicate(timeout=5)
        assert holder.returncode == 0, stderr
        retry = subprocess.run(command(migration_binary, tmp_path), env=env, cwd=tmp_path,
                               capture_output=True, text=True, timeout=8)
        assert retry.returncode == 0, retry.stderr
        assert sql(tmp_path, "SELECT count(*) FROM coordination_events") == [(1,)]
    finally:
        if holder.poll() is None:
            holder.kill()
        holder.communicate(timeout=5)
