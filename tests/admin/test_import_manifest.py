"""End-to-end coverage for `zigbase import --manifest` and the Task 6 hardening flags.

Uses the `import-fixture` binary (fixtures/import/main.zig), which declares the relation
graph `posts.author -> authors` plus the self-relation `authors.mentor -> authors`.
"""
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import tempfile

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]
FIELD_KEY = "an-operator-supplied-field-key-32b"


@pytest.fixture(scope="session")
def import_binary():
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
    d = tempfile.mkdtemp(prefix="zb_manifest_")
    yield d
    shutil.rmtree(d, ignore_errors=True)


def env(data):
    return {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_FIELD_KEY": FIELD_KEY}


def write(data, name, text):
    p = os.path.join(data, name)
    pathlib.Path(p).write_text(text)
    return p


def query(data, sql):
    con = sqlite3.connect(os.path.join(data, "data.db"))
    try:
        return con.execute(sql).fetchall()
    finally:
        con.close()


def test_manifest_loads_out_of_order_files_and_patches_deferred_relations(import_binary, data_dir):
    # `posts` is listed FIRST and references `authors`; `authors.mentor` is a self-relation
    # whose child row appears BEFORE its mentor. Neither can load naively.
    write(data_dir, "posts.ndjson",
          '{"id":"post0000000001","title":"Hello","author":"author00000001"}\n')
    write(data_dir, "authors.ndjson",
          '{"id":"author00000001","nom":"Ada","mentor":"author00000002"}\n'
          '{"id":"author00000002","nom":"Grace","mentor":null}\n')
    manifest = write(data_dir, "m.json", json.dumps({
        "zigbaseImportManifest": 1,
        "collections": [
            {"collection": "posts", "file": "posts.ndjson"},
            {"collection": "authors", "file": "authors.ndjson"},
        ],
    }))

    r = subprocess.run([import_binary, "import", "--manifest", manifest, "--json",
                        "--data-dir", data_dir], env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["failed"] == 0
    assert out["patched"] == 1  # only Ada carried a mentor
    by_col = {c["collection"]: c for c in out["collections"]}
    assert by_col["authors"]["created"] == 2
    assert by_col["posts"]["created"] == 1

    assert query(data_dir, 'SELECT author FROM posts') == [("author00000001",)]
    assert query(data_dir, 'SELECT mentor FROM authors WHERE id="author00000001"') == [("author00000002",)]


def test_manifest_dry_run_writes_nothing(import_binary, data_dir):
    write(data_dir, "authors.ndjson", '{"id":"author00000001","nom":"Ada"}\n')
    manifest = write(data_dir, "m.json", json.dumps({
        "zigbaseImportManifest": 1,
        "collections": [{"collection": "authors", "file": "authors.ndjson"}],
    }))
    r = subprocess.run([import_binary, "import", "--manifest", manifest, "--dry-run", "--json",
                        "--data-dir", data_dir], env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout)["dry_run"] is True
    assert query(data_dir, "SELECT count(*) FROM authors") == [(0,)]


def test_continue_on_error_exits_3_and_writes_findings(import_binary, data_dir):
    src = write(data_dir, "vault.ndjson",
                '{"code":"A"}\nnot json\n{"code":"B"}\n{"nope":"missing required code"}\n')
    log = os.path.join(data_dir, "errs.ndjson")
    r = subprocess.run([import_binary, "import", "--collection", "vault", "--data-dir", data_dir,
                        "--continue-on-error", "--error-log", log, "--json", src],
                       env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 3, r.stderr
    out = json.loads(r.stdout)
    assert (out["created"], out["failed"]) == (2, 2)
    findings = [json.loads(l) for l in pathlib.Path(log).read_text().splitlines() if l.strip()]
    assert [f["line"] for f in findings] == [2, 4]
    assert findings[0]["code"] == "MalformedJson"
    assert query(data_dir, "SELECT count(*) FROM vault") == [(2,)]


def test_manifest_rejects_a_bad_document_and_an_unknown_collection(import_binary, data_dir):
    bad = write(data_dir, "bad.json", '{"collections":[]}')
    r = subprocess.run([import_binary, "import", "--manifest", bad, "--data-dir", data_dir],
                       env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 1 and "InvalidManifest" in r.stderr

    write(data_dir, "x.ndjson", "{}\n")
    unknown = write(data_dir, "u.json", json.dumps({
        "zigbaseImportManifest": 1,
        "collections": [{"collection": "nosuch", "file": "x.ndjson"}],
    }))
    r2 = subprocess.run([import_binary, "import", "--manifest", unknown, "--data-dir", data_dir],
                        env=env(data_dir), capture_output=True, text=True)
    assert r2.returncode == 1 and "UnknownCollection" in r2.stderr
