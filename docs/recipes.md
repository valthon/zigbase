# Recipes: building a real app on ZigBase

> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/recipes> — the site is the canonical reading experience.

Task-oriented, copy-pasteable recipes for going from an empty database to a working
backend. The running example is **"Airbnb for golf simulators"**: hosts list golf
simulators, guests book time slots.

These recipes assume a ZigBase server running on `http://127.0.0.1:8090` and a
superuser already created:

```sh
./zig-out/bin/zigbase superuser create --email admin@example.com --password "a-strong-password" --data-dir ./zb_data
# --insecure-cookies: local dev is over plain HTTP, and auth cookies are Secure by default.
# A strong JWT secret is auto-generated and persisted under the data dir on first run.
./zig-out/bin/zigbase serve --insecure-cookies --data-dir ./zb_data
```

Reference companions: field shapes are in [fields.md](fields.md); endpoint envelopes
and rule semantics are in [api.md](api.md); the framework hook/route/job APIs are in
[framework.md](framework.md).

---

## Recipe: ship your frontend inside the binary

Build any static site into an output folder such as `dist/`, then embed it at
compile time using the `embedStaticDir` helper exported from zigbase's `build.zig`.
Zigapagos is ZigBase's preferred companion, but output from Astro, Vite, Hugo,
Eleventy, or plain HTML works equally well. The built binary serves the frontend
from memory — no directory needed at runtime.

```zig
// build.zig
const std = @import("std");
const zigbase_build = @import("zigbase");

pub fn build(b: *std.Build) void {
    // ... standard setup ...

    // Generate a manifest module: one @embedFile per asset, with precomputed CRC32 ETags.
    // build fails with a clear error if frontend/dist is missing — run `npm run build` first.
    const assets = zigbase_build.embedStaticDir(b, "frontend/dist");
    exe_mod.addImport("static_assets", assets);
}
```

```zig
// main.zig
const static_assets = @import("static_assets");

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .static_files = .{ .embedded = &static_assets.files },
        // ... other config ...
    }).runCli(init);
}
```

GET and HEAD requests that miss `/_/`, the built-in API, and custom routes are
served from the embedded manifest. `/` and directory paths resolve to `index.html`.
Each asset's response carries a precomputed CRC32 `ETag`; a matching
`If-None-Match` gets `304 Not Modified`. Static misses return a plain-text 404;
`/api/*` misses keep the JSON envelope.

The three static-files modes — and their trade-offs:

| Mode | When to use | `--serve-static` flag |
|---|---|---|
| *(field absent — default)* | Flexible deploy: pass `--serve-static <dir>` at runtime. | enabled |
| `.static_files = .disabled` | No static serving, flag rejected. | rejected |
| `.static_files = .{ .dir = "frontend/dist" }` | Dir is always at that relative path (dev servers, Docker images with a known layout). | rejected |
| `.static_files = .{ .embedded = &@import("static_assets").files }` | True single-binary deploy — assets inside the executable. | rejected |

See [examples/blog/](../examples/blog/) (runtime flag), [examples/golfsim/](../examples/golfsim/)
(hardcoded dir), and [examples/plugins/](../examples/plugins/) (embedded) for working
Zigapagos + Preact frontends, one per mode.

---

## Recipe: provisioning your schema

There is no "import a schema file" endpoint — over the REST API you **provision by
calling `POST /api/collections`** for each collection, as a superuser. Because
relation fields reference their target by **id** (not name — see
[fields.md → relation gotcha](fields.md#critical-targetcollectionid-is-an-id-not-a-name)),
you must create collections **in dependency order** and **capture each `id`** from
the response to feed the next collection's `targetCollectionId`.

> **Note:** the golfsim example now self-provisions its schema at startup via
> `App(.{ .collections = .{ ... } })` — the script below is the REST-API
> alternative, useful when you are running the stock binary or want fine-grained
> control over ids and ordering.

> **Embedding ZigBase?** You can skip the REST dance entirely and **declare your
> schema in Zig at comptime** via `App(.{ .collections = .{ ... } })`, provisioned
> at startup with additive auto-migration — relations reference their target **by
> name** (no id-capturing). See
> [framework.md → Define your schema in code](framework.md#8-define-your-schema-in-code-collections--migrations).

The script below logs in as the superuser, then creates `users` (auth) →
`simulators` → `listings` → `bookings`, wiring relations by captured id, and seeds a
demo simulator. It uses `curl` + `jq`.

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE="http://127.0.0.1:8090"
SU_EMAIL="admin@example.com"
SU_PASS="a-strong-password"

# 1) Log in as the superuser. Superusers are the built-in `_superusers` auth
#    collection, so they authenticate through the normal auth endpoint.
TOKEN=$(curl -s -X POST "$BASE/api/collections/_superusers/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d "{\"identity\":\"$SU_EMAIL\",\"password\":\"$SU_PASS\"}" | jq -r .token)
AUTH=(-H "Authorization: Bearer $TOKEN")

# Helper: create a collection from a JSON body, echo the new collection id.
create_collection() { # $1 = JSON body
  curl -s -X POST "$BASE/api/collections" "${AUTH[@]}" \
    -H 'Content-Type: application/json' -d "$1" | jq -r .id
}

# 2) users — an AUTH collection. Public create rule ("@public") enables open signup.
#    (Safe-by-default: an empty "" rule is LOCKED, not public — use "@public" to open.)
USERS_ID=$(create_collection '{
  "name": "users",
  "type": "auth",
  "fields": [
    { "id": "f_name", "name": "name", "type": "text", "options": { "max": 100 } }
  ],
  "listRule": "@public",
  "viewRule": "@public",
  "createRule": "@public",
  "updateRule": "@request.auth.id = id",
  "deleteRule": "@request.auth.id = id"
}')
echo "users id = $USERS_ID"

# 3) simulators — owned by a user. Its `owner` relation targets users by ID.
SIMS_ID=$(create_collection "{
  \"name\": \"simulators\",
  \"type\": \"base\",
  \"fields\": [
    { \"id\": \"f_label\", \"name\": \"label\", \"type\": \"text\", \"required\": true, \"options\": { \"min\": 1, \"max\": 120 } },
    { \"id\": \"f_owner\", \"name\": \"owner\", \"type\": \"relation\", \"required\": true,
      \"options\": { \"targetCollectionId\": \"$USERS_ID\", \"cascadeDelete\": true, \"maxSelect\": 1 } }
  ],
  \"listRule\": \"@public\",
  \"viewRule\": \"@public\",
  \"createRule\": \"@request.auth.id != \\\"\\\"\",
  \"updateRule\": \"@request.auth.id = owner\",
  \"deleteRule\": \"@request.auth.id = owner\"
}")
echo "simulators id = $SIMS_ID"

# 4) listings — a bookable offer for a simulator. References simulators by ID.
LISTINGS_ID=$(create_collection "{
  \"name\": \"listings\",
  \"type\": \"base\",
  \"fields\": [
    { \"id\": \"f_title\", \"name\": \"title\", \"type\": \"text\", \"required\": true, \"options\": { \"min\": 1, \"max\": 140 } },
    { \"id\": \"f_price\", \"name\": \"price_per_hour\", \"type\": \"number\", \"required\": true,
      \"options\": { \"mode\": \"fixed\", \"scale\": 2, \"min\": 0 } },
    { \"id\": \"f_status\", \"name\": \"status\", \"type\": \"select\", \"required\": true,
      \"options\": { \"values\": [\"draft\", \"published\", \"archived\"], \"maxSelect\": 1 } },
    { \"id\": \"f_sim\", \"name\": \"simulator\", \"type\": \"relation\", \"required\": true,
      \"options\": { \"targetCollectionId\": \"$SIMS_ID\", \"cascadeDelete\": true, \"maxSelect\": 1 } },
    { \"id\": \"f_photos\", \"name\": \"photos\", \"type\": \"file\",
      \"options\": { \"maxSelect\": 6, \"maxSize\": 5242880, \"mimeTypes\": [\"image/png\", \"image/jpeg\", \"image/webp\"] } }
  ],
  \"listRule\": \"status = \\\"published\\\"\",
  \"viewRule\": \"status = \\\"published\\\" || @request.auth.id = simulator.owner\",
  \"createRule\": \"@request.auth.id != \\\"\\\"\",
  \"updateRule\": \"@request.auth.id = simulator.owner\",
  \"deleteRule\": \"@request.auth.id = simulator.owner\"
}")
echo "listings id = $LISTINGS_ID"

# 5) bookings — a guest books a listing. References both listings and users by ID.
BOOKINGS_ID=$(create_collection "{
  \"name\": \"bookings\",
  \"type\": \"base\",
  \"fields\": [
    { \"id\": \"f_listing\", \"name\": \"listing\", \"type\": \"relation\", \"required\": true,
      \"options\": { \"targetCollectionId\": \"$LISTINGS_ID\", \"cascadeDelete\": true, \"maxSelect\": 1 } },
    { \"id\": \"f_guest\", \"name\": \"guest\", \"type\": \"relation\", \"required\": true,
      \"options\": { \"targetCollectionId\": \"$USERS_ID\", \"cascadeDelete\": true, \"maxSelect\": 1 } },
    { \"id\": \"f_start\", \"name\": \"starts_at\", \"type\": \"date\", \"required\": true, \"options\": {} },
    { \"id\": \"f_end\", \"name\": \"ends_at\", \"type\": \"date\", \"required\": true, \"options\": {} },
    { \"id\": \"f_status\", \"name\": \"status\", \"type\": \"select\", \"required\": true,
      \"options\": { \"values\": [\"pending\", \"confirmed\", \"cancelled\"], \"maxSelect\": 1 } }
  ],
  \"listRule\": \"@request.auth.id = guest || @request.auth.id = listing.simulator.owner\",
  \"viewRule\": \"@request.auth.id = guest || @request.auth.id = listing.simulator.owner\",
  \"createRule\": \"@request.auth.id != \\\"\\\"\",
  \"updateRule\": \"@request.auth.id = listing.simulator.owner\",
  \"deleteRule\": \"@request.auth.id = guest\"
}")
echo "bookings id = $BOOKINGS_ID"

# 6) Seed demo data: register a host, log in, create a simulator they own.
curl -s -X POST "$BASE/api/collections/users/records" \
  -H 'Content-Type: application/json' \
  -d '{"email":"host@example.com","password":"hostpassword","name":"Demo Host"}' > /dev/null

HOST_LOGIN=$(curl -s -X POST "$BASE/api/collections/users/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d '{"identity":"host@example.com","password":"hostpassword"}')
HOST_TOKEN=$(echo "$HOST_LOGIN" | jq -r .token)
HOST_ID=$(echo "$HOST_LOGIN" | jq -r .record.id)

curl -s -X POST "$BASE/api/collections/simulators/records" \
  -H "Authorization: Bearer $HOST_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"label\":\"Bay 1 — TrackMan\",\"owner\":\"$HOST_ID\"}" > /dev/null

echo "Provisioning complete."
```

Notes:

- **Order matters.** `users` and `simulators` must exist (and their ids captured)
  before `listings`; `listings` and `users` before `bookings`.
- **Capture the id, not the name.** Every relation's `targetCollectionId` above is a
  shell variable holding the **id** returned by the prior create call.
- Collection management is **superuser-only**; record create/seed calls run as the
  relevant user (or anonymously where the create rule is public).

---

## Recipe: seed records offline with `zigbase import`

The HTTP loop above needs a running server and posts one record at a time. For bulk
seeding or migrating a dataset, `zigbase import` loads **NDJSON** (one JSON object per
line) **offline — no server — through the record engine**, so validation, defaults, the
`.encrypted` envelope, and auth password hashing all still apply, and it **preserves each
row's `id`** so relations stay intact:

```sh
# users.ndjson — one auth record per line (password is hashed on import):
#   {"id":"host000000001","email":"host@example.com","password":"hostpassword","name":"Demo Host"}
# simulators.ndjson — references the preserved user id as its owner:
#   {"id":"sim0000000001","label":"Bay 1 — TrackMan","owner":"host000000001"}

# Seed the referenced rows (owners) FIRST, then the rows that point at them by id:
zigbase import --collection users      --data-dir ./zb_data users.ndjson
zigbase import --collection simulators --data-dir ./zb_data simulators.ndjson

# Idempotent re-seed: match on a unique field and UPDATE in place instead of duplicating.
zigbase import --collection users --upsert-key email --data-dir ./zb_data users.ndjson

# Pipe from stdin with `-`:
cat dump.ndjson | zigbase import --collection simulators --data-dir ./zb_data -
```

A bad row (malformed JSON, validation failure, duplicate id) **fails fast**, rolls back the
in-flight batch, and names the offending line; batches committed before it persist (fix the
file and re-run, ideally with `--upsert-key`). Id preservation is **import-only** — the HTTP
create path always generates the id and never honors a client-supplied one. See
[docs/framework.md](docs/framework.md) → "Offline bulk import" and `examples/golfsim/seed/`.

---

## Recipe: user registration (signup)

ZigBase has no separate "register" endpoint. **Signup is a normal record create on
an auth collection:**

```sh
curl -s -X POST "$BASE/api/collections/users/records" \
  -H 'Content-Type: application/json' \
  -d '{"email":"guest@example.com","password":"guestpassword","name":"Guest One"}'
```

What the server does on this create (auth collections only):

- **hashes** `password` with argon2id and stores it as `passwordHash`;
- **strips** the plaintext `password` from the stored/returned record;
- mints a `tokenKey` (the per-record token-invalidation secret);
- **forces `verified` to `false`** — a client-supplied `verified: true` is ignored;
- `passwordHash` and `tokenKey` are **hidden** and never appear in the response.

Requirements:

- The `users` collection needs a **public create rule** (`"createRule": "@public"`) for
  open signup. Any non-public rule denies anonymous signup with `403` — including a blank
  rule (`""` or `null`), which is now **Locked** (safe-by-default), not public.
- `password` must be at least **`minPasswordLength`** characters (default **8**;
  configurable in the collection's `options.auth.minPasswordLength`). A missing or
  too-short password is a **`400`** ("A password of the required length is
  required.").

Then **log in** to obtain a token (and the `zb_auth`/`zb_csrf` cookies):

```sh
curl -s -X POST "$BASE/api/collections/users/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d '{"identity":"guest@example.com","password":"guestpassword"}'
# -> { "token": "<jwt>", "record": { "id": "...", "email": "guest@example.com", ... } }
```

`identity` is matched against the collection's `identityFields` (default `["email"]`).
See [api.md → auth-with-password](api.md#auth-with-password). Email **verification**
is optional; the token is emailed when SMTP is configured, or logged in dev otherwise —
see [api.md → Verification & password reset](api.md#verification--password-reset--email-delivery).

---

## Recipe: owner-scoped access rules

A rule is one of: **Locked** (`null` or `""` — superuser only; the safe default),
**Public** (`"@public"` — anyone; the only allow-all value, logged at startup), or a
**filter expression** evaluated per request (full grammar in
[api.md → Filter grammar](api.md#filter-grammar)). Relevant pieces:

- `@request.auth.id` — the authenticated user's record id (`""` when anonymous).
- A bare field name (e.g. `owner`) refers to the record being checked.
- **Relation traversal with `.` is supported in rules** (not just flat fields):
  `simulator.owner` follows the single-value `simulator` relation to the simulators
  row and reads its `owner`. You can chain: `listing.simulator.owner`. (Traversal
  works through **single-value** relations; traversing a multi-value relation —
  `maxSelect > 1` — is not supported and the query is rejected.)
- **Set membership with `in`:** `status in ("draft", "published")` matches any value in
  a literal list, and `account in @request.account.ids` matches the caller's accounts.
- **Account-scope macros** (multi-tenancy foundation): `@request.account.id` /
  `@request.account.role` (single values) and `@request.account.ids` (the list macro for
  `in`). They resolve to `""`/empty until the tenancy resolver ships, so they are
  fail-closed and don't change existing rules. See
  [api.md → Filter grammar](api.md#filter-grammar).

### Edit only your own records

```jsonc
"updateRule": "@request.auth.id = owner",
"deleteRule": "@request.auth.id = owner"
```

### Public read OR owner read

Anyone may read published rows; the owner may additionally read their own
(e.g. drafts):

```jsonc
"listRule": "status = \"published\"",
"viewRule": "status = \"published\" || @request.auth.id = simulator.owner"
```

### Relation-traversal rule (visible to host *and* guest)

A booking should be visible to the guest who made it **and** to the host who owns the
booked listing's simulator:

```jsonc
"viewRule": "@request.auth.id = guest || @request.auth.id = listing.simulator.owner"
```

Here `listing.simulator.owner` traverses `bookings.listing` →
`listings.simulator` → `simulators.owner`.

### How does the `owner` field get set on create?

A rule like `updateRule: "@request.auth.id = owner"` only protects *existing* rows.
You still must ensure the `owner` field is correctly populated **at create time**.
Two patterns:

1. **Server sets it (recommended).** A `beforeCreate` hook overwrites `owner` from
   the authenticated identity, so the client can't spoof it:

   ```zig
   fn setOwner(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
       _ = ctx;
       if (ev.record.* != .object) return;
       const uid = ev.rctx.resolveMacro("@request.auth.id") orelse "";
       if (uid.len == 0) return error.Unauthenticated; // reject anonymous creates -> 400
       try ev.record.object.put(ev.arena.a, "owner", .{ .string = uid }); // ev.arena.a
   }
   ```
   Register it as `.hooks = .{ .simulators = .{ .beforeCreate = setOwner } }`. See
   [framework.md → Record hooks](framework.md#4-record-hooks-hooks).

2. **Client sends it, the create rule enforces it.** Require the submitted `owner`
   to equal the caller, via a `@request.data.*` create rule:

   ```jsonc
   "createRule": "@request.data.owner = @request.auth.id"
   ```
   The client must include `"owner": "<their id>"` in the body; a mismatched or
   missing value fails the rule with `403`.

Pattern 1 is sturdier (the client cannot get it wrong); pattern 2 needs no Zig code.

---

## Recipe: global roles with a select field (no framework RBAC)

ZigBase deliberately has no global role ladder — the rule language composes one from
existing pieces. Put a `role` select on the auth collection, reference it from rules, and
guard escalation with a one-line hook:

```zig
.users = .{
    .type = .auth,
    .fields = .{
        .{ .name = "role", .type = .select, .values = .{ "member", "editor", "admin" } },
    },
    ...
},
.posts = .{
    // Editors and admins may update any post:
    .rules = .{ .update = "@request.auth.role = \"editor\" || @request.auth.role = \"admin\"", ... },
},
```

```zig
// Self-escalation guard: only superusers may change `role`.
fn guardRole(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    _ = ctx;
    if (ev.phase != .before_update) return;
    if (ev.ctx.is_superuser) return;
    if (ev.record.* == .object and ev.record.object.get("role") != null)
        return error.Forbidden;
}
```

Wire `guardRole` as a `beforeUpdate` hook on `users` (or express the same thing as a
field-guarding `updateRule`). For **per-account** roles with an ordered ladder
(`viewer < editor < admin < owner`), use the built-in tenancy system instead —
`_memberships.role`, `@request.account.role`, and `.abilities` `.min_role` already ship
ordered comparisons (see docs/tenancy.md and docs/abilities.md).

---

## Recipe: a computed-field / validation `beforeCreate` hook

A `beforeCreate` hook runs **after** access rules pass and **before** the write. It
may mutate `ev.record` and may **return an error to reject** the write (the request
fails with `400`). This example, on `bookings`, (a) rejects a booking that overlaps
an existing confirmed booking for the same listing, and (b) computes a derived
`duration_minutes` field.

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// before_create on "bookings": reject overlaps with a confirmed booking and
/// compute a derived duration field. Allocations that land in ev.record use ev.arena.a.
fn validateBooking(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return; // framework guards non-objects already

    const listing = strField(ev.record, "listing") orelse return error.MissingListing;
    const starts = strField(ev.record, "starts_at") orelse return error.MissingStart;
    const ends = strField(ev.record, "ends_at") orelse return error.MissingEnd;

    // 1) Conflict check: any CONFIRMED booking for this listing that overlaps?
    //    ctx.records().list runs a curated query on the request's connection.
    const filter = try std.fmt.allocPrint(ev.arena.a,
        "listing = \"{s}\" && status = \"confirmed\" && starts_at < \"{s}\" && ends_at > \"{s}\"",
        .{ listing, ends, starts },
    );
    const conflicts = try ctx.records().list("bookings", .{ .filter = filter, .perPage = 1 });
    if ((conflicts.totalItems orelse 0) > 0) return error.SlotUnavailable; // -> 400, rejects the create

    // 2) Compute a derived numeric field from the two timestamps (illustrative).
    const minutes = durationMinutes(starts, ends);
    try ev.record.object.put(ev.arena.a, "duration_minutes", .{ .integer = minutes });
}

fn strField(rec: *std.json.Value, name: []const u8) ?[]const u8 {
    const v = rec.object.get(name) orelse return null;
    return switch (v) { .string => |s| s, else => null };
}

fn durationMinutes(starts: []const u8, ends: []const u8) i64 {
    _ = starts; _ = ends;
    return 60; // parse your timestamp format here
}
```

Register it:

```zig
.hooks = .{ .bookings = .{ .beforeCreate = validateBooking } },
```

Key points:

- **Use `ev.arena.a`** for anything stored into `ev.record`. `ev.arena` is a typed
  `RequestArena` rather than a bare `std.mem.Allocator`, so a general-purpose
  allocator can't reach an arena-scoped API by accident; `.a` is the request-scoped
  allocator inside it, the one that owns the record's JSON. See
  [framework.md → Always allocate record data with ev.arena.a](framework.md#always-allocate-record-data-with-evarenaa).
- **`ctx.records().list(collection, opts)`** returns a `ListResult` with `totalItems`
  (a `?i64` — `orelse 0` it) and `items`; the `opts` is a `ListOptions` (`.filter`,
  `.sort`, `.page`, `.perPage`). `ctx.records()` also offers `get`, `create`, `update`, `delete`.
- **Returning any error rejects** the create with `400` ("Request rejected by a
  hook.").
- **Atomicity:** a `before*` hook's own `ctx.records()` writes **are** atomic with the
  triggering write — they share its transaction. If the hook returns an error (or the
  access rule denies the write), the whole transaction rolls back, including the hook's
  side-writes (fail closed). See
  [framework.md → DB access from a hook](framework.md#db-access-from-a-hook-ctxrecords).

---

## Recipe: a custom business route with a path param + DB write

A `POST /api/bookings/:id/confirm` route that a host calls to confirm a pending
booking. It reads the `:id` path param, loads the record, mutates it, and returns the
standard JSON envelope (or `404`/`403`).

The untyped handler receives a `*zigbase.Ctx` — the per-request capability object. DB
access is via `ctx.records()` (it manages a pooled connection for you), the
authenticated identity via `ctx.user()`, and the raw request (path params, body) via
`ctx.request.?`.

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// POST /api/bookings/:id/confirm — host confirms a pending booking.
fn confirmBooking(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    const a = ctx.arena.a; // the request arena's allocator
    const id = ctx.request.?.param("id") orelse
        return ctx.jsonError(404, "not_found", "Not found.");

    // DB access via the capability object — ctx.records() manages the pooled
    // connection itself (no manual acquireWriter / Data wiring).
    const records = ctx.records();

    // Load the booking (null = unknown collection OR missing record).
    const booking = (try records.get("bookings", id, .{})) orelse
        return ctx.jsonError(404, "not_found", "Not found.");

    // Authorize: only the host who owns the booked listing's simulator may confirm.
    // (ctx.user() is the authenticated identity; .auth = .authed on the route spec
    // already guarantees a logged-in user.)
    const uid = if (ctx.user()) |u| u.id else "";
    _ = booking; // (look up listing.simulator.owner via records.get and compare to uid)
    if (uid.len == 0)
        return ctx.jsonError(403, "forbidden", "Forbidden.");

    // Mutate: set status = "confirmed".
    var patch: std.json.ObjectMap = .empty;
    try patch.put(a, "status", .{ .string = "confirmed" });
    const updated = (try records.update("bookings", id, .{ .object = patch })) orelse
        return ctx.jsonError(404, "not_found", "Not found.");

    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, updated, .{}) };
}
```

Register it (note `.auth = .authed` so only logged-in users reach the handler; the
default if omitted is `.superuser`):

```zig
.routes = .{
    .{ .method = .POST, .path = "/api/bookings/:id/confirm", .handler = confirmBooking, .auth = .authed },
},
```

Key points:

- **Path params:** `ctx.request.?.param("id")` returns the captured `:id` (or `null`).
- **The auth level is enforced by the framework before your handler runs**; inside,
  use `ctx.user()` for finer authorization (e.g. owner checks).
- **Built-in routes win** over custom routes matching the same method+path, so namespace
  your routes (`/api/bookings/:id/confirm`, not a path that shadows a built-in).
- Return any `zigbase.http.Response`; the body is a JSON string you allocate from
  `ctx.arena.a`.

---

## Recipe: DB access inside a cron / lifecycle job

A job handler is `fn(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void` —
the scheduler hands it a `*Ctx`. `JobEvent` still carries `.app` and `.name`. DB access
is via `ctx.records()` (`get` / `create` / `update` / `delete` / `list`); it lazily checks
out a pooled connection that the framework releases when the job's ctx is torn down. For
raw SQL on a migration-owned table, use the pooled writer directly:

```zig
const w = ctx.app.pool.acquireWriter();
defer ctx.app.pool.releaseWriter();
try w.exec("...");
```

(See [framework.md → DB access from a job](framework.md#db-access-from-a-route-ctxrecords).)

This nightly job cancels stale `pending` bookings (older than now) by listing them
and updating each:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// Nightly: cancel pending bookings whose start time has passed.
fn expireStaleBookings(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void {
    const a = ev.app.allocator;

    // DB access via the capability object — ctx.records() manages the pooled
    // connection; the framework releases it when the job's ctx is torn down.
    const records = ctx.records();

    const now = "2026-06-10 00:00:00"; // compute the current timestamp in your format
    const filter = try std.fmt.allocPrint(a,
        "status = \"pending\" && starts_at < \"{s}\"", .{now});

    const stale = try records.list("bookings", .{ .filter = filter, .perPage = 200 });
    for (stale.items) |item| {
        const id = item.object.get("id").?.string;
        var patch: std.json.ObjectMap = .empty;
        try patch.put(a, "status", .{ .string = "cancelled" });
        _ = try records.update("bookings", id, .{ .object = patch });
    }
    std.log.info("job '{s}': cancelled {d} stale bookings", .{ ev.name, stale.totalItems orelse 0 });
}
```

Register it on a schedule (cron/interval handlers have the
`fn (*Ctx, *JobEvent) anyerror!void` signature):

```zig
.pools = .{ .jobs = 2 },
.cron = .{
    .{ .name = "expire-bookings",
       .schedule = zigbase.schedule.Schedule{ .cron = "0 3 * * *" }, // 03:00 UTC daily
       .handler = expireStaleBookings },
},
```

Key points:

- **`ctx.records()` manages its own connection** — the framework releases any
  connection it checked out when the job's ctx is torn down, so there is no handle to
  `deinit`. If you drop to raw SQL via `ctx.app.pool.acquireWriter()`, always
  `defer ctx.app.pool.releaseWriter()` — the writer is a single shared, mutex-guarded
  connection, and holding it blocks all other writes.
- Job allocations can use `ev.app.allocator` (the long-lived gpa) since there is no
  request arena here; free anything large yourself if the job runs often.
- Scheduling is **single-process, UTC, minute-granularity**; cron fields accept numbers
  and case-insensitive 3-letter `JAN`..`DEC` / `SUN`..`SAT` names.
  See [framework.md → Scheduled jobs](framework.md#7-scheduled-jobs-cron--jobs) and
  its caveats.

---

---

## Recipe: magic-link (passwordless) login

A magic-link flow uses two custom routes: one that mints and emails a single-use
link token, and one that redeems it and issues a real session. Because the request
route always returns `204` regardless of whether the email matches a record, it is
**enumeration-safe** — callers learn nothing about whether the address is registered.

Both routes are registered as `.auth = .public` (no prior session required).

The full `zigbase.auth` surface used here:

- `zigbase.auth.rateLimit(ctx.request.?, scope, ident)` — returns a `429 http.Response` when
  the caller is over the limit, `null` otherwise. Call it first in any public route.
- `zigbase.auth.mintLinkToken(ctx.request.?, conn, collection, record_id, ttl_s, opts)` — mints a
  signed, single-use JWT and returns `LinkToken{ .token }`. `opts.payload` (default `""`)
  binds a small opaque, signed, tamper-proof string into the token (e.g. a post-login
  redirect path), returned by `verifyLinkToken` as `claims.pl` — carry bound state in the
  one token instead of an unsigned `&next=` URL param.
- `zigbase.auth.deliverAuthMail(ctx.app, alloc, to, subject, body)` — sends the link
  via the configured mailer (SMTP or log in dev).
- `zigbase.auth.verifyLinkToken(ctx.request.?, conn, collection, token)` — validates the JWT
  and returns `?jwt.Claims` (`null` → expired / wrong collection / bad signature).
  `claims.id` is the record id.
- `zigbase.auth.consumeLinkToken(conn, claims)` — marks the token consumed; returns
  `error.AlreadyConsumed` on replay.
- `ctx.issueSession(collection, record_id)` — issues a session from a route handler's
  `*Ctx`, sets the auth cookies, fires `onAuth(.custom)`, and returns `Issued{ .token, .cookies }`.
  This is the seam that guarantees **every login fires your `onAuth` handler**,
  including custom flows.

> **Provisioning a new passwordless account.** The request route below resolves an
> *existing* member. To create one on the fly (passwordless sign-up), call
> `ctx.records().create("members", .{ .object = fields })`: on an auth collection `create`
> generates the per-record `tokenKey` (and forces `verified=false`) so the new row works
> with `mintLinkToken` / `issueSession` immediately. `password` is optional, so no
> credential columns need hand-writing.

```zig
const std = @import("std");
const zigbase = @import("zigbase");

// Body shapes for the two endpoints.
const MagicRequestBody = struct { email: []const u8 };
const MagicConfirmBody = struct { token: []const u8 };

/// POST /api/members/magic/request  { "email": "..." }
///
/// Always returns 204 — enumeration-safe. If the email matches a record, mints a
/// single-use link token (TTL 900 s) and mails it. Rate-limited per IP/email.
fn magicRequest(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    const a = ctx.arena.a;

    // 1) Parse the request body first so we can key the rate limit on the parsed
    //    email rather than the raw body (whitespace/key-order variants of the same
    //    email would otherwise dodge the per-identity cap).
    const parsed = std.json.parseFromSlice(MagicRequestBody, a, ctx.request.?.body, .{}) catch
        return .{ .status = 204, .body = "" }; // malformed body → silent 204
    defer parsed.deinit();
    const email = parsed.value.email;

    // 2) Rate-limit on the scope "magic-request" keyed on the parsed email.
    //    rateLimit returns a ready-to-return 429 Response when limited.
    if (try zigbase.auth.rateLimit(ctx.request.?, "magic-request", email)) |resp| return resp;

    // 3) Acquire a DB writer connection for the auth-helper calls that need a raw conn.
    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();

    // 4) Resolve the member record by email (DB lookup after rate-limit gate).
    //    ctx.records().list returns an empty items slice when nothing matches — we treat
    //    both "not found" and "found" paths the same way externally (always 204).
    const results = try ctx.records().list("members", .{
        .filter = try std.fmt.allocPrint(a, "email = \"{s}\"", .{email}),
        .perPage = 1,
    });
    if ((results.totalItems orelse 0) > 0) {
        const record = results.items[0];
        const rid = record.object.get("id").?.string;

        // Mint a single-use link token valid for 15 minutes. Pass `.{}` for no bound
        // payload, or `.{ .payload = "/dashboard" }` to carry a signed post-login target.
        const lt = try zigbase.auth.mintLinkToken(ctx.request.?, w, "members", rid, 900, .{});

        // Build the magic-link URL (adapt the base URL to your deployment).
        const link = try std.fmt.allocPrint(a,
            "https://app.example.com/auth/confirm?token={s}", .{lt.token});
        const body = try std.fmt.allocPrint(a,
            "Click to sign in (link expires in 15 minutes):\n\n{s}", .{link});

        // Deliver the email. Uses SMTP when configured, logs the token in dev.
        try zigbase.auth.deliverAuthMail(
            ctx.app, a, email, "Your sign-in link", body);
    }

    // Always 204 — callers learn nothing about whether the email is registered.
    return .{ .status = 204, .body = "" };
}

/// POST /api/members/magic/confirm  { "token": "..." }
///
/// Verifies the single-use link token, consumes it (replay → 400), issues a
/// real session, and returns 200 with the auth cookies set. onAuth fires here.
fn magicConfirm(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    const a = ctx.arena.a;

    const parsed = std.json.parseFromSlice(MagicConfirmBody, a, ctx.request.?.body, .{}) catch
        return .{ .status = 400, .body = "{\"message\":\"Invalid request body.\"}" };
    defer parsed.deinit();
    const token = parsed.value.token;

    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();

    // Verify: null = expired / wrong collection / bad signature.
    const claims = (try zigbase.auth.verifyLinkToken(ctx.request.?, w, "members", token))
        orelse return .{ .status = 400, .body = "{\"message\":\"Invalid or expired link.\"}" };

    // Consume: error.AlreadyConsumed on replay — the link is single-use.
    zigbase.auth.consumeLinkToken(w, claims) catch |err| switch (err) {
        error.AlreadyConsumed =>
            return .{ .status = 400, .body = "{\"message\":\"Link already used.\"}" },
        else => return err,
    };

    // Issue the session reusing the writer connection already held — do NOT call
    // ctx.issueSession here; it acquires the writer a second time and would deadlock.
    // zigbase.auth.issueSession takes an explicit conn and fires onAuth(.custom).
    const issued = try zigbase.auth.issueSession(ctx.request.?, w, "members", claims.id);
    // We mint with `zigbase.auth.issueSession(ctx.request.?, w, …)`, reusing the writer we already hold — do **not** call `ctx.issueSession(…)` while holding the writer, as it would acquire the single non-reentrant writer a second time and deadlock.
    return .{ .status = 200, .body = "{\"ok\":true}", .cookies = &issued.cookies };
}
```

Register both routes (`.auth = .public` so they're reachable without a prior session):

```zig
zigbase.App(.{
    .routes = .{
        .{ .method = .POST, .path = "/api/members/magic/request",
           .handler = magicRequest, .auth = .public },
        .{ .method = .POST, .path = "/api/members/magic/confirm",
           .handler = magicConfirm, .auth = .public },
    },
    // ... hooks, cron, etc.
}).runCli(init);
```

Key behaviours to note:

- **Enumeration-safe.** The request route always returns `204` — a missing email, a
  malformed body, and a found-and-mailed record are all indistinguishable to the caller.
- **Single-use link.** Once a token is consumed, any subsequent `confirm` with the same
  token receives `400 "Link already used."`. The link also carries a TTL (900 s above) —
  an expired token returns `400 "Invalid or expired link."` before `consumeLinkToken` is
  reached.
- **`onAuth` fires on confirm.** `zigbase.auth.issueSession` routes through the same seam as
  password and OAuth2 logins, so your `onAuth` handler (if registered) is called on
  every magic-link sign-in. There is no way to mint a session via this path — or any
  custom path — that bypasses it. See [framework.md → Tier 3: escape hatch for exotic flows](framework.md#tier-3-escape-hatch-for-exotic-flows).
- **Rate limiting.** The request route calls `zigbase.auth.rateLimit` keyed on the
  parsed email (not the raw body). The built-in scope key `"magic-request"` is app-defined;
  use a descriptive scope per endpoint. Adjust the window and cap via the standard
  `ZIGBASE_RATE_LIMIT_MAX` / `ZIGBASE_RATE_LIMIT_WINDOW` env vars.

---

## Recipe: enable magic-link + OTP via config

No route code needed — enable methods in your collection declaration. If you don't
use WebAuthn or OAuth2, select the exact built-in set with `.auth.methods.builtins`
so their code (WebAuthn's CBOR/COSE stack in particular, ~3.2k LOC) never ends up
in your binary:

```zig
// No route code needed — enable methods in your collection declaration:
zigbase.App(.{
    .auth = .{ .methods = .{ .builtins = .{ .password, .magic_link, .otp } } },
    .collections = .{
        .members = .{ .type = .auth, .auth = .{
            .methods = .{
                .magic_link = .{
                    .ttl_s = 900,        // link expires in 15 minutes
                    .auto_create = false, // don't auto-provision new accounts
                    .rate_limit = .default,
                },
                .otp = .{
                    .length = 6,
                    .ttl_s = 300,        // code expires in 5 minutes
                    .rate_limit = .{ .custom = .{ .max = 5, .window_s = 60 } },
                },
            },
        } },
    },
}).runCli(init);
```

This auto-mounts four endpoints (no route code):

```
POST /api/collections/members/auth/magic_link/initiate   → 204 (enumeration-safe)
POST /api/collections/members/auth/magic_link/complete   → 200 with session
POST /api/collections/members/auth/otp/initiate          → 204 (enumeration-safe)
POST /api/collections/members/auth/otp/complete          → 200 with session
```

Both built-in methods route through the same `issueSession`+`emitAuth` seam, so your `onAuth` handler fires for every sign-in tagged with `.magic_link` or `.otp`.

Note: the existing custom-route magic-link recipe (above) remains the "low-level" alternative — use it when you need custom logic (e.g. a non-standard token delivery path) that the built-in method doesn't support.

---

## Recipe: custom `AuthMethod` plugin sketch

A minimal custom plugin implementing the `AuthMethod` contract:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// A minimal custom auth method that validates a pre-shared API key.
/// In production, key lookup would hit a database or external service.
const ApiKeyMethod = struct {
    gpa: std.mem.Allocator,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !ApiKeyMethod {
        _ = io; _ = cfg;
        return .{ .gpa = gpa };
    }

    pub fn method(self: *ApiKeyMethod) zigbase.AuthMethod {
        return .{
            .slug = "api-key",
            .ctx = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *ApiKeyMethod) void { _ = self; }

    const vtable = zigbase.AuthMethod.VTable{
        .initiate = initiate,
        .complete = complete,
    };

    /// Phase 1: nothing to do for API-key auth (no challenge).
    fn initiate(ctx: *anyopaque, ac: *zigbase.AuthCtx) anyerror!zigbase.AuthCtx.InitiateResult {
        _ = ctx; _ = ac;
        return .{ .status = 204, .body = null };
    }

    /// Phase 2: validate the key, resolve to a record.
    fn complete(ctx: *anyopaque, ac: *zigbase.AuthCtx) anyerror!zigbase.auth.Resolution {
        _ = ctx;
        const body = ac.ctx.body;

        // Parse {"apiKey":"..."} from the request body.
        const parsed = std.json.parseFromSlice(
            struct { apiKey: []const u8 }, ac.ctx.allocator.a, body, .{},
        ) catch return .{ .fail = .{ .status = 400, .message = "Missing apiKey." } };
        defer parsed.deinit();

        // Look up the record by identity (here: by api key field).
        // findByIdentity matches the collection's configured identity fields.
        const record_id = (try ac.findByIdentity(parsed.value.apiKey))
            orelse return .{ .fail = .{ .status = 401, .message = "Invalid API key." } };

        // Return the record id — the framework mints the session + fires onAuth.
        return .{ .record = record_id };
    }
};

// Register at the app level and enable per collection:
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .auth = .{ .methods = .{ApiKeyMethod} },
        .collections = .{
            .services = .{ .type = .auth, .auth = .{
                .methods = .{
                    .custom = &.{"api-key"},  // enable by slug
                },
            } },
        },
    }).runCli(init);
}
```

Key points:
- The plugin type must implement `create`/`method`/`deinit`. A missing method is a compile error.
- `complete` NEVER mints a session — it returns a `Resolution`. The framework mints via the seam (`issueSession`+`emitAuth`).
- Rate-limiting is applied by the framework around both phases; `ac.rateLimit` is available for finer-grained control within the handler.
- `initiate` may be a no-op (`.{ .status = 204 }`) for methods that need no challenge phase.
- Custom plugins appear in the generated TypeScript client's `auth` surface as untyped stubs (currently).

---

## Recipe: encrypt a field at rest (+ key rotation with `rewrap`)

Mark a `text`/`editor`/`json` field `.encrypted = true` to store it AES-256-GCM-encrypted;
reads and writes see plaintext, the SQLite file holds ciphertext. The key comes **only** from
`ZIGBASE_FIELD_KEY` (never auto-generated) — if any encrypted field exists and the key is
unset, the server refuses to start.

```zig
zigbase.App(.{
    .collections = .{
        .patients = .{ .fields = .{
            .{ .name = "name", .type = .text },
            .{ .name = "ssn",  .type = .text, .encrypted = true },  // ciphertext at rest
        } },
    },
}).runCli(init);
```

```sh
ZIGBASE_FIELD_KEY="a-long-random-secret" ./myserver serve --data-dir ./zb_data
```

Encrypted fields can't be `.unique`, indexed, or used in a `?filter`/`?sort` (a request that
tries gets `400`). To **rotate keys** (generation 1 → 2) or to migrate existing plaintext into
ciphertext, run `zigbase rewrap` with the new primary key plus every older generation present:

```sh
# write new data as v2 while still reading v1; then re-encrypt every v1 cell as v2:
ZIGBASE_FIELD_KEY=newkey ZIGBASE_FIELD_KEY_GENERATION=2 ZIGBASE_FIELD_KEY_V1=oldkey \
  ./myserver rewrap --data-dir ./zb_data        # --dry-run reports counts only
```

`rewrap` is idempotent and fail-closed (a cell it can't decrypt aborts that collection's
transaction). Full envelope/rotation details: [framework.md → Field encryption at rest](framework.md#field-encryption-at-rest-encrypted).

## Recipe: auto-expiring rows (TTL collections)

Name a `date`/`autodate` field as a collection's `.ttl_field` and the framework reaps expired
rows for you (no cron of your own) **and** hides them from every read immediately:

```zig
.holds = .{ .fields = .{
    .{ .name = "slot",       .type = .text },
    .{ .name = "expires_at", .type = .date },   // ISO-8601 UTC
} , .ttl_field = "expires_at" },
```

A row with `expires_at` non-null and at/before "now" is excluded from list/get/expand
immediately and deleted by the internal `_ttl_gc` job (startup + every ~5 minutes). A `null`
ttl value never expires. Over the REST API, set `"options": { "ttl_field": "expires_at" }` in
the collection body (see [api.md → Collection options](api.md#collection-options)).

## Recipe: built-in KV store and feature flags

`ctx.kv()` is a schema-less key→value store (backed by an internal `_kv` table, invisible to
the record API). Feature flags (0.8.0) are **declared** in the `App(cfg)` literal and accessed
through a compile-checked accessor — a typo'd `.name` won't compile. See
[framework.md → Feature flags + experiments](framework.md#feature-flags--experiments-declared)
for the full surface (flags, experiments, `resolveAll`).

```zig
pub const App = zigbase.App(.{
    .flags = .{ .new_checkout = false }, // declared (default off)
    // ... routes etc.
});

fn toggleBeta(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    try App.setFlag(ctx, .new_checkout, true);      // writes the override (typed, compile-checked)
    try ctx.kv().set("welcome_banner", "Hi there"); // arbitrary string value
    const on = App.flag(ctx, .new_checkout);         // declared default until an override is set
    const banner = try ctx.kv().get("welcome_banner"); // ?[]const u8
    _ = on; _ = banner;
    return .{ .status = 204, .body = "" };
}
```

KV/flags are **server-side and superuser-managed** by default. Superusers can manage them over
HTTP (`GET/PUT/DELETE /api/settings[/:key]`) or in the admin UI's "Settings / Feature Flags"
screen. To expose one value publicly, write a one-line custom route that reads it via
`ctx.flagByName(name)` (returns `?bool`, null when undeclared) or `ctx.kv()` — exposing a flag
is then an explicit choice, not the default.

## Recipe: gate a public form with CAPTCHA

Verify a browser-submitted CAPTCHA token against `recaptcha_v2`, `recaptcha_v3`,
`hcaptcha`, or `turnstile` before honoring a public write (signup, contact form, booking
request, ...).

Configure the provider + secret in `App(cfg)`:

```zig
pub const app = zigbase.App(.{
    .auth = .{
        .captcha = .{
            .provider = .recaptcha_v3,   // .recaptcha_v2 | .recaptcha_v3 | .hcaptcha | .turnstile
            .secret   = "6LeXXXXXXXXX",  // server-side site-verify secret
        },
    },
    // ...
});
```

Verify the token in the route/hook that handles the submission, and reject the write if
it fails:

```zig
fn submitHandler(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    const token = (try ctx.query()).get("captcha") orelse "";
    const r = try ctx.verifyCaptcha(.recaptcha_v3, token);
    if (!r.ok) return ctx.jsonError(403, "captcha_required", "Captcha required.");
    // reCAPTCHA v3: score 0.0 (bot) → 1.0 (human); block suspicious traffic.
    if (r.score) |score| if (score < 0.5) return ctx.jsonError(403, "suspicious_request", "Suspicious request.");
    // ... proceed with the submission ...
}
```

`verifyCaptcha` can also fail with a Zig error (`error.TransportFailed`,
`error.CaptchaProviderError`, `error.CaptchaParseError`) rather than returning `ok=false` —
catch it to choose fail-open vs fail-closed:

```zig
const r = ctx.verifyCaptcha(.turnstile, token) catch |e| {
    std.log.warn("captcha provider unreachable: {s}", .{@errorName(e)});
    // fail-open: proceed; or return ctx.jsonError(503, "captcha_unavailable", "Captcha unavailable.") to fail-closed
    return process(ctx);
};
```

With an empty/unset secret, `ctx.verifyCaptcha` returns `.{ .ok = true }` immediately —
no network call, no live key needed — which keeps local dev and unit tests working
without a real provider.

> **Never deploy with an empty secret** — every `verifyCaptcha` call returns `ok=true`
> without contacting the provider.

Full option table: [ctx.verifyCaptcha reference](framework.md#ctxverifycaptcha--captcha-verification-140).

## Recipe: testing an app (in-process, deterministic)

Most tests belong **in-process**: `zigbase.testing` boots your app against a
throwaway data directory and injects requests through the real router, access
rules, auth, and hooks — no socket, no port, milliseconds per test.

Wire the step once (`zigbase init --framework` does this for you):

```zig
// build.zig
const zigbase = @import("zigbase");
// ... after zigbase.addTo(dep, app_mod) ...
const tests = zigbase.addTest(b, dep, .{ .root_module = app_mod });
b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
```

Then write tests against the real endpoints:

```zig
test "only published posts are listed publicly" {
    var t = try zigbase.testing.start(App, .{});
    defer t.deinit();

    _ = try t.createRecord("posts", .{ .title = "Draft", .published = false });
    _ = try t.createRecord("posts", .{ .title = "Live", .published = true });

    const r = try t.request(.GET, "/api/collections/posts/records", .{});
    const page = try r.json(struct { items: []struct { title: []const u8 } });
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
}
```

**Determinism is a `start` option, not an environment variable.** Freeze the
clock and seed the PRNG so IDs, timestamps, and tokens repeat byte-for-byte, and
capture outbound mail with a harness-owned mailbox:

```zig
test "the verification email is sent" {
    var t = try zigbase.testing.start(App, .{
        .fake_now_unix = 1_800_000_000, // every "now", including SQL 'now'
        .fake_seed = 12345,             // reproducible record ids and tokens
    });
    defer t.deinit();

    const mail = try t.captureMail(); // install BEFORE the request that sends

    _ = try t.request(.POST, "/api/collections/users/request-verification",
        .{ .json = .{ .email = "user@example.com" } });

    try std.testing.expectEqual(@as(usize, 1), mail.messages.items.len);
    try std.testing.expectEqualStrings("user@example.com", mail.messages.items[0].to);
}
```

`captureMail` returns a mailbox owned by the harness, so parallel tests do not
share it.

### When you are testing a spawned server instead

For end-to-end runs against a real `serve` process — a client SDK, a frontend,
the socket layer — the same determinism seams are exposed as environment
variables, and `zigbase.testcapture` is the process-global capture API:

```sh
ZIGBASE_FAKE_NOW="2029-03-07T16:00:00Z" \
ZIGBASE_FAKE_SEED=12345 \
  ./myserver serve --data-dir ./zb_data --insecure-cookies
```

```zig
const tc = zigbase.testcapture;
tc.http.enable(true);     // block un-mocked URLs (no real network)
defer tc.http.reset();
tc.http.mock("api.stripe.com", .{ .status = 200, .body = "{\"paid\":true}" });
```

These are process-global mutable flags — fine for a single spawned server,
wrong for parallel in-process tests. Prefer the `StartOptions` above whenever
you are in-process.

Full guide: [testing.md](testing.md). Full API:
[framework.md §15](framework.md#15-testing-your-app-zigbasetesting) and
[§14](framework.md#14-test--dev-mode-determinism-seams).

## See also

[fields.md](fields.md) · [tutorial.md](tutorial.md) · [api.md](api.md) · [framework.md](framework.md)
