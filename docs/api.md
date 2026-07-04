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
- **List envelope:** every list endpoint returns `{"items":[…]}`, never a bare array. Endpoints
  that paginate additionally use the records cursor vocabulary (`?cursor=`/`?limit=` request
  params; `nextCursor`/`hasNext` response keys — see [Cursor (keyset) pagination](#cursor-keyset-pagination)).
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
   unsafe methods (POST, PUT, PATCH, DELETE) additionally require a double-submit
   CSRF check: send the value of the readable `zb_csrf` cookie back in the
   `X-CSRF-Token` header. The server compares it against the CSRF claim embedded in
   the token; a missing or mismatched header fails authentication on unsafe methods.

The `zb_auth` cookie is httpOnly, `SameSite=Strict`; `zb_csrf` is readable (not
httpOnly), `SameSite=Strict`. Both are set by the auth endpoints (see [Auth](#auth)).

#### CSRF on unsafe methods (cookie sessions)

This applies only to the **cookie** transport. Bearer-token requests carry no
ambient cookie, so they are not subject to the CSRF check.

- **Safe methods (`GET`, `HEAD`, `OPTIONS`) are exempt.** Reads work with just the
  cookie — no header needed.
- **Unsafe methods (`POST`, `PUT`, `PATCH`, `DELETE`) require the header.** The
  request must carry `X-CSRF-Token` equal to the current `zb_csrf` cookie value, or
  the request is treated as **unauthenticated**. The resulting status then follows
  the [access rules](#access-rules): a `POST` (create) denial returns `403`, while a
  `PATCH`/`DELETE` denial on a protected record returns `404` (to hide the record's
  existence).

If you authenticate and read fine but writes return `403` (or `404` on
updates/deletes), this is almost always the missing piece: the client never echoed
the `zb_csrf` cookie into the `X-CSRF-Token` header.

The `zb_csrf` cookie is deliberately **not** httpOnly so that a browser SPA / `fetch`
client can read it and replay it as a header on writes — that is what makes the
double-submit check work. Read the cookie and set the header on every unsafe
request:

```js
// read the readable zb_csrf cookie, send it back as X-CSRF-Token on writes
const csrf = document.cookie
  .split("; ")
  .find((c) => c.startsWith("zb_csrf="))
  ?.slice("zb_csrf=".length);

await fetch("/api/collections/posts/records", {
  method: "POST",
  credentials: "include", // send zb_auth + zb_csrf cookies
  headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
  body: JSON.stringify({ title: "Hello" }),
});
```

---

## Collections

Collection management endpoints are **superuser-only**.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/collections` | List all collections: `{"items":[…]}` (changed: was a bare array). |
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
type-specific `options` object. Common options include `required`, `unique`, and
`encrypted` (text/editor/json only — see
[fields.md → Encryption at rest](fields.md#encryption-at-rest-encrypted));
`relation` fields reference another collection. Auth collections (`"type":"auth"`)
have system fields such as `email` injected automatically.

### Collection options

The collection body carries an `options` object for collection-level settings. Beyond the
auth block on auth collections (see [Auth](#auth)), one notable option is row expiry:

| Option | Type | Meaning |
| --- | --- | --- |
| `ttl_field` | string \| null | Name of a `date`/`autodate` field on this collection used as the row's **expiry timestamp**. Rows whose value is non-null and at/before "now" are reaped by an internal GC and **hidden from every read** (list, get, relation expand). Default `null` = no expiry. |

```jsonc
// create a TTL collection — "expires_at" rows auto-expire
{
  "name": "sessions",
  "type": "base",
  "fields": [
    { "name": "token", "type": "text" },
    { "name": "expires_at", "type": "date" }
  ],
  "options": { "ttl_field": "expires_at" }
}
```

Expiry is **eventually consistent**: the GC sweeps at startup and every ~5 minutes, but
expired rows are excluded from reads immediately by a read-time predicate. See
[framework.md → Row expiry (TTL)](framework.md#row-expiry-ttl--ttl_field) for the full
semantics.

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

### Update: changing a password on an auth collection

A `PATCH` on an **auth** collection's record that includes a `password` field is a
self-service password change, gated on top of the normal update rule:

- **Non-superusers must also send a verifying `oldPassword`.** A wrong `oldPassword`, a
  missing `oldPassword`, an unknown record, or a target record with no password set
  (passwordless — e.g. OAuth2-only) all return the **same** login-identical
  `400 {"message":"Invalid credentials."}` — the failure modes are indistinguishable by
  design, so the endpoint can't be used to probe which accounts have a password.
  Passwordless accounts cannot bootstrap a password via `PATCH`; use the password-reset
  email flow or a superuser update instead.
- **Superusers are exempt** from the `oldPassword` check (and from its rate limit — see
  [Rate limiting](#rate-limiting)).
- On a successful **self-change** (the caller is the record being updated), the response
  sets fresh `zb_auth`/`zb_csrf` cookies — the JSON body itself stays the plain updated
  record.
- Every other outstanding session for the record is invalidated (the same guarantee as
  `confirm-password-reset`).

This rides the record `beforeUpdate`/`afterUpdate` hooks plus the `.auth`
`beforePasswordChange`/`afterPasswordChange` lifecycle hooks — see
[framework.md §6](framework.md#auth-lifecycle-hooks-register--logout--refresh--password-change).

### List: query parameters

The list endpoint supports two pagination styles: **offset** (`page`/`perPage`) and
**cursor** (keyset). Both can be enabled/disabled at compile time (see
[Pagination configuration](#pagination-configuration)); by default both are on.

| Param | Default | Meaning |
| --- | --- | --- |
| `page` | `1` | Offset page number (1-based). |
| `perPage` | `30` | Items per page (clamped to 500). |
| `cursor` | — | Opaque keyset cursor. Its **presence** (even empty `cursor=`) selects cursor mode; an empty value is the first page. |
| `limit` | — | Cursor-mode page size (alias of `perPage`, clamped to 500); its presence also selects cursor mode. |
| `skipTotal` | `true` in cursor mode | Skip the `COUNT(*)` total. Set `skipTotal=false` to include `totalItems`/`totalPages`. |
| `filter` | — | Filter expression (see [Filter grammar](#filter-grammar)). |
| `sort` | — | Sort spec (see [sort](#sort)). In cursor mode this defines the keyset order; `id` is auto-appended as a tiebreaker. |
| `search` | — | Full-text search terms (alias `q`). Matches `searchable` fields; results are ranked by relevance (see [Search](#search)). |
| `vector` | — | Nearest-neighbor search (opt-in `-Dvector` build only); `<field>[:cosine|:l2]:<json-embedding>` (see [Search](#search)). |
| `expand` | — | Relation expansion (see [expand](#expand)). Works in both modes. |

The **offset** list response envelope:

```json
{
  "page": 1,
  "perPage": 30,
  "totalItems": 42,
  "totalPages": 2,
  "items": [ { "id": "...", "title": "..." } ]
}
```

### Cursor (keyset) pagination

Offset pagination walks `page`/`perPage` but has two structural problems: deep offsets
(`OFFSET 100000`) scan every skipped row, and an insert/delete on an earlier page shifts
every later page (duplicating or skipping rows during infinite scroll). **Cursor
pagination** fixes both: each page returns an opaque `nextCursor`/`prevCursor` that encodes
the boundary row's sort-key values, and the next request resumes *strictly after* that
boundary — value-based, so it's drift-resistant and cheap regardless of depth.

Send `cursor=` (empty) or a `limit` to start a cursor walk, then forward `nextCursor`:

```
GET /api/collections/posts/records?sort=-created&limit=20&cursor=
GET /api/collections/posts/records?sort=-created&limit=20&cursor=<nextCursor>
```

The **cursor** list response envelope:

```json
{
  "page": 0,
  "perPage": 20,
  "nextCursor": "eyJ2Ijox...",
  "prevCursor": null,
  "hasNext": true,
  "hasPrev": false,
  "items": [ { "id": "...", "title": "..." } ]
}
```

`totalItems`/`totalPages` are present only when `skipTotal=false`. `page` is `0` (a sentinel:
"cursor mode"; `page` is not meaningful for keyset). Walk backward with `prevCursor`.

**Rules and filters always apply** — a cursor only narrows the *window*; the collection's
list rule and your `filter` are still AND-ed into the same query, so a cursor can never reveal
a row a rule would hide. Cursor values are bound parameters (never interpolated into SQL).

**Stale cursors fail loudly.** A cursor is bound to the `sort` and `filter` it was minted
under. Reusing it with a different `sort` returns **400** ("Cursor does not match the requested
sort."); a different `filter` returns **400** ("Cursor does not match the requested filter.");
a malformed/oversized token returns **400** ("Invalid cursor.").

#### Pagination configuration

Both modes and the cursor **token format** are selected at compile time on `App(.{ ... })`:

```zig
zigbase.App(.{
    .pagination = .{
        .offset = true,             // enable page/perPage (default true)
        .cursor = true,             // enable cursor (default true)
        .cursor_token = .stateless, // .stateless | .signed | .stateful (default .stateless)
    },
});
```

- **`.offset = false`** rejects `page`/`perPage` with a 400; only cursor paging is allowed.
- **`.cursor = false`** rejects `cursor` with a 400; only offset paging is allowed.
- Setting **both to false** is a compile error (a list endpoint must have a pagination mode).

The three cursor **token formats** trade off statelessness vs. tamper-evidence:

| `cursor_token` | What the token is | Tamper-evident? | State | Notes |
| --- | --- | --- | --- | --- |
| `.stateless` (default) | base64url JSON payload, validated structurally + against the request's sort/filter | No (rules + parameterization provide the security) | None | CDN-friendly; byte-compatible with the SDK's client-synthesized cursors. |
| `.signed` | the stateless payload + an HMAC-SHA256 tag keyed by the **server's JWT secret** | Yes — a tampered/hand-crafted token returns 400 ("Invalid cursor signature.") | None | No extra config; reuses the existing token secret. Not synthesizable by a client without the secret. |
| `.stateful` | a random opaque id; the keyset payload is stored server-side in `_cursorStates` with a TTL | N/A (server holds the state) | A row per minted cursor, GC'd on expiry | Smallest token; unknown/expired id returns **410 Gone**. Not compatible with client-synthesized cursors. |

For most apps the default **`.stateless`** is the right choice — security comes from access
rules gating every row and from parameterized binding, not from signing the cursor. Choose
`.signed` when you want tamper-evidence with no extra storage, or `.stateful` when you want the
server to fully control cursor validity/expiry (e.g. revocable cursors) and can accept a small
write per page.

#### SDK forward-compatibility

The cursor response shape (`items` + `nextCursor`/`prevCursor`/`hasNext`/`hasPrev` +
optional `totalItems`) is exactly what the TypeScript SDK's `CursorPage` reads, so the SDK can
forward a native `cursor` instead of synthesizing the keyset filter itself, with no SDK type
changes. Treat the token as fully opaque and round-trip whatever the server returned.

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
| `in` | set membership — `field in (a, b, c)` or `field in <list-macro>` |

The `in` operator tests a field against a **list**: either a parenthesized,
comma-separated literal list (`status in ("draft", "published")`) or a list-valued
macro (see below). It compiles to a parameter-bound `IN (?, ?, …)`. An **empty** list
(`field in ()`, or an empty membership set) matches nothing (fail-closed). `in` is a
reserved word — a field literally named `in` cannot appear bare on the left of a
comparison.

**Boolean combination:** `&&` (and), `||` (or), with parentheses `( )` for grouping.

**Operands:** field paths (identifiers, may contain `.` for relation traversal,
e.g. `author.name`), single- or double-quoted strings, numbers, booleans
(`true`/`false`), and `null`.

**String escapes:** inside a quoted string a backslash starts an escape:
`\\` → `\`, `\'` → `'`, `\"` → `"`, plus `\n` `\t` `\r`. This lets a value contain
the same quote character used to delimit it (e.g. `name = 'O\'Brien'`) or even both
quote characters at once (`name = 'both \' and \"'`). A backslash followed by any
other character is rejected. The bound parameter receives the unescaped value.

**Request macros** resolve against the current request:

| Macro | Value |
| --- | --- |
| `@request.auth.<field>` | a field of the authenticated record (e.g. `@request.auth.id`) |
| `@request.data.<field>` | a field of the incoming request body |
| `@request.method` | the HTTP method (e.g. `"GET"`) |
| `@request.account.id` | the active account scope's id (`""` when none); multi-tenancy foundation |
| `@request.account.role` | the principal's role in the active account (`""` when none) |
| `@request.account.ids` | **list macro** — every account the principal belongs to; use with `in` |

> The `@request.account.*` macros are the **foundation** for multi-tenancy and
> row-level/relationship authorization. Until the tenancy resolver ships they resolve
> to `""` / the empty list, so a rule using them is fail-closed and existing rules are
> unaffected. A typical use is scoping a collection to the caller's accounts:
> `account in @request.account.ids`.

Examples:

```text
status = "published"
title ~ "zig" && views >= 100
@request.auth.id = owner
author.role = "admin" || @request.method = "GET"
status in ("draft", "published")
account in @request.account.ids
```

> **Encrypted fields are not filterable or sortable.** A field marked `encrypted` (see
> [fields.md → Encryption at rest](fields.md#encryption-at-rest-encrypted)) is stored as
> per-row-nonce ciphertext, so referencing it in `filter` or `sort` returns
> **`400`** (`"Cannot filter or sort by an encrypted field."`). The same applies to an
> access rule comparing an encrypted field — it can only ever match against ciphertext.

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

### Search

ZigBase has first-class search on the list endpoint. It is **not** a separate, unscoped query:
the search predicate is AND-ed into the *same* composed `WHERE` as your `filter`, the list rule,
abilities and tenant scope — so **search can never widen visibility**. A search of a
tenant-owned or ability-guarded collection returns only the rows the caller may already view.

**Full-text (FTS5) — default build.** Mark one or more `text`/`editor` fields `.searchable` in
the schema:

```zig
.posts = .{ .fields = .{
    .title = .{ .type = .text, .searchable = true },
    .body  = .{ .type = .editor, .searchable = true },
} },
```

At startup ZigBase provisions an [FTS5](https://www.sqlite.org/fts5.html) **external-content**
index per searchable collection (`"<col>_fts"`, `content='<col>'`) plus `INSERT`/`UPDATE`/`DELETE`
triggers that keep it in lock-step with the base table — no doubled storage, no migration. Query
it with `search` (or its alias `q`):

```text
GET /api/collections/posts/records?search=zig%20database
GET /api/collections/posts/records?q=alpha%20OR%20beta&filter=published=true
```

Results are ranked by relevance (`bm25`) in offset mode. The terms support the basic FTS5
operators (`AND`, `OR`, `NOT`, and a trailing `*` for prefix search); the whole term is passed
as a **bound parameter** (never interpolated) and lowered to a guaranteed-valid query, so a
malformed input is harmless — it can never become a SQL error or injection. `search` AND-s with
your `filter` (the result is the intersection — a row must match both). A `search` whose terms
reduce to nothing (e.g. operator-only, `?search=AND`) matches **no rows** rather than returning the
whole collection. A `search` on a collection with no `searchable` field returns **400**. The
`_fts` collection-name suffix is reserved (it backs the per-collection shadow tables).

**SQLite FTS5 is compiled in by default — opt out with `-Dfts5=false`.** A lean custom build
that never declares a `.searchable` field can drop FTS5 (`~250-400 KB` smaller); a `?search=`
then answers a clean **400**, and the server **refuses to start** over a `.searchable` SQLite
schema. Postgres full-text search (below) is unaffected by the flag. See
[docs/search.md](./search.md#build-requirement--dfts5-default-on).

**Full-text on Postgres.** On a Postgres backend the SAME `.searchable` schema flag
and `?search=` API are backed by PostgreSQL's native full-text search instead of FTS5: each
searchable collection gets a `STORED` `tsvector` **generated column** (`to_tsvector('simple', …)`
over the searchable columns) plus a **GIN index**, queried with `@@ plainto_tsquery('simple', $n)`
and ranked by `ts_rank(…) DESC`. The query surface, the bound-parameter safety, and — critically —
the *same composed-`WHERE` scoping* (filter + list rule + abilities + tenant) are identical to the
SQLite path, so a tenant-/ability-scoped search returns only the rows the caller may view on either
backend. The exact relevance ORDER can differ between the two ranking functions (FTS5 `bm25`
length-normalizes; `ts_rank` does not), but the matched set is equivalent. `plainto_tsquery` parses
the plain term (it does not honor the `AND`/`OR`/`NOT`/`*` operators).

**Vector / nearest-neighbor — opt-in `-Dvector` build.** Vector search is **not** compiled into the
default binary. The single `-Dvector=true` flag enables KNN on **both** backends — on SQLite it
vendors and links [`sqlite-vec`](https://github.com/asg017/sqlite-vec) (registered on every
connection); on Postgres it emits the [pgvector](https://github.com/pgvector/pgvector) lowering. It
enables KNN ordering over a field that stores a JSON embedding array:

```text
GET /api/collections/docs/records?vector=embedding:cosine:[0.12,0.04,...]
GET /api/collections/docs/records?vector=embedding:l2:[0.12,0.04,...]&filter=lang="en"
```

The form is `<field>[:cosine|:l2]:<json-embedding>` (cosine is the default metric); rows are
ordered nearest-first. The embedding is validated (a non-empty JSON array of finite numbers) and
bound; a malformed or dimension-mismatched embedding returns a clean **400**. In the **default
build** a `vector` query returns **400** (`"Vector search is not enabled in this build."`), and the
binary is byte-for-byte unaffected. Vector search runs in offset mode (cursor paging is rejected
with 400).

The **stored** embedding field must hold a **numeric JSON array of a consistent dimension** across
the collection's rows — that is the value the distance operator compares against. There is currently
**no write-time validation** of stored embeddings (planned as future work), so a row whose embedding
is malformed (valid JSON but not a numeric array) or of a differing dimension makes that scoped
collection's `?vector=` query **fail closed** — a clean **400** (no data leak; the connection
recovers), symmetric on both backends — until the offending row is corrected.

**Vector on Postgres (pgvector) — opt-in `-Dvector` build.** On a Postgres backend the SAME
`?vector=` API is backed by pgvector: the embedding column and the bound query embedding are cast to
the `vector` type at query time and ordered by the native KNN operators `<=>` (cosine distance) /
`<->` (L2). The embedding stays in an ordinary JSON field (no schema change) — a brute-force scan,
exactly symmetric with sqlite-vec's scalar distance (no ANN index either side). A `-Dvector` build
runs `CREATE EXTENSION IF NOT EXISTS vector` at startup, so the target PostgreSQL must have
**pgvector available** (e.g. the [`pgvector/pgvector:pgNN`](https://hub.docker.com/r/pgvector/pgvector)
image, or `apt install postgresql-NN-pgvector`); if the connecting role lacks privilege to create
the extension, install it once as a superuser (`CREATE EXTENSION vector;`) — startup then logs a
warning and continues rather than aborting. As with full-text search, the KNN composes with the
*same composed-`WHERE` scoping* (filter + list rule + abilities + tenant), so a tenant-/ability-scoped
vector search returns only the rows the caller may view — identically on both backends.

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
| POST | `/api/collections/:col/request-verification` | Request an email-verification token. `204` (no body). |
| POST | `/api/collections/:col/confirm-verification` | Confirm verification with a token. `204` (no body) on success. |
| POST | `/api/collections/:col/request-password-reset` | Request a password-reset token. `204` (no body). |
| POST | `/api/collections/:col/confirm-password-reset` | Confirm a reset with a token. `204` (no body) on success. |
| GET | `/api/collections/:col/auth/sessions` | List the caller's active sessions. `.session_store = .table` only — `404` in `.epoch` mode. |
| DELETE | `/api/collections/:col/auth/sessions/:sid` | "Log out THIS device". `204` (no body). `.session_store = .table` only — `404` in `.epoch` mode. |
| DELETE | `/api/collections/:col/auth/sessions` | "Log out everywhere" — works in both session-store modes. `204` (no body). |

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

When you authenticate via these cookies, writes must echo the `zb_csrf` cookie in
the `X-CSRF-Token` header — see
[CSRF on unsafe methods](#csrf-on-unsafe-methods-cookie-sessions).

> **Embeddable hooks.** When ZigBase is used as a Zig library, `auth-refresh` and
> `auth-logout` run through the `.auth` lifecycle hook group (`before_refresh` /
> `after_refresh`, `before_logout` / `after_logout`); a `before` hook that fails closed
> aborts the request before any session change. `beforeAuthSuccess` also fires on
> `auth-with-password` (tag `.password`) and `auth-refresh` (tag `.refresh`, in the same
> transaction as `beforeRefresh`, lifecycle phase first) — see
> [framework.md → Auth lifecycle](framework.md#auth-lifecycle-beforeauthsuccess). Embedders
> also get the `ctx.auth()` session verbs (`refresh` / `rotate` / `revokeAllSessions`, and
> per-device `listActiveSessions` / `revoke`) and the optional table-backed session store.
> See [framework.md §6](framework.md#6-auth--file--lifecycle-events).

### Session management

`GET`/`DELETE /api/collections/:col/auth/sessions[/:sid]` (added in the auth endpoints
table above) are the REST surface over the table-mode `ctx.auth()` session verbs (the
TypeScript SDK's `listSessions`/`revokeSession`/`revokeAllSessions` ride these):

```json
// GET /api/collections/:col/auth/sessions — 200
{
  "items": [
    { "id": "...", "created": "...", "last_seen": "...", "user_agent": "...", "ip": "...", "is_current": true }
  ]
}
```

- `items` is newest-first.
- `DELETE …/auth/sessions/:sid` ("log out this device") returns **`204`** with an empty
  body on success. A `:sid` you don't own and an absent `:sid` are an **identical `404`**
  (non-owner probing can't be distinguished from a stale/unknown id).
- Both per-device routes return **`404`** when the collection is running in `.epoch` mode
  (the feature simply isn't enabled — same non-oracle policy as a disabled auth-method slug).
- `DELETE …/auth/sessions` ("log out everywhere") works in **both** modes: it bumps the
  token epoch (killing every outstanding token, including ones minted before `.table` was
  enabled) and, in table mode, also wipes the principal's session rows. It returns `204`
  and **clears** the caller's own auth cookies — the current session dies too, by design.
- `:col` must match the caller's authenticated collection, else `401` (parity with
  `auth-refresh`).

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
the email exists). The matching `confirm-*` endpoint takes that `token` in its body and
also returns `204` (no body) on success.

- **With SMTP configured** (`ZIGBASE_SMTP_HOST` + friends — see the
  [README config table](../README.md#configuration)), the token is **emailed** over
  the configured transport (`none` / `starttls` / `implicit` / `auto`).
- **With a local MTA** (`ZIGBASE_SENDMAIL_COMMAND`, e.g. `sendmail -t -i` / `msmtp -t`),
  the message is piped to that command instead — the app holds no SMTP credentials. This
  takes precedence over `ZIGBASE_SMTP_HOST`.
- **Without either** (the default), the token is **logged to the server** instead — a
  dev/CI convenience. To complete a flow locally, read the token from the log and POST
  it to the matching `confirm-*` endpoint.

Verification and password-reset tokens are **strictly single-use**: each token carries a
random `jti` that is recorded on first redemption, so a second `confirm-*` with the same
token is rejected with `400` (independent of the token's TTL). The reset path validates the
new password *before* consuming the token, so a too-short password does not burn it.

Configure SMTP or a local MTA command for production; see
[KNOWN_LIMITATIONS.md → Auth & email](../KNOWN_LIMITATIONS.md).

### Auth method endpoints (pluggable auth)

For every auth collection that enables a method (built-in or custom), two endpoints are auto-mounted:

| Method | Path | Description |
|---|---|---|
| POST | `/api/collections/:col/auth/:method/initiate` | Phase 1: challenge/email/options. Returns 200 with method-specific JSON body, or 204 for enumeration-safe methods (e.g. magic-link). |
| POST | `/api/collections/:col/auth/:method/complete` | Phase 2: proof → session. Returns 200 with `{ token }` and sets `zb_auth`/`zb_csrf` cookies on success. |

`:method` is the method slug (`magic_link`, `otp`, `password`, `webauthn`, `oauth2`, or a custom plugin's slug). Returns 404 when the collection doesn't exist, isn't an auth collection, or the method isn't enabled.

> The generated TypeScript client exposes these as `zb.auth.<col>.<method>.{initiate,complete}`. Built-ins are typed; custom methods can declare comptime I/O types to get precise interfaces too — see [typescript-sdk.md → Typed auth methods](typescript-sdk.md#typed-auth-methods--zbauth).

> **`require_verified`:** if the auth collection is configured with `require_verified: true`, `complete` returns **403** when the matched record's `verified` field is `false`. This applies to all methods — including WebAuthn and OAuth2 accounts from providers that did not confirm the email address (created `verified=false`).

**WebAuthn passkey registration** (authed — requires a valid session):

| Method | Path | Description |
|---|---|---|
| POST | `/api/collections/:col/auth/webauthn/register/begin` | Returns WebAuthn creation options (challenge, rpId, rpName). |
| POST | `/api/collections/:col/auth/webauthn/register/finish` | Stores the new passkey bound to the authenticated user. `204` (no body) on success. |

**magic_link initiate:**
```json
// request
{ "identity": "user@example.com" }
// response: 204 (enumeration-safe — always 204 whether email exists or not)
```

**magic_link complete:**
```json
// request
{ "token": "<magic-link-token>" }
// response (200) — sets zb_auth and zb_csrf cookies
{ "token": "<jwt>" }
```

**magic_link consume + redirect (the classic email-link UX):**

> Renamed from `magic_link` to dash-case in 0.10: `GET .../auth/magic-link/consume` (was
> `auth/magic_link/consume`). Hard cutover — no redirect shim — so links emailed by a
> pre-upgrade server 404 after the upgrade; tokens are short-lived, so this is a narrow
> window. The method **slug** (`magic_link`, used by `initiate`/`complete` above and in
> `onAuth`) is unchanged — only this bespoke consume path uses the dash.

| Method | Path | Description |
|---|---|---|
| GET | `/api/collections/:col/auth/magic-link/consume?token=...&redirect=/app` | Verify + consume the token, set `zb_auth`/`zb_csrf` cookies, and `302` to the redirect target. For browser email links: the user clicks a plain GET URL and lands logged-in. Fires `onAuth(.magic_link)` and honors `require_verified` (403) exactly like `complete`. |

The token is single-use (replay returns `400 Link already used.`); a missing token returns `400`, and the route `404`s unless `magic_link` is enabled on the collection.

The `redirect` target is validated **server-side** so each app does not re-implement an open-redirect guard. Only same-origin **relative** paths are ever honored — anything with a scheme/host, a protocol-relative `//host`, a backslash, a `.`/`..` path-traversal segment, an encoded `%2e`/`%2f`/`%5c`, or a control/CRLF byte is rejected. A per-method allow-list narrows it further:

```jsonc
// collection options.auth.methods.magic_link
{
  "ttl_s": 900,
  "redirect_default": "/club/welcome",      // used when ?redirect= is absent or rejected
  "redirect_allow": ["/club/", "/dashboard"] // entry ending in "/" is a prefix; else exact path
}
```

- Empty `redirect_allow` ⇒ any same-origin relative path is accepted (the scheme/host guard still applies).
- A non-empty `redirect_allow` restricts to matching paths; a non-matching (or unsafe) `?redirect=` falls back to `redirect_default`.
- `redirect_default` itself must be a safe relative path; an off-origin value degrades to `/`.

**otp initiate:**
```json
// request
{ "identity": "user@example.com" }
// response: 204
```

**otp complete:**
```json
// request
{ "identity": "user@example.com", "code": "123456" }
// response (200)
{ "token": "<jwt>" }
```

**webauthn initiate:**
```json
// request (identity optional for discoverable credentials)
{ "identity": "user@example.com" }
// response (200)
{ "challenge": "<base64url>", "rpId": "app.example.com", "ceremonyId": "<opaque>" }
```

**webauthn complete:**
```json
// request
{
  "ceremonyId": "<opaque>",
  "credentialId": "<base64url>",
  "authenticatorData": "<base64url>",
  "clientDataJSON": "<base64url>",
  "signature": "<base64url>"
}
// response (200)
{ "token": "<jwt>" }
```

**webauthn register/begin (authed):**
```json
// request: empty body or {}
// response (200)
{ "challenge": "<base64url>", "rpId": "app.example.com", "rpName": "My App", "ceremonyId": "<opaque>" }
```

**webauthn register/finish (authed):**
```json
// request
{
  "ceremonyId": "<opaque>",
  "id": "<base64url>",
  "rawId": "<base64url>",
  "response": {
    "clientDataJSON": "<base64url>",
    "attestationObject": "<base64url>"
  }
}
// response (200): {}
```

### The `onAuth` hook — fires on every login

Every successful login — password, OAuth2, magic-link, OTP, WebAuthn, and custom flows built with
`ev.issueSession` / `zigbase.auth.issueSession` — fires the `onAuth` handler
registered in your `App(.{ .onAuth = ... })`. This is the single chokepoint for
cross-cutting session logic (audit logging, account-state checks, etc.). There is no
path through ZigBase's session-issuance machinery that bypasses it.

`AuthEvent.method` is an enum: `.password`, `.oauth2`, `.magic_link`, `.otp`, `.webauthn`,
`.custom` for custom plugins, or `.refresh` for `auth-refresh` (previously mislabeled
`.password`).

See [framework.md §6](framework.md#6-auth--file--lifecycle-events) for the
`zigbase.auth` helper surface and the seam guarantee.

### Rate limiting

The sensitive auth endpoints — `auth-with-password` (login), `request-verification`,
`request-password-reset`, password change (`PATCH …/records/:id` with a `password`, scope
`pwchange`), and all `auth/:method/initiate` / `auth/:method/complete` endpoints — are rate
limited. Over the limit, the endpoint returns **`429 Too Many Requests`**
(`{ "message": "Too many requests. Try again later." }`). Password change shares the same
global `ZIGBASE_RATE_LIMIT_MAX`/`ZIGBASE_RATE_LIMIT_WINDOW` budget as `login`/`verify`/`reset`
(it isn't a `.auth.methods` entry, so it has no per-method override); superusers bypass it.

Per-method rate-limit behavior is configured in `.auth.methods` via the `rate_limit` field (`.default` | `.off` | `.{ .custom = .{ .max, .window_s } }`). See [framework.md §6](framework.md#6-auth--file--lifecycle-events).

- **Config:** `ZIGBASE_RATE_LIMIT_MAX` attempts (default `10`) per
  `ZIGBASE_RATE_LIMIT_WINDOW` seconds (default `60`), per client key, per endpoint.
  Setting `ZIGBASE_RATE_LIMIT_MAX=0` disables only the **global** env-configured limiter;
  any per-method `.auth.methods.<m>.rate_limit = .{ .custom = … }` still applies (a custom
  limit overrides the global one for that method). To turn a specific method's limiting off,
  set its `rate_limit = .off`.
- **Keying:** `X-Forwarded-For` / `X-Real-IP` are **ignored by default** — they are
  attacker-controlled on direct exposure. With `--trust-proxy` (`ZIGBASE_TRUST_PROXY=true`),
  set **only** behind a trusted reverse proxy that rewrites them, the key is the IP from
  `X-Forwarded-For` (first hop) or `X-Real-IP`. Otherwise the limiter keys on the submitted
  identity/email, which is not header-spoofable. This makes direct exposure safe by default.

### OAuth2

ZigBase uses **client-driven PKCE**: the client generates and holds the PKCE state
and code verifier, runs the authorization redirect itself, then submits the
authorization `code` to the server.

OAuth2 is the **fifth built-in `AuthMethod`** (slug `oauth2`) and is exposed
exclusively through the standard auth-method contract endpoints:

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/collections/:col/auth/oauth2/providers` | List enabled providers (`name`, `authURL`, `clientId`, `scopes`) as `{"items":[…]}` (changed: was `{"providers":[…]}`). Secrets are never returned. Gated on `.auth.oauth2.enabled`. |
| POST | `/api/collections/:col/auth/oauth2/initiate` | Return provider metadata so the client can drive the authorization redirect. |
| POST | `/api/collections/:col/auth/oauth2/complete` | Exchange the authorization code for a session. |
| DELETE | `/api/collections/:col/records/:id/external-auths/:provider` | Unlink a provider from a record. |

**`GET .../auth/oauth2/providers`** — no request body. Response:

```json
{
  "items": [
    { "name": "google", "authURL": "https://accounts.google.com/o/oauth2/v2/auth?...", "clientId": "my-client-id.apps.googleusercontent.com", "scopes": ["openid", "email", "profile"] }
  ]
}
```

**`oauth2` initiate** — body `{ "provider": "<name>" }`:

```json
// response (200)
{
  "authURL": "https://accounts.google.com/o/oauth2/v2/auth?...",
  "clientId": "my-client-id.apps.googleusercontent.com",
  "scopes": ["openid", "email", "profile"],
  "state": "<server-issued-state>"
}
```

`state` is always present by default (`ZIGBASE_OAUTH_STATE_SERVER` defaults to `true`); omitted only when the server-side state is explicitly disabled.

**`oauth2` complete** — body:

```json
{
  "provider": "google",
  "code": "<authorization-code>",
  "codeVerifier": "<pkce-verifier>",
  "redirectUrl": "https://app.example.com/callback",
  "state": "<server-issued-state>"
}
```

`state` is required by default; omitted only when `ZIGBASE_OAUTH_STATE_SERVER=false`.
`redirectUrl` must be in the provider's configured allowlist.

```json
// response (200) — sets zb_auth and zb_csrf cookies
{ "token": "<jwt>" }
```

On success, `onAuth(.oauth2)` fires through the shared session seam. Security enforced on all paths: single-use TTL'd CSRF `state` consumed before the code exchange, PKCE required, redirect allow-list, and https-only provider URLs.

#### CSRF on the OAuth flow: `state`

The OAuth `state` parameter prevents login-CSRF. ZigBase supports two modes:

- **Server-side (default).** `ZIGBASE_OAUTH_STATE_SERVER` defaults to `true` (TTL via
  `ZIGBASE_OAUTH_STATE_TTL`, default 600s). The `initiate` endpoint issues a `state` value
  that the client must round-trip through the provider and back to `complete`. The backend
  verifies the state exists, matches the (collection, provider), is unexpired, and is
  **single-use** (deleted on first use). A missing, mismatched, expired, or replayed `state`
  is rejected with `400` before the provider is contacted.
  1. The client calls `POST .../auth/oauth2/initiate` with `{ "provider": "<name>" }` and
     receives `{ ..., "state": "<value>" }`.
  2. The client embeds that `state` in the provider authorization URL.
  3. On callback, the client adds `"state": "<value>"` to the `complete` body.
- **Client-driven (opt-out).** Set `ZIGBASE_OAUTH_STATE_SERVER=false` to restore the
  previous behavior: the SPA generates and verifies `state` itself; the backend does not
  see or check it.

**PKCE (`codeVerifier`) is required in both modes** — server-side `state` adds CSRF
protection, it does not replace PKCE.

---

## Settings (key/value store)

ZigBase ships a built-in key→value store (backed by an internal `_kv` system table) and a
**superuser-only** HTTP surface over it. It is the same store that the embeddable
`ctx.kv()` API and the admin UI's "Settings / Feature Flags" screen use, and where the
declared feature-flag/experiment overrides live (`flag:<name>`, `exp:<name>:weights`).
Every endpoint requires a valid **superuser** token (`401`/`403` otherwise); values are
server-managed and never public by default.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/settings` | List every setting: `{"items":[{ key, value, created, updated }, …]}` (changed: was a bare array). |
| GET | `/api/settings/:key` | Fetch one: `{ key, value }`; `404` if absent. |
| PUT | `/api/settings/:key` | Upsert. Body `{ "value": "..." }`; returns `{ key, value }`. A malformed body is `400`. |
| DELETE | `/api/settings/:key` | Remove; `204`, or `404` if absent. |

```json
// PUT /api/settings/welcome_banner   (Authorization: Bearer <superuser-jwt>)
{ "value": "Closed for maintenance" }
```

Values are stored as opaque strings. Declared feature flags (0.8.0) store their override
under the `flag:<name>` key as `"true"` / `"false"`; resolution uses the declared default
when no override is set. To publish a value to non-superusers, write your own custom route
that reads it via `ctx.kv()`, or `ctx.flagByName()` / `ctx.flags().resolveAll()` for declared
flags — see
[framework.md → Feature flags + experiments](framework.md#feature-flags--experiments-declared).

## Email — verified senders & bounce webhook (#154)

Tenant-scoped verified sender identities and a bounce/complaint ingestion webhook. These are
**additive and off by default** — see
[framework.md → Email subsystem](framework.md#email-subsystem-154-templates-providers-verified-senders-suppression).
Present only when `.mail` is configured — without it these routes are absent from your binary
(not merely 404 at runtime).
The sender routes require an authenticated principal and resolve the active account (via the
`X-Account-Id` header or signed `zb_account` cookie); a member may only manage its own account's
senders (fail closed, `403`). Superusers may target any account.

| Method | Path | Description |
| --- | --- | --- |
| POST | `/api/senders` | Request verification of a From address. Body `{ "email": "from@acct.com" }`; emails a single-use token. Returns `{ id, email, status }` (`201` pending, `200` if already verified). Re-sends are rate-limited per `(account,email)` — a repeat within ~60s is `429`. |
| POST | `/api/senders/:id/verify` | Confirm a pending identity. Body `{ "token": "..." }`; `{ "verified": true }` on success, `404` on a wrong/absent token (no oracle). |
| GET | `/api/senders` | List the active account's identities: `{ "items": [{ id, email, status, verified_at }, …] }` (changed in 0.10.0 — was a bare array). |
| POST | `/api/mail/webhooks/:provider` | Inbound bounce/complaint ingestion (`provider` = `ses` \| `postmark`). Verifies a shared-secret HMAC-SHA256 signature over `"<X-Webhook-Timestamp>.<provider>.<X-Account-Id>.<body>"` (constant-time) and a ±5m timestamp-freshness window; `401` on a stale timestamp or bad signature, `404` when no `webhook_secret` is configured. Upserts a suppression per hard bounce / complaint; returns `{ "suppressed": n }`. A genuine provider webhook (no signature/`X-Account-Id`) is GLOBAL-only — per-account scoping requires a signing relay. |

When `.mail.require_verified_sender = true`, an account-scoped send whose From is not a verified
identity is rejected. When `.mail.check_suppression = true`, a send to a suppressed recipient is
blocked.

## Features (declared registry)

A separate **superuser-only** read endpoint exposes the comptime-declared flag + experiment
registry together with each entry's active `_kv` override:

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/features` | Return declared flags + experiments and their current overrides. |

```json
// GET /api/features   (Authorization: Bearer <superuser-jwt>)
{
  "flags": [
    { "name": "dark_mode", "default": false, "description": "",
      "override": "true" }
  ],
  "experiments": [
    { "name": "onboarding_flow",
      "variants": ["control", "streamlined"], "weights": [70, 30],
      "sticky": false, "description": "Onboarding flow A/B test",
      "weight_override": "[90,10]" }
  ]
}
```

`override` / `weight_override` are `null` when no `_kv` row is present (the declared
default is used). To change an override, use the existing
`PUT /api/settings/flag:<name>` / `PUT /api/settings/exp:<name>:weights` verbs.

The embedded admin UI exposes this as the **Feature Flags & Experiments** screen
(`/_/#/features`) — see [framework.md → Admin UI](framework.md#admin-ui).

---

## Feature state (public)

The **read-only** public projection of resolved feature flags + experiments. Unlike the
superuser `/api/settings` surface above, this endpoint is **unauthenticated** and exposes
**only resolved values** — never the raw `_kv` keys, timestamps, declared defaults, or any
admin verb.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/state?subject=<id>` | Resolve every declared flag + experiment for `subject`. |

`subject` is the caller-supplied bucketing key (a user id, session id, or any stable
string) used for deterministic experiment assignment; omit it (or pass empty) to get the
stable "anonymous" assignment. The response is exactly:

```json
// GET /api/state?subject=user-42   (no Authorization header)
{
  "flags": { "checkout_enabled": true, "new_dashboard": false },
  "experiments": { "checkout_layout": "compact" }
}
```

`flags` maps each **declared** flag name to its resolved boolean (override else declared
default); `experiments` maps each declared experiment name to its resolved variant. Apps
that declare no flags/experiments get `{ "flags": {}, "experiments": {} }`.

A `.sticky` experiment returns its **persisted** assignment here (the same value
`App.experiment` resolves), so the public projection survives later weight changes. The
lookup is **reader-first** — a repeat call for a known `subject` is served from a pooled
reader, and only a subject's *first-ever* resolve briefly takes the writer to persist it —
so this unauthenticated, caller-supplied-`subject` endpoint never storms the writer lock.

**Mount + disable.** The route auto-mounts at `/api/state`. Configure it with the
`.features` knob: `.features = .{ .public_route = "/state" }` remaps it, and
`.features = .{ .public_route = .disabled }` turns it off (then it `404`s). The typed
TypeScript SDK exposes this as `zb.flags.resolveAll(subject)` — see
[TypeScript SDK → Typed feature state](typescript-sdk.md#typed-feature-state--zbflags).

---

## Analytics

Read the built-in product-analytics data: the raw event feed and the declarative rollups
(see [framework → Product analytics](framework.md#product-analytics-analytics--ctxtrack)).
Events are emitted server-side with `ctx.track(name, payload)`; the rollups aggregate them on
a schedule into per-rollup summary tables. Present only when `.analytics` is configured —
without it these routes are absent from your binary (not merely 404 at runtime).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/analytics/events?name=&actor=&since=&limit=&cursor=` | The raw activity feed (newest first). |
| GET | `/api/analytics/rollups/:name?from=&to=` | A rollup's summary rows. |

Both endpoints are **authenticated and fail closed**. A **superuser** sees all data; a **member**
sees only their **active account's** data (resolved from a verified `_memberships` row — send
`X-Account-Id` or activate the `zb_account` cookie). With tenancy **disabled**, the feed is scoped
to the caller's **own** events and a (global) rollup is **superuser-only** (`403`). A member can
never read another account's events or rollups; an anonymous request gets `401` (the rollups handler
authenticates **before** the rollup-name lookup, so 401-vs-404 never leaks which rollup names exist).

Visibility within an account is **account-level, not role-level**: any active member of an account —
whatever their role — reads the whole account's event feed (including other members' events and
payloads) and all of its rollup buckets. The trust boundary is the tenant, not the role.

**Events.** Filters: `name` (exact event name), `actor` (exact principal id), `since` (an ISO-8601
lower bound on `occurred_at`), `limit` (default 50, max 200). The `actor` / `account` / `occurred_at`
fields are stamped server-side at capture time and cannot be forged by a client.

Events paginate with the house cursor vocabulary: pass the previous page's `nextCursor` back as
`?cursor=` to fetch the next page. `nextCursor`/`hasNext` are always present, even on the last page
(`nextCursor: null`, `hasNext: false`). A malformed `cursor` is `400 "Invalid cursor."`.

```json
// GET /api/analytics/events?name=user.signup&limit=2   (Authorization + X-Account-Id)
{
  "items": [
    { "id": "…", "created": "2026-06-29T12:00:05Z", "name": "user.signup",
      "payload": { "plan": "pro" }, "actor_collection": "users", "actor": "u_123",
      "account": "acc_abc", "occurred_at": "2026-06-29T12:00:05Z" }
  ],
  "nextCursor": "2026-06-29T12:00:05Z|e_122",
  "hasNext": true
}
```

**Rollups.** `:name` must be a **declared** rollup (else `404`, no table-name oracle). Filters:
`from` / `to` bound the `bucket` value. Each row is `{ bucket, account, actor, value, computed_at }`;
columns absent from the rollup's `group_by` are the empty string. The summary table is created on the
first scheduled run — until then the endpoint returns `{ "items": [] }`.

```json
// GET /api/analytics/rollups/signups_daily   (Authorization + X-Account-Id)
{
  "items": [
    { "bucket": "2026-06-29", "account": "acc_abc", "actor": "", "value": 5,
      "computed_at": "2026-06-29T13:00:00Z" }
  ]
}
```

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

### Range and conditional requests

File downloads support HTTP range and conditional requests (0.10.0):

- `Accept-Ranges: bytes` on every 200/206. A single `Range: bytes=a-b`, `bytes=a-`,
  or `bytes=-n` answers `206 Partial Content` with `Content-Range`; a syntactically
  multi-range request is served as a full `200` (RFC-permitted). An unsatisfiable
  range answers `416` with `Content-Range: bytes */<size>`.
- Every response carries a strong `ETag` derived from the stored file's identity
  (stored names are content-immutable — an update mints a new name), so
  `If-None-Match` revalidation answers `304`. `If-Range` requires an exact strong
  match, otherwise the range is ignored.
- `HEAD` mirrors `GET` (status, headers, `Content-Length`) with no body.
- `?download` and `?token=` compose with `Range` unchanged.
- **File tokens vs. seeking:** `ZIGBASE_FILE_TOKEN_TTL` defaults to 120 s; a video
  player seeking via `?token=` URLs gets 404s once the token expires mid-playback.
  Use cookie/bearer auth for long media, or re-mint tokens per seek.

---

## Static files

When static serving is configured (see [framework.md](framework.md) for the
comptime modes and the `--serve-static <dir>` flag), GET and HEAD requests that
match none of the admin UI (`/_/`), the built-in API, or the app's custom routes
are served from the static root. The `/api` namespace (the bare `/api` path and
everything under `/api/`) is never served statically — an unmatched API path
keeps the JSON 404 envelope, while a static miss returns a plain-text 404
(`text/plain`) — unless an [SPA fallback](#spa-fallback) applies.

Static files are served **without authentication** — collection access rules do
not apply to the static root, so never place secrets there. For access-controlled
file delivery, use [file storage](#files) instead.

- `/` and directory paths resolve to that directory's `index.html`.
- **Range requests:** a single `Range: bytes=a-b`, `bytes=a-` (open-ended, e.g.
  video seeking), or `bytes=-n` (suffix) answers `206 Partial Content` with
  `Content-Range`; a range past the end of the file answers `416 Range Not
  Satisfiable` with `Content-Range: bytes */<size>`. A syntactically malformed or
  multi-range `Range` header is ignored (plain `200`). This applies to both **dir**
  mode (the request is normalized into the canonical closed form so facil.io's own
  transport assembles the `206`) and **embedded** mode (a single-range `206` sliced
  out of the compiled-in asset bytes).
- **Caching:** every response — embedded or dir — now emits a `Cache-Control`
  header. The value defaults to `max-age=3600` and is tunable process-wide via the
  `--static-cache-control <value>` flag, the `ZIGBASE_STATIC_CACHE_CONTROL` env var,
  or the comptime `App(.{ .static_cache_control = "…" })` key (flag > env >
  comptime; unset keeps the stock default). See
  [framework.md → Static files](framework.md) for the full precedence and scope
  notes. In **embedded** mode each asset also has a precomputed CRC32 content
  `ETag`; a request with a matching `If-None-Match` gets `304 Not Modified` from
  zigbase itself. In **dir** mode, `ETag`/`Last-Modified`/`If-None-Match`/`If-Range`
  handling is delegated to facil.io's `sendFile`, which uses its own exact-match
  `ETag` semantics (an unquoted base64 size^mtime tag) rather than RFC 7232
  list/weak comparison. A ranged request with a *matching* `If-Range` resumes
  (`206`); zigbase neutralizes an inverted branch in the vendored facil.io that
  otherwise deleted the `Range` on a match and forced a full `200` (RFC 9110
  §13.1.5). A *stale/mismatched* `If-Range` in dir mode still returns `206` rather
  than the RFC-mandated `200` — facil.io's dir-mode `ETag` is process-local and
  cannot be recomputed to distinguish the two cases. Owned serving (record-file
  downloads and **embedded** static) is fully RFC-correct: a mismatched `If-Range`
  there ignores the `Range` and returns `200`.
- **`.gz` sidecar negotiation (dir mode):** if the request sends `Accept-Encoding`
  containing `gzip` and a `<file>.gz` sibling exists next to the matched `<file>`,
  the sidecar's bytes are served instead with `Content-Encoding: gzip` (facil.io's
  existing behavior, unchanged) and — new — `Vary: Accept-Encoding`, so a shared
  cache in front of dir-mode static serving doesn't conflate the plain and
  gzip-encoded responses for the same URL.
- Every response includes `X-Content-Type-Options: nosniff`; content types are
  derived from the file extension (html, css, js, mjs, json, map, svg, png, jpg/jpeg,
  gif, webp, avif, ico, woff/woff2, ttf, wasm, txt, xml, pdf, mp4, webm; unknown →
  `application/octet-stream`).
- Paths containing `..`, backslashes, or NUL bytes are rejected (404). There are no
  directory listings.
- **SPA fallback:** a directory containing a file named `.spa` is an SPA root —
  GET/HEAD misses at or below it serve that directory's `index.html` with 200
  (real files always win; the `.spa` file itself is never served). The fallback
  shell response is always `Cache-Control: no-cache` with a revalidation `ETag`
  (a redeploy can't strand a deep link on a stale cached shell), regardless of the
  Cache-Control knob above; a **direct** hit on that same `index.html` file (not via
  the fallback) keeps the knob's normal value. In **embedded** mode the marker set
  is derived once at startup (the manifest can't change at runtime); in **dir** mode
  it's resolved **live** against the filesystem on every miss, so adding/removing a
  marker needs no restart (startup only fails fast if a `.spa` has no
  `index.html`). Custom builds can also declare comptime `static_routes` rewrites,
  consulted before the marker. See
  [framework.md → Static files](framework.md) for details. <a id="spa-fallback"></a>

---

## Realtime (WebSocket + SSE)

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

### SSE transport

Everything above — the frame grammar (`connect`/`auth`/`ack`/`event`/`signal`/`message`/`error`),
per-record delivery authorization, subscription rules, the Origin policy, and the shared
10,000-connection cap — applies identically over Server-Sent Events. SSE is a second pipe under
the same hub, not a second protocol.

**Connect (downlink).** `GET /api/realtime/sse` with `Accept: text/event-stream` — the header
must be EXACT for non-browser clients (the server dispatches SSE upgrades on an exact match;
`EventSource` always sends it). Every hub frame arrives as one `data: <json>` event (default
event name → `EventSource.onmessage`; no `id:`/`event:`/`retry:` fields). The first event is the
standard connect frame: `{"type":"connect","clientId":"<32 chars>"}`.

**Verbs (uplink).** `POST /api/realtime/sse/:clientId` with the same JSON verb body the WS
socket sends (`auth` / `subscribe` / `unsubscribe`). The response body is the exact frame the
WS socket would have written — the frame body is the protocol; the HTTP status is just framing:

| Condition | Response |
|---|---|
| unknown, expired, or just-closed `clientId` | `404` standard error envelope — **non-oracle**: byte-identical for never-existed vs. just-closed |
| body fails to parse as a verb | `400`, body `{"type":"error","message":"bad message"}` |
| verb processed | `200`, body = `{"type":"auth","status":"ok"\|"error"}`, `{"type":"ack",…}`, or `{"type":"error","message":…}` |

Error-frame outcomes return `200` deliberately — WS keeps the connection open and replies a
frame; clients share one frame-handling path across transports.

**Auth.** Identical to WS: the ONLY identity path is the `auth` verb with the token in the POST
body — a bearer token never appears in any URL, and the auth cookie is intentionally NOT used.
The `clientId` is a crypto-random capability delivered only on the Origin-gated stream; no CORS
headers are emitted. Deployment note: unlike the WS handle, the uplink `clientId` rides the URL
*path* (`POST /api/realtime/sse/:clientId`), so it can land in HTTP access/proxy logs — the
mitigation is that it's a 165-bit CSPRNG capability that dies with the connection, and a leaked
id only permits griefing that connection (unsubscribe/auth-clear), never data exfiltration
(deliveries flow to the victim's held-open stream socket, not the uplink POST response).

**Heartbeats.** The server writes the SSE comment `: ping` on every protocol-timeout tick
(invisible to `EventSource`). Default interval: the listener's 40s timeout; override with
`--sse-heartbeat-seconds N` / `ZIGBASE_SSE_HEARTBEAT_SECONDS` (1..=255; validated at startup).

**Limits.** WS and SSE share ONE global connection cap (10,000; upgrades past it → `503`) and
the 256-subscriptions-per-connection cap. Browser note: HTTP/1.1 `EventSource` is limited to
~6 streams per origin by browsers.

**Slow-consumer backpressure.** A client that reads slowly or stalls without closing would
otherwise let the server buffer its outbound frames without bound (an OOM/DoS risk). Each
realtime connection therefore has a per-connection **outbound high-water-mark**: once its queued
outbound frames exceed the bound, the server **disconnects** that consumer (the standard pub/sub
choice — dropping individual frames would silently corrupt the client's view; a disconnect forces
a clean reconnect + re-fetch). Applies to both WS and SSE. Default `1024` frames; tune with
`--realtime-outbound-hwm N` / `ZIGBASE_REALTIME_OUTBOUND_HWM` (`0` disables the bound).

**No-SDK example.**

```js
const es = new EventSource('/api/realtime/sse');
let clientId;
es.onmessage = async (e) => {
  const m = JSON.parse(e.data);
  if (m.type === 'connect') {
    clientId = m.clientId;
    await fetch('/api/realtime/sse/' + clientId, {
      method: 'POST',
      body: JSON.stringify({ action: 'subscribe', topic: 'posts' }),
    });
  } else if (m.type === 'event') {
    console.log(m.action, m.record);
  }
};
```

---

## Health

| Method | Path | Description |
|---|---|---|
| GET | `/api/health` | Liveness probe + the active database backend. No auth. |

```json
{ "status": "ok", "backend": "sqlite" }
```

`backend` is `"sqlite"` or `"postgres"` — the *kind* of database the server is running on. It is
deliberately read-only and carries **no** secrets: the connection string, host, and credentials are
never exposed. The admin UI reads this to show a small backend badge in the sidebar.

---

## See also

- [tutorial.md](tutorial.md) — build an app on ZigBase, end to end.
- [fields.md](fields.md) — the complete field-type & options catalog.
- [recipes.md](recipes.md) — provisioning, access rules, hooks, custom routes, jobs.
- [framework.md](framework.md) — embedding ZigBase as a Zig library.
