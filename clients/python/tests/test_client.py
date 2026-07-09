"""Tests for `zigbase.client` (`ZigBase`/`AsyncZigBase`).

Mirrors the equivalent behavior in clients/typescript/test/client.test.ts
and clients/dart/test/client_test.dart, adapted to this SDK's `httpx.Client(
transport=httpx.MockTransport(handler))` fixture (see test_transport.py) so
every facade method is exercised through a real `SyncTransport`/
`AsyncTransport` rather than a fake.
"""

from __future__ import annotations

from collections.abc import Callable

import httpx
import pytest

from zigbase.accounts import AccountsService, AsyncAccountsService
from zigbase.analytics import AnalyticsService, AsyncAnalyticsService
from zigbase.auth_store import MemoryAuthStore
from zigbase.client import AsyncZigBase, ZigBase
from zigbase.collection import AsyncCollectionService, CollectionService
from zigbase.files import AsyncFilesService, FilesService
from zigbase.senders import AsyncSendersService, SendersService

Handler = Callable[[httpx.Request], httpx.Response]


def json_response(body: object, status: int = 200) -> httpx.Response:
    return httpx.Response(status, json=body)


def make_sync_client(handler: Handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def make_async_client(handler: Handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


# --- construction --------------------------------------------------------


def test_base_url_is_normalized() -> None:
    zb = ZigBase(
        "http://localhost:8090///", http_client=make_sync_client(lambda r: json_response({}))
    )
    assert zb.base_url == "http://localhost:8090"
    zb.close()


def test_default_auth_store_is_memory_auth_store() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))
    assert isinstance(zb.auth_store, MemoryAuthStore)
    zb.close()


def test_explicit_auth_store_is_used_verbatim() -> None:
    store = MemoryAuthStore()
    zb = ZigBase(
        "http://localhost:8090",
        auth_store=store,
        http_client=make_sync_client(lambda r: json_response({})),
    )
    assert zb.auth_store is store
    zb.close()


# --- collection() ----------------------------------------------------------


def test_collection_returns_service_bound_to_name() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response({"id": "rec1", "collectionName": "posts"})

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    svc = zb.collection("posts")

    assert isinstance(svc, CollectionService)
    assert svc.name == "posts"

    svc.get_one("rec1")
    assert requests[0].url.path == "/api/collections/posts/records/rec1"
    zb.close()


# --- lazily-cached services --------------------------------------------------


def test_service_attributes_are_correct_types_and_cached() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))

    assert isinstance(zb.files, FilesService)
    assert isinstance(zb.accounts, AccountsService)
    assert isinstance(zb.analytics, AnalyticsService)
    assert isinstance(zb.senders, SendersService)
    assert zb.files is zb.files
    assert zb.accounts is zb.accounts
    assert zb.analytics is zb.analytics
    assert zb.senders is zb.senders
    zb.close()


# --- health() ----------------------------------------------------------


def test_health_gets_api_health() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response({"status": "ok"})

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))

    result = zb.health()

    assert result == {"status": "ok"}
    assert requests[0].method == "GET"
    assert requests[0].url.path == "/api/health"
    zb.close()


# --- send() / raw_request() --------------------------------------------------


def test_send_hits_arbitrary_path_with_auth_header() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response({"ok": True})

    store = MemoryAuthStore()
    store.save("tok.tok.tok", {"id": "u1"})
    zb = ZigBase("http://localhost:8090", auth_store=store, http_client=make_sync_client(handler))

    result = zb.send("POST", "/api/custom", body={"a": 1})

    assert result == {"ok": True}
    assert requests[0].headers["authorization"] == "Bearer tok.tok.tok"
    assert requests[0].method == "POST"
    assert requests[0].url.path == "/api/custom"
    zb.close()


def test_raw_request_returns_httpx_response_without_decoding() -> None:
    zb = ZigBase(
        "http://localhost:8090",
        http_client=make_sync_client(lambda r: json_response({"status": "ok"})),
    )

    response = zb.raw_request("GET", "/api/health")

    assert isinstance(response, httpx.Response)
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    zb.close()


def test_raw_request_rejects_unknown_keyword() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))

    with pytest.raises(TypeError):
        zb.raw_request("GET", "/api/health", bogus=True)
    zb.close()


# --- with_account() ----------------------------------------------------------


def test_with_account_sends_header_only_on_sibling() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response({})

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    sibling = zb.with_account("acct-1")

    zb.send("GET", "/api/x")
    sibling.send("GET", "/api/y")

    assert "x-account-id" not in requests[0].headers
    assert requests[1].headers["x-account-id"] == "acct-1"
    zb.close()


def test_with_account_shares_auth_store_and_http_client() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))

    sibling = zb.with_account("acct-1")

    assert sibling.auth_store is zb.auth_store
    assert sibling._http_client is zb._http_client  # type: ignore[attr-defined]

    # login propagates: saving on either store is visible to the other.
    zb.auth_store.save("tok", {"id": "u1"})
    assert sibling.auth_store.token == "tok"
    zb.close()


def test_with_account_sibling_never_owns_shared_client() -> None:
    client = make_sync_client(lambda r: json_response({}))
    zb = ZigBase("http://localhost:8090", http_client=client)
    sibling = zb.with_account("acct-1")

    sibling.close()

    assert client.is_closed is False
    zb.close()


# --- close() / context manager ------------------------------------------------


def test_close_closes_self_created_client() -> None:
    zb = ZigBase("http://127.0.0.1:65535")

    zb.close()

    with pytest.raises(RuntimeError):
        zb.raw_request("GET", "/api/health")


def test_close_leaves_injected_client_open() -> None:
    client = make_sync_client(lambda r: json_response({}))
    zb = ZigBase("http://localhost:8090", http_client=client)

    zb.close()

    assert client.is_closed is False
    # the client itself is still usable.
    response = client.get("http://localhost:8090/api/health")
    assert response.status_code == 200


def test_context_manager_closes_self_created_client() -> None:
    with ZigBase("http://127.0.0.1:65535") as zb:
        pass

    with pytest.raises(RuntimeError):
        zb.raw_request("GET", "/api/health")


def test_context_manager_leaves_injected_client_open() -> None:
    client = make_sync_client(lambda r: json_response({}))

    with ZigBase("http://localhost:8090", http_client=client):
        pass

    assert client.is_closed is False


def test_close_is_idempotent() -> None:
    zb = ZigBase("http://127.0.0.1:65535")
    zb.close()
    zb.close()  # must not raise


# =====================================================================
# AsyncZigBase
# =====================================================================


async def test_async_base_url_is_normalized() -> None:
    zb = AsyncZigBase(
        "http://localhost:8090///", http_client=make_async_client(lambda r: json_response({}))
    )
    assert zb.base_url == "http://localhost:8090"
    await zb.aclose()


async def test_async_collection_returns_service_bound_to_name() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response({"id": "rec1", "collectionName": "posts"})

    zb = AsyncZigBase("http://localhost:8090", http_client=make_async_client(handler))
    svc = zb.collection("posts")

    assert isinstance(svc, AsyncCollectionService)
    assert svc.name == "posts"

    await svc.get_one("rec1")
    assert requests[0].url.path == "/api/collections/posts/records/rec1"
    await zb.aclose()


async def test_async_service_attributes_are_correct_types() -> None:
    zb = AsyncZigBase(
        "http://localhost:8090", http_client=make_async_client(lambda r: json_response({}))
    )

    assert isinstance(zb.files, AsyncFilesService)
    assert isinstance(zb.accounts, AsyncAccountsService)
    assert isinstance(zb.analytics, AsyncAnalyticsService)
    assert isinstance(zb.senders, AsyncSendersService)
    await zb.aclose()


async def test_async_health_gets_api_health() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/health"
        return json_response({"status": "ok"})

    zb = AsyncZigBase("http://localhost:8090", http_client=make_async_client(handler))

    result = await zb.health()

    assert result == {"status": "ok"}
    await zb.aclose()


async def test_async_with_account_sends_header_only_on_sibling() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response({})

    zb = AsyncZigBase("http://localhost:8090", http_client=make_async_client(handler))
    sibling = zb.with_account("acct-1")

    await zb.send("GET", "/api/x")
    await sibling.send("GET", "/api/y")

    assert "x-account-id" not in requests[0].headers
    assert requests[1].headers["x-account-id"] == "acct-1"
    await zb.aclose()


async def test_async_aclose_closes_self_created_client() -> None:
    zb = AsyncZigBase("http://127.0.0.1:65535")

    await zb.aclose()

    with pytest.raises(RuntimeError):
        await zb.raw_request("GET", "/api/health")


async def test_async_aclose_leaves_injected_client_open() -> None:
    client = make_async_client(lambda r: json_response({}))
    zb = AsyncZigBase("http://localhost:8090", http_client=client)

    await zb.aclose()

    assert client.is_closed is False


async def test_async_context_manager_closes_self_created_client() -> None:
    async with AsyncZigBase("http://127.0.0.1:65535") as zb:
        pass

    with pytest.raises(RuntimeError):
        await zb.raw_request("GET", "/api/health")


async def test_async_context_manager_leaves_injected_client_open() -> None:
    client = make_async_client(lambda r: json_response({}))

    async with AsyncZigBase("http://localhost:8090", http_client=client):
        pass

    assert client.is_closed is False
