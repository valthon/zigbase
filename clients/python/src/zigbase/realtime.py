"""Realtime (WebSocket) frame types, codec, and the multiplexing service.

Port of clients/typescript/src/realtime.ts and clients/dart/lib/src/realtime.dart.
This module carries the wire-level pieces (frame dataclasses, the encode/decode
codec, and the `RealtimeConnection` transport contract) and `RealtimeService`,
which multiplexes subscribe/unsubscribe over one connection with ack-gating,
the auth lifecycle (see below), and reconnect with bounded exponential backoff
(`_schedule_reconnect`/`_reconnect`): an unexpected drop (not a user `close()`)
re-opens the connection after `min(10.0, 0.25 * 2**attempts)` seconds (module-
level `_asleep`, monkeypatchable in tests), re-authenticates, and resends every
surviving subscription's frame.

The service opens a single WebSocket to `<baseUrl>/api/realtime` (`http`/`https`
mapped to `ws`/`wss`) and multiplexes every collection- and topic-subscription
over it. The wire protocol is authoritative in `src/realtime/` on the server:

 - Uplink: `{"action":"auth","token":…}`,
   `{"action":"subscribe","topic":…,"filter"?:…}` (the `filter` key is
   omitted -- not sent as `null` -- when no filter is given),
   `{"action":"unsubscribe","topic":…}`.
 - Downlink, dispatched on `type`: `connect` (stores `clientId`), `auth`
   (`status` `ok`|`error` gates the resubscribe), `ack` (resolves pending
   subscribes for the topic), `event` (`topic`/`action`/`record` -> record
   callbacks), `signal`/`message` (topic callbacks), `error` (rejects pending
   subscribes and calls `onError`).

Auth lifecycle (port of `sendAuth`/`sendAuthFrame` in the TS SDK): on open,
a present `auth_store.token` is sent FIRST and every resubscribe is gated on
that `auth` reply SETTLING -- whether its `status` is `ok` or `error` (a
failed auth is surfaced via `on_error`, never by blocking or failing the
resubscribe) -- so a subscription with a `@public` view rule still resubscribes
even when auth itself fails; anonymous opens resubscribe at once. An
`auth_store.on_change` listener registered at construction re-sends
`encode_auth(token or "")` whenever the token changes while the socket is
open (an empty token de-auths the connection server-side on logout). Unlike
the TS/Dart ports -- which swallow every auth failure silently -- this SDK
surfaces every auth failure via `on_error`, never by rejecting a subscribe
or caller future.

Known limitations (documented, not fixed):
 - A still-pending (unacked) subscribe whose entry is removed while another
   still-pending subscribe to the same topic/filter is also awaiting an ack
   never settles -- nothing acks or rejects it once the entry is gone. This
   happens whenever a caller `unsubscribe()`s before the server has acked:
   during a reconnect backoff (the entry vanishes before the eventual
   reconnect can resend its frame) is the common case, but it equally happens
   on an otherwise-healthy, already-open connection if one caller's
   `unsubscribe()` drops the entry while a second caller's concurrent
   `subscribe()` to that same topic/filter is still awaiting its ack.
   Inherited from the TS/Dart SDKs. (An unexpected drop *without* that
   removal is fine: the subscribe's own `await` simply stays pending until
   the reconnect re-sends the frame and a fresh ack arrives.)
 - Cancelling the `subscribe()`/`subscribe_topic()` coroutine (e.g. via
   `asyncio.wait_for` timing out, or the enclosing task being cancelled)
   while it's still awaiting its ack does NOT undo the callback registration:
   the callback was already added to the `_Subscription` before the await, so
   it stays registered -- and will start receiving events once the ack
   eventually arrives -- until the caller explicitly calls `unsubscribe()`/
   `unsubscribe_topic()`.
 - Callback dispatch is serialized: the receive loop `await`s each callback
   in turn before decoding the next frame (mirroring the TS/JS single-threaded
   event-loop model). An awaited coroutine callback that itself calls
   `subscribe()`/`subscribe_topic()` for a topic that hasn't been acked yet
   deadlocks -- the `ack` frame that would resolve it can only be processed
   by this same receive loop, which is blocked awaiting the callback.
"""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import json
import logging
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, Final, Protocol

from zigbase.auth_store import AuthStore
from zigbase.errors import ZigbaseError

if TYPE_CHECKING:
    from websockets.asyncio.client import ClientConnection


class RealtimeConnection(Protocol):
    """The transport contract a connector hands back per connection attempt.

    Asyncio-flavored analogue of the TS `WebSocket` glue / Dart
    `StreamChannel`: `send` writes one uplink frame, `recv` yields downlink
    frames as they arrive, and `close` tears the connection down.
    """

    async def send(self, data: str) -> None: ...

    def recv(self) -> AsyncIterator[str | bytes]: ...

    async def close(self) -> None: ...


class _WebsocketsConnection:
    """Adapts a `websockets` `ClientConnection` to `RealtimeConnection`."""

    def __init__(self, connection: ClientConnection) -> None:
        self._connection = connection

    async def send(self, data: str) -> None:
        await self._connection.send(data)

    async def recv(self) -> AsyncIterator[str | bytes]:
        async for message in self._connection:
            yield message

    async def close(self) -> None:
        await self._connection.close()


async def _default_connector(url: str) -> RealtimeConnection:
    """The default connector used by `AsyncZigBase.realtime` when the client
    was built without an explicit `realtime_connector`.

    Backed by the `websockets` package -- the `zigbase[realtime]` extra,
    not a hard dependency of this SDK -- imported lazily here (never at
    module import time) so importing `zigbase` never requires it; a missing
    install raises a clear `ImportError` naming the extra instead of a bare
    `ModuleNotFoundError`. Connects with no extra headers and no Origin
    override.
    """
    try:
        import websockets
    except ImportError as exc:
        raise ImportError(
            "realtime support requires the 'websockets' package; install it "
            "with: pip install 'zigbase[realtime]'"
        ) from exc
    connection = await websockets.connect(url)
    return _WebsocketsConnection(connection)


@dataclass(frozen=True)
class RealtimeEvent:
    """A record mutation delivered on a collection topic.

    `action` is one of `create`, `update`, `delete` (a delete carries an
    `{"id": ...}`-only `record`).
    """

    topic: str
    action: str
    record: dict[str, Any]


@dataclass(frozen=True)
class TopicMessage:
    """A frame delivered on a custom (non-collection) topic.

    `kind` is `signal` (a re-fetch hint, `data` is `None`) or `message` (a
    payload-carrying broadcast via `ctx.realtime().broadcast`).
    """

    topic: str
    kind: str
    data: Any | None = None


def encode_auth(token: str) -> str:
    """Encode an `auth` uplink frame. The empty string de-auths the connection."""
    return json.dumps({"action": "auth", "token": token})


def encode_subscribe(topic: str, filter: str | None) -> str:
    """Encode a `subscribe` uplink frame.

    The `filter` key is omitted entirely when `filter` is `None` -- it is
    never sent as a JSON `null`.
    """
    frame: dict[str, Any] = {"action": "subscribe", "topic": topic}
    if filter is not None:
        frame["filter"] = filter
    return json.dumps(frame)


def encode_unsubscribe(topic: str) -> str:
    """Encode an `unsubscribe` uplink frame."""
    return json.dumps({"action": "unsubscribe", "topic": topic})


def decode_frame(raw: str | bytes) -> dict[str, Any] | None:
    """Decode one downlink frame.

    Returns the parsed object for any JSON *object*; returns `None` (drop)
    for malformed JSON, non-UTF-8 bytes, and any JSON value that isn't an
    object (array, number, string, bool, null). Dispatch on the frame's
    `type`/validation of its shape happens in the service, not here.
    """
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError:
            return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(parsed, dict):
        return None
    return parsed


def realtime_url(base_url: str) -> str:
    """Map an http(s) base URL to its `ws(s)://.../api/realtime` endpoint.

    `http` -> `ws`, `https` -> `wss` (a single `http` -> `ws` prefix swap
    handles both, since `https` already carries the trailing `s`); all
    trailing slashes are stripped before appending the path.
    """
    url = base_url
    if url.startswith("http"):
        url = "ws" + url[4:]
    url = url.rstrip("/")
    return f"{url}/api/realtime"


RecordCallback = Callable[[RealtimeEvent], Any]
TopicCallback = Callable[[TopicMessage], Any]
Unsubscribe = Callable[[], Awaitable[None]]

_CLOSED_MESSAGE = "realtime client closed"


class _StreamClosed:
    """Sentinel pushed into a `stream()`'s internal queue by `close()` so a
    still-iterating consumer ends cleanly (`StopAsyncIteration`) instead of
    hanging forever on a queue nothing will ever fill again."""


_STREAM_CLOSED: Final = _StreamClosed()

# Reconnect backoff sleep, indirected through a module-level name so tests can
# monkeypatch `zigbase.realtime._asleep` to collapse (or observe) the delay
# instead of waiting on the wall clock.
_asleep = asyncio.sleep

_RECONNECT_MIN_DELAY = 0.25
_RECONNECT_MAX_DELAY = 10.0
# 2**attempts is computed as an exact Python int, which can grow far beyond
# what `float()` can represent (OverflowError) after enough consecutive
# failures on a long-lived connection; attempts are already capped well past
# the point the delay saturates at `_RECONNECT_MAX_DELAY`, so clamping the
# exponent itself is safe and side-steps that overflow entirely.
_RECONNECT_MAX_SHIFT = 30


def _default_on_error(message: str) -> None:
    logging.getLogger("zigbase.realtime").warning(message)


def _sub_key(topic: str, filter: str | None) -> str:
    # Record- and topic-subscription keys share one dict, so their key spaces
    # must be structurally disjoint: the `r:`/`t:` prefixes guarantee no
    # record key (however adversarial the topic/filter text) can collide with
    # a topic key -- see `_topic_key` and the regression test in
    # test_realtime_subscribe.py.
    return f"r:{topic}" if filter is None else f"r:{topic} {filter}"


def _topic_key(topic: str) -> str:
    return f"t:{topic}"


@dataclass
class _Subscription:
    topic: str
    kind: str  # "records" | "topic"
    filter: str | None = None
    callbacks: set[RecordCallback] = field(default_factory=set)
    topic_callbacks: set[TopicCallback] = field(default_factory=set)
    # Futures waiting on the `ack` of the in-flight subscribe frame.
    pending: list[asyncio.Future[None]] = field(default_factory=list)
    acked: bool = False
    # A subscribe frame is on the wire awaiting its ack -- concurrent
    # subscribers must join `pending` without sending a duplicate frame.
    inflight: bool = False


class RealtimeService:
    """Multiplexes realtime subscriptions over a single WebSocket connection.

    Port of `clients/typescript/src/realtime.ts` / `clients/dart/lib/src/realtime.dart`'s
    `RealtimeService`: connect-on-first-subscribe, ack-gated subscribe/unsubscribe,
    frame dispatch, the auth lifecycle -- an auth-gated resubscribe on open and
    re-auth on every `auth_store` token change while connected -- and reconnect
    with bounded exponential backoff on an unexpected drop (`_schedule_reconnect`/
    `_reconnect`): auth-first, then every surviving subscription is marked unacked
    and its frame re-sent. `stream()` is an async-generator convenience wrapper
    over `subscribe()` (see its docstring for the cancel/close semantics).
    See `client.py`'s `AsyncZigBase.realtime` for how this is wired into the
    client facade, and `_default_connector` above for the default
    `websockets`-backed connector used when none is injected.
    """

    def __init__(
        self,
        base_url: str,
        auth_store: AuthStore,
        *,
        connector: Callable[[str], Awaitable[RealtimeConnection]] | None = None,
        on_error: Callable[[str], None] | None = None,
    ) -> None:
        self._base_url = base_url
        self._auth_store = auth_store
        self._connector = connector
        self._on_error = on_error or _default_on_error

        self._subscriptions: dict[str, _Subscription] = {}
        # Live `stream()` queues (not yet cancelled/exhausted), so `close()`
        # can wake each one with `_STREAM_CLOSED` instead of leaving it
        # hanging on a queue nothing will ever fill again.
        self._stream_queues: set[asyncio.Queue[RealtimeEvent | _StreamClosed]] = set()
        self._connection: RealtimeConnection | None = None
        self._receive_task: asyncio.Task[None] | None = None
        self._opened = False
        self._connecting = False
        self._reconnect_pending = False
        self._reconnect_attempts = 0
        self._reconnect_task: asyncio.Task[None] | None = None
        self._closed_by_user = False
        self._client_id: str | None = None

        # Auth lifecycle. `_auth_ack` is the in-flight auth response future
        # (reused across back-to-back sends, see `_send_auth_frame`); `_loop`
        # is captured on the first real connect attempt (always inside a
        # running coroutine) so the sync `auth_store.on_change` listener --
        # which can fire from arbitrary, possibly non-async/non-loop-thread
        # code via `auth_store.save()`/`clear()` -- has a safe, thread-safe
        # way to wake the loop. `_auth_tasks` holds the fire-and-forget
        # re-auth sends spawned off that listener so they (a) aren't
        # garbage-collected mid-flight (a bare `asyncio.create_task` with no
        # surviving reference is a documented asyncio pitfall) and (b) can be
        # cancelled cleanly by `close()`.
        self._auth_ack: asyncio.Future[None] | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._auth_tasks: set[asyncio.Task[None]] = set()
        self._auth_unsub = auth_store.on_change(self._on_auth_store_change)

    @property
    def client_id(self) -> str | None:
        """The server-assigned connection id from the last `connect` frame,
        or `None` before the socket has connected."""
        return self._client_id

    # ---- public API ---------------------------------------------------------

    async def subscribe(
        self, topic: str, callback: RecordCallback, *, filter: str | None = None
    ) -> Unsubscribe:
        self._raise_if_closed()
        key = _sub_key(topic, filter)
        sub = self._subscriptions.get(key)
        if sub is None:
            sub = _Subscription(topic=topic, kind="records", filter=filter)
            self._subscriptions[key] = sub
        sub.callbacks.add(callback)

        async def _unsubscribe() -> None:
            await self.unsubscribe(topic, callback, filter=filter)

        await self._ensure_connected()
        self._raise_if_closed()

        if sub.acked:
            # Already live -- nothing more to send.
            return _unsubscribe

        fut: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        sub.pending.append(fut)
        # If the socket is already open and no subscribe frame is awaiting its
        # ack, send one now; concurrent callers just join `pending`.
        if self._opened and not sub.inflight:
            await self._send_subscribe(sub)
        await fut
        return _unsubscribe

    async def unsubscribe(
        self,
        topic: str,
        callback: RecordCallback | None = None,
        filter: str | None = None,
    ) -> None:
        """Remove a record callback.

        When `filter` is omitted, `callback` is removed from EVERY variant of
        `topic` regardless of filter (the public path -- a filtered
        subscription's key would never match the unfiltered key, so keying
        alone would silently leak it). When `filter` is given, only that exact
        `(topic, filter)` variant is targeted. A single `unsubscribe` frame is
        sent once `topic` has no live variants left. Idempotent for an unknown
        topic/callback.
        """
        if filter is not None:
            key = _sub_key(topic, filter)
            targets = [self._subscriptions[key]] if key in self._subscriptions else []
        else:
            targets = [
                s for s in self._subscriptions.values() if s.kind == "records" and s.topic == topic
            ]

        removed = False
        for sub in targets:
            if callback is not None:
                sub.callbacks.discard(callback)
            else:
                sub.callbacks.clear()
            if not sub.callbacks:
                del self._subscriptions[_sub_key(sub.topic, sub.filter)]
                removed = True

        if removed and self._opened and self._connection is not None and not self._has_topic(topic):
            await self._connection.send(encode_unsubscribe(topic))

    async def subscribe_topic(self, topic: str, callback: TopicCallback) -> Unsubscribe:
        """Subscribe to a custom (non-collection) topic: `signal`/`message`
        frames are delivered as `TopicMessage`s. Same ack/dedup machinery as
        `subscribe`."""
        self._raise_if_closed()
        key = _topic_key(topic)
        sub = self._subscriptions.get(key)
        if sub is None:
            sub = _Subscription(topic=topic, kind="topic")
            self._subscriptions[key] = sub
        sub.topic_callbacks.add(callback)

        async def _unsubscribe() -> None:
            await self.unsubscribe_topic(topic, callback)

        await self._ensure_connected()
        self._raise_if_closed()

        if sub.acked:
            return _unsubscribe

        fut: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        sub.pending.append(fut)
        if self._opened and not sub.inflight:
            await self._send_subscribe(sub)
        await fut
        return _unsubscribe

    async def unsubscribe_topic(self, topic: str, callback: TopicCallback | None = None) -> None:
        """Remove a topic callback (all of them when `callback` is omitted);
        sends one `unsubscribe` frame once the topic has no live variants
        left. Idempotent for an unknown topic/callback."""
        key = _topic_key(topic)
        sub = self._subscriptions.get(key)
        if sub is None:
            return
        if callback is not None:
            sub.topic_callbacks.discard(callback)
        else:
            sub.topic_callbacks.clear()
        if not sub.topic_callbacks:
            del self._subscriptions[key]
            if self._opened and self._connection is not None and not self._has_topic(topic):
                await self._connection.send(encode_unsubscribe(topic))

    def stream(self, topic: str, *, filter: str | None = None) -> AsyncIterator[RealtimeEvent]:
        """A convenience `AsyncIterator` of `RealtimeEvent`s for `topic`.

        Subscribes on the FIRST iteration -- not at call time: this method
        itself is synchronous (only the `_raise_if_closed` mint-time check
        below runs eagerly) and returns an async generator whose body,
        including the underlying `subscribe()` call, doesn't run until the
        caller's first `async for` step (`__anext__`/`anext()`).

        Ending iteration -- `break` followed by an explicit `aclose()`
        (`async for` alone does NOT close a generator on `break`; use
        `contextlib.aclosing()` or call `aclose()` yourself for deterministic
        cleanup, same as any Python async generator), or the consuming task
        being cancelled -- always unsubscribes, including when the teardown
        lands while the initial subscribe is still awaiting its ack. Unlike
        Dart's `stream()` (which lets a pending completer keep waiting after
        `cancel()`, since Dart's `Stream.cancel()` is cooperative, not
        preemptive), a cancelled/`aclose()`d Python task truly interrupts the
        `await` inside `subscribe()` -- so this unsubscribes immediately
        rather than waiting for a (now-moot) ack, and separately removes the
        callback that `subscribe()`'s documented cancellation caveat (see the
        module docstring) would otherwise leave registered. A subscribe
        rejected by the server (an `error` frame) raises the `ZigbaseError`
        out of the iterator at the point of iteration.

        `close()` on the service ends every live stream with a clean
        `StopAsyncIteration` (matching Dart's close-completes-controllers
        behavior), never an exception.

        The internal queue between the subscribe callback and the consumer
        is unbounded -- matching Dart's broadcast-`StreamController`
        semantics -- so a consumer that falls behind the server just grows
        memory rather than applying backpressure; the server already
        disconnects slow consumers, so this is accepted, not an oversight.

        Raises a `ZigbaseError` immediately (at mint time, not on first
        iteration) once the service has been `close()`d.
        """
        self._raise_if_closed()
        return self._stream_events(topic, filter)

    async def _stream_events(self, topic: str, filter: str | None) -> AsyncIterator[RealtimeEvent]:
        queue: asyncio.Queue[RealtimeEvent | _StreamClosed] = asyncio.Queue()
        self._stream_queues.add(queue)
        callback: RecordCallback = queue.put_nowait
        try:
            try:
                await self.subscribe(topic, callback, filter=filter)
            except ZigbaseError:
                if self._closed_by_user:
                    # A racing close() failed the pending ack -- end quietly
                    # rather than raising past a caller who already asked to
                    # shut everything down.
                    return
                raise
            while True:
                item = await queue.get()
                if isinstance(item, _StreamClosed):
                    return
                yield item
        finally:
            self._stream_queues.discard(queue)
            # Idempotent and safe in every exit path: a normal/close()d/
            # rejected subscribe has already removed (or never registered)
            # `callback`, so this is a no-op; a cancelled/aclose()d subscribe
            # still mid-ack is exactly the case that needs this call to strip
            # the callback the cancellation caveat would otherwise leave
            # registered.
            await self.unsubscribe(topic, callback, filter=filter)

    async def close(self) -> None:
        """Tear down the socket, stop reconnecting, and fail any subscribe
        still awaiting its ack so no caller is left hanging."""
        self._closed_by_user = True
        self._auth_unsub()
        # Captured before cancelling the receive task: that task's own
        # `finally` clause (see `_receive_loop`) nulls `self._connection` as
        # part of unwinding, so reading `self._connection` only AFTER
        # `await task` would find it already `None` and skip closing the
        # transport entirely.
        connection = self._connection
        task = self._receive_task
        reconnect_task = self._reconnect_task
        auth_tasks = list(self._auth_tasks)
        self._fail_pending(_CLOSED_MESSAGE)
        # Unblocks an inline `await ack` still in flight inside the on-open
        # auth send (not tracked in `_auth_tasks`, which only holds the
        # fire-and-forget re-auth sends) so that caller's `subscribe()`
        # doesn't hang on a connection that will never respond again.
        self._fail_auth_ack(_CLOSED_MESSAGE)
        self._subscriptions.clear()
        # Wake every live stream() so its `await queue.get()` resolves to a
        # clean end (StopAsyncIteration) instead of hanging forever -- not
        # awaited, matching `subscribe()`'s pending futures above: the
        # consumer's own task drives the generator's actual cleanup/unsub
        # whenever it next gets a turn, which may be well after close()
        # returns (a stream that was never listened to would otherwise have
        # nothing to drive it at all).
        for queue in self._stream_queues:
            queue.put_nowait(_STREAM_CLOSED)
        self._stream_queues.clear()

        # Cancel a reconnect sleeping out its backoff BEFORE it can act on a
        # stale `_closed_by_user` read race -- it already re-checks the flag
        # after waking, but cancelling outright also stops it from consuming
        # the rest of a (possibly very long, real) backoff window for nothing.
        if reconnect_task is not None:
            reconnect_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await reconnect_task

        for auth_task in auth_tasks:
            auth_task.cancel()
        for auth_task in auth_tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await auth_task

        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

        self._connection = None
        self._receive_task = None
        self._reconnect_task = None
        self._reconnect_pending = False
        self._opened = False
        self._connecting = False
        if connection is not None:
            await connection.close()

    # ---- connection lifecycle ------------------------------------------------

    def _has_topic(self, topic: str) -> bool:
        return any(s.topic == topic for s in self._subscriptions.values())

    def _raise_if_closed(self) -> None:
        if self._closed_by_user:
            raise ZigbaseError(status=0, message=_CLOSED_MESSAGE, url="")

    async def _ensure_connected(self) -> None:
        # Defer to an in-flight connect OR a scheduled reconnect that is
        # sleeping out its backoff -- during that window a fresh subscribe
        # here must not open a second, competing socket.
        if self._connection is not None or self._connecting or self._reconnect_pending:
            return
        if self._connector is None:
            raise ZigbaseError(status=0, message="realtime connector not configured", url="")
        await self._connect_once()

    async def _connect_once(self) -> None:
        """Attempt exactly one connect.

        Mirrors the TS/Dart `connect()`'s fire-and-forget contract: a
        connector failure here is NEVER raised to a `subscribe()` caller
        racing this attempt (see `_ensure_connected`) -- it's surfaced via
        `on_error` and a reconnect is scheduled instead, so the caller's
        pending future simply stays pending until a later attempt succeeds
        and resends its frame. Propagating the exception here would leave
        that caller's already-registered callback orphaned: raising past it
        while the subscription entry survives so a later reconnect can still
        resubscribe it silently -- a state the caller has no reason to
        expect after being told the call failed.

        That fire-and-forget handling is deliberately scoped to `Exception`
        only: a `CancelledError` reaching here (the subscribing task itself
        being cancelled, e.g. via `asyncio.wait_for` timing out, while
        `connector(url)` is still in flight) is a non-`Exception`
        `BaseException` and is never caught by the `except Exception` below,
        so it propagates out of this method -- and out of the awaiting
        `subscribe()` call -- as normal asyncio cancellation. The `finally`
        still runs first, so `_connecting` is always reset regardless of
        which way this method exits.
        """
        # `_ensure_connected` -- the only caller that reaches here for a
        # fresh connect -- already raised if `_connector` were None; `_reconnect`
        # -- the only other caller -- only runs after that first successful
        # check. Asserted (rather than re-raised) since mypy can't narrow an
        # instance attribute across the method boundary on its own.
        connector = self._connector
        assert connector is not None
        self._loop = asyncio.get_running_loop()
        self._connecting = True
        self._opened = False
        url = realtime_url(self._base_url)
        try:
            try:
                connection = await connector(url)
            except Exception as exc:
                self._on_error(str(exc))
                self._schedule_reconnect()
                return
        finally:
            # Reset unconditionally, including when the connector await is
            # interrupted by cancellation (a non-`Exception` `BaseException`,
            # not caught above): a later subscribe defers to `_connecting`
            # via `_ensure_connected` and must never find it stuck `True`, or
            # every subscribe after a cancelled connect would hang forever.
            self._connecting = False

        if self._closed_by_user:
            # close() ran while the connect was in flight: tear the late
            # connection down rather than resurrecting the service.
            await connection.close()
            return

        self._connection = connection
        self._opened = True
        self._reconnect_attempts = 0
        self._receive_task = asyncio.create_task(self._receive_loop(connection))
        await self._on_open()

    async def _on_open(self) -> None:
        # A present token is sent and awaited BEFORE resubscribing, so the
        # server has applied the identity before evaluating subscription
        # rules; anonymous opens skip straight to resubscribing. An auth
        # failure never blocks this: `_send_auth_frame` swallows it into
        # `on_error` and returns normally either way.
        token = self._auth_store.token
        if token:
            await self._send_auth_frame(token)
        await self._resubscribe_all()

    async def _resubscribe_all(self) -> None:
        # The connection may already be gone by the time this runs -- e.g. a
        # drop arrived while `_on_open` was still awaiting the auth ack (see
        # `_receive_loop`'s finally, which fails that ack so this always gets
        # reached rather than hanging), or while THIS loop's own sends were
        # still in flight (`_send_subscribe` guards that per-iteration).
        # Nothing to (re)send in that case; each subscription's own pending
        # future stays pending until the next reconnect resends its frame.
        if self._connection is None:
            return
        for sub in list(self._subscriptions.values()):
            sub.acked = False
            await self._send_subscribe(sub)

    def _on_auth_store_change(self, token: str | None, record: dict[str, Any] | None) -> None:
        """`auth_store` listener, registered at construction.

        `save()`/`clear()` call listeners synchronously and from arbitrary
        code -- not necessarily the loop's thread, and not necessarily from
        inside a running coroutine -- so this must not touch asyncio
        primitives directly. `call_soon_threadsafe` is safe to call from any
        thread once `_loop` is captured (see `_ensure_connected`); before any
        connect attempt `_loop` is `None` and there is nothing to wake -- the
        next `_on_open` reads `auth_store.token` fresh, so a pre-connect
        change is picked up naturally without any action here. While not
        opened (mid-connect, or between connections), the change is likewise
        dropped for the same reason: the eventual `_on_open` reads the token
        fresh rather than replaying this event.
        """
        del record  # only the token drives re-auth
        if not self._opened or self._loop is None:
            return
        self._loop.call_soon_threadsafe(self._spawn_auth_send, token)

    def _spawn_auth_send(self, token: str | None) -> None:
        # Runs on the loop's thread (scheduled via call_soon_threadsafe from
        # `_on_auth_store_change`) -- `create_task` is safe here. Re-check
        # `_opened`: the socket may have closed/dropped between the listener
        # firing and this callback actually running.
        if not self._opened:
            return
        task = asyncio.create_task(self._send_auth_frame(token or ""))
        self._auth_tasks.add(task)
        task.add_done_callback(self._auth_tasks.discard)

    async def _send_auth_frame(self, token: str) -> None:
        """Send an `auth` frame and await its response.

        The ack future is REUSED across back-to-back sends (rapid token
        churn before any reply arrives): every waiter shares one future and
        settles together on the FIRST response, mirroring the TS/Dart ports
        (`sendAuthFrame`/`_sendAuthFrame`). Never raises -- an auth failure
        is caught here and surfaced via `on_error` only, so it can't block
        the on-open resubscribe gate or leave a fire-and-forget re-auth task
        with an unretrieved exception.

        The connection can also drop between this fire-and-forget send being
        scheduled (a re-auth task off `_on_auth_store_change`) and actually
        running: captured locally and checked rather than asserted, so that
        race drops the frame silently instead of crashing -- the eventual
        reconnect re-authenticates from a freshly read `auth_store.token`
        anyway.
        """
        connection = self._connection
        if connection is None:
            return
        ack = self._auth_ack
        if ack is None:
            ack = self._auth_ack = asyncio.get_running_loop().create_future()
        await connection.send(encode_auth(token))
        try:
            await ack
        except Exception as exc:
            self._on_error(str(exc))

    def _on_auth_frame(self, status: str | None) -> None:
        # Detach before settling so a superseded frame's later response (the
        # future is reused across back-to-back sends) finds `_auth_ack`
        # already `None` and is a no-op rather than double-settling a future
        # a fresh send has since replaced.
        ack = self._auth_ack
        self._auth_ack = None
        if ack is None or ack.done():
            return
        if status == "ok":
            ack.set_result(None)
        else:
            ack.set_exception(ZigbaseError(status=0, message="auth failed", url=""))

    def _fail_auth_ack(self, message: str) -> None:
        """Detach and fail a live auth-ack future with `message`.

        Shared by `close()` and `_receive_loop`'s finally: both are places
        where the connection is going away and no `auth` reply will ever
        arrive, so whoever is awaiting the (possibly shared/reused) ack
        inside `_send_auth_frame` must be unblocked rather than left
        hanging. A no-op when there's nothing pending.
        """
        ack = self._auth_ack
        self._auth_ack = None
        if ack is not None and not ack.done():
            ack.set_exception(ZigbaseError(status=0, message=message, url=""))

    def _schedule_reconnect(self) -> None:
        """Schedule the next reconnect attempt with bounded exponential
        backoff.

        `_reconnect_pending` stays `True` through the backoff sleep, so a
        subscribe racing it defers via `_ensure_connected` instead of opening
        a competing socket. `_reconnect` clears the flag in a `finally`
        immediately BEFORE calling `_connect_once` (not after) -- but that
        call's very first statements set `_connecting = True` with no `await`
        in between, so no other task ever gets a turn to observe both flags
        `False` at once; the baton passes atomically from one guard to the
        other. `close()` cancels the task outright. Scheduling itself is a
        no-op when a reconnect is already pending (multiple call sites --
        the receive loop's drop handler and `_connect_once`'s own failure
        path -- can each want one), the service has been closed, or there
        are no live subscriptions left to resurrect the socket for -- an
        idle connection (every caller unsubscribed) that drops, or fails to
        connect, must not be reopened; matches TS `onClose`/`connect`'s catch
        and Dart `_onClose`/`_connect`'s catch, which gate identically on a
        non-empty subscription set.
        """
        if self._reconnect_pending or self._closed_by_user or not self._subscriptions:
            return
        self._reconnect_pending = True
        self._reconnect_task = asyncio.create_task(self._reconnect())

    async def _reconnect(self) -> None:
        try:
            shift = min(self._reconnect_attempts, _RECONNECT_MAX_SHIFT)
            delay = min(_RECONNECT_MAX_DELAY, _RECONNECT_MIN_DELAY * (2**shift))
            self._reconnect_attempts += 1
            try:
                await _asleep(delay)
            except Exception as exc:
                # A throwing injectable sleep must neither wedge
                # `_reconnect_pending` (the finally below always clears it --
                # a stuck flag would no-op `_ensure_connected` forever) nor
                # leave this fire-and-forget task's exception unretrieved.
                # Surface it and treat the backoff as elapsed -- the
                # reconnect itself still proceeds.
                self._on_error(str(exc))
        finally:
            self._reconnect_pending = False
        if self._closed_by_user:
            return
        await self._connect_once()

    async def _send_subscribe(self, sub: _Subscription) -> None:
        # The connection can drop between two iterations of a caller's loop
        # (`_resubscribe_all` awaits one send per subscription) -- captured
        # locally and checked rather than asserted, so a drop landing mid-loop
        # silently skips the remaining sends instead of crashing the whole
        # reconnect/open path; a later reconnect resends whatever was missed.
        connection = self._connection
        if connection is None:
            return
        sub.inflight = True
        await connection.send(encode_subscribe(sub.topic, sub.filter))

    def _fail_pending(self, message: str) -> None:
        for sub in self._subscriptions.values():
            pending = sub.pending
            sub.pending = []
            for fut in pending:
                if not fut.done():
                    fut.set_exception(ZigbaseError(status=0, message=message, url=""))

    # ---- receive loop / dispatch ----------------------------------------------

    async def _receive_loop(self, connection: RealtimeConnection) -> None:
        try:
            async for raw in connection.recv():
                frame = decode_frame(raw)
                if frame is None:
                    continue
                await self._dispatch(frame)
        finally:
            if self._connection is connection:
                self._opened = False
                self._connection = None
                self._receive_task = None
                # An unexpected drop can land while `_on_open` is still
                # awaiting the auth ack (a genuine suspension point, unlike
                # the largely-synchronous resubscribe sends) -- without this,
                # nothing but a user close() would ever settle that ack, and
                # `_on_open` -- and the `subscribe()` call that triggered it
                # -- would hang forever. `_send_auth_frame` routes this
                # through `on_error` and returns normally either way, so
                # `_on_open` still reaches `_resubscribe_all`.
                self._fail_auth_ack("realtime connection lost")
                if not self._closed_by_user:
                    self._schedule_reconnect()

    async def _dispatch(self, frame: dict[str, Any]) -> None:
        frame_type = frame.get("type")
        if frame_type == "connect":
            client_id = frame.get("clientId")
            self._client_id = client_id if isinstance(client_id, str) else None
        elif frame_type == "auth":
            status = frame.get("status")
            self._on_auth_frame(status if isinstance(status, str) else None)
        elif frame_type == "ack":
            topic = frame.get("topic")
            if isinstance(topic, str):
                self._on_ack(topic)
        elif frame_type == "event":
            await self._on_event(frame)
        elif frame_type in ("signal", "message"):
            await self._on_topic_frame(frame)
        elif frame_type == "error":
            message = frame.get("message")
            self._on_error_frame(message if isinstance(message, str) else "realtime error")
        # any other/missing type -> unknown, dropped silently

    def _on_ack(self, topic: str) -> None:
        # Ack frames carry only a topic string, so this settles EVERY
        # subscription sharing that topic -- record and topic subs alike, and
        # every filter variant of a record sub -- matching the TS/Dart ports.
        for sub in self._subscriptions.values():
            if sub.topic != topic:
                continue
            sub.acked = True
            sub.inflight = False
            pending = sub.pending
            sub.pending = []
            for fut in pending:
                if not fut.done():
                    fut.set_result(None)

    async def _on_event(self, frame: dict[str, Any]) -> None:
        topic = frame.get("topic")
        if not isinstance(topic, str):
            return
        record = frame.get("record")
        action = frame.get("action")
        event = RealtimeEvent(
            topic=topic,
            action=action if isinstance(action, str) else "",
            record=record if isinstance(record, dict) else {},
        )
        for sub in list(self._subscriptions.values()):
            if sub.kind != "records" or sub.topic != topic:
                continue
            for cb in list(sub.callbacks):
                await self._invoke_record_callback(cb, event)

    async def _invoke_record_callback(self, cb: RecordCallback, event: RealtimeEvent) -> None:
        try:
            result = cb(event)
            if inspect.isawaitable(result):
                await result
        except Exception as exc:  # a raising callback must not kill the loop
            self._on_error(str(exc))

    async def _on_topic_frame(self, frame: dict[str, Any]) -> None:
        topic = frame.get("topic")
        if not isinstance(topic, str):
            return  # malformed (missing topic) -> dropped
        frame_type = frame.get("type")
        kind = frame_type if isinstance(frame_type, str) else ""
        data = frame.get("data") if kind == "message" else None
        msg = TopicMessage(topic=topic, kind=kind, data=data)
        for sub in list(self._subscriptions.values()):
            if sub.kind != "topic" or sub.topic != topic:
                continue
            for cb in list(sub.topic_callbacks):
                await self._invoke_topic_callback(cb, msg)

    async def _invoke_topic_callback(self, cb: TopicCallback, msg: TopicMessage) -> None:
        try:
            result = cb(msg)
            if inspect.isawaitable(result):
                await result
        except Exception as exc:  # a raising callback must not kill the loop
            self._on_error(str(exc))

    def _on_error_frame(self, message: str) -> None:
        # The server's error frame carries NO topic, so this rejects EVERY
        # unacked pending subscribe (a pre-existing wire-protocol limitation
        # inherited from the TS/Dart SDKs: two subscribes in flight when one
        # fails are both rejected). Each rejected subscription never acked,
        # so no unsubscribe frame is owed; it's dropped from the map entirely
        # so a reconnect won't silently resubscribe a topic the caller was
        # already told had failed -- a later subscribe() re-creates it fresh.
        for key, sub in list(self._subscriptions.items()):
            if sub.acked or not sub.pending:
                continue
            del self._subscriptions[key]
            pending = sub.pending
            sub.pending = []
            for fut in pending:
                if not fut.done():
                    fut.set_exception(ZigbaseError(status=0, message=message, url=""))
        self._on_error(message)


__all__ = [
    "RealtimeConnection",
    "RealtimeEvent",
    "RealtimeService",
    "RecordCallback",
    "TopicCallback",
    "TopicMessage",
    "Unsubscribe",
    "decode_frame",
    "encode_auth",
    "encode_subscribe",
    "encode_unsubscribe",
    "realtime_url",
]
