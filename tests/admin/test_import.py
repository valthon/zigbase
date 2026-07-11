"""End-to-end coverage for the offline `zigbase import` subcommand (issue #283).

Unlike the Zig unit tests (which drive `import.run` over an in-memory DB with a fake cipher),
this exercises the REAL CLI against a REAL data dir: a genuine boot (migrations + comptime
`.collections` provisioning + AES-GCM field-cipher stamping), then verifies the results both
by opening the SQLite file directly (ciphertext-at-rest, hashed password) and over the live
REST API (transparent decryption round-trip, preserved ids). This is the first CLI-subcommand
e2e in the suite; it needs no browser, so it uses subprocess + sqlite3 + urllib only.

The `import-fixture` binary (fixtures/import/main.zig) declares an auth collection `members`
(password) and a base collection `vault` with an `.encrypted` field `secret`.
"""
import json
import os
import pathlib
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.request

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]
FIELD_KEY = "an-operator-supplied-field-key-32b"  # >= 32 bytes


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


@pytest.fixture(scope="session")
def import_binary():
    """The offline-import e2e fixture. Honors a CI-prebuilt override; else builds it."""
    override = os.environ.get("ZIGBASE_TEST_IMPORT_BINARY")
    if override:
        if not pathlib.Path(override).exists():
            raise FileNotFoundError(f"ZIGBASE_TEST_IMPORT_BINARY={override} does not exist")
        return override
    subprocess.run(ZIG + ["build", "import-fixture"], cwd=REPO, check=True)
    path = REPO / "zig-out" / "bin" / "import-fixture"
    assert path.exists(), f"import-fixture not built at {path}"
    return str(path)


@pytest.fixture()
def data_dir():
    d = tempfile.mkdtemp(prefix="zb_import_e2e_")
    yield d
    import shutil
    shutil.rmtree(d, ignore_errors=True)


def _env(data):
    return {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_FIELD_KEY": FIELD_KEY}


def _write(data, name, text):
    p = os.path.join(data, name)
    pathlib.Path(p).write_text(text)
    return p


def run_import(binary, data, collection, ndjson_path, *extra, stdin=None):
    """Invoke `import-fixture import ...`; return the CompletedProcess (capturing output)."""
    cmd = [binary, "import", "--collection", collection, "--data-dir", data, *extra, ndjson_path]
    return subprocess.run(
        cmd, env=_env(data), input=stdin, capture_output=True, text=True
    )


def _serve(binary, data):
    port = _free_port()
    proc = subprocess.Popen(
        [binary, "serve", "--insecure-cookies", "--http-port", str(port)],
        env=_env(data), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            time.sleep(0.1)
    return proc, f"http://127.0.0.1:{port}"


def _get_json(url):
    return json.load(urllib.request.urlopen(url, timeout=5))


def test_import_roundtrip_encrypted_and_auth(import_binary, data_dir):
    """The headline path: encrypted field sealed at rest + decrypts on read, auth password
    hashed, and source ids preserved — proven both in the raw DB and over REST."""
    vault = _write(
        data_dir, "vault.ndjson",
        '{"id":"vault0000000001","code":"AAA","secret":"topsecret","note":"n1"}\n'
        "\n"  # blank line is skipped
        '{"code":"BBB","secret":"hush","note":"n2"}\n',
    )
    members = _write(
        data_dir, "members.ndjson",
        '{"id":"member000000001","email":"ada@example.com","password":"supersecret1","name":"Ada"}\n',
    )

    r1 = run_import(import_binary, data_dir, "vault", vault)
    assert r1.returncode == 0, r1.stderr
    assert "2 created, 0 updated, 2 total" in r1.stderr, r1.stderr
    r2 = run_import(import_binary, data_dir, "members", members)
    assert r2.returncode == 0, r2.stderr
    assert "1 created" in r2.stderr, r2.stderr

    # --- Raw DB assertions: ciphertext at rest, hashed password ---
    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        raw = dict(con.execute("SELECT code, secret FROM vault").fetchall())
        # The encrypted column holds a v1 AES-GCM envelope, NEVER the plaintext.
        assert raw["AAA"].startswith("v1:") and "topsecret" not in raw["AAA"]
        assert raw["BBB"].startswith("v1:") and "hush" not in raw["BBB"]
        # id preservation: the provided id was kept; the id-less row got a generated 15-char id.
        ids = [row[0] for row in con.execute("SELECT id FROM vault ORDER BY code").fetchall()]
        assert ids[0] == "vault0000000001"
        assert ids[1] != "vault0000000001" and len(ids[1]) == 15
        # Auth: password hashed (argon2id), never plaintext; tokenKey set; verified forced false.
        phash, tokenkey, verified, mid = con.execute(
            "SELECT passwordHash, tokenKey, verified, id FROM members"
        ).fetchone()
        assert phash.startswith("$argon2") and "supersecret1" not in phash
        assert len(tokenkey) > 0
        assert verified == 0
        assert mid == "member000000001"  # auth-collection id preserved too
    finally:
        con.close()

    # --- REST assertions: transparent decryption + preserved ids ---
    proc, base = _serve(import_binary, data_dir)
    try:
        got = _get_json(base + "/api/collections/vault/records")
        by_code = {it["code"]: it for it in got["items"]}
        assert by_code["AAA"]["secret"] == "topsecret"  # decrypts transparently on read
        assert by_code["AAA"]["id"] == "vault0000000001"
        assert by_code["BBB"]["secret"] == "hush"
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_import_upsert_is_idempotent(import_binary, data_dir):
    """`--upsert-key` matches on a field and updates in place instead of inserting."""
    f1 = _write(data_dir, "u1.ndjson", '{"code":"K1","secret":"v1","note":"first"}\n')
    r1 = run_import(import_binary, data_dir, "vault", f1, "--upsert-key", "code")
    assert r1.returncode == 0, r1.stderr
    assert "1 created, 0 updated" in r1.stderr

    f2 = _write(data_dir, "u2.ndjson", '{"code":"K1","secret":"v2","note":"second"}\n')
    r2 = run_import(import_binary, data_dir, "vault", f2, "--upsert-key", "code")
    assert r2.returncode == 0, r2.stderr
    assert "0 created, 1 updated" in r2.stderr

    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        rows = con.execute("SELECT note FROM vault WHERE code='K1'").fetchall()
        assert rows == [("second",)]  # exactly one row, updated
    finally:
        con.close()


def test_import_reads_stdin(import_binary, data_dir):
    """A file path of `-` streams NDJSON from stdin."""
    r = subprocess.run(
        [import_binary, "import", "--collection", "vault", "--data-dir", data_dir, "-"],
        env=_env(data_dir), input='{"code":"STDIN","secret":"s","note":"n"}\n',
        capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    assert "1 created" in r.stderr, r.stderr
    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        assert con.execute("SELECT COUNT(*) FROM vault WHERE code='STDIN'").fetchone()[0] == 1
    finally:
        con.close()


def test_import_duplicate_id_fails_fast_and_rolls_back(import_binary, data_dir):
    """A duplicate preserved id fails the whole batch; nothing from that batch persists."""
    dup = _write(
        data_dir, "dup.ndjson",
        '{"id":"dupe000000001","code":"D1","secret":"a"}\n'
        '{"id":"dupe000000001","code":"D2","secret":"b"}\n',
    )
    r = run_import(import_binary, data_dir, "vault", dup)
    assert r.returncode != 0
    assert "DuplicateId" in r.stderr, r.stderr
    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        # Both rows were in the same (default 500) batch, which rolled back: zero rows.
        assert con.execute("SELECT COUNT(*) FROM vault WHERE code IN ('D1','D2')").fetchone()[0] == 0
    finally:
        con.close()


def test_import_validation_error_names_the_line(import_binary, data_dir):
    """A row that fails validation aborts with the offending 1-based line + field named."""
    bad = _write(
        data_dir, "bad.ndjson",
        '{"code":"OK1","secret":"s"}\n'
        '{"secret":"no-code-here"}\n',  # line 2: missing required `code`
    )
    r = run_import(import_binary, data_dir, "vault", bad)
    assert r.returncode != 0
    assert "line 2" in r.stderr and "code" in r.stderr, r.stderr


def test_import_rejects_unknown_collection_and_bad_upsert_key(import_binary, data_dir):
    f = _write(data_dir, "x.ndjson", "{}\n")
    r1 = run_import(import_binary, data_dir, "nope", f)
    assert r1.returncode != 0 and "UnknownCollection" in r1.stderr
    r2 = run_import(import_binary, data_dir, "vault", f, "--upsert-key", "secret")
    assert r2.returncode != 0 and "EncryptedUpsertKey" in r2.stderr
