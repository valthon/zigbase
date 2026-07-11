//! Shared schema-introspection primitives for the comptime raw-SQL tooling (#281).
//!
//! Both the raw-SQL *checker* (`schema_check.zig`) and the typed *builder* (`query_builder.zig`)
//! must agree on exactly one thing: what counts as a valid table, and what counts as a valid
//! column of that table. Keeping that logic here — one source of truth — means the two features
//! can never drift (e.g. one of them forgetting the auth system columns, or disagreeing on the
//! built-in `id`/`created`/`updated`). It also carries the comptime helpers that render the same
//! identifier lists into `@compileError` messages so both features report failures identically.

const std = @import("std");
const schema = @import("../schema.zig");

/// Case-insensitive identifier compare — SQLite folds unquoted identifiers case-insensitively, so
/// column/table matching does too (biases toward matching, never a spurious "unknown").
pub fn eqIC(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The collection named `name` (case-insensitive), or null.
pub fn collectionByName(cols: []const schema.Collection, name: []const u8) ?schema.Collection {
    for (cols) |c| if (eqIC(name, c.name)) return c;
    return null;
}

/// Index of the collection named `name` (case-insensitive), or null.
pub fn collectionIndexByName(cols: []const schema.Collection, name: []const u8) ?usize {
    for (cols, 0..) |c, i| if (eqIC(name, c.name)) return i;
    return null;
}

/// Whether `name` is a valid column of `c`: the built-in `id`/`created`/`updated`, the auth system
/// columns for an `auth` collection (`email`, `username`, `passwordHash`, `tokenKey`, `verified`,
/// `token_epoch` — NOT injected into `App(cfg).collections`, so synthesized here), and the
/// collection's own fields. A `view` collection's columns come from an arbitrary query, so any
/// column is accepted (no false rejection).
pub fn isValidColumn(c: schema.Collection, name: []const u8) bool {
    if (c.type == .view) return true;
    if (eqIC(name, "id") or eqIC(name, "created") or eqIC(name, "updated")) return true;
    if (c.type == .auth) {
        for (schema.authSystemFields()) |f| if (eqIC(name, f.name)) return true;
    }
    for (c.fields) |f| if (eqIC(name, f.name)) return true;
    return false;
}

/// Emit `name` as a double-quoted SQL identifier. Field/collection names are always valid
/// identifiers (`schema.isValidIdentifier`: a leading ASCII-alphabetic character followed by ASCII
/// alphanumerics or `_`), so no embedded `"` is possible — the simple wrap is safe.
pub fn quoteIdent(comptime name: []const u8) []const u8 {
    return "\"" ++ name ++ "\"";
}

/// Comptime: a comma-separated list of the collection names (for `@compileError` messages).
pub fn tableNamesList(comptime cols: []const schema.Collection) []const u8 {
    comptime {
        var s: []const u8 = "";
        for (cols, 0..) |c, i| {
            if (i != 0) s = s ++ ", ";
            s = s ++ c.name;
        }
        return s;
    }
}

/// Comptime: a comma-separated list of the valid columns of `c` (for `@compileError` messages).
pub fn columnsList(comptime c: schema.Collection) []const u8 {
    comptime {
        var s: []const u8 = "id, created, updated";
        if (c.type == .auth) {
            for (schema.authSystemFields()) |f| s = s ++ ", " ++ f.name;
        }
        for (c.fields) |f| s = s ++ ", " ++ f.name;
        return s;
    }
}

// ---------------------------------------------------------------------------
// Tests — the runtime-checkable helpers (the comptime-list helpers are exercised through the
// checker's/builder's @compileError paths, which cannot themselves be executable tests).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testCols() []const schema.Collection {
    const S = struct {
        const users_fields = [_]schema.Field{
            .{ .id = "u_name", .name = "name", .options = .{ .text = .{} } },
        };
        const orders_fields = [_]schema.Field{
            .{ .id = "o_total", .name = "total", .options = .{ .number = .{} } },
            .{ .id = "o_note", .name = "note", .options = .{ .text = .{} } },
        };
        const cols = [_]schema.Collection{
            .{ .id = "users", .name = "users", .type = .auth, .fields = &users_fields },
            .{ .id = "orders", .name = "orders", .type = .base, .fields = &orders_fields },
        };
    };
    return &S.cols;
}

test "collectionByName is case-insensitive and misses cleanly" {
    try testing.expect(collectionByName(testCols(), "ORDERS") != null);
    try testing.expect(collectionByName(testCols(), "nope") == null);
}

test "isValidColumn: built-ins, fields, auth system cols, view passthrough" {
    const users = collectionByName(testCols(), "users").?;
    const orders = collectionByName(testCols(), "orders").?;
    // built-ins on any collection
    try testing.expect(isValidColumn(orders, "id"));
    try testing.expect(isValidColumn(orders, "created"));
    // own fields
    try testing.expect(isValidColumn(orders, "total"));
    try testing.expect(!isValidColumn(orders, "totl"));
    // auth system columns synthesized for auth collections
    try testing.expect(isValidColumn(users, "email"));
    try testing.expect(isValidColumn(users, "passwordHash"));
    try testing.expect(!isValidColumn(users, "email_typo"));
    // a view accepts any column (columns come from an arbitrary query)
    const view = schema.Collection{ .id = "v", .name = "v", .type = .view, .fields = &.{} };
    try testing.expect(isValidColumn(view, "anything"));
}
