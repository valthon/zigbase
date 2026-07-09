"""Synchronous HTTP transport: header assembly, JSON/multipart bodies, the
401 single-flight refresh state machine, and 429 backoff.

Port of the `SyncTransport` half of clients/typescript/src/transport.ts
(`Transport`), with the single-flight-lock shape mirroring
clients/dart/lib/src/transport.dart's `_awaitRefresh`. `AsyncTransport`
(Task 7) lands in this same module and shares the pure, module-level
helpers below (`_build_headers`, `_prepare_request`, `_decode_response`,
`_compute_backoff`) -- only the stateful request-loop and refresh
single-flight logic differ between the sync and async classes.

429 backoff retries for any HTTP method, matching transport.ts/
transport.dart (neither gates on idempotency): a 429 is a rejection before
the request is processed, so retrying it can't duplicate a write's side
effect.
"""

from __future__ import annotations

import asyncio
import json
import math
import threading
import time
from typing import Any

import httpx

from zigbase._multipart import encode_body, has_file
from zigbase._request import RequestSpec
from zigbase.auth_store import AuthStore
from zigbase.errors import ZigbaseError, parse_error_response

_MAX_BACKOFF_SECONDS = 30.0

# Module-level and monkeypatchable so tests never actually wait.
_sleep = time.sleep
_asleep = asyncio.sleep


def _set_header(headers: dict[str, str], name: str, value: str) -> None:
    """Set `name` to `value`, first removing any existing key that matches
    case-insensitively -- mirrors JS `Headers.set` / Dart's `_setHeader` so a
    spec header like `"authorization"` can't survive alongside our
    canonically-cased `"Authorization"`."""
    lower = name.lower()
    for existing in [k for k in headers if k.lower() == lower]:
        del headers[existing]
    headers[name] = value


def _has_header(headers: dict[str, str], name: str) -> bool:
    lower = name.lower()
    return any(k.lower() == lower for k in headers)


def _build_headers(
    spec_headers: dict[str, str] | None,
    *,
    token: str | None,
    skip_auth: bool,
    lang: str | None,
    account_id: str | None,
) -> dict[str, str]:
    """Assemble the effective request headers (rule 1): `Authorization` and
    `Accept-Language` are always (re)applied on top of any caller-supplied
    header of the same name; `X-Account-Id` is applied only when the caller
    hasn't already set it -- so a per-request `X-Account-Id` wins over the
    transport-wide `account_id`, matching transport.ts/transport.dart."""
    headers: dict[str, str] = dict(spec_headers) if spec_headers else {}
    if not skip_auth and token:
        _set_header(headers, "Authorization", f"Bearer {token}")
    if lang:
        _set_header(headers, "Accept-Language", lang)
    if account_id and not _has_header(headers, "X-Account-Id"):
        _set_header(headers, "X-Account-Id", account_id)
    return headers


def _to_multipart_data(fields: list[tuple[str, str]]) -> dict[str, str | list[str]]:
    """Fold `encode_body`'s (possibly key-repeating) field list into the
    `dict[str, str | list[str]]` shape httpx's multipart encoder expects,
    preserving repeats as a list under one key."""
    data: dict[str, str | list[str]] = {}
    for key, value in fields:
        existing = data.get(key)
        if existing is None:
            data[key] = value
        elif isinstance(existing, list):
            existing.append(value)
        else:
            data[key] = [existing, value]
    return data


def _prepare_request(
    spec: RequestSpec,
    *,
    token: str | None,
    lang: str | None,
    account_id: str | None,
) -> dict[str, Any]:
    """Build the keyword arguments for `httpx.Client.request` /
    `httpx.AsyncClient.request` from a `RequestSpec` -- pure aside from
    reading `token` (already resolved by the caller), so both transports
    share it verbatim."""
    kwargs: dict[str, Any] = {
        "headers": _build_headers(
            spec.headers, token=token, skip_auth=spec.skip_auth, lang=lang, account_id=account_id
        ),
        "params": spec.query,
    }
    if spec.timeout is not None:
        kwargs["timeout"] = spec.timeout
    # A GET body is dropped, matching transport.ts's `buildRequestInit`
    # (`opts.body !== undefined && opts.method !== "GET"`) and
    # transport.dart's `_perform`/`_maybeBufferMultipart` (both gate on
    # `!isGet`).
    if spec.body is not None and spec.method.upper() != "GET":
        if has_file(spec.body):
            encoded = encode_body(spec.body)
            # Never set Content-Type manually (rule 6): httpx derives the
            # multipart boundary from files= being present.
            kwargs["data"] = _to_multipart_data(encoded.fields or [])
            kwargs["files"] = encoded.files or []
        else:
            kwargs["json"] = encode_body(spec.body).json_body
    return kwargs


def _decode_response(response: httpx.Response) -> Any:
    """Decode a 2xx response body (rule 2): 204 or an empty body -> `None`;
    otherwise `json.loads`. Assumes the response body has already been read
    (true for a sync `httpx.Response`; the async transport awaits
    `response.aread()` first)."""
    if response.status_code == 204:
        return None
    text = response.text
    if not text:
        return None
    return json.loads(text)


def _compute_backoff(retry_after: str | None, attempt: int) -> float:
    """429 backoff delay (rule 4): a positive, finite numeric `Retry-After`
    is honored verbatim (seconds); otherwise an exponential delay capped at
    `_MAX_BACKOFF_SECONDS`."""
    if retry_after is not None:
        try:
            seconds = float(retry_after)
        except ValueError:
            seconds = float("nan")
        if math.isfinite(seconds) and seconds > 0:
            return seconds
    return min(float(2**attempt) * 0.2, _MAX_BACKOFF_SECONDS)


def _parse_refresh_result(result: Any, path: str) -> tuple[str | None, dict[str, Any] | None]:
    """Extract `(token, record)` from an `auth-refresh` 2xx body (rule: mirror
    transport.ts's untyped property access, which the JS engine resolves
    without a runtime shape check).

    An EMPTY body (204, or a 2xx with no text) decodes to `None` here and to
    `undefined` in JS; accessing `.token` on `undefined` THROWS a TypeError
    there, which fails the refresh and lets the caller's ORIGINAL 401
    propagate without touching the auth store -- so this raises too, rather
    than silently overwriting a valid token/record with `None`. A body that
    parses but isn't shaped like `{token, record}` (a list, string, number,
    or a dict missing "token") does NOT throw in JS -- `.token` on any of
    those is simply `undefined`, and `authStore.save(undefined, undefined)`
    proceeds -- so that case still clears the store below rather than
    raising, matching that silent behavior too.
    """
    if result is None:
        raise ZigbaseError(
            status=0,
            message="auth-refresh returned an empty response body.",
            url=path,
        )
    token = result.get("token") if isinstance(result, dict) else None
    record = result.get("record") if isinstance(result, dict) else None
    return token, record


class _RefreshFlight:
    """A single in-flight refresh, joinable by any number of waiters."""

    def __init__(self) -> None:
        self._done = threading.Event()
        self.error: BaseException | None = None

    def wait(self) -> None:
        self._done.wait()
        if self.error is not None:
            raise self.error

    def finish(self, error: BaseException | None) -> None:
        self.error = error
        self._done.set()


class SyncTransport:
    """The HTTP engine every sync service builds on."""

    def __init__(
        self,
        base_url: str,
        auth_store: AuthStore,
        *,
        auth_collection: str | None = None,
        auto_refresh: bool = False,
        account_id: str | None = None,
        lang: str | None = None,
        max_retries: int = 3,
        http_client: httpx.Client | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._auth_store = auth_store
        self._auth_collection = auth_collection
        self._auto_refresh = auto_refresh
        self._account_id = account_id
        self._lang = lang
        self._max_retries = max_retries
        self._owns_client = http_client is None
        self._client = http_client if http_client is not None else httpx.Client()

        # The single-flight 401 refresh. The first 401 starts it; every 401
        # that lands while it runs joins the SAME flight and then retries its
        # own request once (still bounded per-exchange by `did_refresh` in
        # `_exchange`), so a parallel burst of expired-token requests all
        # succeed after exactly one refresh call. `_refresh_guard` only ever
        # protects the tiny check-and-set of `_refresh_flight` -- it is never
        # held across the network call or a waiter's `flight.wait()`, so it
        # cannot deadlock against itself or against a waiter.
        self._refresh_guard = threading.Lock()
        self._refresh_flight: _RefreshFlight | None = None

    @property
    def auth_store(self) -> AuthStore:
        """The `AuthStore` this transport reads its bearer token from --
        `CollectionService` saves/clears through this instead of taking a
        separate constructor argument (unlike collection.ts/collection.dart,
        which are handed an `AuthStore` directly)."""
        return self._auth_store

    def close(self) -> None:
        """Close the underlying `httpx.Client`, but only if this transport
        created it -- a caller-supplied client outlives this transport."""
        if self._owns_client:
            self._client.close()

    def raw_request(self, spec: RequestSpec) -> httpx.Response:
        """Escape hatch: perform exactly one HTTP call and return the
        `httpx.Response` as-is -- no error mapping, no 401 refresh, no 429
        retry. Auth/lang/account headers and body encoding still apply."""
        return self._perform_once(spec)

    def request(self, spec: RequestSpec) -> Any:
        """Perform `spec`, following the 401-refresh/429-backoff state
        machine, and return the parsed JSON body (or `None` for a 204/empty
        body). Raises `ZigbaseError` for a non-2xx response that survives
        that state machine."""
        response = self._exchange(spec)
        return _decode_response(response)

    # --- internals -------------------------------------------------------

    def _perform_once(self, spec: RequestSpec) -> httpx.Response:
        url = self._base_url + spec.path
        kwargs = _prepare_request(
            spec, token=self._auth_store.token, lang=self._lang, account_id=self._account_id
        )
        return self._client.request(spec.method, url, **kwargs)

    def _exchange(self, spec: RequestSpec) -> httpx.Response:
        did_refresh = False
        attempt = 0

        while True:
            response = self._perform_once(spec)

            if response.is_success:
                return response

            if (
                response.status_code == 401
                and self._auto_refresh
                and self._auth_collection is not None
                and not did_refresh
                and not spec.skip_auth
                and not spec.is_refresh
                and self._auth_store.token
            ):
                did_refresh = True
                try:
                    self._await_refresh()
                    continue
                except Exception:
                    # Refresh failed -- fall through and raise this
                    # request's ORIGINAL 401 below, not the refresh error.
                    pass

            if response.status_code == 429 and attempt < self._max_retries:
                delay = _compute_backoff(response.headers.get("Retry-After"), attempt)
                attempt += 1
                _sleep(delay)
                continue

            raise parse_error_response(
                response.status_code,
                response.text,
                str(response.url),
                reason_phrase=response.reason_phrase or None,
            )

    def _await_refresh(self) -> None:
        """Join the in-flight refresh, or become its owner and start it."""
        with self._refresh_guard:
            flight = self._refresh_flight
            if flight is not None:
                is_owner = False
            else:
                flight = _RefreshFlight()
                self._refresh_flight = flight
                is_owner = True

        if not is_owner:
            flight.wait()
            return

        error: BaseException | None = None
        try:
            self._perform_refresh()
        except BaseException as exc:
            error = exc
            raise
        finally:
            with self._refresh_guard:
                self._refresh_flight = None
            flight.finish(error)

    def _perform_refresh(self) -> None:
        assert self._auth_collection is not None
        spec = RequestSpec(
            method="POST",
            path=f"/api/collections/{self._auth_collection}/auth-refresh",
            is_refresh=True,
        )
        result = self.request(spec)
        self._auth_store.save(*_parse_refresh_result(result, spec.path))


class _AsyncRefreshFlight:
    """`_RefreshFlight`'s `asyncio.Event` counterpart -- a single in-flight
    refresh, joinable by any number of waiting coroutines."""

    def __init__(self) -> None:
        self._done = asyncio.Event()
        self.error: BaseException | None = None

    async def wait(self) -> None:
        await self._done.wait()
        if self.error is not None:
            raise self.error

    def finish(self, error: BaseException | None) -> None:
        self.error = error
        self._done.set()


class AsyncTransport:
    """The `asyncio` mirror of `SyncTransport`, sharing every pure helper
    above (`_build_headers`, `_prepare_request`, `_decode_response`,
    `_compute_backoff`) -- only the request loop and refresh single-flight
    are duplicated, since those are inherently await-shaped."""

    def __init__(
        self,
        base_url: str,
        auth_store: AuthStore,
        *,
        auth_collection: str | None = None,
        auto_refresh: bool = False,
        account_id: str | None = None,
        lang: str | None = None,
        max_retries: int = 3,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._auth_store = auth_store
        self._auth_collection = auth_collection
        self._auto_refresh = auto_refresh
        self._account_id = account_id
        self._lang = lang
        self._max_retries = max_retries
        self._owns_client = http_client is None
        self._client = http_client if http_client is not None else httpx.AsyncClient()

        # See SyncTransport's equivalent fields: same single-flight shape,
        # `asyncio.Lock`/`asyncio.Event` instead of their `threading`
        # counterparts. `_refresh_guard` is never held across the network
        # call or a waiter's `flight.wait()`.
        self._refresh_guard = asyncio.Lock()
        self._refresh_flight: _AsyncRefreshFlight | None = None

    @property
    def auth_store(self) -> AuthStore:
        """See `SyncTransport.auth_store`."""
        return self._auth_store

    async def aclose(self) -> None:
        """Close the underlying `httpx.AsyncClient`, but only if this
        transport created it -- a caller-supplied client outlives this
        transport."""
        if self._owns_client:
            await self._client.aclose()

    async def raw_request(self, spec: RequestSpec) -> httpx.Response:
        """Escape hatch: perform exactly one HTTP call and return the
        `httpx.Response` as-is -- no error mapping, no 401 refresh, no 429
        retry. Auth/lang/account headers and body encoding still apply."""
        return await self._perform_once(spec)

    async def request(self, spec: RequestSpec) -> Any:
        """Perform `spec`, following the 401-refresh/429-backoff state
        machine, and return the parsed JSON body (or `None` for a 204/empty
        body). Raises `ZigbaseError` for a non-2xx response that survives
        that state machine."""
        response = await self._exchange(spec)
        return _decode_response(response)

    # --- internals -------------------------------------------------------

    async def _perform_once(self, spec: RequestSpec) -> httpx.Response:
        url = self._base_url + spec.path
        kwargs = _prepare_request(
            spec, token=self._auth_store.token, lang=self._lang, account_id=self._account_id
        )
        return await self._client.request(spec.method, url, **kwargs)

    async def _exchange(self, spec: RequestSpec) -> httpx.Response:
        did_refresh = False
        attempt = 0

        while True:
            response = await self._perform_once(spec)

            if response.is_success:
                return response

            if (
                response.status_code == 401
                and self._auto_refresh
                and self._auth_collection is not None
                and not did_refresh
                and not spec.skip_auth
                and not spec.is_refresh
                and self._auth_store.token
            ):
                did_refresh = True
                try:
                    await self._await_refresh()
                    continue
                except Exception:
                    # Refresh failed -- fall through and raise this
                    # request's ORIGINAL 401 below, not the refresh error.
                    pass

            if response.status_code == 429 and attempt < self._max_retries:
                delay = _compute_backoff(response.headers.get("Retry-After"), attempt)
                attempt += 1
                await _asleep(delay)
                continue

            raise parse_error_response(
                response.status_code,
                response.text,
                str(response.url),
                reason_phrase=response.reason_phrase or None,
            )

    async def _await_refresh(self) -> None:
        """Join the in-flight refresh, or become its owner and start it."""
        async with self._refresh_guard:
            flight = self._refresh_flight
            if flight is not None:
                is_owner = False
            else:
                flight = _AsyncRefreshFlight()
                self._refresh_flight = flight
                is_owner = True

        if not is_owner:
            await flight.wait()
            return

        error: BaseException | None = None
        try:
            await self._perform_refresh()
        except BaseException as exc:
            error = exc
            raise
        finally:
            async with self._refresh_guard:
                self._refresh_flight = None
            flight.finish(error)

    async def _perform_refresh(self) -> None:
        assert self._auth_collection is not None
        spec = RequestSpec(
            method="POST",
            path=f"/api/collections/{self._auth_collection}/auth-refresh",
            is_refresh=True,
        )
        result = await self.request(spec)
        self._auth_store.save(*_parse_refresh_result(result, spec.path))


__all__ = ["AsyncTransport", "SyncTransport"]
