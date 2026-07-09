"""Live-server CRUD/pagination/authorization coverage.

Drives the public `ZigBase`/`AsyncZigBase` facades against a real `zigbase
serve` process (see `conftest.py`). Mirrors
`clients/dart/test/integration/integration_test.dart`'s CRUD/cursor/abilities
coverage.
"""

from __future__ import annotations

import pytest

from zigbase import AsyncZigBase, ZigBase, ZigbaseError, zb_filter

pytestmark = pytest.mark.integration


def test_health_check(client: ZigBase) -> None:
    health = client.health()
    assert health["status"] == "ok"


async def test_health_check_async(async_client: AsyncZigBase) -> None:
    health = await async_client.health()
    assert health["status"] == "ok"


def test_crud_roundtrip_with_zb_filter(client: ZigBase) -> None:
    posts = client.collection("posts")

    target = posts.create({"title": "O'Brien", "views": 100})
    posts.create({"title": "Smith", "views": 101})
    assert target["id"]
    assert target["title"] == "O'Brien"
    assert target["views"] == 100

    fetched = posts.get_one(target["id"])
    assert fetched["title"] == "O'Brien"

    result = posts.get_list(filter=zb_filter("title = {:t}", {"t": "O'Brien"}))
    assert [item["id"] for item in result.items] == [target["id"]]
    assert result.items[0]["title"] == "O'Brien"


async def test_crud_roundtrip_with_zb_filter_async(async_client: AsyncZigBase) -> None:
    posts = async_client.collection("posts")

    target = await posts.create({"title": "O'Hara-async", "views": 200})
    await posts.create({"title": "Jones-async", "views": 201})

    result = await posts.get_list(filter=zb_filter("title = {:t}", {"t": "O'Hara-async"}))
    assert [item["id"] for item in result.items] == [target["id"]]


def test_patch_partial_update(client: ZigBase) -> None:
    posts = client.collection("posts")
    created = posts.create({"title": "Original", "views": 7})

    updated = posts.update(created["id"], {"title": "Renamed"})
    assert updated["title"] == "Renamed"
    assert updated["views"] == 7  # untouched by the partial PATCH


async def test_patch_partial_update_async(async_client: AsyncZigBase) -> None:
    posts = async_client.collection("posts")
    created = await posts.create({"title": "Original-async", "views": 8})

    updated = await posts.update(created["id"], {"title": "Renamed-async"})
    assert updated["title"] == "Renamed-async"
    assert updated["views"] == 8  # untouched by the partial PATCH


def test_delete_then_get_one_raises_404(client: ZigBase) -> None:
    posts = client.collection("posts")
    created = posts.create({"title": "Ephemeral", "views": 1})

    assert posts.delete(created["id"]) is None

    with pytest.raises(ZigbaseError) as exc_info:
        posts.get_one(created["id"])
    assert exc_info.value.status == 404


async def test_delete_then_get_one_raises_404_async(async_client: AsyncZigBase) -> None:
    posts = async_client.collection("posts")
    created = await posts.create({"title": "Ephemeral-async", "views": 1})

    assert await posts.delete(created["id"]) is None

    with pytest.raises(ZigbaseError) as exc_info:
        await posts.get_one(created["id"])
    assert exc_info.value.status == 404


def test_get_abilities(client: ZigBase) -> None:
    posts = client.collection("posts")
    created = posts.create({"title": "Abilities", "views": 1})

    abilities = posts.get_abilities(created["id"])
    # posts has @public view/update/delete rules -- even an anonymous
    # caller can do all three.
    assert abilities == {"view": True, "update": True, "delete": True}


async def test_get_abilities_async(async_client: AsyncZigBase) -> None:
    posts = async_client.collection("posts")
    created = await posts.create({"title": "Abilities-async", "views": 1})

    abilities = await posts.get_abilities(created["id"])
    assert abilities == {"view": True, "update": True, "delete": True}


def test_locked_collection_create_as_anon_raises_403(client: ZigBase) -> None:
    with pytest.raises(ZigbaseError) as exc_info:
        client.collection("locked").create({"title": "nope"})
    assert exc_info.value.status == 403


async def test_locked_collection_create_as_anon_raises_403_async(
    async_client: AsyncZigBase,
) -> None:
    with pytest.raises(ZigbaseError) as exc_info:
        await async_client.collection("locked").create({"title": "nope"})
    assert exc_info.value.status == 403


def test_cursor_iterate_over_multiple_pages(client: ZigBase) -> None:
    posts = client.collection("cursorposts")
    seed_count = 70
    for i in range(seed_count):
        posts.create({"title": f"C{i}", "views": i})

    # Manually drive get_page to confirm the run actually spans > 2 pages,
    # and that the server-side sort order (`views` ascending) is honored
    # continuously across the cursor boundary, not just within one page.
    seen: list[str] = []
    seen_views: list[int] = []
    pages = 0
    page = posts.get_page(limit=30, sort="views", with_total=True)
    assert page.total_items == seed_count
    while True:
        pages += 1
        seen.extend(item["id"] for item in page.items)
        seen_views.extend(item["views"] for item in page.items)
        if not page.has_next or not page.next_cursor:
            break
        page = posts.get_page(cursor=page.next_cursor, limit=30, sort="views")
    assert pages > 2
    assert len(seen) == seed_count
    assert len(set(seen)) == seed_count
    assert seen_views == sorted(seen_views), "sort order must hold across the cursor boundary"
    assert seen_views == list(range(seed_count))

    # iterate() yields every record exactly once, following the cursor itself.
    iterated = list(posts.iterate(batch=30, sort="views"))
    assert len(iterated) == seed_count
    assert len({item["id"] for item in iterated}) == seed_count
