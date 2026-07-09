"""Tests for `zigbase.collection` (`CollectionService`/`AsyncCollectionService`).

Mirrors clients/typescript/test/cursor-paging.test.ts plus the CRUD half of
clients/typescript/src/collection.ts (auth methods are Task 9, not covered
here). Each test drives a fake transport that records the `RequestSpec` it
was sent and returns a canned envelope, matching the "MockTransport handler"
shape the task-8 brief asks for.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import pytest

from zigbase._request import RequestSpec
from zigbase.collection import AsyncCollectionService, CollectionService
from zigbase.errors import ZigbaseError

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
    """`MockTransport`'s async counterpart, for `AsyncCollectionService`."""

    def __init__(self, handler: Handler) -> None:
        self._handler = handler
        self.calls: list[RequestSpec] = []

    async def request(self, spec: RequestSpec) -> Any:
        self.calls.append(spec)
        return self._handler(spec)


def sequence_handler(*bodies: Any) -> Handler:
    """A handler that returns each of `bodies` in turn, one per call."""
    it = iter(bodies)

    def handler(_spec: RequestSpec) -> Any:
        return next(it)

    return handler


# --- get_list (offset) --------------------------------------------------------


def test_get_list_parses_offset_envelope_to_snake_case() -> None:
    transport = MockTransport(
        lambda spec: {
            "page": 2,
            "perPage": 10,
            "totalItems": 42,
            "totalPages": 5,
            "items": [{"id": "a"}, {"id": "b"}],
        }
    )
    svc = CollectionService(transport, "posts")

    result = svc.get_list(2, 10, filter="status = 'ok'", sort="-created")

    assert result.page == 2
    assert result.per_page == 10
    assert result.total_items == 42
    assert result.total_pages == 5
    assert result.items == [{"id": "a"}, {"id": "b"}]

    spec = transport.calls[0]
    assert spec.method == "GET"
    assert spec.path == "/api/collections/posts/records"
    assert spec.query == {
        "page": "2",
        "perPage": "10",
        "filter": "status = 'ok'",
        "sort": "-created",
    }


def test_get_list_clamps_per_page_and_sends_skip_total_only_when_true() -> None:
    seen: list[RequestSpec] = []

    def handler(spec: RequestSpec) -> Any:
        seen.append(spec)
        return {"page": 1, "perPage": 500, "totalItems": 0, "totalPages": 0, "items": []}

    svc = CollectionService(MockTransport(handler), "posts")
    svc.get_list(1, 10_000)
    assert seen[0].query is not None
    assert seen[0].query["perPage"] == "500"
    assert "skipTotal" not in seen[0].query

    svc.get_list(1, 30, skip_total=True)
    assert seen[1].query is not None
    assert seen[1].query["skipTotal"] == "true"


def test_get_list_encodes_collection_name_in_path() -> None:
    transport = MockTransport(
        lambda spec: {"page": 1, "perPage": 30, "totalItems": 0, "totalPages": 0, "items": []}
    )
    svc = CollectionService(transport, "a/b c")
    svc.get_list()
    assert transport.calls[0].path == "/api/collections/a%2Fb%20c/records"


# --- get_one / create / update / delete ---------------------------------------


def test_get_one_sends_expand_and_fields() -> None:
    transport = MockTransport(lambda spec: {"id": "r1", "title": "hi"})
    svc = CollectionService(transport, "posts")

    record = svc.get_one("r1", expand="author", fields="id,title")

    assert record == {"id": "r1", "title": "hi"}
    spec = transport.calls[0]
    assert spec.method == "GET"
    assert spec.path == "/api/collections/posts/records/r1"
    assert spec.query == {"expand": "author", "fields": "id,title"}


def test_get_one_encodes_record_id() -> None:
    transport = MockTransport(lambda spec: {"id": "a/b"})
    svc = CollectionService(transport, "posts")
    svc.get_one("a/b")
    assert transport.calls[0].path == "/api/collections/posts/records/a%2Fb"


def test_create_posts_body_and_returns_record() -> None:
    transport = MockTransport(lambda spec: {"id": "new1", "title": "hello"})
    svc = CollectionService(transport, "posts")

    record = svc.create({"title": "hello"}, expand="author")

    assert record == {"id": "new1", "title": "hello"}
    spec = transport.calls[0]
    assert spec.method == "POST"
    assert spec.path == "/api/collections/posts/records"
    assert spec.body == {"title": "hello"}
    assert spec.query == {"expand": "author"}


def test_update_patches_body_and_returns_record() -> None:
    transport = MockTransport(lambda spec: {"id": "r1", "title": "updated"})
    svc = CollectionService(transport, "posts")

    record = svc.update("r1", {"title": "updated"}, fields="id,title")

    assert record == {"id": "r1", "title": "updated"}
    spec = transport.calls[0]
    assert spec.method == "PATCH"
    assert spec.path == "/api/collections/posts/records/r1"
    assert spec.body == {"title": "updated"}
    assert spec.query == {"fields": "id,title"}


def test_delete_returns_none_on_204() -> None:
    transport = MockTransport(lambda spec: None)
    svc = CollectionService(transport, "posts")

    result = svc.delete("r1")

    assert result is None
    spec = transport.calls[0]
    assert spec.method == "DELETE"
    assert spec.path == "/api/collections/posts/records/r1"


# --- get_abilities -------------------------------------------------------------


def test_get_abilities_returns_view_update_delete() -> None:
    transport = MockTransport(lambda spec: {"view": True, "update": False, "delete": False})
    svc = CollectionService(transport, "posts")

    abilities = svc.get_abilities("r1")

    assert abilities == {"view": True, "update": False, "delete": False}
    spec = transport.calls[0]
    assert spec.method == "GET"
    assert spec.path == "/api/collections/posts/records/r1/abilities"


# --- get_first_list_item --------------------------------------------------------


def test_get_first_list_item_returns_first_match() -> None:
    transport = MockTransport(
        lambda spec: {
            "page": 1,
            "perPage": 1,
            "totalItems": 0,
            "totalPages": 0,
            "items": [{"id": "r1"}],
        }
    )
    svc = CollectionService(transport, "posts")

    record = svc.get_first_list_item("status = 'ok'")

    assert record == {"id": "r1"}
    spec = transport.calls[0]
    assert spec.query is not None
    assert spec.query["filter"] == "status = 'ok'"
    assert spec.query["page"] == "1"
    assert spec.query["perPage"] == "1"
    assert spec.query["skipTotal"] == "true"


def test_get_first_list_item_raises_synthesized_404_when_empty() -> None:
    transport = MockTransport(
        lambda spec: {"page": 1, "perPage": 1, "totalItems": 0, "totalPages": 0, "items": []}
    )
    svc = CollectionService(transport, "posts")

    with pytest.raises(ZigbaseError) as excinfo:
        svc.get_first_list_item("status = 'nope'")

    err = excinfo.value
    assert err.status == 404
    # Matches the TS/Dart normative reference's synthesized-404 message
    # (clients/typescript/src/collection.ts, clients/dart/lib/src/collection.dart)
    # -- the task-8 brief's suggested wording differs; TS/Dart win per the
    # "normative reference wins on wire behavior" instruction.
    assert err.message == "No record found matching the filter."
    assert err.url == "/api/collections/posts/records"


# --- get_page (native cursor pagination) ----------------------------------------


def test_get_page_first_page_omits_cursor_and_defaults_limit() -> None:
    transport = MockTransport(
        lambda spec: {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "r1"}, {"id": "r2"}],
            "nextCursor": "TOKEN_NEXT",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
        }
    )
    svc = CollectionService(transport, "posts")

    page = svc.get_page(limit=2, sort="-created")

    assert [i["id"] for i in page.items] == ["r1", "r2"]
    assert page.next_cursor == "TOKEN_NEXT"
    assert page.prev_cursor is None
    assert page.has_next is True
    assert page.has_prev is False
    assert page.total_items is None

    spec = transport.calls[0]
    assert spec.query is not None
    assert spec.query["limit"] == "2"
    assert "cursor" not in spec.query
    assert "skipTotal" not in spec.query
    assert "page" not in spec.query
    assert "perPage" not in spec.query


def test_get_page_forwards_opaque_cursor_token_verbatim() -> None:
    transport = MockTransport(
        lambda spec: {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "r3"}],
            "nextCursor": None,
            "prevCursor": "PREV_TOK",
            "hasNext": False,
            "hasPrev": True,
        }
    )
    svc = CollectionService(transport, "posts")

    svc.get_page(cursor="OPAQUE_TOKEN_FROM_SERVER", limit=2)

    spec = transport.calls[0]
    assert spec.query is not None
    assert spec.query["cursor"] == "OPAQUE_TOKEN_FROM_SERVER"


def test_get_page_empty_cursor_string_is_treated_as_first_page() -> None:
    transport = MockTransport(
        lambda spec: {
            "page": 1,
            "perPage": 2,
            "items": [],
            "nextCursor": None,
            "prevCursor": None,
            "hasNext": False,
            "hasPrev": False,
        }
    )
    svc = CollectionService(transport, "posts")
    svc.get_page(cursor="", limit=2)
    assert "cursor" not in (transport.calls[0].query or {})


def test_get_page_default_limit_is_30() -> None:
    transport = MockTransport(
        lambda spec: {
            "page": 1,
            "perPage": 30,
            "items": [],
            "nextCursor": None,
            "prevCursor": None,
            "hasNext": False,
            "hasPrev": False,
        }
    )
    svc = CollectionService(transport, "posts")
    svc.get_page()
    assert transport.calls[0].query is not None
    assert transport.calls[0].query["limit"] == "30"


def test_get_page_with_total_sends_skip_total_false_and_surfaces_total() -> None:
    transport = MockTransport(
        lambda spec: {
            "page": 1,
            "perPage": 2,
            "totalItems": 42,
            "items": [{"id": "a"}],
            "nextCursor": "N",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
        }
    )
    svc = CollectionService(transport, "posts")

    page = svc.get_page(limit=2, with_total=True)

    assert transport.calls[0].query is not None
    assert transport.calls[0].query["skipTotal"] == "false"
    assert page.total_items == 42


# --- iterate / get_full_list ----------------------------------------------------


def test_iterate_crosses_three_pages_in_order() -> None:
    pages = [
        {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "r1"}, {"id": "r2"}],
            "nextCursor": "TOK1",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
        },
        {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "r3"}, {"id": "r4"}],
            "nextCursor": "TOK2",
            "prevCursor": "P",
            "hasNext": True,
            "hasPrev": True,
        },
        {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "r5"}],
            "nextCursor": None,
            "prevCursor": "P2",
            "hasNext": False,
            "hasPrev": True,
        },
    ]
    seen_cursors: list[str | None] = []

    def handler(spec: RequestSpec) -> Any:
        seen_cursors.append((spec.query or {}).get("cursor"))
        return pages[len(seen_cursors) - 1]

    svc = CollectionService(MockTransport(handler), "posts")

    seen = [rec["id"] for rec in svc.iterate(sort="-created", batch=2)]

    assert seen == ["r1", "r2", "r3", "r4", "r5"]
    assert seen_cursors == [None, "TOK1", "TOK2"]


def test_get_full_list_accumulates_across_cursor_pages() -> None:
    pages = [
        {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "a"}, {"id": "b"}],
            "nextCursor": "T",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
        },
        {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "c"}],
            "nextCursor": None,
            "prevCursor": "P",
            "hasNext": False,
            "hasPrev": True,
        },
    ]
    transport = MockTransport(sequence_handler(*pages))
    svc = CollectionService(transport, "posts")

    all_records = svc.get_full_list(sort="-created", batch=2)

    assert [r["id"] for r in all_records] == ["a", "b", "c"]


def test_iterate_raises_status_0_on_empty_page_still_claiming_has_next() -> None:
    pages = [
        {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "r1"}],
            "nextCursor": "TOK1",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
        },
        {
            "page": 1,
            "perPage": 2,
            "items": [],
            "nextCursor": "TOK2",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
        },
    ]
    calls = {"n": 0}

    def handler(spec: RequestSpec) -> Any:
        idx = min(calls["n"], len(pages) - 1)
        calls["n"] += 1
        return pages[idx]

    svc = CollectionService(MockTransport(handler), "posts")

    seen = []
    with pytest.raises(ZigbaseError) as excinfo:
        for rec in svc.iterate(batch=2):
            seen.append(rec["id"])

    assert seen == ["r1"]
    assert excinfo.value.status == 0
    assert "non-advancing cursor" in excinfo.value.message


def test_iterate_raises_status_0_on_repeated_cursor_token() -> None:
    calls = {"n": 0}

    def handler(spec: RequestSpec) -> Any:
        calls["n"] += 1
        return {
            "page": 1,
            "perPage": 2,
            "items": [{"id": f"r{calls['n']}"}],
            "nextCursor": "STUCK",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
        }

    svc = CollectionService(MockTransport(handler), "posts")

    with pytest.raises(ZigbaseError) as excinfo:
        for _rec in svc.iterate(batch=2):
            pass

    assert excinfo.value.status == 0
    assert calls["n"] == 2


# --- async variants --------------------------------------------------------------


@pytest.mark.asyncio
async def test_async_get_list_parses_offset_envelope() -> None:
    transport = AsyncMockTransport(
        lambda spec: {
            "page": 1,
            "perPage": 30,
            "totalItems": 1,
            "totalPages": 1,
            "items": [{"id": "a"}],
        }
    )
    svc = AsyncCollectionService(transport, "posts")

    result = await svc.get_list()

    assert result.items == [{"id": "a"}]
    assert transport.calls[0].method == "GET"
    assert transport.calls[0].path == "/api/collections/posts/records"


@pytest.mark.asyncio
async def test_async_create_posts_body() -> None:
    transport = AsyncMockTransport(lambda spec: {"id": "new1"})
    svc = AsyncCollectionService(transport, "posts")

    record = await svc.create({"title": "hi"})

    assert record == {"id": "new1"}
    assert transport.calls[0].method == "POST"
    assert transport.calls[0].body == {"title": "hi"}


@pytest.mark.asyncio
async def test_async_iterate_crosses_pages() -> None:
    pages = [
        {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "a"}, {"id": "b"}],
            "nextCursor": "T",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
        },
        {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "c"}],
            "nextCursor": None,
            "prevCursor": "P",
            "hasNext": False,
            "hasPrev": True,
        },
    ]
    transport = AsyncMockTransport(sequence_handler(*pages))
    svc = AsyncCollectionService(transport, "posts")

    seen = [rec["id"] async for rec in svc.iterate(batch=2)]

    assert seen == ["a", "b", "c"]


@pytest.mark.asyncio
async def test_async_iterate_raises_status_0_on_non_advancing_cursor() -> None:
    def handler(spec: RequestSpec) -> Any:
        return {
            "page": 1,
            "perPage": 2,
            "items": [{"id": "r1"}],
            "nextCursor": "STUCK",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
        }

    transport = AsyncMockTransport(handler)
    svc = AsyncCollectionService(transport, "posts")

    with pytest.raises(ZigbaseError) as excinfo:
        async for _rec in svc.iterate(batch=2):
            pass

    assert excinfo.value.status == 0


# --- non-object 2xx body guard ---------------------------------------------------
#
# `SyncTransport`/`AsyncTransport._decode_response` returns `None` for a 204 or
# any other empty-bodied 2xx -- the transport has no way to know a given
# endpoint's contract promises a JSON object. Every helper below used to
# `typing.cast(dict, body)` that `None` and then crash with a bare
# AttributeError on the first `.get(...)`. They now route through
# `ensure_object_body` and raise a clear status-0 `ZigbaseError` instead.


def test_get_one_raises_clear_error_on_non_object_body() -> None:
    transport = MockTransport(lambda spec: None)
    svc = CollectionService(transport, "posts")

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        svc.get_one("r1")
    assert excinfo.value.status == 0


def test_get_list_raises_clear_error_on_non_object_body() -> None:
    transport = MockTransport(lambda spec: None)
    svc = CollectionService(transport, "posts")

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        svc.get_list()
    assert excinfo.value.status == 0


def test_get_page_raises_clear_error_on_non_object_body() -> None:
    transport = MockTransport(lambda spec: None)
    svc = CollectionService(transport, "posts")

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        svc.get_page()
    assert excinfo.value.status == 0


async def test_async_get_one_raises_clear_error_on_non_object_body() -> None:
    transport = AsyncMockTransport(lambda spec: None)
    svc = AsyncCollectionService(transport, "posts")

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        await svc.get_one("r1")
    assert excinfo.value.status == 0


async def test_async_get_list_raises_clear_error_on_non_object_body() -> None:
    transport = AsyncMockTransport(lambda spec: None)
    svc = AsyncCollectionService(transport, "posts")

    with pytest.raises(ZigbaseError, match="JSON object") as excinfo:
        await svc.get_list()
    assert excinfo.value.status == 0
