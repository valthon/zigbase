"""Top-level client facades: `ZigBase` and `AsyncZigBase`.

Port of clients/typescript/src/client.ts (`createClient`); cross-checked
against clients/dart/lib/src/client.dart's `ZigbaseClient` for the
close()/ownership and `with_account` sibling contract. `ZigBase` assembles a
`SyncTransport` plus every service (`CollectionService` per collection name,
`FilesService`, `AccountsService`, `AnalyticsService`, `SendersService`)
around one `AuthStore`; `AsyncZigBase` is its `asyncio` mirror over an
`AsyncTransport`. Unlike collection.ts/collection.dart's per-service
constructor shape, every service here reads/writes auth state through
`transport.auth_store` (Task 6/7's design), so the facade never has to pass
`auth_store` to a service explicitly.

Ownership: a self-created `httpx.Client`/`httpx.AsyncClient` (no
`http_client` passed in) is closed by `close()`/`aclose()`; a caller-supplied
one is not. `with_account` returns a sibling `ZigBase`/`AsyncZigBase` built
by re-invoking the constructor with this instance's `auth_store` and
`_http_client` passed through verbatim as its `http_client` -- the
constructor's existing "an explicit `http_client` is never owned" rule then
makes the sibling correctly never own the shared client, without any
sibling-specific code path. A login/logout via either client's `auth_store`
is visible to both (same instance); closing the parent closes the shared
client for every sibling. Using a closed client raises httpx's own
`RuntimeError` -- there are no extra guards here (unlike client.dart's
`StateError` gate on every accessor).

Realtime (Task 6) is `asyncio`-only: `AsyncZigBase.realtime` lazily builds
ONE `RealtimeService` per client instance (bound to `base_url`/`auth_store`,
same instance on every later access) and `aclose()` tears it down first --
before the transport -- since `RealtimeService.close()` needs the running
loop and cancels its own tasks, while closing the transport is just an
`httpx` client shutdown. `with_account` siblings each get their own lazily-
built `realtime` service (subscriptions are tied to one connection, not
shared across account-scoped siblings), constructed with the same injected
`realtime_connector`/`on_realtime_error` as the parent. `ZigBase.realtime`
raises `RuntimeError` naming `AsyncZigBase` -- there is no sync realtime
transport.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Mapping
from types import TracebackType
from typing import Any, NoReturn

import httpx

from zigbase._request import RequestSpec, ensure_object_body
from zigbase._transport import AsyncTransport, SyncTransport
from zigbase.accounts import AccountsService, AsyncAccountsService
from zigbase.analytics import AnalyticsService, AsyncAnalyticsService
from zigbase.auth_store import AuthStore, MemoryAuthStore
from zigbase.collection import AsyncCollectionService, CollectionService
from zigbase.files import AsyncFilesService, FilesService
from zigbase.realtime import RealtimeConnection, RealtimeService, _default_connector
from zigbase.senders import AsyncSendersService, SendersService

_SEND_OPT_KEYS = frozenset({"query", "body", "headers"})


def _pluck(opts: dict[str, Any], keys: frozenset[str]) -> dict[str, Any]:
    """Pop every key in `keys` out of `opts` into a new dict; raise
    `TypeError` if anything is left over (an unrecognized keyword) -- see
    collection.py's identically-shaped helper."""
    picked = {key: opts.pop(key) for key in list(opts) if key in keys}
    if opts:
        unexpected = ", ".join(sorted(opts))
        raise TypeError(f"unexpected keyword argument(s): {unexpected}")
    return picked


def _normalize_base_url(base_url: str) -> str:
    return base_url.rstrip("/")


class ZigBase:
    """The official ZigBase Python client, synchronous.

    ```python
    with ZigBase("http://127.0.0.1:8090") as zb:
        zb.collection("users").auth_with_password("a@b.com", "secret")
        posts = zb.collection("posts").get_list()
    ```
    """

    def __init__(
        self,
        base_url: str,
        *,
        auth_store: AuthStore | None = None,
        auto_refresh: bool = False,
        auth_collection: str | None = None,
        account_id: str | None = None,
        lang: str | None = None,
        max_retries: int = 3,
        http_client: httpx.Client | None = None,
    ) -> None:
        self.base_url = _normalize_base_url(base_url)
        self.auth_store: AuthStore = auth_store if auth_store is not None else MemoryAuthStore()
        self._auto_refresh = auto_refresh
        self._auth_collection = auth_collection
        self._lang = lang
        self._max_retries = max_retries
        self._owns_client = http_client is None
        self._http_client = http_client if http_client is not None else httpx.Client()
        self._transport = SyncTransport(
            self.base_url,
            self.auth_store,
            auth_collection=auth_collection,
            auto_refresh=auto_refresh,
            account_id=account_id,
            lang=lang,
            max_retries=max_retries,
            http_client=self._http_client,
        )
        self._files: FilesService | None = None
        self._accounts: AccountsService | None = None
        self._analytics: AnalyticsService | None = None
        self._senders: SendersService | None = None

    def collection(self, name: str) -> CollectionService:
        """A `CollectionService` bound to `name`. Matches client.ts's
        `collection()`: a fresh instance every call (no per-name cache)."""
        return CollectionService(self._transport, name)

    @property
    def files(self) -> FilesService:
        if self._files is None:
            self._files = FilesService(self._transport, self.base_url)
        return self._files

    @property
    def accounts(self) -> AccountsService:
        if self._accounts is None:
            self._accounts = AccountsService(self._transport)
        return self._accounts

    @property
    def analytics(self) -> AnalyticsService:
        if self._analytics is None:
            self._analytics = AnalyticsService(self._transport)
        return self._analytics

    @property
    def senders(self) -> SendersService:
        if self._senders is None:
            self._senders = SendersService(self._transport)
        return self._senders

    @property
    def realtime(self) -> NoReturn:
        """Realtime (WebSocket) subscriptions are `asyncio`-only; use
        `AsyncZigBase` instead."""
        raise RuntimeError("Realtime is async-only; use AsyncZigBase")

    def send(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        body: Mapping[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> Any:
        """Issue a request through the shared transport and return its
        parsed JSON body (or `None` for a 204/empty body): the auth header,
        401 auto-refresh, and 429 backoff all apply, exactly as for every
        service call (they share this same transport)."""
        return self._transport.request(
            RequestSpec(method=method, path=path, query=query, body=body, headers=headers)
        )

    def raw_request(self, method: str, path: str, **kw: Any) -> httpx.Response:
        """Escape hatch: returns the `httpx.Response` as-is -- no JSON
        parsing, no error mapping, no 401 refresh, no 429 retry. Accepts the
        same `query`/`body`/`headers` keywords as `send`; auth/lang/account
        headers and body encoding still apply."""
        picked = _pluck(dict(kw), _SEND_OPT_KEYS)
        return self._transport.raw_request(
            RequestSpec(
                method=method,
                path=path,
                query=picked.get("query"),
                body=picked.get("body"),
                headers=picked.get("headers"),
            )
        )

    def health(self) -> dict[str, Any]:
        """`GET /api/health`."""
        return ensure_object_body(self.send("GET", "/api/health"), context="health")

    def with_account(self, account_id: str) -> ZigBase:
        """A sibling `ZigBase` sharing this instance's `auth_store` and
        underlying httpx client (a login/logout on either is visible to
        both), but sending `X-Account-Id: <account_id>` on every request.
        See the class doc for the close()/ownership implications."""
        return ZigBase(
            self.base_url,
            auth_store=self.auth_store,
            auto_refresh=self._auto_refresh,
            auth_collection=self._auth_collection,
            account_id=account_id,
            lang=self._lang,
            max_retries=self._max_retries,
            http_client=self._http_client,
        )

    def close(self) -> None:
        """Close the underlying `httpx.Client`, but only if this instance
        created it (no `http_client` was passed in, including every
        `with_account` sibling). Idempotent: `httpx.Client.close()` already
        tolerates being called more than once."""
        if self._owns_client:
            self._http_client.close()

    def __enter__(self) -> ZigBase:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()


class AsyncZigBase:
    """`ZigBase`'s `asyncio` mirror, over an `AsyncTransport`.

    ```python
    async with AsyncZigBase("http://127.0.0.1:8090") as zb:
        await zb.collection("users").auth_with_password("a@b.com", "secret")
        posts = await zb.collection("posts").get_list()
    ```
    """

    def __init__(
        self,
        base_url: str,
        *,
        auth_store: AuthStore | None = None,
        auto_refresh: bool = False,
        auth_collection: str | None = None,
        account_id: str | None = None,
        lang: str | None = None,
        max_retries: int = 3,
        http_client: httpx.AsyncClient | None = None,
        realtime_connector: Callable[[str], Awaitable[RealtimeConnection]] | None = None,
        on_realtime_error: Callable[[str], None] | None = None,
    ) -> None:
        self.base_url = _normalize_base_url(base_url)
        self.auth_store: AuthStore = auth_store if auth_store is not None else MemoryAuthStore()
        self._auto_refresh = auto_refresh
        self._auth_collection = auth_collection
        self._lang = lang
        self._max_retries = max_retries
        self._owns_client = http_client is None
        self._http_client = http_client if http_client is not None else httpx.AsyncClient()
        self._transport = AsyncTransport(
            self.base_url,
            self.auth_store,
            auth_collection=auth_collection,
            auto_refresh=auto_refresh,
            account_id=account_id,
            lang=lang,
            max_retries=max_retries,
            http_client=self._http_client,
        )
        self._files: AsyncFilesService | None = None
        self._accounts: AsyncAccountsService | None = None
        self._analytics: AsyncAnalyticsService | None = None
        self._senders: AsyncSendersService | None = None
        self._realtime_connector = realtime_connector
        self._on_realtime_error = on_realtime_error
        self._realtime: RealtimeService | None = None

    def collection(self, name: str) -> AsyncCollectionService:
        """See `ZigBase.collection`."""
        return AsyncCollectionService(self._transport, name)

    @property
    def files(self) -> AsyncFilesService:
        if self._files is None:
            self._files = AsyncFilesService(self._transport, self.base_url)
        return self._files

    @property
    def accounts(self) -> AsyncAccountsService:
        if self._accounts is None:
            self._accounts = AsyncAccountsService(self._transport)
        return self._accounts

    @property
    def analytics(self) -> AsyncAnalyticsService:
        if self._analytics is None:
            self._analytics = AsyncAnalyticsService(self._transport)
        return self._analytics

    @property
    def senders(self) -> AsyncSendersService:
        if self._senders is None:
            self._senders = AsyncSendersService(self._transport)
        return self._senders

    @property
    def realtime(self) -> RealtimeService:
        """Lazily-constructed `RealtimeService` bound to this client's
        `base_url`/`auth_store` -- the same instance on every later access.
        Uses the constructor's `realtime_connector` when one was given, else
        the default `websockets`-backed connector (requires the
        `zigbase[realtime]` extra; only imported when a connection is
        actually attempted). Each `with_account` sibling gets its own
        instance -- see the module docstring."""
        if self._realtime is None:
            self._realtime = RealtimeService(
                self.base_url,
                self.auth_store,
                connector=self._realtime_connector or _default_connector,
                on_error=self._on_realtime_error,
            )
        return self._realtime

    async def send(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        body: Mapping[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> Any:
        """See `ZigBase.send`."""
        return await self._transport.request(
            RequestSpec(method=method, path=path, query=query, body=body, headers=headers)
        )

    async def raw_request(self, method: str, path: str, **kw: Any) -> httpx.Response:
        """See `ZigBase.raw_request`."""
        picked = _pluck(dict(kw), _SEND_OPT_KEYS)
        return await self._transport.raw_request(
            RequestSpec(
                method=method,
                path=path,
                query=picked.get("query"),
                body=picked.get("body"),
                headers=picked.get("headers"),
            )
        )

    async def health(self) -> dict[str, Any]:
        """`GET /api/health`."""
        return ensure_object_body(await self.send("GET", "/api/health"), context="health")

    def with_account(self, account_id: str) -> AsyncZigBase:
        """See `ZigBase.with_account`. The sibling gets its own lazily-built
        `realtime` service (constructed with the same `realtime_connector`/
        `on_realtime_error` as this instance) -- not shared with it."""
        return AsyncZigBase(
            self.base_url,
            auth_store=self.auth_store,
            auto_refresh=self._auto_refresh,
            auth_collection=self._auth_collection,
            account_id=account_id,
            lang=self._lang,
            max_retries=self._max_retries,
            http_client=self._http_client,
            realtime_connector=self._realtime_connector,
            on_realtime_error=self._on_realtime_error,
        )

    async def aclose(self) -> None:
        """See `ZigBase.close`. Closes the `realtime` service first, if one
        was ever built -- it needs the running loop to cancel its own tasks,
        so it must run before the transport's `httpx` client (which doesn't)
        is torn down."""
        if self._realtime is not None:
            await self._realtime.close()
        if self._owns_client:
            await self._http_client.aclose()

    async def __aenter__(self) -> AsyncZigBase:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        await self.aclose()


__all__ = ["AsyncZigBase", "ZigBase"]
