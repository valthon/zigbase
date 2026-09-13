"""Latest-request-wins is scoped to one async client, not one HTTP connection."""

import asyncio

import httpx
import pytest

from zigbase import AsyncZigBase
from zigbase import _transport as transport_module
from zigbase.auth_store import MemoryAuthStore
from zigbase.errors import ZigbaseError
from zigbase.typed import AsyncTypedCollection, CollectionMeta


@pytest.mark.parametrize("raw", [False, True])
async def test_replacement_cancels_old_request_without_removing_new_owner(raw):
    started = asyncio.Event()
    replacement_started = asyncio.Event()
    finish = asyncio.Event()

    async def handler(request):
        if request.url.path == "/old":
            started.set()
            await asyncio.Event().wait()
        replacement_started.set()
        await finish.wait()
        return httpx.Response(200, json={"fresh": True})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase("http://localhost", http_client=http) as zb,
    ):
        send = zb.raw_request if raw else zb.send
        old = asyncio.create_task(send("GET", "/old", request_key="search"))
        await started.wait()
        new = asyncio.create_task(send("GET", "/new", request_key="search"))
        await replacement_started.wait()
        with pytest.raises(asyncio.CancelledError):
            await old
        assert "search" in zb._transport._keyed_requests
        finish.set()
        result = await new
        assert (result.json() if raw else result) == {"fresh": True}
        assert zb._transport._keyed_requests == {}


async def test_different_keys_and_unkeyed_requests_do_not_cancel_each_other():
    entered = 0
    all_started = asyncio.Event()

    async def handler(request):
        nonlocal entered
        entered += 1
        if entered == 4:
            all_started.set()
        await all_started.wait()
        return httpx.Response(200, json={"ok": True})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase("http://localhost", http_client=http) as zb,
    ):
        results = await asyncio.wait_for(
            asyncio.gather(
                *(zb.send("GET", "/same", request_key=key) for key in ["a", "", None, None])
            ),
            timeout=2,
        )
        assert len(results) == 4
        assert zb._transport._keyed_requests == {}


async def test_account_siblings_have_separate_key_namespaces():
    entered = 0
    all_started = asyncio.Event()

    async def handler(request):
        nonlocal entered
        entered += 1
        if entered == 2:
            all_started.set()
        await all_started.wait()
        return httpx.Response(200, json={"account": request.headers.get("X-Account-Id")})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase("http://localhost", http_client=http) as zb,
    ):
        async with zb.with_account("other") as sibling:
            results = await asyncio.wait_for(
                asyncio.gather(
                    zb.send("GET", "/same", request_key="shared"),
                    sibling.send("GET", "/same", request_key="shared"),
                ),
                timeout=2,
            )
        assert results == [{"account": None}, {"account": "other"}]
        assert not http.is_closed


@pytest.mark.parametrize("close", [False, True])
async def test_caller_cancellation_and_client_close_release_key(close):
    started = asyncio.Event()

    async def handler(request):
        started.set()
        await asyncio.Event().wait()

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase("http://localhost", http_client=http) as zb,
    ):
        task = asyncio.create_task(zb.send("GET", "/wait", request_key="k"))
        await started.wait()
        if close:
            await zb.aclose()
        else:
            task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert zb._transport._keyed_requests == {}
        assert not http.is_closed


async def test_error_cleanup_and_key_reuse():
    async def handler(request):
        return httpx.Response(400 if request.url.path == "/bad" else 200, json={})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase("http://localhost", http_client=http) as zb,
    ):
        with pytest.raises(ZigbaseError):
            await zb.send("GET", "/bad", request_key="k")
        assert zb._transport._keyed_requests == {}
        assert await zb.send("GET", "/ok", request_key="k") == {}
        with pytest.raises(TypeError, match="request_key"):
            await zb.send("GET", "/ok", request_key=42)
        assert zb._transport._keyed_requests == {}


async def test_supersession_stops_overload_backoff(monkeypatch):
    sleeping = asyncio.Event()
    calls = []

    async def sleep(delay):
        sleeping.set()
        await asyncio.Event().wait()

    async def handler(request):
        calls.append(request.url.path)
        if request.url.path == "/old":
            return httpx.Response(503, json={"code": "overloaded", "message": "busy"})
        return httpx.Response(200, json={})

    monkeypatch.setattr(transport_module, "_asleep", sleep)
    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase("http://localhost", http_client=http) as zb,
    ):
        old = asyncio.create_task(zb.send("GET", "/old", request_key="k"))
        await sleeping.wait()
        assert await zb.send("GET", "/new", request_key="k") == {}
        with pytest.raises(asyncio.CancelledError):
            await old
        assert calls == ["/old", "/new"]


@pytest.mark.parametrize("failure", [None, "http", "transport"])
async def test_transport_suppressing_cancellation_cannot_deliver_stale_result(failure):
    started = asyncio.Event()

    async def handler(request):
        if request.url.path == "/old":
            started.set()
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                if failure == "transport":
                    raise httpx.ConnectError("stale failure") from None
                return httpx.Response(400 if failure == "http" else 200, json={"stale": True})
        return httpx.Response(200, json={"fresh": True})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase("http://localhost", http_client=http) as zb,
    ):
        old = asyncio.create_task(zb.send("GET", "/old", request_key="k"))
        await started.wait()
        assert await zb.send("GET", "/new", request_key="k") == {"fresh": True}
        with pytest.raises(asyncio.CancelledError):
            await old


async def test_superseding_refresh_owner_does_not_cancel_other_waiters():
    refreshing = asyncio.Event()
    waiter_started = asyncio.Event()
    refresh_calls = 0
    store = MemoryAuthStore()
    store.save("old-token", {"id": "u"})

    async def handler(request):
        nonlocal refresh_calls
        if request.url.path.endswith("/auth-refresh"):
            refresh_calls += 1
            if refresh_calls == 1:
                refreshing.set()
                await asyncio.Event().wait()
            return httpx.Response(200, json={"token": "new-token", "record": {"id": "u"}})
        if request.headers.get("Authorization") == "Bearer old-token":
            if request.url.path == "/waiter":
                waiter_started.set()
            return httpx.Response(401, json={"message": "expired"})
        return httpx.Response(200, json={"ok": True})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase(
            "http://localhost",
            http_client=http,
            auth_store=store,
            auto_refresh=True,
            auth_collection="users",
        ) as zb,
    ):
        old = asyncio.create_task(zb.send("GET", "/old", request_key="k"))
        await refreshing.wait()
        waiter = asyncio.create_task(zb.send("GET", "/waiter"))
        await waiter_started.wait()
        assert await zb.send("GET", "/new", request_key="k") == {"ok": True}
        assert await waiter == {"ok": True}
        with pytest.raises(asyncio.CancelledError):
            await old
        assert refresh_calls == 2


@pytest.mark.parametrize("method", ["get_list", "get_one", "get_first_list_item", "get_page"])
@pytest.mark.parametrize("typed", [False, True])
async def test_collection_read_helpers_forward_key_without_sending_it(method, typed):
    started = asyncio.Event()
    calls = 0

    async def handler(request):
        nonlocal calls
        calls += 1
        assert "request_key" not in str(request.url)
        assert "requestKey" not in str(request.url)
        if calls == 1:
            started.set()
            await asyncio.Event().wait()
        return httpx.Response(200, json={"id": "r", "items": [{"id": "r"}]})

    async with (
        httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http,
        AsyncZigBase("http://localhost", http_client=http) as zb,
    ):
        args = (
            ("r",)
            if method == "get_one"
            else ("@public",)
            if method == "get_first_list_item"
            else ()
        )
        collection = (
            AsyncTypedCollection(zb, CollectionMeta(name="posts", fields={}), lambda r: r)
            if typed
            else zb.collection("posts")
        )
        call = getattr(collection, method)
        old = asyncio.create_task(call(*args, request_key="k"))
        await started.wait()
        await call(*args, request_key="k")
        with pytest.raises(asyncio.CancelledError):
            await old
