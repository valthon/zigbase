# ZigBase golfsim example — a realistic complete app

"**Airbnb for golf simulators**": hosts list golf simulators, guests book time
slots. This is the **middle rung** of a three-example ladder:

| Rung | Example | Purpose |
|------|---------|---------|
| 1 | `examples/blog` | Minimal packaging proof — one hook, one route, one cron |
| 2 | **`examples/golfsim`** | Realistic complete product — multi-collection relations, hooks, files, realtime |
| 3 | `examples/plugins` | Advanced framework surface — custom storage, comptime migrations, pool tuning |

`golfsim` covers the **hard parts** of building a real backend on ZigBase *as a
library*: multi-collection relations with cascadeDelete, invariant-enforcing hooks
(double-booking prevention), access rules with relation traversal, file uploads,
WebSocket realtime, per-device session management (`ctx.auth()`), atomic multi-write
transactions (`ctx.tx()`), outbound webhooks (`ctx.http()`), and multiple custom
business routes — all with a working Zigapagos islands frontend. That business logic is
covered by an in-process Zig test suite (`zig build test`, [`zigbase.testing`](../../docs/testing.md)),
including a determinism test that freezes time and seeds id generation
(`.fake_now_unix` / `.fake_seed`); a separate vitest e2e suite drives the **generated
typed client** against a real spawned server and its worker pool, which the outbound
webhook needs. See ["Two test surfaces, on purpose"](#two-test-surfaces-on-purpose).

Everything else (HTTP API, SQLite storage, auth, file storage, the admin UI, the
CLI) comes straight from the framework via the public `zigbase.*` exports.

> **Pre-1.0:** ZigBase is pre-1.0 — the hook/route/job config shapes and the module
> API may change between releases.

---

## What golfsim demonstrates

### 1. Invariant-enforcing hooks

#### `prepareBooking` — `beforeCreate` on `bookings`

```zig
fn prepareBooking(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    // 1. Validate listing exists and is published. DB access goes through the
    //    per-request capability object: `ctx.records()` (bound to the triggering
    //    write's in-transaction connection).
    const listing = (try ctx.records().get("listings", listing_id, .{})) orelse
        return error.ListingNotFound;

    // 2. Double-booking check — allocate filter with ev.arena.a.
    const overlap_filter = try std.fmt.allocPrint(ev.arena.a,
        "listing = \"{s}\" && status != \"cancelled\" && starts_at < \"{s}\" && ends_at > \"{s}\"",
        .{ listing_id, ends_at, starts_at });
    const conflicts = try ctx.records().list("bookings", .{ .filter = overlap_filter, .perPage = 1 });
    // totalItems is optional (cursor mode may skip COUNT); offset mode always sets it.
    if ((conflicts.totalItems orelse 0) > 0) return error.TimeSlotConflict; // -> HTTP 400

    // 3. Compute price_total = hours × rate (server-side, unforgeable).
    try rec.put(ev.arena.a, "price_total", .{ .float = hours * rate });

    // 4. Stamp guest and force status=pending from the server.
    try rec.put(ev.arena.a, "guest", .{ .string = try ev.arena.a.dupe(u8, auth_id) });
    try rec.put(ev.arena.a, "status", .{ .string = "pending" });
}
```

Record mutations that enter `ev.record` **must** allocate with `ev.arena.a`.
`ev.arena` is a typed `RequestArena` (so a general-purpose allocator can't be
handed to an arena-scoped API by accident) and `.a` is the request-scoped
allocator inside it, the one that owns `ev.record`. Need the app itself?
Use `ctx.app`. Returning any error rejects the write → HTTP 400 to the client.

#### `prepareReview` — `beforeCreate` on `reviews`

A second invariant hook gates who may leave a review. It stamps the `author`
from the authenticated identity (server-authoritative) and rejects the write
unless the referenced booking exists, was made by *this* author (they were the
`guest`), and is already `confirmed` — you can't review someone else's booking,
or a session that hasn't happened:

```zig
fn prepareReview(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    const booking = (try ctx.records().get("bookings", booking_id, .{})) orelse
        return error.BookingNotFound;
    // gate 1: the booking must be the caller's own
    if (!std.mem.eql(u8, guest, author)) return error.BookingNotYours;     // -> 400
    // gate 2: only a CONFIRMED (completed) session may be reviewed
    if (!std.mem.eql(u8, status, "confirmed")) return error.BookingNotConfirmed; // -> 400
    // stamp author from the identity (overwriting any client-supplied value)
    try rec.put(ev.arena.a, "author", .{ .string = try ev.arena.a.dupe(u8, author) });
}
```

---

### 2. Custom business routes

| Method | Path | Auth | What it does |
|--------|------|------|--------------|
| `POST` | `/api/bookings/:id/confirm` | authed | Host confirms a booking. Multi-hop owner check: booking → listing → simulator → owner. 403 if caller doesn't own the simulator. Gated by the declared `bookings_frozen` feature flag (`App.flag(ctx, .bookings_frozen)`) — returns 503 when set. On success offloads a best-effort booking-confirmation webhook (`ctx.http()`) to the background worker pool via `ctx.app.submit` so the response isn't blocked. |
| `POST` | `/api/bookings/:id/cancel` | authed | Guest cancels their own booking. 403 if caller is not the booking's guest. Reads/writes via `req.ctx.records()`. |
| `GET` | `/api/listings/:id/availability` | authed | Returns all non-cancelled bookings for a listing for availability calendar rendering. Reads via `req.ctx.records()`. |
| `POST` | `/api/holds/:id/convert` | authed | Promotes the caller's `hold` into a pending `booking` for a chosen window. Runs the booking-create + hold-delete **atomically in one `ctx.tx()`**. 403 if caller is not the hold's guest. |
| `POST` | `/api/golfsim/logout-everywhere` | authed | "Log out everywhere" via `ctx.auth().revokeAllSessions()` — bumps the token epoch and (in table mode) wipes the principal's session rows; also clears this device's cookies. |
| `GET` | `/api/golfsim/sessions` | authed | "Active devices": `ctx.auth().listActiveSessions()` → `{"items":[…]}`, each session flagged `is_current`. Requires `.auth.session.store = .table`. |
| `POST` | `/api/golfsim/sessions/:id/revoke` | authed | "Log out this device": `ctx.auth().revoke(id)`. Owner-authorized — a non-owner or absent id is `404`. |
| `GET` | `/api/golfsim/health` | public | Smoke endpoint. |
| `GET` | `/api/golfsim/flags/:name` | public | Public read of one declared feature flag via `ctx.flagByName` → `{"name","enabled"}` (404 for an undeclared name). Manage values with the superuser settings API or `App.setFlag`. |
| `POST` | `/api/golfsim/logout` | public | Clears the `zb_auth`/`zb_csrf` session cookies via `ctx.auth().clearSession()`. Works even with a stale or expired cookie. |
| `GET` | `/api/golfsim/calendar.ics` | public | Returns a static iCal feed (`text/calendar`). Untyped handler (raw `http.Response`) — not in the generated `zb.rpc.*` client; subscribe to this URL directly from a calendar app. |

Feature flags are **declared** in the `App(.{ .flags = … })` literal (0.8.0) and resolve
through the typed `App.flag(ctx, .name)` accessor (a typo'd name is a compile error) over the
built-in KV store (`flag:<name>` overrides, backed by the internal `_kv` table). Flags are
superuser-managed and not public by default — the `flags/:name` route above opts declared
flags into a public read via `ctx.flagByName`. The kill switch `bookings_frozen` lets an
operator freeze confirmations instantly with a single
`PUT /api/settings/flag:bookings_frozen {"value":"true"}` — no redeploy.

The `confirmBooking` route shows the multi-hop imperative owner check (the access
rule engine does this via traversal for CRUD endpoints; custom routes do it via
`records.get` hops). It is a typed route — `req.ctx.records()` manages the pooled
connection itself (no manual acquireWriter / Data wiring):

```zig
fn confirmBooking(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const records = req.ctx.records();
    // booking.listing -> listings -> listing.simulator -> simulators -> simulator.owner
    const listing = (records.get("listings", listing_id, .{}) catch return error.RouteFailed) orelse return error.NotFound;
    const simulator = (records.get("simulators", simulator_id, .{}) catch return error.RouteFailed) orelse return error.NotFound;
    const owner_id = // simulator.owner
    if (!std.mem.eql(u8, owner_id, caller_id)) return error.Forbidden; // 403
    const updated = (records.update("bookings", id, patch) catch return error.RouteFailed) orelse return error.NotFound;
    return updated; // thunk serializes it to the 200 body
}
```

---

### 3. Files — listing photos

`listings` has a `photos` file field accepting up to 6 images (5 MB each, png/jpeg/webp):

```zig
.{ .name = "photos", .type = .file, .maxSelect = 6, .maxSize = 5242880,
   .mimeTypes = .{ "image/png", "image/jpeg", "image/webp" } }
```

Upload via `PATCH /api/collections/listings/records/:id` with `multipart/form-data`.
Do NOT set `Content-Type` — the browser sets the multipart boundary automatically.
Serve stored photos at `/api/files/listings/:recId/:filename`.

An `onFileUpload` handler logs every upload:

```zig
fn logFileUpload(ev: *zigbase.events.FileEvent) void {
    std.log.info("file-upload: collection={s} record={s} file={s}",
        .{ ev.collection, ev.record_id, ev.filename });
}
// registered as: .onFileUpload = logFileUpload
```

---

### 4. Access rules with relation traversal

```
bookings.list = "@request.auth.id = guest || @request.auth.id = listing.simulator.owner"
```

The rule engine traverses `booking.listing → listing.simulator → simulator.owner`
at query time for all CRUD endpoints — the application layer doesn't join manually
for authorization. Custom routes re-implement this imperatively (via
`records.get` hops) to return a proper 403.

---

### 5. Realtime

`MyBookings` subscribes to the `bookings` topic over WebSocket so the booking
list live-updates without polling whenever a host confirms, a guest cancels, or
the `expire-holds` cron sweeps stale holds:

```ts
// lib/api.ts — subscribeBookings()
const ws = new WebSocket(`${proto}://${location.host}/api/realtime`);
ws.onopen = () => ws.send(JSON.stringify({ action: 'auth', token }));
// on { type:"auth", status:"ok" } → send { action:"subscribe", topic:"bookings" }
// on { type:"event", topic:"bookings", action, record } → call onEvent
```

Returns a cleanup function (calls `ws.close()`) wired into the island's `useEffect`
teardown.

---

### 6. DB-touching cron job

```zig
fn expireHolds(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void {
    _ = ev;
    const stale = ctx.records().list("bookings", .{
        .filter = "status = \"pending\" && starts_at < @now",
        .perPage = 200,
    }) catch |err| switch (err) {
        error.UnknownCollection => return, // no-op until provisioning runs
        else => return err,
    };
    for (stale.items) |item| _ = ctx.records().update("bookings", id, /* cancelled */) catch continue;
}
```

Real DB access inside a background job: the scheduler hands the job a `*Ctx` whose
`records()` handle reads via a pooled reader and writes via the pool writer — no
manual `pool.acquireWriter()` + hand-built `Data`. The framework owns the ctx
lifetime and releases any lazily-acquired connection on exit.

---

### 7. Per-device session management (`.auth.session.store = .table`)

golfsim opts into **per-device sessions** with `App(.{ ..., .auth = .{ .session = .{ .store = .table } } })`.
Each login records a row in the internal `_sessions` table (the default `.epoch` mode
keeps only a token-epoch counter and has no per-session inventory), and the framework
installs a periodic session-GC sweep. The three routes expose the full `ctx.auth()`
surface (#99):

```zig
// "Log out everywhere": invalidate every outstanding token + wipe session rows.
fn logoutEverywhere(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response {
    ctx.auth().revokeAllSessions() catch |e| return ctx.errorResponse(e);
    return .{ .status = 204, .body = "", .cookies = try ctx.auth().clearSession() };
}

// "Active devices": the caller's unexpired sessions, newest first, is_current flagged.
fn activeDevices(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    const sessions = req.ctx.auth().listActiveSessions() catch return error.RouteFailed;
    // ... serialize { id, created, last_seen, user_agent, ip, is_current } into {"items":[…]} ...
}

// "Log out this device": revoke ONE session by id. Owner-only (404 for a non-owner).
fn revokeDevice(req: *zigbase.Req(void)) zigbase.RouteError!RevokeOut {
    const id = req.param("id") orelse return req.fail(400, "Missing session id.");
    req.ctx.auth().revoke(id) catch |e| switch (e) {
        error.NotFound => return error.NotFound,
        else => return error.RouteFailed,
    };
    return .{ .revoked = true };
}
```

`listActiveSessions` / `revoke` return `error.SessionStoreNotEnabled` in the default
`.epoch` mode. `revokeAllSessions` / `refresh` / `rotate` work in both modes.

---

### 8. Atomic multi-write — `ctx.txWith()` (hold → booking convert)

`POST /api/holds/:id/convert` promotes a guest's soft `hold` into a real `booking`. The
booking INSERT and the hold DELETE **must commit or roll back together** — never a
booking with a live hold (double reservation), never a deleted hold with no booking
(lost slot). That is exactly what `ctx.txWith()` is for:

```zig
// ctx.tx takes a bare `*const fn(*Tx)` that cannot capture; ctx.txWith (#237) threads a
// caller-supplied payload straight into the callback instead — no thread-local needed.
fn convertHoldTxn(t: *zigbase.Tx, p: *const ConvertParams) anyerror!std.json.Value {
    const created = try t.records().create("bookings", p.booking);
    if (!try t.records().delete("holds", p.hold_id)) return error.HoldVanished; // rolls back the booking
    return created;
}

// in the route handler, after validating + pricing the booking:
const params = ConvertParams{ .hold_id = id, .booking = .{ .object = b } };
return req.ctx.txWith(std.json.Value, &params, convertHoldTxn) catch return error.RouteFailed;
```

> Note: record `beforeCreate` hooks (like `prepareBooking`) do **not** fire on the
> `Data`/`ctx.records()` create path, so this server-authoritative route prices the
> booking itself. Outbound HTTP (the webhook below) stays **outside** any `ctx.tx` — a
> network stall must never hold the single DB writer.

---

### 9. Outbound HTTP — `ctx.http()`, offloaded via `ctx.app.submit` (booking webhook)

When a host confirms a booking, `confirmBooking` fires a best-effort webhook via
`ctx.http()`. The **recommended production pattern** is to NOT block the request thread on
an outbound call — instead offload it to the background worker pool with `ctx.app.submit`,
so the confirm response returns immediately even if the webhook endpoint is slow:

```zig
// In the route: offload, don't block. `JobTask` is a bare fn that can't capture and
// `submit` doesn't copy `name`, so we hand the booking id to the job as its `name` on a
// long-lived allocator (the job frees it).
fn notifyBookingConfirmed(ctx: *zigbase.Ctx, booking_id: []const u8) void {
    const id = ctx.app.allocator.dupe(u8, booking_id) catch return;
    ctx.app.submit(id, webhookJob) catch |err| {
        ctx.app.allocator.free(id);
        std.log.warn("could not offload booking webhook: {s}", .{@errorName(err)});
    };
}

// The background job (off the request thread): reads the URL from KV, POSTs via ctx.http().
fn webhookJob(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void {
    const booking_id = ev.name;
    defer ctx.app.allocator.free(booking_id);       // we own the name we submitted
    const url = (ctx.kv().get("booking_webhook_url") catch return) orelse return;
    const body = std.fmt.allocPrint(ctx.arena.a,
        "{{\"event\":\"booking.confirmed\",\"booking\":\"{s}\"}}", .{booking_id}) catch return;
    _ = ctx.http().post(url, .{
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = body,
    }) catch |err| { std.log.warn("booking webhook POST failed: {s}", .{@errorName(err)}); return; };
}
```

The job **never propagates an error that matters** — a webhook is a notification, not part
of the transaction, so an unreachable endpoint can't break a confirmation. (Submitted
ad-hoc tasks run on the bounded background worker pool; see `App.submit`'s doc comment
for the shutdown semantics.) The target URL is read from the KV store
(`booking_webhook_url`), seeded at
startup by the `onBootstrap` handler from the `GOLFSIM_BOOKING_WEBHOOK_URL` env var:

```zig
// onBootstrap: the WRITE side of the KV store from app code (routes only read it).
fn seedConfig(ctx: *zigbase.Ctx, ev: *zigbase.events.LifecycleEvent) anyerror!void {
    const raw = std.c.getenv("GOLFSIM_BOOKING_WEBHOOK_URL") orelse return;
    try ctx.kv().set("booking_webhook_url", std.mem.span(raw));
}
```

Run with a webhook configured:

```sh
GOLFSIM_BOOKING_WEBHOOK_URL="https://example.com/hooks/booking" \
  ./zig-out/bin/golfsim serve --insecure-cookies --data-dir ./data
```

---

## Collections

| Collection | Type | Key fields |
|---|---|---|
| `users` | auth | `name`, `loginCount`; `require_verified=true`; OTP + password methods; Google OAuth2 |
| `simulators` | base | `label`, `owner` → users |
| `listings` | base | `title`, `price_per_hour`, `status` (draft/published/archived), `simulator` → simulators, `photos` (file ×6) |
| `bookings` | base | `listing`, `guest`, `starts_at`, `ends_at`, `price_total`, `status` (pending/confirmed/cancelled) |
| `reviews` | base | `booking` → bookings, `author` → users, `rating` (int 1–5), `body` (text) |
| `holds` | base | `listing`, `guest`, `expires_at` (TTL field — auto-GC'd by `_ttl_gc`) |

All six collections are provisioned at startup via comptime `.collections` — no
manual API calls needed. (Lowering a schema this size FNV-hashes every collection
+ field name at comptime, which would exceed Zig's default branch quota; ZigBase
raises its own quota in `provision.buildCollections`, so it just works.)

### TTL records — `holds`

A "hold" is an ephemeral soft-reservation a guest places while paying. Declaring
`.ttl_field = "expires_at"` on the `holds` collection tells the framework's internal
`_ttl_gc` job to sweep and delete expired rows automatically (once at startup, then
every 5 minutes) — no cron required. The `prepareHold` `beforeCreate` hook stamps
`expires_at = now + 15m` server-side; any client-supplied value is ignored, so a
caller cannot pin a hold forever. "now" is read from the **database clock**
(`strftime('%s','now')`) rather than the OS clock, so it honors the `ZIGBASE_FAKE_NOW`
determinism seam on a dev build (see the determinism e2e below).

---

## Handler signatures

| Feature | Signature |
|---|---|
| record hook | `fn(*zigbase.Ctx, *zigbase.RecordEvent) anyerror!void` |
| typed custom route | `fn(*zigbase.Req(In)) zigbase.RouteError!Out` |
| untyped custom route | `fn(*zigbase.Ctx) anyerror!zigbase.http.Response` |
| cron job | `fn(*zigbase.Ctx, *zigbase.events.JobEvent) anyerror!void` |
| file upload | `fn(*zigbase.events.FileEvent) void` |

DB access is through the per-request capability object: `ctx.records()` in hooks/
jobs/untyped routes, `req.ctx.records()` in typed routes — the pooled connection
is managed for you (`.get` / `.list` / `.create` / `.update` / `.delete`).

For raw SQL on a migration-owned table, acquire the pooled writer directly:
`const w = ctx.app.pool.acquireWriter(); defer ctx.app.pool.releaseWriter();`.

---

## Frontend (Zigapagos v0.4.0 islands)

`frontend/` is a Zigapagos site with `@z/runtime` islands. The release command is
pinned through [`scripts/zigapagos.sh`](../../scripts/zigapagos.sh), and its output
continues to land in `frontend/dist` for the comptime static-directory proof:

`zigapagos doctor` reports the expected dangling-link warnings for `/_/` and the
Google OAuth authorize route because those paths are supplied dynamically by the
same ZigBase process rather than emitted into the static tree. It reports no errors.

- **`ListingsBrowser`** — sign in, browse listings with photo gallery, check
  availability (lazy via `/api/listings/:id/availability`), book a slot, upload
  photos via multipart/form-data.
- **`MyBookings`** — view bookings, cancel pending/confirmed bookings, leave a
  rating + review on a confirmed booking; live-updates via realtime WebSocket.
- **`Auth`** — multi-step auth: password sign-in, OTP initiate/complete, signup, email-verification, and OAuth2 (Google).

---

## Generated TypeScript client

> **SDK Tier 2 — comptime-generated typed client.** `zig build gen-client` reads this example's `pub const App` at build time and emits a fully-typed `zbase.gen.ts`: typed `zb.db.<collection>.*` and typed custom-route RPC via `zb.rpc.*` (e.g. `zb.rpc.bookingsConfirm({ id })`). This is the richest tier — it's the only one with typed custom-route RPC. See the [TypeScript SDK docs](../../docs/typescript-sdk.md) and, for runtime generation without Zig source, the plugins example (Tier 3).

`examples/golfsim` ships a **generated, fully type-safe TypeScript client** at
`clients/typescript/zbase.gen.ts`. The file is committed to the repo; `zig build
gen-client` regenerates it from the schema, and the CI staleness gate (`zig build
gen-client-check`) fails if the committed snapshot is out of date.

The prerequisite for code generation is that `src/main.zig` exposes `pub const App`
at module scope — the generator reads the schema directly from the comptime `App`
declaration:

```zig
// src/main.zig
pub const App = zigbase.App(.{
    .collections = .{ ... },
    // ... hooks, routes, jobs ...
});

pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
```

### Commands

```bash
# Regenerate the typed client from the schema:
zig build gen-client

# CI staleness gate — fails if the committed zbase.gen.ts is stale:
zig build gen-client-check

# Build @zigbase/client, then typecheck + run the full e2e suite against a live
# golfsim binary:
cd ../../clients/typescript && npm run build && cd ../../examples/golfsim
npm install && npm run typecheck && npm run test:e2e
```

The e2e suite (`test/`) drives the generated typed client (`clients/typescript/zbase.gen.ts`)
against a live `golfsim` binary — covering typed CRUD, filtering, expand, auth, realtime,
and typed custom-route RPC including the session-management routes (`golfsim.e2e.test.ts`),
plus `ctx.http()`'s webhook offload (`golfsim.determinism.e2e.test.ts`) — all with full
TypeScript type-checking via `vitest`. See ["Two test surfaces, on purpose"](#two-test-surfaces-on-purpose)
below for what moved to the in-process Zig suite and why the webhook test could not follow.

### Determinism e2e — frozen time + captured webhook

`test/golfsim.determinism.e2e.test.ts` starts a golfsim server with `ZIGBASE_FAKE_NOW`
set (so the whole process clock is frozen) and `GOLFSIM_BOOKING_WEBHOOK_URL` pointed at
an in-process Node capture server, then asserts that confirming a booking POSTs the
`booking.confirmed` webhook (`ctx.http()`, offloaded via `ctx.app.submit`) to the capture
server. The frozen-clock hold-expiry assertion and the `ctx.tx` hold-into-booking
conversion that used to live here moved to the in-process Zig suite (`zig build test`),
which reproduces both more precisely (byte-exact `expires_at`, and a determinism test that
proves `.fake_now_unix` + `.fake_seed` give identical output across two independent boots)
with no server process or port. The webhook test could NOT move: it needs `ctx.app.submit`'s
background worker pool, which `zigbase.testing`'s socketless boot deliberately never starts
(see the "Two test surfaces" section below) — so `ctx.app.submit` always returns
`error.SchedulerUnavailable` in-process, and the webhook offload silently no-ops there.

The determinism seam (`ZIGBASE_FAKE_NOW`, test-capture) is compiled in only on a
`dev_mode` build — the default Debug build the harness produces — and is comptime-
eliminated from any release binary. See [docs/framework.md](../../docs/framework.md)
(the determinism + `zigbase.testcapture` sections).

### Using `zb.rpc.*`

The generated client exposes typed methods for each custom route under `zb.rpc.*`:

```ts
// bookingsConfirm: POST /api/bookings/:id/confirm → unknown (cast for type-safe access)
const confirmed = await zb.rpc.bookingsConfirm({ id: booking.id }) as Booking;

// bookingsCancel: POST /api/bookings/:id/cancel
await zb.rpc.bookingsCancel({ id: booking.id });

// listingsAvailability: GET /api/listings/:id/availability
const avail = await zb.rpc.listingsAvailability({ id: listing.id });

// golfsimHealth: GET /api/golfsim/health → typed HealthOut { status: string; app: string }
const health = await zb.rpc.golfsimHealth();
```

`unknown` outputs correspond to `std.json.Value` in Zig — cast to your concrete type for field access. The e2e test (`test/golfsim.e2e.test.ts`) exercises `bookingsConfirm` live through this surface.

---

## Two test surfaces, on purpose

```sh
mise exec zig@0.16.0 -- zig build test              # in-process, no socket
cd frontend && ../../../scripts/zigapagos.sh validate --format=json && ./build.sh && ../../../scripts/zigapagos.sh doctor dist --format=json && cd ..
mise exec node@24 -- npm install && npm run test:e2e # real server, real generated client
```

`zig build test` uses [`zigbase.testing`](../../docs/testing.md): it boots this app
against a throwaway data directory and injects requests through the real router, access
rules, auth, and hooks — no port, no background threads, milliseconds per test. It covers
the business logic that makes golfsim "the hard parts" example: `prepareBooking`'s
computed `price_total`, forced `status = "pending"`, server-stamped `guest`, and
double-booking rejection; `prepareReview`'s ownership + confirmed-only gate;
`confirmBooking`'s multi-hop owner check and the `bookings_frozen` kill switch;
`cancelBooking`'s guest-only guard; `listingAvailability`'s cancelled-booking filter;
`prepareHold`'s frozen-clock TTL stamp; the `POST /api/holds/:id/convert` atomic
`ctx.txWith` conversion; per-device sessions (list/revoke/logout-everywhere); and the
`require_verified` login gate. It also proves reproducibility directly: booting the same
app twice with the same `.fake_seed` + `.fake_now_unix` produces byte-identical generated
ids and hook-derived timestamps — the in-process equivalent of the `ZIGBASE_FAKE_NOW` /
`ZIGBASE_FAKE_SEED` env vars a spawned server reads. **This is how you should test your
own app's business logic.**

Because `.static_files = .{ .dir = "frontend/dist" }` is comptime-hardcoded (not the
`--serve-static` flag blog uses), golfsim's app refuses to boot — including the
socketless boot `zig build test` uses — unless `frontend/dist` already exists. Build the
frontend once before running the in-process suite (see the command above); CI does the
same right before its `zig build test` step.

The vitest suite (`test/`) covers what an in-process test structurally cannot, and now
covers ONLY that: it spawns the real binary and drives the **generated typed client**
(`clients/typescript/zbase.gen.ts`) over a real HTTP + WebSocket socket, so it's the only
surface that exercises the codegen output itself — typed `zb.db.<collection>.*` CRUD,
typed `expand`, and typed `zb.rpc.*` custom-route calls including the session-management
RPCs — plus one thing the in-process harness structurally cannot observe: the
booking-confirmation webhook. `confirmBooking` offloads that webhook via
`ctx.app.submit` onto the background worker pool, and `zigbase.testing`'s socketless
`bootForTest` deliberately never starts that pool (it boots just far enough to route a
request, not to serve) — so under `zig build test`, `ctx.app.submit` always returns
`error.SchedulerUnavailable`, which the route swallows (logged, not surfaced), and the
webhook silently never fires. Verifying it actually POSTs needs a real spawned server
with a real worker pool, which is exactly what `golfsim.determinism.e2e.test.ts` now
exists to do — everything else that file used to cover (the frozen-clock hold-expiry
stamp, the atomic hold→booking conversion) moved to the in-process suite, which
reproduces both more precisely and without a port. Keep both suites; neither implies
the other.

---

## Auth & onboarding

`golfsim` uses `require_verified = true` on the `users` collection: a guest must
have a verified email before a session is minted. This is appropriate for a
booking/payments app — unverified accounts cannot hold time slots.

### Onboarding flow (new users)

1. **Sign up** — email + password via the login card on the home page.
   (API: `POST /api/collections/users/records`)
2. **Verify email** — a verification token is emailed (dev: printed to the server log
   by the default LogMailer). Paste it into the "Verify your account" input.
   (API: `POST /api/collections/users/confirm-verification`)
3. **Sign in** — password login now succeeds, or use OTP for future logins.

### OTP passwordless login (returning verified users)

Once verified, users may sign in with a one-time code instead of their password:

1. Enter email → "Send one-time code".
   (API: `POST /api/collections/users/auth/otp/initiate`)
2. Enter the 6-digit code from the email (dev: server log). Valid for 5 minutes.
   (API: `POST /api/collections/users/auth/otp/complete`)

`auto_create = false` means OTP will NOT create new accounts — it is a convenience
for existing, verified users only. First-time onboarding always uses password signup.

### OAuth2 — Sign in with Google

Google OAuth2 is declared at comptime and enabled when environment credentials are set:

```sh
export ZIGBASE_OAUTH_GOOGLE_CLIENT_ID=<your_client_id>
export ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET=<your_client_secret>
```

Google-verified accounts are created with `verified=true` and can book immediately,
bypassing the email-verification step. This flow is **not exercised in CI** (it
requires live Google credentials).

To test locally:
1. Create a Google OAuth2 client in GCP (Web application type).
2. Add `http://localhost:8090/api/oauth2/google/callback` as an authorized redirect URI.
3. Set the env vars above and restart the binary.
4. The "Sign in with Google" button on the login card will redirect to Google.

### Auth lifecycle hooks

`golfsim` demonstrates two auth lifecycle hooks:

- **`beforeAuthSuccess` / `bumpLoginCount`** — runs *inside* the login transaction, after
  credentials are verified but before the session is issued. It reads the current
  `loginCount` off `ev.record` and increments it via `ctx.records().update(...)`, then logs
  the auth method as a lightweight audit trail. The write commits atomically with the
  session — returning an error here rolls it back AND blocks the login. Since auth round 2
  (0.10.0) this hook also fires on the legacy `/auth-with-password` and `/auth-refresh`
  endpoints, so `ev.method` can be `.password`, `.refresh`, or any other enabled method —
  one hook covers every session-issuing path.
- **`.auth.hooks.beforeRegister` / `seedNewUser`** — runs inside the account-create
  transaction before the row is inserted. Seeds `loginCount = 0` so the field is
  initialized at signup rather than only on the first login. Returning an error aborts
  registration entirely (the canonical hook for gating sign-ups).

The custom `POST /api/golfsim/logout` route returns `ctx.auth().clearSession()` — a
single line that builds and returns the cleared `zb_auth`/`zb_csrf` cookies, matching
the built-in `/auth-logout` behavior exactly without any extra logic.

### Comptime indexes

Two indexes are provisioned at startup via comptime `.indexes`:

- **`idx_users_email_nocase`** — unique, `COLLATE NOCASE` on `users.email`. Prevents
  `Bob@x.com` and `bob@x.com` from being treated as distinct accounts.
- **`idx_bookings_listing_time_active`** — composite `(listing, starts_at)` with
  `WHERE status != 'cancelled'`. Backs the double-booking overlap check
  (`prepareBooking`) and the availability route — only active bookings are indexed,
  so availability queries are O(active bookings per listing).

---

## Building and running

```sh
# 1. Validate and build the pinned Zigapagos v0.4.0 frontend
cd frontend
../../../scripts/zigapagos.sh validate --format=json
./build.sh
../../../scripts/zigapagos.sh doctor dist --format=json
cd ..

# 2. Build the backend
mise exec zig@0.16.0 -- zig build          # -> ./zig-out/bin/golfsim

# 3. Create a superuser (optional — admin UI at /_/)
./zig-out/bin/golfsim superuser create --email you@example.com --password "<pw>" --data-dir ./data

# 4. Run
# --insecure-cookies: local dev over plain HTTP (auth cookies are Secure by default).
# The frontend is served from this same binary, so its live-bookings WebSocket is
# same-origin and allowed by default — no --realtime-origins needed.
# A random JWT secret is generated + persisted at data/.jwt_secret on first run.
./zig-out/bin/golfsim serve --insecure-cookies --data-dir ./data
# open http://127.0.0.1:8090/  — frontend served automatically, no --serve-static flag
```

The collections provision themselves at startup. A quick smoke:

```sh
curl -s http://127.0.0.1:8090/api/golfsim/health
# -> {"status":"ok","app":"golfsim"}
```

### Seeding demo data offline — `zigbase import`

`serve` is not the only way to load records. The built-in `import` subcommand bulk-loads
NDJSON (one JSON object per line) **offline — no running server — through the record engine**,
so every row still gets field validation, defaults, the `.encrypted` envelope, and (for auth
collections) password hashing. It also **preserves each row's `id`**, which is exactly what
relation integrity needs: seed the owners first, then the rows that reference them by id.

```sh
# Provision the schema without serving (import also boots + provisions, but this is explicit):
./zig-out/bin/golfsim migrate --data-dir ./data

# 1. Seed the host accounts (auth collection): passwords are hashed, tokenKey generated.
#    `verified` is NOT trusted from the file — import always forces verified=false, so these
#    demo hosts must verify their email before they can log in (the security model holds).
./zig-out/bin/golfsim import --collection users      --data-dir ./data seed/users.ndjson

# 2. Seed simulators that reference those preserved user ids as their owner.
./zig-out/bin/golfsim import --collection simulators --data-dir ./data seed/simulators.ndjson
# -> info: import complete: 3 created, 0 updated, 3 total (collection 'simulators')

# Re-running is easy to make idempotent with --upsert-key (match on a unique field):
#   ./zig-out/bin/golfsim import --collection simulators --upsert-key label --data-dir ./data seed/simulators.ndjson
```

Pipe from stdin with `-` (e.g. `cat dump.ndjson | ./zig-out/bin/golfsim import --collection simulators - `).
See `docs/framework.md` → "Offline bulk import" for the full flag/semantics reference.

## Using ZigBase in your own project

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

```zig
const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zigbase.module("zigbase"));
```

Your executable module must `.link_libc = true` (SQLite needs libc).
