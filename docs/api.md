# ZigBase REST + WebSocket API

ZigBase is a single-binary backend. This document is the user-facing reference for
its HTTP REST API and its realtime WebSocket interface. It describes only what the
server actually implements.

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
| `null` | Locked — only a superuser may perform the operation; everyone else is denied. |
| `""` (empty string) | Public — anyone may perform the operation. |
| a filter expression | The operation is allowed only when the expression matches (using the [filter grammar](#filter-grammar), including `@request.*` macros). |

Superusers bypass all rules.

**Denial status codes:**

- **view / update / delete** on a record that does not exist *or* does not satisfy
  the rule return **404** — this hides record existence.
- **create** denial returns **403**.
- A **locked** (`null`) list/view rule denies non-superusers (list returns 403; view
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

### Verification & password reset — mailer limitation

> **Important:** ZigBase currently has **no mailer**. The verification and
> password-reset endpoints **write their tokens to the server log** instead of
> emailing them. See [KNOWN_LIMITATIONS.md](../KNOWN_LIMITATIONS.md). To complete a
> flow, read the token from the server log and POST it to the matching
> `confirm-*` endpoint (each `confirm-*` request takes a `token` field).

### OAuth2

ZigBase uses **client-driven PKCE**: the client generates and holds the PKCE state
and code verifier, runs the authorization redirect itself, then submits the
authorization `code` to the server.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/collections/:col/oauth2-providers` | List enabled providers (name, `authURL`, `clientId`, `scopes`). Secrets are never returned. |
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

---

## Files

File-type fields hold uploaded files.

- **Upload:** files are submitted via `multipart/form-data` on record create
  (`POST .../records`) or update (`PATCH .../records/:id`), alongside the other
  field values.
- **Serve:** `GET /api/files/:col/:rec/:name`.

### Access

File access reuses the collection's **view** rule:

- Files in a **public** collection (empty view rule) serve directly.
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

## Realtime (WebSocket)

Connect to `ws://<host>/api/realtime` (the upgrade is gated to that exact path and
the connection Origin is validated against the server's allowlist).

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

Malformed or unknown client frames produce
`{ "type": "error", "message": "..." }`.
