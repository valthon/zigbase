"""Regression test for cancelling a `subscribe()` while its connect is in
flight (final-review fix wave, SP2).

Before the fix, `RealtimeService._connect_once` set `self._connecting = True`
before `await connector(url)` and only reset it to `False` on the `Exception`
path (or on success) -- never on a `BaseException` such as
`asyncio.CancelledError`. Cancelling the task driving the FIRST `subscribe()`
call while the connector await was still in flight (e.g. an
`asyncio.wait_for` timeout racing a slow connect) therefore left
`_connecting` stuck `True` forever: `_ensure_connected` defers to that flag,
so every LATER `subscribe()` call -- even on an entirely fresh topic --
would silently hang, never opening a new connection. Only `close()` could
unwedge it (by force-failing every pending future), which is not something a
caller expects to need after a routine timeout on an unrelated subscribe.
"""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import Callable

from tests.support.fake_connector import FakeConnectorFactory
from zigbase.auth_store import MemoryAuthStore
from zigbase.realtime import RealtimeService


async def _pump(times: int = 5) -> None:
    for _ in range(times):
        await asyncio.sleep(0)


async def _pump_until(predicate: Callable[[], bool], limit: int = 500) -> None:
    for _ in range(limit):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("condition not met within pump limit")


class TestCancelMidConnect:
    async def test_cancelling_the_first_subscribe_mid_connect_resets_connecting_flag(
        self,
    ) -> None:
        factory = FakeConnectorFactory()
        factory.gate = asyncio.Event()  # park the connector await in flight
        service = RealtimeService("http://api.test", MemoryAuthStore(), connector=factory.connect)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        assert service._connecting is True  # type: ignore[attr-defined]
        assert len(factory.connections) == 0  # connector still parked on the gate

        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task

        assert service._connecting is False  # type: ignore[attr-defined]

        await service.close()

    async def test_a_later_subscribe_connects_fresh_and_completes_after_a_cancelled_first_connect(
        self,
    ) -> None:
        factory = FakeConnectorFactory()
        factory.gate = asyncio.Event()
        service = RealtimeService("http://api.test", MemoryAuthStore(), connector=factory.connect)

        first = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        first.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await first

        # Subsequent connects resolve immediately.
        factory.gate = None
        second = asyncio.create_task(service.subscribe("comments", lambda e: None))
        await _pump_until(lambda: len(factory.connections) == 1)
        assert not second.done()

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "comments"})
        await asyncio.wait_for(second, timeout=1)

        await service.close()
