"""Real CLI deletion controls; no backend or network writes outside tmp_path."""
import fcntl
import json
import os
import pathlib
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

import pytest
from test_file_inventory import inventory_binary, inventory_data


def reconcile(binary, data, *args, env=None):
    return subprocess.run(
        [binary, "files", "reconcile", "--data-dir", str(data), *args],
        env={**os.environ, "ZIGBASE_DB_URL": "", "ZIGBASE_S3_BUCKET": "", **(env or {})},
        capture_output=True, text=True, timeout=10,
    )


def blob(data, key, age=100):
    path = data / "storage" / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"payload")
    os.utime(path, (time.time() - age, time.time() - age))
    return path


def test_dry_run_age_bounds_and_explicit_deletion(inventory_binary, inventory_data):
    data = inventory_data
    kept = blob(data, "images/r1/a.png")
    old = blob(data, "images/r1/b.png")
    recent = blob(data, "images/r1/c.png", age=0)
    unknown = blob(data, "absent/r1/x.png")
    before = (data / "data.db").read_bytes()
    result = reconcile(inventory_binary, data, "--min-age-seconds", "60", "--limit", "2")
    assert result.returncode == 0, result.stderr
    first = json.loads(result.stdout)
    assert first["mode"] == "dry-run" and first["hasNext"]
    assert [i["outcome"] for i in first["items"]] == ["unknown", "referenced"]
    assert not (data / "storage" / ".zigbase-maintenance.lock").exists()
    assert (data / "data.db").read_bytes() == before
    result = reconcile(inventory_binary, data, "--min-age-seconds", "60", "--limit", "2",
                       "--cursor", first["nextCursor"], "--apply")
    assert result.returncode == 0, result.stderr
    assert [i["outcome"] for i in json.loads(result.stdout)["items"]] == ["deleted", "recent"]
    assert not old.exists()
    assert kept.exists() and recent.exists() and unknown.exists()


def test_reused_record_and_hidden_expired_physical_reference_survive(inventory_binary, inventory_data):
    data = inventory_data
    target = blob(data, "images/r1/reused.png")
    assert json.loads(reconcile(inventory_binary, data, "--min-age-seconds", "1").stdout)["items"][0]["outcome"] == "candidate"
    with sqlite3.connect(data / "data.db") as conn:
        conn.execute("ALTER TABLE images ADD COLUMN expires TEXT")
        conn.execute("DELETE FROM images")
        conn.execute("INSERT INTO images VALUES ('r1','','','reused.png','1970-01-01T00:00:00Z')")
        fields = [
            {"id": "photo", "name": "photo", "type": "file", "hidden": True, "options": {"maxSelect": 1}},
            {"id": "expires", "name": "expires", "type": "date", "options": {}},
        ]
        conn.execute("UPDATE _collections SET schema=?, options=?",
                     (json.dumps(fields), json.dumps({"ttl": {"field": "expires"}})))
    result = reconcile(inventory_binary, data, "--min-age-seconds", "1", "--apply")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["items"][0]["outcome"] == "referenced"
    assert target.exists()


def test_changed_object_is_reclassified_not_approved_by_prior_dry_run(inventory_binary, inventory_data):
    target = blob(inventory_data, "images/r1/orphan.png")
    result = reconcile(inventory_binary, inventory_data, "--min-age-seconds", "60")
    assert json.loads(result.stdout)["items"][0]["outcome"] == "candidate"
    target.write_bytes(b"new replacement")
    result = reconcile(inventory_binary, inventory_data, "--min-age-seconds", "60", "--apply")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["items"][0]["outcome"] == "recent"
    assert target.read_bytes() == b"new replacement"


def test_active_lease_and_root_alias_refuse_apply(inventory_binary, inventory_data, tmp_path):
    target = blob(inventory_data, "images/r1/orphan.png")
    with (inventory_data / "storage" / ".zigbase-maintenance.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
        alias = tmp_path / "alias"
        alias.mkdir()
        (alias / "storage").symlink_to(inventory_data / "storage", target_is_directory=True)
        (alias / "data.db").symlink_to(inventory_data / "data.db")
        result = reconcile(inventory_binary, alias, "--apply", "--min-age-seconds", "1")
        assert result.returncode != 0 and "WouldBlock" in result.stderr
    assert target.exists()


def test_database_writer_contention_and_unknown_metadata_do_not_delete(inventory_binary, inventory_data):
    target = blob(inventory_data, "images/r1/orphan.png")
    with sqlite3.connect(inventory_data / "data.db") as writer:
        writer.execute("BEGIN IMMEDIATE")
        result = reconcile(inventory_binary, inventory_data, "--apply", "--min-age-seconds", "1")
        assert result.returncode != 0
    assert target.exists()
    with sqlite3.connect(inventory_data / "data.db") as conn:
        conn.execute("UPDATE _collections SET schema='not-json'")
    result = reconcile(inventory_binary, inventory_data, "--apply", "--min-age-seconds", "1")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["items"][0]["outcome"] == "unknown"
    assert target.exists()


@pytest.mark.parametrize("env", [
    {"ZIGBASE_S3_BUCKET": "never-connect"},
    {"ZIGBASE_DB_URL": "postgres://invalid/no-connect"},
])
@pytest.mark.parametrize("mode", [(), ("--apply",)])
def test_remote_backends_are_refused_before_storage_changes(inventory_binary, inventory_data, env, mode):
    target = blob(inventory_data, "images/r1/orphan.png")
    result = reconcile(inventory_binary, inventory_data, *mode, env=env)
    assert result.returncode != 0 and "ReconciliationLocalSqliteOnly" in result.stderr
    assert target.exists()
    assert not (inventory_data / "storage" / ".zigbase-maintenance.lock").exists()


def test_symlinks_are_not_deleted_or_followed(inventory_binary, inventory_data):
    target = blob(inventory_data, "images/r1/orphan.png")
    (target.parent / "link").symlink_to(target)
    (inventory_data / "storage" / "external").symlink_to(target.parent, target_is_directory=True)
    (inventory_data / "storage" / ".zigbase-maintenance.lock").symlink_to(target)
    result = reconcile(inventory_binary, inventory_data, "--apply", "--min-age-seconds", "1")
    assert result.returncode != 0
    assert target.exists() and target.read_bytes() == b"payload"


@pytest.mark.skipif(os.geteuid() == 0, reason="root bypasses the lockfile permission denial")
def test_readonly_existing_lock_allows_shared_boot_but_not_exclusive_apply(inventory_binary, tmp_path):
    storage = tmp_path / "storage"
    storage.mkdir()
    lock = storage / ".zigbase-maintenance.lock"
    lock.write_bytes(b"")
    inode = lock.stat().st_ino
    lock.chmod(0o444)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(tmp_path), "ZIGBASE_DB_URL": "", "ZIGBASE_S3_BUCKET": "",
           "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"}
    command = [inventory_binary, "serve", "--ignore-lock", "--insecure-cookies"]
    try:
        proc = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                try:
                    request(f"http://127.0.0.1:{port}", "/api/health")
                    break
                except OSError:
                    assert proc.poll() is None, proc.stderr.read()
                    time.sleep(0.05)
            else:
                pytest.fail("server failed to become ready with a read-only lock")
            assert lock.stat().st_ino == inode and lock.read_bytes() == b""
            result = reconcile(inventory_binary, tmp_path, "--apply")
            assert result.returncode != 0 and "AccessDenied" in result.stderr
        finally:
            proc.terminate()
            proc.communicate(timeout=10)
        # Shared opening must still honor an exclusive lease held elsewhere.
        lock.chmod(0o644)
        with lock.open("r+") as owner:
            fcntl.flock(owner, fcntl.LOCK_EX)
            lock.chmod(0o444)
            result = subprocess.run(command, env=env, capture_output=True, timeout=10)
            assert result.returncode != 0 and b"WouldBlock" in result.stderr
        assert lock.stat().st_ino == inode
    finally:
        lock.chmod(0o644)


@pytest.mark.parametrize("mode", [(), ("--apply",)])
def test_invalid_later_filename_refuses_whole_page_before_deletion(inventory_binary, inventory_data, mode):
    candidate = blob(inventory_data, "images/r1/a-orphan.png")
    preview = reconcile(inventory_binary, inventory_data, "--min-age-seconds", "1")
    assert json.loads(preview.stdout)["items"][0]["outcome"] == "candidate"
    bad_path = os.fsencode(candidate.parent) + b"/z-\xff.png"
    descriptor = os.open(bad_path, os.O_CREAT | os.O_WRONLY, 0o600)
    os.close(descriptor)
    result = reconcile(inventory_binary, inventory_data, "--min-age-seconds", "1", *mode)
    assert result.returncode != 0 and "InvalidInventoryUtf8" in result.stderr
    assert not result.stdout
    assert candidate.read_bytes() == b"payload"
    assert os.path.exists(bad_path)


@pytest.mark.skipif(os.geteuid() == 0, reason="root bypasses the directory permission denial")
def test_partial_unlink_failure_is_reported_and_exits_nonzero(inventory_binary, inventory_data):
    removed = blob(inventory_data, "images/r1/orphan.png")
    denied = blob(inventory_data, "images/r2/orphan.png")
    denied.parent.chmod(0o555)
    try:
        result = reconcile(inventory_binary, inventory_data, "--apply", "--min-age-seconds", "1")
        assert result.returncode != 0, result.stderr
        report = json.loads(result.stdout)
        assert report["failures"] == 1
        assert [item["outcome"] for item in report["items"]] == ["deleted", "failed"]
        assert report["items"][1]["failure"] == "AccessDenied"
        assert not removed.exists() and denied.exists()
    finally:
        denied.parent.chmod(0o755)


def request(server, path, body=None, token=None, content_type="application/json"):
    headers = {"Content-Type": content_type}
    if token:
        headers["Authorization"] = "Bearer " + token
    if body is not None and not isinstance(body, bytes):
        body = json.dumps(body).encode()
    with urllib.request.urlopen(urllib.request.Request(server + path, body, headers), timeout=10) as response:
        return json.loads(response.read())


def test_ignore_lock_server_pins_storage_during_put_before_commit(inventory_binary, tmp_path):
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(tmp_path), "ZIGBASE_DB_URL": "",
           "ZIGBASE_S3_BUCKET": "", "ZIGBASE_SERVE_BACKGROUND": "0"}
    result = subprocess.run([inventory_binary, "superuser", "create", "--email", "admin@x.io",
                             "--password", "adminpassword"], env=env, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env["ZIGBASE_HTTP_PORT"] = str(port)
    server = f"http://127.0.0.1:{port}"
    with (tmp_path / "serve.log").open("wb") as log:
        proc = subprocess.Popen([inventory_binary, "serve", "--ignore-lock", "--insecure-cookies"],
                                env=env, stdout=log, stderr=log)
    worker = None
    writer = None
    try:
        for _ in range(100):
            try:
                request(server, "/api/health")
                break
            except (OSError, ValueError):
                assert proc.poll() is None
                time.sleep(0.05)
        token = request(server, "/api/collections/_superusers/auth-with-password",
                        {"identity": "admin@x.io", "password": "adminpassword"})["token"]
        # Exactly one boot-lifetime descriptor, independent of HTTP request count.
        if sys.platform == "linux":
            lease_fds = [path for path in (pathlib.Path("/proc") / str(proc.pid) / "fd").iterdir()
                         if os.readlink(path).endswith("/.zigbase-maintenance.lock")]
            assert len(lease_fds) == 1
        request(server, "/api/collections", {"name": "photos", "type": "base",
            "fields": [{"id": "", "name": "file", "type": "file", "options": {"maxSelect": 1}}]}, token)
        record = request(server, "/api/collections/photos/records", {}, token)
        # Hold the SQLite writer: the HTTP upload can PUT, but cannot commit its reference.
        writer = sqlite3.connect(tmp_path / "data.db")
        writer.execute("BEGIN IMMEDIATE")
        body = b'--boundary\r\nContent-Disposition: form-data; name="file"; filename="pending.txt"\r\nContent-Type: text/plain\r\n\r\npending\r\n--boundary--\r\n'
        errors = []
        def upload():
            try:
                req = urllib.request.Request(server + "/api/collections/photos/records/" + record["id"],
                    body, {"Authorization": "Bearer " + token, "Content-Type": "multipart/form-data; boundary=boundary"}, method="PATCH")
                with urllib.request.urlopen(req, timeout=10) as response:
                    response.read()
            except Exception as error:
                errors.append(error)
        worker = threading.Thread(target=upload)
        worker.start()
        files = []
        for _ in range(100):
            files = list((tmp_path / "storage" / "photos" / record["id"]).glob("*"))
            if files:
                break
            time.sleep(0.02)
        assert files, "upload never reached storage PUT before writer acquisition"
        for path in files:
            os.utime(path, (1, 1))  # Even apparently ancient in-flight bytes are protected.
        result = reconcile(inventory_binary, tmp_path, "--apply", "--min-age-seconds", "1")
        assert result.returncode != 0 and "WouldBlock" in result.stderr
        assert all(path.exists() for path in files)
        writer.rollback()
        writer.close()
        writer = None
        worker.join(timeout=10)
        assert not worker.is_alive() and not errors, errors
    finally:
        if writer is not None:
            writer.rollback()
            writer.close()
        if worker is not None:
            worker.join(timeout=10)
        proc.terminate()
        proc.wait(timeout=10)
