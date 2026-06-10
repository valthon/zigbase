---
title: Recipes
description: Copy-pasteable recipes — provisioning a schema, signup, owner-scoped access rules, validation hooks, custom routes, and DB access in cron jobs.
order: 1
group: guides
---

# Recipes

Task-oriented, copy-pasteable recipes for going from an empty database to a working
backend. The running example is **"Airbnb for golf simulators"**: hosts list golf
simulators, guests book time slots.

These recipes assume a ZigBase server running on `http://127.0.0.1:8090` and a superuser
already created:

```sh
./zig-out/bin/zigbase superuser create --email admin@example.com --password "a-strong-password" --data-dir ./zb_data
ZIGBASE_JWT_SECRET="$(head -c 32 /dev/urandom | base64)" ./zig-out/bin/zigbase serve --data-dir ./zb_data
```

Reference companions: field shapes are in [Fields](./fields); endpoint envelopes and rule
semantics are in [API](./api); the framework hook/route/job APIs are in
[Framework](./framework).

## Recipe: provisioning your schema

There is no "import a schema file" endpoint — over the REST API you **provision by calling
`POST /api/collections`** for each collection, as a superuser. Because relation fields
reference their target by **id** (not name — see
[Fields → relation gotcha](./fields#relation)), you must create collections **in
dependency order** and **capture each `id`** from the response to feed the next
collection's `targetCollectionId`.

> **Embedding ZigBase?** You can skip the REST dance entirely and **declare your schema in
> Zig at comptime** via `App(.{ .collections = .{ ... } })`, provisioned at startup with
> additive auto-migration — relations reference their target **by name** (no id-capturing).
> See [Framework → Define your schema in code](./framework#8-define-your-schema-in-code-collections--migrations).

The script below logs in as the superuser, then creates `users` (auth) → `simulators` →
`listings` → `bookings`, wiring relations by captured id, and seeds a demo simulator. It
uses `curl` + `jq`.

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

# 2) users — an AUTH collection. Public create rule ("") enables open signup.
USERS_ID=$(create_collection '{
  "name": "users",
  "type": "auth",
  "fields": [
    { "id": "f_name", "name": "name", "type": "text", "options": { "max": 100 } }
  ],
  "listRule": "",
  "viewRule": "",
  "createRule": "",
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
  \"listRule\": \"\",
  \"viewRule\": \"\",
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

- **Order matters.** `users` and `simulators` must exist (and their ids captured) before
  `listings`; `listings` and `users` before `bookings`.
- **Capture the id, not the name.** Every relation's `targetCollectionId` above is a shell
  variable holding the **id** returned by the prior create call.
- Collection management is **superuser-only**; record create/seed calls run as the
  relevant user (or anonymously where the create rule is public).

## Recipe: user registration (signup)

ZigBase has no separate "register" endpoint. **Signup is a normal record create on an auth
collection:**

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

- The `users` collection needs a **public create rule** (`"createRule": ""`) for open
  signup. With any other rule, anonymous signup is denied (a non-public, non-empty rule
  yields `403`; a `null`/locked rule yields `403`).
- `password` must be at least **`minPasswordLength`** characters (default **8**;
  configurable in the collection's `options.auth.minPasswordLength`). A missing or
  too-short password is a **`400`** ("A password of the required length is required.").

Then **log in** to obtain a token (and the `zb_auth`/`zb_csrf` cookies):

```sh
curl -s -X POST "$BASE/api/collections/users/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d '{"identity":"guest@example.com","password":"guestpassword"}'
# -> { "token": "<jwt>", "record": { "id": "...", "email": "guest@example.com", ... } }
```

`identity` is matched against the collection's `identityFields` (default `["email"]`). See
[API → auth-with-password](./api#auth-with-password). Email **verification** is optional;
the token is emailed when SMTP is configured, or logged in dev otherwise — see
[API → Verification & password reset](./api#verification--password-reset--email-delivery).

## Recipe: owner-scoped access rules

Access rules are filter expressions evaluated per request (full grammar in
[API → Filter grammar](./api#filter-grammar)). Relevant pieces:

- `@request.auth.id` — the authenticated user's record id (`""` when anonymous).
- A bare field name (e.g. `owner`) refers to the record being checked.
- **Relation traversal with `.` is supported in rules** (not just flat fields):
  `simulator.owner` follows the single-value `simulator` relation to the simulators row
  and reads its `owner`. You can chain: `listing.simulator.owner`. (Traversal works
  through **single-value** relations; traversing a multi-value relation — `maxSelect > 1`
  — is not supported and the query is rejected.)

### Edit only your own records

```jsonc
"updateRule": "@request.auth.id = owner",
"deleteRule": "@request.auth.id = owner"
```

### Public read OR owner read

Anyone may read published rows; the owner may additionally read their own (e.g. drafts):

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

Here `listing.simulator.owner` traverses `bookings.listing` → `listings.simulator` →
`simulators.owner`.

### How does the `owner` field get set on create?

A rule like `updateRule: "@request.auth.id = owner"` only protects *existing* rows. You
still must ensure the `owner` field is correctly populated **at create time**. Two
patterns:

1. **Server sets it (recommended).** A `beforeCreate` hook overwrites `owner` from the
   authenticated identity, so the client can't spoof it:

   ```zig
   fn setOwner(ev: *zigbase.RecordEvent) anyerror!void {
       if (ev.record.* != .object) return;
       const uid = ev.ctx.resolveMacro("@request.auth.id") orelse "";
       if (uid.len == 0) return error.Unauthenticated; // reject anonymous creates -> 400
       try ev.record.object.put(ev.arena, "owner", .{ .string = uid }); // ev.arena, not app.allocator
   }
   ```

   Register it as `.hooks = .{ .simulators = .{ .beforeCreate = setOwner } }`. See
   [Framework → Record hooks](./framework#4-record-hooks-hooks).

2. **Client sends it, the create rule enforces it.** Require the submitted `owner` to
   equal the caller, via a `@request.data.*` create rule:

   ```jsonc
   "createRule": "@request.data.owner = @request.auth.id"
   ```

   The client must include `"owner": "<their id>"` in the body; a mismatched or missing
   value fails the rule with `403`.

Pattern 1 is sturdier (the client cannot get it wrong); pattern 2 needs no Zig code.

## Recipe: a computed-field / validation `beforeCreate` hook

A `beforeCreate` hook runs **after** access rules pass and **before** the write. It may
mutate `ev.record` and may **return an error to reject** the write (the request fails with
`400`). This example, on `bookings`, (a) rejects a booking that overlaps an existing
confirmed booking for the same listing, and (b) computes a derived `duration_minutes`
field.

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// before_create on "bookings": reject overlaps with a confirmed booking and
/// compute a derived duration field. Allocations that land in ev.record use ev.arena.
fn validateBooking(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return; // framework guards non-objects already

    const listing = strField(ev.record, "listing") orelse return error.MissingListing;
    const starts = strField(ev.record, "starts_at") orelse return error.MissingStart;
    const ends = strField(ev.record, "ends_at") orelse return error.MissingEnd;

    // 1) Conflict check: any CONFIRMED booking for this listing that overlaps?
    //    ev.data.list runs a curated query on the request's connection.
    const filter = try std.fmt.allocPrint(ev.arena,
        "listing = \"{s}\" && status = \"confirmed\" && starts_at < \"{s}\" && ends_at > \"{s}\"",
        .{ listing, ends, starts },
    );
    const conflicts = try ev.data.list("bookings", .{ .filter = filter, .perPage = 1 });
    if (conflicts.totalItems > 0) return error.SlotUnavailable; // -> 400, rejects the create

    // 2) Compute a derived numeric field from the two timestamps (illustrative).
    const minutes = durationMinutes(starts, ends);
    try ev.record.object.put(ev.arena, "duration_minutes", .{ .integer = minutes });
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

- **Use `ev.arena`** for anything stored into `ev.record` (the request-scoped allocator
  that owns the record's JSON), never `ev.app.allocator`. See
  [Framework → CRITICAL: use ev.arena](./framework#critical-use-evarena-not-evappallocator).
- **`ev.data.list(collection, query)`** returns a `ListResult` with `totalItems` and
  `items`; the `query` is a `records.ListQuery` (`.filter`, `.sort`, `.page`, `.perPage`).
  `ev.data` also offers `findById`, `create`, `update`, `delete`.
- **Returning any error rejects** the create with `400` ("Request rejected by a hook.").
- **Atomicity caveat:** a `before*` hook's own `ev.data` writes are **not** atomic with the
  triggering write (the triggering write's transaction opens after the hook returns). For a
  pure read-and-validate hook like this, that's fine; avoid relying on a hook-issued
  side-write rolling back if the main write fails. See
  [Framework → The ev.data facade](./framework#the-evdata-facade).

## Recipe: a custom business route with a path param + DB write

A `POST /api/bookings/:id/confirm` route that a host calls to confirm a pending booking. It
reads the `:id` path param, loads the record, mutates it, and returns the standard JSON
envelope (or `404`/`403`).

`RouteEvent` carries `app`, `ctx` (the `http.RequestCtx`), and `rctx` (the resolved auth
identity). It does **not** carry a `Data` facade — build one from the pool the same way a
cron job does.

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// POST /api/bookings/:id/confirm — host confirms a pending booking.
fn confirmBooking(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    const a = ev.ctx.allocator; // request arena
    const id = ev.ctx.param("id") orelse
        return .{ .status = 404, .body = "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}" };

    // Build a Data facade on a writer connection (route events don't carry one).
    const w = ev.app.pool.acquireWriter();
    defer ev.app.pool.releaseWriter();
    const data = zigbase.Data{ .app = ev.app, .conn = w, .io = ev.app.io };

    // Load the booking (null = unknown collection OR missing record).
    const booking = (try data.findById("bookings", id)) orelse
        return .{ .status = 404, .body = "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}" };

    // Authorize: only the host who owns the booked listing's simulator may confirm.
    // (rctx carries the authenticated identity; .auth = .authed on the route spec
    // already guarantees a logged-in user.)
    const uid = ev.rctx.resolveMacro("@request.auth.id") orelse "";
    _ = booking; // (look up listing.simulator.owner via data.findById and compare to uid)
    if (uid.len == 0)
        return .{ .status = 403, .body = "{\"code\":403,\"message\":\"Forbidden.\",\"data\":{}}" };

    // Mutate: set status = "confirmed".
    var patch: std.json.ObjectMap = .empty;
    try patch.put(a, "status", .{ .string = "confirmed" });
    const updated = (try data.update("bookings", id, .{ .object = patch })) orelse
        return .{ .status = 404, .body = "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}" };

    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, updated, .{}) };
}
```

Register it (note `.auth = .authed` so only logged-in users reach the handler; the default
if omitted is `.superuser`):

```zig
.routes = .{
    .{ .method = .POST, .path = "/api/bookings/:id/confirm", .handler = confirmBooking, .auth = .authed },
},
```

Key points:

- **Path params:** `ev.ctx.param("id")` returns the captured `:id` (or `null`).
- **The auth level is enforced by the framework before your handler runs**; inside, use
  `ev.rctx` for finer authorization (e.g. owner checks).
- **Built-in routes win** over custom routes matching the same method+path, so namespace
  your routes (`/api/bookings/:id/confirm`, not a path that shadows a built-in).
- Return any `zigbase.http.Response`; the body is a JSON string you allocate from
  `ev.ctx.allocator`.

## Recipe: DB access inside a cron / lifecycle job

A `JobEvent` carries `app` and `name` — but no ambient connection. Use the RAII DB
accessors it exposes to check a connection out of the pool and hand it back:

- For **writes**: `var w = ev.writer(); defer w.deinit();` then `w.data()`.
- For **reads**: `var r = try ev.reader(); defer r.deinit();` then `r.data()`.

`w.data()` / `r.data()` each yield a `zigbase.Data` bound to that connection (`findById` /
`create` / `update` / `delete` / `list`). The same accessors exist on `RouteEvent` and
`LifecycleEvent`. (See
[Framework → DB access from a route](./framework#db-access-from-a-route-evwriter--evreader).)

This nightly job cancels stale `pending` bookings (older than now) by listing them and
updating each:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// Nightly: cancel pending bookings whose start time has passed.
fn expireStaleBookings(ev: *zigbase.events.JobEvent) anyerror!void {
    const a = ev.app.allocator;

    // Writer handle + Data facade — the accessor checks the writer out of the pool
    // and deinit() hands it back (no leak).
    var w = ev.writer();
    defer w.deinit();
    const data = w.data();

    const now = "2026-06-10 00:00:00"; // compute the current timestamp in your format
    const filter = try std.fmt.allocPrint(a,
        "status = \"pending\" && starts_at < \"{s}\"", .{now});

    const stale = try data.list("bookings", .{ .filter = filter, .perPage = 200 });
    for (stale.items) |item| {
        const id = item.object.get("id").?.string;
        var patch: std.json.ObjectMap = .empty;
        try patch.put(a, "status", .{ .string = "cancelled" });
        _ = try data.update("bookings", id, .{ .object = patch });
    }
    std.log.info("job '{s}': cancelled {d} stale bookings", .{ ev.name, stale.totalItems });
}
```

Register it on a schedule (cron/interval handlers have the `fn (*JobEvent) anyerror!void`
signature):

```zig
.jobs = .{ .pool_size = 2 },
.cron = .{
    .{ .name = "expire-bookings",
       .schedule = zigbase.schedule.Schedule{ .cron = "0 3 * * *" }, // 03:00 UTC daily
       .handler = expireStaleBookings },
},
```

Key points:

- **Always `defer <handle>.deinit()`** on the writer/reader handle — it releases the writer
  (or returns the reader connection) to the pool. The writer is a single shared,
  mutex-guarded connection — holding it blocks all other writes.
- Job allocations can use `ev.app.allocator` (the long-lived gpa) since there is no request
  arena here; free anything large yourself if the job runs often.
- Scheduling is **single-process, UTC, minute-granularity**; cron is numeric-only. See
  [Framework → Scheduled jobs](./framework#7-scheduled-jobs-cron--jobs) and its caveats.

## See also

[Fields](./fields) · [Tutorial](./tutorial) · [API](./api) · [Framework](./framework)
