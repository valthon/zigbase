"""Per-collection record CRUD, pagination, and auth.

Port of clients/typescript/src/collection.ts (`CollectionService`) and
clients/typescript/src/cursor.ts (`CursorPage`); cross-checked against
clients/dart/lib/src/collection.dart. Unlike collection.ts/collection.dart
(which take an `AuthStore` as a separate constructor argument),
`CollectionService`/`AsyncCollectionService` here read/write auth state
through `transport.auth_store` -- the transport already owns one (Task 6/7).

`CollectionService` wraps a `SyncTransport`; `AsyncCollectionService` wraps
an `AsyncTransport` and mirrors every method (`iterate` returns an
`AsyncIterator` instead of an `Iterator`). Both share the pure
envelope-parsing and option-validation helpers below -- only the
request-issuing bodies differ (`transport.request` vs. `await
transport.request`).
"""

from __future__ import annotations

from collections.abc import AsyncIterator, Iterator, Mapping
from dataclasses import dataclass
from typing import Any

from zigbase._request import RequestSpec, encode_path_segment, ensure_object_body, require_str_field
from zigbase._transport import AsyncTransport, SyncTransport
from zigbase.errors import ZigbaseError
from zigbase.query import build_list_params

# Keys accepted by `get_first_list_item`'s `**opts` -- every `get_list`
# option except `filter` (positional there) and `page`/`per_page` (fixed to
# 1/1). `skip_total` is accepted for `Omit<ListOpts, "filter">` parity with
# the TS/Dart signature but is always forced to `True` below, matching TS's
# `{...opts, filter, skipTotal: true}` object-literal override order.
_FIRST_ITEM_OPT_KEYS = frozenset({"sort", "expand", "fields", "search", "vector", "skip_total"})

# Keys accepted by `get_page`/`iterate`/`get_full_list`'s `**opts`. Vector
# search is offset-mode only (the server rejects vector + cursor), so it is
# deliberately absent here.
_CURSOR_OPT_KEYS = frozenset({"filter", "sort", "expand", "fields", "search"})


@dataclass
class AuthResponse:
    """Response shape from the password/refresh/OAuth2-complete auth
    endpoints. `record` is `None` for `auth_with_oauth2`'s response (the
    `/auth/oauth2/complete` endpoint sets cookies directly and does not
    return a record); `meta` is provider-specific OAuth2 metadata, populated
    from the envelope on password/refresh responses but always `None` on
    `auth_with_oauth2` (that endpoint has no metadata to report)."""

    token: str
    record: dict[str, Any] | None
    meta: dict[str, Any] | None


@dataclass
class ListResult:
    """Result of an offset-paginated `get_list` call. Mirrors the wire envelope."""

    page: int
    per_page: int
    total_items: int
    total_pages: int
    items: list[dict[str, Any]]


@dataclass
class CursorPage:
    """One page of native server-side cursor (keyset) pagination.

    The server (src/api/records.zig + src/query/keyset.zig) mints the
    opaque `next_cursor`/`prev_cursor` tokens; this client forwards whatever
    it received verbatim and never decodes, validates, or synthesizes one.
    `total_items` is `None` unless the page was fetched with `with_total=True`.
    """

    items: list[dict[str, Any]]
    next_cursor: str | None
    prev_cursor: str | None
    has_next: bool
    has_prev: bool
    total_items: int | None


def _pluck(opts: dict[str, Any], keys: frozenset[str]) -> dict[str, Any]:
    """Pop every key in `keys` out of `opts` into a new dict; raise
    `TypeError` if anything is left over (an unrecognized keyword)."""
    picked = {key: opts.pop(key) for key in list(opts) if key in keys}
    if opts:
        unexpected = ", ".join(sorted(opts))
        raise TypeError(f"unexpected keyword argument(s): {unexpected}")
    return picked


def _as_dict(body: Any, context: str) -> dict[str, Any]:
    """The server always answers these endpoints with a JSON object (never
    a bare array/scalar) -- but `_decode_response` returns `None` for any
    2xx with a 204/empty body, so this is a real runtime check, not a bare
    cast: `ensure_object_body` raises a clear `ZigbaseError` rather than
    letting a malformed 2xx crash on the first `.get(...)`."""
    return ensure_object_body(body, context=context)


def _collection_base(name: str) -> str:
    return f"/api/collections/{encode_path_segment(name)}"


def _records_base(name: str) -> str:
    return f"{_collection_base(name)}/records"


def _record_path(name: str, record_id: str) -> str:
    return f"{_records_base(name)}/{encode_path_segment(record_id)}"


def _parse_auth_response(body: Any, context: str) -> AuthResponse:
    """Parse a `{token, record?, meta?}` auth envelope. `token` is
    mandatory -- a missing/non-string `token` raises rather than silently
    defaulting to `""`, matching TS/Dart's throw-on-malformed-response
    behavior. `record`/`meta` fall back to `None` when absent or not shaped
    as an object -- those two stay optional."""
    envelope = _as_dict(body, context)
    raw_record = envelope.get("record")
    raw_meta = envelope.get("meta")
    return AuthResponse(
        token=require_str_field(envelope, "token", context=context),
        record=raw_record if isinstance(raw_record, dict) else None,
        meta=raw_meta if isinstance(raw_meta, dict) else None,
    )


def _oauth2_complete_body(
    *, provider: str, code: str, code_verifier: str, redirect_url: str, state: str | None
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "provider": provider,
        "code": code,
        "codeVerifier": code_verifier,
        "redirectUrl": redirect_url,
    }
    if state is not None:
        body["state"] = state
    return body


def _unwrap_items(body: Any, context: str) -> list[dict[str, Any]]:
    """Unwrap the house `{items}` list envelope used by
    `list_auth_providers`/`list_sessions`."""
    envelope = _as_dict(body, context)
    items = envelope.get("items")
    return list(items) if isinstance(items, list) else []


def _change_password_reauth_identity(
    principal: dict[str, Any] | None, target_id: str
) -> str | None:
    """Whether `change_password` should re-authenticate: the auth store's
    principal must BE the record whose password was just changed. Returns
    the identity (`email`, falling back to `username`) to re-auth with, or
    `None` if no re-auth is needed."""
    if principal is None or principal.get("id") != target_id:
        return None
    identity = principal.get("email") or principal.get("username")
    return identity if isinstance(identity, str) else None


def _parse_list_result(body: Any, context: str) -> ListResult:
    envelope = _as_dict(body, context)
    items = envelope.get("items")
    return ListResult(
        page=envelope.get("page", 0),
        per_page=envelope.get("perPage", 0),
        total_items=envelope.get("totalItems", 0),
        total_pages=envelope.get("totalPages", 0),
        items=list(items) if isinstance(items, list) else [],
    )


def _parse_cursor_page(body: Any, context: str) -> CursorPage:
    envelope = _as_dict(body, context)
    items = envelope.get("items")
    return CursorPage(
        items=list(items) if isinstance(items, list) else [],
        next_cursor=envelope.get("nextCursor"),
        prev_cursor=envelope.get("prevCursor"),
        has_next=bool(envelope.get("hasNext")),
        has_prev=bool(envelope.get("hasPrev")),
        total_items=envelope.get("totalItems"),
    )


def _non_advancing_cursor_error(url: str) -> ZigbaseError:
    return ZigbaseError(
        status=0,
        message=(
            "iterate(): the server returned a non-advancing cursor page "
            "(empty page or a repeated cursor); aborting to avoid an infinite loop."
        ),
        url=url,
    )


def _get_list_query(
    *,
    page: int,
    per_page: int,
    filter: str | None,
    sort: str | None,
    expand: str | None,
    fields: str | None,
    search: str | None,
    skip_total: bool,
    vector: str | None,
) -> dict[str, str]:
    """Build the offset-mode query params, clamping `per_page` to `[1, 500]`
    (server-clamped too; matching the client-side clamp in transport.ts/
    transport.dart avoids surprising the caller with a silently-differing
    `perPage`). `skip_total` is sent only when `True` -- offset mode already
    defaults to including totals server-side, so the default `False` here
    stays unsent (matches TS's `opts.skipTotal ? 1 : undefined`)."""
    clamped_per_page = min(max(per_page, 1), 500)
    return build_list_params(
        filter=filter,
        sort=sort,
        expand=expand,
        fields=fields,
        search=search,
        page=page,
        per_page=clamped_per_page,
        skip_total=True if skip_total else None,
        vector=vector,
    )


def _get_page_query(
    *,
    cursor: str | None,
    limit: int | None,
    with_total: bool,
    filter: str | None = None,
    sort: str | None = None,
    expand: str | None = None,
    fields: str | None = None,
    search: str | None = None,
) -> dict[str, str]:
    """Build the cursor-mode query params. `cursor` is sent only when
    non-empty (an empty/`None` cursor means "first page", so the token is
    omitted rather than sent as `cursor=`). `with_total=True` opts back into
    the total count the server skips by default in cursor mode, sent as the
    explicit `skipTotal=false` (matching TS's `opts.withTotal ? "false" :
    undefined`)."""
    return build_list_params(
        filter=filter,
        sort=sort,
        expand=expand,
        fields=fields,
        search=search,
        cursor=cursor if cursor else None,
        limit=limit if limit is not None else 30,
        skip_total=False if with_total else None,
    )


class CollectionService:
    """Per-collection auth + record CRUD + pagination, over a `SyncTransport`."""

    def __init__(self, transport: SyncTransport, name: str) -> None:
        self._transport = transport
        self.name = name

    # -----------------------------------------------------------------
    # Auth
    # -----------------------------------------------------------------

    def auth_with_password(self, identity: str, password: str) -> AuthResponse:
        """`POST /auth-with-password` with `{identity, password}`,
        `skip_auth=True`. Saves `{token, record}` to the transport's auth
        store."""
        body = self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/auth-with-password",
                body={"identity": identity, "password": password},
                skip_auth=True,
            )
        )
        auth = _parse_auth_response(body, "auth_with_password")
        self._transport.auth_store.save(auth.token, auth.record)
        return auth

    def auth_refresh(self) -> AuthResponse:
        """`POST /auth-refresh` with an empty body. Carries the bearer
        header (not `skip_auth`) but is exempt from the transport's
        single-flight 401-refresh branch (`is_refresh=True`) -- a 401 here
        propagates instead of recursing into its own refresh. Saves the
        response to the transport's auth store."""
        body = self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/auth-refresh",
                body={},
                is_refresh=True,
            )
        )
        auth = _parse_auth_response(body, "auth_refresh")
        self._transport.auth_store.save(auth.token, auth.record)
        return auth

    def list_auth_providers(self) -> list[dict[str, Any]]:
        """`GET /auth/oauth2/providers` -- unwraps the house `{items}` list
        envelope."""
        body = self._transport.request(
            RequestSpec(method="GET", path=f"{_collection_base(self.name)}/auth/oauth2/providers")
        )
        return _unwrap_items(body, "list_auth_providers")

    def oauth2_init(self, provider: str) -> dict[str, Any]:
        """`POST /auth/oauth2/initiate` with `{provider}` --
        `{authURL, clientId, scopes, state}`, passed through verbatim."""
        body = self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/auth/oauth2/initiate",
                body={"provider": provider},
            )
        )
        return _as_dict(body, "oauth2_init")

    def auth_with_oauth2(
        self,
        *,
        provider: str,
        code: str,
        code_verifier: str,
        redirect_url: str,
        state: str | None = None,
    ) -> AuthResponse:
        """`POST /auth/oauth2/complete`, `skip_auth=True`. The endpoint sets
        `zb_auth`/`zb_csrf` cookies directly and does not return a record;
        only the token is stored/returned (`record=None`)."""
        body = self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/auth/oauth2/complete",
                body=_oauth2_complete_body(
                    provider=provider,
                    code=code,
                    code_verifier=code_verifier,
                    redirect_url=redirect_url,
                    state=state,
                ),
                skip_auth=True,
            )
        )
        token = _as_dict(body, "auth_with_oauth2").get("token", "")
        self._transport.auth_store.save(token, None)
        return AuthResponse(token=token, record=None, meta=None)

    def logout(self) -> None:
        """`POST /auth-logout`. Clears the auth store even when the request
        fails (`try`/`finally`)."""
        try:
            self._transport.request(
                RequestSpec(method="POST", path=f"{_collection_base(self.name)}/auth-logout")
            )
        finally:
            self._transport.auth_store.clear()

    def request_verification(self, email: str) -> None:
        """`POST /request-verification` with `{email}`."""
        self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/request-verification",
                body={"email": email},
            )
        )

    def confirm_verification(self, token: str) -> None:
        """`POST /confirm-verification` with `{token}`, `skip_auth=True`."""
        self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/confirm-verification",
                body={"token": token},
                skip_auth=True,
            )
        )

    def request_password_reset(self, email: str) -> None:
        """`POST /request-password-reset` with `{email}`."""
        self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/request-password-reset",
                body={"email": email},
            )
        )

    def confirm_password_reset(self, token: str, password: str) -> None:
        """`POST /confirm-password-reset` with `{token, password}`,
        `skip_auth=True`."""
        self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/confirm-password-reset",
                body={"token": token, "password": password},
                skip_auth=True,
            )
        )

    def change_password(
        self, record_id: str, old_password: str, new_password: str
    ) -> dict[str, Any]:
        """`PATCH /records/:id` with `{password, oldPassword}` (requires
        ZigBase >= 0.10.0). The server verifies `old_password` against the
        TARGET record (superusers exempt) and rotates its tokenKey -- every
        outstanding session dies. When the auth store's current principal
        IS the target record, this additionally re-runs
        `auth_with_password` with the stored identity (`email`, falling
        back to `username`) and the new password, so a bearer-token client
        stays logged in too (a harmless extra login in cookie mode)."""
        rec = self.update(record_id, {"password": new_password, "oldPassword": old_password})
        identity = _change_password_reauth_identity(self._transport.auth_store.record, record_id)
        if identity is not None:
            self.auth_with_password(identity, new_password)
        return rec

    def list_sessions(self) -> list[dict[str, Any]]:
        """`GET /auth/sessions` -- the caller's active sessions, newest
        first (requires `.auth.session.store = .table`; `.epoch` mode
        answers 404). Unwraps `{items}`; wire keys stay snake_case as
        received (`last_seen`, `user_agent`, `is_current`)."""
        body = self._transport.request(
            RequestSpec(method="GET", path=f"{_collection_base(self.name)}/auth/sessions")
        )
        return _unwrap_items(body, "list_sessions")

    def revoke_session(self, session_id: str) -> None:
        """`DELETE /auth/sessions/:id` -- "log out THIS device" (table mode
        only)."""
        self._transport.request(
            RequestSpec(
                method="DELETE",
                path=f"{_collection_base(self.name)}/auth/sessions/{encode_path_segment(session_id)}",
            )
        )

    def revoke_all_sessions(self) -> None:
        """`DELETE /auth/sessions` -- "log out everywhere". Clears the auth
        store even when the request fails (parity with `logout`)."""
        try:
            self._transport.request(
                RequestSpec(method="DELETE", path=f"{_collection_base(self.name)}/auth/sessions")
            )
        finally:
            self._transport.auth_store.clear()

    # -----------------------------------------------------------------
    # Records (offset pagination)
    # -----------------------------------------------------------------

    def get_list(
        self,
        page: int = 1,
        per_page: int = 30,
        *,
        filter: str | None = None,
        sort: str | None = None,
        expand: str | None = None,
        fields: str | None = None,
        search: str | None = None,
        skip_total: bool = False,
        vector: str | None = None,
    ) -> ListResult:
        """`GET /records` (offset pagination)."""
        query = _get_list_query(
            page=page,
            per_page=per_page,
            filter=filter,
            sort=sort,
            expand=expand,
            fields=fields,
            search=search,
            skip_total=skip_total,
            vector=vector,
        )
        body = self._transport.request(
            RequestSpec(method="GET", path=_records_base(self.name), query=query)
        )
        return _parse_list_result(body, "get_list")

    def get_one(
        self, record_id: str, *, expand: str | None = None, fields: str | None = None
    ) -> dict[str, Any]:
        """`GET /records/:id`."""
        query = build_list_params(expand=expand, fields=fields)
        body = self._transport.request(
            RequestSpec(method="GET", path=_record_path(self.name, record_id), query=query)
        )
        return _as_dict(body, "get_one")

    def get_first_list_item(self, filter: str, **opts: Any) -> dict[str, Any]:
        """`get_list(1, 1, skip_total=True, filter=filter, ...)` sugar.

        Raises a synthesized 404 `ZigbaseError` when nothing matches.
        """
        picked = _pluck(dict(opts), _FIRST_ITEM_OPT_KEYS)
        picked.pop("skip_total", None)  # always forced True below
        result = self.get_list(1, 1, filter=filter, skip_total=True, **picked)
        if not result.items:
            raise ZigbaseError(
                status=404,
                message="No record found matching the filter.",
                url=_records_base(self.name),
            )
        return result.items[0]

    def create(
        self,
        body: Mapping[str, Any],
        *,
        expand: str | None = None,
        fields: str | None = None,
    ) -> dict[str, Any]:
        """`POST /records`. Auto-switches to multipart when `body` contains a file."""
        query = build_list_params(expand=expand, fields=fields)
        res = self._transport.request(
            RequestSpec(method="POST", path=_records_base(self.name), query=query, body=body)
        )
        return _as_dict(res, "create")

    def update(
        self,
        record_id: str,
        body: Mapping[str, Any],
        *,
        expand: str | None = None,
        fields: str | None = None,
    ) -> dict[str, Any]:
        """`PATCH /records/:id`. Auto-switches to multipart when `body` contains a file."""
        query = build_list_params(expand=expand, fields=fields)
        res = self._transport.request(
            RequestSpec(
                method="PATCH", path=_record_path(self.name, record_id), query=query, body=body
            )
        )
        return _as_dict(res, "update")

    def delete(self, record_id: str) -> None:
        """`DELETE /records/:id`."""
        self._transport.request(
            RequestSpec(method="DELETE", path=_record_path(self.name, record_id))
        )

    def get_abilities(self, record_id: str) -> dict[str, bool]:
        """`GET /records/:id/abilities` -- `{view, update, delete}` (requires ZigBase >= 0.9.0)."""
        body = self._transport.request(
            RequestSpec(method="GET", path=f"{_record_path(self.name, record_id)}/abilities")
        )
        envelope = _as_dict(body, "get_abilities")
        return {
            "view": bool(envelope.get("view", False)),
            "update": bool(envelope.get("update", False)),
            "delete": bool(envelope.get("delete", False)),
        }

    def get_page(
        self,
        *,
        cursor: str | None = None,
        limit: int | None = None,
        with_total: bool = False,
        **opts: Any,
    ) -> CursorPage:
        """Native server-side cursor (keyset) pagination.

        The server mints the opaque `next_cursor`/`prev_cursor` tokens; the
        client forwards whatever it received and never decodes or
        synthesizes one. Sending `limit` with no `cursor` requests the
        first cursor page.
        """
        picked = _pluck(dict(opts), _CURSOR_OPT_KEYS)
        query = _get_page_query(cursor=cursor, limit=limit, with_total=with_total, **picked)
        body = self._transport.request(
            RequestSpec(method="GET", path=_records_base(self.name), query=query)
        )
        return _parse_cursor_page(body, "get_page")

    def iterate(self, *, batch: int = 100, **opts: Any) -> Iterator[dict[str, Any]]:
        """Iterate every matching record, following the server's `next_cursor`.

        Raises a status-0 `ZigbaseError` if the server returns a
        non-advancing cursor page (an empty page that still claims
        `has_next`, or a `next_cursor` identical to the one just used) --
        a guard against a misbehaving server spinning this forever.
        """
        picked = _pluck(dict(opts), _CURSOR_OPT_KEYS)
        used_cursor: str | None = None
        page = self.get_page(limit=batch, **picked)
        while True:
            yield from page.items
            if not page.has_next or not page.next_cursor:
                return
            if not page.items or page.next_cursor == used_cursor:
                raise _non_advancing_cursor_error(_records_base(self.name))
            used_cursor = page.next_cursor
            page = self.get_page(cursor=used_cursor, limit=batch, **picked)

    def get_full_list(self, *, batch: int = 100, **opts: Any) -> list[dict[str, Any]]:
        """Accumulate every matching record into a list via `iterate`."""
        return list(self.iterate(batch=batch, **opts))


class AsyncCollectionService:
    """`CollectionService`'s `asyncio` mirror, over an `AsyncTransport`."""

    def __init__(self, transport: AsyncTransport, name: str) -> None:
        self._transport = transport
        self.name = name

    # -----------------------------------------------------------------
    # Auth
    # -----------------------------------------------------------------

    async def auth_with_password(self, identity: str, password: str) -> AuthResponse:
        """`POST /auth-with-password` with `{identity, password}`,
        `skip_auth=True`. Saves `{token, record}` to the transport's auth
        store."""
        body = await self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/auth-with-password",
                body={"identity": identity, "password": password},
                skip_auth=True,
            )
        )
        auth = _parse_auth_response(body, "auth_with_password")
        self._transport.auth_store.save(auth.token, auth.record)
        return auth

    async def auth_refresh(self) -> AuthResponse:
        """See `CollectionService.auth_refresh` for the full contract."""
        body = await self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/auth-refresh",
                body={},
                is_refresh=True,
            )
        )
        auth = _parse_auth_response(body, "auth_refresh")
        self._transport.auth_store.save(auth.token, auth.record)
        return auth

    async def list_auth_providers(self) -> list[dict[str, Any]]:
        """`GET /auth/oauth2/providers` -- unwraps the house `{items}` list
        envelope."""
        body = await self._transport.request(
            RequestSpec(method="GET", path=f"{_collection_base(self.name)}/auth/oauth2/providers")
        )
        return _unwrap_items(body, "list_auth_providers")

    async def oauth2_init(self, provider: str) -> dict[str, Any]:
        """`POST /auth/oauth2/initiate` with `{provider}` --
        `{authURL, clientId, scopes, state}`, passed through verbatim."""
        body = await self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/auth/oauth2/initiate",
                body={"provider": provider},
            )
        )
        return _as_dict(body, "oauth2_init")

    async def auth_with_oauth2(
        self,
        *,
        provider: str,
        code: str,
        code_verifier: str,
        redirect_url: str,
        state: str | None = None,
    ) -> AuthResponse:
        """See `CollectionService.auth_with_oauth2` for the full contract."""
        body = await self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/auth/oauth2/complete",
                body=_oauth2_complete_body(
                    provider=provider,
                    code=code,
                    code_verifier=code_verifier,
                    redirect_url=redirect_url,
                    state=state,
                ),
                skip_auth=True,
            )
        )
        token = _as_dict(body, "auth_with_oauth2").get("token", "")
        self._transport.auth_store.save(token, None)
        return AuthResponse(token=token, record=None, meta=None)

    async def logout(self) -> None:
        """`POST /auth-logout`. Clears the auth store even when the request
        fails (`try`/`finally`)."""
        try:
            await self._transport.request(
                RequestSpec(method="POST", path=f"{_collection_base(self.name)}/auth-logout")
            )
        finally:
            self._transport.auth_store.clear()

    async def request_verification(self, email: str) -> None:
        """`POST /request-verification` with `{email}`."""
        await self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/request-verification",
                body={"email": email},
            )
        )

    async def confirm_verification(self, token: str) -> None:
        """`POST /confirm-verification` with `{token}`, `skip_auth=True`."""
        await self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/confirm-verification",
                body={"token": token},
                skip_auth=True,
            )
        )

    async def request_password_reset(self, email: str) -> None:
        """`POST /request-password-reset` with `{email}`."""
        await self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/request-password-reset",
                body={"email": email},
            )
        )

    async def confirm_password_reset(self, token: str, password: str) -> None:
        """`POST /confirm-password-reset` with `{token, password}`,
        `skip_auth=True`."""
        await self._transport.request(
            RequestSpec(
                method="POST",
                path=f"{_collection_base(self.name)}/confirm-password-reset",
                body={"token": token, "password": password},
                skip_auth=True,
            )
        )

    async def change_password(
        self, record_id: str, old_password: str, new_password: str
    ) -> dict[str, Any]:
        """See `CollectionService.change_password` for the full contract."""
        rec = await self.update(record_id, {"password": new_password, "oldPassword": old_password})
        identity = _change_password_reauth_identity(self._transport.auth_store.record, record_id)
        if identity is not None:
            await self.auth_with_password(identity, new_password)
        return rec

    async def list_sessions(self) -> list[dict[str, Any]]:
        """`GET /auth/sessions` -- see `CollectionService.list_sessions` for
        the full contract."""
        body = await self._transport.request(
            RequestSpec(method="GET", path=f"{_collection_base(self.name)}/auth/sessions")
        )
        return _unwrap_items(body, "list_sessions")

    async def revoke_session(self, session_id: str) -> None:
        """`DELETE /auth/sessions/:id` -- "log out THIS device" (table mode
        only)."""
        await self._transport.request(
            RequestSpec(
                method="DELETE",
                path=f"{_collection_base(self.name)}/auth/sessions/{encode_path_segment(session_id)}",
            )
        )

    async def revoke_all_sessions(self) -> None:
        """`DELETE /auth/sessions` -- "log out everywhere". Clears the auth
        store even when the request fails (parity with `logout`)."""
        try:
            await self._transport.request(
                RequestSpec(method="DELETE", path=f"{_collection_base(self.name)}/auth/sessions")
            )
        finally:
            self._transport.auth_store.clear()

    # -----------------------------------------------------------------
    # Records (offset pagination)
    # -----------------------------------------------------------------

    async def get_list(
        self,
        page: int = 1,
        per_page: int = 30,
        *,
        filter: str | None = None,
        sort: str | None = None,
        expand: str | None = None,
        fields: str | None = None,
        search: str | None = None,
        skip_total: bool = False,
        vector: str | None = None,
    ) -> ListResult:
        """`GET /records` (offset pagination)."""
        query = _get_list_query(
            page=page,
            per_page=per_page,
            filter=filter,
            sort=sort,
            expand=expand,
            fields=fields,
            search=search,
            skip_total=skip_total,
            vector=vector,
        )
        body = await self._transport.request(
            RequestSpec(method="GET", path=_records_base(self.name), query=query)
        )
        return _parse_list_result(body, "get_list")

    async def get_one(
        self, record_id: str, *, expand: str | None = None, fields: str | None = None
    ) -> dict[str, Any]:
        """`GET /records/:id`."""
        query = build_list_params(expand=expand, fields=fields)
        body = await self._transport.request(
            RequestSpec(method="GET", path=_record_path(self.name, record_id), query=query)
        )
        return _as_dict(body, "get_one")

    async def get_first_list_item(self, filter: str, **opts: Any) -> dict[str, Any]:
        """`get_list(1, 1, skip_total=True, filter=filter, ...)` sugar.

        Raises a synthesized 404 `ZigbaseError` when nothing matches.
        """
        picked = _pluck(dict(opts), _FIRST_ITEM_OPT_KEYS)
        picked.pop("skip_total", None)  # always forced True below
        result = await self.get_list(1, 1, filter=filter, skip_total=True, **picked)
        if not result.items:
            raise ZigbaseError(
                status=404,
                message="No record found matching the filter.",
                url=_records_base(self.name),
            )
        return result.items[0]

    async def create(
        self,
        body: Mapping[str, Any],
        *,
        expand: str | None = None,
        fields: str | None = None,
    ) -> dict[str, Any]:
        """`POST /records`. Auto-switches to multipart when `body` contains a file."""
        query = build_list_params(expand=expand, fields=fields)
        res = await self._transport.request(
            RequestSpec(method="POST", path=_records_base(self.name), query=query, body=body)
        )
        return _as_dict(res, "create")

    async def update(
        self,
        record_id: str,
        body: Mapping[str, Any],
        *,
        expand: str | None = None,
        fields: str | None = None,
    ) -> dict[str, Any]:
        """`PATCH /records/:id`. Auto-switches to multipart when `body` contains a file."""
        query = build_list_params(expand=expand, fields=fields)
        res = await self._transport.request(
            RequestSpec(
                method="PATCH", path=_record_path(self.name, record_id), query=query, body=body
            )
        )
        return _as_dict(res, "update")

    async def delete(self, record_id: str) -> None:
        """`DELETE /records/:id`."""
        await self._transport.request(
            RequestSpec(method="DELETE", path=_record_path(self.name, record_id))
        )

    async def get_abilities(self, record_id: str) -> dict[str, bool]:
        """`GET /records/:id/abilities` -- `{view, update, delete}` (requires ZigBase >= 0.9.0)."""
        body = await self._transport.request(
            RequestSpec(method="GET", path=f"{_record_path(self.name, record_id)}/abilities")
        )
        envelope = _as_dict(body, "get_abilities")
        return {
            "view": bool(envelope.get("view", False)),
            "update": bool(envelope.get("update", False)),
            "delete": bool(envelope.get("delete", False)),
        }

    async def get_page(
        self,
        *,
        cursor: str | None = None,
        limit: int | None = None,
        with_total: bool = False,
        **opts: Any,
    ) -> CursorPage:
        """Native server-side cursor (keyset) pagination. See
        `CollectionService.get_page` for the full contract."""
        picked = _pluck(dict(opts), _CURSOR_OPT_KEYS)
        query = _get_page_query(cursor=cursor, limit=limit, with_total=with_total, **picked)
        body = await self._transport.request(
            RequestSpec(method="GET", path=_records_base(self.name), query=query)
        )
        return _parse_cursor_page(body, "get_page")

    async def iterate(self, *, batch: int = 100, **opts: Any) -> AsyncIterator[dict[str, Any]]:
        """Async-iterate every matching record, following the server's
        `next_cursor`. See `CollectionService.iterate` for the
        non-advancing-cursor guard this shares."""
        picked = _pluck(dict(opts), _CURSOR_OPT_KEYS)
        used_cursor: str | None = None
        page = await self.get_page(limit=batch, **picked)
        while True:
            for item in page.items:
                yield item
            if not page.has_next or not page.next_cursor:
                return
            if not page.items or page.next_cursor == used_cursor:
                raise _non_advancing_cursor_error(_records_base(self.name))
            used_cursor = page.next_cursor
            page = await self.get_page(cursor=used_cursor, limit=batch, **picked)

    async def get_full_list(self, *, batch: int = 100, **opts: Any) -> list[dict[str, Any]]:
        """Accumulate every matching record into a list via `iterate`."""
        return [item async for item in self.iterate(batch=batch, **opts)]


__all__ = [
    "AsyncCollectionService",
    "AuthResponse",
    "CollectionService",
    "CursorPage",
    "ListResult",
]
