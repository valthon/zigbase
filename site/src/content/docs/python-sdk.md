---
title: Python SDK
description: The official zigbase Python SDK — sync and async clients for auth, records, offset + cursor pagination, files, and multi-tenancy/analytics/senders.
order: 7
group: guides
---

# ZigBase Python SDK

The official Python client (`zigbase`) wraps the ZigBase HTTP REST API
([API reference](./api)) in an ergonomic surface: auth + stores, records, offset and cursor
pagination, files, and multi-tenancy/analytics/senders services. It ships **both** a
synchronous facade — `ZigBase`, over `httpx.Client` — and an `asyncio` facade —
`AsyncZigBase`, over `httpx.AsyncClient` — with an identical API surface (`snake_case`
methods, same return types, one just `await`-ed). The package is `mypy --strict`-checked
inline (PEP 561 `py.typed`) and supports Python 3.10+.

Like the [TypeScript](./typescript-sdk) and [Dart](./dart-sdk) SDKs, this is a straight
behavioral port of the same client contract — same wire format, same filter-escaping rules,
same cursor-pagination semantics — with a few deliberate divergences called out in
[Divergences from the TypeScript/Dart SDKs](#divergences-from-the-typescriptdart-sdks).
Realtime and a generated typed tier are **not** in this release — see that section.

## Install

**Not yet published to PyPI.** The publishing workflow
(`release-python-sdk.yml`, OIDC-based Trusted Publishing) is wired up, but the first publish
still needs one-time owner setup on PyPI — see
[clients/python/RELEASING.md](https://github.com/valthon/zigbase/blob/main/clients/python/RELEASING.md).
Until then, install straight from the repo:

```sh
pip install "zigbase @ git+https://github.com/valthon/zigbase.git#subdirectory=clients/python"
```

Once published:

```sh
pip install zigbase
```

Runtime dependency: `httpx`.

## Quick start (sync)

```python
from zigbase import ZigBase

with ZigBase("http://127.0.0.1:8090") as zb:
    zb.collection("users").auth_with_password("you@example.com", "secret")

    posts = zb.collection("posts").get_list()
    print(posts.items[0]["title"])

    health = zb.health()
    print(health["status"])  # "ok"
```

`ZigBase.close()` (called automatically by the `with` block) releases the underlying
`httpx.Client` — but only if the client created it itself; see [Ownership &
close()](#ownership--close) for the rule when you pass your own.

## Quick start (async)

```python
import asyncio
from zigbase import AsyncZigBase


async def main() -> None:
    async with AsyncZigBase("http://127.0.0.1:8090") as zb:
        await zb.collection("users").auth_with_password("you@example.com", "secret")
        posts = await zb.collection("posts").get_list()
        print(posts.items[0]["title"])


asyncio.run(main())
```

Every method on `AsyncZigBase` and its services mirrors `ZigBase`'s sync API one-for-one,
just `await`-ed — see [Sync vs. async](#sync-vs-async) for which one to reach for.

## Create a client

```python
from zigbase import ZigBase

zb = ZigBase(
    "http://127.0.0.1:8090",
    auto_refresh=True,
    auth_collection="users",
)
```

`ZigBase(base_url, *, ...)` / `AsyncZigBase(base_url, *, ...)` constructor options:

| Option | Default | Purpose |
| --- | --- | --- |
| `auth_store` | `MemoryAuthStore()` | Where the token + auth record live. |
| `auto_refresh` | `False` | Retry once on a 401 by refreshing the token (needs `auth_collection`). |
| `auth_collection` | `None` | The auth collection used for automatic refresh (e.g. `"users"`). |
| `account_id` | `None` | Bakes `X-Account-Id` into every request from this client (multi-tenancy). |
| `lang` | `None` | `Accept-Language` for localized server errors. |
| `max_retries` | `3` | 429-backoff retry budget. |
| `http_client` | a fresh `httpx.Client()` / `httpx.AsyncClient()` | Override the HTTP transport (tests, connection pooling, custom `timeout=`/proxies — see [Divergences](#divergences-from-the-typescriptdart-sdks)). |

### Ownership & `close()`

A client constructed without an explicit `http_client=` **owns** the `httpx.Client`/
`httpx.AsyncClient` it builds and tears it down in `close()`/`aclose()`; a client built with
`http_client=<your own>` never closes it — that instance is yours to close. `close()`/
`aclose()` are idempotent (`httpx`'s own `close()` already tolerates repeat calls). Using a
closed client raises `httpx`'s own `RuntimeError` on the next request — there is no
ZigBase-specific guard.

`with_account(account_id)` returns a **sibling**: a second `ZigBase`/`AsyncZigBase` sharing
this client's `auth_store` **and** underlying `httpx` client (a login/logout on either is
visible to both), scoped to send `X-Account-Id: <account_id>` on every request. Because the
sibling is built by passing this instance's `http_client` through, it never owns the shared
`httpx` client — only closing the original (non-sibling) instance actually closes it.

## Auth + stores

Two stores ship in the box:

- **`MemoryAuthStore`** — the default. Never persists; gone on process exit.
- **`FileAuthStore`** — JSON-file-backed, for CLI/script use across process runs. Loads
  eagerly on construction; an unreadable/missing/malformed file is treated as empty rather
  than raising (repo-wide philosophy: unreadable = nonexistent).

```python
from zigbase import FileAuthStore, ZigBase

store = FileAuthStore("~/.config/myapp/zb_auth.json")
zb = ZigBase("http://127.0.0.1:8090", auth_store=store, auto_refresh=True, auth_collection="users")

# password auth — saves {token, record} into the store on success
zb.collection("users").auth_with_password("you@example.com", "secret")

zb.auth_store.is_valid  # decodes the JWT `exp` locally — UX hint only, see security note below
zb.auth_store.record    # the authenticated record, or None
zb.auth_store.token     # the raw JWT

# refresh + logout
zb.collection("users").auth_refresh()
zb.collection("users").logout()  # clears the store

# react to login/logout/refresh anywhere; returns an unsubscribe callable
unsubscribe = zb.auth_store.on_change(
    lambda token, record: print("auth changed:", (record or {}).get("id", "(signed out)"))
)
```

`auto_refresh=True` opts the transport into a single-flight 401 auto-refresh: the first
request that gets a 401 triggers one `auth-refresh` call (concurrent 401s wait on it rather
than each firing their own), and the original request is retried once with the new token.

### OAuth2 (Authorization-Code + PKCE)

```python
from zigbase.pkce import code_challenge_s256, generate_code_verifier

users = zb.collection("users")

# Discover configured providers (name, authURL, clientId, scopes):
providers = users.list_auth_providers()

verifier = generate_code_verifier()
challenge = code_challenge_s256(verifier)
state = generate_code_verifier(32)  # any random string works for state too
# 1. redirect the user to the provider authorize URL with `challenge` + `state`
# 2. on the callback, exchange the code:
auth = users.auth_with_oauth2(
    provider="github",
    code=code,
    code_verifier=verifier,
    redirect_url="https://app.example.com/callback",
    state=state,
)
```

`auth_with_oauth2` returns an `AuthResponse` with `record=None` — the endpoint sets
`zb_auth`/`zb_csrf` cookies directly and never returns a record.

### Verification + password reset

```python
users.request_verification("you@example.com")
users.confirm_verification(token_from_email)

users.request_password_reset("you@example.com")
users.confirm_password_reset(token_from_email, "new-secret")
```

### Changing a password (`change_password`)

*Requires ZigBase >= 0.10.0.*

```python
users.change_password(user_id, "old-secret", "new-secret")
```

A self-service change while already logged in — distinct from the "forgot password" flow
above. It rides `PATCH /records/:id` with `{password, oldPassword}`; the server verifies
`old_password` against the target record (non-oracle: wrong/missing `old_password` both fail
the same way) and rotates the record's session epoch, dropping every other outstanding
session. When the auth store's current principal *is* the target record, `change_password`
transparently re-authenticates with the stored identity (`email`, falling back to
`username`) and the new password, so a bearer-token client stays logged in.

### Sessions (`list_sessions` / `revoke_session` / `revoke_all_sessions`)

*Requires ZigBase >= 0.10.0. `list_sessions`/`revoke_session` additionally require the
server to run `App(.{ .auth = .{ .session = .{ .store = .table } } })` — the default
`.epoch` mode has no per-device state to list, and the call surfaces the server's 404 as a
`ZigbaseError`.*

```python
sessions = users.list_sessions()  # list[dict], newest first
# sessions[i]["is_current"] marks the one THIS request authenticated with

users.revoke_session(sessions[1]["id"])  # log out one other device
users.revoke_all_sessions()  # log out everywhere, incl. this device
```

Wire keys stay **snake_case** as received (`last_seen`, `user_agent`, `is_current`) — the
SDK does not remap them into a typed class. `revoke_all_sessions()` works in both
session-store modes and always clears the local `AuthStore`, even if the request fails.

### Security notes

- **`auth_store.is_valid` is not authorization.** It decodes the JWT `exp` claim
  client-side purely so the UI can pre-empt an expired session; the server authorizes every
  request — never gate sensitive logic on `is_valid` alone.
- There is no browser-cookie store in this SDK (Python has no browser, unlike the
  TypeScript SDK's `CookieAuthStore`). For CLI/script persistence, use `FileAuthStore`,
  ideally pointed at a file with restrictive permissions.

## Account scoping (multi-tenancy)

*Requires ZigBase >= 0.9.0 with `.tenancy` enabled.*

```python
# 1. Bake it into the client at creation time.
zb = ZigBase(url, account_id="acc_123")

# 2. with_account(id) — a sibling client scoped to a (possibly different) account.
tenant_zb = zb.with_account("acc_123")
tenant_zb.collection("notes").get_list()  # every request carries X-Account-Id: acc_123

# accounts.activate(id) — verify membership + set the zb_account cookie (browser/webview apps).
scope = zb.accounts.activate("acc_123")
scope["account"]  # "acc_123"
scope["role"]     # the caller's role on that account
```

`with_account` shares the same `AuthStore` (and underlying `httpx` client) as the client it
was derived from, and **replaces** the account id rather than stacking. Per-request
`X-Account-Id` (via `account_id=`/`with_account`) always wins over the `zb_account` cookie
server-side.

## Records

```python
posts = zb.collection("posts")

page = posts.get_list(
    page=1,
    per_page=30,
    filter="status = 'published'",
    sort="-created",
    expand="author",
)
print(page.items[0]["title"])

one = posts.get_one("REC123", expand="author")

# create — multipart is auto-detected when a body value is file-like or a (filename, bytes[, content_type]) tuple
made = posts.create({"title": "Hi", "status": "draft"})
updated = posts.update("REC123", {"title": "Edited"})
posts.delete("REC123")

# get_first_list_item — get_list(1, 1, skip_total=True) sugar; raises a synthesized 404 ZigbaseError when nothing matches
draft = posts.get_first_list_item("status = 'draft'")
```

Records are plain `dict[str, Any]` (the raw JSON body) — there is no wrapper class; index
directly (`record["title"]`, `record["id"]`).

### Safe filters — `zb_filter`

Build filter strings without injection risk using `zb_filter(expr, params)`, which
interpolates named `{:name}` placeholders via `filter_value`. String values are always
single-quoted and escaped against the server lexer (`'`, `\`, and newline/tab/CR are
backslash-escaped); `int`/`float`/`bool` render bare; `datetime` becomes a
millisecond-clamped UTC ISO-8601 string. Any string is representable — including values
containing both `'` and `"`.

```python
from zigbase import zb_filter

user_input = untrusted  # even `' || 1=1 --` or `he said "hi" to O'Brien` is safely quoted
filter = zb_filter("status = {:s} && author ~ {:q}", {"s": "published", "q": user_input})
listing = posts.get_list(filter=filter)
```

`zb_filter` is **stricter than the TypeScript/Dart ports**: it raises `ValueError` if
`params` contains a key `expr` never references (not just failing on a placeholder missing
from `params`) — a reject-don't-coerce posture that catches copy-paste mistakes early.

`filter_value(value)` (`from zigbase.query import filter_value`) is the single-operand
primitive `zb_filter` calls internally — reach for it directly to build one operand at a
time. Both raise `TypeError` on a non-finite `float` or an unsupported type (`list`/`dict`
operands are ambiguous — expand them yourself, e.g. into an `||` chain or a native
`in (...)` clause).

### Vector search

*Requires ZigBase >= 0.9.0 built with `-Dvector=true`.*

```python
from zigbase.query import vector_spec

nearest = posts.get_list(
    per_page=10,
    vector=vector_spec("embedding", [0.12, 0.34], metric="cosine"),
)
```

`vector_spec(field, embedding, *, metric=None)` serializes to the wire's
`<field>[:metric]:<json-embedding>` mini-grammar; it raises `TypeError` on a non-finite or
non-numeric embedding element. Vector search is **offset-only** — the server rejects it in
cursor mode. `search` (full-text) is a plain string kwarg on `get_list`/`get_page`/
`iterate`/`get_full_list` and works in both modes.

## Pagination — offset + cursor

```python
# Offset: random page access + exact totals.
p = posts.get_list(page=2, per_page=30)
p.total_items  # total across all pages
p.total_pages

# Cursor / keyset: stable under inserts; ideal for feeds and infinite scroll.
c = posts.get_page(limit=30, sort="-created")
c.items
while c.has_next and c.next_cursor:
    c = posts.get_page(limit=30, sort="-created", cursor=c.next_cursor)

# iterate every matching record over the stable cursor engine (sync: Iterator; async: AsyncIterator)
for post in posts.iterate(sort="-created"):
    ...
all_published = posts.get_full_list(filter="status = 'published'")
```

**Which one to use?** Reach for **offset** (`get_list`) when you need jump-to-page-N
navigation or an exact total count. Reach for **cursor** (`get_page` / `iterate` /
`get_full_list`) for stable feeds and infinite scroll: it is stable under concurrent inserts
and avoids the cost of deep offsets.

Cursor pagination is **native server-side keyset pagination**. The server mints an opaque
token; the client treats `next_cursor`/`prev_cursor` as opaque strings and forwards whatever
it received on the next `get_page` call — it never decodes or synthesizes one. The server
skips the total count by default (the expensive part); pass `with_total=True` to a
`get_page` call to include `total_items`. Sending `limit` with no `cursor` requests the
first page.

`iterate`/`get_full_list` raise a status-0 `ZigbaseError` if the server ever answers with a
**non-advancing cursor page** — an empty page that still claims `has_next`, or a
`next_cursor` identical to the one just used — a guard against looping forever on a
misbehaving server. `status=0` on a `ZigbaseError` always denotes this kind of client-side
protocol violation rather than a real HTTP response; see [Error
handling](#error-handling).

## Files

A `create`/`update` body value that is a file-like object (anything with `.read()`), or a
`(filename, bytes)` / `(filename, bytes, content_type)` tuple — or a `list` containing any
of those — is sent as `multipart/form-data` automatically. No special method call needed:

```python
with open("cover.png", "rb") as f:
    rec = posts.create({
        "title": "Hi",
        "status": "draft",
        "cover": (f.name, f.read(), "image/png"),
    })

# build a (optionally thumbnailed) file URL from the record:
url = zb.files.get_url(rec, rec["cover"], thumb="100x100")

# short-lived token for protected-file access (<img>, emails):
token = zb.files.get_token()
protected_url = zb.files.get_url(rec, rec["cover"], token=token)

# or pass collection + id explicitly instead of a record dict:
url2 = zb.files.get_url_for("posts", "REC123", "cover.png", download=True)
```

`zb.files.get_url(record, filename, **opts)` reads the collection from
`record["collectionId"]`, falling back to `record["collectionName"]`; it raises
`ValueError` when neither is present (e.g. a hand-built dict that never round-tripped
through the server). `get_url`/`get_url_for` are pure string builders — no request — so
they're identical between `FilesService` and `AsyncFilesService`; only `get_token` is
`async` on the async facade.

## Abilities

*Requires ZigBase >= 0.9.0.*

```python
abilities = posts.get_abilities("REC123")
abilities["view"]    # always True on success — you couldn't have fetched abilities otherwise
abilities["update"]  # bool
abilities["delete"]  # bool
```

**404, not 403, when the record isn't viewable** — a deliberate non-oracle: a
`ZigbaseError(status=404)` never distinguishes "exists but you lack access" from "doesn't
exist."

## Analytics

*Requires ZigBase >= 0.9.0 (cursor pagination on `events` requires >= 0.10.0).*

```python
feed = zb.analytics.events(name="signup", since="2026-01-01T00:00:00Z", limit=50)
feed.items[0]["payload"]  # arbitrary JSON value; None when unparseable/empty
if feed.has_next:
    zb.analytics.events(cursor=feed.next_cursor)

rollup = zb.analytics.rollup("daily_signups", from_="2026-01-01T00:00:00.000Z", to="2026-01-08T00:00:00.000Z")
rollup[0]["value"]
```

Wire field names stay **snake_case** as the server sends them (`actor_collection`,
`occurred_at`, `computed_at`, …) — `events()` returns a `CursorPage` of raw `dict`s rather
than a typed record class. `since`/`from_`/`to` are plain ISO-8601 strings (format them
yourself). `from_` uses a trailing underscore because `from` is a Python keyword.
`events()` is 401 for an anonymous caller, returns empty `items` when there's no active
account, and a superuser sees every account's events. `rollup(name)` is 404 for an
undeclared rollup name and 403 when a non-superuser queries a rollup that isn't grouped by
account.

## Senders

*`list` requires ZigBase >= 0.10.0; `create`/`verify` require >= 0.9.0.*

```python
# request verification — the token is EMAILED to the address, never returned
pending = zb.senders.create("orders@my-shop.example")
pending["status"]  # "pending" (201) or already-verified (200)

# confirm with the token from the email
zb.senders.verify(pending["id"], token_from_email)

# the active account's identities (requires server >= 0.10.0)
items = zb.senders.list()
items[0]["verified_at"]
```

A re-send of `create()` for the same `(account, email)` within the server's throttle window
raises a 429 `ZigbaseError`. `verify()` returns `False`/raises a 404 `ZigbaseError` — never
a distinguishing error — for a wrong token, wrong account, or wrong id.

## Error handling

Every non-2xx response raises `ZigbaseError`, carrying `status`, `message`, `url`, and
per-field validation errors in `data` (`dict[str, FieldError]`):

```python
from zigbase import ZigbaseError

try:
    posts.create({"title": ""})
except ZigbaseError as e:
    if e.status == 400:
        print(e.data["title"].message)  # field-level error
```

`status=0` is reserved for a client-side protocol violation with no real HTTP response
behind it — currently, only a non-advancing cursor page (see
[Pagination](#pagination--offset--cursor)).

## Escape hatch — `send()` and `raw_request()`

`zb.send(method, path, **opts)` calls any endpoint the typed surface doesn't cover,
returning parsed JSON (or `None` for 204/empty); the auth header, 401 auto-refresh, and
`ZigbaseError` mapping still apply:

```python
stats = zb.send("GET", "/api/custom/stats", query={"window": "7d"})
zb.send("POST", "/api/custom/reindex", body={"collection": "posts"})
```

When you need the **raw `httpx.Response`** (binary/text bodies, response headers, custom
status handling), use `zb.raw_request(method, path, **opts)`. It passes through
`query`/`body`/`headers` and the auth header, but does **not** JSON-parse and does **not**
raise on a non-2xx status:

```python
res = zb.raw_request("GET", "/api/export.csv", query={"format": "csv"})
if res.status_code == 200:
    print(res.headers["content-type"])
    print(res.text)
```

## Sync vs. async

Both facades expose the identical API (`snake_case` methods, same return types); pick based
on your program, not the SDK:

- **`ZigBase`** (sync, `httpx.Client`) — scripts, CLIs, Django/Flask/WSGI apps, notebooks,
  anywhere you're not already inside an event loop.
- **`AsyncZigBase`** (`asyncio`, `httpx.AsyncClient`) — FastAPI/Starlette/aiohttp
  applications, or any code already running under `asyncio` where blocking I/O would stall
  the event loop.

Don't mix them in one process against the same `auth_store` unless you're deliberately
sharing state across a sync/async boundary — each facade owns its own `httpx` client by
default (pass `http_client=` to share/override one, mirroring `with_account`'s ownership
rule).

## Divergences from the TypeScript/Dart SDKs

This is a straight behavioral port, but a few things differ by design, not oversight:

- **No realtime yet.** `RealtimeService`/live-store parity — WebSocket subscriptions, the
  live-store observable objects the Dart and TypeScript SDKs expose — is deferred to a
  follow-up SDK milestone; there is no subscribe API in this release.
- **No typed tier yet.** Unlike the [TypeScript](./typescript-sdk#typed-client--zigbaseclienttyped)
  and [Dart](./dart-sdk#typed-tier) SDKs, there is no generated typed client for Python
  yet — `zigbase typegen` does not emit a Python target. Records stay plain `dict[str, Any]`.
- **No `requestKey` de-duplication.** The TypeScript/Dart SDKs' opt-in last-write-wins
  request cancellation (`requestKey=`) has no Python equivalent. For the async facade, use
  `asyncio` task cancellation (e.g. cancel the previous `asyncio.Task` before issuing a new
  one) at the call site; there is no sync-facade analogue since `httpx.Client` calls block
  the calling thread.
- **No per-call `timeout=`/`signal=`.** Where the TypeScript SDK takes a per-request
  `AbortSignal` and the Dart SDK a `requestKey`-based cancel, this SDK follows `httpx`'s own
  convention: configure timeouts (and any other transport policy — proxies, connection
  limits) by constructing your own `httpx.Client(timeout=...)` /
  `httpx.AsyncClient(timeout=...)` and passing it as `http_client=` to `ZigBase`/
  `AsyncZigBase`, rather than a bespoke per-call kwarg.

## Integration-test recipe

The SDK's own end-to-end suite (`clients/python/tests/integration/`) drives the public API
against a real `zigbase serve` process — the same pattern works for consumer apps that want
a live-server smoke test:

```sh
# 1. Build the server binary once.
mise exec zig@0.16.0 -- zig build

# 2. Point ZIGBASE_TEST_BINARY at it and run the marked suite.
ZIGBASE_TEST_BINARY="$(pwd)/zig-out/bin/zigbase" \
  mise exec python@3.13 -- python -m pytest clients/python/tests/integration -q

# Everything else (the default suite) skips the live-server tests:
mise exec python@3.13 -- python -m pytest -m "not integration" -q
```

`tests/integration/conftest.py` skips collecting the live-server tests entirely (a printed
skip, never a failure) when `ZIGBASE_TEST_BINARY` is unset, so plain `pytest` stays green
without the Zig toolchain. The harness launches the binary on a free loopback port with a
fresh tempdir data directory and `--insecure-cookies`, seeds a superuser via the `superuser
create` CLI subcommand, polls `/api/health` for readiness (retrying on a fresh port if a
bind race kills the child), and tears the process + tempdir down on teardown.

## Not yet

The Python SDK is a base client only — a few surfaces the TypeScript and Dart SDKs have do
not exist here yet:

- **Realtime.** No WebSocket subscribe API or live store; see
  [Divergences](#divergences-from-the-typescriptdart-sdks).
- **Typed tier.** No generated typed client (`zigbase typegen` doesn't emit Python); records
  stay plain `dict[str, Any]`.
- **`requestKey` de-duplication.** Use `asyncio` task cancellation on the async facade
  instead; see [Divergences](#divergences-from-the-typescriptdart-sdks).

These are planned follow-ups, not permanent gaps — track them alongside the TypeScript and
Dart SDKs, which reached them first.

## See also

- [API reference](./api) — the underlying HTTP protocol.
- [TypeScript SDK](./typescript-sdk) — the most mature sibling client, including realtime,
  the live store, and the typed `rpc.*`/auth-method/flags surfaces.
- [Dart SDK](./dart-sdk) — the Dart/Flutter sibling client, including realtime, the live
  store, and a typed tier.
- [Recipes](./recipes) — schema provisioning, owner-scoped rules, signup flows.
- [Tutorial](./tutorial) — build an app on ZigBase end to end.
