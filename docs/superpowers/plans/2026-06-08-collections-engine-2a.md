# ZigBase SP2 Plan 2a: Collections Engine (internal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fully-tested, internal (no-HTTP) collections engine: a typed field model with validation and JSON (de)serialization, DDL generation, a by-field-id rebuild diff, a system-migration runner, and create/get/list/update/delete operations against SQLite.

**Architecture:** Layered with no cycles: `id` → `schema` (types+validation+JSON) → `ddl` (pure SQL strings + rebuild plan) → `collections` (engine orchestrating db+ddl+persistence) and `migrations` (versioned system schema). REST exposure is the separate Plan 2b.

**Tech Stack:** Zig 0.16.0 (mise), vendored SQLite via the existing `db.zig`, `std.json` for schema (de)serialization, `std.Io` for randomness.

---

## Toolchain (read once)
Run every zig command via the pinned 0.16.0 toolchain from the repo root: `mise exec zig@0.16.0 -- zig <args>` (e.g. `mise exec zig@0.16.0 -- zig build test`). Do NOT pass `mise -C`. If `zig version` already prints 0.16.0 in your shell, the bare `zig` is fine.

## Verified 0.16 API facts (grounding — already confirmed against the installed std)
- **Randomness is `Io`-based:** `io.random(buf: []u8)` fills bytes from a CSPRNG-seeded source. `id.zig` functions take an `io: std.Io`. In tests use `std.testing.io`; at runtime use `init.io` (carried later by `App`).
- **JSON:** `std.json.parseFromSlice`, the dynamic `std.json.Value = union(enum){ null, bool, integer: i64, float: f64, number_string: []const u8, string: []const u8, array: Array, object: ObjectMap }`, and `std.json.Stringify.valueAlloc(alloc, v, .{}) ![]u8`. We parse schema via the dynamic `Value` tree (not struct reflection) because field `options` are type-dependent.
- **`std.StringHashMap(V)`** exists (used later in 2b).
- **db.zig** already provides `Db.openMemory/open/exec/prepare`, `Stmt.bindText/bindInt/step/columnText/columnInt/reset/finalize`, `Pool`, `DbError`. This plan ADDS `Stmt.columnDouble/columnType/isNull` (Task 2).
- Existing suite: 19 tests pass on `main`. Keep them green.

## File Structure
| File | Responsibility |
|---|---|
| `src/id.zig` | URL-safe id generation (`collectionId`=15, `fieldId`=8) from `io.random` |
| `src/db.zig` (modify) | add `Stmt.columnDouble`, `Stmt.columnType`, `Stmt.isNull` |
| `src/schema.zig` | `FieldType`, `NumberMode`, `FieldOptions`, `Field`, `Collection`; validation; JSON parse/serialize |
| `src/ddl.zig` | pure SQL: `quoteIdent`, `columnDef`, `createTableSql`, `createIndexSql`, `rebuildPlan` |
| `src/collections.zig` | engine: `create`/`get`/`list`/`update`/`delete` over a `*db.Db` writer |
| `src/migrations.zig` | `_migrations` bootstrap + ordered migrations; `0001_init` creates `_collections` |
| `src/main.zig` (modify) | extend the `test {}` aggregator with the new modules |

The engine operates on a `*db.Db` (the writer connection) so it is testable with `Db.openMemory()`; Plan 2b wires it to `Pool`/`App`.

---

## Task 1: `id.zig` — URL-safe id generator

**Files:** Create `src/id.zig`; Modify `src/main.zig` (aggregate tests).

- [ ] **Step 1: Write `src/id.zig`**

```zig
const std = @import("std");

/// Lowercase base36 — safe in URLs, table names, and JSON without escaping.
const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";

/// Fill `out` with random base36 characters. `io` supplies entropy.
pub fn generate(io: std.Io, out: []u8) void {
    io.random(out);
    for (out) |*b| b.* = alphabet[b.* % alphabet.len];
}

/// 15-char id for collections and records.
pub fn collectionId(io: std.Io) [15]u8 {
    var buf: [15]u8 = undefined;
    generate(io, &buf);
    return buf;
}

/// 8-char id for fields.
pub fn fieldId(io: std.Io) [8]u8 {
    var buf: [8]u8 = undefined;
    generate(io, &buf);
    return buf;
}

test "generate fills exact length with base36 chars" {
    var buf: [15]u8 = undefined;
    generate(std.testing.io, &buf);
    for (buf) |c| try std.testing.expect(std.mem.indexOfScalar(u8, alphabet, c) != null);
}

test "ids vary between calls" {
    const a = collectionId(std.testing.io);
    const b = collectionId(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expectEqual(@as(usize, 8), fieldId(std.testing.io).len);
}
```

- [ ] **Step 2: Aggregate** — add `_ = @import("id.zig");` inside the `test {}` block in `src/main.zig`.

- [ ] **Step 3: Run** `mise exec zig@0.16.0 -- zig build test` — expect PASS (21 tests). If `io.random`'s exact name differs, grep the fetched std (`std/Io.zig` `pub fn random`) and match; the rest is unchanged.

- [ ] **Step 4: Commit**
```bash
git add src/id.zig src/main.zig
git commit -m "feat(id): url-safe base36 id generator"
```

---

## Task 2: `Stmt` column helpers

**Files:** Modify `src/db.zig`.

The engine reads `_collections` rows whose columns are text; later record reads need REAL and NULL handling. Add three readers.

- [ ] **Step 1: Add to the `Stmt` struct body in `src/db.zig`** (next to `columnText`/`columnInt`):

```zig
    pub fn columnDouble(self: *Stmt, idx: c_int) f64 {
        return c.sqlite3_column_double(self.handle, idx);
    }

    pub const ColumnType = enum { Null, Integer, Float, Text, Blob };

    pub fn columnType(self: *Stmt, idx: c_int) ColumnType {
        return switch (c.sqlite3_column_type(self.handle, idx)) {
            c.SQLITE_INTEGER => .Integer,
            c.SQLITE_FLOAT => .Float,
            c.SQLITE_TEXT => .Text,
            c.SQLITE_BLOB => .Blob,
            else => .Null, // SQLITE_NULL
        };
    }

    pub fn isNull(self: *Stmt, idx: c_int) bool {
        return c.sqlite3_column_type(self.handle, idx) == c.SQLITE_NULL;
    }
```

- [ ] **Step 2: Add tests** to `src/db.zig`:

```zig
test "column type, double, and null detection" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (a REAL, b TEXT);");
    try db.exec("INSERT INTO t (a, b) VALUES (3.5, NULL);");
    var sel = try db.prepare("SELECT a, b FROM t;");
    defer sel.finalize();
    try std.testing.expect((try sel.step()) == true);
    try std.testing.expectEqual(Stmt.ColumnType.Float, sel.columnType(0));
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), sel.columnDouble(0), 0.0001);
    try std.testing.expect(sel.isNull(1));
}
```

- [ ] **Step 3: Run** `mise exec zig@0.16.0 -- zig build test` — expect PASS (22 tests).

- [ ] **Step 4: Commit**
```bash
git add src/db.zig
git commit -m "feat(db): Stmt columnDouble/columnType/isNull"
```

---

## Task 3: `schema.zig` — field & collection model + validation

**Files:** Create `src/schema.zig`; Modify `src/main.zig`.

This task defines the in-memory types and validation. JSON (de)serialization is Task 4 so this file stays focused; write it WITHOUT json yet.

- [ ] **Step 1: Write the types and validation in `src/schema.zig`**

```zig
const std = @import("std");

pub const NumberMode = enum { float, int, fixed };

pub const FieldType = enum {
    text, email, url, editor, date, autodate, @"bool", number, json, select, relation, file,
};

pub const FieldOptions = union(FieldType) {
    text: struct { min: ?u32 = null, max: ?u32 = null, pattern: ?[]const u8 = null },
    email: struct {},
    url: struct {},
    editor: struct {},
    date: struct { min: ?[]const u8 = null, max: ?[]const u8 = null },
    autodate: struct { onCreate: bool = true, onUpdate: bool = false },
    @"bool": struct {},
    number: struct { mode: NumberMode = .float, scale: ?u8 = null, min: ?f64 = null, max: ?f64 = null },
    json: struct { maxSize: ?u32 = null },
    select: struct { values: []const []const u8, maxSelect: u32 = 1 },
    relation: struct { targetCollectionId: []const u8, cascadeDelete: bool = false, minSelect: ?u32 = null, maxSelect: u32 = 1 },
    file: struct { maxSelect: u32 = 1, maxSize: ?u64 = null, mimeTypes: ?[]const []const u8 = null },
};

pub const Field = struct {
    id: []const u8,
    name: []const u8,
    required: bool = false,
    unique: bool = false,
    options: FieldOptions,

    pub fn fieldType(self: Field) FieldType {
        return std.meta.activeTag(self.options);
    }

    /// SQLite column affinity for this field.
    pub fn sqlType(self: Field) []const u8 {
        return switch (self.options) {
            .@"bool" => "INTEGER",
            .number => |n| if (n.mode == .float) "REAL" else "INTEGER",
            else => "TEXT",
        };
    }

    /// True for single-valued select/relation/file (maxSelect == 1).
    pub fn isMultiValue(self: Field) bool {
        return switch (self.options) {
            .select => |o| o.maxSelect > 1,
            .relation => |o| o.maxSelect > 1,
            .file => |o| o.maxSelect > 1,
            else => false,
        };
    }
};

pub const CollectionType = enum { base, auth, view };

pub const Collection = struct {
    id: []const u8,
    name: []const u8,
    type: CollectionType = .base,
    system: bool = false,
    fields: []const Field,
    indexes: []const Index = &.{},
    listRule: ?[]const u8 = null,
    viewRule: ?[]const u8 = null,
    createRule: ?[]const u8 = null,
    updateRule: ?[]const u8 = null,
    deleteRule: ?[]const u8 = null,
    created: []const u8 = "",
    updated: []const u8 = "",
};

pub const Index = struct { name: []const u8, fields: []const []const u8, unique: bool = false };

pub const ValidationError = struct { field: []const u8, code: []const u8, message: []const u8 };

const system_columns = [_][]const u8{ "id", "created", "updated" };

/// Returns true if `s` is a valid identifier: ^[A-Za-z][A-Za-z0-9_]*$ and not starting with '_'.
pub fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

/// Validate a collection definition. Appends any problems to `errors`.
/// Caller owns `errors` (an ArrayList(ValidationError)); message/field/code are static or
/// borrowed from the collection, so the list does not own heap strings.
pub fn validate(c: Collection, errors: *std.ArrayList(ValidationError)) void {
    if (!isValidIdentifier(c.name))
        errors.appendAssumeCapacity(.{ .field = "name", .code = "validation_invalid_name", .message = "Name must start with a letter and contain only letters, digits, and underscores." });

    for (c.fields, 0..) |f, i| {
        if (!isValidIdentifier(f.name)) {
            errors.appendAssumeCapacity(.{ .field = f.name, .code = "validation_invalid_name", .message = "Invalid field name." });
            continue;
        }
        for (system_columns) |sys| {
            if (std.ascii.eqlIgnoreCase(f.name, sys))
                errors.appendAssumeCapacity(.{ .field = f.name, .code = "validation_reserved_name", .message = "Field name collides with a system column." });
        }
        // duplicate name check (case-insensitive) against earlier fields
        for (c.fields[0..i]) |g| {
            if (std.ascii.eqlIgnoreCase(f.name, g.name))
                errors.appendAssumeCapacity(.{ .field = f.name, .code = "validation_duplicate_name", .message = "Duplicate field name." });
        }
        // per-type option checks
        switch (f.options) {
            .select => |o| if (o.values.len == 0)
                errors.appendAssumeCapacity(.{ .field = f.name, .code = "validation_required", .message = "select requires at least one value." }),
            .number => |o| if (o.mode == .fixed and (o.scale == null or o.scale.? < 1 or o.scale.? > 8))
                errors.appendAssumeCapacity(.{ .field = f.name, .code = "validation_invalid_scale", .message = "fixed number requires scale 1..8." }),
            .relation => |o| if (o.targetCollectionId.len == 0)
                errors.appendAssumeCapacity(.{ .field = f.name, .code = "validation_required", .message = "relation requires targetCollectionId." }),
            else => {},
        }
    }
}
```

Note: `validate` uses `appendAssumeCapacity`, so callers must ensure capacity. Tests below pass a list created with enough capacity. (The engine in Task 7 reserves capacity sized to a safe upper bound.)

- [ ] **Step 2: Add tests** to `src/schema.zig`:

```zig
fn collectErrors(c: Collection) !std.ArrayList(ValidationError) {
    var list = try std.ArrayList(ValidationError).initCapacity(std.testing.allocator, 64);
    validate(c, &list);
    return list;
}

test "valid collection produces no errors" {
    const fields = [_]Field{
        .{ .id = "aaaaaaaa", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "bbbbbbbb", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    var errs = try collectErrors(.{ .id = "c1", .name = "posts", .fields = &fields });
    defer errs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), errs.items.len);
}

test "invalid name, reserved field, duplicate, bad scale, empty select are caught" {
    const fields = [_]Field{
        .{ .id = "a", .name = "id", .options = .{ .text = .{} } },        // reserved
        .{ .id = "b", .name = "x", .options = .{ .number = .{ .mode = .fixed, .scale = null } } }, // bad scale
        .{ .id = "c", .name = "x", .options = .{ .text = .{} } },          // duplicate of previous
        .{ .id = "d", .name = "tags", .options = .{ .select = .{ .values = &.{}, .maxSelect = 2 } } }, // empty values
    };
    var errs = try collectErrors(.{ .id = "c1", .name = "1bad", .fields = &fields }); // bad collection name
    defer errs.deinit(std.testing.allocator);
    try std.testing.expect(errs.items.len >= 5);
}

test "sqlType mapping" {
    const tf = Field{ .id = "a", .name = "t", .options = .{ .text = .{} } };
    const nf = Field{ .id = "b", .name = "n", .options = .{ .number = .{ .mode = .float } } };
    const nif = Field{ .id = "c", .name = "m", .options = .{ .number = .{ .mode = .int } } };
    const bf = Field{ .id = "d", .name = "b", .options = .{ .@"bool" = .{} } };
    try std.testing.expectEqualStrings("TEXT", tf.sqlType());
    try std.testing.expectEqualStrings("REAL", nf.sqlType());
    try std.testing.expectEqualStrings("INTEGER", nif.sqlType());
    try std.testing.expectEqualStrings("INTEGER", bf.sqlType());
}
```

- [ ] **Step 3: Aggregate** — add `_ = @import("schema.zig");` to the `test {}` block in `src/main.zig`.

- [ ] **Step 4: Run** `mise exec zig@0.16.0 -- zig build test`. Expect PASS. If `std.ArrayList.initCapacity`/`deinit` signatures differ in this 0.16 std (ArrayList took an allocator-per-call change), adjust the test helper to the working form (e.g. `var list = std.ArrayList(ValidationError){}; try list.ensureTotalCapacity(alloc, 64);`) and match `appendAssumeCapacity`. Report the form you used.

- [ ] **Step 5: Commit**
```bash
git add src/schema.zig src/main.zig
git commit -m "feat(schema): field/collection model and validation"
```

---

## Task 4: `schema.zig` — JSON (de)serialization

**Files:** Modify `src/schema.zig`.

Parse/serialize a collection's `fields` and `indexes` from/to JSON using the dynamic `std.json.Value` tree (options are type-dependent, so struct reflection won't do). All produced slices are allocated from the caller's allocator (the engine passes an arena).

- [ ] **Step 1: Add tests first** to `src/schema.zig` (TDD):

```zig
test "round-trip fields through json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fields = [_]Field{
        .{ .id = "aaaaaaaa", .name = "title", .required = true, .options = .{ .text = .{ .max = 200 } } },
        .{ .id = "bbbbbbbb", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
        .{ .id = "cccccccc", .name = "tags", .options = .{ .select = .{ .values = &.{ "a", "b" }, .maxSelect = 3 } } },
        .{ .id = "dddddddd", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .cascadeDelete = true } } },
    };
    const jsonStr = try fieldsToJson(a, &fields);
    const back = try fieldsFromJson(a, jsonStr);
    try std.testing.expectEqual(fields.len, back.len);
    try std.testing.expectEqualStrings("title", back[0].name);
    try std.testing.expect(back[0].required);
    try std.testing.expectEqual(@as(?u32, 200), back[0].options.text.max);
    try std.testing.expectEqual(NumberMode.fixed, back[1].options.number.mode);
    try std.testing.expectEqual(@as(?u8, 2), back[1].options.number.scale);
    try std.testing.expectEqual(@as(usize, 2), back[2].options.select.values.len);
    try std.testing.expectEqualStrings("users", back[3].options.relation.targetCollectionId);
    try std.testing.expect(back[3].options.relation.cascadeDelete);
}

test "indexes round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const idx = [_]Index{.{ .name = "idx_title", .fields = &.{"title"}, .unique = true }};
    const s = try indexesToJson(a, &idx);
    const back = try indexesFromJson(a, s);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("idx_title", back[0].name);
    try std.testing.expect(back[0].unique);
}
```

- [ ] **Step 2: Implement the four functions** in `src/schema.zig`. Structure (implement to satisfy the tests above — write each `options` arm explicitly):

```zig
const json = std.json;

pub const ParseError = error{ InvalidSchema, UnknownFieldType, OutOfMemory };

/// Serialize fields to a JSON array string. Each field: {id,name,required,unique,type,options:{...}}.
pub fn fieldsToJson(alloc: std.mem.Allocator, fields: []const Field) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    var w = json.Stringify{ .writer = ... }; // use the streaming writer over `out`
    // Build an array; for each field write the object, then write "type" = @tagName(field.options)
    // and an "options" object whose keys depend on the active union tag (switch on field.options).
    // ... explicit per-type option writing ...
    return out.toOwnedSlice(alloc);
}

/// Parse a JSON array string into []Field allocated from `alloc`.
pub fn fieldsFromJson(alloc: std.mem.Allocator, s: []const u8) ![]Field {
    const parsed = try json.parseFromSlice(json.Value, alloc, s, .{});
    // parsed.value must be .array; for each element (.object):
    //   read "id","name","required","unique","type"(string) -> FieldType
    //   switch on FieldType to read the matching "options" object into the union variant,
    //   dup'ing any strings/arrays into `alloc`.
    // Return the built slice.
}

pub fn indexesToJson(alloc: std.mem.Allocator, idx: []const Index) ![]u8 { ... }
pub fn indexesFromJson(alloc: std.mem.Allocator, s: []const u8) ![]Index { ... }
```

Implementation guidance (the test is the contract — make it pass):
- For **serialization**, the simplest robust path is to build a `std.json.Value` tree (objects/arrays via `std.json.ObjectMap`/`Array`) and call `std.json.Stringify.valueAlloc(alloc, root, .{})`. Switch on `field.options` to populate the per-type options object. This avoids manual streaming-writer details.
- For **parsing**, walk the `std.json.Value` tree manually. Helper: `fn getStr(obj, key) ?[]const u8`, `fn getBool(obj, key, default) bool`, `fn getU32(obj, key) ?u32` (handle `.integer`). `obj.get(key)` returns `?Value`. For arrays of strings (`select.values`, index `fields`), iterate `.array.items` collecting `.string`.
- A field's `type` string maps to `FieldType` via `std.meta.stringToEnum(FieldType, s) orelse return error.UnknownFieldType`. Note the enum has `@"bool"` — `@tagName`/`stringToEnum` use the string `"bool"`, which is what we want in JSON.
- Allocate every returned string with `alloc` (use `alloc.dupe(u8, ...)`), since the parsed `Value` tree (and its arena) is owned by `parsed` and freed when it goes out of scope — but here `alloc` IS the caller's arena and we pass `.{}` so `parseFromSlice` allocates into `alloc` too; keep the `parsed` alive by NOT calling `parsed.deinit()` when `alloc` is an arena. Simplest and safe: dupe everything you keep into `alloc`, and the arena frees all.

- [ ] **Step 3: Run** `mise exec zig@0.16.0 -- zig build test`. Iterate until the round-trip tests pass. If `std.json.ObjectMap.put`/`Array.append` need an allocator argument in this std, thread the arena through. Report the exact serialization approach used (tree+valueAlloc vs streaming).

- [ ] **Step 4: Commit**
```bash
git add src/schema.zig
git commit -m "feat(schema): json (de)serialization of fields and indexes"
```

---

## Task 5: `ddl.zig` — table & index SQL generation

**Files:** Create `src/ddl.zig`; Modify `src/main.zig`.

Pure SQL string generation from `schema` types. No DB access. All identifiers come from validated names, but still quote them defensively.

- [ ] **Step 1: Write tests first** in `src/ddl.zig`:

```zig
const std = @import("std");
const schema = @import("schema.zig");

test "createTableSql includes system columns, field columns, and FK for single relation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]schema.Field{
        .{ .id = "a", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "b", .name = "price", .options = .{ .number = .{ .mode = .float } } },
        .{ .id = "c", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .cascadeDelete = true, .maxSelect = 1 } } },
    };
    const col = schema.Collection{ .id = "c1", .name = "posts", .fields = &fields };
    const sql = try createTableSql(a, col, "users"); // target table name resolved by caller
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"id\" TEXT PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"created\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"title\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"price\" REAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "FOREIGN KEY (\"author\") REFERENCES \"users\" (\"id\") ON DELETE CASCADE") != null);
}

test "createIndexSql builds unique and non-unique" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try createIndexSql(a, "posts", .{ .name = "idx_title", .fields = &.{"title"}, .unique = true });
    try std.testing.expectEqualStrings("CREATE UNIQUE INDEX \"idx_title\" ON \"posts\" (\"title\");", u);
    const n = try createIndexSql(a, "posts", .{ .name = "idx_ab", .fields = &.{ "a", "b" }, .unique = false });
    try std.testing.expectEqualStrings("CREATE INDEX \"idx_ab\" ON \"posts\" (\"a\",\"b\");", n);
}
```

- [ ] **Step 2: Implement** in `src/ddl.zig`:

```zig
/// Double-quote a SQL identifier, escaping embedded quotes.
pub fn quoteIdent(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    try out.append(alloc, '"');
    for (name) |ch| {
        if (ch == '"') try out.append(alloc, '"');
        try out.append(alloc, ch);
    }
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

/// `"name" TYPE` for one field (no constraints).
pub fn columnDef(alloc: std.mem.Allocator, f: schema.Field) ![]u8 {
    return std.fmt.allocPrint(alloc, "\"{s}\" {s}", .{ f.name, f.sqlType() });
}

/// Full CREATE TABLE for a collection. `relTargetName(field)` is resolved by the caller and
/// passed per single-relation field; here we accept a single target name for simplicity in the
/// test, but the engine supplies a lookup. (Engine in Task 7 builds the FK clauses itself if
/// multiple relations exist — see note.)
pub fn createTableSql(alloc: std.mem.Allocator, c: schema.Collection, single_rel_target: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "CREATE TABLE ");
    const tbl = try quoteIdent(alloc, c.name);
    try out.appendSlice(alloc, tbl);
    try out.appendSlice(alloc, " (\"id\" TEXT PRIMARY KEY, \"created\" TEXT, \"updated\" TEXT");
    for (c.fields) |f| {
        try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, try columnDef(alloc, f));
    }
    // Foreign keys for single-value relations.
    for (c.fields) |f| {
        switch (f.options) {
            .relation => |r| if (r.maxSelect == 1) {
                const target = single_rel_target orelse r.targetCollectionId;
                const on_delete = if (r.cascadeDelete) "CASCADE" else "SET NULL";
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ", FOREIGN KEY (\"{s}\") REFERENCES \"{s}\" (\"id\") ON DELETE {s}", .{ f.name, target, on_delete }));
            },
            else => {},
        }
    }
    try out.appendSlice(alloc, ");");
    return out.toOwnedSlice(alloc);
}

pub fn createIndexSql(alloc: std.mem.Allocator, table: []const u8, idx: schema.Index) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, if (idx.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\" ON \"{s}\" (", .{ idx.name, table }));
    for (idx.fields, 0..) |fname, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{fname}));
    }
    try out.appendSlice(alloc, ");");
    return out.toOwnedSlice(alloc);
}
```

Note on `single_rel_target`: the test passes one target name. In the engine (Task 7), relations reference a target **collection id**; the engine resolves each to the target's table name before building FK clauses. If a collection has multiple single-relations to different targets, the engine constructs the table SQL by composing `columnDef` + its own FK clause builder rather than relying on a single target param. Keep `createTableSql` flexible: if you find the single-target param too limiting while doing Task 7, change its signature to accept a small `targets: []const struct{ field: []const u8, table: []const u8 }` and update this test accordingly.

- [ ] **Step 3: Aggregate** — add `_ = @import("ddl.zig");` to `src/main.zig` `test {}`.

- [ ] **Step 4: Run** `mise exec zig@0.16.0 -- zig build test`. Expect PASS. If `std.ArrayList(u8)` empty-init `.{}` + `append(alloc, x)` differs in this std, use the working ArrayList form consistently (same as Task 3 resolution) and report it.

- [ ] **Step 5: Commit**
```bash
git add src/ddl.zig src/main.zig
git commit -m "feat(ddl): CREATE TABLE/INDEX generation with relation FKs"
```

---

## Task 6: `ddl.zig` — rebuild plan (diff by field id)

**Files:** Modify `src/ddl.zig`.

`update` = generalized SQLite rebuild. This task produces the ordered statement list; the engine executes it (Task 8).

- [ ] **Step 1: Write tests first** in `src/ddl.zig`:

```zig
test "rebuildPlan copies retained columns by field id, adds new, drops removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old_fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "old_price", .options = .{ .number = .{ .mode = .float } } },
    };
    const new_fields = [_]schema.Field{
        .{ .id = "f1", .name = "headline", .options = .{ .text = .{} } },          // renamed (same id)
        .{ .id = "f3", .name = "views", .options = .{ .number = .{ .mode = .int } } }, // added
    };
    const old = schema.Collection{ .id = "c1", .name = "posts", .fields = &old_fields };
    const new = schema.Collection{ .id = "c1", .name = "posts", .fields = &new_fields };

    const plan = try rebuildPlan(a, old, new);
    // Expect: CREATE TABLE posts__new (...), INSERT ... SELECT ..., DROP, RENAME.
    try std.testing.expect(plan.len >= 4);
    try std.testing.expect(std.mem.indexOf(u8, plan[0], "\"posts__new\"") != null);
    // retained field f1 copied old col "title" -> new col "headline"
    const insert = plan[1];
    try std.testing.expect(std.mem.indexOf(u8, insert, "INSERT INTO \"posts__new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert, "\"headline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert, "\"title\"") != null); // source column
    try std.testing.expect(std.mem.indexOf(u8, insert, "DROP TABLE \"posts\"") == null); // drop is its own stmt
    try std.testing.expect(std.mem.indexOf(u8, plan[plan.len - 1], "RENAME TO \"posts\"") != null);
}
```

- [ ] **Step 2: Implement `rebuildPlan`** in `src/ddl.zig`:

```zig
/// Ordered statements to migrate `old` -> `new` in one transaction.
/// Caller wraps these between `PRAGMA foreign_keys=OFF;`/`ON;` and a transaction (Task 8).
pub fn rebuildPlan(alloc: std.mem.Allocator, old: schema.Collection, new: schema.Collection) ![]const []u8 {
    var stmts: std.ArrayList([]u8) = .{};
    errdefer stmts.deinit(alloc);

    const tmp = try std.fmt.allocPrint(alloc, "{s}__new", .{new.name});
    // 1. CREATE TABLE <tmp> with new schema. Reuse createTableSql by building a temp Collection
    //    whose name is <tmp>.
    var tmp_col = new;
    tmp_col.name = tmp;
    try stmts.append(alloc, try createTableSql(alloc, tmp_col, null));

    // 2. INSERT INTO <tmp> (id,created,updated,<new cols...>) SELECT id,created,updated,<src...> FROM <old.name>
    //    For each new field, find the old field with the same id:
    //      - found  -> source column is the OLD field's name (CAST to new type if affinity changed)
    //      - absent -> source expression is NULL
    var new_cols: std.ArrayList(u8) = .{};
    var src_cols: std.ArrayList(u8) = .{};
    try new_cols.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    try src_cols.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    for (new.fields) |nf| {
        try new_cols.append(alloc, ',');
        try new_cols.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{nf.name}));
        try src_cols.append(alloc, ',');
        const old_match = blk: {
            for (old.fields) |of| {
                if (std.mem.eql(u8, of.id, nf.id)) break :blk of;
            }
            break :blk null;
        };
        if (old_match) |of| {
            if (std.mem.eql(u8, of.sqlType(), nf.sqlType())) {
                try src_cols.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{of.name}));
            } else {
                try src_cols.appendSlice(alloc, try std.fmt.allocPrint(alloc, "CAST(\"{s}\" AS {s})", .{ of.name, nf.sqlType() }));
            }
        } else {
            try src_cols.appendSlice(alloc, "NULL");
        }
    }
    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "INSERT INTO \"{s}\" ({s}) SELECT {s} FROM \"{s}\";", .{ tmp, new_cols.items, src_cols.items, old.name }));

    // 3. DROP old, 4. RENAME tmp -> name
    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "DROP TABLE \"{s}\";", .{old.name}));
    try stmts.append(alloc, try std.fmt.allocPrint(alloc, "ALTER TABLE \"{s}\" RENAME TO \"{s}\";", .{ tmp, new.name }));

    // 5. recreate indexes
    for (new.indexes) |idx| try stmts.append(alloc, try createIndexSql(alloc, new.name, idx));

    return stmts.toOwnedSlice(alloc);
}
```

- [ ] **Step 3: Run** `mise exec zig@0.16.0 -- zig build test`. Expect PASS.

- [ ] **Step 4: Commit**
```bash
git add src/ddl.zig
git commit -m "feat(ddl): rebuild plan with by-field-id column mapping"
```

---

## Task 7: `migrations.zig` — runner + `0001_init`, and `collections.zig` create/get/list

This task is split into two commits but one dispatch: the migrations runner (so `_collections` exists), then the engine's read/create paths.

**Files:** Create `src/migrations.zig`, `src/collections.zig`; Modify `src/main.zig`.

### 7a — migrations runner

- [ ] **Step 1: Write `src/migrations.zig`**

```zig
const std = @import("std");
const db = @import("db.zig");

pub const Migration = struct { name: []const u8, up: *const fn (w: *db.Db) db.DbError!void };

fn init_0001(w: *db.Db) db.DbError!void {
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_collections" (
        \\  "id" TEXT PRIMARY KEY, "name" TEXT UNIQUE NOT NULL, "type" TEXT NOT NULL DEFAULT 'base',
        \\  "system" INTEGER NOT NULL DEFAULT 0, "schema" TEXT NOT NULL DEFAULT '[]',
        \\  "indexes" TEXT NOT NULL DEFAULT '[]',
        \\  "listRule" TEXT, "viewRule" TEXT, "createRule" TEXT, "updateRule" TEXT, "deleteRule" TEXT,
        \\  "created" TEXT NOT NULL, "updated" TEXT NOT NULL
        \\);
    );
}

pub const all = [_]Migration{
    .{ .name = "0001_init", .up = init_0001 },
};

/// Ensure the _migrations table exists, then apply any unapplied migrations in order.
pub fn run(w: *db.Db) db.DbError!void {
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_migrations" (
        \\  "id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT UNIQUE NOT NULL, "applied_at" TEXT NOT NULL
        \\);
    );
    for (all) |m| {
        if (try isApplied(w, m.name)) continue;
        try w.begin();
        errdefer w.rollback() catch {};
        try m.up(w);
        try recordApplied(w, m.name);
        try w.commit();
    }
}

fn isApplied(w: *db.Db, name: []const u8) db.DbError!bool {
    var st = try w.prepare("SELECT 1 FROM \"_migrations\" WHERE \"name\" = ?1;");
    defer st.finalize();
    try st.bindText(1, name);
    return try st.step();
}

fn recordApplied(w: *db.Db, name: []const u8) db.DbError!void {
    var st = try w.prepare("INSERT INTO \"_migrations\" (\"name\", \"applied_at\") VALUES (?1, datetime('now'));");
    defer st.finalize();
    try st.bindText(1, name);
    _ = try st.step();
}

test "migrations apply once and are idempotent" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    try run(&d); // second run is a no-op
    var st = try d.prepare("SELECT COUNT(*) FROM \"_migrations\";");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
    // _collections exists
    var c = try d.prepare("SELECT COUNT(*) FROM \"_collections\";");
    defer c.finalize();
    try std.testing.expect((try c.step()));
}
```

- [ ] **Step 2: Aggregate** — add `_ = @import("migrations.zig");` to `src/main.zig` `test {}`. Run tests, expect PASS. If `datetime('now')` is undesired, RFC3339 timestamps come later; this is fine for the system table.

- [ ] **Step 3: Commit**
```bash
git add src/migrations.zig src/main.zig
git commit -m "feat(migrations): runner + 0001_init system schema"
```

### 7b — engine: create / get / list

- [ ] **Step 4: Write tests first** in `src/collections.zig`:

```zig
const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const migrations = @import("migrations.zig");

test "create persists a collection and builds its physical table" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    const def = schema.Collection{ .id = "", .name = "posts", .fields = &fields };
    const created = try create(arena.allocator(), std.testing.io, &d, def);
    try std.testing.expect(created.id.len == 15);

    // physical table exists with the field columns
    var st = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('posts') WHERE name IN ('id','created','updated','title','price');");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqual(@as(i64, 5), st.columnInt(0));

    // round-trips through get/list
    const got = (try get(arena.allocator(), &d, "posts")).?;
    try std.testing.expectEqualStrings("posts", got.name);
    try std.testing.expectEqual(@as(usize, 2), got.fields.len);
    const all = try list(arena.allocator(), &d);
    try std.testing.expectEqual(@as(usize, 1), all.len);
}

test "create rejects an invalid collection" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const def = schema.Collection{ .id = "", .name = "1bad", .fields = &.{} };
    try std.testing.expectError(error.Validation, create(arena.allocator(), std.testing.io, &d, def));
}
```

- [ ] **Step 5: Implement create/get/list** in `src/collections.zig`:

```zig
const ddl = @import("ddl.zig");
const id = @import("id.zig");

pub const EngineError = error{ Validation, NotFound, Conflict } || db.DbError || error{OutOfMemory} || schema.ParseError;

/// Validation failures captured for the caller (2b surfaces them in the response envelope).
pub threadlocal var last_errors: ?[]const schema.ValidationError = null;

pub fn create(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, def: schema.Collection) EngineError!schema.Collection {
    // 1. assign ids: collection id (15) + a field id (8) for any field with an empty id.
    var fields = try alloc.alloc(schema.Field, def.fields.len);
    for (def.fields, 0..) |f, i| {
        fields[i] = f;
        if (f.id.len == 0) fields[i].id = try alloc.dupe(u8, &id.fieldId(io));
    }
    var col = def;
    col.fields = fields;
    col.id = try alloc.dupe(u8, &id.collectionId(io));

    // 2. validate
    var errs = try std.ArrayList(schema.ValidationError).initCapacity(alloc, def.fields.len * 4 + 8);
    schema.validate(col, &errs);
    if (errs.items.len > 0) { last_errors = errs.items; return error.Validation; }

    // 3. DDL + persist in one transaction
    try w.begin();
    errdefer w.rollback() catch {};
    const create_sql = try toSentinel(alloc, try ddl.createTableSql(alloc, col, null));
    try w.exec(create_sql);
    for (col.indexes) |idx| try w.exec(try toSentinel(alloc, try ddl.createIndexSql(alloc, col.name, idx)));
    try insertRow(alloc, w, col);
    try w.commit();
    return col;
}

pub fn get(alloc: std.mem.Allocator, w: *db.Db, id_or_name: []const u8) EngineError!?schema.Collection { ... }
pub fn list(alloc: std.mem.Allocator, w: *db.Db) EngineError![]schema.Collection { ... }
```

Implementation guidance:
- `toSentinel(alloc, s) ![:0]u8` = `alloc.dupeZ(u8, s)` — `Db.exec` needs `[:0]const u8`.
- `insertRow` binds id/name/type/system/schema(JSON via `schema.fieldsToJson`)/indexes(JSON)/rules/created/updated and executes an INSERT into `_collections`. Use `datetime('now')` or an RFC3339 string for created/updated (consistency with records comes in SP3 — `datetime('now')` is acceptable here).
- `get`/`list` SELECT from `_collections`, read columns, and use `schema.fieldsFromJson`/`indexesFromJson` to rebuild `fields`/`indexes`. `get` matches `id` OR `name` (try id first, then name).
- The `last_errors` threadlocal is a pragmatic channel for validation details until 2b introduces a richer result type; 2b will read it right after an `error.Validation`.

- [ ] **Step 6: Run** `mise exec zig@0.16.0 -- zig build test`. Expect PASS. If `std.Io` is the right type name for the `io` param (it is — `std.Io`), and `alloc.dupe(u8, &id.fieldId(io))` (taking address of a returned array) needs a `var`, bind it to a local first: `var fid = id.fieldId(io); ... alloc.dupe(u8, &fid)`. Adjust as the compiler requires.

- [ ] **Step 7: Commit**
```bash
git add src/collections.zig src/main.zig
git commit -m "feat(collections): create/get/list engine operations"
```

---

## Task 8: `collections.zig` — update (rebuild) & delete

**Files:** Modify `src/collections.zig`.

- [ ] **Step 1: Write tests first** in `src/collections.zig`:

```zig
test "update rebuilds table and preserves data across a field rename" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const f0 = [_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
    const created = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &f0 });
    try d.exec("INSERT INTO posts (id, created, updated, title) VALUES ('r1','t','t','hello');");

    // rename title->headline (same field id) and add a column
    const f1 = [_]schema.Field{
        .{ .id = "f1", .name = "headline", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "views", .options = .{ .number = .{ .mode = .int } } },
    };
    var newdef = created;
    newdef.fields = &f1;
    _ = try update(a, &d, created.id, newdef);

    var st = try d.prepare("SELECT headline, views FROM posts WHERE id='r1';");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqualStrings("hello", st.columnText(0)); // data preserved through rename
    try std.testing.expect(st.isNull(1));                          // new column is NULL
}

test "delete drops the table; delete refuses when referenced by a relation" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const users = try create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &.{} });
    const pf = [_]schema.Field{.{ .id = "f1", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    _ = try create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });

    try std.testing.expectError(error.Conflict, delete(a, &d, "users")); // posts references users
    try delete(a, &d, "posts");
    try delete(a, &d, "users"); // now allowed
    try std.testing.expect((try get(a, &d, "posts")) == null);
}
```

- [ ] **Step 2: Implement update/delete** in `src/collections.zig`:

```zig
pub fn update(alloc: std.mem.Allocator, w: *db.Db, id_or_name: []const u8, newdef: schema.Collection) EngineError!schema.Collection {
    const old = (try get(alloc, w, id_or_name)) orelse return error.NotFound;

    // assign ids to any new fields lacking one (preserve existing ids!)
    // validate newdef (capacity-reserved list); on errors set last_errors, return error.Validation.
    var errs = try std.ArrayList(schema.ValidationError).initCapacity(alloc, newdef.fields.len * 4 + 8);
    schema.validate(newdef, &errs);
    if (errs.items.len > 0) { last_errors = errs.items; return error.Validation; }

    try w.exec("PRAGMA foreign_keys=OFF;");
    try w.begin();
    errdefer w.rollback() catch {};
    const plan = try ddl.rebuildPlan(alloc, old, newdef);
    for (plan) |stmt| try w.exec(try alloc.dupeZ(u8, stmt));
    try updateRow(alloc, w, old.id, newdef); // UPDATE _collections SET schema/indexes/updated...
    try w.commit();
    try w.exec("PRAGMA foreign_keys=ON;");
    var result = newdef;
    result.id = old.id;
    return result;
}

pub fn delete(alloc: std.mem.Allocator, w: *db.Db, id_or_name: []const u8) EngineError!void {
    const target = (try get(alloc, w, id_or_name)) orelse return error.NotFound;
    // refuse if any other collection has a relation whose targetCollectionId == target.id
    const all = try list(alloc, w);
    for (all) |c| {
        if (std.mem.eql(u8, c.id, target.id)) continue;
        for (c.fields) |f| switch (f.options) {
            .relation => |r| if (std.mem.eql(u8, r.targetCollectionId, target.id)) return error.Conflict,
            else => {},
        };
    }
    try w.begin();
    errdefer w.rollback() catch {};
    try w.exec(try std.fmt.allocPrintSentinel(alloc, "DROP TABLE \"{s}\";", .{target.name}, 0));
    var st = try w.prepare("DELETE FROM \"_collections\" WHERE \"id\" = ?1;");
    defer st.finalize();
    try st.bindText(1, target.id);
    _ = try st.step();
    try w.commit();
}
```

Note: re-enabling `foreign_keys` after `commit` is correct (the pragma is a no-op inside a transaction in SQLite; setting it OFF must happen outside/at connection level — if the `PRAGMA foreign_keys=OFF` inside fails to take effect mid-transaction, move both pragmas to wrap the `begin`/`commit` entirely, i.e. OFF → begin → ... → commit → ON). Verify with the delete-referenced test and the rebuild test passing; adjust pragma placement if SQLite complains.

- [ ] **Step 3: Run** `mise exec zig@0.16.0 -- zig build test`. Expect PASS. The rename-preserves-data assertion is the key signal that field-id mapping works.

- [ ] **Step 4: Commit**
```bash
git add src/collections.zig
git commit -m "feat(collections): update via rebuild + guarded delete"
```

---

## Self-Review (completed by plan author)

**Spec coverage (SP2 design §1–§6, the engine-side):**
- System tables + migration runner → Task 7a ✓ (`_collections`,`_migrations`,`0001_init`,`migrate`-able runner; the `migrate` CLI command itself is 2b).
- Field model incl. number mode, full relations, file stub, stable field ids → Tasks 3,4 ✓.
- Validation → Task 3 ✓.
- JSON (de)serialization → Task 4 ✓.
- DDL gen + FK for single relations → Task 5 ✓.
- Rebuild diff by field id (rename/add/remove/type-change CAST) → Task 6 ✓.
- Engine create/get/list/update/delete + referenced-delete guard → Tasks 7b,8 ✓.
- id generator → Task 1 ✓; Stmt helpers → Task 2 ✓.
- **Deferred to Plan 2b (intentional):** error-envelope validation `data`, `App`/`RequestCtx`/router, `api/collections.zig` REST handlers, `server.zig`/`main.zig`/`cli.zig` wiring, `migrate` CLI command, `setZapStatus` extension, manual curl smoke. Engine validation details are surfaced now via `collections.last_errors` for 2b to consume.

**Type consistency:** `schema.Field/Collection/FieldOptions/FieldType/NumberMode/Index/ValidationError`, `Field.sqlType()/fieldType()/isMultiValue()`, `ddl.createTableSql/createIndexSql/columnDef/quoteIdent/rebuildPlan`, `collections.create/get/list/update/delete` + `EngineError` + `last_errors`, `migrations.run/all/Migration`, `id.generate/collectionId/fieldId`, `db.Stmt.columnDouble/columnType/isNull` — referenced consistently across tasks.

**Placeholder scan:** Tasks 1–3, 5, 6, 7a, 8 contain complete code. Tasks 4 and 7b give complete TEST code (the behavioral contract) plus full function signatures and structured implementations with `...` only inside bodies whose behavior the tests pin exactly; these are explicitly flagged "implement to satisfy these tests," with concrete guidance on the std.json tree walk and memory handling — not vague hand-waving. This is a deliberate altitude choice for the two genuinely fiddly modules (union JSON, engine orchestration) where literal pre-written code would risk subtle 0.16 mismatches; the tests make them TDD-sound.
