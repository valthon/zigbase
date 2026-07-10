"""Tests for zigbase.realtime.RealtimeService's connect/subscribe/ack core.

Port of the ack-gating and topic-isolation coverage in
clients/typescript/test/realtime-subscribe.test.ts and
clients/dart/test/realtime_test.dart, adapted to asyncio: `pumpEventQueue()`'s
role is played by `_pump()` (a handful of `asyncio.sleep(0)` yields), since
this service's connect/on-open/resubscribe chain runs inline inside the
triggering `subscribe`/`subscribe_topic` call (see realtime.py's
`_ensure_connected`) with only the receive loop as a genuinely concurrent
task -- unlike JS/Dart's single-threaded microtask queue, asyncio needs an
explicit yield for that task (and any second `subscribe` call racing it) to
run.

Auth-gated resubscribe (Task 3), reconnect backoff (Task 4), and `stream()`
(Task 5) are out of scope here.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable

import pytest

from tests.support.fake_connector import FakeConnectorFactory
from zigbase.auth_store import MemoryAuthStore
from zigbase.errors import ZigbaseError
from zigbase.realtime import RealtimeEvent, RealtimeService, TopicMessage


async def _pump(times: int = 5) -> None:
    for _ in range(times):
        await asyncio.sleep(0)


def make_service(
    factory: FakeConnectorFactory | None = None,
    on_error: Callable[[str], None] | None = None,
) -> tuple[RealtimeService, FakeConnectorFactory]:
    factory = factory or FakeConnectorFactory()
    service = RealtimeService(
        "http://api.test", MemoryAuthStore(), connector=factory.connect, on_error=on_error
    )
    return service, factory


class TestLazyConnect:
    async def test_connects_only_on_first_subscribe(self) -> None:
        service, factory = make_service()
        assert factory.connections == []

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()

        assert len(factory.connections) == 1
        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        unsub = await task
        assert callable(unsub)
        await service.close()


class TestAckGating:
    async def test_subscribe_does_not_resolve_before_ack(self) -> None:
        service, factory = make_service()
        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        assert not task.done()

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await _pump()
        assert task.done()
        await service.close()


class TestConcurrentSubscribe:
    async def test_same_topic_and_filter_sends_one_frame_both_callbacks_fire(self) -> None:
        service, factory = make_service()
        events1: list[RealtimeEvent] = []
        events2: list[RealtimeEvent] = []
        task1 = asyncio.create_task(service.subscribe("posts", events1.append))
        task2 = asyncio.create_task(service.subscribe("posts", events2.append))
        await _pump()

        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await asyncio.gather(task1, task2)

        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "update", "record": {"id": "p1"}}
        )
        await _pump()
        assert len(events1) == 1
        assert len(events2) == 1
        await service.close()


class TestFilterVariants:
    async def test_distinct_filters_are_distinct_variants(self) -> None:
        service, factory = make_service()
        task1 = asyncio.create_task(
            service.subscribe("posts", lambda e: None, filter="status='live'")
        )
        await _pump()
        task2 = asyncio.create_task(
            service.subscribe("posts", lambda e: None, filter="status='draft'")
        )
        await _pump()

        assert factory.last.subscribe_frames == [
            {"action": "subscribe", "topic": "posts", "filter": "status='live'"},
            {"action": "subscribe", "topic": "posts", "filter": "status='draft'"},
        ]
        # A single ack is keyed by topic only, so it settles both variants --
        # a pre-existing wire limitation inherited from the TS/Dart SDKs.
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await asyncio.gather(task1, task2)
        await service.close()


class TestEventDispatch:
    async def test_dispatches_only_to_exact_topic(self) -> None:
        service, factory = make_service()
        posts: list[RealtimeEvent] = []
        comments: list[RealtimeEvent] = []
        t1 = asyncio.create_task(service.subscribe("posts", posts.append))
        await _pump()
        t2 = asyncio.create_task(service.subscribe("comments", comments.append))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "comments"})
        await asyncio.gather(t1, t2)

        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "create", "record": {"id": "p1"}}
        )
        await _pump()
        assert len(posts) == 1
        assert posts[0].topic == "posts"
        assert posts[0].action == "create"
        assert posts[0].record == {"id": "p1"}
        assert comments == []
        await service.close()

    async def test_delete_event_carries_id_only_record(self) -> None:
        service, factory = make_service()
        got: list[RealtimeEvent] = []
        task = asyncio.create_task(service.subscribe("posts", got.append))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "delete", "record": {"id": "p9"}}
        )
        await _pump()
        assert len(got) == 1
        assert got[0].action == "delete"
        assert got[0].record == {"id": "p9"}
        await service.close()


class TestUnsubscribe:
    async def test_one_variant_removed_keeps_the_other_no_frame_sent(self) -> None:
        service, factory = make_service()
        a: list[RealtimeEvent] = []
        b: list[RealtimeEvent] = []
        task_a = asyncio.create_task(service.subscribe("posts", a.append))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task_a
        await service.subscribe("posts", b.append)  # already acked -> resolves immediately

        await service.unsubscribe("posts", a.append)
        assert factory.last.unsubscribe_frames == []
        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "update", "record": {"id": "p1"}}
        )
        await _pump()
        assert a == []
        assert len(b) == 1

        await service.unsubscribe("posts", b.append)
        assert factory.last.unsubscribe_frames == [{"action": "unsubscribe", "topic": "posts"}]
        await service.close()

    async def test_unsubscribe_removes_a_filtered_variant_without_filter_arg(self) -> None:
        service, factory = make_service()
        got: list[RealtimeEvent] = []
        task = asyncio.create_task(
            service.subscribe("posts", got.append, filter="status='published'")
        )
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await service.unsubscribe("posts", got.append)
        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "update", "record": {"id": "p1"}}
        )
        await _pump()
        assert got == []
        assert factory.last.unsubscribe_frames == [{"action": "unsubscribe", "topic": "posts"}]
        await service.close()

    async def test_callback_none_and_filter_none_clears_every_variant(self) -> None:
        service, factory = make_service()
        got: list[RealtimeEvent] = []
        t1 = asyncio.create_task(service.subscribe("posts", got.append))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await t1

        t2 = asyncio.create_task(service.subscribe("posts", got.append, filter="status='live'"))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await t2

        await service.unsubscribe("posts")  # callback=None, filter=None -> clears both variants
        assert factory.last.unsubscribe_frames == [{"action": "unsubscribe", "topic": "posts"}]

        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "update", "record": {"id": "p1"}}
        )
        await _pump()
        assert got == []
        await service.close()

    async def test_unsubscribe_is_idempotent_for_unknown_topic_or_callback(self) -> None:
        service, _ = make_service()
        await service.unsubscribe("nope")
        await service.unsubscribe("nope", lambda e: None)
        await service.close()


class TestSubscribeTopic:
    async def test_delivers_signal_and_message_frames_by_topic(self) -> None:
        service, factory = make_service()
        got: list[TopicMessage] = []
        task = asyncio.create_task(service.subscribe_topic("orders", got.append))
        await _pump()
        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "orders"}]
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "orders"})
        await task

        await factory.last.push({"type": "signal", "topic": "orders"})
        await factory.last.push({"type": "message", "topic": "orders", "data": {"n": 1}})
        await factory.last.push({"type": "message", "topic": "other", "data": {"n": 2}})
        await _pump()

        assert got == [
            TopicMessage(topic="orders", kind="signal", data=None),
            TopicMessage(topic="orders", kind="message", data={"n": 1}),
        ]
        await service.close()

    async def test_unsubscribe_topic_sends_one_frame_when_topic_empties(self) -> None:
        service, factory = make_service()
        got: list[TopicMessage] = []
        task = asyncio.create_task(service.subscribe_topic("orders", got.append))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "orders"})
        await task

        await service.unsubscribe_topic("orders", got.append)
        await factory.last.push({"type": "signal", "topic": "orders"})
        await _pump()
        assert got == []
        assert factory.last.unsubscribe_frames == [{"action": "unsubscribe", "topic": "orders"}]
        await service.close()


class TestTopicKeyIsolation:
    async def test_record_sub_key_never_collides_with_topic_sub_key(self) -> None:
        # Regression guard (ported from realtime-subscribe.test.ts): a record
        # subscription crafted as subscribe("", filter="topic:x") would collide
        # with subscribeTopic("x") under a naive `" topic:x"`-style key scheme.
        # The `r:`/`t:` prefixes must keep them structurally disjoint.
        service, factory = make_service()
        record_events: list[RealtimeEvent] = []
        topic_msgs: list[TopicMessage] = []

        t1 = asyncio.create_task(service.subscribe("", record_events.append, filter="topic:x"))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": ""})
        await t1

        t2 = asyncio.create_task(service.subscribe_topic("x", topic_msgs.append))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "x"})
        await t2

        assert {
            "action": "subscribe",
            "topic": "",
            "filter": "topic:x",
        } in factory.last.subscribe_frames
        assert {"action": "subscribe", "topic": "x"} in factory.last.subscribe_frames

        await factory.last.push(
            {"type": "event", "topic": "", "action": "create", "record": {"id": "r1"}}
        )
        await factory.last.push({"type": "signal", "topic": "x"})
        await _pump()
        assert len(record_events) == 1
        assert topic_msgs == [TopicMessage(topic="x", kind="signal", data=None)]

        # Unsubscribing the topic sub must not disturb the independent record sub.
        await service.unsubscribe_topic("x", topic_msgs.append)
        await factory.last.push(
            {"type": "event", "topic": "", "action": "update", "record": {"id": "r1"}}
        )
        await _pump()
        assert len(record_events) == 2
        await service.close()


class TestRaisingCallback:
    async def test_raising_callback_is_caught_and_surfaced_via_on_error(self) -> None:
        errors: list[str] = []
        service, factory = make_service(on_error=errors.append)

        def bad_callback(event: RealtimeEvent) -> None:
            raise ValueError("boom")

        got: list[RealtimeEvent] = []
        task = asyncio.create_task(service.subscribe("posts", bad_callback))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task
        await service.subscribe("posts", got.append)  # already acked -> joins immediately

        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "update", "record": {"id": "p1"}}
        )
        await _pump()

        assert any("boom" in e for e in errors)
        # The loop survived the raising callback: the well-behaved sibling still fired.
        assert len(got) == 1
        await service.close()


class TestMalformedFrames:
    async def test_unknown_frame_type_is_dropped_without_crashing_the_loop(self) -> None:
        service, factory = make_service()
        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "bogus", "topic": "posts"})
        await _pump()
        assert not task.done()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task
        await service.close()


class TestConnectFrame:
    async def test_connect_frame_stores_client_id(self) -> None:
        service, factory = make_service()
        assert service.client_id is None
        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "connect", "clientId": "c1"})
        await _pump()
        assert service.client_id == "c1"
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task
        await service.close()


class TestServerErrorFrame:
    async def test_server_error_rejects_pending_subscribe_and_calls_on_error(self) -> None:
        errors: list[str] = []
        service, factory = make_service(on_error=errors.append)
        task = asyncio.create_task(service.subscribe("private", lambda e: None))
        await _pump()

        await factory.last.push({"type": "error", "message": "anonymous not allowed"})
        with pytest.raises(ZigbaseError) as exc_info:
            await asyncio.wait_for(task, timeout=1)
        assert exc_info.value.message == "anonymous not allowed"
        assert "anonymous not allowed" in errors
        await service.close()

    async def test_a_rejected_subscribe_can_be_retried_with_a_fresh_frame(self) -> None:
        service, factory = make_service()
        task = asyncio.create_task(service.subscribe("private", lambda e: None))
        await _pump()
        await factory.last.push({"type": "error", "message": "nope"})
        with pytest.raises(ZigbaseError):
            await asyncio.wait_for(task, timeout=1)

        retry = asyncio.create_task(service.subscribe("private", lambda e: None))
        await _pump()
        assert len(factory.last.subscribe_frames) == 2
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "private"})
        await retry
        await service.close()


class TestNoConnector:
    async def test_subscribe_without_a_connector_raises_immediately(self) -> None:
        service = RealtimeService("http://api.test", MemoryAuthStore())
        with pytest.raises(ZigbaseError):
            await asyncio.wait_for(service.subscribe("posts", lambda e: None), timeout=1)


class TestPostClose:
    async def test_subscribe_after_close_raises_without_hanging(self) -> None:
        service, factory = make_service()
        await service.close()

        with pytest.raises(ZigbaseError) as exc_info:
            await asyncio.wait_for(service.subscribe("posts", lambda e: None), timeout=1)
        assert exc_info.value.status == 0
        assert factory.connections == []

    async def test_subscribe_topic_after_close_raises_without_hanging(self) -> None:
        service, factory = make_service()
        await service.close()

        with pytest.raises(ZigbaseError):
            await asyncio.wait_for(service.subscribe_topic("orders", lambda m: None), timeout=1)
        assert factory.connections == []


class TestClose:
    async def test_close_cancels_receive_loop_and_closes_connection(self) -> None:
        service, factory = make_service()
        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await asyncio.wait_for(service.close(), timeout=1)
        assert service.client_id is None

    async def test_close_explicitly_closes_the_transport_not_just_the_receive_loop(self) -> None:
        # Regression guard: the receive task's own `finally` clause nulls
        # `self._connection` as part of unwinding from cancellation, so
        # close() must capture the connection reference BEFORE cancelling
        # that task -- reading `self._connection` afterward would find it
        # already `None` and silently skip calling `connection.close()`.
        service, factory = make_service()
        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        conn = factory.last
        close_calls = 0
        original_close = conn.close

        async def _counting_close() -> None:
            nonlocal close_calls
            close_calls += 1
            await original_close()

        conn.close = _counting_close  # type: ignore[method-assign]

        await asyncio.wait_for(service.close(), timeout=1)
        assert close_calls == 1

    async def test_close_during_in_flight_connect_tears_down_the_late_connection(self) -> None:
        factory = FakeConnectorFactory()
        factory.gate = asyncio.Event()
        service, _factory = make_service(factory)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        assert factory.connections == []  # still parked on the gate

        await asyncio.wait_for(service.close(), timeout=1)

        factory.gate.set()
        with pytest.raises(ZigbaseError):
            await asyncio.wait_for(task, timeout=1)

        await _pump()
        assert len(factory.connections) == 1
