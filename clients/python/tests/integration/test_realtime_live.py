"""Live-server realtime coverage: WebSocket subscribe/stream against a real
server, using the default `websockets`-backed connector (the
`zigbase[realtime]` extra) -- the counterpart to the frame/service-level
tests (`test_realtime_subscribe.py`, `test_realtime_service.py`, ...), which
fake the transport. Mirrors `clients/dart/test/integration/integration_test.dart`
(~L235-260) and `clients/typescript/test/integration/realtime.integration.test.ts`.

`feed` (see `conftest.py`'s `_bootstrap`) is a dedicated `@public` collection
so this file's create/update/delete traffic never crosses streams with
`posts`' CRUD/filter/abilities/files coverage running in the same session.

Reconnect (bounded-backoff resume after an unexpected drop) is intentionally
NOT covered here: exercising it live would mean killing the shared session
server mid-suite, which every other file in this directory depends on
staying up. It's already covered at the unit level, where the connector can
be faked to simulate a drop.
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools

import pytest

from zigbase import AsyncZigBase, ZigBase, ZigbaseError
from zigbase.query import zb_filter
from zigbase.realtime import RealtimeEvent

pytestmark = pytest.mark.integration

_EVENT_TIMEOUT_S = 10.0

_feed_seq = itertools.count()


def _feed_title() -> str:
    return f"rt-{next(_feed_seq)}"


async def _next_event(queue: asyncio.Queue[RealtimeEvent]) -> RealtimeEvent:
    return await asyncio.wait_for(queue.get(), timeout=_EVENT_TIMEOUT_S)


async def test_subscribe_smoke(async_client: AsyncZigBase) -> None:
    """Connecting and subscribing to a `@public` collection acks without
    raising -- the harness-first smoke test."""
    events: asyncio.Queue[RealtimeEvent] = asyncio.Queue()
    unsub = await async_client.realtime.subscribe("feed", events.put_nowait)
    await unsub()


async def test_create_event_delivered(async_client: AsyncZigBase, admin_client: ZigBase) -> None:
    events: asyncio.Queue[RealtimeEvent] = asyncio.Queue()
    unsub = await async_client.realtime.subscribe("feed", events.put_nowait)
    try:
        created = admin_client.collection("feed").create({"title": _feed_title(), "views": 1})
        event = await _next_event(events)
        assert event.action == "create"
        assert event.record["id"] == created["id"]
    finally:
        await unsub()


async def test_update_and_delete_events_on_both_topics(
    async_client: AsyncZigBase, admin_client: ZigBase
) -> None:
    """Subscribed to both the collection topic (`feed`) and a specific
    record's topic (`feed/<id>`), an update/delete delivers a SEPARATE
    `event` frame per topic (the two are distinct subscriptions, so the
    server sends one frame each rather than a single frame fanned out
    client-side); a delete's record is id-only per the wire protocol."""
    created = admin_client.collection("feed").create({"title": _feed_title(), "views": 1})
    record_id = created["id"]

    collection_events: asyncio.Queue[RealtimeEvent] = asyncio.Queue()
    record_events: asyncio.Queue[RealtimeEvent] = asyncio.Queue()
    unsub_collection = await async_client.realtime.subscribe("feed", collection_events.put_nowait)
    unsub_record = await async_client.realtime.subscribe(
        f"feed/{record_id}", record_events.put_nowait
    )
    try:
        admin_client.collection("feed").update(record_id, {"title": "updated"})

        collection_event = await _next_event(collection_events)
        assert collection_event.action == "update"
        assert collection_event.record["id"] == record_id

        record_event = await _next_event(record_events)
        assert record_event.action == "update"
        assert record_event.record["id"] == record_id

        admin_client.collection("feed").delete(record_id)

        collection_delete = await _next_event(collection_events)
        assert collection_delete.action == "delete"
        assert collection_delete.record == {"id": record_id}

        record_delete = await _next_event(record_events)
        assert record_delete.action == "delete"
        assert record_delete.record == {"id": record_id}
    finally:
        await unsub_collection()
        await unsub_record()


async def test_members_subscribe_requires_auth_then_delivers_own_update(
    admin_client: ZigBase, server_url: str
) -> None:
    """`members`' `viewRule` (`@request.auth.id = id`, see `conftest.py`) is
    neither blank nor `@public`, so an anonymous socket is rejected at
    SUBSCRIBE time (`subscribeAuthorized` in `src/realtime/hub.zig`) --
    before per-record delivery is even considered. Once authenticated (any
    member, not necessarily the record's owner) the subscribe itself
    succeeds; delivery then stays gated per record by the owner-scoped
    rule, so logging in as the record's own owner is what proves an event
    actually arrives."""
    email = f"rtmember{next(_feed_seq)}@test.local"
    password = "member-rt-pass-1"
    seeded = admin_client.collection("members").create(
        {
            "email": email,
            "password": password,
            "passwordConfirm": password,
            "name": "RT Member",
            "emailVisibility": True,
        }
    )
    member_id = seeded["id"]

    async with AsyncZigBase(server_url) as anon:
        with pytest.raises(ZigbaseError) as exc_info:
            await anon.realtime.subscribe("members", lambda e: None)
        assert "authentication required" in str(exc_info.value)

    async with AsyncZigBase(server_url) as member_client:
        await member_client.collection("members").auth_with_password(email, password)

        events: asyncio.Queue[RealtimeEvent] = asyncio.Queue()
        unsub = await member_client.realtime.subscribe("members", events.put_nowait)
        try:
            admin_client.collection("members").update(member_id, {"name": "RT Member 2"})
            event = await _next_event(events)
            assert event.action == "update"
            assert event.record["id"] == member_id
        finally:
            await unsub()


async def test_filtered_subscribe_only_delivers_matching_events(
    async_client: AsyncZigBase, admin_client: ZigBase
) -> None:
    tag = _feed_title()
    expr = zb_filter("title = {:t}", {"t": tag})

    events: asyncio.Queue[RealtimeEvent] = asyncio.Queue()
    unsub = await async_client.realtime.subscribe("feed", events.put_nowait, filter=expr)
    try:
        # Non-matching first, matching second: a filtered subscription must
        # skip the former and deliver only the latter, so the FIRST (and
        # only) event received is provably the matching one -- an
        # ordering-free negative check that never waits out an absence.
        admin_client.collection("feed").create({"title": _feed_title(), "views": 1})
        matching = admin_client.collection("feed").create({"title": tag, "views": 2})

        event = await _next_event(events)
        assert event.action == "create"
        assert event.record["id"] == matching["id"]
        assert event.record["title"] == tag
    finally:
        await unsub()


@pytest.mark.filterwarnings("error::RuntimeWarning", "error::ResourceWarning")
async def test_stream_yields_one_event_then_breaks_cleanly(
    async_client: AsyncZigBase, admin_client: ZigBase
) -> None:
    async def _create_soon() -> None:
        await asyncio.sleep(0.05)
        admin_client.collection("feed").create({"title": _feed_title(), "views": 1})

    creator = asyncio.create_task(_create_soon())
    try:
        seen = 0
        async with contextlib.aclosing(async_client.realtime.stream("feed")) as events:
            async for event in events:
                assert event.action == "create"
                seen += 1
                break
        assert seen == 1
    finally:
        await creator
