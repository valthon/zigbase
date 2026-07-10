"""Tests for Task 6: `AsyncZigBase.realtime`/`ZigBase.realtime` wiring and the
default `websockets`-backed connector factory in `zigbase.realtime`.

Uses local fake connections shaped like `tests/support/fake_connector.py`'s
`FakeConnection` (not that module directly -- this file additionally needs a
`closed` flag to observe `aclose()` tearing the connection down) rather than
a real WebSocket. `websockets` lives behind the `zigbase[realtime]` extra and
is not assumed to be installed here; `_default_connector` itself is only
exercised on its `ImportError` path (via `sys.modules` poisoning) -- see
Task 7 for a real end-to-end `websockets` test.
"""

from __future__ import annotations

import asyncio
import json
import subprocess
import sys
from collections.abc import AsyncIterator
from typing import Any

import pytest

from zigbase import RealtimeEvent, TopicMessage
from zigbase.client import AsyncZigBase, ZigBase
from zigbase.realtime import RealtimeService, _default_connector


async def _pump(times: int = 5) -> None:
    for _ in range(times):
        await asyncio.sleep(0)


class _FakeConnection:
    def __init__(self) -> None:
        self.sent: list[dict[str, Any]] = []
        self.closed = False
        self._incoming: asyncio.Queue[str | bytes | None] = asyncio.Queue()

    async def send(self, data: str) -> None:
        self.sent.append(json.loads(data))

    async def recv(self) -> AsyncIterator[str | bytes]:
        while True:
            item = await self._incoming.get()
            if item is None:
                return
            yield item

    async def close(self) -> None:
        self.closed = True
        await self._incoming.put(None)

    async def push(self, frame: dict[str, Any]) -> None:
        await self._incoming.put(json.dumps(frame))


class _FakeConnectorFactory:
    def __init__(self) -> None:
        self.connections: list[_FakeConnection] = []

    async def connect(self, url: str) -> _FakeConnection:
        conn = _FakeConnection()
        self.connections.append(conn)
        return conn

    @property
    def last(self) -> _FakeConnection:
        return self.connections[-1]


def make_client(factory: _FakeConnectorFactory) -> AsyncZigBase:
    return AsyncZigBase("http://api.test", realtime_connector=factory.connect)


class TestRealtimeProperty:
    async def test_returns_same_instance_on_every_access(self) -> None:
        zb = make_client(_FakeConnectorFactory())
        first = zb.realtime
        second = zb.realtime
        assert first is second
        assert isinstance(first, RealtimeService)
        await zb.aclose()

    async def test_injected_connector_used_end_to_end(self) -> None:
        factory = _FakeConnectorFactory()
        zb = make_client(factory)

        events: list[RealtimeEvent] = []
        task = asyncio.create_task(zb.realtime.subscribe("posts", events.append))
        await _pump()

        assert len(factory.connections) == 1
        assert factory.last.sent == [{"action": "subscribe", "topic": "posts"}]

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        unsub = await task
        assert callable(unsub)

        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "create", "record": {"id": "1"}}
        )
        await _pump()
        assert len(events) == 1
        assert events[0].record == {"id": "1"}

        await zb.aclose()

    async def test_aclose_closes_the_realtime_service(self) -> None:
        factory = _FakeConnectorFactory()
        zb = make_client(factory)
        task = asyncio.create_task(zb.realtime.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await zb.aclose()
        assert factory.last.closed is True

    async def test_aclose_without_ever_touching_realtime_is_a_noop(self) -> None:
        zb = AsyncZigBase("http://api.test")
        await zb.aclose()  # must not raise / must not try to build a connector

    async def test_with_account_sibling_gets_its_own_realtime_service(self) -> None:
        factory = _FakeConnectorFactory()
        zb = make_client(factory)
        sibling = zb.with_account("acct1")
        try:
            assert sibling.realtime is not zb.realtime
            assert isinstance(sibling.realtime, RealtimeService)
        finally:
            await zb.aclose()
            await sibling.aclose()


class TestSyncZigBaseRealtime:
    def test_raises_naming_async_zig_base(self) -> None:
        zb = ZigBase("http://api.test")
        try:
            with pytest.raises(RuntimeError, match="AsyncZigBase"):
                _ = zb.realtime
        finally:
            zb.close()


class TestDefaultConnector:
    async def test_import_error_names_the_realtime_extra(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # `sys.modules[name] = None` makes the next `import <name>` raise
        # ImportError regardless of whether the real package is actually
        # installed -- simulates a `zigbase[realtime]`-less install without
        # depending on this dev environment's actual package set.
        monkeypatch.setitem(sys.modules, "websockets", None)
        with pytest.raises(ImportError, match=r"zigbase\[realtime\]"):
            await _default_connector("ws://api.test/api/realtime")


def test_realtime_event_and_topic_message_exported_from_top_level_package() -> None:
    assert RealtimeEvent(topic="t", action="create", record={}).topic == "t"
    assert TopicMessage(topic="t", kind="signal").topic == "t"


class TestOptionalDependencyContract:
    def test_import_zigbase_never_imports_websockets(self) -> None:
        """`websockets` (the `zigbase[realtime]` extra) must stay an optional,
        lazily-imported dependency -- `_default_connector` only imports it
        inside the coroutine body, on the first actual connect attempt (see
        its docstring). A module-scope `import websockets` anywhere reachable
        from `import zigbase` would make it a hard dependency in practice, so
        this locks the contract in: a fresh interpreter (subprocess, so no
        earlier test in this same process can have already pulled
        `websockets` into `sys.modules`) that only does `import zigbase` must
        never have `websockets` in `sys.modules` afterward -- regardless of
        whether `websockets` even happens to be installed in this env.
        """
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                "import zigbase, sys; sys.exit(1 if 'websockets' in sys.modules else 0)",
            ],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"'websockets' was imported by a bare `import zigbase`\n"
            f"stdout={result.stdout!r} stderr={result.stderr!r}"
        )
