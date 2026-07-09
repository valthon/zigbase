"""Tests for `zigbase.files`, `zigbase.accounts`, `zigbase.analytics`, and
`zigbase.senders`.

Mirrors the equivalent TS/Dart test suites for `FilesService`,
`AccountsService`, `AnalyticsService`, and `SendersService`. Each request-
issuing test drives a fake transport (the same `MockTransport`/
`AsyncMockTransport` shape as test_collection.py) that records the
`RequestSpec` it was sent and returns a canned envelope; `get_url`/
`get_url_for` are pure string builders and are tested without a transport.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

import pytest

from zigbase._request import RequestSpec
from zigbase.accounts import AccountsService, AsyncAccountsService
from zigbase.analytics import AnalyticsService, AsyncAnalyticsService
from zigbase.errors import ZigbaseError
from zigbase.files import AsyncFilesService, FilesService
from zigbase.senders import AsyncSendersService, SendersService

Handler = Callable[[RequestSpec], Any]


class MockTransport:
    """Fake `SyncTransport`: records every spec, dispatches to `handler`."""

    def __init__(self, handler: Handler) -> None:
        self._handler = handler
        self.calls: list[RequestSpec] = []

    def request(self, spec: RequestSpec) -> Any:
        self.calls.append(spec)
        return self._handler(spec)


class AsyncMockTransport:
    """`MockTransport`'s async counterpart."""

    def __init__(self, handler: Handler) -> None:
        self._handler = handler
        self.calls: list[RequestSpec] = []

    async def request(self, spec: RequestSpec) -> Any:
        self.calls.append(spec)
        return self._handler(spec)


def sequence_handler(*bodies: Any) -> Handler:
    it = iter(bodies)

    def handler(_spec: RequestSpec) -> Any:
        return next(it)

    return handler


# --- FilesService.get_url / get_url_for (pure) ------------------------------


def test_get_url_for_encodes_each_segment_and_strips_trailing_slashes() -> None:
    svc = FilesService(MockTransport(sequence_handler()), "http://localhost:8090/")

    url = svc.get_url_for("posts", "rec1", "my photo.png")

    assert url == "http://localhost:8090/api/files/posts/rec1/my%20photo.png"


def test_get_url_for_download_thumb_token_query_in_order() -> None:
    svc = FilesService(MockTransport(sequence_handler()), "http://localhost:8090")

    url = svc.get_url_for(
        "posts", "rec1", "photo.png", download=True, thumb="100x100", token="tok abc"
    )

    assert url == (
        "http://localhost:8090/api/files/posts/rec1/photo.png"
        "?download=1&thumb=100x100&token=tok+abc"
    )


def test_get_url_derives_collection_from_collection_id() -> None:
    svc = FilesService(MockTransport(sequence_handler()), "http://localhost:8090")
    record = {"id": "rec1", "collectionId": "col_abc", "collectionName": "posts"}

    url = svc.get_url(record, "photo.png")

    assert url == "http://localhost:8090/api/files/col_abc/rec1/photo.png"


def test_get_url_falls_back_to_collection_name() -> None:
    svc = FilesService(MockTransport(sequence_handler()), "http://localhost:8090")
    record = {"id": "rec1", "collectionName": "posts"}

    url = svc.get_url(record, "photo.png")

    assert url == "http://localhost:8090/api/files/posts/rec1/photo.png"


def test_get_url_raises_value_error_when_no_collection_present() -> None:
    svc = FilesService(MockTransport(sequence_handler()), "http://localhost:8090")
    record = {"id": "rec1"}

    with pytest.raises(ValueError, match="collectionId nor collectionName"):
        svc.get_url(record, "photo.png")


def test_async_get_url_for_is_a_plain_sync_method() -> None:
    svc = AsyncFilesService(AsyncMockTransport(sequence_handler()), "http://localhost:8090")

    url = svc.get_url_for("posts", "rec1", "a b.png", thumb="50x50")

    assert url == "http://localhost:8090/api/files/posts/rec1/a%20b.png?thumb=50x50"


# --- FilesService.get_token --------------------------------------------------


def test_get_token_posts_and_unwraps_token() -> None:
    transport = MockTransport(sequence_handler({"token": "file-tok-1"}))
    svc = FilesService(transport, "http://localhost:8090")

    tok = svc.get_token()

    assert tok == "file-tok-1"
    assert len(transport.calls) == 1
    assert transport.calls[0].method == "POST"
    assert transport.calls[0].path == "/api/files/token"


async def test_async_get_token_posts_and_unwraps_token() -> None:
    transport = AsyncMockTransport(sequence_handler({"token": "file-tok-2"}))
    svc = AsyncFilesService(transport, "http://localhost:8090")

    tok = await svc.get_token()

    assert tok == "file-tok-2"
    assert transport.calls[0].path == "/api/files/token"


# --- AccountsService.activate -------------------------------------------------


def test_activate_posts_encoded_id_path_and_returns_scope() -> None:
    transport = MockTransport(sequence_handler({"account": "acc_1", "role": "owner"}))
    svc = AccountsService(transport)

    scope = svc.activate("acc/1")

    assert scope == {"account": "acc_1", "role": "owner"}
    assert transport.calls[0].method == "POST"
    assert transport.calls[0].path == "/api/accounts/acc%2F1/activate"


async def test_async_activate_posts_encoded_id_path_and_returns_scope() -> None:
    transport = AsyncMockTransport(sequence_handler({"account": "acc_2", "role": "member"}))
    svc = AsyncAccountsService(transport)

    scope = await svc.activate("acc_2")

    assert scope == {"account": "acc_2", "role": "member"}
    assert transport.calls[0].path == "/api/accounts/acc_2/activate"


# --- AnalyticsService.events ---------------------------------------------------


def test_events_sends_query_and_parses_cursor_envelope() -> None:
    transport = MockTransport(
        sequence_handler(
            {
                "items": [{"id": "e1", "name": "signup"}],
                "nextCursor": "c2",
                "hasNext": True,
            }
        )
    )
    svc = AnalyticsService(transport)

    page = svc.events(name="signup", actor="u1", limit=10, cursor="c1")

    spec = transport.calls[0]
    assert spec.method == "GET"
    assert spec.path == "/api/analytics/events"
    assert spec.query == {"name": "signup", "actor": "u1", "limit": "10", "cursor": "c1"}
    assert page.items == [{"id": "e1", "name": "signup"}]
    assert page.next_cursor == "c2"
    assert page.has_next is True
    assert page.prev_cursor is None
    assert page.total_items is None


def test_events_since_datetime_formats_as_iso_millis_z() -> None:
    transport = MockTransport(sequence_handler({"items": [], "nextCursor": None, "hasNext": False}))
    svc = AnalyticsService(transport)

    svc.events(since=datetime(2024, 1, 2, 3, 4, 5, 678000, tzinfo=timezone.utc))

    assert transport.calls[0].query == {"since": "2024-01-02T03:04:05.678Z"}


def test_events_rejects_unknown_kwarg() -> None:
    svc = AnalyticsService(MockTransport(sequence_handler()))

    with pytest.raises(TypeError, match="bogus"):
        svc.events(bogus="x")


async def test_async_events_sends_query_and_parses_cursor_envelope() -> None:
    transport = AsyncMockTransport(
        sequence_handler({"items": [{"id": "e1"}], "nextCursor": None, "hasNext": False})
    )
    svc = AsyncAnalyticsService(transport)

    page = await svc.events()

    assert transport.calls[0].query == {}
    assert page.items == [{"id": "e1"}]
    assert page.has_next is False


# --- AnalyticsService.rollup ----------------------------------------------------


def test_rollup_sends_encoded_name_and_from_to_and_unwraps_items() -> None:
    transport = MockTransport(sequence_handler({"items": [{"bucket": "2024-01-01", "value": 3}]}))
    svc = AnalyticsService(transport)

    rows = svc.rollup(
        "daily active/users", from_="2024-01-01T00:00:00.000Z", to="2024-01-02T00:00:00.000Z"
    )

    assert rows == [{"bucket": "2024-01-01", "value": 3}]
    spec = transport.calls[0]
    assert spec.path == "/api/analytics/rollups/daily%20active%2Fusers"
    assert spec.query == {"from": "2024-01-01T00:00:00.000Z", "to": "2024-01-02T00:00:00.000Z"}


def test_rollup_with_no_opts_sends_empty_query() -> None:
    transport = MockTransport(sequence_handler({"items": []}))
    svc = AnalyticsService(transport)

    rows = svc.rollup("daily")

    assert rows == []
    assert transport.calls[0].query == {}


async def test_async_rollup_unwraps_items() -> None:
    transport = AsyncMockTransport(sequence_handler({"items": [{"bucket": "b1"}]}))
    svc = AsyncAnalyticsService(transport)

    rows = await svc.rollup("daily")

    assert rows == [{"bucket": "b1"}]


# --- SendersService -------------------------------------------------------------


def test_senders_list_unwraps_items() -> None:
    transport = MockTransport(
        sequence_handler({"items": [{"id": "s1", "email": "a@b.com", "status": "verified"}]})
    )
    svc = SendersService(transport)

    rows = svc.list()

    assert rows == [{"id": "s1", "email": "a@b.com", "status": "verified"}]
    assert transport.calls[0].method == "GET"
    assert transport.calls[0].path == "/api/senders"


def test_senders_create_posts_email_and_returns_body() -> None:
    transport = MockTransport(
        sequence_handler({"id": "s2", "email": "c@d.com", "status": "pending"})
    )
    svc = SendersService(transport)

    row = svc.create("c@d.com")

    assert row == {"id": "s2", "email": "c@d.com", "status": "pending"}
    spec = transport.calls[0]
    assert spec.method == "POST"
    assert spec.path == "/api/senders"
    assert spec.body == {"email": "c@d.com"}


def test_senders_verify_posts_token_and_returns_verified_flag() -> None:
    # src/api/senders.zig answers 200 {"verified": true/false}, not 204 -- the
    # TS/Dart references (files.ts/senders.dart) both surface this boolean.
    transport = MockTransport(sequence_handler({"verified": True}))
    svc = SendersService(transport)

    result = svc.verify("s1", "tok-1")

    assert result is True
    spec = transport.calls[0]
    assert spec.method == "POST"
    assert spec.path == "/api/senders/s1/verify"
    assert spec.body == {"token": "tok-1"}


def test_senders_verify_encodes_id_segment() -> None:
    transport = MockTransport(sequence_handler({"verified": False}))
    svc = SendersService(transport)

    result = svc.verify("s/1", "tok-1")

    assert result is False
    assert transport.calls[0].path == "/api/senders/s%2F1/verify"


async def test_async_senders_list_create_verify() -> None:
    transport = AsyncMockTransport(
        sequence_handler(
            {"items": [{"id": "s1"}]},
            {"id": "s2", "email": "e@f.com", "status": "pending"},
            {"verified": True},
        )
    )
    svc = AsyncSendersService(transport)

    assert await svc.list() == [{"id": "s1"}]
    assert await svc.create("e@f.com") == {"id": "s2", "email": "e@f.com", "status": "pending"}
    assert await svc.verify("s2", "tok") is True


# --- non-object 2xx body guard ---------------------------------------------------
#
# `_decode_response` returns `None` for a 204/empty body on ANY 2xx -- the
# transport can't know a given endpoint's contract promises a JSON object.
# `get_token`/`rollup`/`list`/`verify` used to `typing.cast(dict, body)` that
# `None` and crash with a bare AttributeError on the first `.get(...)`; they
# now raise a clear status-0 `ZigbaseError` instead.


def test_get_token_raises_clear_error_on_non_object_body() -> None:
    svc = FilesService(MockTransport(sequence_handler(None)), "http://localhost:8090")

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        svc.get_token()
    assert excinfo.value.status == 0


async def test_async_get_token_raises_clear_error_on_non_object_body() -> None:
    svc = AsyncFilesService(AsyncMockTransport(sequence_handler(None)), "http://localhost:8090")

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        await svc.get_token()
    assert excinfo.value.status == 0


def test_rollup_raises_clear_error_on_non_object_body() -> None:
    svc = AnalyticsService(MockTransport(sequence_handler(None)))

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        svc.rollup("daily")
    assert excinfo.value.status == 0


async def test_async_events_raises_clear_error_on_non_object_body() -> None:
    svc = AsyncAnalyticsService(AsyncMockTransport(sequence_handler(None)))

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        await svc.events()
    assert excinfo.value.status == 0


def test_senders_list_raises_clear_error_on_non_object_body() -> None:
    svc = SendersService(MockTransport(sequence_handler(None)))

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        svc.list()
    assert excinfo.value.status == 0


def test_senders_verify_raises_clear_error_on_non_object_body() -> None:
    svc = SendersService(MockTransport(sequence_handler(None)))

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        svc.verify("s1", "tok")
    assert excinfo.value.status == 0


async def test_async_senders_verify_raises_clear_error_on_non_object_body() -> None:
    svc = AsyncSendersService(AsyncMockTransport(sequence_handler(None)))

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        await svc.verify("s1", "tok")
    assert excinfo.value.status == 0


def test_activate_raises_clear_error_on_non_object_body() -> None:
    svc = AccountsService(MockTransport(sequence_handler(None)))

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        svc.activate("acc_1")
    assert excinfo.value.status == 0
