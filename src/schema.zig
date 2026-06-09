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
    hidden: bool = false,
    options: FieldOptions,

    pub fn fieldType(self: Field) FieldType {
        return std.meta.activeTag(self.options);
    }

    pub fn sqlType(self: Field) []const u8 {
        return switch (self.options) {
            .@"bool" => "INTEGER",
            .number => |n| if (n.mode == .float) "REAL" else "INTEGER",
            else => "TEXT",
        };
    }

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
    options: CollectionOptions = .{},
    created: []const u8 = "",
    updated: []const u8 = "",
};

pub const AuthOptions = struct {
    identityFields: []const []const u8 = &.{"email"},
    minPasswordLength: u8 = 8,
};
pub const CollectionOptions = struct {
    auth: AuthOptions = .{},
};

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

/// Find a field by exact name (case-sensitive). Returns null if absent.
pub fn fieldByName(c: Collection, name: []const u8) ?Field {
    for (c.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

test "fieldByName finds and misses" {
    const fields = [_]Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
    const c = Collection{ .id = "c", .name = "posts", .fields = &fields };
    try std.testing.expect(fieldByName(c, "title") != null);
    try std.testing.expect(fieldByName(c, "missing") == null);
}

/// Names reserved by the engine (base + auth system columns); user fields may not use them.
pub fn isSystemFieldName(name: []const u8) bool {
    // case-insensitive: SQLite column names collide case-insensitively
    const reserved = [_][]const u8{ "id", "created", "updated", "email", "username", "passwordHash", "tokenKey", "verified" };
    for (reserved) |r| if (std.ascii.eqlIgnoreCase(name, r)) return true;
    return false;
}

/// The implicit system fields of an auth collection (beyond id/created/updated).
/// passwordHash/tokenKey are hidden (never serialized). Stable ids (leading '_').
pub fn authSystemFields() []const Field {
    const S = struct {
        const fields = [_]Field{
            .{ .id = "_email", .name = "email", .options = .{ .email = .{} } }, // uniqueness via partial unique index (see ddl.authIdentityIndexSql)
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

pub const Index = struct { name: []const u8, fields: []const []const u8, unique: bool = false };

pub const ValidationError = struct { field: []const u8, code: []const u8, message: []const u8 };

pub fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

/// Appends any validation problems to `errors`. Self-sizing; messages/codes are static or borrowed from `c`.
pub fn validate(alloc: std.mem.Allocator, c: Collection, errors: *std.ArrayList(ValidationError)) std.mem.Allocator.Error!void {
    if (!isValidIdentifier(c.name))
        try errors.append(alloc, .{ .field = "name", .code = "validation_invalid_name", .message = "Name must start with a letter and contain only letters, digits, and underscores." });

    for (c.fields, 0..) |f, i| {
        if (!isValidIdentifier(f.name)) {
            try errors.append(alloc, .{ .field = f.name, .code = "validation_invalid_name", .message = "Invalid field name." });
            continue;
        }
        if (isSystemFieldName(f.name)) {
            try errors.append(alloc, .{ .field = f.name, .code = "validation_reserved_name", .message = "Field name is reserved." });
        }
        for (c.fields[0..i]) |g| {
            if (std.ascii.eqlIgnoreCase(f.name, g.name))
                try errors.append(alloc, .{ .field = f.name, .code = "validation_duplicate_name", .message = "Duplicate field name." });
        }
        switch (f.options) {
            .select => |o| if (o.values.len == 0)
                try errors.append(alloc, .{ .field = f.name, .code = "validation_required", .message = "select requires at least one value." }),
            .number => |o| if (o.mode == .fixed and (o.scale == null or o.scale.? < 1 or o.scale.? > 8))
                try errors.append(alloc, .{ .field = f.name, .code = "validation_invalid_scale", .message = "fixed number requires scale 1..8." }),
            .relation => |o| if (o.targetCollectionId.len == 0)
                try errors.append(alloc, .{ .field = f.name, .code = "validation_required", .message = "relation requires targetCollectionId." }),
            else => {},
        }
    }

    for (c.indexes) |idx| {
        if (!isValidIdentifier(idx.name))
            try errors.append(alloc, .{ .field = idx.name, .code = "validation_invalid_name", .message = "Invalid index name." });
        for (idx.fields) |fname| {
            if (!isValidIdentifier(fname))
                try errors.append(alloc, .{ .field = fname, .code = "validation_invalid_name", .message = "Invalid index field name." });
        }
    }

    // Auth identity fields are interpolated into SQL/DDL, so they must be valid identifiers.
    if (c.type == .auth) {
        for (c.options.auth.identityFields) |idf| {
            if (!isValidIdentifier(idf))
                try errors.append(alloc, .{ .field = "identityFields", .code = "validation_invalid_identity_field", .message = "Identity field must be a valid identifier." });
        }
    }
}

// ---------------------------------------------------------------------------
// JSON (de)serialization
//
// Serialization builds a `std.json.Value` tree and calls
// `std.json.Stringify.valueAlloc`. Parsing walks the dynamic `std.json.Value`
// tree from `parseFromSlice`. Every string/array we retain is `dupe`d into the
// caller's `alloc` (expected to be an arena), so the parsed tree may be freed
// safely — we own all retained memory.
// ---------------------------------------------------------------------------

pub const ParseError = error{ InvalidSchema, UnknownFieldType, OutOfMemory };

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

fn jStr(s: []const u8) Value {
    return .{ .string = s };
}
fn jBool(b: bool) Value {
    return .{ .bool = b };
}
fn jInt(i: anytype) !Value {
    return .{ .integer = std.math.cast(i64, i) orelse return error.InvalidSchema };
}

fn putOpt(alloc: std.mem.Allocator, obj: *ObjectMap, key: []const u8, v: ?Value) !void {
    if (v) |val| try obj.put(alloc, key, val);
}

fn fieldToValue(alloc: std.mem.Allocator, f: Field) !Value {
    var obj: ObjectMap = .empty;
    try obj.put(alloc, "id", jStr(f.id));
    try obj.put(alloc, "name", jStr(f.name));
    try obj.put(alloc, "required", jBool(f.required));
    try obj.put(alloc, "unique", jBool(f.unique));
    try obj.put(alloc, "type", jStr(@tagName(std.meta.activeTag(f.options))));

    var opts: ObjectMap = .empty;
    switch (f.options) {
        .text => |o| {
            try putOpt(alloc, &opts, "min", if (o.min) |x| try jInt(x) else null);
            try putOpt(alloc, &opts, "max", if (o.max) |x| try jInt(x) else null);
            try putOpt(alloc, &opts, "pattern", if (o.pattern) |x| jStr(x) else null);
        },
        .email, .url, .editor, .@"bool" => {},
        .date => |o| {
            try putOpt(alloc, &opts, "min", if (o.min) |x| jStr(x) else null);
            try putOpt(alloc, &opts, "max", if (o.max) |x| jStr(x) else null);
        },
        .autodate => |o| {
            try opts.put(alloc, "onCreate", jBool(o.onCreate));
            try opts.put(alloc, "onUpdate", jBool(o.onUpdate));
        },
        .number => |o| {
            try opts.put(alloc, "mode", jStr(@tagName(o.mode)));
            try putOpt(alloc, &opts, "scale", if (o.scale) |x| try jInt(x) else null);
            try putOpt(alloc, &opts, "min", if (o.min) |x| Value{ .float = x } else null);
            try putOpt(alloc, &opts, "max", if (o.max) |x| Value{ .float = x } else null);
        },
        .json => |o| {
            try putOpt(alloc, &opts, "maxSize", if (o.maxSize) |x| try jInt(x) else null);
        },
        .select => |o| {
            var arr = Array.init(alloc);
            for (o.values) |v| try arr.append(jStr(v));
            try opts.put(alloc, "values", .{ .array = arr });
            try opts.put(alloc, "maxSelect", try jInt(o.maxSelect));
        },
        .relation => |o| {
            try opts.put(alloc, "targetCollectionId", jStr(o.targetCollectionId));
            try opts.put(alloc, "cascadeDelete", jBool(o.cascadeDelete));
            try putOpt(alloc, &opts, "minSelect", if (o.minSelect) |x| try jInt(x) else null);
            try opts.put(alloc, "maxSelect", try jInt(o.maxSelect));
        },
        .file => |o| {
            try opts.put(alloc, "maxSelect", try jInt(o.maxSelect));
            try putOpt(alloc, &opts, "maxSize", if (o.maxSize) |x| try jInt(x) else null);
            if (o.mimeTypes) |mts| {
                var arr = Array.init(alloc);
                for (mts) |m| try arr.append(jStr(m));
                try opts.put(alloc, "mimeTypes", .{ .array = arr });
            }
        },
    }
    try obj.put(alloc, "options", .{ .object = opts });
    return .{ .object = obj };
}

pub fn fieldsToJson(alloc: std.mem.Allocator, fields: []const Field) ![]u8 {
    var arr = Array.init(alloc);
    for (fields) |f| try arr.append(try fieldToValue(alloc, f));
    const root = Value{ .array = arr };
    return std.json.Stringify.valueAlloc(alloc, root, .{});
}

pub fn indexesToJson(alloc: std.mem.Allocator, idx: []const Index) ![]u8 {
    var arr = Array.init(alloc);
    for (idx) |ix| {
        var obj: ObjectMap = .empty;
        try obj.put(alloc, "name", jStr(ix.name));
        var farr = Array.init(alloc);
        for (ix.fields) |fn_| try farr.append(jStr(fn_));
        try obj.put(alloc, "fields", .{ .array = farr });
        try obj.put(alloc, "unique", jBool(ix.unique));
        try arr.append(.{ .object = obj });
    }
    return std.json.Stringify.valueAlloc(alloc, Value{ .array = arr }, .{});
}

// --- parsing helpers ---

fn objGet(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn getStr(alloc: std.mem.Allocator, v: Value, key: []const u8) !?[]const u8 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    if (x != .string) return error.InvalidSchema;
    return try alloc.dupe(u8, x.string);
}

fn getBool(v: Value, key: []const u8, default: bool) bool {
    const x = objGet(v, key) orelse return default;
    return switch (x) {
        .bool => |b| b,
        else => default,
    };
}

fn asInt(x: Value) !i64 {
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (std.math.floor(f) == f and f >= -9.2233720368547758e18 and f < 9.2233720368547758e18)
            @intFromFloat(f)
        else
            error.InvalidSchema,
        else => error.InvalidSchema,
    };
}

fn getU32(v: Value, key: []const u8) !?u32 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    return std.math.cast(u32, try asInt(x)) orelse return error.InvalidSchema;
}

fn getU32Default(v: Value, key: []const u8, default: u32) !u32 {
    return (try getU32(v, key)) orelse default;
}

fn getU8(v: Value, key: []const u8) !?u8 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    return std.math.cast(u8, try asInt(x)) orelse return error.InvalidSchema;
}

fn getU64(v: Value, key: []const u8) !?u64 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    return std.math.cast(u64, try asInt(x)) orelse return error.InvalidSchema;
}

fn getF64(v: Value, key: []const u8) !?f64 {
    const x = objGet(v, key) orelse return null;
    return switch (x) {
        .null => null,
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.InvalidSchema,
    };
}

fn getStrArray(alloc: std.mem.Allocator, v: Value, key: []const u8) !?[]const []const u8 {
    const x = objGet(v, key) orelse return null;
    if (x == .null) return null;
    if (x != .array) return error.InvalidSchema;
    const items = x.array.items;
    const out = try alloc.alloc([]const u8, items.len);
    for (items, 0..) |it, i| {
        if (it != .string) return error.InvalidSchema;
        out[i] = try alloc.dupe(u8, it.string);
    }
    return out;
}

fn optionsFromValue(alloc: std.mem.Allocator, t: FieldType, opts: Value) !FieldOptions {
    return switch (t) {
        .text => .{ .text = .{
            .min = try getU32(opts, "min"),
            .max = try getU32(opts, "max"),
            .pattern = try getStr(alloc, opts, "pattern"),
        } },
        .email => .{ .email = .{} },
        .url => .{ .url = .{} },
        .editor => .{ .editor = .{} },
        .date => .{ .date = .{
            .min = try getStr(alloc, opts, "min"),
            .max = try getStr(alloc, opts, "max"),
        } },
        .autodate => .{ .autodate = .{
            .onCreate = getBool(opts, "onCreate", true),
            .onUpdate = getBool(opts, "onUpdate", false),
        } },
        .@"bool" => .{ .@"bool" = .{} },
        .number => blk: {
            var mode: NumberMode = .float;
            if (objGet(opts, "mode")) |m| {
                if (m == .string) mode = std.meta.stringToEnum(NumberMode, m.string) orelse return error.InvalidSchema;
            }
            break :blk .{ .number = .{
                .mode = mode,
                .scale = try getU8(opts, "scale"),
                .min = try getF64(opts, "min"),
                .max = try getF64(opts, "max"),
            } };
        },
        .json => .{ .json = .{ .maxSize = try getU32(opts, "maxSize") } },
        .select => .{ .select = .{
            .values = (try getStrArray(alloc, opts, "values")) orelse &.{},
            .maxSelect = try getU32Default(opts, "maxSelect", 1),
        } },
        .relation => .{ .relation = .{
            .targetCollectionId = (try getStr(alloc, opts, "targetCollectionId")) orelse "",
            .cascadeDelete = getBool(opts, "cascadeDelete", false),
            .minSelect = try getU32(opts, "minSelect"),
            .maxSelect = try getU32Default(opts, "maxSelect", 1),
        } },
        .file => .{ .file = .{
            .maxSelect = try getU32Default(opts, "maxSelect", 1),
            .maxSize = try getU64(opts, "maxSize"),
            .mimeTypes = try getStrArray(alloc, opts, "mimeTypes"),
        } },
    };
}

fn fieldFromValue(alloc: std.mem.Allocator, v: Value) !Field {
    if (v != .object) return error.InvalidSchema;
    const id = (try getStr(alloc, v, "id")) orelse return error.InvalidSchema;
    const name = (try getStr(alloc, v, "name")) orelse return error.InvalidSchema;
    const type_v = objGet(v, "type") orelse return error.InvalidSchema;
    if (type_v != .string) return error.InvalidSchema;
    const t = std.meta.stringToEnum(FieldType, type_v.string) orelse return error.UnknownFieldType;
    const opts = objGet(v, "options") orelse Value{ .object = .empty };
    return .{
        .id = id,
        .name = name,
        .required = getBool(v, "required", false),
        .unique = getBool(v, "unique", false),
        .options = try optionsFromValue(alloc, t, opts),
    };
}

pub fn fieldsFromJson(alloc: std.mem.Allocator, s: []const u8) ![]Field {
    var parsed = try std.json.parseFromSlice(Value, alloc, s, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return error.InvalidSchema;
    const items = root.array.items;
    const out = try alloc.alloc(Field, items.len);
    for (items, 0..) |it, i| out[i] = try fieldFromValue(alloc, it);
    return out;
}

pub fn indexesFromJson(alloc: std.mem.Allocator, s: []const u8) ![]Index {
    var parsed = try std.json.parseFromSlice(Value, alloc, s, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return error.InvalidSchema;
    const items = root.array.items;
    const out = try alloc.alloc(Index, items.len);
    for (items, 0..) |it, i| {
        out[i] = .{
            .name = (try getStr(alloc, it, "name")) orelse return error.InvalidSchema,
            .fields = (try getStrArray(alloc, it, "fields")) orelse &.{},
            .unique = getBool(it, "unique", false),
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Collection request parse / response serialize
// ---------------------------------------------------------------------------

/// Non-allocating: returns the `.string` payload of `v.object.get(key)` if present.
fn objGetStr(v: Value, key: []const u8) ?[]const u8 {
    const x = objGet(v, key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

fn optStrValue(v: ?[]const u8) Value {
    return if (v) |s| .{ .string = s } else .null;
}
fn dupOptStr(alloc: std.mem.Allocator, v: ?[]const u8) !?[]const u8 {
    return if (v) |s| try alloc.dupe(u8, s) else null;
}

/// Parse a request body into a Collection (id left empty; create/update assign it).
pub fn parseCollectionInput(alloc: std.mem.Allocator, s: []const u8) !Collection {
    const parsed = try std.json.parseFromSlice(Value, alloc, s, .{});
    defer parsed.deinit(); // everything retained is duped into `alloc` before return
    const obj = parsed.value;
    if (obj != .object) return error.InvalidSchema;

    const name = try alloc.dupe(u8, (objGetStr(obj, "name")) orelse return error.InvalidSchema);
    const ctype = std.meta.stringToEnum(CollectionType, objGetStr(obj, "type") orelse "base") orelse .base;

    const raw_fields = if (obj.object.get("fields")) |fv| blk: {
        const fs = try std.json.Stringify.valueAlloc(alloc, fv, .{});
        break :blk try fieldsFromJson(alloc, fs);
    } else &[_]Field{};
    var kept: std.ArrayList(Field) = .empty;
    for (raw_fields) |f| if (!isSystemFieldName(f.name)) try kept.append(alloc, f);
    const fields = try kept.toOwnedSlice(alloc);

    const empty_indexes: []const Index = &.{};
    const indexes = if (obj.object.get("indexes")) |iv| blk: {
        const is = try std.json.Stringify.valueAlloc(alloc, iv, .{});
        break :blk try indexesFromJson(alloc, is);
    } else empty_indexes;

    return .{
        .id = "",
        .name = name,
        .type = ctype,
        .fields = fields,
        .indexes = indexes,
        .listRule = try dupOptStr(alloc, objGetStr(obj, "listRule")),
        .viewRule = try dupOptStr(alloc, objGetStr(obj, "viewRule")),
        .createRule = try dupOptStr(alloc, objGetStr(obj, "createRule")),
        .updateRule = try dupOptStr(alloc, objGetStr(obj, "updateRule")),
        .deleteRule = try dupOptStr(alloc, objGetStr(obj, "deleteRule")),
        .options = if (obj.object.get("options")) |ov|
            try optionsFromJson(alloc, try std.json.Stringify.valueAlloc(alloc, ov, .{}))
        else
            .{},
    };
}

/// Serialize a Collection to its API JSON shape.
pub fn collectionToJson(alloc: std.mem.Allocator, c: Collection) ![]u8 {
    var root: ObjectMap = .empty;
    try root.put(alloc, "id", .{ .string = c.id });
    try root.put(alloc, "name", .{ .string = c.name });
    try root.put(alloc, "type", .{ .string = @tagName(c.type) });
    try root.put(alloc, "system", .{ .bool = c.system });
    // Embed fields/indexes as arrays by reparsing their JSON. The parse trees stay alive
    // until after Stringify reads them (defers run after the return expression evaluates).
    var visible: std.ArrayList(Field) = .empty;
    for (c.fields) |f| if (!f.hidden) try visible.append(alloc, f);
    const fields_str = try fieldsToJson(alloc, visible.items);
    const fparsed = try std.json.parseFromSlice(Value, alloc, fields_str, .{});
    defer fparsed.deinit();
    try root.put(alloc, "schema", fparsed.value);
    const idx_str = try indexesToJson(alloc, c.indexes);
    const iparsed = try std.json.parseFromSlice(Value, alloc, idx_str, .{});
    defer iparsed.deinit();
    try root.put(alloc, "indexes", iparsed.value);
    try root.put(alloc, "listRule", optStrValue(c.listRule));
    try root.put(alloc, "viewRule", optStrValue(c.viewRule));
    try root.put(alloc, "createRule", optStrValue(c.createRule));
    try root.put(alloc, "updateRule", optStrValue(c.updateRule));
    try root.put(alloc, "deleteRule", optStrValue(c.deleteRule));
    try root.put(alloc, "created", .{ .string = c.created });
    try root.put(alloc, "updated", .{ .string = c.updated });
    const oparsed = try std.json.parseFromSlice(std.json.Value, alloc, try optionsToJson(alloc, c), .{});
    defer oparsed.deinit();
    try root.put(alloc, "options", oparsed.value);
    return std.json.Stringify.valueAlloc(alloc, Value{ .object = root }, .{});
}

test "parseCollectionInput then collectionToJson round-trips the essentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"name":"posts","fields":[
        \\  {"id":"f1","name":"title","required":true,"type":"text","options":{}},
        \\  {"id":"f2","name":"price","type":"number","options":{"mode":"fixed","scale":2}}
        \\]}
    ;
    const col = try parseCollectionInput(a, input);
    try std.testing.expectEqualStrings("posts", col.name);
    try std.testing.expectEqual(CollectionType.base, col.type);
    try std.testing.expectEqual(@as(usize, 2), col.fields.len);
    try std.testing.expectEqualStrings("", col.id);

    var full = col;
    full.id = "abc123def456ghi";
    full.created = "2026-01-01 00:00:00";
    full.updated = "2026-01-01 00:00:00";
    const out = try collectionToJson(a, full);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"abc123def456ghi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\"") != null);
}

fn collectErrors(c: Collection) !std.ArrayList(ValidationError) {
    var list: std.ArrayList(ValidationError) = .empty;
    try validate(std.testing.allocator, c, &list);
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
        .{ .id = "a", .name = "id", .options = .{ .text = .{} } },
        .{ .id = "b", .name = "x", .options = .{ .number = .{ .mode = .fixed, .scale = null } } },
        .{ .id = "c", .name = "x", .options = .{ .text = .{} } },
        .{ .id = "d", .name = "tags", .options = .{ .select = .{ .values = &.{}, .maxSelect = 2 } } },
    };
    var errs = try collectErrors(.{ .id = "c1", .name = "1bad", .fields = &fields });
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
    try std.testing.expectEqualStrings("a", back[2].options.select.values[0]);
    try std.testing.expectEqualStrings("b", back[2].options.select.values[1]);
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

test "collection options round-trip identity fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .identityFields = &.{ "email", "username" }, .minPasswordLength = 10 } } };
    const s = try optionsToJson(a, c);
    const back = try optionsFromJson(a, s);
    try std.testing.expectEqual(@as(usize, 2), back.auth.identityFields.len);
    try std.testing.expectEqualStrings("username", back.auth.identityFields[1]);
    try std.testing.expectEqual(@as(u8, 10), back.auth.minPasswordLength);
}

test "validate rejects an auth collection with a non-identifier identity field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var errs: std.ArrayList(ValidationError) = .empty;
    const c = Collection{
        .id = "c", .name = "users", .type = .auth, .fields = &.{},
        .options = .{ .auth = .{ .identityFields = &.{ "email", "x\") WHERE 1=1; --" } } },
    };
    try validate(a, c, &errs);
    var found = false;
    for (errs.items) |e| if (std.mem.eql(u8, e.code, "validation_invalid_identity_field")) {
        found = true;
    };
    try std.testing.expect(found);
}

test "validate accepts an auth collection with valid identity fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var errs: std.ArrayList(ValidationError) = .empty;
    const c = Collection{
        .id = "c", .name = "users", .type = .auth, .fields = &.{},
        .options = .{ .auth = .{ .identityFields = &.{ "email", "username" } } },
    };
    try validate(a, c, &errs);
    for (errs.items) |e| try std.testing.expect(!std.mem.eql(u8, e.code, "validation_invalid_identity_field"));
}
