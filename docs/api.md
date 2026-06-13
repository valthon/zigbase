# ZigBase REST + WebSocket API

> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/api> — the site is the canonical reading experience.

ZigBase is a single-binary backend. This document is the user-facing reference for
its HTTP REST API and its realtime WebSocket interface. It describes only what the
server actually implements.

> **New to ZigBase?** Start with the [tutorial](tutorial.md) (build an app end to
> end), then reach for the [field-type catalog](fields.md) and the
> [task recipes](recipes.md). This page is the endpoint reference.

## Conventions

- **Base path:** all REST endpoints live under `/api`.
- **Encoding:** requests and responses are JSON (`Content-Type: application/json`),
  except file uploads (`multipart/form-data`, see [Files](#files)) and file downloads.
- **Error envelope:** every error response is a JSON object of the shape:

  ```json
  { "code": 404, "message": "Not found.", "data": {} }
  ```

  `code` mirrors the HTTP status. For validation failures (`400`), `data` maps each
  offending field to `{ "code": "...", "message": "..." }`:

  ```json
  {
    "code": 400,
    "message": "Failed to validate the request.",
    "data": { "name": { "code": "validation_invalid_name", "message": "Invalid." } }
  }
  ```

### Authentication transport

A request is authenticated by either of:

1. **Bearer token** — `Authorization: Bearer <jwt>`.
2. **Cookie** — the httpOnly `zb_auth` cookie. When authenticating via the cookie,
   unsafe methods (POST, PATCH, DELETE) additionally require a double-submit CSRF
   check: send the value of the readable `zb_csrf` cookie back in the
   `X-CSRF-Token` header. The server compares it against the CSRF claim embedded in
   the token; a missing or mismatched header fails authentication on unsafe methods.

The `zb_auth` cookie is httpOnly, `SameSite=Strict`; `zb_csrf` is readable (not
httpOnly), `SameSite=Strict`. Both are set by the auth endpoints (see [Auth](#auth)).

---

## Collections

Collection management endpoints are **superuser-only**.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/collections` | List all collections. |
| POST | `/api/collections` | Create a collection. |
| GET | `/api/collections/:idOrName` | Get one collection by id or name. |
| PATCH | `/api/collections/:idOrName` | Update a collection. |
| DELETE | `/api/collections/:idOrName` | Delete a collection. |

### Input vs. output shape

On **input** (POST/PATCH), the field list is supplied under the key `fields`.
On **output**, the serialized collection exposes the field list under the key
`schema`:

```jsonc
// request body (create)
{
  "name": "posts",
  "type": "base",
  "fields": [
    { "name": "title", "type": "text", "options": {} }
  ]
}
```

```jsonc
// response
{
  "id": "...",
  "name": "posts",
  "type": "base",
  "system": false,
  "schema": [ { "name": "title", "type": "text", "options": {} } ],
  "indexes": []
}
```

### Fields

A field has a `name`, a `type` (e.g. `text`, `relation`, `file`, …), and a
type-specific `options` object. Common options include `required` and `unique`;
`relation` fields reference another collection. Auth collections (`"type":"auth"`)
have system fields such as `email` injected automatically.

---

## Records

Record endpoints operate on a collection by name (`:col`).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/collections/:col/records` | List records (paginated). |
| GET | `/api/collections/:col/records/:id` | Get one record. |
| POST | `/api/collections/:col/records` | Create a record. |
| PATCH | `/api/collections/:col/records/:id` | Update a record. |
| DELETE | `/api/collections/:col/records/:id` | Delete a record. |

Access to each operation is governed by the collection's
[access rules](#access-rules).

### List: query parameters

| Param | Default | Meaning |
| --- | --- | --- |
| `page` | `1` | Page number (1-based). |
| `perPage` | `30` | Items per page. |
| `filter` | — | Filter expression (see [Filter grammar](#filter-grammar)). |
| `sort` | — | Sort spec (see [sort](#sort)). |
| `expand` | — | Relation expansion (see [expand](#expand)). |

The list response envelope:

```json
{
  "page": 1,
  "perPage": 30,
  "totalItems": 42,
  "totalPages": 2,
  "items": [ { "id": "...", "title": "..." } ]
}
```

### Filter grammar

The `filter` parameter (and rule expressions, and realtime subscription filters)
share one grammar.

**Comparison operators:**

| Operator | Meaning |
| --- | --- |
| `=` | equal |
| `!=` | not equal |
| `>` | greater than |
| `>=` | greater than or equal |
| `<` | less than |
| `<=` | less than or equal |
| `~` | LIKE (contains / pattern match) |
| `!~` | NOT LIKE |

**Boolean combination:** `&&` (and), `||` (or), with parentheses `( )` for grouping.

**Operands:** field paths (identifiers, may contain `.` for relation traversal,
e.g. `author.name`), single- or double-quoted strings, numbers, booleans
(`true`/`false`), and `null`.

**Request macros** resolve against the current request:

| Macro | Value |
| --- | --- |
| `@request.auth.<field>` | a field of the authenticated record (e.g. `@request.auth.id`) |
| `@request.data.<field>` | a field of the incoming request body |
| `@request.method` | the HTTP method (e.g. `"GET"`) |

Examples:

```text
status = "published"
title ~ "zig" && views >= 100
@request.auth.id = owner
author.role = "admin" || @request.method = "GET"
```

### sort

Comma-separated field list. Prefix a field with `-` for descending; ascending is the
default:

```text
sort=-created,title
```

### expand

Comma-separated relation paths; nest deeper relations with `.`:

```text
expand=author,comments.user
```

Expansion runs on both the list endpoint and the single-record `view` endpoint.

---

## Access rules

Each collection defines five rules: **list**, **view**, **create**, **update**,
**delete**. A rule is one of:

| Rule value | Meaning |
| --- | --- |
| `null` | **Locked** — only a superuser may perform the operation; everyone else is denied. |
| `""` (empty string) | **Locked** — same as `null` (safe-by-default). An empty rule is **not** public. |
| `"@public"` | **Public** — anyone may perform the operation. This explicit sentinel is the *only* way to open a collection. |
| a filter expression | The operation is allowed only when the expression matches (using the [filter grammar](#filter-grammar), including `@request.*` macros). |

Superusers bypass all rules.

> **Safe-by-default (changed):** a blank rule (`null` or `""`) is **locked to superusers**.
> To open an operation to the public you must set the rule to exactly `"@public"`. On startup,
> ZigBase logs a prominent warning for every `@public` rule (`collection 'X' is PUBLIC for <op>`)
> so a wide-open collection is never silent.

**Denial status codes:**

- **view / update / delete** on a record that does not exist *or* does not satisfy
  the rule return **404** — this hides record existence.
- **create** denial returns **403**.
- A **locked** (`null` or `""`) list/view rule denies non-superusers (list returns 403; view
  returns 404).

---

## Auth

Auth endpoints target an auth-type collection (`:col`).

| Method | Path | Description |
| --- | --- | --- |
| POST | `/api/collections/:col/auth-with-password` | Log in with identity + password. |
| POST | `/api/collections/:col/auth-refresh` | Issue a fresh token for the current session. |
| POST | `/api/collections/:col/auth-logout` | Clear the auth cookies. |
| POST | `/api/collections/:col/request-verification` | Request an email-verification token. |
| POST | `/api/collections/:col/confirm-verification` | Confirm verification with a token. |
| POST | `/api/collections/:col/request-password-reset` | Request a password-reset token. |
| POST | `/api/collections/:col/confirm-password-reset` | Confirm a reset with a token. |

### auth-with-password

```json
// request
{ "identity": "user@example.com", "password": "secret" }
```

```json
// response (200) — also sets zb_auth (httpOnly) and zb_csrf cookies
{ "token": "<jwt>", "record": { "id": "...", "email": "..." } }
```

`identity` is matched against the collection's configured identity fields.
`auth-refresh` returns the same `{ token, record }` shape and re-sets the cookies.
`auth-logout` clears `zb_auth` and `zb_csrf`.

### Registration / signup

There is **no dedicated register endpoint**. Signing up a user is a normal
**record create on the auth collection**:

```sh
POST /api/collections/users/records
{ "email": "user@example.com", "password": "a-good-password" }
```

On this create the server hashes the password (argon2id), strips the plaintext,
mints a `tokenKey`, and **forces `verified` to `false`** (a client-supplied
`verified` is ignored); `passwordHash`/`tokenKey` are hidden in the response. The
auth collection needs a **public create rule** (`"@public"`) for open signup, and the
password must be at least `minPasswordLength` (default 8) — otherwise the create is
a `400`. After signup, obtain a token via `auth-with-password` above. Full walkthrough:
[recipes.md → User registration](recipes.md#recipe-user-registration-signup).

### Verification & password reset — email delivery

The `request-verification` and `request-password-reset` endpoints mint a token and
deliver it via the configured mailer, then return `204` (they never reveal whether
the email exists). The matching `confirm-*` endpoint takes that `token` in its body.

- **With SMTP configured** (`ZIGBASE_SMTP_HOST` + friends — see the
  [README config table](../README.md#configuration)), the token is **emailed** over
  the configured transport (`none` / `starttls` / `implicit` / `auto`).
- **Without SMTP** (the default), the token is **logged to the server** instead — a
  dev/CI convenience. To complete a flow locally, read the token from the log and POST
  it to the matching `confirm-*` endpoint.

Configure SMTP for production; see
[KNOWN_LIMITATIONS.md → Auth & email](../KNOWN_LIMITATIONS.md).

### Rate limiting

The sensitive auth endpoints — `auth-with-password` (login), `request-verification`,
and `request-password-reset` — are rate limited. Over the limit, the endpoint returns
**`429 Too Many Requests`** (`{ "message": "Too many requests. Try again later." }`).

- **Config:** `ZIGBASE_RATE_LIMIT_MAX` attempts (default `10`) per
  `ZIGBASE_RATE_LIMIT_WINDOW` seconds (default `60`), per client key, per endpoint.
  Set `ZIGBASE_RATE_LIMIT_MAX=0` to disable rate limiting entirely.
- **Keying:** `X-Forwarded-For` / `X-Real-IP` are **ignored by default** — they are
  attacker-controlled on direct exposure. With `--trust-proxy` (`ZIGBASE_TRUST_PROXY=true`),
  set **only** behind a trusted reverse proxy that rewrites them, the key is the IP from
  `X-Forwarded-For` (first hop) or `X-Real-IP`. Otherwise the limiter keys on the submitted
  identity/email, which is not header-spoofable. This makes direct exposure safe by default.

### OAuth2

ZigBase uses **client-driven PKCE**: the client generates and holds the PKCE state
and code verifier, runs the authorization redirect itself, then submits the
authorization `code` to the server.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/collections/:col/oauth2-providers` | List enabled providers (name, `authURL`, `clientId`, `scopes`). Secrets are never returned. |
| POST | `/api/collections/:col/oauth2-init` | (Server-side state mode only) Mint a server-issued `state` for a provider. `404` when server-side state is disabled. |
| POST | `/api/collections/:col/auth-with-oauth2` | Exchange an authorization code for a session. |
| DELETE | `/api/collections/:col/records/:id/external-auths/:provider` | Unlink a provider from a record. |

```json
// auth-with-oauth2 request
{
  "provider": "google",
  "code": "<authorization-code>",
  "codeVerifier": "<pkce-verifier>",
  "redirectUrl": "https://app.example.com/callback"
}
```

```json
// auth-with-oauth2 response (200) — also sets the auth cookies
{ "token": "<jwt>", "record": { "id": "..." }, "meta": { "isNew": true } }
```

`redirectUrl` must be in the provider's configured allowlist.

#### CSRF on the OAuth flow: `state`

The OAuth `state` parameter prevents login-CSRF. ZigBase supports two modes:

- **Client-driven (default).** The SPA generates `state`, embeds it in the provider
  authorization URL, and verifies the returned `state` against what it stored before
  calling `auth-with-oauth2`. The backend does not see or check `state`. This is the
  documented flow and is unchanged.
- **Server-side (opt-in).** Set `ZIGBASE_OAUTH_STATE_SERVER=true` (TTL via
  `ZIGBASE_OAUTH_STATE_TTL`, default 600s). Then:
  1. The client calls `POST .../oauth2-init` with `{ "provider": "<name>" }` and
     receives `{ "state": "<value>" }`.
  2. The client embeds that `state` in the provider authorization URL.
  3. On callback, the client adds `"state": "<value>"` to the `auth-with-oauth2` body.

  The backend verifies the state exists, matches the (collection, provider), is
  unexpired, and is **single-use** (deleted on first use). A missing, mismatched,
  expired, or replayed `state` is rejected with `400` before the provider is contacted.
  Use this when you can't guarantee a correct SPA. **PKCE (`codeVerifier`) is still
  required in both modes** — server-side `state` adds CSRF protection, it does not
  replace PKCE.

---

## Files

File-type fields hold uploaded files.

- **Upload:** files are submitted via `multipart/form-data` on record create
  (`POST .../records`) or update (`PATCH .../records/:id`), alongside the other
  field values.
- **Serve:** `GET /api/files/:col/:rec/:name`.

### Access

File access reuses the collection's **view** rule:

- Files in a **public** collection (`@public` view rule) serve directly (cacheable).
- Files in a **protected** collection require an authenticated identity. Supply it
  via a bearer token, the auth cookie, or a short-lived **file token**:
  `POST /api/files/token` returns `{ "token": "<jwt>" }` (the caller must already be
  authenticated). Pass that token to the serve endpoint as the `token` query
  parameter: `GET /api/files/:col/:rec/:name?token=...`.

### Content handling

Only known-safe types are rendered inline (images such as png/jpg/gif/webp/avif/
bmp/ico, plus pdf). Everything else is served as a download:
`Content-Disposition: attachment` with `X-Content-Type-Options: nosniff` (this
neutralizes HTML/SVG/JS XSS). Appending `?download` forces a download for any type.

---

## Static files

When static serving is configured (see [framework.md](framework.md) for the
comptime modes and the `--serve-static <dir>` flag), GET and HEAD requests that
match none of the admin UI (`/_/`), the built-in API, or the app's custom routes
are served from the static root. The `/api` namespace (the bare `/api` path and
everything under `/api/`) is never served statically — an unmatched API path
keeps the JSON 404 envelope, while a static miss returns a plain-text 404
(`text/plain`).

Static files are served **without authentication** — collection access rules do
not apply to the static root, so never place secrets there. For access-controlled
file delivery, use [file storage](#files) instead.

- `/` and directory paths resolve to that directory's `index.html`.
- **Caching:** in **embedded** mode, each asset has a precomputed CRC32 content
  `ETag`; a request with a matching `If-None-Match` gets `304 Not Modified` from
  zigbase itself. In **dir** mode (comptime-hardcoded `.dir` or `--serve-static`),
  caching is delegated to facil.io's `sendFile`, which emits its own `ETag`,
  `Last-Modified`, `Cache-Control: max-age=3600`, and handles `If-None-Match`/`304`.
- Every response includes `X-Content-Type-Options: nosniff`; content types are
  derived from the file extension (html, css, js, mjs, json, map, svg, png, jpg/jpeg,
  gif, webp, avif, ico, woff/woff2, ttf, wasm, txt, xml, pdf, mp4, webm; unknown →
  `application/octet-stream`).
- Paths containing `..`, backslashes, or NUL bytes are rejected (404). There are no
  directory listings and no `Range`/partial-content support.

---

## Realtime (WebSocket)

Connect to `ws://<host>/api/realtime` (the upgrade is gated to that exact path and
the connection Origin is validated against the server's allowlist). The allowlist is
`ZIGBASE_REALTIME_ORIGINS` / `--realtime-origins` (CSV). It is **empty by default, which
denies cross-origin browser upgrades** — set your app origin(s) only if your frontend is served
from a *different* origin. **Same-origin upgrades** (the embedded admin UI, or a frontend served
from this same binary — the Origin authority equals the request `Host`) are **always allowed**,
so the common single-binary deployment needs no configuration. A request with **no** `Origin`
header (a non-browser client) is allowed regardless; delivery is still gated per-record by each
collection's `viewRule`.

### Authenticating

Send the JWT explicitly as a frame — the auth **cookie is intentionally NOT used**
over WebSocket (defense against cross-site WebSocket hijacking):

```json
{ "action": "auth", "token": "<jwt>" }
```

The server replies `{ "type": "auth", "status": "ok" | "error" }`.

### Subscribing

```json
{ "action": "subscribe", "topic": "posts" }
{ "action": "subscribe", "topic": "posts/RECORD_ID", "filter": "status = 'published'" }
```

A topic is either a whole collection (`<collection>`) or a single record
(`<collection>/<id>`). `filter` is optional and uses the
[filter grammar](#filter-grammar). Unsubscribe with
`{ "action": "unsubscribe", "topic": "..." }`. The server acknowledges subscribe/
unsubscribe with `{ "type": "ack", "action": "...", "topic": "..." }`. On connect it
sends `{ "type": "connect", "clientId": "..." }`.

**Authentication is required to subscribe** to any collection whose `viewRule` is not
`"@public"`. A socket may subscribe anonymously *only* to a public (`@public`) collection;
for a locked, owner-scoped, or expression-gated collection you must send a successful
`auth` frame first, otherwise `subscribe` is rejected with
`{ "type": "error", "message": "authentication required to subscribe" }`. (Delivery is
*also* re-authorized per record, so auth-before-subscribe is a layered, not the only, check.)

The server enforces a global cap on concurrent WebSocket connections; once reached, new
upgrades are rejected with HTTP `503`.

### Event frames

When a subscribed record changes, the server pushes:

```json
{
  "type": "event",
  "topic": "posts",
  "action": "create",
  "record": { "id": "...", "title": "..." }
}
```

`action` is one of `create`, `update`, `delete`. For `delete`, `record` is id-only.
Delete events are authorized per subscriber against a snapshot of the just-deleted record,
so an owner-scoped (or otherwise gated) `viewRule` only notifies subscribers who were allowed
to view that record — a delete on someone else's record is not leaked to other subscribers.

Malformed or unknown client frames produce
`{ "type": "error", "message": "..." }`.

---

## See also

- [tutorial.md](tutorial.md) — build an app on ZigBase, end to end.
- [fields.md](fields.md) — the complete field-type & options catalog.
- [recipes.md](recipes.md) — provisioning, access rules, hooks, custom routes, jobs.
- [framework.md](framework.md) — embedding ZigBase as a Zig library.
