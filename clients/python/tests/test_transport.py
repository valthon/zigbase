"""Tests for `zigbase._request` and `zigbase._transport.SyncTransport`.

Mirrors clients/typescript/test/transport.test.ts and
clients/typescript/test/transport-retry.test.ts -- one test per numbered
rule in the task-6 brief's behavior contract, plus the brief's explicitly
required scenarios (single-flight concurrency, refresh-401 propagation, 429
exhaustion, non-idempotent-method 429 skip).
"""

from __future__ import annotations

import json
import threading
from collections.abc import Callable

import httpx
import pytest

from zigbase import _transport
from zigbase._request import RequestSpec, encode_path_segment, ensure_object_body, require_str_field
from zigbase._transport import SyncTransport
from zigbase.auth_store import MemoryAuthStore
from zigbase.errors import ZigbaseError

Handler = Callable[[httpx.Request], httpx.Response]


def make_transport(
    handler: Handler,
    *,
    auth_store: MemoryAuthStore | None = None,
    auth_collection: str | None = None,
    auto_refresh: bool = False,
    account_id: str | None = None,
    lang: str | None = None,
    max_retries: int = 3,
) -> SyncTransport:
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return SyncTransport(
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


# --- _request.py -------------------------------------------------------------


def test_encode_path_segment_escapes_slash_and_special_chars() -> None:
    assert encode_path_segment("a/b c") == "a%2Fb%20c"
    assert encode_path_segment("plain") == "plain"


def test_ensure_object_body_passes_through_a_dict() -> None:
    body = {"a": 1}
    assert ensure_object_body(body, context="x") is body


@pytest.mark.parametrize("body", [None, [], "str", 1, True])
def test_ensure_object_body_raises_status_0_on_non_dict(body: object) -> None:
    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        ensure_object_body(body, context="get_one")
    assert excinfo.value.status == 0
    assert "get_one" in excinfo.value.message


def test_require_str_field_returns_the_string() -> None:
    assert require_str_field({"token": "tok1"}, "token", context="x") == "tok1"


def test_require_str_field_accepts_an_empty_string() -> None:
    assert require_str_field({"token": ""}, "token", context="x") == ""


def test_require_str_field_raises_status_0_when_key_is_missing() -> None:
    with pytest.raises(ZigbaseError, match="'token'") as excinfo:
        require_str_field({}, "token", context="get_one")
    assert excinfo.value.status == 0
    assert "get_one" in excinfo.value.message


@pytest.mark.parametrize("value", [None, 1, True, [], {}])
def test_require_str_field_raises_status_0_when_value_is_not_a_string(value: object) -> None:
    with pytest.raises(ZigbaseError, match="'token'") as excinfo:
        require_str_field({"token": value}, "token", context="get_one")
    assert excinfo.value.status == 0


def test_request_spec_defaults() -> None:
    spec = RequestSpec(method="GET", path="/api/health")
    assert spec.query is None
    assert spec.body is None
    assert spec.skip_auth is False
    assert spec.is_refresh is False
    assert spec.headers is None
    assert spec.timeout is None


# --- Rule 1: header assembly --------------------------------------------------


def test_header_assembly_authorization_lang_account_id() -> None:
    store = MemoryAuthStore()
    store.save("tok.tok.tok", {"id": "u1"})
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler, auth_store=store, account_id="acct-1", lang="fr")
    transport.request(RequestSpec(method="GET", path="/api/x"))

    assert seen["authorization"] == "Bearer tok.tok.tok"
    assert seen["accept-language"] == "fr"
    assert seen["x-account-id"] == "acct-1"


def test_header_assembly_skip_auth_omits_authorization() -> None:
    store = MemoryAuthStore()
    store.save("tok.tok.tok", {"id": "u1"})
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler, auth_store=store)
    transport.request(RequestSpec(method="GET", path="/api/x", skip_auth=True))

    assert "authorization" not in seen


def test_header_assembly_no_token_omits_authorization() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler)
    transport.request(RequestSpec(method="GET", path="/api/x"))

    assert "authorization" not in seen


def test_header_assembly_spec_headers_win_over_account_id() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler, account_id="configured-acct")
    transport.request(
        RequestSpec(method="GET", path="/api/x", headers={"X-Account-Id": "explicit-acct"})
    )

    assert seen["x-account-id"] == "explicit-acct"


def test_header_assembly_custom_headers_pass_through() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler)
    transport.request(RequestSpec(method="GET", path="/api/x", headers={"X-Custom": "value"}))

    assert seen["x-custom"] == "value"


def test_header_assembly_authorization_and_lang_overwrite_spec_headers() -> None:
    # Unlike X-Account-Id, a spec-supplied Authorization/Accept-Language does
    # NOT win -- the transport's own token/lang always take over, matching
    # transport.ts's `Headers.set` (which unconditionally overwrites) rather
    # than the `X-Account-Id` presence check.
    store = MemoryAuthStore()
    store.save("tok.tok.tok", {"id": "u1"})
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"ok": True})

    transport = make_transport(handler, auth_store=store, lang="fr")
    transport.request(
        RequestSpec(
            method="GET",
            path="/api/x",
            headers={"Authorization": "Bearer stale-caller-supplied", "Accept-Language": "de"},
        )
    )

    assert seen["authorization"] == "Bearer tok.tok.tok"
    assert seen["accept-language"] == "fr"


# --- Rule 2: 2xx decoding -----------------------------------------------------


def test_204_returns_none() -> None:
    transport = make_transport(lambda r: httpx.Response(204))
    assert transport.request(RequestSpec(method="DELETE", path="/api/x")) is None


def test_200_empty_body_returns_none() -> None:
    transport = make_transport(lambda r: httpx.Response(200, content=b""))
    assert transport.request(RequestSpec(method="GET", path="/api/x")) is None


def test_200_json_body_parses() -> None:
    transport = make_transport(lambda r: json_response({"page": 2, "items": []}))
    out = transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"page": 2, "items": []}


# --- Rule 3: non-2xx raises ---------------------------------------------------


def test_non_2xx_raises_zigbase_error() -> None:
    transport = make_transport(
        lambda r: json_response({"message": "Nope.", "data": {}}, status=403)
    )
    with pytest.raises(ZigbaseError) as exc_info:
        transport.request(RequestSpec(method="GET", path="/api/x"))
    err = exc_info.value
    assert err.status == 403
    assert err.message == "Nope."
    assert err.url.endswith("/api/x")


# --- Rule 4: 429 backoff -------------------------------------------------------


def test_429_retry_after_header_honored_verbatim(monkeypatch: pytest.MonkeyPatch) -> None:
    delays: list[float] = []
    monkeypatch.setattr(_transport, "_sleep", delays.append)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            return json_response({"message": "slow"}, status=429, headers={"Retry-After": "5"})
        return json_response({"ok": True})

    transport = make_transport(handler)
    out = transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"ok": True}
    assert delays == [5.0]


def test_429_exponential_backoff_when_no_retry_after(monkeypatch: pytest.MonkeyPatch) -> None:
    delays: list[float] = []
    monkeypatch.setattr(_transport, "_sleep", delays.append)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] <= 3:
            return json_response({"message": "slow"}, status=429)
        return json_response({"ok": True})

    transport = make_transport(handler, max_retries=5)
    out = transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"ok": True}
    assert delays == [0.2, 0.4, 0.8]


def test_429_backoff_capped_at_30_seconds(monkeypatch: pytest.MonkeyPatch) -> None:
    delays: list[float] = []
    monkeypatch.setattr(_transport, "_sleep", delays.append)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] <= 20:
            return json_response({"message": "slow"}, status=429)
        return json_response({"ok": True})

    transport = make_transport(handler, max_retries=20)
    transport.request(RequestSpec(method="GET", path="/api/x"))
    assert max(delays) <= 30.0
    assert 30.0 in delays


def test_429_retried_up_to_max_retries_then_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    delays: list[float] = []
    monkeypatch.setattr(_transport, "_sleep", delays.append)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "slow"}, status=429, headers={"Retry-After": "0"})

    transport = make_transport(handler, max_retries=3)
    with pytest.raises(ZigbaseError) as exc_info:
        transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 429
    # initial attempt + 3 retries = 4 calls total
    assert calls["n"] == 4
    assert len(delays) == 3


def test_429_retried_for_patch(monkeypatch: pytest.MonkeyPatch) -> None:
    # A 429 is a rejection before processing -- it cannot have caused a
    # partial write, so retrying a non-idempotent method is safe. Matches
    # transport.ts/transport.dart, which retry a 429 for any method.
    delays: list[float] = []
    monkeypatch.setattr(_transport, "_sleep", delays.append)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            return json_response({"message": "slow"}, status=429, headers={"Retry-After": "0"})
        return json_response({"ok": True}, status=200)

    transport = make_transport(handler, max_retries=3)
    out = transport.request(RequestSpec(method="PATCH", path="/api/x", body={"a": 1}))
    assert out == {"ok": True}
    assert calls["n"] == 2
    # Retry-After: 0 is not honored verbatim (not > 0); falls back to the
    # first exponential step.
    assert delays == [0.2]


@pytest.mark.parametrize("method", ["GET", "HEAD", "DELETE", "PATCH", "POST", "PUT"])
def test_429_retried_for_any_method(monkeypatch: pytest.MonkeyPatch, method: str) -> None:
    monkeypatch.setattr(_transport, "_sleep", lambda _d: None)
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            return json_response({"message": "slow"}, status=429, headers={"Retry-After": "0"})
        return httpx.Response(204) if method != "GET" else json_response({"ok": True})

    transport = make_transport(handler, max_retries=1)
    transport.request(RequestSpec(method=method, path="/api/x"))
    assert calls["n"] == 2


# --- Rule 5: single-flight 401 refresh -----------------------------------------


def test_401_without_auto_refresh_propagates() -> None:
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
        transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 401
    assert calls["n"] == 1


def test_401_without_auth_collection_propagates() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "expired"}, status=401)

    store = MemoryAuthStore()
    store.save("tok", {"id": "u1"})
    transport = make_transport(handler, auth_store=store, auto_refresh=True, auth_collection=None)
    with pytest.raises(ZigbaseError):
        transport.request(RequestSpec(method="GET", path="/api/x"))
    assert calls["n"] == 1


def test_401_without_token_propagates() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "expired"}, status=401)

    transport = make_transport(handler, auto_refresh=True, auth_collection="users")
    with pytest.raises(ZigbaseError):
        transport.request(RequestSpec(method="GET", path="/api/x"))
    assert calls["n"] == 1


def test_401_marked_is_refresh_propagates_no_recursion() -> None:
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
        transport.request(
            RequestSpec(method="POST", path="/api/collections/users/auth-refresh", is_refresh=True)
        )
    assert calls["n"] == 1


def test_401_one_shot_refresh_then_retries() -> None:
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
    out = transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"ok": True}
    assert calls == ["x", "refresh", "x"]
    assert store.token == "new.tok"


def test_401_refresh_endpoint_itself_401s_propagates_original(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The refresh call's own 401 must propagate without recursing, and the
    # ORIGINAL request's 401 error is what the caller sees (not a second one).
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
        transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 401
    assert exc_info.value.message == "original expired"
    assert calls["refresh"] == 1
    assert calls["x"] == 1  # no retry after a failed refresh


def test_401_refresh_failure_propagates_original_401() -> None:
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
        transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 401
    assert exc_info.value.message == "original expired"
    assert calls["x"] == 1


def test_401_refresh_empty_body_propagates_original_401_and_preserves_store() -> None:
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
        transport.request(RequestSpec(method="GET", path="/api/x"))
    assert exc_info.value.status == 401
    assert exc_info.value.message == "original expired"
    assert calls["refresh"] == 1
    assert calls["x"] == 1
    assert store.token == "tok"
    assert store.record == {"id": "u1"}


def test_401_refresh_body_missing_token_clears_store() -> None:
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
    out = transport.request(RequestSpec(method="GET", path="/api/x"))
    assert out == {"ok": True}
    assert calls == ["x", "refresh", "x"]
    assert store.token is None
    assert store.record is None


def test_401_single_flight_concurrent_refresh_exactly_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Two threads hitting 401 simultaneously must trigger exactly one
    refresh call; both retries succeed afterwards.

    Determinism note: releasing the refresh response as soon as the owner
    thread has *started* it is not enough -- the other thread still has to
    reach `_await_refresh` and observe the in-flight flight before the owner
    clears it, and that race flaked in practice. So instead we wrap
    `SyncTransport._await_refresh` (whitebox, like the `transport._client`
    access above) to count entries and signal once BOTH threads have called
    it. Since the owner is provably still blocked inside its network call at
    that point (we haven't released `refresh_gate` yet), the second thread is
    guaranteed to see the still-set flight and join it rather than starting
    its own -- a structural guarantee, not a timing heuristic.
    """
    lock = threading.Lock()
    calls = {"a": 0, "b": 0, "refresh": 0}
    refresh_gate = threading.Event()
    refreshed = threading.Event()

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path.endswith("auth-refresh"):
            with lock:
                calls["refresh"] += 1
            refresh_gate.wait(timeout=5)
            refreshed.set()
            return json_response({"token": "fresh.tok", "record": {"id": "u1"}})

        key = "a" if path.endswith("/a") else "b"
        with lock:
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
    both_entered = threading.Event()
    original_await_refresh = SyncTransport._await_refresh

    def instrumented_await_refresh(self: SyncTransport) -> None:
        with lock:
            entered["n"] += 1
            if entered["n"] == 2:
                both_entered.set()
        original_await_refresh(self)

    monkeypatch.setattr(SyncTransport, "_await_refresh", instrumented_await_refresh)

    results: list[object] = [None, None]
    errors: list[BaseException | None] = [None, None]

    def worker(idx: int, path: str) -> None:
        try:
            results[idx] = transport.request(RequestSpec(method="GET", path=path))
        except BaseException as exc:  # captured for the assertion below
            errors[idx] = exc

    t1 = threading.Thread(target=worker, args=(0, "/api/a"))
    t2 = threading.Thread(target=worker, args=(1, "/api/b"))
    t1.start()
    t2.start()

    assert both_entered.wait(timeout=5), "both threads never joined the refresh"
    refresh_gate.set()
    t1.join(timeout=5)
    t2.join(timeout=5)

    assert errors == [None, None]
    assert results == [{"ok": True}, {"ok": True}]
    assert calls["refresh"] == 1


# --- Rule 6: multipart ----------------------------------------------------------


def test_multipart_uses_data_and_files_without_manual_content_type() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["content_type"] = request.headers.get("content-type", "")
        seen["body"] = request.content
        return json_response({"id": "1"}, status=201)

    transport = make_transport(handler)
    out = transport.request(
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


def test_json_body_sets_content_type_application_json() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["content_type"] = request.headers.get("content-type", "")
        seen["body"] = json.loads(request.content)
        return json_response({"id": "1"}, status=201)

    transport = make_transport(handler)
    transport.request(RequestSpec(method="POST", path="/api/x", body={"title": "hi"}))
    assert seen["content_type"] == "application/json"
    assert seen["body"] == {"title": "hi"}


def test_get_drops_body() -> None:
    # transport.ts (buildRequestInit) and transport.dart (_maybeBufferMultipart
    # / _perform) both only attach a body for a non-GET method; a GET's body
    # is dropped even if the caller supplied one.
    seen: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["content_type"] = request.headers.get("content-type")
        seen["content"] = request.content
        return json_response({"ok": True})

    transport = make_transport(handler)
    out = transport.request(RequestSpec(method="GET", path="/api/x", body={"ignored": "value"}))
    assert out == {"ok": True}
    assert seen["content_type"] is None
    assert seen["content"] == b""


# --- Rule 7: network errors propagate natively -----------------------------------


def test_network_error_propagates_natively() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("boom", request=request)

    transport = make_transport(handler)
    with pytest.raises(httpx.ConnectError):
        transport.request(RequestSpec(method="GET", path="/api/x"))


# --- raw_request: no error mapping, no retry -------------------------------------


def test_raw_request_returns_response_without_raising_or_retrying() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return json_response({"message": "slow"}, status=429, headers={"Retry-After": "0"})

    transport = make_transport(handler)
    response = transport.raw_request(RequestSpec(method="GET", path="/api/x"))
    assert response.status_code == 429
    assert calls["n"] == 1


# --- close() -----------------------------------------------------------------------


def test_close_closes_self_created_client() -> None:
    store = MemoryAuthStore()
    transport = SyncTransport("http://api.test", store)
    client = transport._client  # whitebox check that ownership tracking works
    assert client.is_closed is False
    transport.close()
    assert client.is_closed is True


def test_close_does_not_close_caller_provided_client() -> None:
    client = httpx.Client(transport=httpx.MockTransport(lambda r: json_response({"ok": True})))
    store = MemoryAuthStore()
    transport = SyncTransport("http://api.test", store, http_client=client)
    transport.close()
    assert client.is_closed is False
    client.close()
