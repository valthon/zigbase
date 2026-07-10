"""Tests for `zigbase.typed`'s result envelopes + `TypedCollection`/
`AsyncTypedCollection`, a port of `clients/dart/lib/typed.dart:307-522`
(`TypedList`/`TypedCursorPage`/`joinCsv`/`normalizeSort`/`TypedCollection`).

Drives a real `ZigBase`/`AsyncZigBase` (built on `httpx.Client(transport=
httpx.MockTransport(handler))`, the fixture test_client.py uses) so
`TypedCollection` is exercised through the actual `client.collection(name)`/
`client.files` wiring rather than a fake -- matching how the Task 6 generated
services will use it.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import httpx

from zigbase.client import AsyncZigBase, ZigBase
from zigbase.collection import AsyncCollectionService, CollectionService
from zigbase.typed import (
    AsyncTypedCollection,
    CollectionMeta,
    FieldMeta,
    FieldType,
    TypedCollection,
    TypedCursorPage,
    TypedList,
    join_csv,
    normalize_sort,
)

Handler = Callable[[httpx.Request], httpx.Response]


def json_response(body: object, status: int = 200) -> httpx.Response:
    return httpx.Response(status, json=body)


def make_sync_client(handler: Handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def make_async_client(handler: Handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


@dataclass(frozen=True)
class Post:
    """A minimal generated-style typed record."""

    id: str
    title: str


def post_from_record(record: dict[str, Any]) -> Post:
    return Post(id=str(record["id"]), title=str(record.get("title", "")))


POSTS_META = CollectionMeta(
    name="posts",
    fields={"title": FieldMeta(type=FieldType.TEXT)},
)


# ---------------------------------------------------------------------------
# join_csv / normalize_sort
# ---------------------------------------------------------------------------


class TestJoinCsv:
    def test_none_omits(self) -> None:
        assert join_csv(None) is None

    def test_empty_omits(self) -> None:
        assert join_csv([]) is None

    def test_joins_with_comma(self) -> None:
        assert join_csv(["author", "comments"]) == "author,comments"

    def test_single_value(self) -> None:
        assert join_csv(["author"]) == "author"


class TestNormalizeSort:
    def test_none_omits(self) -> None:
        assert normalize_sort(None) is None

    def test_string_passthrough(self) -> None:
        assert normalize_sort("-created") == "-created"

    def test_sequence_joins(self) -> None:
        assert normalize_sort(["-created", "title"]) == "-created,title"

    def test_empty_sequence_omits(self) -> None:
        assert normalize_sort([]) is None

    def test_sequence_drops_empty_entries(self) -> None:
        assert normalize_sort(["-created", "", "title"]) == "-created,title"


# ---------------------------------------------------------------------------
# TypedCollection (sync)
# ---------------------------------------------------------------------------


def test_collection_escape_hatch_returns_underlying_service() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    assert isinstance(typed.collection, CollectionService)
    assert typed.collection.name == "posts"
    zb.close()


def test_get_list_maps_items_through_from_record_and_sends_query() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response(
            {
                "page": 1,
                "perPage": 30,
                "totalItems": 2,
                "totalPages": 1,
                "items": [{"id": "p1", "title": "hi"}, {"id": "p2", "title": "bye"}],
            }
        )

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    result = typed.get_list(
        1, 30, filter="title != ''", sort=["-created", "title"], expand=["author", "comments"]
    )

    assert isinstance(result, TypedList)
    assert result.items == [Post(id="p1", title="hi"), Post(id="p2", title="bye")]
    assert all(isinstance(item, Post) for item in result.items)
    assert result.page == 1
    assert result.per_page == 30
    assert result.total_items == 2
    assert result.total_pages == 1

    query = dict(requests[0].url.params)
    assert query["filter"] == "title != ''"
    assert query["sort"] == "-created,title"
    assert query["expand"] == "author,comments"
    zb.close()


def test_get_list_omits_expand_when_none() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response(
            {"page": 1, "perPage": 30, "totalItems": 0, "totalPages": 0, "items": []}
        )

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    typed.get_list()

    assert "expand" not in requests[0].url.params
    assert "sort" not in requests[0].url.params
    assert "filter" not in requests[0].url.params
    zb.close()


def test_get_one_maps_through_from_record() -> None:
    zb = ZigBase(
        "http://localhost:8090",
        http_client=make_sync_client(lambda r: json_response({"id": "p1", "title": "hi"})),
    )
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    result = typed.get_one("p1")

    assert result == Post(id="p1", title="hi")
    zb.close()


def test_get_first_list_item_maps_through_from_record() -> None:
    zb = ZigBase(
        "http://localhost:8090",
        http_client=make_sync_client(
            lambda r: json_response(
                {
                    "page": 1,
                    "perPage": 1,
                    "totalItems": 1,
                    "totalPages": 1,
                    "items": [{"id": "p1", "title": "hi"}],
                }
            )
        ),
    )
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    result = typed.get_first_list_item("title = 'hi'")

    assert result == Post(id="p1", title="hi")
    zb.close()


def test_get_page_round_trips_cursor() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response(
            {
                "items": [{"id": "p1", "title": "hi"}],
                "nextCursor": "cursor-2",
                "prevCursor": None,
                "hasNext": True,
                "hasPrev": False,
                "totalItems": None,
            }
        )

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    page = typed.get_page(cursor="cursor-1", limit=1)

    assert isinstance(page, TypedCursorPage)
    assert page.items == [Post(id="p1", title="hi")]
    assert page.next_cursor == "cursor-2"
    assert page.prev_cursor is None
    assert page.has_next is True
    assert page.has_prev is False
    assert page.total_items is None
    assert dict(requests[0].url.params)["cursor"] == "cursor-1"
    zb.close()


def test_iterate_maps_every_item() -> None:
    pages = [
        {
            "items": [{"id": "p1", "title": "a"}, {"id": "p2", "title": "b"}],
            "nextCursor": "c2",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
            "totalItems": None,
        },
        {
            "items": [{"id": "p3", "title": "c"}],
            "nextCursor": None,
            "prevCursor": "c2",
            "hasNext": False,
            "hasPrev": True,
            "totalItems": None,
        },
    ]
    it = iter(pages)

    def handler(request: httpx.Request) -> httpx.Response:
        return json_response(next(it))

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    items = list(typed.iterate(batch=2))

    assert items == [Post(id="p1", title="a"), Post(id="p2", title="b"), Post(id="p3", title="c")]
    assert all(isinstance(item, Post) for item in items)
    zb.close()


def test_get_full_list_accumulates_via_iterate() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return json_response(
            {
                "items": [{"id": "p1", "title": "a"}],
                "nextCursor": None,
                "prevCursor": None,
                "hasNext": False,
                "hasPrev": False,
                "totalItems": None,
            }
        )

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    items = typed.get_full_list()

    assert items == [Post(id="p1", title="a")]
    zb.close()


def test_create_passes_raw_dict_body_through_untouched() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response({"id": "new1", "title": "hello"})

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    body = {"title": "hello", "extra": 42}
    result = typed.create(body)

    assert result == Post(id="new1", title="hello")
    import json as _json

    assert _json.loads(requests[0].content) == {"title": "hello", "extra": 42}
    zb.close()


def test_update_passes_raw_dict_body_through_untouched() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response({"id": "p1", "title": "updated"})

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    body = {"title": "updated"}
    result = typed.update("p1", body)

    assert result == Post(id="p1", title="updated")
    import json as _json

    assert _json.loads(requests[0].content) == {"title": "updated"}
    assert requests[0].method == "PATCH"
    zb.close()


def test_delete_passthrough() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(204)

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    typed.delete("p1")

    assert requests[0].method == "DELETE"
    assert requests[0].url.path == "/api/collections/posts/records/p1"
    zb.close()


def test_file_url_builds_via_files_service() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))
    typed = TypedCollection(zb, POSTS_META, post_from_record)

    record = {"id": "p1", "collectionName": "posts"}
    url = typed.file_url(record, "photo.png", download=True, thumb="100x100")

    assert url == "http://localhost:8090/api/files/posts/p1/photo.png?download=1&thumb=100x100"
    zb.close()


# ---------------------------------------------------------------------------
# AsyncTypedCollection
# ---------------------------------------------------------------------------


async def test_async_collection_escape_hatch_returns_underlying_service() -> None:
    zb = AsyncZigBase(
        "http://localhost:8090", http_client=make_async_client(lambda r: json_response({}))
    )
    typed = AsyncTypedCollection(zb, POSTS_META, post_from_record)

    assert isinstance(typed.collection, AsyncCollectionService)
    assert typed.collection.name == "posts"
    await zb.aclose()


async def test_async_get_list_maps_items_through_from_record() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response(
            {
                "page": 1,
                "perPage": 30,
                "totalItems": 1,
                "totalPages": 1,
                "items": [{"id": "p1", "title": "hi"}],
            }
        )

    zb = AsyncZigBase("http://localhost:8090", http_client=make_async_client(handler))
    typed = AsyncTypedCollection(zb, POSTS_META, post_from_record)

    result = await typed.get_list(expand=["author"])

    assert result.items == [Post(id="p1", title="hi")]
    assert dict(requests[0].url.params)["expand"] == "author"
    await zb.aclose()


async def test_async_create_passes_raw_dict_body_through() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response({"id": "new1", "title": "hello"})

    zb = AsyncZigBase("http://localhost:8090", http_client=make_async_client(handler))
    typed = AsyncTypedCollection(zb, POSTS_META, post_from_record)

    result = await typed.create({"title": "hello"})

    assert result == Post(id="new1", title="hello")
    import json as _json

    assert _json.loads(requests[0].content) == {"title": "hello"}
    await zb.aclose()


async def test_async_iterate_maps_every_item() -> None:
    pages = [
        {
            "items": [{"id": "p1", "title": "a"}],
            "nextCursor": "c2",
            "prevCursor": None,
            "hasNext": True,
            "hasPrev": False,
            "totalItems": None,
        },
        {
            "items": [{"id": "p2", "title": "b"}],
            "nextCursor": None,
            "prevCursor": "c2",
            "hasNext": False,
            "hasPrev": True,
            "totalItems": None,
        },
    ]
    it = iter(pages)

    def handler(request: httpx.Request) -> httpx.Response:
        return json_response(next(it))

    zb = AsyncZigBase("http://localhost:8090", http_client=make_async_client(handler))
    typed = AsyncTypedCollection(zb, POSTS_META, post_from_record)

    items = [item async for item in typed.iterate(batch=1)]

    assert items == [Post(id="p1", title="a"), Post(id="p2", title="b")]
    assert all(isinstance(item, Post) for item in items)
    await zb.aclose()


async def test_async_file_url_builds_via_files_service() -> None:
    zb = AsyncZigBase(
        "http://localhost:8090", http_client=make_async_client(lambda r: json_response({}))
    )
    typed = AsyncTypedCollection(zb, POSTS_META, post_from_record)

    record = {"id": "p1", "collectionName": "posts"}
    url = typed.file_url(record, "photo.png")

    assert url == "http://localhost:8090/api/files/posts/p1/photo.png"
    await zb.aclose()
