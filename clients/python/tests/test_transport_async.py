"""Tests for `zigbase._transport.AsyncTransport`.

Mirrors test_transport.py's `SyncTransport` cases one-for-one (same rules,
same scenarios) with the async substitutions: `httpx.AsyncClient` +
`httpx.MockTransport`, `asyncio.gather` for the single-flight concurrency
case instead of `threading.Thread`, and `_transport._asleep` instead of
`_transport._sleep` for backoff.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Awaitable, Callable

import httpx
import pytest

from zigbase import _transport
from zigbase._request import RequestSpec
from zigbase._transport import AsyncTransport
from zigbase.auth_store import MemoryAuthStore
from zigbase.errors import ZigbaseError

Handler = (
    Callable[[httpx.Request], httpx.Response] | Callable[[httpx.Request], Awaitable[httpx.Response]]
)


def make_transport(
    handler: Handler,
    *,
    auth_store: MemoryAuthStore | None = None,
    auth_collection: str | None = None,
    auto_refresh: bool = False,
    account_id: str | None = None,
    lang: str | None = None,
    max_retries: int = 3,
) -> AsyncTransport:
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return AsyncTransport(
        "http://api.test",
        auth_store or MemoryAuthStore(),
        auth_collection=auth_collection,
        auto_refresh=auto_refresh,
        account_id=account_id,
        lang=lang,
        max_retries=max_retries,
        http_client=client,
    )


def json_response(
    body: object, status: int = 200, headers: dict[str, str] | None = None
) -> httpx.Response:
    return httpx.Response(status, json=body, headers=headers)


# --- Rule 1: header assembly --------------------------------------------------


async def test_header_assembly_authorization_lang_account_id() -> None:
    store = MemoryAuthStore()
    store.save("tok.tok.tok", {"id": "u1"})
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler, auth_store=store, account_id="acct-1", lang="fr")
    await transport.request(RequestSpec(method="GET", path="/api/x"))

    assert seen["authorization"] == "Bearer tok.tok.tok"
    assert seen["accept-language"] == "fr"
    assert seen["x-account-id"] == "acct-1"


async def test_header_assembly_skip_auth_omits_authorization() -> None:
    store = MemoryAuthStore()
    store.save("tok.tok.tok", {"id": "u1"})
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler, auth_store=store)
    await transport.request(RequestSpec(method="GET", path="/api/x", skip_auth=True))

    assert "authorization" not in seen


async def test_header_assembly_no_token_omits_authorization() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler)
    await transport.request(RequestSpec(method="GET", path="/api/x"))

    assert "authorization" not in seen


async def test_header_assembly_spec_headers_win_over_account_id() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler, account_id="configured-acct")
    await transport.request(
        RequestSpec(method="GET", path="/api/x", headers={"X-Account-Id": "explicit-acct"})
    )

    assert seen["x-account-id"] == "explicit-acct"


async def test_header_assembly_custom_headers_pass_through() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler)
    await transport.request(RequestSpec(method="GET", path="/api/x", headers={"X-Custom": "value"}))

    assert seen["x-custom"] == "value"


async def test_header_assembly_authorization_and_lang_overwrite_spec_headers() -> None:
    store = MemoryAuthStore()
    store.save("tok.tok.tok", {"id": "u1"})
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler, auth_store=store, lang="fr")
    await transport.request(
        RequestSpec(
            method="GET",
            path="/api/x",
            headers={"Authorization": "Bearer stale-caller-supplied", "Accept-Language": "de"},
        )
    )

    assert seen["authorization"] == "Bearer tok.tok.tok"
    assert seen["accept-language"] == "fr"


# --- Rule 2: 2xx decoding -----------------------------------------------------


async def test_204_returns_none() -> None:
    transport = make_transport(lambda r: httpx.Response(204))
    assert await transport.request(RequestSpec(method="DELETE", path="/api/x")) is None


async def test_200_empty_body_returns_none() -> None:
    transport = make_transport(lambda r: httpx.Response(200, content=b""))
    assert await transport.request(RequestSpec(method="GET", path="/api/x")) is None


async def test_200_json_body_parses() -> None:
    transport = make_transport(lambda r: json_response({"page": 2, "items": []}))
    out = await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"page": 2, "items": []}


# --- Rule 3: non-2xx raises ---------------------------------------------------


async def test_non_2xx_raises_zigbase_error() -> None:
    transport = make_transport(
        lambda r: json_response({"message": "Nope.", "data": {}}, status=403)
    )
    with pytest.raises(ZigbaseError) as exc_info:
        await transport.request(RequestSpec(method="GET", path="/api/x"))
    err = exc_info.value
    assert err.status == 403
    assert err.message == "Nope."
    assert err.url.endswith("/api/x")


# --- Rule 4: 429 backoff -------------------------------------------------------


async def test_429_retry_after_header_honored_verbatim(monkeypatch: pytest.MonkeyPatch) -> None:
    delays: list[float] = []

    async def fake_sleep(seconds: float) -> None:
        delays.append(seconds)

    monkeypatch.setattr(_transport, "_asleep", fake_sleep)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            return json_response({"message": "slow"}, status=429, headers={"Retry-After": "5"})
        return json_response({"ok": True})

    transport = make_transport(handler)
    out = await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"ok": True}
    assert delays == [5.0]


async def test_429_exponential_backoff_when_no_retry_after(monkeypatch: pytest.MonkeyPatch) -> None:
    delays: list[float] = []

    async def fake_sleep(seconds: float) -> None:
        delays.append(seconds)

    monkeypatch.setattr(_transport, "_asleep", fake_sleep)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] <= 3:
            return json_response({"message": "slow"}, status=429)
        return json_response({"ok": True})

    transport = make_transport(handler, max_retries=5)
    out = await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"ok": True}
    assert delays == [0.2, 0.4, 0.8]


async def test_429_backoff_capped_at_30_seconds(monkeypatch: pytest.MonkeyPatch) -> None:
    delays: list[float] = []

    async def fake_sleep(seconds: float) -> None:
        delays.append(seconds)

    monkeypatch.setattr(_transport, "_asleep", fake_sleep)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] <= 20:
            return json_response({"message": "slow"}, status=429)
        return json_response({"ok": True})

    transport = make_transport(handler, max_retries=20)
    await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert max(delays) <= 30.0
    assert 30.0 in delays


async def test_429_retried_up_to_max_retries_then_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    delays: list[float] = []

    async def fake_sleep(seconds: float) -> None:
        delays.append(seconds)

    monkeypatch.setattr(_transport, "_asleep", fake_sleep)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "slow"}, status=429, headers={"Retry-After": "0"})

    transport = make_transport(handler, max_retries=3)
    with pytest.raises(ZigbaseError) as exc_info:
        await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 429
    assert calls["n"] == 4
    assert len(delays) == 3


async def test_429_retried_for_patch(monkeypatch: pytest.MonkeyPatch) -> None:
    delays: list[float] = []

    async def fake_sleep(seconds: float) -> None:
        delays.append(seconds)

    monkeypatch.setattr(_transport, "_asleep", fake_sleep)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            return json_response({"message": "slow"}, status=429, headers={"Retry-After": "0"})
        return json_response({"ok": True}, status=200)

    transport = make_transport(handler, max_retries=3)
    out = await transport.request(RequestSpec(method="PATCH", path="/api/x", body={"a": 1}))
    assert out == {"ok": True}
    assert calls["n"] == 2
    assert delays == [0.2]


@pytest.mark.parametrize("method", ["GET", "HEAD", "DELETE", "PATCH", "POST", "PUT"])
async def test_429_retried_for_any_method(monkeypatch: pytest.MonkeyPatch, method: str) -> None:
    async def fake_sleep(seconds: float) -> None:
        return None

    monkeypatch.setattr(_transport, "_asleep", fake_sleep)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            return json_response({"message": "slow"}, status=429, headers={"Retry-After": "0"})
        return httpx.Response(204) if method != "GET" else json_response({"ok": True})

    transport = make_transport(handler, max_retries=1)
    await transport.request(RequestSpec(method=method, path="/api/x"))
    assert calls["n"] == 2


# --- Rule 5: single-flight 401 refresh -----------------------------------------


async def test_401_without_auto_refresh_propagates() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "expired"}, status=401)

    store = MemoryAuthStore()
    store.save("tok", {"id": "u1"})
    transport = make_transport(
        handler, auth_store=store, auto_refresh=False, auth_collection="users"
    )
    with pytest.raises(ZigbaseError) as exc_info:
        await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 401
    assert calls["n"] == 1


async def test_401_without_auth_collection_propagates() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "expired"}, status=401)

    store = MemoryAuthStore()
    store.save("tok", {"id": "u1"})
    transport = make_transport(handler, auth_store=store, auto_refresh=True, auth_collection=None)
    with pytest.raises(ZigbaseError):
        await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert calls["n"] == 1


async def test_401_without_token_propagates() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "expired"}, status=401)

    transport = make_transport(handler, auto_refresh=True, auth_collection="users")
    with pytest.raises(ZigbaseError):
        await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert calls["n"] == 1


async def test_401_marked_is_refresh_propagates_no_recursion() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "expired"}, status=401)

    store = MemoryAuthStore()
    store.save("tok", {"id": "u1"})
    transport = make_transport(
        handler, auth_store=store, auto_refresh=True, auth_collection="users"
    )
    with pytest.raises(ZigbaseError):
        await transport.request(
            RequestSpec(method="POST", path="/api/collections/users/auth-refresh", is_refresh=True)
        )
    assert calls["n"] == 1


async def test_401_one_shot_refresh_then_retries() -> None:
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("auth-refresh"):
            calls.append("refresh")
            return json_response({"token": "new.tok", "record": {"id": "u1"}})
        calls.append("x")
        if calls.count("x") == 1:
            return json_response({"message": "expired"}, status=401)
        return json_response({"ok": True})

    store = MemoryAuthStore()
    store.save("old.tok", {"id": "u1"})
    transport = make_transport(
        handler, auth_store=store, auto_refresh=True, auth_collection="users"
    )
    out = await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"ok": True}
    assert calls == ["x", "refresh", "x"]
    assert store.token == "new.tok"


async def test_401_refresh_endpoint_itself_401s_propagates_original() -> None:
    calls = {"x": 0, "refresh": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("auth-refresh"):
            calls["refresh"] += 1
            return json_response({"message": "refresh expired"}, status=401)
        calls["x"] += 1
        return json_response({"message": "original expired"}, status=401)

    store = MemoryAuthStore()
    store.save("tok", {"id": "u1"})
    transport = make_transport(
        handler, auth_store=store, auto_refresh=True, auth_collection="users"
    )
    with pytest.raises(ZigbaseError) as exc_info:
        await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 401
    assert exc_info.value.message == "original expired"
    assert calls["refresh"] == 1
    assert calls["x"] == 1


async def test_401_refresh_failure_propagates_original_401() -> None:
    calls = {"x": 0, "refresh": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("auth-refresh"):
            calls["refresh"] += 1
            return json_response({"message": "bad refresh request"}, status=400)
        calls["x"] += 1
        return json_response({"message": "original expired"}, status=401)

    store = MemoryAuthStore()
    store.save("tok", {"id": "u1"})
    transport = make_transport(
        handler, auth_store=store, auto_refresh=True, auth_collection="users"
    )
    with pytest.raises(ZigbaseError) as exc_info:
        await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 401
    assert exc_info.value.message == "original expired"
    assert calls["x"] == 1


async def test_401_refresh_empty_body_propagates_original_401_and_preserves_store() -> None:
    """A 2xx `auth-refresh` response with an EMPTY body (204, or 200 with no
    text) mirrors transport.ts: accessing `.token` on the resulting
    `undefined` throws there, failing the refresh without ever calling
    `authStore.save` -- so the ORIGINAL request's 401 propagates and the
    previously-stored token/record survive untouched (not overwritten with
    `None`)."""
    calls = {"x": 0, "refresh": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("auth-refresh"):
            calls["refresh"] += 1
            return httpx.Response(204)
        calls["x"] += 1
        return json_response({"message": "original expired"}, status=401)

    store = MemoryAuthStore()
    store.save("tok", {"id": "u1"})
    transport = make_transport(
        handler, auth_store=store, auto_refresh=True, auth_collection="users"
    )
    with pytest.raises(ZigbaseError) as exc_info:
        await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 401
    assert exc_info.value.message == "original expired"
    assert calls["refresh"] == 1
    assert calls["x"] == 1
    assert store.token == "tok"
    assert store.record == {"id": "u1"}


async def test_401_refresh_body_missing_token_clears_store() -> None:
    """A 2xx `auth-refresh` body that parses but has no "token" key (a dict
    missing it, here) mirrors transport.ts's `res.token` resolving to
    `undefined` WITHOUT throwing (property access on a real object doesn't
    throw) -- so the refresh "succeeds" and the store is saved with
    `(None, None)`, and the retried request proceeds unauthenticated."""
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("auth-refresh"):
            calls.append("refresh")
            return json_response({"unexpected": "shape"})
        calls.append("x")
        if calls.count("x") == 1:
            return json_response({"message": "expired"}, status=401)
        return json_response({"ok": True})

    store = MemoryAuthStore()
    store.save("old.tok", {"id": "u1"})
    transport = make_transport(
        handler, auth_store=store, auto_refresh=True, auth_collection="users"
    )
    out = await transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"ok": True}
    assert calls == ["x", "refresh", "x"]
    assert store.token is None
    assert store.record is None


async def test_401_single_flight_concurrent_refresh_exactly_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Two concurrent 401-triggering requests must trigger exactly one
    refresh call; both retries succeed afterwards.

    Deterministic overlap, mirroring the sync test's whitebox approach: we
    wrap `AsyncTransport._await_refresh` to count entries and only release
    the mock refresh handler once BOTH coroutines have called it. Since the
    owner is provably still awaiting inside the refresh network call at that
    point (the refresh handler is blocked on `refresh_gate`), the second
    coroutine is guaranteed to see the still-set flight and join it rather
    than starting its own.
    """
    calls = {"a": 0, "b": 0, "refresh": 0}
    refresh_gate = asyncio.Event()
    refreshed = asyncio.Event()

    async def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path.endswith("auth-refresh"):
            calls["refresh"] += 1
            await asyncio.wait_for(refresh_gate.wait(), timeout=5)
            refreshed.set()
            return json_response({"token": "fresh.tok", "record": {"id": "u1"}})

        key = "a" if path.endswith("/a") else "b"
        calls[key] += 1
        if refreshed.is_set():
            return json_response({"ok": True})
        return json_response({"message": "expired"}, status=401)

    store = MemoryAuthStore()
    store.save("stale.tok", {"id": "u1"})
    transport = make_transport(
        handler, auth_store=store, auto_refresh=True, auth_collection="users"
    )

    entered = {"n": 0}
    both_entered = asyncio.Event()
    original_await_refresh = AsyncTransport._await_refresh

    async def instrumented_await_refresh(self: AsyncTransport) -> None:
        entered["n"] += 1
        if entered["n"] == 2:
            both_entered.set()
        await original_await_refresh(self)

    monkeypatch.setattr(AsyncTransport, "_await_refresh", instrumented_await_refresh)

    async def worker(path: str) -> object:
        return await transport.request(RequestSpec(method="GET", path=path))

    task_a = asyncio.create_task(worker("/api/a"))
    task_b = asyncio.create_task(worker("/api/b"))

    await asyncio.wait_for(both_entered.wait(), timeout=5)
    refresh_gate.set()

    results = await asyncio.gather(task_a, task_b)

    assert results == [{"ok": True}, {"ok": True}]
    assert calls["refresh"] == 1


# --- Rule 6: multipart ----------------------------------------------------------


async def test_multipart_uses_data_and_files_without_manual_content_type() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["content_type"] = request.headers.get("content-type", "")
        seen["body"] = request.content
        return json_response({"id": "1"}, status=201)

    transport = make_transport(handler)
    out = await transport.request(
        RequestSpec(
            method="POST",
            path="/api/collections/posts/records",
            body={"title": "hi", "file": ("a.txt", b"hello", "text/plain")},
        )
    )
    assert out == {"id": "1"}
    content_type = str(seen["content_type"])
    assert content_type.startswith("multipart/form-data")
    body = seen["body"]
    assert isinstance(body, bytes)
    assert b'name="title"' in body
    assert b'filename="a.txt"' in body
    assert b"hello" in body


async def test_json_body_sets_content_type_application_json() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["content_type"] = request.headers.get("content-type", "")
        seen["body"] = json.loads(request.content)
        return json_response({"id": "1"}, status=201)

    transport = make_transport(handler)
    await transport.request(RequestSpec(method="POST", path="/api/x", body={"title": "hi"}))
    assert seen["content_type"] == "application/json"
    assert seen["body"] == {"title": "hi"}


async def test_get_drops_body() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["content_type"] = request.headers.get("content-type")
        seen["content"] = request.content
        return json_response({"ok": True})

    transport = make_transport(handler)
    out = await transport.request(
        RequestSpec(method="GET", path="/api/x", body={"ignored": "value"})
    )
    assert out == {"ok": True}
    assert seen["content_type"] is None
    assert seen["content"] == b""


# --- Rule 7: network errors propagate natively -----------------------------------


async def test_network_error_propagates_natively() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("boom", request=request)

    transport = make_transport(handler)
    with pytest.raises(httpx.ConnectError):
        await transport.request(RequestSpec(method="GET", path="/api/x"))


# --- raw_request: no error mapping, no retry -------------------------------------


async def test_raw_request_returns_response_without_raising_or_retrying() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "slow"}, status=429, headers={"Retry-After": "0"})

    transport = make_transport(handler)
    response = await transport.raw_request(RequestSpec(method="GET", path="/api/x"))
    assert response.status_code == 429
    assert calls["n"] == 1


# --- aclose() -----------------------------------------------------------------------


async def test_aclose_closes_self_created_client() -> None:
    store = MemoryAuthStore()
    transport = AsyncTransport("http://api.test", store)
    client = transport._client  # whitebox check that ownership tracking works
    assert client.is_closed is False
    await transport.aclose()
    assert client.is_closed is True


async def test_aclose_does_not_close_caller_provided_client() -> None:
    client = httpx.AsyncClient(transport=httpx.MockTransport(lambda r: json_response({"ok": True})))
    store = MemoryAuthStore()
    transport = AsyncTransport("http://api.test", store, http_client=client)
    await transport.aclose()
    assert client.is_closed is False
    await client.aclose()
