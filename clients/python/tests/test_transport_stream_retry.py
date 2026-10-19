"""Logical requests must retain stream bytes while rebuilding retry headers."""

import asyncio
import threading
from io import BytesIO

import httpx
import pytest

from zigbase import _transport
from zigbase._request import RequestSpec
from zigbase._transport import AsyncTransport, SyncTransport
from zigbase.auth_store import MemoryAuthStore


@pytest.mark.parametrize("status", [401, 429, 503])
@pytest.mark.parametrize("asynchronous", [False, True])
def test_stream_survives_retry(
    status: int, asynchronous: bool, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(_transport, "_sleep", lambda _: None)

    async def no_sleep(_: float) -> None:
        pass

    monkeypatch.setattr(_transport, "_asleep", no_sleep)
    payloads: list[bytes] = []
    auth = MemoryAuthStore()
    auth.save("old", None)

    class NonSeekable:
        def __init__(self) -> None:
            self.stream = BytesIO(b"important file bytes")

        def read(self) -> bytes:
            return self.stream.read()

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("auth-refresh"):
            return httpx.Response(200, json={"token": "fresh", "record": None})
        payloads.append(request.read())
        if len(payloads) == 1:
            return httpx.Response(status, json={"code": "overloaded"})
        if status == 401:
            assert request.headers["Authorization"] == "Bearer fresh"
        return httpx.Response(200, json={"ok": True})

    spec = RequestSpec(method="POST", path="/upload", body={"file": NonSeekable()})
    if asynchronous:

        async def run() -> None:
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                transport = AsyncTransport(
                    "http://test",
                    auth,
                    auto_refresh=True,
                    auth_collection="users",
                    http_client=client,
                )
                assert await transport.request(spec) == {"ok": True}

        asyncio.run(run())
    else:
        with httpx.Client(transport=httpx.MockTransport(handler)) as client:
            transport = SyncTransport(
                "http://test",
                auth,
                auto_refresh=True,
                auth_collection="users",
                http_client=client,
            )
            assert transport.request(spec) == {"ok": True}
    assert len(payloads) == 2
    assert all(b"important file bytes" in payload for payload in payloads)


def test_delayed_stale_401_reuses_completed_refresh() -> None:
    auth = MemoryAuthStore()
    auth.save("old", None)
    delayed_started = threading.Event()
    release_delayed = threading.Event()
    refreshes = 0
    expire_next = False

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal refreshes, expire_next
        if request.url.path.endswith("auth-refresh"):
            refreshes += 1
            return httpx.Response(200, json={"token": f"fresh-{refreshes}", "record": None})
        if request.headers.get("Authorization") == "Bearer old":
            if request.url.path == "/delayed":
                delayed_started.set()
                assert release_delayed.wait(5)
            return httpx.Response(401, json={})
        if expire_next:
            expire_next = False
            return httpx.Response(401, json={})
        return httpx.Response(200, json={"ok": True})

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        transport = SyncTransport(
            "http://test",
            auth,
            auto_refresh=True,
            auth_collection="users",
            http_client=client,
        )
        results: list[object] = []
        thread = threading.Thread(
            target=lambda: results.append(
                transport.request(RequestSpec(method="GET", path="/delayed"))
            )
        )
        thread.start()
        try:
            assert delayed_started.wait(5)
            assert transport.request(RequestSpec(method="GET", path="/first")) == {"ok": True}
        finally:
            release_delayed.set()
            thread.join(5)
        assert not thread.is_alive()
        assert results == [{"ok": True}]
        assert refreshes == 1
        expire_next = True
        assert transport.request(RequestSpec(method="GET", path="/later")) == {"ok": True}
        assert refreshes == 2
