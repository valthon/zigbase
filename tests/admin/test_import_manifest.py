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

