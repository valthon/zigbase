"""Cancellation must not depend on a custom transport cooperating."""

import asyncio

import httpx
import pytest

from zigbase import AsyncZigBase
from zigbase.auth_store import MemoryAuthStore


@pytest.mark.parametrize("keyed", [False, True])
async def test_delayed_401_uses_refresh_completed_by_another_request(keyed):
    started = asyncio.Event()
    release = asyncio.Event()
    store = MemoryAuthStore()
    store.save("old-token", {"id": "u"})
    refreshes = 0
    sent = []

    async def handler(request):
        nonlocal refreshes
        token = request.headers["Authorization"].removeprefix("Bearer ")
        sent.append((request.url.path, token))
        if request.url.path.endswith("/auth-refresh"):
            refreshes += 1
            return httpx.Response(200, json={"token": "fresh-token", "record": {"id": "u"}})
        if token == "old-token":
            if request.url.path == "/slow":
                started.set()
                await release.wait()
            return httpx.Response(401, json={"message": "expired"})
        return httpx.Response(200, json={"ok": True})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase(
            "http://localhost",
            http_client=http,
            auth_store=store,
            auth_collection="users",
            auto_refresh=True,
        ) as zb,
    ):
        slow = asyncio.create_task(zb.send("GET", "/slow", request_key="slow" if keyed else None))
        try:
            await asyncio.wait_for(started.wait(), 1)
            assert await zb.send("GET", "/fast", request_key="fast" if keyed else None) == {
                "ok": True
            }
            assert store.token == "fresh-token"
            assert refreshes == 1
            release.set()
            assert await asyncio.wait_for(slow, 1) == {"ok": True}
            assert refreshes == 1
            assert [(path, token) for path, token in sent if path == "/slow"] == [
                ("/slow", "old-token"),
                ("/slow", "fresh-token"),
            ]
        finally:
            release.set()
            await asyncio.gather(slow, return_exceptions=True)


@pytest.mark.parametrize("action", ["replace", "caller"])
async def test_close_recancels_detached_transport_work(action):
    started = asyncio.Event()
    swallowed = asyncio.Event()
    stopped = asyncio.Event()

    async def handler(request):
        if request.url.path == "/old":
            started.set()
            try:
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    swallowed.set()
                    await asyncio.Event().wait()
            finally:
                stopped.set()
        return httpx.Response(200, json={})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        zb = AsyncZigBase("http://localhost", http_client=http)
        old = asyncio.create_task(zb.send("GET", "/old", request_key="k"))
        try:
            await asyncio.wait_for(started.wait(), 1)
            if action == "replace":
                await zb.send("GET", "/new", request_key="k")
            else:
                old.cancel()
            with pytest.raises(asyncio.CancelledError):
                await old
            await asyncio.wait_for(swallowed.wait(), 1)
            assert not zb._transport._keyed_requests
            retained = tuple(zb._transport._keyed_tasks)
            assert retained
            await zb.aclose()
            done, _ = await asyncio.wait(retained, timeout=0.1)
            assert len(done) == len(retained), "close did not cancel detached work"
            assert stopped.is_set()
            assert not http.is_closed
        finally:
            for task in zb._transport._keyed_tasks:
                task.cancel()
            await asyncio.gather(old, *zb._transport._keyed_tasks, return_exceptions=True)


@pytest.mark.parametrize("failure", [False, True])
async def test_keyed_calls_cancel_before_realtime_close(failure):
    started = asyncio.Event()
    closing = asyncio.Event()
    release = asyncio.Event()

    async def handler(request):
        started.set()
        await asyncio.Event().wait()

    class Realtime:
        async def close(self):
            closing.set()
            if failure:
                raise RuntimeError("realtime close failed")
            await release.wait()

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        zb = AsyncZigBase("http://localhost", http_client=http)
        zb._realtime = Realtime()
        old = asyncio.create_task(zb.send("GET", "/old", request_key="k"))
        await asyncio.wait_for(started.wait(), 1)
        close = asyncio.create_task(zb.aclose())
        try:
            await asyncio.wait_for(closing.wait(), 1)
            done, _ = await asyncio.wait({old}, timeout=0.1)
            assert old in done, "HTTP cancellation depended on realtime teardown"
            with pytest.raises(asyncio.CancelledError):
                await old
            assert not http.is_closed
            if failure:
                with pytest.raises(RuntimeError, match="realtime close failed"):
                    await close
            else:
                assert not close.done()
        finally:
            release.set()
            old.cancel()
            await asyncio.gather(old, close, return_exceptions=True)


async def test_owned_http_client_closes_when_realtime_close_fails():
    class Realtime:
        async def close(self):
            raise RuntimeError("realtime close failed")

    zb = AsyncZigBase("http://localhost")
    zb._realtime = Realtime()
    try:
        with pytest.raises(RuntimeError, match="realtime close failed"):
            await zb.aclose()
        assert zb._http_client.is_closed
    finally:
        await zb._http_client.aclose()


@pytest.mark.parametrize("action", ["replace", "close", "caller"])
@pytest.mark.parametrize("raw", [False, True])
@pytest.mark.parametrize("late_outcome", ["success", "http_error", "transport_error"])
async def test_cancel_returns_before_stubborn_transport_finishes(action, raw, late_outcome):
    started = asyncio.Event()
    swallowed = asyncio.Event()
    release = asyncio.Event()

    async def handler(request):
        if request.url.path == "/old":
            started.set()
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                swallowed.set()
                await release.wait()
            if late_outcome == "transport_error":
                raise httpx.ConnectError("late failure")
            return httpx.Response(400 if late_outcome == "http_error" else 200, json={"old": True})
        return httpx.Response(200, json={"new": True})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase("http://localhost", http_client=http) as zb,
    ):
        send = zb.raw_request if raw else zb.send
        old = asyncio.create_task(send("GET", "/old", request_key="k"))
        try:
            await asyncio.wait_for(started.wait(), 1)
            if action == "replace":
                await asyncio.wait_for(send("GET", "/new", request_key="k"), 1)
            elif action == "close":
                await asyncio.wait_for(zb.aclose(), 1)
                assert not http.is_closed
            else:
                old.cancel()
            await asyncio.wait_for(swallowed.wait(), 1)
            # asyncio.wait (unlike wait_for) does not cancel a hung public
            # caller and therefore cannot accidentally make the assertion pass.
            done, _ = await asyncio.wait({old}, timeout=0.1)
            assert old in done, "public cancellation waited for transport cleanup"
            with pytest.raises(asyncio.CancelledError):
                await old
            assert not release.is_set()
            assert zb._transport._keyed_requests == {}
            assert zb._transport._keyed_tasks  # retained until eventual completion
        finally:
            release.set()
            await asyncio.gather(old, *zb._transport._keyed_tasks, return_exceptions=True)
        assert zb._transport._keyed_tasks == set()


@pytest.mark.parametrize(
    "late_outcome", ["success", "http_error", "transport_error", "overload", "rate_limit"]
)
async def test_cancelled_refresh_owner_cannot_hold_waiters_or_overwrite_new_token(late_outcome):
    refreshing = asyncio.Event()
    waiting = asyncio.Event()
    release = asyncio.Event()
    store = MemoryAuthStore()
    store.save("old-token", {"id": "u"})
    refresh_calls = 0

    async def handler(request):
        nonlocal refresh_calls
        if request.url.path.endswith("/auth-refresh"):
            refresh_calls += 1
            if refresh_calls == 1:
                refreshing.set()
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    await release.wait()
                if late_outcome == "transport_error":
                    raise httpx.ConnectError("translated cancellation")
                if late_outcome in ("overload", "rate_limit"):
                    return httpx.Response(
                        503 if late_outcome == "overload" else 429,
                        headers={"Retry-After": "0"},
                        json={"code": "overloaded", "message": "late overload"},
                    )
                return httpx.Response(
                    400 if late_outcome == "http_error" else 200,
                    json={"token": "stale-token", "record": {"id": "stale"}},
                )
            return httpx.Response(200, json={"token": "fresh-token", "record": {"id": "u"}})
        if request.headers.get("Authorization") == "Bearer old-token":
            if request.url.path == "/waiter":
                waiting.set()
            return httpx.Response(401, json={"message": "expired"})
        return httpx.Response(200, json={"ok": True})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase(
            "http://localhost",
            http_client=http,
            auth_store=store,
            auth_collection="users",
            auto_refresh=True,
        ) as zb,
    ):
        old = asyncio.create_task(zb.send("GET", "/old", request_key="k"))
        waiter = None
        try:
            await asyncio.wait_for(refreshing.wait(), 1)
            waiter = asyncio.create_task(zb.send("GET", "/waiter"))
            await asyncio.wait_for(waiting.wait(), 1)
            assert await asyncio.wait_for(zb.send("GET", "/new", request_key="k"), 1) == {
                "ok": True
            }
            assert await asyncio.wait_for(waiter, 1) == {"ok": True}
            done, _ = await asyncio.wait({old}, timeout=0.1)
            assert old in done
            with pytest.raises(asyncio.CancelledError):
                await old
            assert store.token == "fresh-token"
            assert not release.is_set()
        finally:
            release.set()
            tasks = [old, *zb._transport._keyed_tasks]
            if waiter is not None:
                tasks.append(waiter)
            await asyncio.gather(*tasks, return_exceptions=True)
        assert store.token == "fresh-token"
        assert refresh_calls == 2
        assert zb._transport._refresh_flight is None
        assert zb._transport._keyed_tasks == set()
