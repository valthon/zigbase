"""Tests for `RealtimeService`'s auth lifecycle.

Port of the auth-gated on-open resubscribe and re-auth-on-token-change
coverage in clients/typescript/test/realtime-auth.test.ts and
clients/dart/test/realtime_test.dart's "RealtimeService auth" group, adapted
to asyncio (see test_realtime_subscribe.py's module docstring for the
`_pump()` rationale).

One deliberate deviation from the TS/Dart ports: an auth failure is always
surfaced via `on_error` here (never silently swallowed), matching the SDK's
"errors are never silently dropped" philosophy -- see realtime.py's
`_send_auth_frame`/`_on_auth_frame`.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable

import pytest

from tests.support.fake_connector import FakeConnectorFactory
from zigbase.auth_store import MemoryAuthStore
from zigbase.errors import ZigbaseError
from zigbase.realtime import RealtimeEvent, RealtimeService


async def _pump(times: int = 5) -> None:
    for _ in range(times):
        await asyncio.sleep(0)


def make_service(
    factory: FakeConnectorFactory | None = None,
    auth_store: MemoryAuthStore | None = None,
    on_error: Callable[[str], None] | None = None,
) -> tuple[RealtimeService, FakeConnectorFactory, MemoryAuthStore]:
    factory = factory or FakeConnectorFactory()
    auth_store = auth_store or MemoryAuthStore()
    service = RealtimeService(
        "http://api.test", auth_store, connector=factory.connect, on_error=on_error
    )
    return service, factory, auth_store


class TestAuthOnOpen:
    async def test_auth_frame_precedes_subscribe_and_gates_it_on_ok(self) -> None:
        store = MemoryAuthStore()
        store.save("tok-1", {"id": "u1"})
        service, factory, _ = make_service(auth_store=store)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()

        assert factory.last.sent == [{"action": "auth", "token": "tok-1"}]
        assert factory.last.subscribe_frames == []

        await factory.last.push({"type": "auth", "status": "ok"})
        await _pump()
        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task
        await service.close()

    async def test_anonymous_open_sends_no_auth_frame(self) -> None:
        service, factory, _ = make_service()

        task = asyncio.create_task(service.subscribe("public", lambda e: None))
        await _pump()

        assert factory.last.sent == [{"action": "subscribe", "topic": "public"}]

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "public"})
        await task
        await service.close()


class TestReauthOnTokenChange:
    async def test_token_change_while_open_sends_new_auth_frame_with_event_token(self) -> None:
        store = MemoryAuthStore()
        service, factory, _ = make_service(auth_store=store)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        assert factory.last.sent == [{"action": "subscribe", "topic": "posts"}]
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        store.save("tok-1", {"id": "u1"})
        await _pump()

        assert factory.last.sent[-1] == {"action": "auth", "token": "tok-1"}
        await service.close()

    async def test_logout_sends_empty_token_frame_and_existing_subs_keep_delivering(self) -> None:
        store = MemoryAuthStore()
        store.save("tok-1", {"id": "u1"})
        events: list[RealtimeEvent] = []
        service, factory, _ = make_service(auth_store=store)

        task = asyncio.create_task(service.subscribe("posts", events.append))
        await _pump()
        await factory.last.push({"type": "auth", "status": "ok"})
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        store.clear()
        await _pump()
        assert factory.last.sent[-1] == {"action": "auth", "token": ""}

        # The server rejects the empty token; existing subscriptions must
        # keep delivering regardless.
        await factory.last.push({"type": "auth", "status": "error"})
        await factory.last.push(
            {"type": "event", "topic": "posts", "action": "update", "record": {"id": "p1"}}
        )
        await _pump()
        assert len(events) == 1
        assert events[0].record == {"id": "p1"}
        await service.close()

    async def test_rapid_reauth_before_any_response_settles_cleanly(self) -> None:
        store = MemoryAuthStore()
        store.save("tok-1", {"id": "u1"})
        service, factory, _ = make_service(auth_store=store)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        assert factory.last.sent == [{"action": "auth", "token": "tok-1"}]

        # onOpen sent auth tok-1; before its response, the token changes twice.
        store.save("tok-2", {"id": "u1"})
        store.save("tok-3", {"id": "u1"})
        await _pump()

        auths = [f for f in factory.last.sent if f.get("action") == "auth"]
        assert auths == [
            {"action": "auth", "token": "tok-1"},
            {"action": "auth", "token": "tok-2"},
            {"action": "auth", "token": "tok-3"},
        ]

        # A single response settles the shared, reused future so the gated
        # subscribe flushes -- superseded waiters must not hang.
        await factory.last.push({"type": "auth", "status": "ok"})
        await _pump()
        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]

        # Late, superseded responses arriving after the future was already
        # detached and settled must not raise or double-settle anything.
        await factory.last.push({"type": "auth", "status": "ok"})
        await factory.last.push({"type": "auth", "status": "error"})
        await _pump()

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        # Fails (times out) if the subscribe gate hung on a superseded auth.
        await asyncio.wait_for(task, timeout=1)
        await service.close()


class TestAuthErrorOnOpen:
    async def test_auth_error_on_open_calls_on_error_and_still_resubscribes(self) -> None:
        errors: list[str] = []
        store = MemoryAuthStore()
        store.save("tok-1", {"id": "u1"})
        service, factory, _ = make_service(auth_store=store, on_error=errors.append)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        assert factory.last.sent == [{"action": "auth", "token": "tok-1"}]

        await factory.last.push({"type": "auth", "status": "error"})
        await _pump()

        assert len(errors) == 1
        # Public subs must still work even when auth fails.
        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await asyncio.wait_for(task, timeout=1)
        await service.close()


class TestCloseDetachesListener:
    async def test_auth_store_save_after_close_sends_nothing(self) -> None:
        store = MemoryAuthStore()
        store.save("tok-1", {"id": "u1"})
        service, factory, _ = make_service(auth_store=store)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        await factory.last.push({"type": "auth", "status": "ok"})
        await _pump()
        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await task

        await service.close()
        sent_before = len(factory.last.sent)

        store.save("tok-2", {"id": "u1"})
        await _pump()
        assert len(factory.last.sent) == sent_before


class TestNoConnectorAuth:
    async def test_auth_store_save_before_any_connect_does_not_raise(self) -> None:
        # `_loop` is never captured (no subscribe has run yet), so the
        # on_change listener must be a pure no-op here rather than blowing
        # up on a missing running loop.
        store = MemoryAuthStore()
        RealtimeService("http://api.test", store)
        store.save("tok-1", {"id": "u1"})
        store.clear()


class TestPendingAuthAckOnClose:
    async def test_close_while_awaiting_initial_auth_ack_unblocks_subscribe(self) -> None:
        store = MemoryAuthStore()
        store.save("tok-1", {"id": "u1"})
        service, factory, _ = make_service(auth_store=store)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        assert factory.last.sent == [{"action": "auth", "token": "tok-1"}]

        # The auth ack never arrives; close() must still complete (not hang)
        # and unblock the subscribe() call stuck awaiting it inside _on_open.
        await asyncio.wait_for(service.close(), timeout=1)
        with pytest.raises(ZigbaseError):
            await asyncio.wait_for(task, timeout=1)


class TestSendAuthFrameSendFailure:
    async def test_send_failure_fails_the_ack_waiter_and_calls_on_error(self) -> None:
        # Regression guard: `_send_auth_frame`'s docstring promises "never
        # raises", but the `await connection.send(...)` itself used to be
        # unguarded -- a transport-level send failure (not a rejected auth
        # reply) would escape past this method's own try/except (which only
        # wrapped `await ack`) straight out of `_on_open`. The fix wraps the
        # send too: on failure it must fail the (possibly shared/reused) ack
        # future via `_fail_auth_ack` -- so no waiter strands -- and report
        # through `on_error`, never raise.
        store = MemoryAuthStore()
        store.save("tok-1", {"id": "u1"})
        errors: list[str] = []
        factory = FakeConnectorFactory()
        factory.next_send_exception = RuntimeError("send boom")
        service, _, _ = make_service(factory, auth_store=store, on_error=errors.append)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()

        assert any("send boom" in e for e in errors)
        # Detached, not stranded: a fresh send later reuses `_auth_ack` clean.
        assert service._auth_ack is None  # type: ignore[attr-defined]
        # The one-shot send failure only hit the auth frame -- the resubscribe
        # that follows in `_on_open` still goes out normally.
        assert factory.last.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]

        await factory.last.push({"type": "ack", "action": "subscribe", "topic": "posts"})
        await asyncio.wait_for(task, timeout=1)
        await service.close()


class TestConnectionDropDuringAuthGate:
    async def test_drop_before_auth_reply_unblocks_the_auth_gate_without_close(self) -> None:
        # Regression guard: an unexpected connection drop (not a user
        # close()) while `_on_open` is awaiting the auth ack must settle the
        # gate itself -- `_receive_loop`'s finally must fail `_auth_ack`
        # alongside its existing state reset, mirroring what close() already
        # does. Before the fix, nothing but close() ever settled `_auth_ack`,
        # so this hung forever with no external close() call.
        errors: list[str] = []
        store = MemoryAuthStore()
        store.save("tok-1", {"id": "u1"})
        service, factory, _ = make_service(auth_store=store, on_error=errors.append)

        task = asyncio.create_task(service.subscribe("posts", lambda e: None))
        await _pump()
        assert factory.last.sent == [{"action": "auth", "token": "tok-1"}]

        await factory.last.server_close()
        # No close() call here -- only the drop itself must unblock the gate.
        await asyncio.wait_for(_pump(20), timeout=1)

        assert len(errors) == 1

        # The subscribe's OWN pending future staying unresolved is the
        # pre-existing, documented drop-before-ack limitation (no reconnect
        # until Task 4) -- resubscribe-all no-ops on the now-dead connection
        # rather than crashing. Only close() finally settles it.
        assert not task.done()
        await asyncio.wait_for(service.close(), timeout=1)
        with pytest.raises(ZigbaseError):
            await asyncio.wait_for(task, timeout=1)
