# Tutorial: build an app on ZigBase, end to end

> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/tutorial> — the site is the canonical reading experience.

This walkthrough takes you from an empty database to a working backend for
**"Airbnb for golf simulators"** — hosts list simulators, guests book slots. It ties
together every moving part: provisioning collections, setting access rules,
registering and logging in a user, creating a record with a file upload, a custom
business route, and a scheduled job.

It is meant to be read top to bottom and run as you go. Each step links to the
reference docs for depth:

- field types & option shapes → [fields.md](fields.md)
- the full curl recipes this tutorial condenses → [recipes.md](recipes.md)
- endpoint envelopes, rule semantics, realtime, files → [api.md](api.md)
- hooks, custom routes, jobs (the Zig framework) → [framework.md](framework.md)

---

## 0. Run the server

Build the binary and create a superuser (collection management is superuser-only),
then start serving:

```sh
mise install                                     # Zig 0.16.0, pinned in mise.toml
zig build                                         # -> zig-out/bin/zigbase
./zig-out/bin/zigbase superuser create --email admin@example.com --password "a-strong-password" --data-dir ./zb_data
ZIGBASE_JWT_SECRET="$(head -c 32 /dev/urandom | base64)" ./zig-out/bin/zigbase serve --data-dir ./zb_data
```

The server listens on `http://127.0.0.1:8090`. Sanity check:

```sh
curl http://127.0.0.1:8090/api/health   # {"status":"ok"}
```

Throughout, `BASE=http://127.0.0.1:8090`.

---

## 1. Provision collections (in dependency order)

There is no schema-file import — you create collections by calling
`POST /api/collections` as the superuser. Relation fields point at their target by
**collection id** (the `id` from the create response, **not** the name — see
[fields.md → the relation gotcha](fields.md#critical-targetcollectionid-is-an-id-not-a-name)),
so you must create targets first and **capture each returned id**.

First, log in as the superuser. Superusers live in the built-in `_superusers` auth
collection, so they use the normal auth endpoint:

```sh
TOKEN=$(curl -s -X POST "$BASE/api/collections/_superusers/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d '{"identity":"admin@example.com","password":"a-strong-password"}' | jq -r .token)
```

Create `users` (auth) and capture its id:

```sh
USERS_ID=$(curl -s -X POST "$BASE/api/collections" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{
    "name": "users",
    "type": "auth",
    "fields": [ { "id": "f_name", "name": "name", "type": "text", "options": { "max": 100 } } ],
    "listRule": "", "viewRule": "",
    "createRule": "",
    "updateRule": "@request.auth.id = id",
    "deleteRule": "@request.auth.id = id"
  }' | jq -r .id)
```

Then `simulators` (references `users` by id), then `listings` (references
`simulators`). The full four-collection script — including `bookings` — is in
[recipes.md → Provisioning your schema](recipes.md#recipe-provisioning-your-schema).
Here is `listings`, which also carries a `file` field for photos:

```sh
SIMS_ID=$(curl -s -X POST "$BASE/api/collections" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{
    \"name\": \"simulators\", \"type\": \"base\",
    \"fields\": [
      { \"id\": \"f_label\", \"name\": \"label\", \"type\": \"text\", \"required\": true, \"options\": { \"min\": 1 } },
      { \"id\": \"f_owner\", \"name\": \"owner\", \"type\": \"relation\", \"required\": true,
        \"options\": { \"targetCollectionId\": \"$USERS_ID\", \"cascadeDelete\": true, \"maxSelect\": 1 } }
    ],
    \"listRule\": \"\", \"viewRule\": \"\",
    \"createRule\": \"@request.auth.id != \\\"\\\"\",
    \"updateRule\": \"@request.auth.id = owner\",
    \"deleteRule\": \"@request.auth.id = owner\"
  }" | jq -r .id)

LISTINGS_ID=$(curl -s -X POST "$BASE/api/collections" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{
    \"name\": \"listings\", \"type\": \"base\",
    \"fields\": [
      { \"id\": \"f_title\", \"name\": \"title\", \"type\": \"text\", \"required\": true, \"options\": { \"min\": 1, \"max\": 140 } },
      { \"id\": \"f_price\", \"name\": \"price_per_hour\", \"type\": \"number\", \"required\": true,
        \"options\": { \"mode\": \"fixed\", \"scale\": 2, \"min\": 0 } },
      { \"id\": \"f_status\", \"name\": \"status\", \"type\": \"select\", \"required\": true,
        \"options\": { \"values\": [\"draft\", \"published\", \"archived\"], \"maxSelect\": 1 } },
      { \"id\": \"f_sim\", \"name\": \"simulator\", \"type\": \"relation\", \"required\": true,
        \"options\": { \"targetCollectionId\": \"$SIMS_ID\", \"cascadeDelete\": true, \"maxSelect\": 1 } },
      { \"id\": \"f_photos\", \"name\": \"photos\", \"type\": \"file\",
        \"options\": { \"maxSelect\": 6, \"maxSize\": 5242880, \"mimeTypes\": [\"image/png\", \"image/jpeg\"] } }
    ],
    \"listRule\": \"status = \\\"published\\\"\",
    \"viewRule\": \"status = \\\"published\\\" || @request.auth.id = simulator.owner\",
    \"createRule\": \"@request.auth.id != \\\"\\\"\",
    \"updateRule\": \"@request.auth.id = simulator.owner\",
    \"deleteRule\": \"@request.auth.id = simulator.owner\"
  }" | jq -r .id)
```

The field shapes used here are catalogued in [fields.md](fields.md).

---

## 2. Understand the access rules you just set

Each collection's five rules (`listRule`/`viewRule`/`createRule`/`updateRule`/
`deleteRule`) are filter expressions; `""` means public, `null` means
superuser-only, anything else is checked per request. Highlights from above:

- `users`: `createRule: ""` → **open signup** (anyone may create a user). Update/
  delete are self-only (`@request.auth.id = id`).
- `simulators`/`listings`: writes are **owner-scoped**
  (`@request.auth.id = simulator.owner`), which uses **relation traversal** —
  following the single-value `simulator` relation to read the owner.
- `listings` are publicly listable only when `status = "published"`; the owner can
  also view their drafts.

Rule grammar and denial status codes are in
[api.md → Access rules](api.md#access-rules); owner-scoped and relation-traversal
patterns (and how the `owner` field gets set safely) are in
[recipes.md → Owner-scoped access rules](recipes.md#recipe-owner-scoped-access-rules).

---

## 3. Register a user and log in

Signup is a **record create on the `users` auth collection** (there is no separate
register endpoint). The server hashes the password, strips the plaintext, sets
`verified=false`, and mints a token key:

```sh
curl -s -X POST "$BASE/api/collections/users/records" \
  -H 'Content-Type: application/json' \
  -d '{"email":"host@example.com","password":"hostpassword","name":"Demo Host"}'
```

`password` must be at least `minPasswordLength` (default 8). Now log in to get a
token and the user's id:

```sh
LOGIN=$(curl -s -X POST "$BASE/api/collections/users/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d '{"identity":"host@example.com","password":"hostpassword"}')
HOST_TOKEN=$(echo "$LOGIN" | jq -r .token)
HOST_ID=$(echo "$LOGIN"   | jq -r .record.id)
```

Details: [recipes.md → User registration](recipes.md#recipe-user-registration-signup)
and [api.md → Auth](api.md#auth).

---

## 4. Create records, including a file upload

Create a simulator the host owns:

```sh
SIM_ID=$(curl -s -X POST "$BASE/api/collections/simulators/records" \
  -H "Authorization: Bearer $HOST_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"label\":\"Bay 1 — TrackMan\",\"owner\":\"$HOST_ID\"}" | jq -r .id)
```

Now create a listing **with a photo upload**. A `file` field is populated via
`multipart/form-data`: send the non-file fields as form fields and the file under the
field's name (`photos`). With `curl`, use `-F`:

```sh
curl -s -X POST "$BASE/api/collections/listings/records" \
  -H "Authorization: Bearer $HOST_TOKEN" \
  -F "title=Sunset Tee Times" \
  -F "price_per_hour=45.00" \
  -F "status=published" \
  -F "simulator=$SIM_ID" \
  -F "photos=@./bay1.jpg;type=image/jpeg"
```

The uploaded file is stored locally and served from
`GET /api/files/listings/:recordId/:filename`. Because `listings` has a public
`viewRule` for published rows, the photo serves directly; protected collections need
a bearer token, the auth cookie, or a short-lived **file token**. See
[api.md → Files](api.md#files).

---

## 5. Add a custom business route (the Zig framework)

REST CRUD covers most needs, but "confirm a booking" is business logic. ZigBase is an
**embeddable Zig framework**: import it, register a custom route, and your binary
*is* the server. A `POST /api/bookings/:id/confirm` handler reads the `:id` path
param, loads the record, and flips its status:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

fn confirmBooking(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    const a = ev.ctx.allocator;
    const id = ev.ctx.param("id") orelse
        return .{ .status = 404, .body = "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}" };

    const w = ev.app.pool.acquireWriter();
    defer ev.app.pool.releaseWriter();
    const data = zigbase.Data{ .app = ev.app, .conn = w, .io = ev.app.io };

    var patch: std.json.ObjectMap = .empty;
    try patch.put(a, "status", .{ .string = "confirmed" });
    const updated = (try data.update("bookings", id, .{ .object = patch })) orelse
        return .{ .status = 404, .body = "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}" };

    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(a, updated, .{}) };
}
```

`RouteEvent` gives you `app`, `ctx` (path params via `ctx.param`), and `rctx` (auth
identity for finer authorization). It does **not** carry a `Data` facade, so you build
one from the pool. The full version (with owner authorization) is in
[recipes.md → custom business route](recipes.md#recipe-a-custom-business-route-with-a-path-param--db-write).

---

## 6. Add a scheduled job

A nightly job cancels stale pending bookings. A `JobEvent` carries only `app` and
`name`, so — like the route above — you acquire a connection and build `Data`:

```zig
fn expireStaleBookings(ev: *zigbase.events.JobEvent) anyerror!void {
    const a = ev.app.allocator;
    const w = ev.app.pool.acquireWriter();
    defer ev.app.pool.releaseWriter();
    const data = zigbase.Data{ .app = ev.app, .conn = w, .io = ev.app.io };

    const stale = try data.list("bookings", .{ .filter = "status = \"pending\"", .perPage = 200 });
    for (stale.items) |item| {
        const bid = item.object.get("id").?.string;
        var patch: std.json.ObjectMap = .empty;
        try patch.put(a, "status", .{ .string = "cancelled" });
        _ = try data.update("bookings", bid, .{ .object = patch });
    }
}
```

---

## 7. Wire it all into your `App(.{...})`

The hook, route, and job come together in one comptime config. This is the whole
extended server:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

// ... confirmBooking, expireStaleBookings, validateBooking defined above ...

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{
            .bookings = .{ .beforeCreate = validateBooking }, // overlap check + computed field
        },
        .routes = .{
            .{ .method = .POST, .path = "/api/bookings/:id/confirm", .handler = confirmBooking, .auth = .authed },
        },
        .jobs = .{ .pool_size = 2 },
        .cron = .{
            .{ .name = "expire-bookings",
               .schedule = zigbase.schedule.Schedule{ .cron = "0 3 * * *" },
               .handler = expireStaleBookings },
        },
    }).runCli(init);
}
```

`runCli` gives your binary the same `serve` / `migrate` / `superuser create` / `help`
commands as the stock server. A misconfigured extension (unknown config key, typo'd
hook phase, wrong-typed handler) is a **compile error**, so it never reaches runtime.

Build and run your binary exactly as in step 0 (it replaces `zig-out/bin/zigbase`).
The `validateBooking` before-hook is shown in full in
[recipes.md → computed-field / validation hook](recipes.md#recipe-a-computed-field--validation-beforecreate-hook).

---

## Where to go next

- **Field reference:** every type and option → [fields.md](fields.md)
- **More recipes:** provisioning, owner rules, hooks, routes, jobs →
  [recipes.md](recipes.md)
- **API reference:** records query (`filter`/`sort`/`expand`), realtime, files →
  [api.md](api.md)
- **Framework reference:** the full hook/route/job/event surface →
  [framework.md](framework.md)
- **The worked, buildable example:** [`examples/blog/`](../examples/blog/)
- **Caveats:** [KNOWN_LIMITATIONS.md](../KNOWN_LIMITATIONS.md)
</content>
