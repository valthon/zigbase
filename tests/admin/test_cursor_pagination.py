"""Integration tests for native server-side cursor (keyset) pagination.

Runs against a real `zigbase serve` (the STOCK binary: both pagination modes enabled,
stateless cursor tokens). Exercises the design's integration bullets: forward walk to
exhaustion (no dup/skip), drift-resistance under an inserted row, forward-then-back, the
cursor-vs-sort/filter 400s, expand in cursor mode, list-rule enforcement, and skipTotal.
"""
import json
from conftest import login, api_request


def setup_notes(page, list_rule=""):
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "notes", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}},
                   {"id": "", "name": "rank", "type": "number", "options": {"mode": "int"}}],
        "listRule": list_rule, "viewRule": list_rule, "createRule": "", "updateRule": "", "deleteRule": ""})
    page.reload()


def make_note(page, title, rank):
    r = api_request(page, "POST", "/api/collections/notes/records", {"title": title, "rank": str(rank)})
    assert r.status == 200 or r.status == 201, r.text()
    return r.json()


def list_cursor(page, query):
    r = api_request(page, "GET", "/api/collections/notes/records?" + query)
    return r


def test_forward_walk_no_dup_or_skip(page):
    setup_notes(page)
    for i in range(1, 8):  # 7 notes, rank 1..7
        make_note(page, f"n{i}", i)
    seen = []
    cursor = None
    pages = 0
    while True:
        q = "sort=rank&limit=3&perPage=3"
        # First page: no cursor token, but we want cursor mode -> send an empty cursor param.
        if cursor is None:
            q += "&cursor="
        else:
            q += "&cursor=" + cursor
        r = list_cursor(page, q)
        assert r.status == 200, r.text()
        body = r.json()
        for it in body["items"]:
            seen.append(it["rank"])
        pages += 1
        assert pages < 10
        if not body["hasNext"]:
            assert body["nextCursor"] is None
            break
        cursor = body["nextCursor"]
    assert seen == ["1", "2", "3", "4", "5", "6", "7"]


def test_insert_between_pages_does_not_drift(page):
    setup_notes(page)
    for i in range(1, 7):  # rank 1..6
        make_note(page, f"n{i}", i)
    p1 = list_cursor(page, "sort=rank&limit=2&cursor=").json()
    assert [it["rank"] for it in p1["items"]] == ["1", "2"]
    # Insert a row that would shift an OFFSET page (rank 0 sorts before everything).
    make_note(page, "n0", 0)
    p2 = list_cursor(page, "sort=rank&limit=2&cursor=" + p1["nextCursor"]).json()
    # Keyset is value-based: page 2 is still rank 3,4 — no dup, no skip from the insert.
    assert [it["rank"] for it in p2["items"]] == ["3", "4"]


def test_forward_then_back_round_trips(page):
    setup_notes(page)
    for i in range(1, 7):
        make_note(page, f"n{i}", i)
    p1 = list_cursor(page, "sort=rank&limit=2&cursor=").json()
    p2 = list_cursor(page, "sort=rank&limit=2&cursor=" + p1["nextCursor"]).json()
    assert [it["rank"] for it in p2["items"]] == ["3", "4"]
    assert p2["hasPrev"]
    back = list_cursor(page, "sort=rank&limit=2&cursor=" + p2["prevCursor"]).json()
    assert [it["rank"] for it in back["items"]] == ["1", "2"]


def test_changed_sort_or_filter_or_garbage_is_400(page):
    setup_notes(page)
    for i in range(1, 5):
        make_note(page, f"n{i}", i)
    p1 = list_cursor(page, "sort=rank&limit=2&cursor=").json()
    tok = p1["nextCursor"]
    # Same token, different sort -> 400.
    assert list_cursor(page, "sort=-rank&limit=2&cursor=" + tok).status == 400
    # Same token, added filter -> 400.
    assert list_cursor(page, "sort=rank&limit=2&filter=rank>0&cursor=" + tok).status == 400
    # Garbage token -> 400.
    assert list_cursor(page, "sort=rank&limit=2&cursor=%21%21garbage%21%21").status == 400


def test_skip_total_default_and_optin(page):
    setup_notes(page)
    for i in range(1, 5):
        make_note(page, f"n{i}", i)
    cheap = list_cursor(page, "sort=rank&limit=2&cursor=").json()
    assert "totalItems" not in cheap
    full = list_cursor(page, "sort=rank&limit=2&skipTotal=false&cursor=").json()
    assert full["totalItems"] == 4


def test_filter_constrains_the_cursor_window(page):
    # A user filter is AND-ed into the keyset query: the window must never reveal a row outside
    # the filter, across every page. (List-rule enforcement is covered by the records.zig unit
    # test "cursor: rule clause is still AND-ed"; here we use a filter because the superuser the
    # admin harness authenticates as bypasses list rules, but never bypasses an explicit filter.)
    setup_notes(page)
    for i in range(1, 6):  # rank 1..5
        make_note(page, f"n{i}", i)
    seen = []
    cursor = None
    while True:
        q = "sort=rank&limit=2&filter=rank>=3&cursor=" + (cursor if cursor else "")
        body = list_cursor(page, q).json()
        seen += [it["rank"] for it in body["items"]]
        if not body["hasNext"]:
            break
        cursor = body["nextCursor"]
    assert seen == ["3", "4", "5"]  # ranks 1,2 are outside the filter on every page


def test_expand_works_in_cursor_mode(page):
    # A relation field + expand should still resolve in cursor mode (orthogonal to keyset).
    login(page)
    api_request(page, "POST", "/api/collections", {"name": "authors", "type": "base",
        "fields": [{"id": "", "name": "name", "type": "text", "options": {}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    api_request(page, "POST", "/api/collections", {"name": "books", "type": "base",
        "fields": [{"id": "", "name": "title", "type": "text", "options": {}},
                   {"id": "", "name": "author", "type": "relation", "options": {"targetCollectionId": "authors", "maxSelect": 1}}],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": ""})
    page.reload()
    a = api_request(page, "POST", "/api/collections/authors/records", {"name": "Ada"}).json()
    api_request(page, "POST", "/api/collections/books/records", {"title": "B1", "author": a["id"]})
    r = api_request(page, "GET", "/api/collections/books/records?sort=created&limit=10&cursor=&expand=author")
    body = r.json()
    assert body["items"], body
    exp = body["items"][0].get("expand", {})
    assert exp.get("author", {}).get("name") == "Ada"
