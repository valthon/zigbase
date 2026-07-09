"""Tests for the auth half of `zigbase.collection`
(`CollectionService`/`AsyncCollectionService`).

Mirrors clients/dart/test/collection_auth_test.dart and the auth half of
clients/typescript/src/collection.ts. Each test drives a fake transport
(`MockTransport`/`AsyncMockTransport` from test_collection.py) that records
the `RequestSpec` it was sent and returns a canned envelope; the transport
also owns a real `MemoryAuthStore` (via `.auth_store`) so save/clear side
effects can be asserted directly.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import pytest

from zigbase._request import RequestSpec
from zigbase.auth_store import MemoryAuthStore
from zigbase.collection import AsyncCollectionService, CollectionService
from zigbase.errors import ZigbaseError

Handler = Callable[[RequestSpec], Any]


class MockTransport:
    """Fake `SyncTransport`: records every spec, dispatches to `handler`,
    and owns a real `MemoryAuthStore` so auth side effects are observable."""

    def __init__(self, handler: Handler, *, auth_store: MemoryAuthStore | None = None) -> None:
        self._handler = handler
        self.calls: list[RequestSpec] = []
        self.auth_store = auth_store if auth_store is not None else MemoryAuthStore()

    def request(self, spec: RequestSpec) -> Any:
        self.calls.append(spec)
        return self._handler(spec)


class AsyncMockTransport:
    """`MockTransport`'s async counterpart, for `AsyncCollectionService`."""

    def __init__(self, handler: Handler, *, auth_store: MemoryAuthStore | None = None) -> None:
        self._handler = handler
        self.calls: list[RequestSpec] = []
        self.auth_store = auth_store if auth_store is not None else MemoryAuthStore()

    async def request(self, spec: RequestSpec) -> Any:
        self.calls.append(spec)
        return self._handler(spec)


def sequence_handler(*bodies: Any) -> Handler:
    it = iter(bodies)

    def handler(_spec: RequestSpec) -> Any:
        return next(it)

    return handler


def error_handler(status: int, message: str) -> Handler:
    def handler(spec: RequestSpec) -> Any:
        raise ZigbaseError(status=status, message=message, url=spec.path)

    return handler


# --- auth_with_password --------------------------------------------------------


def test_auth_with_password_posts_skip_auth_and_saves_token_record() -> None:
    store = MemoryAuthStore()
    store.save("stale-token", {"id": "old"})
    transport = MockTransport(
        sequence_handler({"token": "new-token", "record": {"id": "u1", "email": "a@b.com"}}),
        auth_store=store,
    )
    svc = CollectionService(transport, "users")

    res = svc.auth_with_password("a@b.com", "secret")

    assert len(transport.calls) == 1
    spec = transport.calls[0]
    assert spec.method == "POST"
    assert spec.path == "/api/collections/users/auth-with-password"
    assert spec.body == {"identity": "a@b.com", "password": "secret"}
    assert spec.skip_auth is True

    assert res.token == "new-token"
    assert res.record == {"id": "u1", "email": "a@b.com"}
    assert store.token == "new-token"
    assert store.record == {"id": "u1", "email": "a@b.com"}


async def test_async_auth_with_password_posts_skip_auth_and_saves_token_record() -> None:
    store = MemoryAuthStore()
    transport = AsyncMockTransport(
        sequence_handler({"token": "new-token", "record": {"id": "u1"}}), auth_store=store
    )
    svc = AsyncCollectionService(transport, "users")

    res = await svc.auth_with_password("a@b.com", "secret")

    spec = transport.calls[0]
    assert spec.path == "/api/collections/users/auth-with-password"
    assert spec.skip_auth is True
    assert res.token == "new-token"
    assert store.token == "new-token"


# --- auth_refresh ----------------------------------------------------------------


def test_auth_refresh_posts_empty_body_not_skip_auth_and_saves() -> None:
    transport = MockTransport(sequence_handler({"token": "refreshed", "record": {"id": "u1"}}))
    svc = CollectionService(transport, "users")

    res = svc.auth_refresh()

    spec = transport.calls[0]
    assert spec.method == "POST"
    assert spec.path == "/api/collections/users/auth-refresh"
    assert spec.body == {}
    assert spec.skip_auth is False
    assert spec.is_refresh is True
    assert res.token == "refreshed"
    assert transport.auth_store.token == "refreshed"


# --- list_auth_providers / oauth2_init -------------------------------------------


def test_list_auth_providers_unwraps_items() -> None:
    transport = MockTransport(
        sequence_handler(
            {
                "items": [
                    {"name": "google", "authURL": "https://g/auth", "clientId": "cid"},
                ]
            }
        )
    )
    svc = CollectionService(transport, "users")

    providers = svc.list_auth_providers()

    spec = transport.calls[0]
    assert spec.method == "GET"
    assert spec.path == "/api/collections/users/auth/oauth2/providers"
    assert providers == [{"name": "google", "authURL": "https://g/auth", "clientId": "cid"}]


def test_oauth2_init_posts_provider_and_returns_raw_dict() -> None:
    transport = MockTransport(
        sequence_handler(
            {"authURL": "https://p/auth", "clientId": "cid", "scopes": ["a", "b"], "state": "st"}
        )
    )
    svc = CollectionService(transport, "users")

    res = svc.oauth2_init("google")

    spec = transport.calls[0]
    assert spec.method == "POST"
    assert spec.path == "/api/collections/users/auth/oauth2/initiate"
    assert spec.body == {"provider": "google"}
    assert res == {
        "authURL": "https://p/auth",
        "clientId": "cid",
        "scopes": ["a", "b"],
        "state": "st",
    }


# --- auth_with_oauth2 --------------------------------------------------------------


def test_auth_with_oauth2_posts_exact_body_skip_auth_and_saves_token_only() -> None:
    store = MemoryAuthStore()
    transport = MockTransport(sequence_handler({"token": "oauth-token"}), auth_store=store)
    svc = CollectionService(transport, "users")

    res = svc.auth_with_oauth2(
        provider="google",
        code="c",
        code_verifier="v",
        redirect_url="https://app/cb",
        state="s1",
    )

    spec = transport.calls[0]
    assert spec.method == "POST"
    assert spec.path == "/api/collections/users/auth/oauth2/complete"
    assert spec.body == {
        "provider": "google",
        "code": "c",
        "codeVerifier": "v",
        "redirectUrl": "https://app/cb",
        "state": "s1",
    }
    assert spec.skip_auth is True
    assert res.token == "oauth-token"
    assert res.record is None
    assert store.token == "oauth-token"
    assert store.record is None


def test_auth_with_oauth2_omits_state_when_not_provided() -> None:
    transport = MockTransport(sequence_handler({"token": "t"}))
    svc = CollectionService(transport, "users")

    svc.auth_with_oauth2(
        provider="google", code="c", code_verifier="v", redirect_url="https://app/cb"
    )

    assert "state" not in transport.calls[0].body  # type: ignore[operator]


# --- logout -------------------------------------------------------------------------


def test_logout_posts_and_clears_store() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "u1"})
    transport = MockTransport(sequence_handler(None), auth_store=store)
    svc = CollectionService(transport, "users")

    svc.logout()

    spec = transport.calls[0]
    assert spec.method == "POST"
    assert spec.path == "/api/collections/users/auth-logout"
    assert store.token is None
    assert store.record is None


def test_logout_clears_store_even_when_request_fails() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "u1"})
    transport = MockTransport(error_handler(500, "boom"), auth_store=store)
    svc = CollectionService(transport, "users")

    with pytest.raises(ZigbaseError):
        svc.logout()

    assert store.token is None
    assert store.record is None


async def test_async_logout_clears_store_even_when_request_fails() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "u1"})
    transport = AsyncMockTransport(error_handler(500, "boom"), auth_store=store)
    svc = AsyncCollectionService(transport, "users")

    with pytest.raises(ZigbaseError):
        await svc.logout()

    assert store.token is None
    assert store.record is None


# --- verification / password reset ---------------------------------------------------


def test_request_verification_posts_email_not_skip_auth() -> None:
    transport = MockTransport(sequence_handler(None))
    svc = CollectionService(transport, "users")

    result = svc.request_verification("a@b.com")

    spec = transport.calls[0]
    assert spec.path == "/api/collections/users/request-verification"
    assert spec.body == {"email": "a@b.com"}
    assert spec.skip_auth is False
    assert result is None


def test_confirm_verification_posts_token_skip_auth() -> None:
    transport = MockTransport(sequence_handler(None))
    svc = CollectionService(transport, "users")

    result = svc.confirm_verification("vtok")

    spec = transport.calls[0]
    assert spec.path == "/api/collections/users/confirm-verification"
    assert spec.body == {"token": "vtok"}
    assert spec.skip_auth is True
    assert result is None


def test_request_password_reset_posts_email_not_skip_auth() -> None:
    transport = MockTransport(sequence_handler(None))
    svc = CollectionService(transport, "users")

    svc.request_password_reset("a@b.com")

    spec = transport.calls[0]
    assert spec.path == "/api/collections/users/request-password-reset"
    assert spec.body == {"email": "a@b.com"}
    assert spec.skip_auth is False


def test_confirm_password_reset_posts_token_password_skip_auth() -> None:
    transport = MockTransport(sequence_handler(None))
    svc = CollectionService(transport, "users")

    svc.confirm_password_reset("rtok", "newpass")

    spec = transport.calls[0]
    assert spec.path == "/api/collections/users/confirm-password-reset"
    assert spec.body == {"token": "rtok", "password": "newpass"}
    assert spec.skip_auth is True


# --- change_password ----------------------------------------------------------------


def test_change_password_patches_record_no_reauth_for_non_principal() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "someone-else", "email": "x@y.com"})
    transport = MockTransport(
        sequence_handler({"id": "target", "email": "z@z.com"}), auth_store=store
    )
    svc = CollectionService(transport, "users")

    rec = svc.change_password("target", "oldpw", "newpw")

    assert len(transport.calls) == 1  # no follow-up auth_with_password call
    spec = transport.calls[0]
    assert spec.method == "PATCH"
    assert spec.path == "/api/collections/users/records/target"
    assert spec.body == {"password": "newpw", "oldPassword": "oldpw"}
    assert rec == {"id": "target", "email": "z@z.com"}


def test_change_password_reauths_with_email_identity_when_self() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "target", "email": "z@z.com", "username": "zed"})
    transport = MockTransport(
        sequence_handler(
            {"id": "target", "email": "z@z.com"},  # PATCH response
            {"token": "re-token", "record": {"id": "target", "email": "z@z.com"}},  # re-auth
        ),
        auth_store=store,
    )
    svc = CollectionService(transport, "users")

    rec = svc.change_password("target", "oldpw", "newpw")

    assert len(transport.calls) == 2
    assert transport.calls[0].method == "PATCH"
    assert transport.calls[1].method == "POST"
    assert transport.calls[1].path == "/api/collections/users/auth-with-password"
    assert transport.calls[1].body == {"identity": "z@z.com", "password": "newpw"}
    assert rec == {"id": "target", "email": "z@z.com"}
    assert store.token == "re-token"


def test_change_password_falls_back_to_username_identity() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "target", "username": "zed"})
    transport = MockTransport(
        sequence_handler(
            {"id": "target", "username": "zed"},
            {"token": "re-token", "record": {"id": "target"}},
        ),
        auth_store=store,
    )
    svc = CollectionService(transport, "users")

    svc.change_password("target", "oldpw", "newpw")

    assert len(transport.calls) == 2
    assert transport.calls[1].body == {"identity": "zed", "password": "newpw"}


def test_change_password_no_reauth_when_no_principal_stored() -> None:
    transport = MockTransport(sequence_handler({"id": "target"}))
    svc = CollectionService(transport, "users")

    svc.change_password("target", "oldpw", "newpw")

    assert len(transport.calls) == 1


async def test_async_change_password_reauths_when_self() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "target", "email": "z@z.com"})
    transport = AsyncMockTransport(
        sequence_handler(
            {"id": "target", "email": "z@z.com"},
            {"token": "re-token", "record": {"id": "target", "email": "z@z.com"}},
        ),
        auth_store=store,
    )
    svc = AsyncCollectionService(transport, "users")

    await svc.change_password("target", "oldpw", "newpw")

    assert len(transport.calls) == 2
    assert transport.calls[1].path == "/api/collections/users/auth-with-password"


# --- sessions -------------------------------------------------------------------------


def test_list_sessions_gets_and_unwraps_items_snake_case() -> None:
    transport = MockTransport(
        sequence_handler(
            {
                "items": [
                    {
                        "id": "sid1",
                        "created": "2026-01-01T00:00:00Z",
                        "last_seen": "2026-01-02T00:00:00Z",
                        "user_agent": "ua",
                        "ip": "1.2.3.4",
                        "is_current": True,
                    }
                ]
            }
        )
    )
    svc = CollectionService(transport, "users")

    sessions = svc.list_sessions()

    spec = transport.calls[0]
    assert spec.method == "GET"
    assert spec.path == "/api/collections/users/auth/sessions"
    assert sessions == [
        {
            "id": "sid1",
            "created": "2026-01-01T00:00:00Z",
            "last_seen": "2026-01-02T00:00:00Z",
            "user_agent": "ua",
            "ip": "1.2.3.4",
            "is_current": True,
        }
    ]


def test_revoke_session_deletes_encoded_path() -> None:
    transport = MockTransport(sequence_handler(None))
    svc = CollectionService(transport, "users")

    svc.revoke_session("sid with space")

    spec = transport.calls[0]
    assert spec.method == "DELETE"
    assert spec.path == "/api/collections/users/auth/sessions/sid%20with%20space"


def test_revoke_all_sessions_deletes_and_clears_store_on_success() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "u1"})
    transport = MockTransport(sequence_handler(None), auth_store=store)
    svc = CollectionService(transport, "users")

    svc.revoke_all_sessions()

    spec = transport.calls[0]
    assert spec.method == "DELETE"
    assert spec.path == "/api/collections/users/auth/sessions"
    assert store.token is None


def test_revoke_all_sessions_clears_store_even_on_failure() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "u1"})
    transport = MockTransport(error_handler(500, "boom"), auth_store=store)
    svc = CollectionService(transport, "users")

    with pytest.raises(ZigbaseError):
        svc.revoke_all_sessions()

    assert store.token is None


async def test_async_revoke_all_sessions_clears_store_even_on_failure() -> None:
    store = MemoryAuthStore()
    store.save("t", {"id": "u1"})
    transport = AsyncMockTransport(error_handler(500, "boom"), auth_store=store)
    svc = AsyncCollectionService(transport, "users")

    with pytest.raises(ZigbaseError):
        await svc.revoke_all_sessions()

    assert store.token is None


# --- collection name encoding ----------------------------------------------------------


def test_auth_endpoints_uri_encode_collection_name() -> None:
    transport = MockTransport(sequence_handler(None))
    svc = CollectionService(transport, "weird name/x")

    svc.request_password_reset("a@b.com")

    assert "weird%20name%2Fx" in transport.calls[0].path
