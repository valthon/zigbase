"""End-to-end coverage for `zigbase import --external-auths` (issue #377).

The Zig unit tests drive `import.run` in-process over an in-memory DB. This exercises the
REAL operator sequence against a REAL data dir: configure an OAuth2 provider over the admin
API, stop the server, run the offline `import` CLI, restart, and check what the *running*
server can now see.

## What this proves, and what it does not

A complete OAuth2 sign-in ends in `resolveRecordFromIdentity`, which reaches the record by
looking `_externalAuths` up on `(provider, providerId)` (`api/oauth.zig` `findLink`). Getting
there over HTTP requires a real token + userinfo round-trip to the provider: the transport is
`std.http.Client` (no interception seam — `testcapture`'s HTTP mock only covers `ctx.http()`),
and `resolveProvider` refuses any non-HTTPS endpoint, so a local fake provider is not
reachable either. **This module therefore does not drive `auth/oauth2/complete`.** That claim
— an imported identity signs its owner into the imported record instead of colliding on their
email — is proven in `src/auth/methods/oauth2.zig` ("an imported provider link signs the
migrated user into their existing record"), which runs the real `completeImpl` /
`resolveRecordFromIdentity` / `findLink` over a stubbed transport, with a control test showing
the same sign-in without the import returns the 409.

What this module proves instead, out-of-process and end-to-end:

- the offline CLI writes a link row that survives a server restart, keyed by exactly the
  `(provider, providerId)` pair `findLink` queries, pointing at the imported record id;
- the *running* server resolves that link through its own code path (the unlink endpoint,
  which reads `_externalAuths` by `(collection, record, provider)`, answers 204 for the
  imported link and 404 once it is gone);
- the flag is the gate: the same file imported without `--external-auths` mints nothing;
- the HTTP fence holds: no client write — create or update — can produce a link row.
  (That last one asserts the end-to-end property, which two independent mechanisms hold up:
  no HTTP handler writes `_externalAuths` outside a verified OAuth2 sign-in, AND
  `auth.isServerManagedField` drops the key from every payload. The second mechanism is
  pinned on its own by `src/auth.zig`'s "strip a client-supplied externalAuths" test — this
  one stays green if only that strip regresses.)
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

# Reuse the suite's memoized superuser template: `superuser create` hashes with argon2id
# (deliberately CPU-slow) and every data dir here would otherwise pay for it fresh.
from conftest import _su_template_for

RECORD_ID = "members00000001"   # 15 chars, the engine's id width
LEGACY_EMAIL = "ada@legacy.example"
PROVIDER_ID = "g-legacy-1"
SU = {"identity": "admin@x.io", "password": "adminpassword"}


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _http(method, url, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class _Server:
    """A `serve` child owned by one `with` block, so a test can stop the server, run the
    offline CLI against the same data dir, and start it again."""

    def __init__(self, binary, data):
        self.binary, self.data = binary, data

    def __enter__(self):
        port = _free_port()
        self.log = os.path.join(self.data, "serve.log")
        with open(self.log, "ab") as log:
            self.proc = subprocess.Popen(
                [self.binary, "serve", "--insecure-cookies", "--http-port", str(port)],
                # Foreground pin: see conftest's note on ZIGBASE_SERVE_BACKGROUND.
                env={**os.environ, "ZIGBASE_DATA_DIR": self.data,
                     "ZIGBASE_SERVE_BACKGROUND": "0"},
                stdout=log, stderr=subprocess.STDOUT,
            )
        for _ in range(50):
            if self.proc.poll() is not None:
                break
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    return f"http://127.0.0.1:{port}"
            except OSError:
                time.sleep(0.1)
        self.__exit__(None, None, None)
        output = pathlib.Path(self.log).read_text(errors="replace")
        pytest.fail(f"serve on port {port} never became reachable:\n{output}")

    def __exit__(self, *_exc):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)


def _su_token(base):
    status, body = _http("POST", f"{base}/api/collections/_superusers/auth-with-password", body=SU)
    assert status == 200, body
    return json.loads(body)["token"]


@pytest.fixture(scope="session")
def provisioned_template(binary):
    """A data dir carrying the superuser plus a `members` auth collection that declares a
    `google` OAuth2 provider — the precondition `--external-auths` requires. Built once per
    worker (one boot) and copied per test, since every test here writes to its data dir."""
    tmpl = tempfile.mkdtemp(prefix="zb_extauth_tmpl_")
    shutil.copytree(_su_template_for(binary), tmpl, dirs_exist_ok=True)
    with _Server(binary, tmpl) as base:
        token = _su_token(base)
        status, body = _http("POST", f"{base}/api/collections", token=token, body={
            "name": "members",
            "type": "auth",
            "fields": [],
            "options": {"auth": {"oauth2": {"enabled": True, "providers": [{
                "name": "google",
                "clientId": "cid",
                "clientSecret": "client-secret",
                "enabled": True,
                "redirectUrls": ["https://app/cb"],
            }]}}},
        })
        assert status in (200, 201), body
    yield tmpl
    shutil.rmtree(tmpl, ignore_errors=True)


@pytest.fixture()
def data_dir(provisioned_template):
    d = tempfile.mkdtemp(prefix="zb_extauth_")
    shutil.copytree(provisioned_template, d, dirs_exist_ok=True)
    yield d
    shutil.rmtree(d, ignore_errors=True)


def _ndjson(data_dir, *rows):
    p = os.path.join(data_dir, "members.ndjson")
    pathlib.Path(p).write_text("".join(json.dumps(r) + "\n" for r in rows))
    return p


def _run_import(binary, data_dir, path, *extra):
    return subprocess.run(
        [binary, "import", "--collection", "members", "--data-dir", data_dir, *extra, path],
        env={**os.environ, "ZIGBASE_DATA_DIR": data_dir},
        capture_output=True, text=True,
    )


def _find_link(data_dir, provider, provider_id):
    """The exact lookup `api/oauth.zig` `findLink` runs on every OAuth2 sign-in."""
    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        return con.execute(
            'SELECT "collectionRef","recordRef" FROM "_externalAuths" '
            'WHERE "provider"=? AND "providerId"=?;',
            (provider, provider_id),
        ).fetchone()
    finally:
        con.close()


def _links_for(data_dir, record_id):
    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        return con.execute(
            'SELECT "provider","providerId" FROM "_externalAuths" WHERE "recordRef"=?;',
            (record_id,),
        ).fetchall()
    finally:
        con.close()


LEGACY_ROW = {
    "id": RECORD_ID,
    "email": LEGACY_EMAIL,
    # A migrated user usually keeps a password too; it also makes the unlink assertion below
    # meaningful — without a second credential the endpoint refuses to remove the last one.
    "password": "legacy-password-1",
    "externalAuths": [{"provider": "google", "providerId": PROVIDER_ID}],
}


def test_imported_link_survives_restart_and_the_live_server_resolves_it(binary, data_dir):
    """The migration path: import offline, restart, and the running server finds the identity
    on exactly the key the OAuth2 sign-in looks it up by."""
    path = _ndjson(data_dir, LEGACY_ROW)
    res = _run_import(binary, data_dir, path, "--external-auths")
    assert res.returncode == 0, res.stdout + res.stderr

    # Written where the sign-in reads it: `(provider, providerId)` -> the IMPORTED record id,
    # in the imported collection. A new record would carry a generated id, never this one.
    assert _find_link(data_dir, "google", PROVIDER_ID) == ("members", RECORD_ID)

    with _Server(binary, data_dir) as base:
        token = _su_token(base)
        status, body = _http("GET", f"{base}/api/collections/members/records/{RECORD_ID}", token=token)
        assert status == 200, body
        rec = json.loads(body)
        assert rec["email"] == LEGACY_EMAIL
        # Linkage lives in `_externalAuths`, never as a record field.
        assert "externalAuths" not in rec

        # The live server resolves the imported link through its own reader: unlink answers
        # 204 only when it actually found the row for (members, RECORD_ID, google) …
        status, body = _http(
            "DELETE", f"{base}/api/collections/members/records/{RECORD_ID}/external-auths/google",
            token=token)
        assert status == 204, body
        # … and 404 once it is gone, so the 204 above was not a blanket success.
        status, body = _http(
            "DELETE", f"{base}/api/collections/members/records/{RECORD_ID}/external-auths/google",
            token=token)
        assert status == 404, body


def test_without_the_flag_the_same_file_mints_no_identity(binary, data_dir):
    """The flag is the gate: a file alone can never hand someone an account."""
    path = _ndjson(data_dir, LEGACY_ROW)
    res = _run_import(binary, data_dir, path)
    assert res.returncode == 0, res.stdout + res.stderr

    assert _find_link(data_dir, "google", PROVIDER_ID) is None
    assert _links_for(data_dir, RECORD_ID) == []

    # The record itself still imported — only the linkage was ignored.
    with _Server(binary, data_dir) as base:
        token = _su_token(base)
        status, body = _http("GET", f"{base}/api/collections/members/records/{RECORD_ID}", token=token)
        assert status == 200, body


def test_external_auths_is_refused_with_an_upsert_key(binary, data_dir):
    """An upserted row returns before linkage runs, so the CLI refuses the combination rather
    than leaving an account nobody can sign in to."""
    path = _ndjson(data_dir, LEGACY_ROW)
    res = _run_import(binary, data_dir, path, "--external-auths", "--upsert-key", "email")
    assert res.returncode != 0
    assert _find_link(data_dir, "google", PROVIDER_ID) is None


def test_http_writes_can_never_mint_a_provider_link(binary, data_dir):
    """The fence: `externalAuths` is server-managed, so neither a create nor an update carrying
    it may produce a link row. Whoever holds `(provider, providerId)` becomes that record, so a
    client that could set it could hand itself someone else's account."""
    with _Server(binary, data_dir) as base:
        token = _su_token(base)
        forged = [{"provider": "google", "providerId": "attacker-controlled"}]

        status, body = _http("POST", f"{base}/api/collections/members/records", token=token, body={
            "email": "mallory@example.com",
            "password": "a-password-12",
            "passwordConfirm": "a-password-12",
            "externalAuths": forged,
        })
        assert status in (200, 201), body
        rid = json.loads(body)["id"]
        assert "externalAuths" not in json.loads(body)

        status, body = _http("PATCH", f"{base}/api/collections/members/records/{rid}",
                             token=token, body={"externalAuths": forged})
        assert status == 200, body

        # Nothing reached `_externalAuths` — neither keyed by the forged identity nor by the
        # record — so the OAuth2 sign-in has nothing to resolve.
        assert _find_link(data_dir, "google", "attacker-controlled") is None
        assert _links_for(data_dir, rid) == []
        status, body = _http(
            "DELETE", f"{base}/api/collections/members/records/{rid}/external-auths/google",
            token=token)
        assert status == 404, body
