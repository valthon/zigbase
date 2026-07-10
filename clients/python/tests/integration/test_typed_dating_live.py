"""Typed-tier e2e: drives the generated dating client
(`tests/codegen/dating/zbase_gen.py`) against the live `dating-server`
binary (the dating fixture, schema baked in). Mirrors
`clients/dart/test/integration/typed_dating_test.dart` and
`clients/typescript/test/integration/dating.integration.test.ts`.

Guard: this file needs BOTH `ZIGBASE_TEST_DATING_BINARY` (its own server)
AND `ZIGBASE_TEST_BINARY` (the generic `zigbase` binary). The latter is not
optional despite this file never launching that binary itself: it lives in
`tests/integration/`, whose `conftest.py` defines a *session-scoped,
autouse* `_bootstrap` fixture that provisions collections against
`ZIGBASE_TEST_BINARY` for every test collected under this directory --
including this file's -- so it fires regardless of which fixtures a given
test function actually requests. `conftest.py`'s `pytest_ignore_collect`
skips collecting this directory entirely when `ZIGBASE_TEST_BINARY` is
unset, but that hook is bypassed when a file is named explicitly on the
command line (e.g. `pytest tests/integration/test_typed_dating_live.py`),
so the module-level guard below checks both variables itself rather than
relying on that hook -- otherwise a dating-only invocation fails every test
with `KeyError: 'ZIGBASE_TEST_BINARY'` from the autouse fixture instead of
skipping cleanly. CI always sets both together for the Python job
(`.github/workflows/ci.yml`), so this coupling is a non-issue there.

Run: `ZIGBASE_TEST_DATING_BINARY=/abs/path/to/dating-server \
  ZIGBASE_TEST_BINARY=/abs/path/to/zigbase \
  python -m pytest tests/integration/test_typed_dating_live.py -q -m integration`

The dating fixture's schema is comptime (baked into the binary) so, unlike
the generic `zigbase` binary used elsewhere in this directory, this file's
own harness needs no collection bootstrap step of its own -- its server is
ready to use as soon as it answers healthy.
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import os
import shutil
import subprocess
import tempfile
from collections.abc import AsyncIterator, Iterator

import httpx
import pytest

from tests.codegen.dating.zbase_gen import (
    AsyncZbClient,
    Photo,
    PhotoCreate,
    PhotoUpdate,
    PrivatePhotoCreate,
    PrivatePhotoFileField,
    Profile,
    ProfileCreate,
    ProfileFileField,
    ProfileUpdate,
    SubscriptionCreate,
    SubscriptionPlan,
    TagCreate,
    ZbClient,
    create_async_client,
    create_client,
)
from tests.integration.conftest import _free_port, _wait_for_health
from zigbase.typed import TypedRealtimeEvent

pytestmark = pytest.mark.integration

_DATING_BIN_ENV = "ZIGBASE_TEST_DATING_BINARY"
_GENERIC_BIN_ENV = "ZIGBASE_TEST_BINARY"
_START_ATTEMPTS = 5
_HEALTH_TIMEOUT_S = 20.0
_EVENT_TIMEOUT_S = 10.0

if not os.environ.get(_DATING_BIN_ENV):
    pytest.skip(f"{_DATING_BIN_ENV} unset", allow_module_level=True)
if not os.environ.get(_GENERIC_BIN_ENV):
    # See the module docstring: `conftest.py`'s autouse `_bootstrap` fixture
    # needs this too, and its own ignore-collect guard is bypassed when this
    # file is named explicitly on the command line.
    pytest.skip(
        f"{_GENERIC_BIN_ENV} unset (required by conftest.py's autouse fixtures)",
        allow_module_level=True,
    )

_email_seq = itertools.count()


def _unique_email(tag: str) -> str:
    return f"{tag}{next(_email_seq)}@d.app"


class _DatingServer:
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


def _start_dating_server(binary: str) -> _DatingServer:
    """Spawn `dating-server serve --insecure-cookies` on a free port. No
    superuser/collection bootstrap: the dating fixture's schema is comptime
    (baked into the binary), so the server is ready as soon as it's
    healthy. Retries on a fresh port when a start attempt fails."""
    last_err: Exception | None = None
    for _attempt in range(_START_ATTEMPTS):
        data_dir = tempfile.mkdtemp(prefix="zb_py_dating_it_")
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
            return _DatingServer(base_url, proc, data_dir)
        except RuntimeError as exc:
            last_err = exc
            proc.kill()
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=5)
            shutil.rmtree(data_dir, ignore_errors=True)
    raise RuntimeError(f"dating-server did not start after {_START_ATTEMPTS} attempts: {last_err}")


@pytest.fixture(scope="module")
def dating_binary() -> str:
    path = os.environ[_DATING_BIN_ENV]
    if not os.path.exists(path):
        raise FileNotFoundError(f"{_DATING_BIN_ENV}={path} does not exist")
    return path


@pytest.fixture(scope="module")
def dating_server(dating_binary: str) -> Iterator[_DatingServer]:
    server = _start_dating_server(dating_binary)
    try:
        yield server
    finally:
        server.stop()


@pytest.fixture(scope="module")
def dating_url(dating_server: _DatingServer) -> str:
    return dating_server.base_url


@pytest.fixture()
def zb(dating_url: str) -> Iterator[ZbClient]:
    client = create_client(dating_url)
    try:
        yield client
    finally:
        client.close()


@pytest.fixture()
async def async_zb(dating_url: str) -> AsyncIterator[AsyncZbClient]:
    client = create_async_client(dating_url)
    try:
        yield client
    finally:
        await client.aclose()


def _register_and_auth(zb: ZbClient, tag: str, *, age: int = 25) -> Profile:
    """Public signup (`profiles.createRule = "@public"`) then password auth
    -- `age` is an int-mode number field: the server stores it as a decimal
    string, and the typed client coerces it back to an `int` on read."""
    email = _unique_email(tag)
    password = "member-pass-1"
    profile = zb.profiles.create(
        ProfileCreate(
            email=email,
            password=password,
            password_confirm=password,
            name=email.split("@")[0],
            age=age,
        )
    )
    zb.profiles.auth_with_password(email, password)
    return profile


async def _async_register_and_auth(zb: AsyncZbClient, tag: str, *, age: int = 25) -> Profile:
    email = _unique_email(tag)
    password = "member-pass-1"
    profile = await zb.profiles.create(
        ProfileCreate(
            email=email,
            password=password,
            password_confirm=password,
            name=email.split("@")[0],
            age=age,
        )
    )
    await zb.profiles.auth_with_password(email, password)
    return profile


def test_typed_get_list_smoke(zb: ZbClient) -> None:
    """Harness-first smoke test: a typed `get_list` against the live
    server, unauthenticated, on a `@public`-listed collection."""
    page = zb.tags.get_list()
    assert page.page == 1


def test_crud_nested_relation_expand_cursor(zb: ZbClient) -> None:
    profile = _register_and_auth(zb, "crud")

    # age is int-mode: the typed record exposes it as a Python int.
    assert isinstance(profile.age, int)
    assert profile.age == 25

    t1 = zb.tags.create(TagCreate(label="hiking"))
    t2 = zb.tags.create(TagCreate(label="coffee"))

    p1 = zb.photos.create(PhotoCreate(owner=profile.id, caption="trail", tags=[t1.id, t2.id]))
    p2 = zb.photos.create(PhotoCreate(owner=profile.id, caption="espresso", tags=[t2.id]))
    assert p1.id

    # Negative control: a second profile with its own photo. Without a
    # second owner in play, a broken or silently-ignored filter (e.g. one
    # that compiles to a vacuous `1=1`) would pass every assertion below
    # just as well as a correct one, since `profile` would be the only
    # owner and every photo would "match" regardless.
    other = _register_and_auth(zb, "crud-other")
    other_photo = zb.photos.create(PhotoCreate(owner=other.id, caption="not-mine"))
    known_photo_ids = {p1.id, p2.id, other_photo.id}

    # Nested-relation filter via the typed fluent builder: owner.name ~ '...'.
    by_owner = zb.photos.get_list(where=lambda p: p.owner.rel(lambda o: o.name.like(profile.name)))
    by_owner_ids = {item.id for item in by_owner.items}
    assert len(by_owner_ids) < len(known_photo_ids)  # excludes at least other_photo
    assert by_owner_ids == {p1.id, p2.id}

    # Expand single (owner -> Profile) and multi (tags -> Tag[]).
    with_owner = zb.photos.get_one(p1.id, expand=["owner"])
    assert with_owner.expand.owner is not None
    assert with_owner.expand.owner.id == profile.id

    with_tags = zb.photos.get_one(p1.id, expand=["tags"])
    assert sorted(t.label for t in with_tags.expand.tags) == ["coffee", "hiking"]

    # Update + delete.
    updated = zb.photos.update(p1.id, PhotoUpdate(caption="summit"))
    assert updated.caption == "summit"
    zb.photos.delete(p1.id)
    remaining = zb.photos.get_list(where=lambda p: p.owner.eq(profile.id))
    # other_photo (still live, owned by `other`) is the negative control
    # here too: a broken/ignored filter would return it alongside p2.
    assert len(remaining.items) == 1
    assert remaining.items[0].id == p2.id

    # Native cursor: walk the 2 tags one per page.
    page1 = zb.tags.get_page(sort="-created", limit=1)
    assert len(page1.items) == 1
    assert page1.has_next is True
    page2 = zb.tags.get_page(sort="-created", limit=1, cursor=page1.next_cursor)
    assert len(page2.items) == 1
    assert page2.items[0].id != page1.items[0].id


def test_int_and_fixed_coercion_round_trip(zb: ZbClient) -> None:
    profile = _register_and_auth(zb, "fixed")

    sub = zb.subscriptions.create(
        SubscriptionCreate(
            profile=profile.id,
            plan=SubscriptionPlan.PREMIUM,
            # fixed(2): encoded as "9.99" on write, parsed back to a float.
            price=9.99,
            renewsAt="2026-01-01 00:00:00.000Z",
            active=True,
        )
    )
    assert sub.price == 9.99
    assert sub.plan is SubscriptionPlan.PREMIUM
    assert sub.active is True

    read = zb.subscriptions.get_one(sub.id)
    assert read.price == 9.99


def test_files_public_avatar_and_gated_private_photo(zb: ZbClient) -> None:
    profile = _register_and_auth(zb, "files")

    # Public avatar on the (public) profile -- fileUrl is fetchable anonymously.
    with_avatar = zb.profiles.update(
        profile.id, ProfileUpdate(avatar=("a.png", b"\x01\x02\x03\x04"))
    )
    avatar_url = zb.profiles.file_url(with_avatar, field=ProfileFileField.AVATAR)
    pub = httpx.get(avatar_url, timeout=5.0)
    assert pub.status_code == 200

    # Private photo: owner-only view -- the image file is gated by the viewRule.
    priv = zb.privatePhotos.create(
        PrivatePhotoCreate(
            owner=profile.id, image=("secret.png", b"\x05\x06\x07\x08"), caption="hidden"
        )
    )
    priv_url_no_tok = zb.privatePhotos.file_url(priv, field=PrivatePhotoFileField.IMAGE)
    anon = httpx.get(priv_url_no_tok, timeout=5.0)
    assert anon.status_code != 200

    # With a fresh file-access token (owner is authed), the file is fetchable.
    token = zb.raw.files.get_token()
    priv_url_tok = zb.privatePhotos.file_url(priv, field=PrivatePhotoFileField.IMAGE, token=token)
    ok = httpx.get(priv_url_tok, timeout=5.0)
    assert ok.status_code == 200


async def test_realtime_create_event(async_zb: AsyncZbClient) -> None:
    profile = await _async_register_and_auth(async_zb, "rt")

    events: asyncio.Queue[TypedRealtimeEvent[Photo]] = asyncio.Queue()

    unsub = await async_zb.photosRealtime.subscribe(events.put_nowait)
    try:
        made = await async_zb.photos.create(PhotoCreate(owner=profile.id, caption="live"))
        event = await asyncio.wait_for(events.get(), timeout=_EVENT_TIMEOUT_S)
        assert event.action == "create"
        assert event.record.id == made.id
        # The event's record went through the same from_record coercion as
        # a regular REST response -- check a plain field survives it too,
        # not just the id.
        assert event.record.caption == "live"
    finally:
        await unsub()
