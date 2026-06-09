# ZigBase SP5 Plan 5b: Auth Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `type:"auth"` collections functional — fixed system columns (email/username/passwordHash/tokenKey/verified, with hidden secrets), per-collection auth options, the `_superusers` system collection, password hashing on auth-record create/update, and a `superuser create` CLI.

**Architecture:** Auth system fields are **injected into a loaded collection's `fields`** (and at create-DDL time) and **stripped before persisting** to `_collections.schema`, so the existing record/DDL engine (which iterates `col.fields`) handles them generically; a `Field.hidden` flag keeps `passwordHash`/`tokenKey` out of API responses. Auth options live in a new `_collections.options` JSON column (migration `0002`, which also seeds `_superusers`). A small `auth.zig` applies password hashing/token-key generation; the CLI inserts a superuser through the same path.

**Tech Stack:** Zig 0.16.0 (mise), the SP2/SP3 engine (`schema`,`ddl`,`collections`,`records`,`migrations`), `crypto.zig` (5a), `std.json`.

---

## Toolchain (read once)
Run zig via the pinned 0.16.0 toolchain from repo root: `mise exec zig@0.16.0 -- zig <args>`. Do NOT use `mise -C`. On branch `auth` (5a merged conceptually; 107 tests pass).

## Verified current code (grounding)
- `schema.Field{id,name,required,unique,options}` + `fieldType()/sqlType()/isMultiValue()`; `FieldOptions` union (text/email/url/editor/date/autodate/@"bool"/number/json/select/relation/file). `Collection{id,name,type:CollectionType(.base/.auth/.view),system,fields,indexes,5 rules,created,updated}`. `fieldByName`, `isValidIdentifier`, `validate(alloc,c,*ArrayList(ValidationError))`, `fieldsToJson/fieldsFromJson`, `parseCollectionInput(alloc,s)`, `collectionToJson(alloc,c)`.
- `records.columnList`/`baseColumnList` emit `"id","created","updated"` + each `col.fields` quoted name; `rowToObject` reads cols 0,1,2 then `col.fields[i]` at index `3+i` via `values.readValue`. `records.create` builds INSERT cols/vals/binds from `col.fields`.
- `ddl.createTableSql(alloc,c,single_rel_target)` emits system cols + `c.fields` columns (+ FK + UNIQUE via `Field.unique`); `ddl.rebuildPlan` iterates fields by id.
- `collections.create(alloc,io,*db.Db,def)` validates, builds DDL, persists; `collections.get/list` parse `_collections` rows via `fieldsFromJson`. `collections.resolveRelations` etc.
- `migrations.zig`: `Migration{name,up:fn(*db.Db) DbError!void}`, `all = [_]Migration{0001_init}`, `run(*db.Db)`; `0001_init` creates `_collections` (no `options` column yet) + `_migrations`.
- `cli.zig`: `Command = union(enum){ help, serve:ServeArgs, migrate:ServeArgs }`, `parse(args)`; `main.zig` `runServe`/`runMigrate`/`openPool`/`loadCfg`.
- `crypto.hashPassword(io,alloc,pw)![]u8`, `crypto.genToken(io,alloc,len)![]u8`.

## File Structure
| File | Change |
|---|---|
| `src/schema.zig` | `Field.hidden`; `authSystemFields()`; `injectAuthFields(alloc,col)`; `isSystemFieldName`; `CollectionOptions` (auth identity); options (de)serialize; parseCollectionInput strips system fields; collectionToJson skips hidden |
| `src/records.zig` | `rowToObject` skips hidden fields (index-preserving) |
| `src/collections.zig` | create injects auth fields for DDL + persists user-only; get/list inject on load; persist/read `options` |
| `src/migrations.zig` | `0002`: add `options` column to `_collections` + seed `_superusers` |
| `src/auth.zig` | NEW — `applyCreate`/`applyUpdate` (password→passwordHash, tokenKey gen/rotate) |
| `src/cli.zig` + `src/main.zig` | `superuser create --email --password [--data-dir]` |

---

## Task 1: auth system fields + hidden flag (schema + records)

**Files:** Modify `src/schema.zig`, `src/records.zig`.

- [ ] **Step 1: `Field.hidden` + helpers in `src/schema.zig`.** Add `hidden: bool = false` to the `Field` struct. Add after `fieldByName`:

```zig
/// Names reserved by the engine (base + auth system columns); user fields may not use them.
pub fn isSystemFieldName(name: []const u8) bool {
    const reserved = [_][]const u8{ "id", "created", "updated", "email", "username", "passwordHash", "tokenKey", "verified" };
    for (reserved) |r| if (std.mem.eql(u8, name, r)) return true;
    return false;
}

/// The implicit system fields of an auth collection (beyond id/created/updated).
/// passwordHash/tokenKey are hidden (never serialized). Stable ids (leading '_').
pub fn authSystemFields() []const Field {
    const S = struct {
        const fields = [_]Field{
            .{ .id = "_email", .name = "email", .unique = true, .options = .{ .email = .{} } },
            .{ .id = "_username", .name = "username", .options = .{ .text = .{} } },
            .{ .id = "_pwhash", .name = "passwordHash", .hidden = true, .options = .{ .text = .{} } },
            .{ .id = "_tokkey", .name = "tokenKey", .hidden = true, .options = .{ .text = .{} } },
            .{ .id = "_verified", .name = "verified", .options = .{ .@"bool" = .{} } },
        };
    };
    return &S.fields;
}

/// Returns `col` with auth system fields prepended to `fields` (for auth collections);
/// base/view collections are returned unchanged. The slice is allocated from `alloc`.
pub fn injectAuthFields(alloc: std.mem.Allocator, col: Collection) !Collection {
    if (col.type != .auth) return col;
    const sys = authSystemFields();
    const out = try alloc.alloc(Field, sys.len + col.fields.len);
    @memcpy(out[0..sys.len], sys);
    @memcpy(out[sys.len..], col.fields);
    var c = col;
    c.fields = out;
    return c;
}

test "injectAuthFields prepends the 5 auth fields for auth collections only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const user = [_]Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }};
    const auth_col = try injectAuthFields(a, .{ .id = "c", .name = "users", .type = .auth, .fields = &user });
    try std.testing.expectEqual(@as(usize, 6), auth_col.fields.len);
    try std.testing.expectEqualStrings("email", auth_col.fields[0].name);
    try std.testing.expect(fieldByName(auth_col, "passwordHash").?.hidden);
    const base_col = try injectAuthFields(a, .{ .id = "c", .name = "posts", .type = .base, .fields = &user });
    try std.testing.expectEqual(@as(usize, 1), base_col.fields.len);
}
```

- [ ] **Step 2: `rowToObject` skips hidden fields** (index-preserving) in `src/records.zig`:

```zig
    for (col.fields, 0..) |f, i| {
        const v = try values.readValue(alloc, stmt, @intCast(3 + i), f);
        if (!f.hidden) try obj.put(alloc, f.name, v);
    }
```
(Every field still occupies a SELECT column — only the JSON output skips hidden ones. `columnList`/`baseColumnList` are unchanged: they SELECT all columns including hidden, so the auth layer can read `passwordHash`/`tokenKey` via its own queries.)

- [ ] **Step 3: Run** `mise exec zig@0.16.0 -- zig build test` (expect 108). Commit:
```bash
git add src/schema.zig src/records.zig
git commit -m "feat(schema): auth system fields + Field.hidden"
```

---

## Task 2: auth collections end-to-end (collections engine + DDL)

**Files:** Modify `src/collections.zig`, `src/schema.zig`.

The engine injects auth fields for DDL + reads, persists only user fields, and strips/hides system fields in the API (de)serialization.

- [ ] **Step 1: `parseCollectionInput` drops system-named fields** — in `src/schema.zig`'s `parseCollectionInput`, after building the `fields` slice from the body, filter out any field whose name is a system field name (so a client echoing a GET response can't double-inject auth/base system columns). Replace the `fields` assignment so it filters:

```zig
    // build user fields, dropping any system-named field the client may have echoed back
    const raw_fields = if (obj.object.get("fields")) |fv| blk: {
        const fs = try std.json.Stringify.valueAlloc(alloc, fv, .{});
        break :blk try fieldsFromJson(alloc, fs);
    } else &[_]Field{};
    var kept: std.ArrayList(Field) = .empty;
    for (raw_fields) |f| {
        if (!isSystemFieldName(f.name)) try kept.append(alloc, f);
    }
    const fields = try kept.toOwnedSlice(alloc);
```

- [ ] **Step 2: `collectionToJson` skips hidden fields** — in `src/schema.zig`'s `collectionToJson`, where it serializes `c.fields` (currently via `fieldsToJson(alloc, c.fields)`), first filter out hidden fields:

```zig
    var visible: std.ArrayList(Field) = .empty;
    for (c.fields) |f| if (!f.hidden) try visible.append(alloc, f);
    const fields_str = try fieldsToJson(alloc, visible.items);
    // ... (existing reparse-and-embed under "schema" key, using fields_str) ...
```

- [ ] **Step 3: engine injects auth fields for DDL + reads; persists user-only.** In `src/collections.zig`:
  - In `create`, after validation and id assignment but BEFORE building the DDL: materialize the full field set for the table and reads, while persisting only the user fields. Build a `ddl_col` whose `.fields = (try schema.injectAuthFields(alloc, col)).fields` and use that for `ddl.createTableSql` + `resolveRelations`. Keep persisting the ORIGINAL user `col.fields` in `_collections.schema` (so `insertRow`/`fieldsToJson(col.fields)` is unchanged — it stores user fields only).
  - In `get` and `list`, after constructing the Collection from the row (`rowToCollection`), return `try schema.injectAuthFields(alloc, that_collection)` so consumers (record engine) see the full field set.
  - Validation: `schema.validate` should reject a user field whose name is a system field name. Add to `validate` (in schema.zig) a check: `if (isSystemFieldName(f.name)) append .{field=f.name, code="validation_reserved_name", message="Field name is reserved."}`. (parseCollectionInput already drops them, but a direct engine caller could still pass one.)

- [ ] **Step 4: Write the integration test** in `src/collections.zig`:

```zig
test "auth collection gets system columns; passwordHash hidden in metadata" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "bio", .options = .{ .text = .{} } }};
    _ = try create(a, std.testing.io, &d, .{ .id = "", .name = "users", .type = .auth, .fields = &fields });

    // physical table has the auth system columns
    var st = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('users') WHERE name IN ('email','username','passwordHash','tokenKey','verified');");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 5), st.columnInt(0));

    // get() returns the auth fields (incl email) but collectionToJson hides passwordHash
    const got = (try get(a, &d, "users")).?;
    try std.testing.expect(schema.fieldByName(got, "email") != null);
    try std.testing.expect(schema.fieldByName(got, "bio") != null);
    const json = try schema.collectionToJson(a, got);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"email\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "passwordHash") == null); // hidden
}
```

- [ ] **Step 5: Run + commit** — `mise exec zig@0.16.0 -- zig build test` (expect ~109; existing collection/record tests for BASE collections must still pass — base collections inject nothing). Commit:
```bash
git add src/collections.zig src/schema.zig
git commit -m "feat(collections): functional auth collections (system columns, hidden secrets)"
```

---

## Task 3: `options` column + auth options + `_superusers`

**Files:** Modify `src/schema.zig`, `src/migrations.zig`, `src/collections.zig`.

- [ ] **Step 1: `CollectionOptions` in `src/schema.zig`.** Add to the `Collection` struct a field `options: CollectionOptions = .{}` and define:

```zig
pub const AuthOptions = struct {
    identityFields: []const []const u8 = &.{"email"},
    minPasswordLength: u8 = 8,
};
pub const CollectionOptions = struct {
    auth: AuthOptions = .{},
};
```

- [ ] **Step 2: options (de)serialization** in `src/schema.zig`. Add `optionsToJson(alloc, c) ![]u8` and parse in `parseCollectionInput` (read `obj.options.auth.identityFields`/`minPasswordLength` when present, default otherwise). In `collectionToJson`, include an `"options"` key. Add helpers:

```zig
pub fn optionsToJson(alloc: std.mem.Allocator, c: Collection) ![]u8 {
    var root: ObjectMap = .empty;
    var auth: ObjectMap = .empty;
    var ids = std.json.Array.init(alloc);
    for (c.options.auth.identityFields) |f| try ids.append(.{ .string = f });
    try auth.put(alloc, "identityFields", .{ .array = ids });
    try auth.put(alloc, "minPasswordLength", .{ .integer = c.options.auth.minPasswordLength });
    try root.put(alloc, "auth", .{ .object = auth });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
}

pub fn optionsFromJson(alloc: std.mem.Allocator, s: []const u8) !CollectionOptions {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch return .{};
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return .{};
    const av = root.object.get("auth") orelse return .{};
    if (av != .object) return .{};
    var opts = CollectionOptions{};
    if (av.object.get("identityFields")) |idv| if (idv == .array) {
        var list: std.ArrayList([]const u8) = .empty;
        for (idv.array.items) |it| if (it == .string) try list.append(alloc, try alloc.dupe(u8, it.string));
        if (list.items.len > 0) opts.auth.identityFields = try list.toOwnedSlice(alloc);
    };
    if (av.object.get("minPasswordLength")) |mv| if (mv == .integer) {
        opts.auth.minPasswordLength = std.math.cast(u8, mv.integer) orelse 8;
    };
    return opts;
}
```
Wire `parseCollectionInput` to set `.options = if (obj.object.get("options")) |ov| try optionsFromJson(alloc, try std.json.Stringify.valueAlloc(alloc, ov, .{})) else .{}`. Wire `collectionToJson` to add `try root.put(alloc, "options", (try std.json.parseFromSlice(std.json.Value, alloc, try optionsToJson(alloc, c), .{})).value);`.

- [ ] **Step 3: migration `0002`** in `src/migrations.zig` — add the `options` column to `_collections` and persist/read it; then seed `_superusers`. Add a migration that runs raw SQL:

```zig
fn init_0002(w: *db.Db) db.DbError!void {
    // add the options column (idempotent guard: ignore the duplicate-column error if re-run)
    w.exec("ALTER TABLE \"_collections\" ADD COLUMN \"options\" TEXT NOT NULL DEFAULT '{}';") catch {};
    // seed the _superusers system auth collection (a table + a _collections row)
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_superusers" (
        \\  "id" TEXT PRIMARY KEY, "created" TEXT, "updated" TEXT,
        \\  "email" TEXT UNIQUE, "username" TEXT, "passwordHash" TEXT, "tokenKey" TEXT, "verified" INTEGER
        \\);
    );
    try w.exec(
        \\INSERT OR IGNORE INTO "_collections"
        \\  ("id","name","type","system","schema","indexes","options","created","updated")
        \\ VALUES ('_superusers_____','_superusers','auth',1,'[]','[]',
        \\  '{"auth":{"identityFields":["email"],"minPasswordLength":8}}',
        \\  datetime('now'), datetime('now'));
    );
}
```
Add `.{ .name = "0002_auth", .up = init_0002 }` to the `all` array (after `0001_init`).

- [ ] **Step 4: collections.create/get/list persist & read `options`.** In `collections.zig`'s `insertRow`, include the `options` column (bind `try schema.optionsToJson(alloc, col)`); in the INSERT column list add `options`. In `rowToCollection`, read the `options` column (its index — append it to the SELECT in `select_cols`) via `schema.optionsFromJson(alloc, columnText)`. (Update `select_cols` to include `,options` and `rowToCollection` to read it.)

- [ ] **Step 5: Tests** in `src/migrations.zig` / `src/collections.zig`:

```zig
test "0002 adds options column and seeds _superusers" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    var st = try d.prepare("SELECT type FROM \"_collections\" WHERE name='_superusers';");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqualStrings("auth", st.columnText(0));
    var c = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_collections') WHERE name='options';");
    defer c.finalize();
    _ = try c.step();
    try std.testing.expectEqual(@as(i64, 1), c.columnInt(0));
}
```
Add a `collections.zig` test that an auth collection's `options.auth.identityFields` round-trips (create with identityFields `["email","username"]` via a Collection literal → get → assert).

- [ ] **Step 6: Run + commit** — `mise exec zig@0.16.0 -- zig build test`. Commit:
```bash
git add src/schema.zig src/migrations.zig src/collections.zig
git commit -m "feat(collections): options column, auth options, and _superusers"
```

---

## Task 4: `auth.zig` — password handling

**Files:** Create `src/auth.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Create `src/auth.zig`** (the auth-record helpers used by 5c handlers + the CLI):

```zig
const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const crypto = @import("crypto.zig");

pub const AuthError = error{ PasswordTooShort, IdentityTaken } || db.DbError || std.mem.Allocator.Error;

/// Given the request data for an auth-collection record, return a copy with `passwordHash`,
/// `tokenKey`, and `verified` populated (password removed). Hashes the `password` field.
/// `min_len` is the collection's minPasswordLength.
pub fn applyCreate(io: std.Io, alloc: std.mem.Allocator, data: std.json.Value, min_len: u8) AuthError!std.json.Value {
    if (data != .object) return error.PasswordTooShort; // caller validates object-ness; treat as bad
    const pw = (data.object.get("password")) orelse return error.PasswordTooShort;
    if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
    const phc = try crypto.hashPassword(io, alloc, pw.string);
    const tk = try crypto.genToken(io, alloc, 32);
    var obj = data.object; // shallow copy is fine; we add keys to a fresh map
    var out: std.json.ObjectMap = .empty;
    var it = obj.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "password")) continue; // never store the plaintext
        try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), e.value_ptr.*);
    }
    try out.put(alloc, "passwordHash", .{ .string = phc });
    try out.put(alloc, "tokenKey", .{ .string = tk });
    if (out.get("verified") == null) try out.put(alloc, "verified", .{ .bool = false });
    return .{ .object = out };
}

/// For an update: if `data` contains a new `password`, return a copy with a fresh
/// `passwordHash` and a rotated `tokenKey` (invalidating existing tokens), password removed.
/// If no password is present, returns `data` unchanged.
pub fn applyUpdate(io: std.Io, alloc: std.mem.Allocator, data: std.json.Value, min_len: u8) AuthError!std.json.Value {
    if (data != .object) return data;
    const pw = data.object.get("password") orelse return data;
    if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
    const phc = try crypto.hashPassword(io, alloc, pw.string);
    const tk = try crypto.genToken(io, alloc, 32);
    var out: std.json.ObjectMap = .empty;
    var it = data.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "password")) continue;
        try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), e.value_ptr.*);
    }
    try out.put(alloc, "passwordHash", .{ .string = phc });
    try out.put(alloc, "tokenKey", .{ .string = tk });
    return .{ .object = out };
}

test "applyCreate hashes the password, sets tokenKey/verified, strips plaintext" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expect(out.object.get("password") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.object.get("passwordHash").?.string, "$argon2id$"));
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
    try std.testing.expectEqualStrings("a@b.c", out.object.get("email").?.string);
}

test "applyCreate rejects a short password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "password", .{ .string = "short" });
    try std.testing.expectError(error.PasswordTooShort, applyCreate(std.testing.io, a, .{ .object = data }, 8));
}
```

- [ ] **Step 2: Aggregate + run + commit** — add `_ = @import("auth.zig");` to `src/main.zig`'s `test {}`. Run tests. Commit:
```bash
git add src/auth.zig src/main.zig
git commit -m "feat(auth): password hashing helpers for auth records"
```

---

## Task 5: `superuser create` CLI

**Files:** Modify `src/cli.zig`, `src/main.zig`.

- [ ] **Step 1: `cli.zig` — add the `superuser` command.** Extend `Command`:

```zig
pub const SuperuserArgs = struct { data_dir: ?[]const u8 = null, email: ?[]const u8 = null, password: ?[]const u8 = null };
pub const Command = union(enum) {
    help,
    serve: ServeArgs,
    migrate: ServeArgs,
    superuser_create: SuperuserArgs,
};
```
In `parse`, before the `serve` check, handle `superuser create`:

```zig
    if (std.mem.eql(u8, args[0], "superuser")) {
        if (args.len < 2 or !std.mem.eql(u8, args[1], "create")) return ParseError.UnknownCommand;
        var sa = SuperuserArgs{};
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--email")) { i += 1; if (i >= args.len) return ParseError.MissingValue; sa.email = args[i]; }
            else if (std.mem.eql(u8, a, "--password")) { i += 1; if (i >= args.len) return ParseError.MissingValue; sa.password = args[i]; }
            else if (std.mem.eql(u8, a, "--data-dir")) { i += 1; if (i >= args.len) return ParseError.MissingValue; sa.data_dir = args[i]; }
            else return ParseError.UnknownFlag;
        }
        return .{ .superuser_create = sa };
    }
```
Add a test:
```zig
test "superuser create parses email and password" {
    const cmd = try parse(&.{ "superuser", "create", "--email", "a@b.c", "--password", "secret123" });
    try std.testing.expectEqualStrings("a@b.c", cmd.superuser_create.email.?);
    try std.testing.expectEqualStrings("secret123", cmd.superuser_create.password.?);
}
```

- [ ] **Step 2: `main.zig` — wire `superuser create`.** Add to the command switch `.superuser_create => |sa| try runSuperuserCreate(allocator, init.io, sa),` and implement:

```zig
const crypto = @import("crypto.zig");
const id_gen = @import("id.zig");

fn runSuperuserCreate(allocator: std.mem.Allocator, io: std.Io, sa: cli.SuperuserArgs) !void {
    const email = sa.email orelse { std.log.err("--email is required", .{}); return; };
    const password = sa.password orelse { std.log.err("--password is required", .{}); return; };
    if (password.len < 8) { std.log.err("password must be at least 8 characters", .{}); return; }
    var cfg = try loadCfg(.{ .data_dir = sa.data_dir });
    var pool = try openPool(allocator, io, cfg);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.run(w);

    const phc = try crypto.hashPassword(io, allocator, password);
    defer allocator.free(phc);
    const tk = try crypto.genToken(io, allocator, 32);
    defer allocator.free(tk);
    var rid = id_gen.collectionId(io);

    var st = try w.prepare(
        \\INSERT INTO "_superusers" ("id","created","updated","email","username","passwordHash","tokenKey","verified")
        \\ VALUES (?1, datetime('now'), datetime('now'), ?2, '', ?3, ?4, 1);
    );
    defer st.finalize();
    try st.bindText(1, &rid);
    try st.bindText(2, email);
    try st.bindText(3, phc);
    try st.bindText(4, tk);
    _ = st.step() catch { std.log.err("could not create superuser (email already exists?)", .{}); return; };
    std.log.info("superuser created: {s}", .{email});
}
```
(`loadCfg` currently takes a `cli.ServeArgs`; either reuse it by constructing a `ServeArgs{ .data_dir = sa.data_dir }` — the snippet does — or add a small overload. `migrations`, `cli`, `crypto`, `id_gen` imports must be present in main.zig.)

- [ ] **Step 3: Build + unit tests** — `mise exec zig@0.16.0 -- zig build && mise exec zig@0.16.0 -- zig build test`. Expect clean build + all pass.

- [ ] **Step 4: Manual smoke (superuser create + an auth collection register).**
```bash
rm -rf ./zb_data
mise exec zig@0.16.0 -- zig build
echo "--- create a superuser via CLI ---"
./zig-out/bin/zigbase superuser create --email admin@x.com --password supersecret --data-dir ./zb_data 2>&1 | tail -1
echo "--- the _superusers row exists ---"
(command -v sqlite3 >/dev/null && sqlite3 ./zb_data/data.db "SELECT email, substr(passwordHash,1,10), length(tokenKey) FROM _superusers;") || echo "(no sqlite3 cli)"
echo "--- serve + create a users auth collection, register a user (password hashed) ---"
./zig-out/bin/zigbase serve --http-port 8090 --data-dir ./zb_data >/tmp/zb_5b.log 2>&1 &
SP=$!; sleep 1.5
curl -s -X POST http://127.0.0.1:8090/api/collections -H 'content-type: application/json' -d '{"name":"users","type":"auth","listRule":"","createRule":"","fields":[{"id":"","name":"bio","type":"text","options":{}}]}' >/dev/null
echo -n "register user (expect record WITHOUT passwordHash): "
curl -s -X POST http://127.0.0.1:8090/api/collections/users/records -H 'content-type: application/json' -d '{"email":"u@x.com","password":"hunter2hunter2"}'
kill $SP 2>/dev/null; wait $SP 2>/dev/null
```
NOTE: the user-register via the REST endpoint requires the auth-aware create handler from **Plan 5c**. In 5b the record create handler does NOT yet hash passwords, so this last curl will store the record but WITHOUT a passwordHash (or reject if email/passwordHash are required). That is expected — the smoke's last step fully works only after 5c. The CLI superuser creation (which uses `auth.zig`/crypto directly) IS fully functional in 5b; verify that and the `_superusers` row. **Always kill the server.**

- [ ] **Step 5: Commit**
```bash
git add src/cli.zig src/main.zig
git commit -m "feat(cli): superuser create command"
```

---

## Self-Review (completed by plan author)

**Spec coverage (SP5 design §3 auth collections, §4 password handling, §8 files — the model half):**
- auth system columns (email/username/passwordHash/tokenKey/verified) + `Field.hidden` → Tasks 1,2 ✓
- inject-on-load / strip-on-persist; hidden secrets never serialized → Tasks 1,2 ✓
- `options` column + `CollectionOptions`/auth identity config → Task 3 ✓
- `_superusers` system auth collection (migration `0002`) → Task 3 ✓
- password hashing + tokenKey gen/rotate helpers → Task 4 ✓
- `superuser create` CLI → Task 5 ✓
- **Deferred to 5c (intentional):** wiring `auth.applyCreate`/`applyUpdate` into the REST record-create/update handlers (the register-via-REST smoke step), all endpoints, and the middleware. Email/username uniqueness enforcement at create lives with the create handler (5c) alongside `applyCreate`.

**Type consistency:** `schema.{Field.hidden, authSystemFields, injectAuthFields, isSystemFieldName, CollectionOptions, AuthOptions, optionsToJson, optionsFromJson}`; `Collection.options`; `auth.{applyCreate, applyUpdate, AuthError}`; `cli.{SuperuserArgs, superuser_create}`; migration `0002_auth`. Consistent across tasks.

**Placeholder scan:** Tasks 1, 4, 5 contain complete code. Tasks 2 and 3 give complete helper code plus precise structural edits to existing functions (`parseCollectionInput`/`collectionToJson`/`collections.create`/`rowToCollection`/`insertRow`/`select_cols`) with the integration tests pinning behavior (auth table has the columns; passwordHash hidden in metadata; `_superusers` seeded; options round-trip). No vague steps.
