# ZigBase golfsim example — a realistic app

"**Airbnb for golf simulators**": hosts list golf simulators, guests book time
slots. This is the **realistic** counterpart to [`examples/blog`](../blog) — where
the blog example is a bare packaging proof (one slug hook, a literal ping route, a
log-only cron), `golfsim` exercises the **hard parts** of building a real backend on
ZigBase *as a library*:

1. **A computed + validating `before_create` hook on `bookings`.** It reads
   **related** data (the target listing) through `ev.data`, **rejects** invalid
   input (a 400 to the client), stamps a server-authoritative `guest` from the
   authenticated identity, and **computes** a derived `price_total` = booked hours ×
   the listing's `price_per_hour`.
2. **A custom business route** `POST /api/bookings/:id/confirm` (auth required). It
   reads the `:id` path param, loads the booking from the DB, flips its `status` to
   `"confirmed"`, and returns the updated record as JSON — or **404** when the
   booking does not exist.
3. **A DB-touching interval cron job** `expire-holds` (every 15 minutes). It opens a
   `Data` from the connection pool, lists stale **pending** holds whose slot has
   already started, and marks them `"cancelled"`.
4. **A public smoke route** `GET /api/golfsim/health` returning a small JSON literal.

Everything else (HTTP API, SQLite storage, auth, file storage, the admin UI, the
CLI) comes straight from the framework via the public `zigbase.*` exports.

> **Pre-1.0:** ZigBase is pre-1.0 — the hook/route/job config shapes and the module
> API may change between releases.

## What each feature looks like

### 1. The computed + validating hook (`before_create` on `bookings`)

```zig
fn prepareBooking(ev: *zigbase.RecordEvent) anyerror!void {
    const rec = &ev.record.object;
    const listing_id = /* read the `listing` relation id from rec */;

    // Read RELATED data through the curated facade; reject if it's not bookable.
    const listing = (try ev.data.findById("listings", listing_id)) orelse return error.ListingNotFound;

    // COMPUTE a derived field — note: mutations allocate with ev.arena, NOT ev.app.allocator.
    const price_total = hours * rate;
    try rec.put(ev.arena, "price_total", .{ .float = price_total });

    // Stamp the guest from the authenticated identity (server-authoritative).
    try rec.put(ev.arena, "guest", .{ .string = guest_id });
    try rec.put(ev.arena, "status", .{ .string = "pending" });
}
```

Returning an error from a `before_create` hook **rejects** the write → the client
gets a `400`. Record mutations **must** allocate with `ev.arena` (the request-scoped
allocator that owns `ev.record`), never `ev.app.allocator`.

### 2. The business route (path param + DB write)

```zig
fn confirmBooking(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    const id = ev.ctx.param("id") orelse return .{ .status = 400, .body = "..." };

    // RouteEvent carries no `Data` — build one from the pool (acquire/release the writer).
    const conn = ev.app.pool.acquireWriter();
    defer ev.app.pool.releaseWriter();
    const data = zigbase.Data{ .app = ev.app, .conn = conn, .io = ev.app.io };

    _ = (try data.findById("bookings", id)) orelse return .{ .status = 404, .body = "..." };
    const updated = (try data.update("bookings", id, /* { "status": "confirmed" } */)).?;
    const body = try std.json.Stringify.valueAlloc(ev.ctx.allocator, updated, .{});
    return .{ .status = 200, .body = body };
}
```

The route is registered with `.auth = .authed`, so the framework enforces
authentication before the handler runs.

### 3. The DB-touching cron job

```zig
fn expireHolds(ev: *zigbase.events.JobEvent) anyerror!void {
    const conn = ev.app.pool.acquireWriter();
    defer ev.app.pool.releaseWriter();
    const data = zigbase.Data{ .app = ev.app, .conn = conn, .io = ev.app.io };

    const stale = data.list("bookings", .{
        .filter = "status = \"pending\" && starts_at < @now",
        .perPage = 200,
    }) catch |err| switch (err) {
        error.UnknownCollection => return, // no-op until provisioning runs
        else => return err,
    };
    for (stale.items) |item| _ = try data.update("bookings", /* item.id */, /* cancelled */);
}
```

This is the pattern for **real DB access inside a background job**: acquire the
pooled writer, wrap it in a `Data`, and release on exit.

## Handler signatures (the contract)

| Feature | Signature |
| --- | --- |
| record hook | `fn(*zigbase.RecordEvent) anyerror!void` |
| custom route | `fn(*zigbase.RouteEvent) anyerror!zigbase.http.Response` |
| cron job | `fn(*zigbase.events.JobEvent) anyerror!void` |

`Data` from the pool: `zigbase.Data{ .app = ev.app, .conn = ev.app.pool.acquireWriter(), .io = ev.app.io }`
(with `defer ev.app.pool.releaseWriter();`).

## Provisioning the collections

The hook, route and cron reference the collections **by name** (`users` /
`simulators` / `listings` / `bookings`); until those collections exist they are
harmless no-ops, which is fine for a compiling example. Provision them at runtime by
calling `POST /api/collections` as a superuser, **in dependency order**, capturing
each new collection's `id` to wire the relation fields.

The canonical, copy-pasteable provisioning script lives in
[`docs/recipes.md` → "provisioning your schema"](../../docs/recipes.md). It creates
`users` (auth) → `simulators` → `listings` → `bookings`, wiring relations by id and
seeding a demo host. The shapes this example assumes:

- `listings`: `title` (text), `price_per_hour` (number), `status`
  (select: `draft`/`published`/`archived`), `simulator` (relation), and
  **`photos` (file** — listing photos, `image/png`/`jpeg`/`webp`).
- `bookings`: `listing` (relation), `guest` (relation), `starts_at`/`ends_at`
  (date), `status` (select: `pending`/`confirmed`/`cancelled`).

> The **`photos` file field** on `listings` is provisioned via the API (see the
> recipe) — file storage itself is provided by the framework; this example does not
> need any extra code to support uploads.

A quick smoke once the server is up:

```sh
curl -s http://127.0.0.1:8090/api/golfsim/health
# -> {"status":"ok","app":"golfsim"}
```

## Using ZigBase in your own project

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

```zig
const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zigbase.module("zigbase"));
```

Your executable module must `.link_libc = true` (SQLite needs libc).

## Building and running

From `examples/golfsim/`:

```sh
mise exec zig@0.16.0 -- zig build           # produces ./zig-out/bin/golfsim
./zig-out/bin/golfsim superuser create --email you@example.com --password "<pw>" --data-dir ./data
ZIGBASE_JWT_SECRET="$(head -c 32 /dev/urandom | base64)" \
  ./zig-out/bin/golfsim serve --data-dir ./data
```

Then provision the collections (recipe above), register a guest, create a
`published` listing, and `POST /api/collections/bookings/records` — the hook fills in
`guest`, `status` and `price_total`; `POST /api/bookings/:id/confirm` flips it to
`confirmed`; and the `expire-holds` cron sweeps stale pending holds.
