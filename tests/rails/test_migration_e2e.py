"""The documented Rails migration, run end to end against the real ZigBase binary.

Every other module in this suite stops at the converter's output: it asserts what
`extract` wrote to disk. That cannot prove a migration path exists. A bundle is only a
proposal until the binary accepts it — the schema document has to apply, the NDJSON has
to import, the files have to land where the file API looks for them, and a Rails bcrypt
digest has to actually log somebody in. This module runs the whole documented workflow
once and then interrogates the result.

It is also the guard against the guide drifting away from the tool. `docs/migrate-rails-api.md`
is the contract an operator follows; a command printed there that the binary rejects is a
broken migration path even when every unit test is green, so the documented commands are
parsed out of the guide and checked against the real CLI surface.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import pytest

from .conftest import decisions_for, materialize_artifacts
from tests._bin import resolve_binary
from tools.rails import rails2zb

REPO = Path(__file__).resolve().parents[2]
CONVERTER = REPO / "tools" / "rails" / "rails2zb.py"
GUIDE = REPO / "docs" / "migrate-rails-api.md"

# The seeds file records the plaintext beside each hard-coded bcrypt digest, which is
# what makes a real login provable here rather than merely a hash comparison.
LOGIN_EMAIL = "ada@example.test"
LOGIN_PASSWORD = "ada-password-1"

SUPERUSER_EMAIL = "e2e-admin@example.test"
SUPERUSER_PASSWORD = "e2e-admin-password"

# Source tables that are framework bookkeeping, not application data. Everything else in
# the observed row counts must arrive as a collection with the same number of rows.
NON_COLLECTION_TABLES = {
    "active_storage_attachments",
    "active_storage_blobs",
    "active_storage_variant_records",
    "ar_internal_metadata",
    "schema_migrations",
}


# ---------------------------------------------------------------------------
# Process plumbing
# ---------------------------------------------------------------------------


def run(*args: object) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(a) for a in args], text=True, capture_output=True, check=False
    )


def ok(result: subprocess.CompletedProcess) -> subprocess.CompletedProcess:
    """Assert success, and put the tool's own diagnosis in the failure message.

    A bare `assert returncode == 0` on a migration step reports that something broke
    without saying what, which is the least useful thing an end-to-end test can do.
    """
    assert result.returncode == 0, (
        f"{' '.join(result.args)}\nexit={result.returncode}\n{result.stderr}"
    )
    return result


def free_port() -> int:
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    port = server.getsockname()[1]
    server.close()
    return port


def request(method: str, url: str, body=None, token: str | None = None):
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
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


# ---------------------------------------------------------------------------
# The pipeline, run once
# ---------------------------------------------------------------------------


@dataclass
class Migration:
    """Everything the pipeline produced, so the assertions never re-run a step."""

    binary: Path
    bundle: Path
    target: Path
    findings: dict
    inventory_exit: int
    dry_run: dict
    applied: dict
    auth_import: dict
    data_import: dict
    installed: dict
    # Captured before any server runs: the first successful login rewrites a hash, so a
    # credential assertion reading the database later would depend on test order.
    credentials: dict


@pytest.fixture(scope="module")
def binary() -> Path:
    """The binary under test, or a skip when this machine cannot produce one.

    CI passes a prebuilt one through ZIGBASE_TEST_BINARY. A set-but-missing override is
    a misconfiguration and raises; only the absence of a toolchain is a skip, so a
    machine that *can* run this test never silently doesn't.
    """
    override = os.environ.get("ZIGBASE_TEST_BINARY")
    if override:
        if not Path(override).exists():
            raise FileNotFoundError(f"ZIGBASE_TEST_BINARY={override} does not exist")
        return Path(override)
    if shutil.which("mise") is None:
        pytest.skip("no ZIGBASE_TEST_BINARY and no mise to build one")
    try:
        return Path(resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase"))
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        pytest.skip(f"cannot build the zigbase binary here: {error}")


@pytest.fixture(scope="module")
def migrated(binary: Path, source: Path, tmp_path_factory) -> Migration:
    """Steps 1-8 of the guide: inventory, decide, extract, migrate, apply, import, install."""
    work = tmp_path_factory.mktemp("rails_e2e")
    bundle = work / "bundle"
    target = work / "zb_data"

    inventory = run(
        sys.executable,
        CONVERTER,
        "inventory",
        "--source",
        source,
        "--out",
        work / "findings.json",
    )
    findings = json.loads((work / "findings.json").read_text())

    decisions = work / "decisions.json"
    # Artifacts live beside the decisions file that names them, and must exist: the
    # converter refuses a decision pointing at a replacement nobody wrote.
    value = materialize_artifacts(decisions_for(findings["findings"]), work)
    decisions.write_text(json.dumps(value))
    ok(
        run(
            sys.executable,
            CONVERTER,
            "extract",
            "--source",
            source,
            "--decisions",
            decisions,
            "--out",
            bundle,
        )
    )

    ok(run(binary, "migrate", "--data-dir", target))
    dry_run = ok(
        run(
            binary,
            "schema",
            "apply",
            bundle / "schema.json",
            "--dry-run",
            "--data-dir",
            target,
        )
    )
    applied = ok(
        run(binary, "schema", "apply", bundle / "schema.json", "--data-dir", target)
    )

    # Auth is its own single-collection run: --legacy-hashes applies uniformly to every
    # manifest entry, so credentials can never ride along with ordinary data.
    auth_import = ok(
        run(
            binary,
            "import",
            "--collection",
            "users",
            "--legacy-hashes",
            "bcrypt",
            "--preserve-timestamps",
            "--data-dir",
            target,
            "--json",
            bundle / "auth" / "users.ndjson",
        )
    )
    data_import = ok(
        run(
            binary,
            "import",
            "--manifest",
            bundle / "manifest.json",
            "--preserve-timestamps",
            "--data-dir",
            target,
            "--json",
        )
    )
    installed = ok(
        run(
            sys.executable,
            CONVERTER,
            "install-files",
            "--bundle",
            bundle,
            "--source",
            source,
            "--data-dir",
            target,
        )
    )

    database = sqlite3.connect(target / "data.db")
    try:
        credentials = dict(
            database.execute("SELECT id, passwordHash FROM users").fetchall()
        )
    finally:
        database.close()

    return Migration(
        binary=binary,
        bundle=bundle,
        target=target,
        findings=findings,
        inventory_exit=inventory.returncode,
        dry_run=json.loads(dry_run.stdout),
        applied=json.loads(applied.stdout),
        auth_import=json.loads(auth_import.stdout),
        data_import=json.loads(data_import.stdout),
        installed=json.loads(installed.stdout),
        credentials=credentials,
    )


@pytest.fixture(scope="module")
def server(migrated: Migration):
    """The migrated data dir, served. Terminated on every path, including a failed boot."""
    port = free_port()
    log_path = migrated.target / f"serve-{port}.log"
    log = log_path.open("wb")
    process = subprocess.Popen(
        [
            str(migrated.binary),
            "serve",
            "--insecure-cookies",
            "--http-port",
            str(port),
            "--data-dir",
            str(migrated.target),
        ],
        # `serve` backgrounds itself when it detects an agent environment, which would
        # detach the process this fixture believes it owns.
        env={**os.environ, "ZIGBASE_SERVE_BACKGROUND": "0"},
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(200):
            if process.poll() is not None:
                raise AssertionError(log_path.read_text(errors="replace"))
            try:
                status, _ = request("GET", f"{base}/api/health")
                if status == 200:
                    break
            except urllib.error.URLError:
                pass
            time.sleep(0.05)
        else:
            raise AssertionError(f"server never answered:\n{log_path.read_text()}")
        yield base
    finally:
        process.terminate()
        process.wait(timeout=10)
        log.close()


@pytest.fixture(scope="module")
def superuser_token(migrated: Migration, server: str) -> str:
    """Every migrated rule is Locked, so reading the data back needs a superuser.

    That is the point of the safe default, not a workaround for it: the converter never
    invents an access rule, so the only actor entitled to inspect a freshly migrated
    collection is an operator.
    """
    ok(
        run(
            migrated.binary,
            "superuser",
            "create",
            "--email",
            SUPERUSER_EMAIL,
            "--password",
            SUPERUSER_PASSWORD,
            "--data-dir",
            migrated.target,
        )
    )
    status, raw = request(
        "POST",
        f"{server}/api/collections/_superusers/auth-with-password",
        {"identity": SUPERUSER_EMAIL, "password": SUPERUSER_PASSWORD},
    )
    assert status == 200, raw
    return json.loads(raw)["token"]


def rows(migrated: Migration, sql: str, *params) -> list:
    database = sqlite3.connect(migrated.target / "data.db")
    try:
        return database.execute(sql, params).fetchall()
    finally:
        database.close()


# ---------------------------------------------------------------------------
# The guide and the tool must not drift apart
# ---------------------------------------------------------------------------


def documented_commands() -> list[str]:
    """Every shell command the guide prints, with `\\` continuations rejoined."""
    blocks = re.findall(r"```sh\n(.*?)```", GUIDE.read_text(), re.DOTALL)
    joined = "\n".join(blocks).replace("\\\n", " ")
    return [line.strip() for line in joined.splitlines() if line.strip()]


def commands_starting(prefix: str) -> list[str]:
    return [line for line in documented_commands() if line.startswith(prefix)]


def test_the_guide_documents_the_commands_it_claims_to():
    """A guard on the guard: silently matching zero commands would pass every test below."""
    assert commands_starting("zigbase "), "no zigbase command found in the guide"
    assert commands_starting("python3 tools/rails/rails2zb.py"), (
        "no converter command found in the guide"
    )


@pytest.mark.parametrize("command", commands_starting("zigbase "))
def test_documented_zigbase_flags_exist_on_the_binary(binary: Path, command: str):
    """A flag the guide prints and the binary rejects is a broken migration path.

    The alternative to checking this is discovering it during a cutover, which is
    exactly when nobody has time to work out which flag the tool actually wants.
    """
    subcommand = command.split()[1]
    help_text = run(binary, subcommand, "--help").stdout
    declared = set(re.findall(r"--[a-z0-9][a-z0-9-]*", help_text))
    used = {token for token in command.split() if token.startswith("--")}
    assert used <= declared, f"{command}\nunknown flags: {sorted(used - declared)}"


def test_the_documented_import_of_credentials_names_a_collection():
    """`--collection` is required, so an import command that omits it cannot run at all.

    Flag existence alone would not catch this: every remaining flag could be valid while
    the command still aborts before reading a single row.
    """
    imports = commands_starting("zigbase import ")
    auth = [line for line in imports if "--legacy-hashes" in line]
    assert auth, "the guide no longer documents a legacy-hash import"
    for line in auth:
        assert "--collection" in line, line


@pytest.mark.parametrize(
    "command", commands_starting("python3 tools/rails/rails2zb.py")
)
def test_documented_converter_commands_parse(command: str):
    """Parse the documented invocation with the converter's own parser, not a copy of it."""
    rails2zb.build_parser().parse_args(command.split()[2:])


def test_extraction_is_byte_identical_across_processes(source, tmp_path):
    """The guide tells the operator to run extraction twice and compare.

    That is two PROCESSES, and Python randomizes string hashing per process — so any
    output that fell out of set iteration order would agree within one interpreter and
    differ between the operator's two runs. The in-process determinism test cannot see
    that; this one varies PYTHONHASHSEED to make the difference observable.
    """
    src = rails2zb.load_source(source)
    findings = [f.to_dict() for f in rails2zb.build_findings(src)]
    decisions = tmp_path / "decisions.json"
    decisions.write_text(
        json.dumps(materialize_artifacts(decisions_for(findings), tmp_path))
    )

    digests = []
    for seed in ("0", "1"):
        out = tmp_path / f"bundle-{seed}"
        environment = {**os.environ, "PYTHONHASHSEED": seed}
        ok(
            subprocess.run(
                [
                    sys.executable,
                    str(CONVERTER),
                    "extract",
                    "--source",
                    str(source),
                    "--decisions",
                    str(decisions),
                    "--out",
                    str(out),
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
        )
        digest = hashlib.sha256()
        for path in sorted(q for q in out.rglob("*") if q.is_file()):
            digest.update(path.relative_to(out).as_posix().encode())
            digest.update(path.read_bytes())
        digests.append(digest.hexdigest())

    assert digests[0] == digests[1], (
        "two runs of the documented command disagreed; something in the bundle depends "
        "on set iteration order"
    )


# ---------------------------------------------------------------------------
# The pipeline itself
# ---------------------------------------------------------------------------


def test_inventory_demands_judgment_before_extraction(migrated: Migration):
    """Exit 2 is "decide these", not "this failed" — the converter refuses to guess."""
    assert migrated.inventory_exit == 2
    summary = migrated.findings["summary"]
    assert summary["blockers"] > 0
    assert summary["decisions"] > 0
    assert migrated.findings["sourceMode"] == "observed"


def test_the_dry_run_writes_no_collections(migrated: Migration):
    """A rehearsal that changed the target would make the rehearsal the cutover."""
    assert migrated.dry_run["dry_run"] is True
    assert migrated.dry_run["destructive"] is False
    assert migrated.dry_run["applied"] == []
    assert {change["collection"] for change in migrated.dry_run["changes"]} == {
        change["collection"] for change in migrated.applied["changes"]
    }


def test_every_collection_the_bundle_declares_is_created(migrated: Migration):
    declared = {
        collection["name"]
        for collection in json.loads((migrated.bundle / "schema.json").read_text())[
            "collections"
        ]
    }
    assert set(migrated.applied["applied"]) == declared
    assert migrated.applied["untracked"] == []


def test_no_row_is_lost_between_the_source_and_the_target(
    migrated: Migration, source: Path
):
    """Counted against Rails' own `unscoped` census, not against the bundle.

    Comparing the target to the bundle would only prove the importer echoed whatever the
    converter chose to write, including the rows it wrongly dropped.
    """
    census = json.loads((source / "inventory" / "counts.json").read_text())
    expected = {
        table["table"]: table["unscoped_count"]
        for table in census["tables"]
        if table["table"] not in NON_COLLECTION_TABLES
    }
    actual = {
        name: rows(migrated, f"SELECT count(*) FROM {name}")[0][0]  # noqa: S608
        for name in expected
    }
    assert actual == expected


def test_the_default_scoped_club_survives_the_whole_pipeline(migrated: Migration):
    """`default_scope` hides the archived club from every ordinary Rails read.

    Two clubs arriving instead of three is the failure this migration is most likely to
    ship silently, because nothing downstream looks wrong.
    """
    clubs = rows(migrated, "SELECT id, slug FROM clubs ORDER BY id")
    assert clubs == [
        ("1", "morning-pages"),
        ("2", "night-owls"),
        ("3", "retired-readers"),
    ]


def test_rails_ids_arrive_verbatim(migrated: Migration):
    """Preserved ids are what keeps every relation, URL, and client cache resolving."""
    assert [row[0] for row in rows(migrated, "SELECT id FROM posts ORDER BY id")] == [
        "1",
        "2",
        "3",
        "4",
    ]
    assert [row[0] for row in rows(migrated, "SELECT id FROM users ORDER BY id")] == [
        "1",
        "2",
        "3",
        "4",
    ]


def test_relations_point_at_the_records_they_did_in_rails(migrated: Migration):
    posts = {
        row[0]: row[1:]
        for row in rows(migrated, "SELECT id, club, author FROM posts ORDER BY id")
    }
    assert posts["1"] == ("1", "1")
    assert posts["3"] == ("2", "3")
    # A relation into a row the source hid: the target is only reachable because the
    # unscoped read carried it over.
    assert posts["4"] == ("3", "1")


def test_timestamps_are_preserved_byte_exactly(migrated: Migration):
    """A migration that re-stamps rows with the import time destroys the record's history."""
    assert rows(migrated, "SELECT created, updated FROM clubs WHERE id='1'") == [
        ("2024-01-15T10:00:00Z", "2024-01-15T10:00:00Z")
    ]
    assert rows(migrated, "SELECT created, updated FROM clubs WHERE id='3'") == [
        ("2024-01-15T10:02:00Z", "2024-02-01T00:00:00Z")
    ]
    assert rows(migrated, "SELECT created, updated FROM users WHERE id='1'") == [
        ("2024-01-15T09:00:00Z", "2024-01-15T09:00:00Z")
    ]


def test_the_integer_backed_enum_arrives_as_its_label(migrated: Migration):
    """`role` is an ordinal in SQLite and a name in the application. Importing the
    ordinal would leave every authorization check comparing against `0`."""
    assert dict(rows(migrated, "SELECT id, role FROM users ORDER BY id")) == {
        "1": "admin",
        "2": "member",
        "3": "moderator",
        "4": "member",
    }


def test_the_attachment_lands_where_the_file_api_looks_for_it(
    migrated: Migration, source: Path
):
    """Bytes on disk plus the record naming them; either half alone is a broken file.

    The destination is not the converter's to choose. `LocalStorage` in
    `src/files/storage.zig` joins exactly `<root>/<collection>/<recordId>/<filename>`,
    and the record stores a bare filename, so any extra path component makes a blob the
    server can never resolve. Asserting the whole tree rather than one path means a
    layout change shows what it actually wrote instead of only that something is missing.
    """
    assert migrated.installed == {
        "files": 1,
        "installed": 1,
        "reused": 0,
        "zigbase_rails_file_install": 1,
    }
    assert dict(rows(migrated, "SELECT id, cover FROM posts ORDER BY id")) == {
        "1": "morning-pages-cover.png",
        "2": None,
        "3": None,
        "4": None,
    }

    storage = migrated.target / "storage"
    on_disk = {
        path.relative_to(storage).as_posix()
        for path in storage.rglob("*")
        if path.is_file()
    }
    assert on_disk == {"posts/1/morning-pages-cover.png"}

    plan = json.loads((migrated.bundle / "files" / "manifest.json").read_text())[
        "files"
    ]
    installed = storage / "posts" / "1" / "morning-pages-cover.png"
    assert installed.read_bytes() == (source / plan[0]["sourcePath"]).read_bytes()


def test_credentials_arrive_tagged_as_legacy_bcrypt(migrated: Migration):
    """The tag is what tells the verifier to try bcrypt and then re-hash on success.

    An untagged bcrypt string would be treated as an argon2id hash and never match.
    """
    assert len(migrated.credentials) == 4
    for identifier, stored in migrated.credentials.items():
        assert stored.startswith("$zblegacy$bcrypt$"), identifier
        assert rails2zb.BCRYPT.fullmatch(stored.removeprefix("$zblegacy$bcrypt$")), (
            identifier
        )


# ---------------------------------------------------------------------------
# The migrated backend, running
# ---------------------------------------------------------------------------


def test_a_rails_password_still_logs_in_and_is_rehashed(
    migrated: Migration, server: str
):
    """The whole migration is worthless if the users cannot get back in.

    This is the one assertion that spans every earlier step at once: the schema applied,
    the row imported with its id, the digest survived tagged, and the verifier accepts
    the password the Rails seeds recorded. The rehash proves the legacy hash is a
    transition and not a permanent state.
    """
    assert migrated.credentials["1"].startswith("$zblegacy$bcrypt$")

    status, raw = request(
        "POST",
        f"{server}/api/collections/users/auth-with-password",
        {"identity": LOGIN_EMAIL, "password": "not-the-password"},
    )
    assert status == 400, raw

    status, raw = request(
        "POST",
        f"{server}/api/collections/users/auth-with-password",
        {"identity": LOGIN_EMAIL, "password": LOGIN_PASSWORD},
    )
    assert status == 200, raw
    record = json.loads(raw)["record"]
    assert record["id"] == "1"
    assert record["display_name"] == "Ada Lovelace"
    assert record["created"] == "2024-01-15T09:00:00Z"

    stored = rows(migrated, "SELECT passwordHash FROM users WHERE id='1'")[0][0]
    assert stored.startswith("$argon2"), (
        "a successful login must retire the legacy hash"
    )


def test_migrated_collections_are_locked_to_their_operator(server: str):
    """The converter never invents a rule, so nothing is readable until someone decides.

    Worth asserting rather than assuming: a migration that arrived world-readable would
    pass every fidelity check in this module while publishing the source's whole dataset.
    """
    status, _ = request("GET", f"{server}/api/collections/posts/records")
    assert status == 403
    # A locked single record conceals its existence rather than admitting to a denial.
    status, _ = request("GET", f"{server}/api/collections/posts/records/1")
    assert status == 404


def test_the_served_records_expand_their_relations(server: str, superuser_token: str):
    """Ids matching in SQLite is not the same as the engine resolving them.

    A relation field whose target collection was mis-named still stores the right string
    and still fails to expand, which is what a client would actually notice.
    """
    status, raw = request(
        "GET",
        f"{server}/api/collections/posts/records?sort=id&expand=club,author",
        token=superuser_token,
    )
    assert status == 200, raw
    items = json.loads(raw)["items"]
    assert [item["id"] for item in items] == ["1", "2", "3", "4"]
    assert items[0]["expand"]["club"]["slug"] == "morning-pages"
    assert items[0]["expand"]["author"]["email"] == LOGIN_EMAIL
    assert items[3]["expand"]["club"]["slug"] == "retired-readers"


def test_the_installed_attachment_is_served_over_http(
    migrated: Migration, server: str, superuser_token: str
):
    status, raw = request(
        "GET",
        f"{server}/api/files/posts/1/morning-pages-cover.png",
        token=superuser_token,
    )
    assert status == 200
    installed = migrated.target / "storage" / "posts" / "1" / "morning-pages-cover.png"
    assert raw == installed.read_bytes()


def test_ciphertext_never_reached_the_target(migrated: Migration):
    """Active Record ciphertext is bound to the source key; carrying it over would ship
    an unreadable column that looks like migrated data."""
    columns = {row[1] for row in rows(migrated, "PRAGMA table_info(users)")}
    assert "phone" not in columns
