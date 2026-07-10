"""Tests for `RealtimeService`'s reconnect/backoff/error-frame lifecycle (SP2 Task 4).

Port of the reconnect coverage in clients/typescript/test/realtime-reconnect.test.ts
and clients/dart/test/realtime_test.dart's reconnect group, adapted to asyncio (see
test_realtime_subscribe.py's module docstring for the `_pump()` rationale). Unlike
those single-threaded JS/Dart event loops, chained reconnect attempts here each
require their own event-loop turn (every `_schedule_reconnect` creates a fresh
`asyncio.Task`), so tests that drive several attempts back to back poll with
`_pump_until` rather than a fixed number of `_pump()` yields.

Also closes three carry-forward gaps flagged by prior task reviews (T2/T3):
a still-unacked subscribe surviving an unexpected drop and settling once the
reconnect delivers a fresh ack; an initial connect failure staying invisible to
the `subscribe()` caller (no exception, no orphaned registration) rather than
propagating; and `_resubscribe_all`'s per-subscription sends surviving a
connection drop landing mid-loop instead of asserting.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable

import pytest

from tests.support.fake_connector import FakeConnectorFactory
from zigbase import realtime
from zigbase.auth_store import MemoryAuthStore
from zigbase.errors import ZigbaseError
from zigbase.realtime import RealtimeEvent, RealtimeService


async def _pump(times: int = 5) -> None:
    for _ in range(times):
        await asyncio.sleep(0)


async def _pump_until(predicate: Callable[[], bool], limit: int = 500) -> None:
    for _ in range(limit):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("condition not met within pump limit")


def make_service(
    factory: FakeConnectorFactory | None = None,
    auth_store: MemoryAuthStore | None = None,
    on_error: Callable[[str], None] | None = None,
) -> tuple[RealtimeService, FakeConnectorFactory]:
    factory = factory or FakeConnectorFactory()
    auth_store = auth_store or MemoryAuthStore()
    service = RealtimeService(
        "http://api.test", auth_store, connector=factory.connect, on_error=on_error
    )
    return service, factory


class TestUnexpectedClose:
    async def test_reconnects_and_resends_auth_and_subscribe_on_the_new_connection(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        delays: list[float] = []

        async def fake_sleep(seconds: float) -> None:
            delays.append(seconds)

        monkeypatch.setattr(realtime, "_asleep", fake_sleep)
        store = MemoryAuthStore()
        store.save("tok-1", {"id": "u1"})
        factory = FakeConnectorFactory()
        service, _ = make_service(factory, auth_store=store)

        events: list[RealtimeEvent] = []
        task = asyncio.create_task(service.subscribe("posts", events.append))
        await _pump()
        await factory.last.push({"type": "auth", "status": "ok"})
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        first = factory.last
        await first.server_close()
        await _pump_until(lambda: len(factory.connections) == 2)
        assert delays == [0.25]

        second = factory.last
        assert second is not first
        assert second.sent == [{"action": "auth", "token": "tok-1"}]
        await second.push({"type": "auth", "status": "ok"})
        await _pump()
        assert second.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]
        await second.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await _pump()

        await second.push(
            {"type": "event", "topic": "posts", "action": "create", "record": {"id": "p9"}}
        )
        await _pump()
        assert len(events) == 1
        assert events[0].record == {"id": "p9"}
        await service.close()


class TestBackoff:
    async def test_backoff_doubles_across_consecutive_connect_failures(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        delays: list[float] = []

        async def fake_sleep(seconds: float) -> None:
            delays.append(seconds)

        monkeypatch.setattr(realtime, "_asleep", fake_sleep)
        factory = FakeConnectorFactory()
        factory.pending_failures = 3
        service, _ = make_service(factory)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump_until(lambda: len(factory.connections) == 1)

        assert delays == [0.25, 0.5, 1.0]
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task
        await service.close()

    async def test_backoff_caps_at_ten_seconds(self, monkeypatch: pytest.MonkeyPatch) -> None:
        delays: list[float] = []

        async def fake_sleep(seconds: float) -> None:
            delays.append(seconds)

        monkeypatch.setattr(realtime, "_asleep", fake_sleep)
        factory = FakeConnectorFactory()
        factory.pending_failures = 7
        service, _ = make_service(factory)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump_until(lambda: len(factory.connections) == 1)

        assert delays == [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 10.0]
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task
        await service.close()

    async def test_attempts_reset_after_successful_open(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        delays: list[float] = []

        async def fake_sleep(seconds: float) -> None:
            delays.append(seconds)

        monkeypatch.setattr(realtime, "_asleep", fake_sleep)
        factory = FakeConnectorFactory()
        factory.pending_failures = 1
        service, _ = make_service(factory)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump_until(lambda: len(factory.connections) == 1)
        assert delays == [0.25]
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        # Drop the now-healthy connection -- if attempts hadn't reset on the
        # earlier successful open, this backoff would continue doubling (0.5)
        # instead of restarting at the base delay.
        await factory.last.server_close()
        await _pump_until(lambda: len(factory.connections) == 2)
        assert delays == [0.25, 0.25]
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await service.close()


class TestSubscribeDuringBackoff:
    async def test_creates_no_second_connection_until_backoff_elapses(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        gate = asyncio.Event()

        async def gated_sleep(seconds: float) -> None:
            await gate.wait()

        monkeypatch.setattr(realtime, "_asleep", gated_sleep)
        service, factory = make_service()

        task1 = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task1
        assert len(factory.connections) == 1

        await factory.last.server_close()
        await _pump()  # reconnect scheduled, now parked on the gated sleep
        assert len(factory.connections) == 1

        task2 = asyncio.create_task(service.subscribe("comments", lambda e: None))
        await _pump()
        assert len(factory.connections) == 1  # still no competing socket

        gate.set()
        await _pump_until(lambda: len(factory.connections) == 2)
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "comments"})
        await task2
        await service.close()


class TestErrorFrameDuringBackoff:
    async def test_rejects_pending_and_a_later_reconnect_skips_that_topic(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(realtime, "_asleep", lambda seconds: asyncio.sleep(0))
        errors: list[str] = []
        service, factory = make_service(on_error=errors.append)
        good_task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await good_task

        bad_task = asyncio.create_task(service.subscribe("private", lambda e: None))
        await _pump()
        await factory.last.push({"type": "error", "message": "not allowed"})
        with pytest.raises(ZigbaseError) as exc_info:
            await asyncio.wait_for(bad_task, timeout=1)
        assert exc_info.value.status == 0
        assert "not allowed" in errors

        first = factory.last
        await first.server_close()
        await _pump_until(lambda: len(factory.connections) == 2)
        second = factory.last
        topics = [f["topic"] for f in second.subscribe_frames]
        assert topics == ["posts"]  # NOT "private"
        await second.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await service.close()


class TestThrowingSleep:
    async def test_hits_on_error_and_does_not_wedge_reconnect(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        calls = 0

        async def flaky_sleep(seconds: float) -> None:
            nonlocal calls
            calls += 1
            if calls == 1:
                raise RuntimeError("sleep broke")

        monkeypatch.setattr(realtime, "_asleep", flaky_sleep)
        errors: list[str] = []
        service, factory = make_service(on_error=errors.append)
        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        first = factory.last
        await first.server_close()
        await _pump_until(lambda: len(factory.connections) == 2)
        assert "sleep broke" in errors

        # Not wedged: a second drop still triggers a reconnect.
        second = factory.last
        await second.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await second.server_close()
        await _pump_until(lambda: len(factory.connections) == 3)
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await service.close()


class TestCloseDuringBackoff:
    async def test_close_cancels_the_pending_reconnect(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        gate = asyncio.Event()

        async def gated_sleep(seconds: float) -> None:
            await gate.wait()

        monkeypatch.setattr(realtime, "_asleep", gated_sleep)
        service, factory = make_service()
        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await factory.last.server_close()
        await _pump()  # reconnect scheduled, parked on the gate
        assert len(factory.connections) == 1

        await asyncio.wait_for(service.close(), timeout=1)
        gate.set()  # release the gate -- even so, no reconnect must follow
        await _pump(20)
        assert len(factory.connections) == 1


class TestReconnectGatedOnLiveSubscriptions:
    """TS (`onClose`/`connect`'s catch) and Dart (`_onClose`/`_connect`'s catch)
    both only schedule a reconnect when `subscriptions` is non-empty -- an
    idle socket (every caller unsubscribed) that drops, or fails to connect,
    must not be resurrected. The Python port initially scheduled
    unconditionally at both call sites (`_receive_loop`'s finally and
    `_connect_once`'s except branch); this closes that gap."""

    async def test_drop_with_no_live_subscriptions_does_not_reconnect(self) -> None:
        service, factory = make_service()

        def cb(event: RealtimeEvent) -> None:
            return None

        task = asyncio.create_task(service.subscribe("posts", cb))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await service.unsubscribe("posts", cb)
        assert factory.last.unsubscribe_frames == [{"action": "unsubscribe", "topic": "posts"}]

        await factory.last.server_close()
        await _pump(20)

        assert len(factory.connections) == 1  # no reconnect attempted
        assert service._reconnect_pending is False  # type: ignore[attr-defined]
        assert service._reconnect_task is None  # type: ignore[attr-defined]
        await service.close()

    async def test_drop_with_live_subscriptions_still_reconnects(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Existing-behavior guard alongside the gate above: a live
        # subscription must still trigger a reconnect on an unexpected drop.
        monkeypatch.setattr(realtime, "_asleep", lambda seconds: asyncio.sleep(0))
        service, factory = make_service()
        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await factory.last.server_close()
        await _pump_until(lambda: len(factory.connections) == 2)
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await service.close()

    async def test_connect_failure_with_no_live_subscriptions_does_not_reschedule(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Targets the OTHER schedule site: `_connect_once`'s except branch,
        # reached from inside `_reconnect` after the backoff sleep. Subscriptions
        # drain to zero WHILE that sleep is parked, so the connect attempt that
        # follows -- which itself fails -- must not schedule a further retry.
        gate = asyncio.Event()

        async def gated_sleep(seconds: float) -> None:
            await gate.wait()

        monkeypatch.setattr(realtime, "_asleep", gated_sleep)

        def cb(event: RealtimeEvent) -> None:
            return None

        factory = FakeConnectorFactory()
        service, _ = make_service(factory)
        task = asyncio.create_task(service.subscribe("posts", cb))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await factory.last.server_close()
        await _pump()  # reconnect scheduled (subs still live), parked on the gate
        assert len(factory.connections) == 1

        await service.unsubscribe("posts", cb)  # drains subscriptions to zero mid-backoff
        factory.pending_failures = 1  # the upcoming connect attempt fails once

        gate.set()
        await _pump(20)

        assert len(factory.connections) == 1  # the failed attempt built no connection
        assert service._reconnect_pending is False  # type: ignore[attr-defined]
        # The one reconnect task that DID run is done (failed to connect, and
        # -- the behavior under test -- did not schedule a successor since
        # subscriptions had drained to zero by then).
        reconnect_task = service._reconnect_task  # type: ignore[attr-defined]
        assert reconnect_task is not None and reconnect_task.done()
        await service.close()


class TestOnOpenFailureDoesNotEscapeConnect:
    async def test_on_open_failure_does_not_raise_to_subscribe_and_reconnect_completes(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Regression guard: `await self._on_open()` in `_connect_once` used to
        # be unguarded -- any exception raised out of it (auth/resubscribe
        # sends, or anything else `_on_open` might someday do) escaped
        # `_connect_once` entirely, reaching a racing `subscribe()` caller (via
        # `_ensure_connected`) or killing the reconnect task outright. The fix
        # catches it, reports via `on_error`, and closes the now-suspect
        # connection so the receive loop's own drop-handling (`finally` ->
        # `_schedule_reconnect`) takes over -- never re-raising to the caller.
        # `_on_open` is monkeypatched directly here to isolate this guard from
        # the (separately fixed) inner send guards in `_send_auth_frame`/
        # `_send_subscribe`, which would otherwise absorb the failure before
        # it ever reaches `_connect_once`.
        monkeypatch.setattr(realtime, "_asleep", lambda seconds: asyncio.sleep(0))
        errors: list[str] = []
        service, factory = make_service(on_error=errors.append)

        original_on_open = service._on_open  # type: ignore[attr-defined]
        calls = 0

        async def failing_on_open() -> None:
            nonlocal calls
            calls += 1
            if calls == 1:
                raise RuntimeError("on-open boom")
            await original_on_open()

        monkeypatch.setattr(service, "_on_open", failing_on_open)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump_until(lambda: len(factory.connections) == 1)
        await _pump()
        assert not task.done()
        assert any("on-open boom" in e for e in errors)

        # The failed-open connection was closed/discarded -> the receive
        # loop's finally schedules a reconnect, same as an unexpected drop.
        await _pump_until(lambda: len(factory.connections) == 2)
        assert not task.done()

        second = factory.last
        assert second.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]
        await second.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await asyncio.wait_for(task, timeout=1)
        await service.close()


class TestSendSubscribeSendFailure:
    async def test_send_failure_does_not_raise_resets_inflight_and_resends_on_next_open(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Regression guard: `_send_subscribe`'s `await connection.send(...)`
        # used to be unguarded, so a transport-level send failure escaped
        # straight out of `subscribe()`/`subscribe_topic()` (and out of
        # `_resubscribe_all`/`_on_open`). The fix catches it, resets
        # `sub.inflight` so the subscription isn't wedged looking "in flight"
        # forever, and reports via `on_error` -- the caller's pending future
        # stays pending (same established contract as an unacked subscribe
        # surviving a drop) until the next reconnect resends the frame.
        monkeypatch.setattr(realtime, "_asleep", lambda seconds: asyncio.sleep(0))
        errors: list[str] = []
        factory = FakeConnectorFactory()
        service, _ = make_service(factory, on_error=errors.append)

        t1 = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await t1

        conn = factory.last
        conn.send_exception = RuntimeError("send boom")

        task = asyncio.create_task(service.subscribe("comments", lambda e: None))
        await asyncio.wait_for(_pump(), timeout=1)

        assert any("send boom" in e for e in errors)
        sub = service._subscriptions["r:comments"]  # type: ignore[attr-defined]
        assert sub.inflight is False
        assert not task.done()

        await conn.server_close()
        await _pump_until(lambda: len(factory.connections) == 2)
        second = factory.last
        assert "comments" in [f["topic"] for f in second.subscribe_frames]
        await second.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await second.push({"type": "ack", "action": "subscribe", "topic": "comments"})
        await asyncio.wait_for(task, timeout=1)
        await service.close()


# ---- carry-forward closures from the T2/T3 reviews -------------------------


class TestDropBeforeAckResolvesViaReconnect:
    async def test_unacked_subscribe_settles_once_reconnect_delivers_an_ack(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Was a permanent hang before Task 4 (documented as a known
        # limitation); reconnect must now resend the never-acked frame and
        # let its original future settle.
        monkeypatch.setattr(realtime, "_asleep", lambda seconds: asyncio.sleep(0))
        service, factory = make_service()
        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]

        await factory.last.server_close()
        await _pump_until(lambda: len(factory.connections) == 2)

        assert not task.done()
        second = factory.last
        assert second.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]
        await second.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await asyncio.wait_for(task, timeout=1)
        await service.close()


class TestConnectFailureDoesNotOrphan:
    async def test_initial_connect_failure_does_not_raise_and_leaves_no_orphan(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Was: the connector's exception propagated straight out of
        # subscribe(), but the callback had already been registered --
        # leaving an orphan a later successful connect would silently
        # resubscribe even though the caller believed the call had failed.
        # TS never propagates a connect failure to the caller (`connect()` is
        # fire-and-forget); this ports that contract: the failure is
        # surfaced via on_error and the subscribe stays pending.
        monkeypatch.setattr(realtime, "_asleep", lambda seconds: asyncio.sleep(0))
        errors: list[str] = []
        factory = FakeConnectorFactory()
        factory.pending_failures = 1
        service, _ = make_service(factory, on_error=errors.append)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump_until(lambda: len(factory.connections) == 1)

        assert not task.done()
        assert any("connect failed" in e for e in errors)

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await asyncio.wait_for(task, timeout=1)
        await service.close()


class TestResubscribeSurvivesMidLoopDrop:
    async def test_resubscribe_all_does_not_crash_when_connection_drops_mid_loop(self) -> None:
        # Regression guard: `_send_subscribe` used to `assert self._connection
        # is not None`. `_resubscribe_all` awaits one send per subscription in
        # a loop; if the connection dropped between two of those awaits (the
        # transport dying right after the first frame went out), the second
        # iteration's assert would crash the whole reconnect/open path instead
        # of silently dropping the frame (a later reconnect resends it). None
        # of our cooperative-scheduling fakes can trigger that interleaving on
        # their own (nothing here truly suspends mid-send), so the drop is
        # forced directly to prove the guard holds.
        service, factory = make_service()
        t1 = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await t1
        t2 = asyncio.create_task(service.subscribe("comments", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "comments"})
        await t2

        conn = factory.last
        calls = 0
        original_send = conn.send

        async def dropping_send(data: str) -> None:
            nonlocal calls
            calls += 1
            if calls == 1:
                service._connection = None  # type: ignore[attr-defined]
            await original_send(data)

        conn.send = dropping_send  # type: ignore[method-assign]

        await service._resubscribe_all()  # type: ignore[attr-defined]  # must not raise
        service._connection = conn  # type: ignore[attr-defined]  # restore for a clean close()
        await service.close()
