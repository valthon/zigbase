"""End-to-end: import a bcrypt credential, log in with it, and confirm the stored hash was
transparently upgraded to argon2id.

The bcrypt vector is generated at test time rather than hardcoded, so the test proves
interoperability with a REAL foreign implementation rather than with itself. Regenerate the
fallback with:
    python3 -c 'import bcrypt; print(bcrypt.hashpw(b"migrated-secret", bcrypt.gensalt(4, prefix=b"2a")).decode())'
"""
import json
import os
import pathlib
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]
FIELD_KEY = "an-operator-supplied-field-key-32b"
PASSWORD = "migrated-secret"

# A $2a$ (Go/PocketBase-style) bcrypt hash of PASSWORD at cost 4. Used when the `bcrypt`
# package is unavailable; the $2a$ version byte is the point — std only accepts $2b$, so a
# missing normalization fails here.
FALLBACK_2A = "$2a$04$9m5ylg8xGlUcv0SJbn8IZuhPCNsiI2KNNfiLK7pnb/VQsfnZwfe96"


def bcrypt_hash():
    try:
        import bcrypt  # noqa: PLC0415
        return bcrypt.hashpw(PASSWORD.encode(), bcrypt.gensalt(4, prefix=b"2a")).decode()
    except ImportError:
        return FALLBACK_2A


@pytest.fixture(scope="session")
def import_binary():
    override = os.environ.get("ZIGBASE_TEST_IMPORT_BINARY")
    if override:
        if not pathlib.Path(override).exists():
            raise FileNotFoundError(f"ZIGBASE_TEST_IMPORT_BINARY={override} does not exist")
        return override
    subprocess.run(ZIG + ["build", "import-fixture"], cwd=REPO, check=True)
    return str(REPO / "zig-out" / "bin" / "import-fixture")


@pytest.fixture()
def data_dir():
    d = tempfile.mkdtemp(prefix="zb_legacy_auth_")
    yield d
    shutil.rmtree(d, ignore_errors=True)


def env(data):
    # `serve()` below spawns the server as a foreground subprocess it polls for a listening
    # socket. SP-3 makes `serve` auto-background when CLAUDECODE is set in the environment
    # (so an agent's own shell doesn't block on it); under that env var this harness would
    # otherwise wait on a process that has already detached, so pin it off explicitly.
    return {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_FIELD_KEY": FIELD_KEY,
            "ZIGBASE_SERVE_BACKGROUND": "0"}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def serve(binary, data):
    port = free_port()
    log_path = os.path.join(data, "serve.log")
    with open(log_path, "wb") as log:
        proc = subprocess.Popen([binary, "serve", "--insecure-cookies", "--http-port", str(port)],
                                env=env(data), stdout=log, stderr=subprocess.STDOUT)
    for _ in range(50):
        if proc.poll() is not None:
            break
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return proc, f"http://127.0.0.1:{port}"
        except OSError:
            time.sleep(0.1)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait(timeout=5)
    pytest.fail(f"serve never became reachable:\n{pathlib.Path(log_path).read_text(errors='replace')}")


def login(base, identity, password):
    req = urllib.request.Request(
        f"{base}/api/collections/members/auth-with-password", method="POST",
        data=json.dumps({"identity": identity, "password": password}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def stored_hash(data):
    con = sqlite3.connect(os.path.join(data, "data.db"))
    try:
        return con.execute('SELECT passwordHash FROM members WHERE id="member000000001"').fetchone()[0]
    finally:
        con.close()


def test_imported_bcrypt_user_logs_in_and_is_upgraded(import_binary, data_dir):
    src = bcrypt_hash()
    assert src.startswith("$2a$"), "the vector must be $2a$ — that is what this test exists to prove"

    nd = os.path.join(data_dir, "members.ndjson")
    pathlib.Path(nd).write_text(json.dumps({
        "id": "member000000001", "email": "ada@example.com", "name": "Ada",
        "passwordHash": src, "verified": True,
    }) + "\n")

    r = subprocess.run([import_binary, "import", "--collection", "members", "--data-dir", data_dir,
                        "--legacy-hashes", "bcrypt", "--json", nd],
                       env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout)["created"] == 1

    # At rest: tagged, and the plaintext appears nowhere.
    before = stored_hash(data_dir)
    assert before == f"$zblegacy$bcrypt${src}"
    assert PASSWORD not in before

    proc, base = serve(import_binary, data_dir)
    try:
        # The wrong password must not upgrade anything.
        status, _ = login(base, "ada@example.com", "not-the-password")
        assert status == 400
        assert stored_hash(data_dir) == before

        status, body = login(base, "ada@example.com", PASSWORD)
        assert status == 200, body
        assert body["token"]

        after = stored_hash(data_dir)
        assert after.startswith("$argon2"), after
        assert not after.startswith("$zblegacy$")
        assert PASSWORD not in after

        # The upgraded credential still works, and nothing rewrites it back.
        status2, _ = login(base, "ada@example.com", PASSWORD)
        assert status2 == 200
        assert stored_hash(data_dir) == after
    finally:
        proc.terminate()
        proc.wait(timeout=5)
