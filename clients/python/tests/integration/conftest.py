"""Live-server integration harness.

A direct port of `clients/dart/test/integration/harness.dart`'s launch
mechanics (free loopback port via `socket.bind`, a fresh temp data dir, the
superuser seeded via the `superuser create` CLI subcommand, `serve
--insecure-cookies`, a health-poll with retry-on-fresh-port) and
`tests/admin/conftest.py`'s canonical Python launch pattern. One server is
launched for the whole test session and a fixed set of collections is
provisioned once, mirroring
`clients/dart/test/integration/integration_test.dart`'s `setUpAll`.

Skip contract: when `ZIGBASE_TEST_BINARY` is unset, `pytest_ignore_collect`
below removes every file in this directory from collection -- a clean no-op,
not a collection error -- so `pytest -m "not integration"` (and even a plain
`pytest` run from the repo) stays green without the zigbase toolchain.
"""

from __future__ import annotations

import contextlib
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time
from collections.abc import AsyncIterator, Iterator
from typing import Any

import httpx
import pytest

from zigbase import AsyncZigBase, ZigBase

_START_ATTEMPTS = 5
_HEALTH_TIMEOUT_S = 20.0

SUPERUSER_EMAIL = "admin@test.local"
SUPERUSER_PASSWORD = "test-password-123"


def pytest_ignore_collect(collection_path: pathlib.Path, config: pytest.Config) -> bool | None:
    """Ignore every file under `tests/integration/` (except this conftest,
    which must still be importable) when no server binary is configured."""
    if collection_path.name == "conftest.py":
        return None
    if not os.environ.get("ZIGBASE_TEST_BINARY"):
        return True
    return None


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _wait_for_health(base_url: str, proc: subprocess.Popen[bytes], timeout: float) -> None:
    """Poll `/api/health` until it answers 200, raising immediately if the
    child exits first (so a port-bind failure doesn't wait out the full
    deadline)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"server exited before becoming healthy (code={proc.returncode})")
        try:
            resp = httpx.get(f"{base_url}/api/health", timeout=1.0)
            if resp.status_code == 200:
                return
        except httpx.HTTPError:
            pass
        time.sleep(0.15)
    raise RuntimeError(f"server did not become healthy within {timeout}s")


class _LaunchedServer:
    def __init__(self, base_url: str, proc: subprocess.Popen[bytes], data_dir: str) -> None:
        self.base_url = base_url
        self._proc = proc
        self._data_dir = data_dir

    def stop(self) -> None:
        self._proc.terminate()
        try:
            self._proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            self._proc.wait(timeout=5)
        shutil.rmtree(self._data_dir, ignore_errors=True)


def _start_server(binary: str) -> _LaunchedServer:
    """Spawn `binary serve --insecure-cookies` on a free port, retrying on a
    fresh port when a start attempt fails (e.g. a lost port-collision race)."""
    last_err: Exception | None = None
    for _attempt in range(_START_ATTEMPTS):
        data_dir = tempfile.mkdtemp(prefix="zb_py_it_")
        su = subprocess.run(
            [
                binary,
                "superuser",
                "create",
                "--email",
                SUPERUSER_EMAIL,
                "--password",
                SUPERUSER_PASSWORD,
                "--data-dir",
                data_dir,
            ],
            capture_output=True,
            text=True,
        )
        if su.returncode != 0:
            shutil.rmtree(data_dir, ignore_errors=True)
            raise RuntimeError(f"superuser create failed: {su.stderr}")

        port = _free_port()
        proc = subprocess.Popen(
            [
                binary,
                "serve",
                "--http-port",
                str(port),
                "--data-dir",
                data_dir,
                "--insecure-cookies",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        base_url = f"http://127.0.0.1:{port}"
        try:
            _wait_for_health(base_url, proc, _HEALTH_TIMEOUT_S)
            return _LaunchedServer(base_url, proc, data_dir)
        except RuntimeError as exc:
            last_err = exc
            proc.kill()
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=5)
            shutil.rmtree(data_dir, ignore_errors=True)
    raise RuntimeError(f"server did not start after {_START_ATTEMPTS} attempts: {last_err}")


def _posts_definition(name: str) -> dict[str, Any]:
    """A `@public` base collection: required text `title`, numeric `views`,
    single-select file `cover`. Matches
    `clients/dart/test/integration/integration_test.dart`'s `_postsDefinition`."""
    return {
        "name": name,
        "type": "base",
        "fields": [
            {"id": "", "name": "title", "type": "text", "required": True, "options": {}},
            {"id": "", "name": "views", "type": "number", "options": {}},
            {"id": "", "name": "cover", "type": "file", "options": {"maxSelect": 1}},
        ],
        "listRule": "@public",
        "viewRule": "@public",
        "createRule": "@public",
        "updateRule": "@public",
        "deleteRule": "@public",
    }


def _locked_definition(name: str) -> dict[str, Any]:
    """No rule keys set at all -- blank, i.e. Locked (superusers only) per
    rules.zig's safe-by-default policy -- for the anon-403 coverage."""
    return {
        "name": name,
        "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}}],
    }


def _members_definition(name: str) -> dict[str, Any]:
    """An auth-type collection for the password-auth/refresh/logout
    coverage. Records are always seeded by the superuser client (never via
    public signup), so `createRule` stays Locked (default). `viewRule`/
    `listRule` are scoped to "the caller's own record"
    (`@request.auth.id = id`, per docs/tutorial.md) rather than left blank:
    that gives the auth-refresh test a genuinely auth-gated endpoint to
    prove the refreshed token against -- `@request.auth.id` resolves to the
    empty string for an anonymous caller (src/request.zig), which never
    equals a real record id, so the same rule also denies anon access with
    a real (not accidental) 404."""
    return {
        "name": name,
        "type": "auth",
        "fields": [{"id": "", "name": "name", "type": "text", "options": {}}],
        "viewRule": "@request.auth.id = id",
        "listRule": "@request.auth.id = id",
    }


@pytest.fixture(scope="session")
def binary() -> str:
    path = os.environ["ZIGBASE_TEST_BINARY"]
    if not pathlib.Path(path).exists():
        raise FileNotFoundError(f"ZIGBASE_TEST_BINARY={path} does not exist")
    return path


@pytest.fixture(scope="session")
def _server(binary: str) -> Iterator[_LaunchedServer]:
    server = _start_server(binary)
    try:
        yield server
    finally:
        server.stop()


@pytest.fixture(scope="session")
def server_url(_server: _LaunchedServer) -> str:
    return _server.base_url


@pytest.fixture(scope="session")
def superuser_token(server_url: str) -> str:
    resp = httpx.post(
        f"{server_url}/api/collections/_superusers/auth-with-password",
        json={"identity": SUPERUSER_EMAIL, "password": SUPERUSER_PASSWORD},
        timeout=5.0,
    )
    resp.raise_for_status()
    return str(resp.json()["token"])


def _create_collection(server_url: str, token: str, definition: dict[str, Any]) -> None:
    resp = httpx.post(
        f"{server_url}/api/collections",
        json=definition,
        headers={"authorization": f"Bearer {token}"},
        timeout=5.0,
    )
    if resp.status_code >= 300:
        raise RuntimeError(
            f"create collection {definition['name']!r} failed: {resp.status_code} {resp.text}"
        )


@pytest.fixture(scope="session", autouse=True)
def _bootstrap(server_url: str, superuser_token: str) -> None:
    """Provision the fixed collection set every test in this directory
    shares: `posts` (@public CRUD/filter/abilities/files), `cursorposts`
    (@public, dedicated to the cursor-pagination test so its record count
    stays exact), `locked` (blank rules, for the anon-403 test), `members`
    (auth-type, for the password-auth/refresh/logout coverage), and `feed`
    (@public, dedicated to the realtime tests -- mirroring the Dart/TS
    integration harnesses' own `feed` collection -- so its event stream
    isn't shared with `posts`' CRUD/filter/abilities/files coverage)."""
    _create_collection(server_url, superuser_token, _posts_definition("posts"))
    _create_collection(server_url, superuser_token, _posts_definition("cursorposts"))
    _create_collection(server_url, superuser_token, _locked_definition("locked"))
    _create_collection(server_url, superuser_token, _members_definition("members"))
    _create_collection(server_url, superuser_token, _posts_definition("feed"))


@pytest.fixture()
def client(server_url: str) -> Iterator[ZigBase]:
    with ZigBase(server_url) as zb:
        yield zb


@pytest.fixture()
async def async_client(server_url: str) -> AsyncIterator[AsyncZigBase]:
    async with AsyncZigBase(server_url) as zb:
        yield zb


@pytest.fixture()
def admin_client(server_url: str, superuser_token: str) -> Iterator[ZigBase]:
    """A superuser-authenticated client, for seeding data outside the
    collection under test (e.g. a `members` record with a password, before
    the test logs in as that member through the public API).

    Seeds the auth store directly from the session-scoped `superuser_token`
    fixture instead of calling `auth-with-password` again per test: the
    server's login rate limiter is keyed per identity (`rate_limit_max`
    attempts per `rate_limit_window_s`, default 10/60s -- see
    `src/config.zig`), and every `admin_client` use logs in as the SAME
    `SUPERUSER_EMAIL` -- a fresh password auth call per test exceeds that
    window once enough tests across this directory use the fixture (a real
    429 this harness hit once the realtime live tests added their own
    `admin_client` uses on top of `test_auth_live.py`'s)."""
    with ZigBase(server_url) as zb:
        zb.auth_store.save(superuser_token, None)
        yield zb
