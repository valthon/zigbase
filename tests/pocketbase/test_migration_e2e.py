import hashlib
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from tools.pocketbase import pb2zb


FIXTURE = Path(__file__).parent / "fixtures" / "v0.39.11"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def run(binary, *args):
    return subprocess.run(
        [str(binary), *map(str, args)], text=True, capture_output=True, check=False
    )


def request(method, url, body=None, token=None):
    headers = {}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    value = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(value, timeout=10) as response:
            return response.status, response.read(), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(), dict(error.headers)


def free_port():
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    port = server.getsockname()[1]
    server.close()
    return port


def start_server(binary, data_dir, port):
    log_path = data_dir / f"serve-{port}.log"
    log = log_path.open("wb")
    process = subprocess.Popen(
        [
            str(binary),
            "serve",
            "--insecure-cookies",
            "--http-port",
            str(port),
            "--data-dir",
            str(data_dir),
        ],
        env={**os.environ, "ZIGBASE_SERVE_BACKGROUND": "0"},
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    base = f"http://127.0.0.1:{port}"
    for _ in range(100):
        if process.poll() is not None:
            break
        try:
            status, _, _ = request("GET", f"{base}/api/health")
            if status == 200:
                return process, log, base
        except urllib.error.URLError:
            pass
        time.sleep(0.05)
    process.terminate()
    process.wait(timeout=5)
    log.close()
    raise AssertionError(log_path.read_text(errors="replace"))


def stop_server(process, log):
    process.terminate()
    process.wait(timeout=5)
    log.close()
    assert process.poll() is not None


def fixture_files():
    return {
        path.relative_to(FIXTURE).as_posix(): {
            "bytes": path.stat().st_size,
            "sha256": digest(path),
        }
        for path in FIXTURE.rglob("*")
        if path.is_file() and path.name != "fixture-manifest.json"
    }


def test_pinned_fixture_manifest_is_complete_and_non_secret():
    manifest = json.loads((FIXTURE / "fixture-manifest.json").read_text())
    assert manifest["pocketbaseVersion"] == "0.39.11"
    assert manifest["containsSecrets"] is False
    expected = {
        entry["path"]: {"bytes": entry["bytes"], "sha256": entry["sha256"]}
        for entry in manifest["files"]
    }
    assert fixture_files() == expected
    database = sqlite3.connect(FIXTURE / "pb_data" / "data.db")
    try:
        assert database.execute("SELECT count(*) FROM _superusers").fetchone()[0] == 0
        assert database.execute("SELECT count(*) FROM members").fetchone()[0] == 1
    finally:
        database.close()


def test_pocketbase_fixture_migrates_end_to_end(zigbase_binary, tmp_path):
    parity = json.loads((FIXTURE / "parity.json").read_text())
    source_before = fixture_files()
    inventory = pb2zb.build_inventory(FIXTURE / "pb_schema.json", FIXTURE / "pb_data")
    assert inventory["summary"] == {
        "collections": 3,
        "decisions": 5,
        "blockers": 1,
        "info": 0,
    }

    bundle = tmp_path / "bundle"
    manifest = pb2zb.extract_bundle(
        FIXTURE / "pb_schema.json",
        FIXTURE / "pb_data",
        FIXTURE / "decisions.json",
        bundle,
    )
    assert source_before == fixture_files()
    assert manifest["rowCounts"] == {"members": 1, "posts": 2, "secrets": 1}
    assert manifest["files"] == 5
    assert len(manifest["unreferencedStorage"]) == 5
    assert all(path.endswith(".attrs") for path in manifest["unreferencedStorage"])

    lint = run(
        zigbase_binary, "schema", "check-rules", "--json", bundle / "schema.json"
    )
    assert lint.returncode == 2, lint.stderr
    lint_lines = [json.loads(line) for line in lint.stdout.splitlines()]
    assert lint_lines[-1]["errors"] == 0
    assert {
        f"{line['collection']}.{line['rule']}"
        for line in lint_lines
        if line.get("code") == "PublicRule"
    } == {"members.createRule", "posts.listRule", "posts.viewRule"}

    target = tmp_path / "zb_data"
    applied = run(
        zigbase_binary, "schema", "apply", bundle / "schema.json", "--data-dir", target
    )
    assert applied.returncode == 0, applied.stderr
    for auth in manifest["authImports"]:
        imported_auth = run(
            zigbase_binary,
            "import",
            "--collection",
            auth["collection"],
            "--legacy-hashes",
            "bcrypt",
            "--preserve-timestamps",
            "--data-dir",
            target,
            bundle / auth["file"],
            "--json",
        )
        assert imported_auth.returncode == 0, imported_auth.stderr
    imported = run(
        zigbase_binary,
        "import",
        "--manifest",
        bundle / manifest["ordinaryManifest"],
        "--preserve-timestamps",
        "--data-dir",
        target,
        "--json",
    )
    assert imported.returncode == 0, imported.stderr
    assert pb2zb.install_files(bundle, target) == {
        "files": 5,
        "installed": 5,
        "reused": 0,
    }

    database = sqlite3.connect(target / "data.db")
    try:
        member = database.execute(
            "SELECT passwordHash, created, updated FROM members WHERE id=?",
            (parity["records"]["member"],),
        ).fetchone()
        assert member[0].startswith("$zblegacy$bcrypt$")
        assert list(member[1:]) == parity["timestamps"]["member"]
        posts = database.execute(
            "SELECT id, related, created, updated FROM posts ORDER BY id"
        ).fetchall()
        assert json.loads(posts[0][1]) == [parity["records"]["posts"][1]]
        assert json.loads(posts[1][1]) == [parity["records"]["posts"][0]]
        assert list(posts[0][2:]) == parity["timestamps"][posts[0][0]]
        assert list(posts[1][2:]) == parity["timestamps"][posts[1][0]]
    finally:
        database.close()

    doctor_before = run(
        zigbase_binary, "doctor", "--production", "--json", "--data-dir", target
    )
    assert doctor_before.returncode == 1
    before_checks = [json.loads(line) for line in doctor_before.stdout.splitlines()]
    assert before_checks[-1]["errors"] == 1
    assert before_checks[-1]["warnings"] == 5
    assert (
        next(
            line for line in before_checks if line["check"] == "legacy-password-hashes"
        )["severity"]
        == "warn"
    )

    port = free_port()
    process, log, base = start_server(zigbase_binary, target, port)
    try:
        status, raw, _ = request(
            "POST",
            f"{base}/api/collections/members/records",
            {
                "email": "new-member@example.test",
                "password": "signup-secret",
                "passwordConfirm": "signup-secret",
                "name": "New Member",
            },
        )
        assert status == 201
        assert json.loads(raw)["email"] == "new-member@example.test"

        status, raw, _ = request(
            "GET", f"{base}/api/collections/posts/records?sort=id&expand=owner,related"
        )
        assert status == 200
        public_posts = json.loads(raw)["items"]
        assert [record["id"] for record in public_posts] == parity["records"]["posts"]
        assert public_posts[0]["expand"]["owner"] is None
        assert public_posts[0]["expand"]["related"][0]["id"] == public_posts[1]["id"]

        cover = public_posts[0]["cover"]
        status, raw, _ = request(
            "GET",
            f"{base}/api/files/posts/{public_posts[0]['id']}/{urllib.parse.quote(cover)}",
        )
        assert status == 200
        assert raw.decode() == parity["files"]["public"]

        secret_id = parity["records"]["secret"]
        status, _, _ = request(
            "GET", f"{base}/api/collections/secrets/records/{secret_id}"
        )
        assert status == 404
        status, _, _ = request(
            "POST",
            f"{base}/api/collections/members/auth-with-password",
            {"identity": parity["credentials"]["email"], "password": "wrong"},
        )
        assert status == 400
        status, raw, _ = request(
            "POST",
            f"{base}/api/collections/members/auth-with-password",
            {
                "identity": parity["credentials"]["email"],
                "password": parity["credentials"]["password"],
            },
        )
        assert status == 200
        token = json.loads(raw)["token"]
        status, raw, _ = request(
            "GET",
            f"{base}/api/collections/posts/records/{public_posts[0]['id']}?expand=owner",
            token=token,
        )
        assert status == 200
        assert json.loads(raw)["expand"]["owner"]["name"] == "Ada"
        status, raw, _ = request(
            "GET", f"{base}/api/collections/secrets/records/{secret_id}", token=token
        )
        assert status == 200
        secret = json.loads(raw)
        status, raw, _ = request(
            "GET",
            f"{base}/api/files/secrets/{secret_id}/{secret['document']}",
            token=token,
        )
        assert status == 200
        assert raw.decode() == parity["files"]["private"]
    finally:
        stop_server(process, log)

    database = sqlite3.connect(target / "data.db")
    try:
        upgraded = database.execute(
            "SELECT passwordHash FROM members WHERE id=?",
            (parity["records"]["member"],),
        ).fetchone()[0]
    finally:
        database.close()
    assert upgraded.startswith("$argon2")

    doctor_after = run(
        zigbase_binary, "doctor", "--production", "--json", "--data-dir", target
    )
    after_checks = [json.loads(line) for line in doctor_after.stdout.splitlines()]
    legacy = next(
        line for line in after_checks if line["check"] == "legacy-password-hashes"
    )
    assert legacy["severity"] == "ok"
    assert after_checks[-1]["warnings"] == 4

    restart_port = free_port()
    process, log, base = start_server(zigbase_binary, target, restart_port)
    try:
        status, raw, _ = request(
            "GET",
            f"{base}/api/collections/posts/records/{parity['records']['posts'][0]}",
        )
        assert status == 200
        assert json.loads(raw)["title"] == "Public first"
        status, _, _ = request(
            "POST",
            f"{base}/api/collections/members/auth-with-password",
            {
                "identity": parity["credentials"]["email"],
                "password": parity["credentials"]["password"],
            },
        )
        assert status == 200
    finally:
        stop_server(process, log)

    assert (target / "serve.lock").exists()  # permanent inode; flock is released
    shutil.rmtree(target)
    assert not target.exists()
