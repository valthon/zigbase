"""Tests for `RealtimeService.stream()` (SP2 Task 5).

Port of the `stream()` coverage in clients/dart/test/realtime_test.dart's
`RealtimeService.stream`/`RealtimeService.close` groups, adapted to asyncio
(see test_realtime_subscribe.py's module docstring for the `_pump()`
rationale). `stream()` is a thin async-generator wrapper over `subscribe()`,
so each `async for` step is driven one at a time here via the builtin
`anext()`, run inside a `Task` so it can be pushed forward by frames arriving
on the fake connection concurrently.

One deliberate divergence from Dart, called out in `stream()`'s docstring: a
cancelled/`aclose()`d Python task truly interrupts the `await` inside
`subscribe()` (Python cancellation is preemptive), unlike Dart's cooperative
`Stream.cancel()`, which lets the pending completer keep waiting until the
real ack/reject arrives before tearing down. This SDK therefore unsubscribes
(and sends the wire `unsubscribe` frame, if it was the last variant)
IMMEDIATELY on cancellation, rather than waiting for a now-moot ack.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable

import pytest

from tests.support.fake_connector import FakeConnectorFactory
from zigbase.auth_store import MemoryAuthStore
from zigbase.errors import ZigbaseError
from zigbase.realtime import RealtimeService


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


def _other_pending_tasks(*exclude: asyncio.Task[object]) -> list[asyncio.Task[object]]:
    current = asyncio.current_task()
    skip = {current, *exclude}
    return [t for t in asyncio.all_tasks() if t not in skip and not t.done()]


class TestStreamReceivesEvents:
    async def test_async_for_step_receives_pushed_events(self) -> None:
        service, factory = make_service()
        agen = service.stream("posts")

        task = asyncio.create_task(anext(agen))
        await _pump()
        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "create", "record": {"id": "p1"}}
        )
        event = await asyncio.wait_for(task, timeout=1)
        assert event.topic == "posts"
        assert event.action == "create"
        assert event.record == {"id": "p1"}

        task2 = asyncio.create_task(anext(agen))
        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "update", "record": {"id": "p2"}}
        )
        event2 = await asyncio.wait_for(task2, timeout=1)
        assert event2.record == {"id": "p2"}

        await agen.aclose()
        await service.close()


class TestStreamAclose:
    async def test_aclose_sends_unsubscribe_when_last_variant(self) -> None:
        service, factory = make_service()
        agen = service.stream("posts")

        task = asyncio.create_task(anext(agen))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "create", "record": {"id": "p1"}}
        )
        await asyncio.wait_for(task, timeout=1)

        await agen.aclose()
        await _pump()
        assert factory.last.unsubscribe_frames == [{"action": "unsubscribe", "topic": "posts"}]
        await service.close()


class TestStreamCancelBeforeAck:
    async def test_cancel_before_ack_tears_down_cleanly_no_pending_tasks(self) -> None:
        service, factory = make_service()
        agen = service.stream("posts")

        task = asyncio.create_task(anext(agen))
        await _pump()
        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]
        # The receive loop is a legitimate background task for the whole
        # (still-open) connection, not something a stream()'s cancellation
        # cleanup spawns -- snapshot it (excluding `task` itself, which is
        # about to be cancelled on purpose) so the assertions below only
        # catch a NEW leaked task.
        baseline = set(_other_pending_tasks(task))

        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

        # The cancelled stream's own task already ran its cleanup inline
        # (inside `task`, awaited above), so the unsubscribe frame is sent
        # immediately -- no later ack needed to trigger teardown, and no
        # background task was spawned to do it.
        assert factory.last.unsubscribe_frames == [{"action": "unsubscribe", "topic": "posts"}]
        assert set(_other_pending_tasks()) == baseline

        # A late ack for the already-torn-down subscription must be a no-op:
        # no callback is registered to receive it, nothing raises.
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await _pump()
        assert set(_other_pending_tasks()) == baseline
        await service.close()

    async def test_cancel_before_a_rejected_subscribe_raises_no_unhandled_error(self) -> None:
        errors: list[str] = []
        service, factory = make_service(on_error=errors.append)
        agen = service.stream("private")

        task = asyncio.create_task(anext(agen))
        await _pump()
        baseline = set(_other_pending_tasks(task))

        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

        # The pending subscribe now rejects for the already-cancelled
        # stream: must not raise anywhere unhandled, just surfaced via
        # on_error (this exercises decode_frame's rejection path).
        await factory.last.push({"type": "error", "message": "anonymous not allowed"})
        await _pump()
        assert "anonymous not allowed" in errors
        assert set(_other_pending_tasks()) == baseline
        await service.close()


class TestStreamRejectedSubscribe:
    async def test_rejected_subscribe_raises_zigbase_error_from_the_iterator(self) -> None:
        service, factory = make_service()
        agen = service.stream("private")

        task = asyncio.create_task(anext(agen))
        await _pump()

        await factory.last.push({"type": "error", "message": "anonymous not allowed"})
        with pytest.raises(ZigbaseError) as exc_info:
            await asyncio.wait_for(task, timeout=1)
        assert exc_info.value.message == "anonymous not allowed"
        await service.close()


class TestStreamClose:
    async def test_close_ends_an_already_acked_stream_without_raising(self) -> None:
        service, factory = make_service()
        agen = service.stream("posts")

        task = asyncio.create_task(anext(agen))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "create", "record": {"id": "p1"}}
        )
        event = await asyncio.wait_for(task, timeout=1)
        assert event.record == {"id": "p1"}

        task2 = asyncio.create_task(anext(agen))
        await _pump()
        await service.close()

        with pytest.raises(StopAsyncIteration):
            await asyncio.wait_for(task2, timeout=1)

    async def test_close_does_not_hang_on_a_never_listened_stream(self) -> None:
        service, _factory = make_service()
        service.stream("posts")  # minted but never iterated -- no callback registered yet

        await asyncio.wait_for(service.close(), timeout=1)


class TestStreamAfterClose:
    async def test_stream_after_close_raises_at_mint_time(self) -> None:
        service, _factory = make_service()
        await service.close()

        with pytest.raises(ZigbaseError):
            service.stream("posts")
