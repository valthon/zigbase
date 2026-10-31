"""A stale response must wait for a newer refresh that is still pending."""

import asyncio
import threading

import httpx
import pytest

from zigbase import _transport
from zigbase._request import RequestSpec
from zigbase._transport import AsyncTransport, SyncTransport
from zigbase.auth_store import MemoryAuthStore


def test_sync_delayed_old_401_joins_newer_refresh(monkeypatch: pytest.MonkeyPatch) -> None:
    auth = MemoryAuthStore()
    auth.save("T0", None)
    started = threading.Event()
    release_old = threading.Event()
    refresh_started = threading.Event()
    release_refresh = threading.Event()
    joined = threading.Event()
    original_wait = _transport._RefreshFlight.wait

    def wait(flight: _transport._RefreshFlight) -> None:
        if threading.current_thread().name == "delayed":
            joined.set()
        original_wait(flight)

    monkeypatch.setattr(_transport._RefreshFlight, "wait", wait)
    refreshes = 0
    tokens: list[str | None] = []

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal refreshes
        path = request.url.path
        token = request.headers.get("Authorization")
        if path.endswith("auth-refresh"):
            refreshes += 1
            if refreshes == 2:
                refresh_started.set()
                assert release_refresh.wait(5)
            return httpx.Response(200, json={"token": f"T{refreshes}", "record": None})
        if path == "/delayed":
            tokens.append(token)
            if token == "Bearer T0":
                started.set()
                assert release_old.wait(5)
        ok = token == "Bearer T2" or (token == "Bearer T1" and path == "/first")
        return httpx.Response(200 if ok else 401, json={"ok": ok})

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        transport = SyncTransport(
            "http://test", auth, auto_refresh=True, auth_collection="users", http_client=client
        )
        results: dict[str, object] = {}

        def send(path: str) -> None:
            try:
                results[path] = transport.request(RequestSpec(method="GET", path=path))
            except Exception as error:
                results[path] = error

        old = threading.Thread(target=send, args=("/delayed",), name="delayed")
        newer = threading.Thread(target=send, args=("/newer",))
        old.start()
        try:
            assert started.wait(5)
            send("/first")
            assert results["/first"] == {"ok": True}
            newer.start()
            assert refresh_started.wait(5)
            release_old.set()
            assert joined.wait(5), "old-token request bypassed the active newer refresh"
            assert tokens == ["Bearer T0"]
        finally:
            release_old.set()
            release_refresh.set()
            old.join(5)
            if newer.ident is not None:
                newer.join(5)
        assert results == {path: {"ok": True} for path in ["/first", "/delayed", "/newer"]}
        assert tokens == ["Bearer T0", "Bearer T2"]
        assert refreshes == 2


@pytest.mark.parametrize(
    "cancel_owner,login_before_join", [(False, False), (True, False), (True, True)]
)
async def test_async_delayed_old_401_joins_newer_refresh(
    cancel_owner: bool, login_before_join: bool, monkeypatch: pytest.MonkeyPatch
) -> None:
    auth = MemoryAuthStore()
    auth.save("T0", None)
    started = asyncio.Event()
    release_old = asyncio.Event()
    refresh_started = asyncio.Event()
    release_refresh = asyncio.Event()
    joined = asyncio.Event()
    original_wait = _transport._AsyncRefreshFlight.wait

    async def wait(flight: _transport._AsyncRefreshFlight) -> bool:
        joined.set()
        return await original_wait(flight)

    monkeypatch.setattr(_transport._AsyncRefreshFlight, "wait", wait)
    refreshes = 0
    tokens: list[str | None] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal refreshes
        path = request.url.path
        token = request.headers.get("Authorization")
        if path.endswith("auth-refresh"):
            refreshes += 1
            if refreshes == 2:
                refresh_started.set()
                await release_refresh.wait()
            return httpx.Response(200, json={"token": f"T{refreshes}", "record": None})
        if path == "/delayed":
            tokens.append(token)
            if token == "Bearer T0":
                started.set()
                await release_old.wait()
        ok = token in ("Bearer T2", "Bearer T3", "Bearer login") or (
            token == "Bearer T1" and path == "/first"
        )
        return httpx.Response(200 if ok else 401, json={"ok": ok})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        transport = AsyncTransport(
            "http://test", auth, auto_refresh=True, auth_collection="users", http_client=client
        )
        old = asyncio.create_task(transport.request(RequestSpec(method="GET", path="/delayed")))
        newer: asyncio.Task[object] | None = None
        try:
            await asyncio.wait_for(started.wait(), 2)
            assert await transport.request(RequestSpec(method="GET", path="/first")) == {"ok": True}
            newer = asyncio.create_task(
                transport.request(
                    RequestSpec(method="GET", path="/newer", request_key="refresh-owner")
                )
            )
            await asyncio.wait_for(refresh_started.wait(), 2)
            if login_before_join:
                auth.save("login", None)
            release_old.set()
            await asyncio.wait_for(joined.wait(), 2)
            assert tokens == ["Bearer T0"]
            if cancel_owner:
                newer.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await newer
                assert await asyncio.wait_for(old, 2) == {"ok": True}
                if login_before_join:
                    assert tokens == ["Bearer T0", "Bearer login"]
                    assert refreshes == 2
                else:
                    assert tokens == ["Bearer T0", "Bearer T3"]
                    assert refreshes == 3
            else:
                release_refresh.set()
                assert await asyncio.wait_for(newer, 2) == {"ok": True}
                assert await asyncio.wait_for(old, 2) == {"ok": True}
                assert tokens == ["Bearer T0", "Bearer T2"]
                assert refreshes == 2
        finally:
            release_old.set()
            release_refresh.set()
            old.cancel()
            if newer is not None:
                newer.cancel()
                await asyncio.gather(old, newer, return_exceptions=True)
            else:
                await asyncio.gather(old, return_exceptions=True)
