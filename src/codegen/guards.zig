//! Generator-time invariants. Each returns a precise message via `GuardReport`
//! and fails the build, so a bad schema never silently mis-emits.
const std = @import("std");
const schema = @import("../schema.zig");
const ident = @import("identifiers.zig");
const ts_type = @import("ts_type.zig");

pub const GuardError = error{ OperatorNameClash, InvalidIdentifier, NameCollision, OutOfMemory };

pub const GuardReport = struct { message: []const u8 };

/// where-operator keys. A relation-TARGET collection must not have a field named
/// like one of these, else the where-DSL's nested-relation-vs-id-operator
/// disambiguation is ambiguous (see compileWhere's documented invariant).
const OPERATOR_KEYS = [_][]const u8{ "eq", "neq", "gt", "gte", "lt", "lte", "like", "nlike", "in", "AND", "OR" };

fn isOperatorKey(name: []const u8) bool {
    for (OPERATOR_KEYS) |k| if (std.mem.eql(u8, name, k)) return true;
    return false;
}

fn findByName(cols: []const schema.Collection, name: []const u8) ?schema.Collection {
    for (cols) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

/// Guard 1: any collection that is the TARGET of a relation must not own a field
/// whose name is a where-operator key.
pub fn checkOperatorNames(alloc: std.mem.Allocator, cols: []const schema.Collection, report: *GuardReport) GuardError!void {
    for (cols) |c| {
        for (c.fields) |f| {
            if (f.options != .relation) continue;
            const target = findByName(cols, f.options.relation.targetCollectionId) orelse continue;
            for (target.fields) |tf| {
                if (isOperatorKey(tf.name)) {
                    report.message = try std.fmt.allocPrint(alloc, "codegen: collection '{s}' field '{s}' relates to '{s}', which has a field '{s}' named like a where-operator — this makes the nested-relation where ambiguous. Rename '{s}.{s}'.", .{ c.name, f.name, target.name, tf.name, target.name, tf.name });
                    return GuardError.OperatorNameClash;
                }
            }
        }
    }
}

/// Append every generated type/const name a collection produces to `seen`, erroring
/// on an invalid identifier, a reserved-name collision, or a duplicate.
/// `msg_alloc` owns the caller-visible `report.message` (the single result that
/// escapes on error). `scratch` owns the transient derived name appended to
/// `seen`; the caller frees the whole scratch arena in one shot.
fn registerName(msg_alloc: std.mem.Allocator, scratch: std.mem.Allocator, seen: *std.ArrayList([]const u8), name: []const u8, owner: []const u8, report: *GuardReport) GuardError!void {
    if (!ident.isValidTsIdent(name)) {
        report.message = try std.fmt.allocPrint(msg_alloc, "codegen: '{s}' (from collection '{s}') is not a valid TS identifier.", .{ name, owner });
        return GuardError.InvalidIdentifier;
    }
    if (ident.isReservedName(name)) {
        report.message = try std.fmt.allocPrint(msg_alloc, "codegen: generated name '{s}' (from collection '{s}') collides with a reserved typed-core name.", .{ name, owner });
        return GuardError.NameCollision;
    }
    for (seen.items) |s| if (std.mem.eql(u8, s, name)) {
        report.message = try std.fmt.allocPrint(msg_alloc, "codegen: generated name '{s}' (from collection '{s}') collides with another generated name.", .{ name, owner });
        return GuardError.NameCollision;
    };
    try seen.append(scratch, name);
}

/// Guard 2: every collection/field name yields a valid TS identifier, and every
/// generated type name is mutually unique + not reserved.
///
/// All derived names and the `seen` list are transient — allocated in an internal
/// scratch arena and freed here. Only `report.message` (allocated with the
/// caller's `alloc`) escapes, and only on the error paths.
pub fn checkIdentifiers(alloc: std.mem.Allocator, cols: []const schema.Collection, report: *GuardReport) GuardError!void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var seen: std.ArrayList([]const u8) = .empty;
    for (cols) |c| {
        if (!ident.isValidTsIdent(c.name)) {
            report.message = try std.fmt.allocPrint(alloc, "codegen: collection name '{s}' is not a valid TS identifier.", .{c.name});
            return GuardError.InvalidIdentifier;
        }
        for (c.fields) |f| {
            if (!ident.isValidTsIdent(f.name)) {
                report.message = try std.fmt.allocPrint(alloc, "codegen: field '{s}' in collection '{s}' is not a valid TS identifier.", .{ f.name, c.name });
                return GuardError.InvalidIdentifier;
            }
        }
        // Register each generated name that the codegen emits at module scope.
        // This covers the 9 per-collection type/const names plus every select-union
        // type name (one per select field, e.g. PostStatus), all of which are
        // exported and must be mutually unique and not reserved.
        try registerName(alloc, sa, &seen, try ident.recordName(sa, c.name), c.name, report);
        try registerName(alloc, sa, &seen, try ident.whereName(sa, c.name), c.name, report);
        try registerName(alloc, sa, &seen, try ident.createName(sa, c.name), c.name, report);
        try registerName(alloc, sa, &seen, try ident.updateName(sa, c.name), c.name, report);
        try registerName(alloc, sa, &seen, try ident.relationsName(sa, c.name), c.name, report);
        try registerName(alloc, sa, &seen, try ident.expandName(sa, c.name), c.name, report);
        try registerName(alloc, sa, &seen, try ident.fieldsName(sa, c.name), c.name, report);
        try registerName(alloc, sa, &seen, try ident.serviceName(sa, c.name), c.name, report);
        try registerName(alloc, sa, &seen, try ident.realtimeAliasName(sa, c.name), c.name, report);
        // Register select-union names (e.g. PostStatus for posts.status).
        for (c.fields) |f| {
            if (f.fieldType() != .select) continue;
            const union_name = try ts_type.selectUnionName(sa, c.name, f.name);
            const owner_ctx = try std.fmt.allocPrint(sa, "{s} (field '{s}')", .{ c.name, f.name });
            try registerName(alloc, sa, &seen, union_name, owner_ctx, report);
        }
        // Register the per-collection metadata const (e.g. `postsMeta`), emitted at
        // module scope by emitMeta for EVERY collection.
        try registerName(alloc, sa, &seen, try ident.metaConst(sa, c.name), c.name, report);
        // Register the `<Rec>FileField` union, emitted by emitTypedFiles only for
        // collections with at least one SINGLE-value file field (mirror that gate
        // exactly so we don't register a name that isn't emitted).
        if (hasSingleFileFields(c)) {
            const file_union = try std.fmt.allocPrint(sa, "{s}FileField", .{try ident.recordName(sa, c.name)});
            try registerName(alloc, sa, &seen, file_union, c.name, report);
        }
    }
}

/// Mirror of emit.zig's hasSingleFileFields: a collection emits a `<Rec>FileField`
/// union iff it has at least one single-value file field.
fn hasSingleFileFields(c: schema.Collection) bool {
    for (c.fields) |f| if (ts_type.kindOf(f) == .file_name and !f.isMultiValue()) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn rel(target: []const u8) schema.FieldOptions {
    return .{ .relation = .{ .targetCollectionId = target } };
}

test "operator-name guard fires on a relation-target field named like an operator" {
    const a = std.testing.allocator;
    // `tags` has a field literally named "in" (a where-operator key); `posts.labels`
    // relates to `tags`, so a nested where on labels would be ambiguous -> must error.
    const tag_fields = [_]schema.Field{.{ .id = "x", .name = "in", .options = .{ .text = .{} } }};
    const post_fields = [_]schema.Field{.{ .id = "y", .name = "labels", .options = rel("tags") }};
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "tags", .fields = &tag_fields },
        .{ .id = "", .name = "posts", .fields = &post_fields },
    };
    var report = GuardReport{ .message = "" };
    try std.testing.expectError(GuardError.OperatorNameClash, checkOperatorNames(a, &cols, &report));
    defer a.free(report.message);
    try std.testing.expect(std.mem.indexOf(u8, report.message, "tags") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.message, "in") != null);
}

test "operator-name guard passes when no relation target has an operator-named field" {
    const a = std.testing.allocator;
    const tag_fields = [_]schema.Field{.{ .id = "x", .name = "label", .options = .{ .text = .{} } }};
    const post_fields = [_]schema.Field{.{ .id = "y", .name = "labels", .options = rel("tags") }};
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "tags", .fields = &tag_fields },
        .{ .id = "", .name = "posts", .fields = &post_fields },
    };
    var report = GuardReport{ .message = "" };
    try checkOperatorNames(a, &cols, &report);
}

test "identifier guard fires on a generated-name collision across collections" {
    const a = std.testing.allocator;
    // "profile" and "profiles" both yield record name "Profile" -> collision.
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "profile", .fields = &.{} },
        .{ .id = "", .name = "profiles", .fields = &.{} },
    };
    var report = GuardReport{ .message = "" };
    try std.testing.expectError(GuardError.NameCollision, checkIdentifiers(a, &cols, &report));
    defer a.free(report.message);
}

test "identifier guard fires on a reserved type-name collision" {
    const a = std.testing.allocator;
    // a collection named "RelOpss" -> recordName "RelOps" collides with the import.
    const cols = [_]schema.Collection{.{ .id = "", .name = "RelOpss", .fields = &.{} }};
    var report = GuardReport{ .message = "" };
    try std.testing.expectError(GuardError.NameCollision, checkIdentifiers(a, &cols, &report));
    defer a.free(report.message);
}

test "identifier guard passes for the blog shape" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{} },
        .{ .id = "", .name = "posts", .fields = &.{} },
        .{ .id = "", .name = "tags", .fields = &.{} },
    };
    var report = GuardReport{ .message = "" };
    try checkIdentifiers(a, &cols, &report);
}

test "identifier guard passes for blog shape with select fields" {
    const a = std.testing.allocator;
    // posts.status -> "PostStatus"; posts.visibility -> "PostVisibility"
    // Neither collides with any other generated name.
    const post_fields = [_]schema.Field{
        .{ .id = "f1", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" } } } },
        .{ .id = "f2", .name = "visibility", .options = .{ .select = .{ .values = &.{ "public", "private" } } } },
    };
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{} },
        .{ .id = "", .name = "posts", .fields = &post_fields },
        .{ .id = "", .name = "tags", .fields = &.{} },
    };
    var report = GuardReport{ .message = "" };
    try checkIdentifiers(a, &cols, &report);
}

test "identifier guard fires when select-union name collides with another generated type name" {
    const a = std.testing.allocator;
    // Collection "postStatuss" (plural) yields recordName "PostStatus".
    // Collection "posts" with a field "status" also yields selectUnionName "PostStatus".
    // -> NameCollision.
    const post_fields = [_]schema.Field{
        .{ .id = "f1", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" } } } },
    };
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "posts", .fields = &post_fields },
        .{ .id = "", .name = "postStatuss", .fields = &.{} }, // recordName -> "PostStatus" = collision
    };
    var report = GuardReport{ .message = "" };
    try std.testing.expectError(GuardError.NameCollision, checkIdentifiers(a, &cols, &report));
    defer a.free(report.message);
    try std.testing.expect(std.mem.indexOf(u8, report.message, "PostStatus") != null);
}

test "identifier guard fires when a <Rec>FileField union collides with another generated name" {
    const a = std.testing.allocator;
    // "members" has a single-value file field -> emits union "MemberFileField".
    // "memberFileFields" -> recordName strips trailing 's' -> "MemberFileField".
    // -> NameCollision (only caught now that the union name is registered).
    const member_fields = [_]schema.Field{
        .{ .id = "av", .name = "avatar", .options = .{ .file = .{ .maxSelect = 1 } } },
    };
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "members", .fields = &member_fields },
        .{ .id = "", .name = "memberFileFields", .fields = &.{} }, // recordName -> "MemberFileField"
    };
    var report = GuardReport{ .message = "" };
    try std.testing.expectError(GuardError.NameCollision, checkIdentifiers(a, &cols, &report));
    defer a.free(report.message);
    try std.testing.expect(std.mem.indexOf(u8, report.message, "MemberFileField") != null);
}

test "identifier guard fires when a <collection>Meta const collides with another generated name" {
    const a = std.testing.allocator;
    // "Profile" -> metaConst "ProfileMeta".
    // "profileMetas" -> recordName strips trailing 's' -> "ProfileMeta".
    // -> NameCollision (only caught now that the meta const name is registered).
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "Profile", .fields = &.{} }, // metaConst -> "ProfileMeta"
        .{ .id = "", .name = "profileMetas", .fields = &.{} }, // recordName -> "ProfileMeta"
    };
    var report = GuardReport{ .message = "" };
    try std.testing.expectError(GuardError.NameCollision, checkIdentifiers(a, &cols, &report));
    defer a.free(report.message);
    try std.testing.expect(std.mem.indexOf(u8, report.message, "ProfileMeta") != null);
}

test "identifier guard fires when select-union name collides with a reserved name" {
    const a = std.testing.allocator;
    // Collection "expressions" -> recordName "Expression".
    // Field "rs" on that collection -> selectUnionName "ExpressionRs"? No, let's make
    // one that actually hits a reserved name: collection "exprs", field "s" ->
    // selectUnionName "ExprS". Not reserved. Better: collection "posts",
    // field "listResult" -> selectUnionName "PostListResult". Not reserved.
    // Cleanest: collection "exprs", field "s" won't hit. Use collection name that
    // gives a record name such that <Record><FieldPascal> == reserved name.
    // reserved: "Expr". We need <Record><FieldPascal> == "Expr".
    // That means e.g. collection "exs" (recordName "Ex") + field "pr" (pascal "Pr") -> "ExPr". No.
    // Or collection "es" (recordName "E") + field "xpr" -> "Expr". Yes!
    // (recordName("es") strips trailing 's' -> "E"; pascal("xpr") -> "Xpr" -> "EXpr"? No.)
    // Simpler: collection "exprs" (recordName "Expr") is the reserved word itself.
    // But that fires on registerName for the record name, not the union name.
    // Let's try: reserved name "ListResult". Need record+field pascal == "ListResult".
    // collection "listResults" -> recordName("listResults") = "ListResult" already fires.
    // Instead target "StringOps": collection "strings" -> recordName "String",
    // field "ops" -> pascal "Ops" -> selectUnionName "StringOps" == reserved.
    const string_fields = [_]schema.Field{
        .{ .id = "f1", .name = "ops", .options = .{ .select = .{ .values = &.{ "a", "b" } } } },
    };
    const cols = [_]schema.Collection{
        .{ .id = "", .name = "strings", .fields = &string_fields }, // "StringOps" hits reserved list
    };
    var report = GuardReport{ .message = "" };
    try std.testing.expectError(GuardError.NameCollision, checkIdentifiers(a, &cols, &report));
    defer a.free(report.message);
    try std.testing.expect(std.mem.indexOf(u8, report.message, "StringOps") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.message, "strings") != null);
}
