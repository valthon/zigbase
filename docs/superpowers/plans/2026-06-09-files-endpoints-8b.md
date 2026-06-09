# File Storage Endpoints & Wiring (Plan 8b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete ZigBase file storage — multipart parsing on the record endpoints, the access-controlled file download endpoint + short-lived file-token endpoint, `sendFile` streaming, and the multipart-aware record create/update/delete — then a holistic security review and merge of SP8 (8a+8b) to `main`.

**Architecture:** A pure `planAllFileFields` (in `files/plan.zig`) turns the parsed form data + uploaded parts into the record data + a list of files to write/delete, reusing 8a's `planFileField`. `files/multipart.zig` (zap glue) extracts neutral `{form_fields, files}` from a request; `server.zig` fills the ctx on multipart bodies and streams file responses via `sendFile`. `api/records.zig` orchestrates create/update/delete with `Storage`; `api/files.zig` serves files (cookie/bearer/file-token access, `viewRule`-enforced) and mints file tokens.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 -- zig <args>`; bare `zig` is 0.15.2). zap multipart (`parametersToOwnedList`) + `sendFile`. Builds on Plan 8a (branch `files`).

**Build/test:** `mise exec zig@0.16.0 -- zig build test --summary all` **and** `mise exec zig@0.16.0 -- zig build` (the binary — `zig build test` does not analyze unreferenced `pub fn` bodies; this bit SP7).

**Branch:** Continue on `files`. SP8 merges as a unit to `main` at the end of this plan (Task 6), after the holistic review.

**Spec:** `docs/superpowers/specs/2026-06-09-files-design.md`. **Prereq:** Plan 8a complete (203 tests green on `files`).

---

## Verified facts (zap v0.10.6 + current code — do not re-derive)

- **zap multipart:** after `try r.parseBody()`, `const list = try r.parametersToOwnedList(alloc);` → `list.items` of `HttpParamKV{ key: []const u8, value: ?HttpParam }`. `HttpParam` is a union: `.String: []const u8`, `.Int: isize`, `.Bool: bool`, `.Float: f64`, `.Hash_Binfile: HttpParamBinaryFile`, `.Array_Binfile: std.ArrayList(HttpParamBinaryFile)`, `.Unsupported`. `HttpParamBinaryFile{ data: ?[]const u8, mimetype: ?[]const u8, filename: ?[]const u8 }`. (Confirm `HttpParamKV` field names by reading `request.zig` if the build complains.)
- **zap serving:** `r.sendFile(path: []const u8) !void` (facil.io sets content-type from the path + streams via `sendfile()`); `r.setHeader(name, value) !void`; `r.setStatus(code)`.
- **`server.zig` `onRequest`** builds `ctx`, sets `authorization`/`cookie_header`/`csrf_token`, dispatches, then writes cookies + `setContentType(.JSON)` + `sendBody(resp.body)`. `Server.instance.?.app` is the `*App`.
- **`src/jwt.zig`:** `TokenType = enum { auth, verification, password_reset }`; `sign(alloc, claims, key)`; `Claims{ id, collection, type, csrf="", iat, exp }`; `peekClaims`.
- **`src/auth.zig`:** `verifyToken(alloc, app, conn, token) ?Verified` (hardcodes `type == .auth`); `Verified{ record, collection, is_superuser, exp }`; `authenticate(io, alloc, app, ctx, conn) !?Authed`; `Authed{ record, collection, is_superuser }`; `nowUnixPub(conn)`.
- **`src/api/auth.zig`:** `pub fn tokenKeyFor(alloc, conn, table, rid) !?[]const u8`. **`src/crypto.zig`:** `deriveKey(secret, tokenKey) [32]u8`.
- **`src/api/records.zig`:** `create`/`update`/`delete` handlers — `create` builds `data` from `ctx.body` JSON, has `app`/`col`/`rctx`, calls `records.create`/`createGuarded`, then `realtime_ws.broadcast(app, col, .create, id, rec)`, returns `jsonResponse(201, rec)`. `update` ends `const ur = updated orelse …; broadcast(...,.update,…); return jsonResponse(200, ur);`. `delete` does the existence/rule checks, `records.delete`, an `_externalAuths` cleanup (auth collections), `broadcast(...,.delete, rid, null)`, returns 204. `resolveCollection(ctx, w)`, `buildContext(ctx, w, data)`, `prepAuthData`, `jsonResponse`, `validationResponse`, `forbidden` exist.
- **`src/records.zig`:** `create(alloc, io, w, col, data) RecordError!Value`, `get(alloc, conn, col, id) RecordError!?Value`, `update(alloc, w, col, id, data) RecordError!?Value`, `delete(alloc, w, col, id) RecordError!bool`.
- **`src/schema.zig`:** `Collection.fields`; `field.options == .file`; `field.options.file = .{ maxSelect, maxSize, mimeTypes }`.
- **8a:** `files/plan.zig` (`planFileField`, `FieldPlan`, `PlannedWrite`, `PlanError`); `files/storage.zig` (`Storage`, `LocalStorage`); `files/naming.zig`; `files/mime.zig`. `App.storage: ?*const Storage`, `App.max_upload_size`, `App.file_token_ttl_s`. `http.UploadedFile`, `http.Header`, `Response.file_path`/`extra_headers`, `RequestCtx.content_type`/`form_fields`/`files`.
- **`src/router.zig`:** segment patterns with `:param`; `ctx.param(name)`.

---

## File Structure

- **Modify** `src/jwt.zig` — add `file` to `TokenType`.
- **Modify** `src/auth.zig` — generalize verify to accept a token-type set (`verifyTokenOfTypes`); `verifyToken` delegates.
- **Modify** `src/files/plan.zig` — add `planAllFileFields` (pure orchestration) + `FieldWrite`/`AllPlan`.
- **Create** `src/files/multipart.zig` — zap multipart → `{form_fields, files}`.
- **Modify** `src/server.zig` — multipart detection (fill ctx) + `sendFile`/`extra_headers` response path.
- **Modify** `src/api/records.zig` — multipart-aware create/update + `Storage.deleteRecord` on delete.
- **Create** `src/api/files.zig` — `GET /api/files/:col/:rec/:name` + `POST /api/files/token`.
- **Modify** `src/main.zig` — construct `LocalStorage` + assign `App.storage`; add modules to test root; routes via server.
- **Modify** `src/server.zig` — register the file routes.

---

### Task 1: `file` token type + generalized verify (`jwt.zig`, `auth.zig`)

**Files:** Modify `src/jwt.zig`, `src/auth.zig`.

- [ ] **Step 1: Write the failing test** (append to `src/auth.zig` tests; mirror the existing `verifyToken` test setup)

```zig
test "verifyTokenOfTypes accepts a file token only when allowed" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
    try d.exec("INSERT INTO \"users\" (\"id\",\"created\",\"updated\",\"email\",\"tokenKey\",\"verified\") VALUES ('rec1','','','u@x.io','tk',1);");
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined };
    const key = crypto.deriveKey(app.jwt_secret, "tk");
    const file_tok = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .file, .iat = 0, .exp = 9999999999 }, &key);
    // verifyToken (auth-only) rejects a file token
    try std.testing.expect(verifyToken(a, &app, &d, file_tok) == null);
    // verifyTokenOfTypes allows it when .file is in the set
    try std.testing.expect(verifyTokenOfTypes(a, &app, &d, file_tok, &.{ .auth, .file }) != null);
    // and still rejects a wrong-key one
    const wrong = crypto.deriveKey(app.jwt_secret, "other");
    const bad = try jwt.sign(a, .{ .id = "rec1", .collection = "users", .type = .file, .iat = 0, .exp = 9999999999 }, &wrong);
    try std.testing.expect(verifyTokenOfTypes(a, &app, &d, bad, &.{ .auth, .file }) == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `.file` not a `TokenType`; `verifyTokenOfTypes` undefined.

- [ ] **Step 3: Add `file` to `jwt.TokenType`**

Change `pub const TokenType = enum { auth, verification, password_reset };` to:

```zig
pub const TokenType = enum { auth, verification, password_reset, file };
```

- [ ] **Step 4: Generalize the verify in `src/auth.zig`**

Replace the `verifyToken` function body so the type check is parameterized. The current `verifyToken` checks `if (claims.type != .auth) return null;`. Refactor into:

```zig
pub fn verifyToken(alloc: std.mem.Allocator, app: anytype, conn: *db.Db, token: []const u8) ?Verified {
    return verifyTokenOfTypes(alloc, app, conn, token, &.{.auth});
}

/// Like verifyToken but accepts any of `types` for the claim's `type`. Used by the file endpoint
/// (which accepts `.auth` and `.file`); the main API uses verifyToken (`.auth` only).
pub fn verifyTokenOfTypes(alloc: std.mem.Allocator, app: anytype, conn: *db.Db, token: []const u8, types: []const jwt.TokenType) ?Verified {
    const claims = jwt.peekClaims(alloc, token) catch return null;
    var ok = false;
    for (types) |t| if (claims.type == t) { ok = true; break; };
    if (!ok) return null;
    const is_super = std.mem.eql(u8, claims.collection, "_superusers");
    const table = if (is_super) "_superusers" else blk: {
        const col = (collections.get(alloc, conn, claims.collection) catch return null) orelse return null;
        break :blk col.name;
    };
    const tk = (tokenKeyFor(alloc, conn, table, claims.id) catch return null) orelse return null;
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const now = nowUnix(conn) catch return null;
    _ = jwt.verify(alloc, token, &key, now) catch return null;
    const rec = if (is_super)
        (superuserRecord(alloc, conn, claims.id) catch return null) orelse return null
    else blk: {
        const col = (collections.get(alloc, conn, claims.collection) catch return null) orelse return null;
        const records = @import("records.zig");
        break :blk (records.get(alloc, conn, col, claims.id) catch return null) orelse return null;
    };
    return .{ .record = rec, .collection = claims.collection, .is_superuser = is_super, .exp = claims.exp };
}
```

(This preserves `verifyToken`'s exact behavior — `&.{.auth}` — so all existing callers/tests are unchanged. `tokenKeyFor`/`nowUnix`/`superuserRecord` already exist.)

- [ ] **Step 5: Run + commit**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` → PASS.

```bash
git add src/jwt.zig src/auth.zig
git commit -m "feat(files): file token type + verifyTokenOfTypes"
```

---

### Task 2: `planAllFileFields` orchestration (`files/plan.zig`)

**Files:** Modify `src/files/plan.zig`.

Pure: turn the form data + uploaded parts into the final record data + the files to write/delete, by running `planFileField` for each `file` field. The `<field>-` removal control comes as a form field whose value is a JSON array of filenames (or a single filename string) — robust within zap's param model (repeated text params don't reliably array).

- [ ] **Step 1: Write the failing tests** (append to `src/files/plan.zig` tests)

```zig
const schema2 = schema; // alias for clarity in tests

fn collWithFile(name: []const u8, max_select: u32) schema.Collection {
    const S = struct {
        var fields: [1]schema.Field = undefined;
    };
    S.fields[0] = fileField(name, max_select, null, null);
    return .{ .id = "c", .name = "posts", .fields = &S.fields };
}

test "planAllFileFields create: sets file fields, collects writes, drops control keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "hi" });
    const col = collWithFile("cover", 1);
    const ups = [_]http.UploadedFile{upload("cover", "p.png", &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })};
    const all = try planAllFileFields(std.testing.io, a, col, .{ .object = data }, &ups, null);
    // title preserved, cover set to a stored name, one write
    try std.testing.expectEqualStrings("hi", all.data.object.get("title").?.string);
    try std.testing.expect(std.mem.endsWith(u8, all.data.object.get("cover").?.string, ".png"));
    try std.testing.expectEqual(@as(usize, 1), all.writes.len);
    try std.testing.expectEqual(@as(usize, 0), all.deletes.len);
}

test "planAllFileFields update multi: <field>- JSON array removes, uploads add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = collWithFile("docs", 5);
    var existing: std.json.ObjectMap = .empty;
    var ex = std.json.Array.init(a);
    try ex.append(.{ .string = "k1.txt" });
    try ex.append(.{ .string = "drop.txt" });
    try existing.put(a, "docs", .{ .array = ex });
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "docs-", .{ .string = "[\"drop.txt\"]" }); // remove control
    const ups = [_]http.UploadedFile{upload("docs", "n.txt", "N")};
    const all = try planAllFileFields(std.testing.io, a, col, .{ .object = data }, &ups, .{ .object = existing });
    const arr = all.data.object.get("docs").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len); // k1 + new
    try std.testing.expectEqualStrings("k1.txt", arr.items[0].string);
    try std.testing.expect(all.data.object.get("docs-") == null); // control key dropped
    try std.testing.expectEqual(@as(usize, 1), all.deletes.len);
    try std.testing.expectEqualStrings("drop.txt", all.deletes[0]);
}

test "planAllFileFields: non-file fields and absent file field are untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = collWithFile("cover", 1);
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "x" });
    const all = try planAllFileFields(std.testing.io, a, col, .{ .object = data }, &.{}, null);
    try std.testing.expectEqualStrings("x", all.data.object.get("title").?.string);
    try std.testing.expect(all.data.object.get("cover") == null); // unchanged/absent
    try std.testing.expectEqual(@as(usize, 0), all.writes.len);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `planAllFileFields` undefined.

- [ ] **Step 3: Implement — add to `src/files/plan.zig`**

```zig
const http2 = http; // (http already imported)

pub const FieldWrite = struct { filename: []const u8, bytes: []const u8 };

pub const AllPlan = struct {
    data: std.json.Value, // record data with file fields set, control keys removed
    writes: []const FieldWrite,
    deletes: []const []const u8,
};

fn parseRemovals(alloc: std.mem.Allocator, v: ?std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const val = v orelse return out.toOwnedSlice(alloc);
    switch (val) {
        .string => |s| {
            // try JSON array first; else a single filename
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch {
                if (s.len > 0) try out.append(alloc, s);
                return out.toOwnedSlice(alloc);
            };
            if (parsed.value == .array) {
                for (parsed.value.array.items) |it| if (it == .string) try out.append(alloc, it.string);
            } else if (s.len > 0) try out.append(alloc, s);
        },
        .array => |arr| for (arr.items) |it| if (it == .string) try out.append(alloc, it.string),
        else => {},
    }
    return out.toOwnedSlice(alloc);
}

/// Build the record data + the files to write/delete from the form `data` + uploaded `files`.
/// `existing` is the current record (for update) or null (create). Reuses `planFileField` per file
/// field. Drops the `<field>` raw value (overwritten) and the `<field>-` control key from the data.
pub fn planAllFileFields(
    io: std.Io,
    alloc: std.mem.Allocator,
    col: schema.Collection,
    data: std.json.Value,
    files: []const http.UploadedFile,
    existing: ?std.json.Value,
) PlanError!AllPlan {
    if (data != .object) return .{ .data = data, .writes = &.{}, .deletes = &.{} };

    // start with a shallow copy of the data
    var out: std.json.ObjectMap = .empty;
    var it = data.object.iterator();
    while (it.next()) |e| try out.put(alloc, e.key_ptr.*, e.value_ptr.*);

    var writes: std.ArrayList(FieldWrite) = .empty;
    var deletes: std.ArrayList([]const u8) = .empty;

    for (col.fields) |field| {
        if (field.options != .file) continue;
        // uploads for this field
        var ups: std.ArrayList(http.UploadedFile) = .empty;
        for (files) |f| if (std.mem.eql(u8, f.field, field.name)) try ups.append(alloc, f);
        // removals from "<field>-"
        const minus_key = try std.fmt.allocPrint(alloc, "{s}-", .{field.name});
        const removals = try parseRemovals(alloc, data.object.get(minus_key));
        _ = out.swapRemove(minus_key); // drop control key from the record data

        const present = ups.items.len > 0 or data.object.get(minus_key) != null or data.object.get(field.name) != null;
        const ex_val: ?std.json.Value = if (existing) |x| (if (x == .object) x.object.get(field.name) else null) else null;

        const plan = try planFileField(io, alloc, field, ex_val, ups.items, removals, present);
        if (plan) |p| {
            try out.put(alloc, field.name, p.value);
            for (p.writes) |w| try writes.append(alloc, .{ .filename = w.filename, .bytes = w.bytes });
            for (p.deletes) |d| try deletes.append(alloc, d);
        } else {
            // unchanged: leave whatever was in data (likely nothing) — but a stray raw string for a
            // file field shouldn't be stored; if present and not set by a plan, drop it.
            if (ups.items.len == 0 and data.object.get(field.name) != null and existing == null)
                _ = out.swapRemove(field.name);
        }
    }

    return .{
        .data = .{ .object = out },
        .writes = try writes.toOwnedSlice(alloc),
        .deletes = try deletes.toOwnedSlice(alloc),
    };
}
```

Note: `std.json.ObjectMap` (`std.StringArrayHashMapUnmanaged(Value)`) has `swapRemove(key) bool`. If the method name differs in this std, use the available remove (`orderedRemove`/`swapRemove`/`remove`) — intent: delete the key.

- [ ] **Step 4: Run + commit**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` → PASS.

```bash
git add src/files/plan.zig
git commit -m "feat(files): planAllFileFields orchestration"
```

---

### Task 3: Multipart extraction + server wiring (`files/multipart.zig`, `server.zig`)

**Files:** Create `src/files/multipart.zig`; Modify `src/server.zig`, `src/main.zig`.

- [ ] **Step 1: Create `src/files/multipart.zig`**

```zig
const std = @import("std");
const zap = @import("zap");
const http = @import("../http.zig");

pub const Extracted = struct { form_fields: std.json.Value, files: []const http.UploadedFile };

/// Parse a multipart/form-data request into neutral form fields + uploaded files. Non-file params
/// become JSON values (string/int/bool/float); file parts become UploadedFile. All borrows from `alloc`.
pub fn extract(r: zap.Request, alloc: std.mem.Allocator) !Extracted {
    try r.parseBody();
    var fields: std.json.ObjectMap = .empty;
    var files: std.ArrayList(http.UploadedFile) = .empty;

    const list = try r.parametersToOwnedList(alloc);
    for (list.items) |kv| {
        const key = kv.key;
        const v = kv.value orelse continue;
        switch (v) {
            .String => |s| try fields.put(alloc, key, .{ .string = s }),
            .Int => |n| try fields.put(alloc, key, .{ .integer = @intCast(n) }),
            .Bool => |b| try fields.put(alloc, key, .{ .bool = b }),
            .Float => |f| try fields.put(alloc, key, .{ .float = f }),
            .Hash_Binfile => |bf| if (bf.data) |d|
                try files.append(alloc, .{ .field = key, .filename = bf.filename orelse "file", .mimetype = bf.mimetype orelse "", .bytes = d }),
            .Array_Binfile => |arr| for (arr.items) |bf| if (bf.data) |d|
                try files.append(alloc, .{ .field = key, .filename = bf.filename orelse "file", .mimetype = bf.mimetype orelse "", .bytes = d }),
            .Unsupported => {},
        }
    }
    return .{ .form_fields = .{ .object = fields }, .files = try files.toOwnedSlice(alloc) };
}
```

Register `_ = @import("files/multipart.zig");` in `src/main.zig` test root (no unit tests — it needs a live request — but keep it compiled).

- [ ] **Step 2: Wire multipart detection + the file-serving response path into `src/server.zig` `onRequest`**

Add the import: `const files_multipart = @import("files/multipart.zig");`.

After setting the header fields and **before** `router.dispatch`, add:

```zig
    ctx.content_type = r.getHeader("content-type") orelse "";
    if (std.mem.startsWith(u8, ctx.content_type, "multipart/form-data")) {
        if (files_multipart.extract(r, arena.allocator())) |ex| {
            ctx.form_fields = ex.form_fields;
            ctx.files = ex.files;
        } else |_| {}
    }
```

Replace the response tail (the `setZapStatus` … `setContentType(.JSON)` … `sendBody` block) so file responses stream and `extra_headers` are written:

```zig
    setZapStatus(r, resp.status);
    for (resp.cookies) |c| {
        r.setCookie(.{
            .name = c.name, .value = c.value, .path = c.path, .max_age_s = @intCast(c.max_age_s),
            .secure = c.secure, .http_only = c.http_only,
            .same_site = switch (c.same_site) { .default => .Default, .lax => .Lax, .strict => .Strict, .none => .None },
        }) catch {};
    }
    for (resp.extra_headers) |h| r.setHeader(h.name, h.value) catch {};
    if (resp.file_path) |path| {
        r.sendFile(path) catch {
            setZapStatus(r, 404);
            r.setContentType(.JSON) catch {};
            r.sendBody("{\"code\":404,\"message\":\"Not found.\",\"data\":{}}") catch {};
        };
        return;
    }
    r.setContentType(.JSON) catch {};
    r.sendBody(resp.body) catch {};
```

- [ ] **Step 3: Build (binary + tests)**

Run: `mise exec zig@0.16.0 -- zig build` (EXIT 0) **and** `mise exec zig@0.16.0 -- zig build test --summary all` (PASS).
If a zap type/field differs (`HttpParamKV` field names, `parametersToOwnedList`, `sendFile`/`setHeader` signatures), READ `zig-pkg/zap-*/src/request.zig` and adapt minimally. Report BLOCKED only if you can't compile.

- [ ] **Step 4: Commit**

```bash
git add src/files/multipart.zig src/server.zig src/main.zig
git commit -m "feat(files): multipart extraction + sendFile response path"
```

---

### Task 4: Multipart-aware record handlers (`api/records.zig`)

**Files:** Modify `src/api/records.zig`.

- [ ] **Step 1: Add imports + a helper** to `src/api/records.zig`:

```zig
const file_plan = @import("../files/plan.zig");
```

Add a helper (after the existing helpers like `prepAuthData`):

```zig
/// If this is a multipart request, compute the file plan and write the bytes for `record_id` via
/// Storage. On any write failure, deletes the just-written files (caller rolls back the record).
/// Returns the file data already merged (the caller used `plan.data` as the record data).
fn writeUploads(ctx: *http.RequestCtx, col: schema.Collection, record_id: []const u8, writes: []const file_plan.FieldWrite, deletes: []const []const u8) !void {
    const app = ctx.app.?;
    const storage = app.storage orelse return; // no storage configured -> nothing to write
    var written: usize = 0;
    for (writes) |w| {
        storage.put(app.io, col.name, record_id, w.filename, w.bytes) catch {
            // roll back the files we just wrote
            for (writes[0..written]) |dw| storage.delete(app.io, col.name, record_id, dw.filename) catch {};
            return error.StorageFailed;
        };
        written += 1;
    }
    // delete replaced/removed files (best-effort)
    for (deletes) |d| storage.delete(app.io, col.name, record_id, d) catch {};
}
```

- [ ] **Step 2: Make `create` multipart-aware.** Replace the top of `create` (the `data` derivation) so it uses `ctx.form_fields` for multipart, runs `planAllFileFields`, and writes files after the record exists. The new `create`:

```zig
pub fn create(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const is_multipart = ctx.form_fields != null;
    const raw = if (is_multipart) ctx.form_fields.? else (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
        return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator)).value;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);

    const all = file_plan.planAllFileFields(app.io, ctx.allocator, col, raw, ctx.files, null) catch |e| switch (e) {
        error.TooLarge => return (ApiError{ .status = 413, .message = "File too large." }).toResponse(ctx.allocator),
        error.TooMany => return ApiError.badRequest("Too many files for the field.").toResponse(ctx.allocator),
        error.BadMimeType => return ApiError.badRequest("File type not allowed.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
    const data = all.data;

    const data2 = prepAuthData(ctx, col, data, true) catch |e| switch (e) {
        error.BadPassword => return ApiError.badRequest("A password of the required length is required.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
    const rctx = buildContext(ctx, w, data);
    const rec = switch (rules.decide(col.createRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => records.create(ctx.allocator, app.io, w, col, data2),
        .check => records.createGuarded(ctx.allocator, app.io, w, col, data2, try rules.compileGuard(ctx.allocator, w, col, col.createRule.?, &rctx)),
    } catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.NotObject => return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator),
        error.Forbidden => return forbidden(ctx),
        else => return e,
    };
    const rid = rec.object.get("id").?.string;
    writeUploads(ctx, col, rid, all.writes, all.deletes) catch {
        _ = records.delete(ctx.allocator, w, col, rid) catch {};
        return ApiError.internal().toResponse(ctx.allocator);
    };
    realtime_ws.broadcast(app, col, .create, rid, rec);
    return jsonResponse(ctx, 201, rec);
}
```

- [ ] **Step 3: Make `update` multipart-aware.** Mirror the change: derive `raw` from `ctx.form_fields` or JSON; load the existing record (for `planAllFileFields`'s `existing`); run the plan; after `records.update` succeeds, `writeUploads`. The `update` handler already loads/gets the record for the rule check — reuse that. Concretely, where `update` currently derives `data` from `ctx.body`, replace with:

```zig
    const is_multipart = ctx.form_fields != null;
    const raw = if (is_multipart) ctx.form_fields.? else (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
        return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator)).value;
    // existing record (for file add/remove) — update already fetches it for the existence/rule check;
    // capture it as `existing` (a std.json.Value) before computing the plan:
    const existing = (records.get(ctx.allocator, w, col, rid) catch null);
    const all = file_plan.planAllFileFields(app.io, ctx.allocator, col, raw, ctx.files, existing) catch |e| switch (e) {
        error.TooLarge => return (ApiError{ .status = 413, .message = "File too large." }).toResponse(ctx.allocator),
        error.TooMany => return ApiError.badRequest("Too many files for the field.").toResponse(ctx.allocator),
        error.BadMimeType => return ApiError.badRequest("File type not allowed.").toResponse(ctx.allocator),
        error.OutOfMemory => return e,
    };
    const data = all.data;
```

Use `data` (instead of the old parsed body) for `prepAuthData`/`buildContext`/`records.update`. After the update succeeds and `ur` is bound, before the broadcast, add:

```zig
    writeUploads(ctx, col, ur.object.get("id").?.string, all.writes, all.deletes) catch {};
```

(READ the current `update` to splice these in without disturbing the rule/auth flow; `rid`/`col`/`w` are in scope. The existence check `records.get(...) == null → 404` stays; reuse that fetch for `existing` if convenient, or do the extra `get` shown above.)

- [ ] **Step 4: Delete cleanup.** In `delete`, after `records.delete` succeeds (and the existing `_externalAuths` cleanup + before/after `broadcast`), add:

```zig
    if (ctx.app.?.storage) |storage| storage.deleteRecord(ctx.app.?.io, col.name, rid) catch {};
```

- [ ] **Step 5: Build + run**

Run: `mise exec zig@0.16.0 -- zig build` (EXIT 0) and `mise exec zig@0.16.0 -- zig build test --summary all` (PASS — the existing JSON-body record tests still pass since `ctx.form_fields` is null for them and `planAllFileFields` returns the data unchanged when there are no file fields/uploads).

- [ ] **Step 6: Commit**

```bash
git add src/api/records.zig
git commit -m "feat(files): multipart-aware record create/update + delete cleanup"
```

---

### Task 5: File serving + token endpoints (`api/files.zig`, `server.zig`, `main.zig`)

**Files:** Create `src/api/files.zig`; Modify `src/server.zig`, `src/main.zig`.

- [ ] **Step 1: Create `src/api/files.zig`**

```zig
const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const rules = @import("../rules.zig");
const request = @import("../request.zig");
const auth = @import("../auth.zig");
const jwt = @import("../jwt.zig");
const crypto = @import("../crypto.zig");
const auth_api = @import("auth.zig");
const ApiError = @import("error.zig").ApiError;

/// True if `name` is one of the filenames stored in any file field of `rec`.
fn recordReferencesFile(col: schema.Collection, rec: std.json.Value, name: []const u8) bool {
    if (rec != .object) return false;
    for (col.fields) |f| {
        if (f.options != .file) continue;
        const v = rec.object.get(f.name) orelse continue;
        switch (v) {
            .string => |s| if (std.mem.eql(u8, s, name)) return true,
            .array => |arr| for (arr.items) |it| if (it == .string and std.mem.eql(u8, it.string, name)) return true,
            else => {},
        }
    }
    return false;
}

/// Resolve the requester identity for a file GET: ?token (file/auth) -> cookie/bearer. Anonymous on failure.
fn fileIdentity(ctx: *http.RequestCtx, conn: *db.Db) ?auth.Verified {
    const app = ctx.app.?;
    // ?token= (a file or auth token)
    const qp = @import("../query/params.zig").parse(ctx.allocator, ctx.query) catch null;
    if (qp) |p| if (p.get("token")) |tok| {
        if (auth.verifyTokenOfTypes(ctx.allocator, app, conn, tok, &.{ .auth, .file })) |v| return v;
    };
    // cookie/bearer via authenticate
    if (auth.authenticate(app.io, ctx.allocator, app, ctx, conn) catch null) |a|
        return .{ .record = a.record, .collection = a.collection, .is_superuser = a.is_superuser, .exp = 0 };
    return null;
}

/// GET /api/files/:col/:rec/:name
pub fn serve(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.openReader();
    defer r.close();
    const col_name = ctx.param("col") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("rec") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const name = ctx.param("name") orelse return ApiError.notFound().toResponse(ctx.allocator);

    const col = (try collections.get(ctx.allocator, &r, col_name)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rec = (try records.get(ctx.allocator, &r, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    if (!recordReferencesFile(col, rec, name)) return ApiError.notFound().toResponse(ctx.allocator);

    // access control via viewRule
    const ident = fileIdentity(ctx, &r);
    const rctx = request.RequestContext{
        .auth = if (ident) |i| i.record else null,
        .is_superuser = if (ident) |i| i.is_superuser else false,
        .method = "GET",
    };
    switch (rules.decide(col.viewRule, &rctx)) {
        .deny_locked => return ApiError.notFound().toResponse(ctx.allocator),
        .allow => {},
        .check => if (!try rules.matches(ctx.allocator, &r, col, rid, col.viewRule.?, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }

    const storage = app.storage orelse return ApiError.internal().toResponse(ctx.allocator);
    const path = (try storage.localPath(ctx.allocator, col.name, rid, name)) orelse return ApiError.internal().toResponse(ctx.allocator);

    const qp = @import("../query/params.zig").parse(ctx.allocator, ctx.query) catch null;
    const is_download = if (qp) |p| (p.get("download") != null) else false;
    const disposition = try std.fmt.allocPrint(ctx.allocator, "{s}; filename=\"{s}\"", .{ if (is_download) "attachment" else "inline", name });
    const cache: []const u8 = if (col.viewRule != null and col.viewRule.?.len == 0) "public, max-age=3600" else "private";
    const headers = try ctx.allocator.dupe(http.Header, &.{
        .{ .name = "Referrer-Policy", .value = "no-referrer" },
        .{ .name = "Cache-Control", .value = cache },
        .{ .name = "Content-Disposition", .value = disposition },
    });
    return .{ .status = 200, .body = "", .file_path = path, .extra_headers = headers };
}

/// POST /api/files/token — authenticated; mints a short-lived file-access token.
pub fn token(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const authed = (try auth.authenticate(app.io, ctx.allocator, app, ctx, w)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const rid = authed.record.object.get("id").?.string;
    const table = if (authed.is_superuser) "_superusers" else authed.collection;
    const tk = (try auth_api.tokenKeyFor(ctx.allocator, w, table, rid)) orelse
        return (ApiError{ .status = 401, .message = "Not authenticated." }).toResponse(ctx.allocator);
    const now = try auth.nowUnixPub(w);
    const key = crypto.deriveKey(app.jwt_secret, tk);
    const claims = jwt.Claims{ .id = rid, .collection = authed.collection, .type = .file, .iat = now, .exp = now + app.file_token_ttl_s };
    const tok = try jwt.sign(ctx.allocator, claims, &key);
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "token", .{ .string = tok });
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}) };
}
```

Confirm `query/params.zig` exposes `parse(alloc, query) → map with .get(name)` (it's used in `api/records.zig` `list`). Match its actual API.

- [ ] **Step 2: Register routes + construct storage.**

In `src/server.zig`: add `const files_api = @import("api/files.zig");` and routes:

```zig
    .{ .method = .GET, .pattern = "/api/files/:col/:rec/:name", .handler = files_api.serve },
    .{ .method = .POST, .pattern = "/api/files/token", .handler = files_api.token },
```

In `src/main.zig` `runServe`, construct the storage and assign it to `App.storage` (it must outlive `app` — allocate on the gpa, not stack):

```zig
    const storage_root = try std.fmt.allocPrint(allocator, "{s}/storage", .{cfg.data_dir});
    defer allocator.free(storage_root);
    var local = files_storage.LocalStorage.init(storage_root);
    const storage_iface = local.storage();
    // app.storage points at storage_iface; both `local` and `storage_iface` live for the serve scope.
```

and set `.storage = &storage_iface` in the `App{…}` literal. Add `const files_storage = @import("files/storage.zig");` to main.zig imports. (Because `runServe` blocks in `srv.listen()`, the stack locals `local`/`storage_iface` live for the server's lifetime — correct. `storage_root` is duped onto `app.allocator`-managed memory; keep it alive: do NOT `defer free` it before `listen` returns — change the `defer` to a plain free after `srv.listen()` or leak it for the process lifetime. Simplest: drop the `defer` and let it live for the process.)

Register `_ = @import("api/files.zig");` in the main.zig test root.

- [ ] **Step 3: Build + run**

Run: `mise exec zig@0.16.0 -- zig build` (EXIT 0) and `mise exec zig@0.16.0 -- zig build test --summary all` (PASS).

- [ ] **Step 4: Commit**

```bash
git add src/api/files.zig src/server.zig src/main.zig
git commit -m "feat(files): file serving + file-token endpoints; wire storage"
```

---

### Task 6: Live smoke, holistic review, merge

**Files:** none (validation + merge).

- [ ] **Step 1: Live smoke** — build, serve, exercise uploads/downloads with curl.

```bash
mise exec zig@0.16.0 -- zig build
SMOKE=/home/valthon/.claude/jobs/fc85a1ad/tmp/zb_files_smoke
rm -rf "$SMOKE"; mkdir -p "$SMOKE"
./zig-out/bin/zigbase superuser create --email admin@x.io --password adminpassword --data-dir "$SMOKE"
ZIGBASE_DATA_DIR="$SMOKE" ZIGBASE_HTTP_PORT=8093 ./zig-out/bin/zigbase serve >"$SMOKE/server.log" 2>&1 &
SRV=$!; sleep 1.5
```

Then (capture status codes; superuser-bearer for collection mgmt):
1. Create a **public** collection `gallery` with a single `file` field `image` (`maxSelect:1`) and rules `listRule/viewRule/createRule = ""`.
2. `POST /api/collections/gallery/records` as `multipart/form-data` (`curl -F "image=@<a real small png>"`) → 201; response `image` is a generated `*.png` filename; the file exists on disk under `$SMOKE/storage/gallery/<rid>/`.
3. `GET /api/files/gallery/<rid>/<filename>` → 200, `Content-Type: image/png`, bytes match the uploaded file; `Referrer-Policy: no-referrer` header present.
4. `GET /api/files/gallery/<rid>/not-a-real-name.png` → 404 (name not referenced).
5. **Protected:** create a collection `private` with `viewRule = "owner = @request.auth.id"`, a text `owner`, and a `file` field `doc`; upload a doc as a user record; an **anonymous** `GET /api/files/private/<rid>/<doc>` → 404; obtain a file token (`POST /api/files/token` with the owner's bearer) and `GET …?token=<t>` → 200.
6. **Multi add/remove:** a `maxSelect:3` field — upload 2, then `PATCH` with one new file + `docs-=["<one old name>"]` → record shows the expected net list; removed file is gone from disk, new file present.
7. **Delete:** delete a record → its `$SMOKE/storage/<col>/<rid>/` dir is removed.
8. Cleanup: `kill $SRV; rm -rf "$SMOKE"`.

Record observed results. Fix any real bug (commit), re-run.

- [ ] **Step 2: Holistic security review** — dispatch a review over the whole SP8 diff (`git diff main..files -- 'src/*'`). Trace, with concrete scenarios: **path traversal** (sanitized stored names + the `:name`-must-be-record-referenced gate — try `..%2f`, absolute paths, a name from a different record); **MIME bypass** (sniffed type vs client header); **file-token scope** (a `.file` token can NOT authenticate record/collection/realtime endpoints — only `.file`-aware file reads; short TTL; viewRule still enforced); **access parity** (file `viewRule` decision matches the record `GET` decision; protected file → 404 for the unauthorized); **upload limits** (maxSize/maxSelect/`max_upload_size`; what bounds the in-memory upload — note zap's body cap); **cleanup/orphans** (record create rollback deletes written files; replaced/removed files deleted; record delete removes the dir; a failed unlink is non-fatal but logged); **SQLi/path injection** (col/rid validated; filename always sanitized — no client string is a raw path component). Fix CRITICAL/IMPORTANT findings (new commits), re-run `zig build` + `zig build test`.

- [ ] **Step 3: Merge SP8 to `main`**

```bash
git checkout main
git merge --no-ff files -m "merge: SP8 File storage (uploads, serving, file tokens)

Local-disk file storage for ZigBase file fields: multipart uploads on the
record endpoints (add/remove/replace semantics), an access-controlled download
endpoint (public direct; protected via cookie/bearer/short-lived file token,
viewRule-enforced) with sendFile streaming, server-side MIME sniffing, and a
pluggable Storage interface (local now). Filename sanitization + the
:name-must-be-referenced gate block traversal. Includes holistic-review fixes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all
```
Expected: binary builds, full suite green on `main`. Then update the project-status memory (SP8 complete; SP9 Admin SPA next — the final sub-project).

---

## Done criteria for 8b / SP8

- Binary builds + full suite green on `main`.
- Multipart upload on record create/update (single replace/clear, multi add/remove/net-cap, size/count/MIME validation); files on disk under `storage/<col>/<rid>/`; `GET /api/files/...` serves with access control (public direct; protected via cookie/bearer/file-token; `viewRule`-enforced; id-only-style 404 hiding) and `sendFile`; record delete removes files; traversal blocked.
- Holistic review clean.

---

## Self-Review (author)

- **Spec coverage:** file token type + verify (§5 → Task 1); upload computation orchestration (§4 → Task 2); multipart extraction + `sendFile` (§2,§4 → Task 3); multipart record create/update/delete (§4 → Task 4); serving + token endpoints + access control + wiring (§5 → Task 5); limits/errors throughout (§6,§7); smoke + review + merge (§8 → Task 6).
- **Type consistency:** `jwt.TokenType.file` (Task 1) used by `verifyTokenOfTypes` (Task 1) + the token endpoint (Task 5); `planAllFileFields`/`AllPlan`/`FieldWrite` (Task 2) consumed by the record handlers (Task 4); `Storage` methods + `App.storage` (8a) used in Tasks 4/5; `Response.file_path`/`extra_headers` (8a) written by `server.zig` (Task 3) and produced by `files_api.serve` (Task 5); `http.UploadedFile` (8a) produced by `multipart.extract` (Task 3) and consumed by `planAllFileFields`.
- **Placeholder scan:** none — full code in every code step. The "confirm the std/zap method name if the build complains" notes (ObjectMap remove, `HttpParamKV`, `query/params` API) are honest std/FFI-boundary guidance with the exact intent, not logic gaps.
- **Known/accepted (for the review):** multipart form fields take zap's guessed types (string/int/bool/float) — fine for text + file fields, the common case; uploads are fully buffered in memory (bounded by zap's body cap / `max_upload_size`) — streaming-to-disk is a post-MVP item; `storage_root`/`local` lifetime in `runServe` relies on `listen()` blocking for the process lifetime.
