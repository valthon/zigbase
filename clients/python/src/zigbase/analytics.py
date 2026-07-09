"""Product-analytics read APIs (requires ZigBase >= 0.9.0). Tenant-scoped,
fail closed.

Port of clients/typescript/src/analytics.ts (`AnalyticsService`);
cross-checked against clients/dart/lib/src/analytics.dart. Event/rollup rows
are returned as raw `dict[str, Any]` (their wire field names are the
snake_case of src/analytics/api.zig -- `actor_collection`, `occurred_at`,
`computed_at`, etc.) rather than a typed class, matching the Dart port.

`events` reuses `collection.py`'s `_parse_cursor_page`/`CursorPage` -- the
`GET /api/analytics/events` envelope (`{items, nextCursor, hasNext}`) is a
subset of the records cursor envelope, so the shared parser's `.get()`-based
field access degrades correctly (`prev_cursor`/`total_items` fall back to
`None`, `has_prev` to `False`).
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from zigbase._request import RequestSpec, encode_path_segment, ensure_object_body
from zigbase._transport import AsyncTransport, SyncTransport
from zigbase.collection import CursorPage, _parse_cursor_page
from zigbase.query import build_list_params, format_date

_EVENTS_OPT_KEYS = frozenset({"name", "actor", "since", "limit", "cursor"})
_ROLLUP_OPT_KEYS = frozenset({"from_", "to"})


def _pluck(opts: dict[str, Any], keys: frozenset[str]) -> dict[str, Any]:
    """Pop every key in `keys` out of `opts` into a new dict; raise
    `TypeError` if anything is left over (an unrecognized keyword) -- see
    `collection.py`'s identically-shaped helper."""
    picked = {key: opts.pop(key) for key in list(opts) if key in keys}
    if opts:
        unexpected = ", ".join(sorted(opts))
        raise TypeError(f"unexpected keyword argument(s): {unexpected}")
    return picked


def _iso(value: Any) -> str:
    """`datetime` -> `format_date` (matches JS `Date.prototype.toISOString()`
    byte-for-byte); a `str` passes through verbatim -- mirrors analytics.ts's
    `iso()` helper, which accepts either `string | Date`."""
    return format_date(value) if isinstance(value, datetime) else str(value)


def _events_query(opts: dict[str, Any]) -> dict[str, str]:
    query = build_list_params(cursor=opts.get("cursor"), limit=opts.get("limit"))
    if opts.get("name") is not None:
        query["name"] = str(opts["name"])
    if opts.get("actor") is not None:
        query["actor"] = str(opts["actor"])
    if opts.get("since") is not None:
        query["since"] = _iso(opts["since"])
    return query


def _rollup_query(opts: dict[str, Any]) -> dict[str, str]:
    query: dict[str, str] = {}
    if opts.get("from_") is not None:
        query["from"] = _iso(opts["from_"])
    if opts.get("to") is not None:
        query["to"] = _iso(opts["to"])
    return query


def _unwrap_items(body: Any, context: str) -> list[dict[str, Any]]:
    envelope = ensure_object_body(body, context=context)
    items = envelope.get("items")
    return list(items) if isinstance(items, list) else []


class AnalyticsService:
    """Product-analytics reads, over a `SyncTransport`."""

    def __init__(self, transport: SyncTransport) -> None:
        self._transport = transport

    def events(self, **opts: Any) -> CursorPage:
        """`GET /api/analytics/events` -- the tenant-scoped activity feed.
        401 anonymous; empty `items` with no active account; a superuser
        sees everything. Paginates with the house cursor: pass the previous
        page's `next_cursor` back as `cursor` to fetch the next one.

        Accepts `name`, `actor`, `since` (`str` or `datetime`), `limit`,
        `cursor`."""
        picked = _pluck(dict(opts), _EVENTS_OPT_KEYS)
        body = self._transport.request(
            RequestSpec(method="GET", path="/api/analytics/events", query=_events_query(picked))
        )
        return _parse_cursor_page(body, "events")

    def rollup(self, name: str, **opts: Any) -> list[dict[str, Any]]:
        """`GET /api/analytics/rollups/:name` -- a declared rollup's summary
        rows (unwraps `{items}`). 404 for an undeclared name; 403 for a
        non-account-grouped rollup queried by a non-superuser.

        Accepts `from_`/`to` (`str` or `datetime`; `from_` since `from` is a
        Python keyword)."""
        picked = _pluck(dict(opts), _ROLLUP_OPT_KEYS)
        body = self._transport.request(
            RequestSpec(
                method="GET",
                path=f"/api/analytics/rollups/{encode_path_segment(name)}",
                query=_rollup_query(picked),
            )
        )
        return _unwrap_items(body, "rollup")


class AsyncAnalyticsService:
    """`AnalyticsService`'s `asyncio` mirror, over an `AsyncTransport`."""

    def __init__(self, transport: AsyncTransport) -> None:
        self._transport = transport

    async def events(self, **opts: Any) -> CursorPage:
        """See `AnalyticsService.events`."""
        picked = _pluck(dict(opts), _EVENTS_OPT_KEYS)
        body = await self._transport.request(
            RequestSpec(method="GET", path="/api/analytics/events", query=_events_query(picked))
        )
        return _parse_cursor_page(body, "events")

    async def rollup(self, name: str, **opts: Any) -> list[dict[str, Any]]:
        """See `AnalyticsService.rollup`."""
        picked = _pluck(dict(opts), _ROLLUP_OPT_KEYS)
        body = await self._transport.request(
            RequestSpec(
                method="GET",
                path=f"/api/analytics/rollups/{encode_path_segment(name)}",
                query=_rollup_query(picked),
            )
        )
        return _unwrap_items(body, "rollup")


__all__ = ["AnalyticsService", "AsyncAnalyticsService"]
