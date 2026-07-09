# ZigBase Python Client

Official Python client for [ZigBase](../../README.md) — REST records, auth, cursor
pagination, and files. Ships both a synchronous facade (`ZigBase`, over `httpx.Client`) and
an `asyncio` facade (`AsyncZigBase`, over `httpx.AsyncClient`) with an identical API
surface, `mypy --strict`-checked inline types (PEP 561 `py.typed`), and Python 3.10+.

## Install

**Not yet published to PyPI** (tracked in [RELEASING.md](RELEASING.md)). Until the first
publish, install straight from the repo:

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
`httpx.Client` — but only if the client created it itself; see [Auth + stores](#auth--stores)
for the ownership rule when you pass your own.

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

## Auth + stores

Two stores ship in the box:

- **`MemoryAuthStore`** — the default. Never persists; gone on process exit.
- **`FileAuthStore`** — JSON-file-backed, for CLI/script use across process runs. Loads
  eagerly on construction; an unreadable/missing/malformed file is treated as empty rather
  than raising (repo-wide philosophy: unreadable = nonexistent).

```python
from zigbase import FileAuthStore, ZigBase

store = FileAuthStore("~/.config/myapp/zb_auth.json")
zb = ZigBase("http://127.0.0.1:8090", auth_store=store, auto_refresh=True)

zb.auth_store.is_valid   # local JWT-exp check (UX only -- see security note)
zb.auth_store.record     # the authenticated record, or None
zb.collection("users").auth_refresh()
zb.collection("users").logout()  # clears the store

# react to login/logout/refresh anywhere
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
providers = users.list_auth_providers()

verifier = generate_code_verifier()
challenge = code_challenge_s256(verifier)
state = generate_code_verifier(32)  # any random string works for state too
# 1. redirect to the provider's authorize URL with `challenge` + `state`
# 2. on the callback, exchange the code:
auth = users.auth_with_oauth2(
    provider="github",
    code=code,
    code_verifier=verifier,
    redirect_url="https://app.example.com/callback",
    state=state,
)
```

> **Security.** `auth_store.is_valid` decodes the JWT `exp` **client-side** — it is a
> UX/expiry hint only, never an authorization decision (the server authorizes every
> request). There is no browser-cookie store in this SDK (Python has no browser); for CLI
> persistence use `FileAuthStore`, ideally pointed at a file with restrictive permissions.

## Records + safe filters

```python
from zigbase import zb_filter

posts = zb.collection("posts")

page = posts.get_list(
    page=1,
    per_page=30,
    filter=zb_filter("status = {:s}", {"s": "published"}),
    sort="-created",
    expand="author",
)
print(page.items[0]["title"])

post = posts.get_one("REC_ID", expand="author")
draft = posts.get_first_list_item("status = 'draft'")  # raises 404 ZigbaseError if none

created = posts.create({"title": "Hi", "status": "draft"})
updated = posts.update(created["id"], {"title": "Edited"})
posts.delete(created["id"])
```

`zb_filter` interpolates named `{:name}` placeholders and always single-quotes/escapes
string values against the server's filter lexer — byte-identical escaping to the
TypeScript/Dart SDKs, so any string is representable, including values containing both `'`
and `"`. It is **stricter than the Dart port**: it raises `ValueError` if `params` contains
a key `expr` never references (not just `KeyError` for a placeholder missing from
`params`), a reject-don't-coerce posture that catches copy-paste mistakes early. Build a
one-off operand yourself with `filter_value(value)`.

## Pagination — offset vs. cursor

```python
# Offset: random page access + exact totals.
p = posts.get_list(page=2, per_page=30)
p.total_items  # total across all pages
p.total_pages

# Cursor (keyset): stable under inserts, no deep-offset cost.
c = posts.get_page(limit=20, sort="-created")
render(c.items)
while c.has_next and c.next_cursor:
    c = posts.get_page(limit=20, sort="-created", cursor=c.next_cursor)
    render(c.items)

# Iterate every matching record (stable even while rows are inserted):
for post in posts.iterate(sort="-created"):
    handle(post)
# async: `async for post in posts.iterate(...)` on AsyncCollectionService

all_published = posts.get_full_list(filter="status = 'published'")
```

**Which one?** Use **offset** (`get_list`) when you need jump-to-page-N or a total count.
Use **cursor** (`get_page` / `iterate` / `get_full_list`) for stable feeds and infinite
scroll where deep offsets get slow — the server mints an opaque `next_cursor`/`prev_cursor`
token the client just forwards back. `iterate`/`get_full_list` raise a status-0
`ZigbaseError` if the server ever answers with a non-advancing cursor page (a guard against
looping forever on a misbehaving server). Totals are skipped by default in cursor mode;
pass `with_total=True` to `get_page` to include `total_items`.

## File uploads & URLs

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

# Build a URL to the stored file:
url = zb.files.get_url(rec, rec["cover"], thumb="100x100")

# Protected files: mint a short-lived access token for <img>/emails:
token = zb.files.get_token()
protected_url = zb.files.get_url(rec, rec["cover"], token=token)

# Or build a URL without a record object (collection + id explicitly):
url2 = zb.files.get_url_for("posts", rec["id"], "cover.png", download=True)
```

## Error handling

Every non-2xx response raises `ZigbaseError`, carrying `status`, `message`, `url`, and
per-field validation errors in `data`:

```python
from zigbase import ZigbaseError

try:
    posts.create({"title": ""})
except ZigbaseError as e:
    if e.status == 400:
        print(e.data["title"].message)  # field-level error
```

## Multi-tenancy, abilities, analytics, senders

```python
# Multi-tenancy: a sibling client scoped to one account (X-Account-Id header).
tenant_zb = zb.with_account("ACCOUNT_ID")
zb.accounts.activate("ACCOUNT_ID")  # sets the signed zb_account cookie for browser apps

# Abilities: per-record view/update/delete permission checks.
abilities = posts.get_abilities("REC_ID")  # {"view": True, "update": False, "delete": False}

# Analytics: the tenant-scoped activity feed (requires ZigBase >= 0.9.0).
events = zb.analytics.events(name="post.viewed", limit=50)
totals = zb.analytics.rollup("daily-signups", from_="2026-01-01T00:00:00.000Z")

# Senders: verified From-address management (requires ZigBase >= 0.9.0/0.10.0).
zb.senders.create("noreply@example.com")           # sends a verification email
verified = zb.senders.verify("SENDER_ID", token)    # bool
```

`with_account` returns a sibling client that shares this instance's `auth_store` **and**
underlying `httpx` client — a login/logout via either is visible to both, and only the
instance that originally created the shared client (i.e. never a `with_account` sibling)
closes it.

## Escape hatch — `send()` and `raw_request()`

`send()` calls any endpoint the typed surface doesn't cover, returning parsed JSON (or
`None` for a 204/empty body); the auth header, 401 auto-refresh, and `ZigbaseError` mapping
all still apply:

```python
stats = zb.send("GET", "/api/custom/stats", query={"window": "7d"})
zb.send("POST", "/api/custom/reindex", body={"collection": "posts"})
```

When you need the **raw `httpx.Response`** (binary/text bodies, custom headers), use
`zb.raw_request(method, path, **opts)`. It passes through `query`/`body`/`headers` and the
auth header, but does **not** JSON-parse and does **not** raise on a non-2xx status:

```python
res = zb.raw_request("GET", "/api/export.csv", query={"format": "csv"})
if res.status_code == 200:
    print(res.text)
```

## Sync vs. async

Both facades expose the identical API (`snake_case` methods, same return types); pick
based on your program, not the SDK:

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

- **No realtime yet.** `RealtimeService`/live-store parity is deferred to a follow-up SDK
  milestone; there is no WebSocket/subscribe API in this release.
- **No `requestKey` de-duplication.** The TypeScript/Dart SDKs' opt-in last-write-wins
  request cancellation (`requestKey=`) has no Python equivalent. For the async facade, use
  `asyncio` task cancellation (e.g. cancel the previous `asyncio.Task` before issuing a new
  one) at the call site; there is no sync-facade analogue since `httpx.Client` calls block
  the calling thread.
- **No per-call `timeout=`/`signal=`.** Where the TypeScript SDK takes a per-request
  `AbortSignal` and the Dart SDK a `requestKey`-based cancel, this SDK follows `httpx`'s own
  convention: configure timeouts (and any other transport policy) by constructing your own
  `httpx.Client(timeout=...)` / `httpx.AsyncClient(timeout=...)` and passing it as
  `http_client=` to `ZigBase`/`AsyncZigBase`, rather than a bespoke per-call kwarg.

## Requirements

- Python 3.10+
- A running ZigBase server (`zigbase serve`) — see the [repo README](../../README.md) to
  get one running locally.
