"""Live-server auth coverage: password auth, refresh, logout.

`members` is an auth-type collection whose `createRule` is blank (Locked --
every member record is seeded by the superuser `admin_client` fixture, never
via public signup) and whose `viewRule`/`listRule` are scoped to the
caller's own record (`@request.auth.id = id`, see `conftest.py`'s
`_members_definition`) -- mirroring
`clients/typescript/test/integration/auth.integration.test.ts`'s `members`
setup, then logging in through the public password-auth endpoint exactly as
an end-user client would.
"""

from __future__ import annotations

import itertools

import pytest

from zigbase import AsyncZigBase, ZigBase, ZigbaseError

pytestmark = pytest.mark.integration

_member_seq = itertools.count()


def _seed_member(admin_client: ZigBase, *, password: str) -> dict[str, str]:
    """Create a `members` record with a unique email via the superuser
    client. Returns `{"email": ..., "password": ...}`."""
    email = f"member{next(_member_seq)}@test.local"
    admin_client.collection("members").create(
        {
            "email": email,
            "password": password,
            "passwordConfirm": password,
            "name": "Mem",
            "emailVisibility": True,
        }
    )
    return {"email": email, "password": password}


def test_password_auth(client: ZigBase, admin_client: ZigBase) -> None:
    creds = _seed_member(admin_client, password="member-pass-1")

    auth = client.collection("members").auth_with_password(creds["email"], creds["password"])
    assert auth.token
    assert client.auth_store.token == auth.token
    assert auth.record is not None
    assert auth.record["email"] == creds["email"]


async def test_password_auth_async(async_client: AsyncZigBase, admin_client: ZigBase) -> None:
    creds = _seed_member(admin_client, password="member-pass-async-1")

    auth = await async_client.collection("members").auth_with_password(
        creds["email"], creds["password"]
    )
    assert auth.token
    assert async_client.auth_store.token == auth.token


def test_auth_refresh_rotates_token(
    client: ZigBase, admin_client: ZigBase, server_url: str
) -> None:
    creds = _seed_member(admin_client, password="member-pass-2")
    members = client.collection("members")
    auth = members.auth_with_password(creds["email"], creds["password"])
    assert auth.record is not None
    member_id = auth.record["id"]

    refreshed = members.auth_refresh()
    assert refreshed.token
    assert client.auth_store.token == refreshed.token

    # The refreshed token genuinely authenticates: `members`' viewRule is
    # `@request.auth.id = id`, so only the record's own owner can view it.
    # /api/health is a bad proof here -- it has no auth check at all, so it
    # would pass with any (or no) token.
    own_record = members.get_one(member_id)
    assert own_record["id"] == member_id

    # ... and the same rule denies the SAME record to an anonymous caller,
    # so the assertion above has teeth (it isn't just "any token works").
    with ZigBase(server_url) as anon, pytest.raises(ZigbaseError) as exc_info:
        anon.collection("members").get_one(member_id)
    assert exc_info.value.status == 404  # view denial never reveals existence


async def test_auth_refresh_rotates_token_async(
    async_client: AsyncZigBase, admin_client: ZigBase, server_url: str
) -> None:
    creds = _seed_member(admin_client, password="member-pass-2-async")
    members = async_client.collection("members")
    auth = await members.auth_with_password(creds["email"], creds["password"])
    assert auth.record is not None
    member_id = auth.record["id"]

    refreshed = await members.auth_refresh()
    assert refreshed.token
    assert async_client.auth_store.token == refreshed.token

    own_record = await members.get_one(member_id)
    assert own_record["id"] == member_id

    async with AsyncZigBase(server_url) as anon:
        with pytest.raises(ZigbaseError) as exc_info:
            await anon.collection("members").get_one(member_id)
    assert exc_info.value.status == 404


def test_logout_clears_store(client: ZigBase, admin_client: ZigBase) -> None:
    creds = _seed_member(admin_client, password="member-pass-3")
    members = client.collection("members")
    members.auth_with_password(creds["email"], creds["password"])
    assert client.auth_store.token is not None

    members.logout()
    assert client.auth_store.token is None
    assert client.auth_store.record is None


async def test_logout_clears_store_async(async_client: AsyncZigBase, admin_client: ZigBase) -> None:
    creds = _seed_member(admin_client, password="member-pass-3-async")
    members = async_client.collection("members")
    await members.auth_with_password(creds["email"], creds["password"])
    assert async_client.auth_store.token is not None

    await members.logout()
    assert async_client.auth_store.token is None
    assert async_client.auth_store.record is None
