"""Tests for `zigbase.typed`'s `TypedRealtime`/`TypedRealtimeEvent`, a port
of `clients/dart/lib/typed.dart:522-569` (`TypedRealtime<T>`).

Drives a real `AsyncZigBase` wired to a `FakeConnectorFactory` (same doubles
`test_realtime_subscribe.py` etc. use) so the wrapper is exercised through
the actual `client.realtime` property rather than a hand-rolled fake
`RealtimeService`.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any

import pytest

from tests.support.fake_connector import FakeConnectorFactory
from zigbase.client import AsyncZigBase
from zigbase.typed import (
    CollectionMeta,
    FieldMeta,
    FieldType,
    StringFieldExpr,
    TypedRealtime,
    TypedRealtimeEvent,
)


async def _pump(times: int = 5) -> None:
    for _ in range(times):
        await asyncio.sleep(0)


@dataclass(frozen=True)
class Post:
    """A minimal generated-style typed record."""

    id: str
    title: str


def post_from_record(record: dict[str, Any]) -> Post:
    return Post(id=str(record.get("id", "")), title=str(record.get("title", "")))


POSTS_META = CollectionMeta(
    name="posts",
    fields={"title": FieldMeta(type=FieldType.TEXT)},
)


def make_client(factory: FakeConnectorFactory) -> AsyncZigBase:
    return AsyncZigBase("http://api.test", realtime_connector=factory.connect)


def make_typed_realtime(
    factory: FakeConnectorFactory | None = None,
) -> tuple[TypedRealtime[Post], AsyncZigBase, FakeConnectorFactory]:
    factory = factory or FakeConnectorFactory()
    client = make_client(factory)
    return TypedRealtime(client, POSTS_META, post_from_record), client, factory


class TestSubscribe:
    async def test_delivers_typed_event_with_converted_record(self) -> None:
        rt, client, factory = make_typed_realtime()
        events: list[TypedRealtimeEvent[Post]] = []

        task = asyncio.create_task(rt.subscribe(events.append))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        unsub = await task

        await factory.last.push(
            {
                "type": "event",
                "topic": "posts",
                "action": "create",
                "record": {"id": "1", "title": "Hi"},
            }
        )
        await _pump()

        assert len(events) == 1
        event = events[0]
        assert isinstance(event, TypedRealtimeEvent)
        assert event.topic == "posts"
        assert event.action == "create"
        assert isinstance(event.record, Post)
        assert event.record == Post(id="1", title="Hi")

        await unsub()
        await client.aclose()

    async def test_filter_string_passthrough(self) -> None:
        rt, client, factory = make_typed_realtime()

        task = asyncio.create_task(rt.subscribe(lambda e: None, filter="title = 'x'"))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        assert factory.last.subscribe_frames == [
            {"action": "subscribe", "topic": "posts", "filter": "title = 'x'"}
        ]
        await client.aclose()

    async def test_where_expr_compiles_into_subscribe_frame_filter(self) -> None:
        rt, client, factory = make_typed_realtime()
        where = StringFieldExpr("title").eq("Hi")

        task = asyncio.create_task(rt.subscribe(lambda e: None, where=where))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        assert factory.last.subscribe_frames == [
            {"action": "subscribe", "topic": "posts", "filter": where.compile()}
        ]
        await client.aclose()

    async def test_where_takes_precedence_over_filter(self) -> None:
        rt, client, factory = make_typed_realtime()
        where = StringFieldExpr("title").eq("Hi")

        task = asyncio.create_task(rt.subscribe(lambda e: None, filter="ignored = 1", where=where))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        assert factory.last.subscribe_frames == [
            {"action": "subscribe", "topic": "posts", "filter": where.compile()}
        ]
        await client.aclose()

    async def test_delete_event_record_is_converted_via_from_record_fallbacks(self) -> None:
        rt, client, factory = make_typed_realtime()
        events: list[TypedRealtimeEvent[Post]] = []

        task = asyncio.create_task(rt.subscribe(events.append))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "delete", "record": {"id": "1"}}
        )
        await _pump()

        assert len(events) == 1
        assert events[0].action == "delete"
        # `title` is absent on a delete frame -- from_record's coercer
        # fallback (`record.get("title", "")`) fills it in rather than
        # raising, mirroring typed.dart's TypedRealtime (no delete special
        # case: fromRecord runs unconditionally for every action).
        assert events[0].record == Post(id="1", title="")

        await client.aclose()

    async def test_returned_unsubscribe_sends_unsubscribe_frame(self) -> None:
        rt, client, factory = make_typed_realtime()

        task = asyncio.create_task(rt.subscribe(lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        unsub = await task

        await unsub()
        await _pump()

        assert factory.last.unsubscribe_frames == [{"action": "unsubscribe", "topic": "posts"}]
        await client.aclose()

    async def test_raising_callback_does_not_kill_the_dispatch_loop(self) -> None:
        errors: list[str] = []
        factory = FakeConnectorFactory()
        client = AsyncZigBase(
            "http://api.test", realtime_connector=factory.connect, on_realtime_error=errors.append
        )
        rt = TypedRealtime(client, POSTS_META, post_from_record)
        good_events: list[TypedRealtimeEvent[Post]] = []

        def bad_callback(_event: TypedRealtimeEvent[Post]) -> None:
            raise ValueError("boom")

        task = asyncio.create_task(rt.subscribe(bad_callback))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task
        await rt.subscribe(good_events.append)
        await _pump()

        await factory.last.push(
            {
                "type": "event",
                "topic": "posts",
                "action": "create",
                "record": {"id": "1", "title": "Hi"},
            }
        )
        await _pump()

        assert errors == ["boom"]
        assert len(good_events) == 1

        await client.aclose()


class TestStream:
    async def test_yields_typed_events(self) -> None:
        rt, client, factory = make_typed_realtime()

        async def consume() -> TypedRealtimeEvent[Post]:
            async for event in rt.stream():
                return event
            raise AssertionError("stream ended without an event")

        task = asyncio.create_task(consume())
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await _pump()
        await factory.last.push(
            {
                "type": "event",
                "topic": "posts",
                "action": "update",
                "record": {"id": "2", "title": "Bye"},
            }
        )

        event = await asyncio.wait_for(task, timeout=1)
        assert isinstance(event, TypedRealtimeEvent)
        assert event.record == Post(id="2", title="Bye")

        await client.aclose()

    async def test_tears_down_on_break(self) -> None:
        rt, client, factory = make_typed_realtime()

        async def consume() -> None:
            async for _event in rt.stream():
                break

        task = asyncio.create_task(consume())
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await _pump()
        await factory.last.push(
            {
                "type": "event",
                "topic": "posts",
                "action": "create",
                "record": {"id": "3", "title": "Z"},
            }
        )
        await asyncio.wait_for(task, timeout=1)
        await _pump()

        assert factory.last.unsubscribe_frames == [{"action": "unsubscribe", "topic": "posts"}]
        await client.aclose()

    async def test_where_expr_compiles_into_stream_subscribe_frame(self) -> None:
        rt, client, factory = make_typed_realtime()
        where = StringFieldExpr("title").eq("Hi")

        async def consume() -> None:
            async for _event in rt.stream(where=where):
                break

        task = asyncio.create_task(consume())
        await _pump()
        assert factory.last.subscribe_frames == [
            {"action": "subscribe", "topic": "posts", "filter": where.compile()}
        ]
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await _pump()
        await factory.last.push(
            {
                "type": "event",
                "topic": "posts",
                "action": "create",
                "record": {"id": "4", "title": "Hi"},
            }
        )
        await asyncio.wait_for(task, timeout=1)

        await client.aclose()


class TestNoClose:
    def test_has_no_close_method(self) -> None:
        """`TypedRealtime` wraps the client's single **shared, multiplexed**
        `RealtimeService` -- there is deliberately no per-collection
        `close()` (matching `clients/dart/lib/typed.dart`'s `TypedRealtime`,
        which documents the same omission): closing the shared service
        would kill every other collection's subscriptions and permanently
        disable reconnect. Tear down individual subscriptions with the
        `Unsubscribe` returned by `subscribe()`; tear down the connection
        itself with `AsyncZigBase.aclose()`.
        """
        rt, _client, _factory = make_typed_realtime()
        assert not hasattr(rt, "close")


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__, "-q"]))
