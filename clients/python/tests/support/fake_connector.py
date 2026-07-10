"""Test doubles for `zigbase.realtime`'s `RealtimeConnection` connector.

Port of clients/dart/test/support/fake_socket.dart (`FakeSocketFactory`/
`FakeConnection`), adapted to asyncio: the Dart version hands the service a
`StreamChannel` over an in-memory controller; here `FakeConnection` queues
inbound (server->client) frames in an `asyncio.Queue` and captures outbound
(client->server) frames directly in `send`.

A `FakeConnectorFactory` hands out a fresh `FakeConnection` on every
`connect` (so reconnect tests can grab the newest one via `.last`).
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterator
from typing import Any


class FakeConnection:
    """A single fake connection.

    - Frames the service under test sends via `send` are JSON-decoded into
      `sent` (and split into `subscribe_frames`/`unsubscribe_frames`).
    - The test pushes a server frame with `push`.
    - The test simulates an unexpected transport drop with `server_close`.
    """

    def __init__(self) -> None:
        self.sent: list[dict[str, Any]] = []
        self._incoming: asyncio.Queue[str | bytes | None] = asyncio.Queue()
        # When set, the NEXT `send` raises this instead of recording the
        # frame, then clears itself back to `None` (one-shot) so a test can
        # fail exactly one send -- e.g. the auth frame -- without derailing
        # every send that follows on the same connection.
        self.send_exception: Exception | None = None

    async def send(self, data: str) -> None:
        if self.send_exception is not None:
            exc, self.send_exception = self.send_exception, None
            raise exc
        self.sent.append(json.loads(data))

    async def recv(self) -> AsyncIterator[str | bytes]:
        while True:
            item = await self._incoming.get()
            if item is None:
                return
            yield item

    async def close(self) -> None:
        await self._incoming.put(None)

    async def push(self, frame: dict[str, Any]) -> None:
        """Deliver a server->client frame."""
        await self._incoming.put(json.dumps(frame))

    async def server_close(self) -> None:
        """Simulate an unexpected transport drop (peer closed the socket)."""
        await self._incoming.put(None)

    @property
    def subscribe_frames(self) -> list[dict[str, Any]]:
        return [f for f in self.sent if f.get("action") == "subscribe"]

    @property
    def unsubscribe_frames(self) -> list[dict[str, Any]]:
        return [f for f in self.sent if f.get("action") == "unsubscribe"]


class FakeConnectorFactory:
    """A connector (`Callable[[str], Awaitable[RealtimeConnection]]`) that
    records every connection it builds."""

    def __init__(self) -> None:
        self.connections: list[FakeConnection] = []
        # Connect attempts that raise ConnectionError before succeeding, for backoff tests.
        self.pending_failures: int = 0
        # When set, `connect` parks on this event before resolving, letting a
        # test interleave work (e.g. close()) while the connect is in flight.
        self.gate: asyncio.Event | None = None
        # Primes the NEXT connection built with a one-shot `send_exception`
        # (see `FakeConnection`), for tests that need the very first send on
        # a freshly-opened connection -- e.g. the on-open auth frame -- to
        # fail. Consumed (reset to `None`) as soon as it's applied.
        self.next_send_exception: Exception | None = None

    async def connect(self, url: str) -> FakeConnection:
        gate = self.gate
        if gate is not None:
            await gate.wait()
        if self.pending_failures > 0:
            self.pending_failures -= 1
            raise ConnectionError("connect failed")
        conn = FakeConnection()
        if self.next_send_exception is not None:
            conn.send_exception, self.next_send_exception = self.next_send_exception, None
        self.connections.append(conn)
        return conn

    @property
    def last(self) -> FakeConnection:
        if not self.connections:
            raise RuntimeError("no FakeConnection constructed yet")
        return self.connections[-1]


__all__ = ["FakeConnection", "FakeConnectorFactory"]
