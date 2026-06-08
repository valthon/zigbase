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
    created: []const u8 = "",
    updated: []const u8 = "",
};

pub const Index = struct { name: []const u8, fields: []const []const u8, unique: bool = false };

pub const ValidationError = struct { field: []const u8, code: []const u8, message: []const u8 };

const system_columns = [_][]const u8{ "id", "created", "updated" };

pub fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

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
        for (c.fields[0..i]) |g| {
            if (std.ascii.eqlIgnoreCase(f.name, g.name))
                errors.appendAssumeCapacity(.{ .field = f.name, .code = "validation_duplicate_name", .message = "Duplicate field name." });
        }
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
