//! Deterministic OpenAPI 3.1 export for ZigBase collections and consumer routes.
const std = @import("std");
const route_path = @import("route_path.zig");
const schema = @import("schema.zig");
const schema_doc = @import("schema_doc.zig");
const events = @import("events.zig");
const route_types = @import("route_types.zig");
const http = @import("http.zig");
const engine_server = @import("server.zig");

const Value = std.json.Value;
const Object = std.json.ObjectMap;

pub const contract_version = "1";

pub const Options = struct {
    title: []const u8 = "ZigBase API",
    api_version: []const u8,
    server: ?[]const u8 = null,
};

pub const Namespace = struct {
    gates: engine_server.Gates = .{},
    features_public_route: ?[]const u8 = "/api/state",
};

fn object() Object {
    return .empty;
}

fn array(alloc: std.mem.Allocator) std.json.Array {
    return .init(alloc);
}

fn refValue(alloc: std.mem.Allocator, name: []const u8) !Value {
    var out = object();
    try out.put(alloc, "$ref", .{ .string = try std.fmt.allocPrint(alloc, "#/components/schemas/{s}", .{name}) });
    return .{ .object = out };
}

fn componentBase(alloc: std.mem.Allocator, collection_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var upper_next = true;
    for (collection_name) |ch| {
        if (ch == '_' or ch == '-') {
            upper_next = true;
            continue;
        }
        try out.append(alloc, if (upper_next) std.ascii.toUpper(ch) else ch);
        upper_next = false;
    }
    return out.toOwnedSlice(alloc);
}

fn addNumber(obj: *Object, alloc: std.mem.Allocator, key: []const u8, value: f64) !void {
    try obj.put(alloc, key, .{ .float = value });
}

fn scalarFieldSchema(alloc: std.mem.Allocator, field: schema.Field, owner: schema.Collection, all: []const schema.Collection) !Value {
    var out = object();
    switch (field.options) {
        .text => |o| {
            try out.put(alloc, "type", .{ .string = "string" });
            if (o.min) |v| try out.put(alloc, "minLength", .{ .integer = @intCast(v) });
            if (o.max) |v| try out.put(alloc, "maxLength", .{ .integer = @intCast(v) });
            if (o.pattern) |v| try out.put(alloc, "pattern", .{ .string = v });
        },
        .email => {
            try out.put(alloc, "type", .{ .string = "string" });
            try out.put(alloc, "format", .{ .string = "email" });
        },
        .url => {
            try out.put(alloc, "type", .{ .string = "string" });
            try out.put(alloc, "format", .{ .string = "uri" });
        },
        .editor => try out.put(alloc, "type", .{ .string = "string" }),
        .date => |o| {
            try out.put(alloc, "type", .{ .string = "string" });
            try out.put(alloc, "format", .{ .string = "date-time" });
            if (o.min) |v| try out.put(alloc, "x-zigbase-min", .{ .string = v });
            if (o.max) |v| try out.put(alloc, "x-zigbase-max", .{ .string = v });
        },
        .autodate => {
            try out.put(alloc, "type", .{ .string = "string" });
            try out.put(alloc, "format", .{ .string = "date-time" });
            try out.put(alloc, "readOnly", .{ .bool = true });
        },
        .bool => try out.put(alloc, "type", .{ .string = "boolean" }),
        .number => |o| {
            try out.put(alloc, "type", .{ .string = "number" });
            try out.put(alloc, "x-zigbase-numberMode", .{ .string = @tagName(o.mode) });
            if (o.min) |v| try addNumber(&out, alloc, "minimum", v);
            if (o.max) |v| try addNumber(&out, alloc, "maximum", v);
            if (o.mode == .fixed) {
                const scale = o.scale orelse 1;
                try out.put(alloc, "x-zigbase-scale", .{ .integer = @intCast(scale) });
                try addNumber(&out, alloc, "multipleOf", std.math.pow(f64, 10, -@as(f64, @floatFromInt(scale))));
            }
        },
        .json => |o| if (o.maxSize) |v| try out.put(alloc, "x-zigbase-maxBytes", .{ .integer = @intCast(v) }),
        .select => |o| {
            try out.put(alloc, "type", .{ .string = "string" });
            var values = array(alloc);
            for (o.values) |v| try values.append(.{ .string = v });
            try out.put(alloc, "enum", .{ .array = values });
        },
        .relation => |o| {
            try out.put(alloc, "type", .{ .string = "string" });
            try out.put(alloc, "x-zigbase-relation", .{ .string = schema_doc.targetName(o.targetCollectionId, owner, all) });
            try out.put(alloc, "x-zigbase-cascadeDelete", .{ .bool = o.cascadeDelete });
        },
        .file => |o| {
            try out.put(alloc, "type", .{ .string = "string" });
            try out.put(alloc, "x-zigbase-file", .{ .bool = true });
            if (o.maxSize) |v| try out.put(alloc, "x-zigbase-maxBytes", .{ .integer = @intCast(v) });
            if (o.mimeTypes) |types| {
                var values = array(alloc);
                for (types) |v| try values.append(.{ .string = v });
                try out.put(alloc, "x-zigbase-mimeTypes", .{ .array = values });
            }
        },
    }
    if (field.unique) try out.put(alloc, "x-zigbase-unique", .{ .bool = true });
    if (field.hidden) try out.put(alloc, "writeOnly", .{ .bool = true });
    if (field.encrypted) try out.put(alloc, "x-zigbase-encrypted", .{ .bool = true });
    if (field.searchable) try out.put(alloc, "x-zigbase-searchable", .{ .bool = true });
    return .{ .object = out };
}

fn fieldSchema(alloc: std.mem.Allocator, field: schema.Field, owner: schema.Collection, all: []const schema.Collection) !Value {
    const scalar = try scalarFieldSchema(alloc, field, owner, all);
    if (!field.isMultiValue()) return scalar;
    var out = object();
    try out.put(alloc, "type", .{ .string = "array" });
    try out.put(alloc, "items", scalar);
    switch (field.options) {
        .select => |o| try out.put(alloc, "maxItems", .{ .integer = @intCast(o.maxSelect) }),
        .relation => |o| {
            if (o.minSelect) |v| try out.put(alloc, "minItems", .{ .integer = @intCast(v) });
            try out.put(alloc, "maxItems", .{ .integer = @intCast(o.maxSelect) });
        },
        .file => |o| try out.put(alloc, "maxItems", .{ .integer = @intCast(o.maxSelect) }),
        else => unreachable,
    }
    return .{ .object = out };
}

const SchemaKind = enum { record, create, update };

fn nullable(alloc: std.mem.Allocator, value: Value) !Value {
    if (value == .object) {
        if (value.object.get("type")) |field_type| {
            if (field_type == .string) {
                var types = array(alloc);
                try types.append(.{ .string = field_type.string });
                try types.append(.{ .string = "null" });
                var out = value;
                try out.object.put(alloc, "type", .{ .array = types });
                return out;
            }
        }
    }
    var alternatives = array(alloc);
    try alternatives.append(value);
    var null_schema = object();
    try null_schema.put(alloc, "type", .{ .string = "null" });
    try alternatives.append(.{ .object = null_schema });
    var out = object();
    try out.put(alloc, "anyOf", .{ .array = alternatives });
    return .{ .object = out };
}

fn collectionFieldSchema(alloc: std.mem.Allocator, field: schema.Field, owner: schema.Collection, all: []const schema.Collection, kind: SchemaKind) !Value {
    var result = try fieldSchema(alloc, field, owner, all);
    switch (field.options) {
        .number => |number| {
            const mode = number.mode;
            if (mode == .int or mode == .fixed) {
                if (kind == .record) {
                    try result.object.put(alloc, "type", .{ .string = "string" });
                } else {
                    var types = array(alloc);
                    try types.append(.{ .string = "string" });
                    try types.append(.{ .string = "number" });
                    try result.object.put(alloc, "type", .{ .array = types });
                }
            }
        },
        else => {},
    }
    if (kind == .record and !field.required) result = try nullable(alloc, result);
    return result;
}

fn collectionSchema(alloc: std.mem.Allocator, col: schema.Collection, all: []const schema.Collection, kind: SchemaKind) !Value {
    var properties = object();
    var required = array(alloc);
    if (kind == .record) {
        inline for (&.{ "id", "created", "updated" }) |name| {
            var p = object();
            try p.put(alloc, "type", .{ .string = "string" });
            if (!std.mem.eql(u8, name, "id")) try p.put(alloc, "format", .{ .string = "date-time" });
            try p.put(alloc, "readOnly", .{ .bool = true });
            try properties.put(alloc, name, .{ .object = p });
        }
    }
    for (col.fields) |field| {
        const internal = std.mem.eql(u8, field.name, "passwordHash") or std.mem.eql(u8, field.name, "tokenKey") or std.mem.eql(u8, field.name, "token_epoch");
        // These auth engine columns are never part of the records wire contract. In
        // particular, naming passwordHash in an exported schema would invite clients to
        // treat it as a supported write field even when marked writeOnly.
        if (internal) continue;
        if (kind != .record and field.options == .autodate) continue;
        try properties.put(alloc, field.name, try collectionFieldSchema(alloc, field, col, all, kind));
        if (field.required and kind == .create) try required.append(.{ .string = field.name });
    }
    if (col.type == .auth and (kind == .create or kind == .update)) {
        inline for (&.{ "password", "passwordConfirm", "oldPassword" }) |name| {
            var p = object();
            try p.put(alloc, "type", .{ .string = "string" });
            try p.put(alloc, "format", .{ .string = "password" });
            try p.put(alloc, "writeOnly", .{ .bool = true });
            try properties.put(alloc, name, .{ .object = p });
            if (kind == .create and !std.mem.eql(u8, name, "oldPassword"))
                try required.append(.{ .string = name });
        }
    }
    var out = object();
    try out.put(alloc, "type", .{ .string = "object" });
    try out.put(alloc, "properties", .{ .object = properties });
    if (required.items.len > 0) try out.put(alloc, "required", .{ .array = required });
    if (kind != .record) try out.put(alloc, "additionalProperties", .{ .bool = false });
    return .{ .object = out };
}

fn listSchema(alloc: std.mem.Allocator, record_name: []const u8) !Value {
    var item_array = object();
    try item_array.put(alloc, "type", .{ .string = "array" });
    try item_array.put(alloc, "items", try refValue(alloc, record_name));
    var props = object();
    inline for (&.{ "page", "perPage", "totalItems", "totalPages" }) |name| {
        var p = object();
        try p.put(alloc, "type", .{ .string = "integer" });
        try props.put(alloc, name, .{ .object = p });
    }
    inline for (&.{ "nextCursor", "prevCursor" }) |name| {
        var p = object();
        var types = array(alloc);
        try types.append(.{ .string = "string" });
        try types.append(.{ .string = "null" });
        try p.put(alloc, "type", .{ .array = types });
        try props.put(alloc, name, .{ .object = p });
    }
    inline for (&.{ "hasNext", "hasPrev" }) |name| {
        var p = object();
        try p.put(alloc, "type", .{ .string = "boolean" });
        try props.put(alloc, name, .{ .object = p });
    }
    try props.put(alloc, "items", .{ .object = item_array });
    var out = object();
    try out.put(alloc, "type", .{ .string = "object" });
    try out.put(alloc, "properties", .{ .object = props });
    var req = array(alloc);
    inline for (&.{ "page", "perPage", "items" }) |v| try req.append(.{ .string = v });
    try out.put(alloc, "required", .{ .array = req });
    return .{ .object = out };
}

fn errorSchema(alloc: std.mem.Allocator) !Value {
    var field_error = object();
    try field_error.put(alloc, "type", .{ .string = "object" });
    var fe_props = object();
    inline for (&.{ "code", "message" }) |name| {
        var p = object();
        try p.put(alloc, "type", .{ .string = "string" });
        try fe_props.put(alloc, name, .{ .object = p });
    }
    try field_error.put(alloc, "properties", .{ .object = fe_props });
    var data = object();
    try data.put(alloc, "type", .{ .string = "object" });
    try data.put(alloc, "additionalProperties", .{ .object = field_error });
    var props = object();
    var status = object();
    try status.put(alloc, "type", .{ .string = "integer" });
    try props.put(alloc, "status", .{ .object = status });
    inline for (&.{ "code", "message" }) |name| {
        var p = object();
        try p.put(alloc, "type", .{ .string = "string" });
        try props.put(alloc, name, .{ .object = p });
    }
    try props.put(alloc, "data", .{ .object = data });
    var out = object();
    try out.put(alloc, "type", .{ .string = "object" });
    try out.put(alloc, "properties", .{ .object = props });
    var req = array(alloc);
    inline for (&.{ "status", "code", "message", "data" }) |v| try req.append(.{ .string = v });
    try out.put(alloc, "required", .{ .array = req });
    return .{ .object = out };
}

fn jsonResponse(alloc: std.mem.Allocator, status_description: []const u8, schema_name: ?[]const u8) !Value {
    var response = object();
    try response.put(alloc, "description", .{ .string = status_description });
    if (schema_name) |name| {
        var media = object();
        try media.put(alloc, "schema", try refValue(alloc, name));
        var content = object();
        try content.put(alloc, "application/json", .{ .object = media });
        try response.put(alloc, "content", .{ .object = content });
    }
    return .{ .object = response };
}

fn applyAccess(alloc: std.mem.Allocator, op: *Object, rule: ?[]const u8) !void {
    if (rule) |r| {
        if (r.len == 0) return applyAccess(alloc, op, null);
        if (std.mem.eql(u8, r, "@public")) {
            try op.put(alloc, "security", .{ .array = array(alloc) });
            try op.put(alloc, "x-zigbase-access", .{ .string = "public" });
        } else {
            try op.put(alloc, "x-zigbase-access", .{ .string = "conditional" });
            try op.put(alloc, "x-zigbase-rule", .{ .string = r });
        }
    } else {
        var requirement = object();
        try requirement.put(alloc, "bearerAuth", .{ .array = array(alloc) });
        var security = array(alloc);
        try security.append(.{ .object = requirement });
        try op.put(alloc, "security", .{ .array = security });
        try op.put(alloc, "x-zigbase-access", .{ .string = "locked" });
    }
}

fn responseSet(alloc: std.mem.Allocator, success_name: ?[]const u8, deleted: bool) !Value {
    var responses = object();
    try responses.put(alloc, if (deleted) "204" else "200", try jsonResponse(alloc, if (deleted) "Deleted" else "Success", success_name));
    try responses.put(alloc, "4XX", try jsonResponse(alloc, "Client error", "ZigBaseError"));
    try responses.put(alloc, "5XX", try jsonResponse(alloc, "Server error", "ZigBaseError"));
    return .{ .object = responses };
}

fn idParameter(alloc: std.mem.Allocator) !Value {
    var param = object();
    try param.put(alloc, "name", .{ .string = "id" });
    try param.put(alloc, "in", .{ .string = "path" });
    try param.put(alloc, "required", .{ .bool = true });
    var value_schema = object();
    try value_schema.put(alloc, "type", .{ .string = "string" });
    try param.put(alloc, "schema", .{ .object = value_schema });
    return .{ .object = param };
}

fn queryParameters(alloc: std.mem.Allocator) !Value {
    var params = array(alloc);
    const names = [_]struct { []const u8, []const u8 }{
        .{ "page", "integer" },      .{ "perPage", "integer" }, .{ "cursor", "string" }, .{ "limit", "integer" },
        .{ "skipTotal", "boolean" }, .{ "filter", "string" },   .{ "sort", "string" },   .{ "search", "string" },
        .{ "q", "string" },          .{ "vector", "string" },   .{ "expand", "string" }, .{ "fields", "string" },
    };
    for (names) |entry| {
        var param = object();
        try param.put(alloc, "name", .{ .string = entry[0] });
        try param.put(alloc, "in", .{ .string = "query" });
        var value_schema = object();
        try value_schema.put(alloc, "type", .{ .string = entry[1] });
        if (std.mem.eql(u8, entry[0], "perPage") or std.mem.eql(u8, entry[0], "limit")) try value_schema.put(alloc, "maximum", .{ .integer = 500 });
        try param.put(alloc, "schema", .{ .object = value_schema });
        try params.append(.{ .object = param });
    }
    return .{ .array = params };
}

fn viewParameters(alloc: std.mem.Allocator) !Value {
    var params = array(alloc);
    try params.append(try idParameter(alloc));
    inline for (&.{ "expand", "fields" }) |name| {
        var param = object();
        try param.put(alloc, "name", .{ .string = name });
        try param.put(alloc, "in", .{ .string = "query" });
        var value_schema = object();
        try value_schema.put(alloc, "type", .{ .string = "string" });
        try param.put(alloc, "schema", .{ .object = value_schema });
        try params.append(.{ .object = param });
    }
    return .{ .array = params };
}

fn requestBody(alloc: std.mem.Allocator, schema_name: []const u8) !Value {
    var media = object();
    try media.put(alloc, "schema", try refValue(alloc, schema_name));
    var content = object();
    try content.put(alloc, "application/json", .{ .object = media });
    var body = object();
    try body.put(alloc, "required", .{ .bool = true });
    try body.put(alloc, "content", .{ .object = content });
    return .{ .object = body };
}

fn operation(alloc: std.mem.Allocator, operation_id: []const u8, rule: ?[]const u8, result: ?[]const u8, body: ?[]const u8, parameters: ?Value, deleted: bool) !Value {
    var op = object();
    try op.put(alloc, "operationId", .{ .string = operation_id });
    if (parameters) |v| try op.put(alloc, "parameters", v);
    if (body) |name| try op.put(alloc, "requestBody", try requestBody(alloc, name));
    try op.put(alloc, "responses", try responseSet(alloc, result, deleted));
    try applyAccess(alloc, &op, rule);
    return .{ .object = op };
}

fn collectionOperation(alloc: std.mem.Allocator, col: schema.Collection, operation_id: []const u8, rule: ?[]const u8, result: ?[]const u8, body: ?[]const u8, parameters: ?Value, deleted: bool) !Value {
    var out = try operation(alloc, operation_id, rule, result, body, parameters, deleted);
    try out.object.put(alloc, "x-zigbase-collection", .{ .string = col.name });
    try out.object.put(alloc, "x-zigbase-collection-type", .{ .string = @tagName(col.type) });
    return out;
}

const collection_operation_prefixes = [_][]const u8{ "list", "create", "view", "update", "delete" };

fn collectionOperationIdsConflict(alloc: std.mem.Allocator, ids: *const std.StringHashMap(void), base: []const u8) !bool {
    for (collection_operation_prefixes) |prefix| {
        const operation_id = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, base });
        if (ids.contains(operation_id)) return true;
    }
    return false;
}

fn reserveCollectionOperationIds(alloc: std.mem.Allocator, ids: *std.StringHashMap(void), base: []const u8) !void {
    for (collection_operation_prefixes) |prefix|
        try ids.put(try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, base }), {});
}

fn collectionSymbolBases(
    alloc: std.mem.Allocator,
    collections: []const schema.Collection,
    comptime route_meta: []const events.RouteMeta,
) ![][]const u8 {
    var reserved = std.StringHashMap(void).init(alloc);
    defer reserved.deinit();
    for (engine_server.migration_builtin_operations) |builtin| try reserved.put(builtin.operation_id, {});
    inline for (route_meta) |meta| try reserved.put(meta.name, {});

    const friendly = try alloc.alloc([]const u8, collections.len);
    for (collections, 0..) |col, index| friendly[index] = try componentBase(alloc, col.name);
    const symbols = try alloc.alloc([]const u8, collections.len);
    for (collections, 0..) |col, index| {
        var duplicate_friendly = false;
        for (friendly, 0..) |other, other_index| {
            if (other_index != index and std.mem.eql(u8, friendly[index], other)) {
                duplicate_friendly = true;
                break;
            }
        }

        const stem = if (duplicate_friendly or try collectionOperationIdsConflict(alloc, &reserved, friendly[index]))
            try std.fmt.allocPrint(alloc, "{s}_{s}", .{ friendly[index], col.name })
        else
            friendly[index];
        var candidate = stem;
        var suffix: usize = 2;
        while (try collectionOperationIdsConflict(alloc, &reserved, candidate)) : (suffix += 1)
            candidate = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ stem, suffix });
        symbols[index] = candidate;
        try reserveCollectionOperationIds(alloc, &reserved, candidate);
    }
    return symbols;
}

fn addCollection(alloc: std.mem.Allocator, paths: *Object, schemas: *Object, col: schema.Collection, base: []const u8, all: []const schema.Collection) !void {
    const record_name = try std.fmt.allocPrint(alloc, "{s}Record", .{base});
    const create_name = try std.fmt.allocPrint(alloc, "{s}Create", .{base});
    const update_name = try std.fmt.allocPrint(alloc, "{s}Update", .{base});
    const list_name = try std.fmt.allocPrint(alloc, "{s}List", .{base});
    try schemas.put(alloc, record_name, try collectionSchema(alloc, col, all, .record));
    try schemas.put(alloc, create_name, try collectionSchema(alloc, col, all, .create));
    try schemas.put(alloc, update_name, try collectionSchema(alloc, col, all, .update));
    try schemas.put(alloc, list_name, try listSchema(alloc, record_name));

    const collection_path = try std.fmt.allocPrint(alloc, "/api/collections/{s}/records", .{col.name});
    var collection_item = object();
    try collection_item.put(alloc, "get", try collectionOperation(alloc, col, try std.fmt.allocPrint(alloc, "list{s}", .{base}), col.listRule, list_name, null, try queryParameters(alloc), false));
    try collection_item.put(alloc, "post", try collectionOperation(alloc, col, try std.fmt.allocPrint(alloc, "create{s}", .{base}), col.createRule, record_name, create_name, null, false));
    try paths.put(alloc, collection_path, .{ .object = collection_item });

    const item_path = try std.fmt.allocPrint(alloc, "{s}/{{id}}", .{collection_path});
    var id_params = array(alloc);
    try id_params.append(try idParameter(alloc));
    const params = Value{ .array = id_params };
    var item = object();
    try item.put(alloc, "get", try collectionOperation(alloc, col, try std.fmt.allocPrint(alloc, "view{s}", .{base}), col.viewRule, record_name, null, try viewParameters(alloc), false));
    try item.put(alloc, "patch", try collectionOperation(alloc, col, try std.fmt.allocPrint(alloc, "update{s}", .{base}), col.updateRule, record_name, update_name, params, false));
    try item.put(alloc, "delete", try collectionOperation(alloc, col, try std.fmt.allocPrint(alloc, "delete{s}", .{base}), col.deleteRule, null, null, params, true));
    try paths.put(alloc, item_path, .{ .object = item });
}

fn lessByName(_: void, a: schema.Collection, b: schema.Collection) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn zigSchema(comptime T: type, alloc: std.mem.Allocator) !Value {
    if (T == std.json.Value) return .{ .bool = true };
    var out = object();
    if (T == void) return .{ .object = out };
    if (T == []const u8 or T == []u8) {
        try out.put(alloc, "type", .{ .string = "string" });
        return .{ .object = out };
    }
    switch (@typeInfo(T)) {
        .bool => try out.put(alloc, "type", .{ .string = "boolean" }),
        .int => |i| {
            try out.put(alloc, "type", .{ .string = "integer" });
            const format: ?[]const u8 = if (i.signedness == .signed)
                if (i.bits <= 32) "int32" else if (i.bits <= 64) "int64" else null
            else if (i.bits <= 31)
                "int32"
            else if (i.bits <= 63)
                "int64"
            else
                null;
            if (format) |value| try out.put(alloc, "format", .{ .string = value });
            if (i.signedness == .unsigned) try out.put(alloc, "minimum", .{ .integer = 0 });
        },
        .float => |f| {
            try out.put(alloc, "type", .{ .string = "number" });
            try out.put(alloc, "format", .{ .string = if (f.bits <= 32) "float" else "double" });
        },
        .@"enum" => |e| {
            try out.put(alloc, "type", .{ .string = "string" });
            var values = array(alloc);
            inline for (e.fields) |field| try values.append(.{ .string = field.name });
            try out.put(alloc, "enum", .{ .array = values });
        },
        .optional => |o| {
            const child = try zigSchema(o.child, alloc);
            var any_of = array(alloc);
            try any_of.append(child);
            var null_schema = object();
            try null_schema.put(alloc, "type", .{ .string = "null" });
            try any_of.append(.{ .object = null_schema });
            try out.put(alloc, "anyOf", .{ .array = any_of });
        },
        .pointer => |p| {
            if (p.size != .slice) unreachable;
            if (p.child == u8) {
                try out.put(alloc, "type", .{ .string = "string" });
            } else {
                try out.put(alloc, "type", .{ .string = "array" });
                try out.put(alloc, "items", try zigSchema(p.child, alloc));
            }
        },
        .@"struct" => |s| {
            try out.put(alloc, "type", .{ .string = "object" });
            var props = object();
            var required = array(alloc);
            inline for (s.fields) |field| {
                try props.put(alloc, field.name, try zigSchema(field.type, alloc));
                if (field.default_value_ptr == null)
                    try required.append(.{ .string = field.name });
            }
            try out.put(alloc, "properties", .{ .object = props });
            if (required.items.len > 0) try out.put(alloc, "required", .{ .array = required });
            try out.put(alloc, "additionalProperties", .{ .bool = false });
        },
        else => unreachable,
    }
    return .{ .object = out };
}

fn methodName(method: http.Method) []const u8 {
    return switch (method) {
        .GET => "get",
        .POST => "post",
        .PUT => "put",
        .PATCH => "patch",
        .DELETE => "delete",
        .OPTIONS => "options",
        .HEAD => "head",
        .UNKNOWN => unreachable,
    };
}

fn openApiPath(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var segments = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (segments.next()) |segment| {
        if (!first) try out.append(alloc, '/');
        first = false;
        if (segment.len > 1 and segment[0] == ':') {
            try out.append(alloc, '{');
            try out.appendSlice(alloc, segment[1..]);
            try out.append(alloc, '}');
        } else try out.appendSlice(alloc, segment);
    }
    return out.toOwnedSlice(alloc);
}

fn reservedRoutes(comptime namespace: Namespace, alloc: std.mem.Allocator) !Value {
    var routes = array(alloc);
    for (engine_server.Server(namespace.gates).routes) |route| {
        var item = object();
        try item.put(alloc, "method", .{ .string = methodName(route.method) });
        try item.put(alloc, "path", .{ .string = try openApiPath(alloc, route.pattern) });
        try routes.append(.{ .object = item });
    }
    for (engine_server.realtime_upgrade_routes) |route| {
        var item = object();
        try item.put(alloc, "method", .{ .string = methodName(route.method) });
        try item.put(alloc, "path", .{ .string = route.pattern });
        try routes.append(.{ .object = item });
    }
    if (namespace.features_public_route) |path| {
        inline for (engine_server.feature_route_methods) |feature_method| {
            var item = object();
            try item.put(alloc, "method", .{ .string = methodName(feature_method) });
            try item.put(alloc, "path", .{ .string = path });
            try routes.append(.{ .object = item });
        }
    }
    return .{ .array = routes };
}

fn reservedPrefixes(comptime namespace: Namespace, alloc: std.mem.Allocator) !Value {
    var prefixes = array(alloc);
    if (namespace.gates.admin) {
        var item = object();
        try item.put(alloc, "path", .{ .string = "/_" });
        try item.put(alloc, "source", .{ .string = "admin" });
        try prefixes.append(.{ .object = item });
    }
    return .{ .array = prefixes };
}

fn builtinOperations(alloc: std.mem.Allocator) !Value {
    var operations = array(alloc);
    for (engine_server.migration_builtin_operations) |builtin| {
        var item = object();
        try item.put(alloc, "operationId", .{ .string = builtin.operation_id });
        try item.put(alloc, "method", .{ .string = methodName(builtin.method) });
        try item.put(alloc, "path", .{ .string = try openApiPath(alloc, builtin.pattern) });
        try item.put(alloc, "access", .{ .string = builtin.access });
        try item.put(alloc, "collectionType", .{ .string = "auth" });
        try operations.append(.{ .object = item });
    }
    return .{ .array = operations };
}

fn exportedGates(comptime namespace: Namespace, alloc: std.mem.Allocator) !Value {
    var gates = object();
    inline for (std.meta.fields(engine_server.Gates)) |field|
        try gates.put(alloc, field.name, .{ .bool = @field(namespace.gates, field.name) });
    return .{ .object = gates };
}

fn routePathParameters(comptime meta: events.RouteMeta, canonical_path: []const u8, alloc: std.mem.Allocator) !std.json.Array {
    var params = array(alloc);
    var source_segments = std.mem.splitScalar(u8, meta.path, '/');
    var canonical_segments = std.mem.splitScalar(u8, canonical_path, '/');
    while (source_segments.next()) |source_segment| {
        const canonical_segment = canonical_segments.next() orelse unreachable;
        if (source_segment.len <= 1 or source_segment[0] != ':') continue;
        const canonical_name = if (canonical_segment.len > 2 and canonical_segment[0] == '{' and canonical_segment[canonical_segment.len - 1] == '}')
            canonical_segment[1 .. canonical_segment.len - 1]
        else if (canonical_segment.len > 1 and canonical_segment[0] == ':')
            canonical_segment[1..]
        else
            unreachable;
        var param = object();
        try param.put(alloc, "name", .{ .string = canonical_name });
        try param.put(alloc, "in", .{ .string = "path" });
        try param.put(alloc, "required", .{ .bool = true });
        var param_schema = object();
        try param_schema.put(alloc, "type", .{ .string = "string" });
        if (meta.path_secret) |secret| {
            if (secret.in == .path and std.mem.eql(u8, secret.param, source_segment[1..]))
                try param_schema.put(alloc, "writeOnly", .{ .bool = true });
        }
        try param.put(alloc, "schema", .{ .object = param_schema });
        try params.append(.{ .object = param });
    }
    return params;
}

fn isTemplateCapture(segment: []const u8) bool {
    return (segment.len > 1 and segment[0] == ':') or
        (segment.len > 2 and segment[0] == '{' and segment[segment.len - 1] == '}');
}

fn sameTemplateShape(a: []const u8, b: []const u8) bool {
    var a_segments = std.mem.splitScalar(u8, a, '/');
    var b_segments = std.mem.splitScalar(u8, b, '/');
    while (true) {
        const a_segment = a_segments.next();
        const b_segment = b_segments.next();
        if (a_segment == null or b_segment == null) return a_segment == null and b_segment == null;
        const a_capture = isTemplateCapture(a_segment.?);
        const b_capture = isTemplateCapture(b_segment.?);
        if (a_capture != b_capture) return false;
        if (!a_capture and !std.mem.eql(u8, a_segment.?, b_segment.?)) return false;
    }
}

fn canonicalPathItem(paths: *const Object, candidate: []const u8) ?[]const u8 {
    var it = paths.iterator();
    while (it.next()) |entry| {
        if (sameTemplateShape(entry.key_ptr.*, candidate)) return entry.key_ptr.*;
    }
    return null;
}

fn queryFieldParameter(comptime field: std.builtin.Type.StructField, alloc: std.mem.Allocator) !Value {
    var param = object();
    try param.put(alloc, "name", .{ .string = field.name });
    try param.put(alloc, "in", .{ .string = "query" });
    if (@typeInfo(field.type) != .optional and field.default_value_ptr == null)
        try param.put(alloc, "required", .{ .bool = true });
    try param.put(alloc, "schema", try zigSchema(field.type, alloc));
    return .{ .object = param };
}

fn secretParameter(secret: events.PathSecretMeta, alloc: std.mem.Allocator) !Value {
    var param = object();
    try param.put(alloc, "name", .{ .string = secret.param });
    try param.put(alloc, "in", .{ .string = switch (secret.in) {
        .path => "path",
        .query => "query",
        .header => "header",
    } });
    try param.put(alloc, "required", .{ .bool = true });
    var param_schema = object();
    try param_schema.put(alloc, "type", .{ .string = "string" });
    try param_schema.put(alloc, "writeOnly", .{ .bool = true });
    try param.put(alloc, "schema", .{ .object = param_schema });
    try param.put(alloc, "x-zigbase-path-secret", .{ .bool = true });
    return .{ .object = param };
}

fn routeResponses(comptime method: http.Method, comptime Output: type, untyped: bool, alloc: std.mem.Allocator) !Value {
    var responses = object();
    var success = object();
    if (Output == void and !untyped) {
        try success.put(alloc, "description", .{ .string = "No content" });
        try responses.put(alloc, "204", .{ .object = success });
    } else {
        try success.put(alloc, "description", .{ .string = "Success" });
        if (!untyped and method != .HEAD) {
            var media = object();
            try media.put(alloc, "schema", try zigSchema(Output, alloc));
            var content = object();
            try content.put(alloc, "application/json", .{ .object = media });
            try success.put(alloc, "content", .{ .object = content });
        }
        try responses.put(alloc, "200", .{ .object = success });
    }
    try responses.put(alloc, "4XX", try jsonResponse(alloc, "Client error", "ZigBaseError"));
    try responses.put(alloc, "5XX", try jsonResponse(alloc, "Server error", "ZigBaseError"));
    return .{ .object = responses };
}

fn applyRouteSecurity(comptime meta: events.RouteMeta, alloc: std.mem.Allocator, op: *Object) !void {
    if (meta.path_secret) |secret| {
        try op.put(alloc, "security", .{ .array = array(alloc) });
        try op.put(alloc, "x-zigbase-auth", .{ .string = "path-secret" });
        try op.put(alloc, "x-zigbase-secret-mismatch", .{ .string = @tagName(secret.on_mismatch) });
        return;
    }
    switch (meta.auth) {
        .public => {
            try op.put(alloc, "security", .{ .array = array(alloc) });
            try op.put(alloc, "x-zigbase-auth", .{ .string = "public" });
        },
        .authed, .superuser => {
            var requirement = object();
            try requirement.put(alloc, "bearerAuth", .{ .array = array(alloc) });
            var security = array(alloc);
            try security.append(.{ .object = requirement });
            try op.put(alloc, "security", .{ .array = security });
            try op.put(alloc, "x-zigbase-auth", .{ .string = if (meta.auth == .superuser) "superuser" else "authenticated" });
        },
    }
    if (meta.authed_collection) |gate| {
        try op.put(alloc, "x-zigbase-auth-collection", .{ .string = gate.collection });
        try op.put(alloc, "x-zigbase-allow-superuser", .{ .bool = gate.allow_superuser });
    }
}

fn addRoute(comptime meta: events.RouteMeta, alloc: std.mem.Allocator, paths: *Object) !void {
    if (comptime !route_path.isCanonicalPattern(meta.path))
        @compileError("consumer route '" ++ meta.path ++ "' is not a canonical router pattern");
    if (comptime meta.method == .UNKNOWN)
        @compileError("consumer route '" ++ meta.path ++ "' cannot use method .UNKNOWN");
    const rendered_path = try openApiPath(alloc, meta.path);
    const path = canonicalPathItem(paths, rendered_path) orelse rendered_path;
    var params = try routePathParameters(meta, path, alloc);
    if (!meta.untyped and meta.Input != void and route_types.inputUsesQuery(meta.method) and @typeInfo(meta.Input) == .@"struct") {
        inline for (@typeInfo(meta.Input).@"struct".fields) |field|
            try params.append(try queryFieldParameter(field, alloc));
    }
    if (meta.path_secret) |secret| {
        if (secret.in != .path) try params.append(try secretParameter(secret, alloc));
    }
    var op = object();
    try op.put(alloc, "operationId", .{ .string = meta.name });
    if (params.items.len > 0) try op.put(alloc, "parameters", .{ .array = params });
    if (meta.untyped) {
        try op.put(alloc, "x-zigbase-untyped", .{ .bool = true });
    } else if (meta.Input != void and !(route_types.inputUsesQuery(meta.method) and @typeInfo(meta.Input) == .@"struct")) {
        var media = object();
        try media.put(alloc, "schema", try zigSchema(meta.Input, alloc));
        var content = object();
        try content.put(alloc, "application/json", .{ .object = media });
        var body = object();
        try body.put(alloc, "required", .{ .bool = true });
        try body.put(alloc, "content", .{ .object = content });
        try op.put(alloc, "requestBody", .{ .object = body });
    }
    try op.put(alloc, "responses", try routeResponses(meta.method, meta.Output, meta.untyped, alloc));
    try applyRouteSecurity(meta, alloc, &op);
    var item = if (paths.get(path)) |existing| existing.object else object();
    const method = methodName(meta.method);
    if (item.contains(method)) {
        std.debug.print(
            "zigbase openapi: duplicate route {s} {s} while exporting consumer operationId '{s}'\n",
            .{ method, path, meta.name },
        );
        return error.DuplicateRoute;
    }
    try item.put(alloc, method, .{ .object = op });
    try paths.put(alloc, path, .{ .object = item });
}

fn validateUniqueOperationIds(alloc: std.mem.Allocator, paths: Object) !void {
    const Origin = struct { method: []const u8, path: []const u8 };
    var seen: std.StringHashMap(Origin) = .init(alloc);
    defer seen.deinit();
    for (engine_server.migration_builtin_operations) |builtin| {
        try seen.put(builtin.operation_id, .{
            .method = methodName(builtin.method),
            .path = builtin.pattern,
        });
    }
    var path_it = paths.iterator();
    while (path_it.next()) |path_entry| {
        var method_it = path_entry.value_ptr.object.iterator();
        while (method_it.next()) |method_entry| {
            const operation_id = method_entry.value_ptr.object.get("operationId") orelse continue;
            const result = try seen.getOrPut(operation_id.string);
            if (result.found_existing) {
                const first = result.value_ptr.*;
                std.debug.print(
                    "zigbase openapi: duplicate operationId '{s}' at {s} {s}; first used by {s} {s}\n",
                    .{ operation_id.string, method_entry.key_ptr.*, path_entry.key_ptr.*, first.method, first.path },
                );
                return error.DuplicateOperationId;
            }
            result.value_ptr.* = .{
                .method = method_entry.key_ptr.*,
                .path = path_entry.key_ptr.*,
            };
        }
    }
}

pub fn generate(comptime route_meta: []const events.RouteMeta, comptime namespace: Namespace, alloc: std.mem.Allocator, collections: []const schema.Collection, options: Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var kept = std.ArrayList(schema.Collection).empty;
    for (collections) |col| if (!col.system) try kept.append(aa, col);
    std.sort.pdq(schema.Collection, kept.items, {}, lessByName);

    var paths = object();
    var schemas = object();
    try schemas.put(aa, "ZigBaseError", try errorSchema(aa));
    const symbol_bases = try collectionSymbolBases(aa, kept.items, route_meta);
    for (kept.items, symbol_bases) |col, base| try addCollection(aa, &paths, &schemas, col, base, kept.items);
    inline for (route_meta) |meta| try addRoute(meta, aa, &paths);
    try validateUniqueOperationIds(aa, paths);

    var bearer = object();
    try bearer.put(aa, "type", .{ .string = "http" });
    try bearer.put(aa, "scheme", .{ .string = "bearer" });
    try bearer.put(aa, "bearerFormat", .{ .string = "JWT" });
    var security_schemes = object();
    try security_schemes.put(aa, "bearerAuth", .{ .object = bearer });
    var components = object();
    try components.put(aa, "securitySchemes", .{ .object = security_schemes });
    try components.put(aa, "schemas", .{ .object = schemas });
    var info = object();
    try info.put(aa, "title", .{ .string = options.title });
    try info.put(aa, "version", .{ .string = options.api_version });
    var coverage = object();
    try coverage.put(aa, "collections", .{ .bool = true });
    try coverage.put(aa, "consumerRoutes", .{ .bool = route_meta.len > 0 });
    inline for (&.{ "admin", "realtime", "fileBytes", "allAuthMethods" }) |name| try coverage.put(aa, name, .{ .bool = false });
    var root = object();
    try root.put(aa, "openapi", .{ .string = "3.1.2" });
    try root.put(aa, "jsonSchemaDialect", .{ .string = "https://spec.openapis.org/oas/3.1/dialect/base" });
    try root.put(aa, "info", .{ .object = info });
    if (options.server) |url| {
        var server = object();
        try server.put(aa, "url", .{ .string = url });
        var servers = array(aa);
        try servers.append(.{ .object = server });
        try root.put(aa, "servers", .{ .array = servers });
    }
    try root.put(aa, "paths", .{ .object = paths });
    try root.put(aa, "components", .{ .object = components });
    try root.put(aa, "x-zigbase-coverage", .{ .object = coverage });
    try root.put(aa, "x-zigbase-contract-version", .{ .string = contract_version });
    try root.put(aa, "x-zigbase-gates", try exportedGates(namespace, aa));
    try root.put(aa, "x-zigbase-feature-public-route", if (namespace.features_public_route) |path| .{ .string = path } else .null);
    try root.put(aa, "x-zigbase-reserved-routes", try reservedRoutes(namespace, aa));
    try root.put(aa, "x-zigbase-reserved-prefixes", try reservedPrefixes(namespace, aa));
    try root.put(aa, "x-zigbase-builtin-operations", try builtinOperations(aa));
    const json = try std.json.Stringify.valueAlloc(aa, Value{ .object = root }, .{ .whitespace = .indent_2 });
    const result = try alloc.alloc(u8, json.len + 1);
    @memcpy(result[0..json.len], json);
    result[json.len] = '\n';
    return result;
}

pub fn generateCollections(alloc: std.mem.Allocator, collections: []const schema.Collection, options: Options) ![]u8 {
    return generate(&.{}, .{}, alloc, collections, options);
}

fn reservedHasRoute(routes: []const Value, method: []const u8, path: []const u8) bool {
    for (routes) |entry| {
        const route = entry.object;
        if (std.mem.eql(u8, route.get("method").?.string, method) and
            std.mem.eql(u8, route.get("path").?.string, path)) return true;
    }
    return false;
}

test "collection export maps constraints, access, auth writes, and deterministic ordering" {
    const a = std.testing.allocator;
    const roles = [_][]const u8{ "author", "editor" };
    const mime = [_][]const u8{"image/png"};
    const post_fields = [_]schema.Field{
        .{ .id = "title", .name = "title", .required = true, .searchable = true, .options = .{ .text = .{ .min = 2, .max = 120, .pattern = "^[A-Z]" } } },
        .{ .id = "price", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2, .min = 0 } } },
        .{ .id = "roles", .name = "roles", .options = .{ .select = .{ .values = &roles, .maxSelect = 2 } } },
        .{ .id = "owner", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = "users-id" } } },
        .{ .id = "photos", .name = "photos", .options = .{ .file = .{ .maxSelect = 3, .maxSize = 1024, .mimeTypes = &mime } } },
        .{ .id = "secret", .name = "secret", .hidden = true, .encrypted = true, .options = .{ .text = .{} } },
    };
    const auth_fields = [_]schema.Field{
        .{ .id = "email", .name = "email", .required = true, .options = .{ .email = .{} } },
        .{ .id = "hash", .name = "passwordHash", .hidden = true, .options = .{ .text = .{} } },
    };
    const cols = [_]schema.Collection{
        .{ .id = "users-id", .name = "users", .type = .auth, .fields = &auth_fields, .createRule = "@public" },
        .{ .id = "posts-id", .name = "posts", .fields = &post_fields, .listRule = "owner = @request.auth.id", .viewRule = "@public" },
        .{ .id = "sys", .name = "_private", .system = true, .fields = &.{} },
    };
    const first = try generateCollections(a, &cols, .{ .api_version = "1.2.3", .server = "https://example.test" });
    defer a.free(first);
    const second = try generateCollections(a, &.{ cols[1], cols[0] }, .{ .api_version = "1.2.3", .server = "https://example.test" });
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(first[first.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(Value, a, first, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3.1.2", root.get("openapi").?.string);
    try std.testing.expectEqualStrings(contract_version, root.get("x-zigbase-contract-version").?.string);
    try std.testing.expectEqualStrings("1.2.3", root.get("info").?.object.get("version").?.string);
    const reserved = root.get("x-zigbase-reserved-routes").?.array.items;
    try std.testing.expect(reserved.len >= engine_server.Server(.{}).routes.len);
    for ([_][2][]const u8{
        .{ "post", "/api/files/token" },
        .{ "get", "/api/realtime" },
        .{ "get", "/api/realtime/sse" },
    }) |expected| try std.testing.expect(reservedHasRoute(reserved, expected[0], expected[1]));
    const builtins = root.get("x-zigbase-builtin-operations").?.array.items;
    try std.testing.expectEqual(@as(usize, engine_server.migration_builtin_operations.len), builtins.len);
    try std.testing.expect(root.get("paths").?.object.get("/api/collections/_private/records") == null);
    const post_list = root.get("paths").?.object.get("/api/collections/posts/records").?.object.get("get").?.object;
    try std.testing.expectEqualStrings("conditional", post_list.get("x-zigbase-access").?.string);
    try std.testing.expectEqualStrings("posts", post_list.get("x-zigbase-collection").?.string);
    try std.testing.expectEqualStrings("base", post_list.get("x-zigbase-collection-type").?.string);
    try std.testing.expectEqualStrings("owner = @request.auth.id", post_list.get("x-zigbase-rule").?.string);
    try std.testing.expect(post_list.get("security") == null);
    const post_view = root.get("paths").?.object.get("/api/collections/posts/records/{id}").?.object.get("get").?.object;
    try std.testing.expectEqual(@as(usize, 0), post_view.get("security").?.array.items.len);
    const view_params = post_view.get("parameters").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), view_params.len);
    try std.testing.expectEqualStrings("id", view_params[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("expand", view_params[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("fields", view_params[2].object.get("name").?.string);
    const schemas = root.get("components").?.object.get("schemas").?.object;
    const record_schema = schemas.get("PostsRecord").?.object;
    try std.testing.expect(record_schema.get("required") == null);
    try std.testing.expect(record_schema.get("additionalProperties") == null);
    const props = record_schema.get("properties").?.object;
    try std.testing.expectEqual(@as(i64, 2), props.get("title").?.object.get("minLength").?.integer);
    const price_types = props.get("price").?.object.get("type").?.array.items;
    try std.testing.expectEqualStrings("string", price_types[0].string);
    try std.testing.expectEqualStrings("null", price_types[1].string);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), props.get("price").?.object.get("multipleOf").?.float, 0.000001);
    try std.testing.expectEqual(@as(i64, 2), props.get("roles").?.object.get("maxItems").?.integer);
    try std.testing.expect(props.get("secret").?.object.get("writeOnly").?.bool);
    const create_props = schemas.get("UsersCreate").?.object.get("properties").?.object;
    const users_create = root.get("paths").?.object.get("/api/collections/users/records").?.object.get("post").?.object;
    try std.testing.expectEqualStrings("auth", users_create.get("x-zigbase-collection-type").?.string);
    try std.testing.expectEqualStrings("users", users_create.get("x-zigbase-collection").?.string);
    try std.testing.expect(create_props.get("password") != null);
    try std.testing.expect(create_props.get("passwordConfirm") != null);
    const update_props = schemas.get("UsersUpdate").?.object.get("properties").?.object;
    try std.testing.expect(update_props.get("password") != null);
    try std.testing.expect(update_props.get("passwordConfirm") != null);
    try std.testing.expect(update_props.get("oldPassword") != null);
    const price_input_types = schemas.get("PostsCreate").?.object.get("properties").?.object.get("price").?.object.get("type").?.array.items;
    try std.testing.expectEqualStrings("string", price_input_types[0].string);
    try std.testing.expectEqualStrings("number", price_input_types[1].string);
    try std.testing.expect(std.mem.indexOf(u8, first, "passwordHash") == null);
}

test "collection export covers every field option and preserves item bounds" {
    const a = std.testing.allocator;
    const fields = [_]schema.Field{
        .{ .id = "email", .name = "email", .options = .{ .email = .{} } },
        .{ .id = "site", .name = "site", .required = true, .options = .{ .url = .{} } },
        .{ .id = "body", .name = "body", .required = true, .options = .{ .editor = .{} } },
        .{ .id = "when", .name = "when", .required = true, .options = .{ .date = .{ .min = "2026-01-01 00:00:00.000Z", .max = "2027-01-01 00:00:00.000Z" } } },
        .{ .id = "changed", .name = "changed", .required = true, .options = .{ .autodate = .{ .onUpdate = true } } },
        .{ .id = "active", .name = "active", .required = true, .options = .{ .bool = .{} } },
        .{ .id = "count", .name = "count", .required = true, .options = .{ .number = .{ .mode = .int, .max = 9 } } },
        .{ .id = "ratio", .name = "ratio", .required = true, .options = .{ .number = .{ .mode = .float } } },
        .{ .id = "meta", .name = "meta", .required = true, .options = .{ .json = .{ .maxSize = 4096 } } },
        .{ .id = "parents", .name = "parents", .required = true, .options = .{ .relation = .{ .targetCollectionId = "nodes-id", .minSelect = 1, .maxSelect = 4 } } },
    };
    const cols = [_]schema.Collection{.{ .id = "nodes-id", .name = "nodes", .fields = &fields }};
    const doc = try generateCollections(a, &cols, .{ .api_version = "dev" });
    defer a.free(doc);
    const parsed = try std.json.parseFromSlice(Value, a, doc, .{});
    defer parsed.deinit();
    const schemas = parsed.value.object.get("components").?.object.get("schemas").?.object;
    const props = schemas.get("NodesRecord").?.object.get("properties").?.object;
    try std.testing.expectEqualStrings("email", props.get("email").?.object.get("format").?.string);
    try std.testing.expectEqualStrings("uri", props.get("site").?.object.get("format").?.string);
    try std.testing.expectEqualStrings("string", props.get("body").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("date-time", props.get("when").?.object.get("format").?.string);
    try std.testing.expect(props.get("changed").?.object.get("readOnly").?.bool);
    try std.testing.expectEqualStrings("boolean", props.get("active").?.object.get("type").?.string);
    const email_types = props.get("email").?.object.get("type").?.array.items;
    try std.testing.expectEqualStrings("string", email_types[0].string);
    try std.testing.expectEqualStrings("null", email_types[1].string);
    try std.testing.expectEqualStrings("string", props.get("count").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("number", props.get("ratio").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 4096), props.get("meta").?.object.get("x-zigbase-maxBytes").?.integer);
    const parents = props.get("parents").?.object;
    try std.testing.expectEqual(@as(i64, 1), parents.get("minItems").?.integer);
    try std.testing.expectEqual(@as(i64, 4), parents.get("maxItems").?.integer);
    try std.testing.expectEqualStrings("nodes", parents.get("items").?.object.get("x-zigbase-relation").?.string);
    try std.testing.expect(schemas.get("NodesUpdate").?.object.get("properties").?.object.get("changed") == null);
    const err = schemas.get("ZigBaseError").?.object;
    try std.testing.expect(err.get("properties").?.object.get("data").?.object.get("additionalProperties") != null);
}

test "locked collection operations require bearer authentication" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{.{ .id = "notes", .name = "notes", .fields = &.{}, .updateRule = "" }};
    const doc = try generateCollections(a, &cols, .{ .api_version = "dev" });
    defer a.free(doc);
    const parsed = try std.json.parseFromSlice(Value, a, doc, .{});
    defer parsed.deinit();
    const op = parsed.value.object.get("paths").?.object.get("/api/collections/notes/records").?.object.get("post").?.object;
    try std.testing.expectEqualStrings("locked", op.get("x-zigbase-access").?.string);
    try std.testing.expect(op.get("security").?.array.items[0].object.get("bearerAuth") != null);
    const update = parsed.value.object.get("paths").?.object.get("/api/collections/notes/records/{id}").?.object.get("patch").?.object;
    try std.testing.expectEqualStrings("locked", update.get("x-zigbase-access").?.string);
    try std.testing.expect(update.get("security").?.array.items[0].object.get("bearerAuth") != null);
}

test "consumer routes map bounded Zig types, methods, paths, and authentication" {
    const Query = struct { limit: u16, tag: ?[]const u8 = null };
    const State = enum { queued, done };
    const Payload = struct { title: []const u8, state: State, scores: []const f32, tag: ?[]const u8, token: [:0]const u8, count: u32, huge: u64 };
    const Reply = struct { ok: bool, payload: ?Payload };
    const routes = [_]events.RouteMeta{
        .{ .method = .GET, .path = "/api/jobs/:id", .name = "getJob", .auth = .public, .Input = Query, .Output = Reply },
        .{ .method = .POST, .path = "/api/jobs", .name = "createJob", .auth = .authed, .Input = Payload, .Output = std.json.Value },
        .{ .method = .DELETE, .path = "/api/jobs/:id", .name = "deleteJob", .auth = .superuser, .Input = void, .Output = void },
        .{ .method = .GET, .path = "/api/raw", .name = "raw", .auth = .public, .Input = void, .Output = void, .untyped = true },
        .{ .method = .POST, .path = "/api/hooks/deploy", .name = "deployHook", .auth = .public, .Input = void, .Output = void, .path_secret = .{ .param = "x-hook-token", .in = .header, .on_mismatch = .not_found } },
        .{ .method = .GET, .path = "/api/account", .name = "account", .auth = .authed, .Input = void, .Output = bool, .authed_collection = .{ .collection = "members", .allow_superuser = true } },
    };
    const a = std.testing.allocator;
    const doc = try generate(&routes, .{}, a, &.{}, .{ .api_version = "dev" });
    defer a.free(doc);
    const parsed = try std.json.parseFromSlice(Value, a, doc, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("x-zigbase-coverage").?.object.get("consumerRoutes").?.bool);
    const paths = root.get("paths").?.object;
    const get_job = paths.get("/api/jobs/{id}").?.object.get("get").?.object;
    try std.testing.expectEqualStrings("getJob", get_job.get("operationId").?.string);
    try std.testing.expect(get_job.get("requestBody") == null);
    const query_params = get_job.get("parameters").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), query_params.len);
    try std.testing.expectEqualStrings("path", query_params[0].object.get("in").?.string);
    try std.testing.expectEqualStrings("query", query_params[1].object.get("in").?.string);
    try std.testing.expect(query_params[1].object.get("required").?.bool);
    try std.testing.expect(query_params[2].object.get("required") == null);
    const reply = get_job.get("responses").?.object.get("200").?.object.get("content").?.object.get("application/json").?.object.get("schema").?.object;
    try std.testing.expectEqualStrings("boolean", reply.get("properties").?.object.get("ok").?.object.get("type").?.string);
    const create_job = paths.get("/api/jobs").?.object.get("post").?.object;
    try std.testing.expect(create_job.get("requestBody") != null);
    const body_schema = create_job.get("requestBody").?.object.get("content").?.object.get("application/json").?.object.get("schema").?.object;
    const body_required = body_schema.get("required").?.array.items;
    try std.testing.expectEqual(@as(usize, 7), body_required.len);
    try std.testing.expectEqualStrings("tag", body_required[3].string);
    const body_props = body_schema.get("properties").?.object;
    try std.testing.expectEqualStrings("string", body_props.get("token").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("int64", body_props.get("count").?.object.get("format").?.string);
    try std.testing.expect(body_props.get("huge").?.object.get("format") == null);
    try std.testing.expectEqualStrings("authenticated", create_job.get("x-zigbase-auth").?.string);
    try std.testing.expect(create_job.get("security").?.array.items[0].object.get("bearerAuth") != null);
    const delete_job = paths.get("/api/jobs/{id}").?.object.get("delete").?.object;
    try std.testing.expect(delete_job.get("responses").?.object.get("204") != null);
    try std.testing.expectEqualStrings("superuser", delete_job.get("x-zigbase-auth").?.string);
    try std.testing.expect(paths.get("/api/raw").?.object.get("get").?.object.get("x-zigbase-untyped").?.bool);
    const deploy = paths.get("/api/hooks/deploy").?.object.get("post").?.object;
    const deploy_secret = deploy.get("parameters").?.array.items[0].object;
    try std.testing.expectEqualStrings("x-hook-token", deploy_secret.get("name").?.string);
    try std.testing.expectEqualStrings("header", deploy_secret.get("in").?.string);
    try std.testing.expect(deploy_secret.get("x-zigbase-path-secret").?.bool);
    const account = paths.get("/api/account").?.object.get("get").?.object;
    try std.testing.expectEqualStrings("members", account.get("x-zigbase-auth-collection").?.string);
    try std.testing.expect(account.get("x-zigbase-collection") == null);
    try std.testing.expect(account.get("x-zigbase-collection-type") == null);
    try std.testing.expect(account.get("x-zigbase-allow-superuser").?.bool);
}

test "reserved namespace follows feature gates and the remapped feature route" {
    const a = std.testing.allocator;
    const doc = try generate(&.{}, .{
        .gates = .{
            .analytics = false,
            .senders = false,
            .mail_webhook = false,
            .tenancy = false,
            .webauthn = false,
            .magic_link = false,
            .oauth2 = false,
            .mail_unsubscribe = false,
        },
        .features_public_route = "/public/features",
    }, a, &.{}, .{ .api_version = "dev" });
    defer a.free(doc);
    const parsed = try std.json.parseFromSlice(Value, a, doc, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "/public/features",
        parsed.value.object.get("x-zigbase-feature-public-route").?.string,
    );
    const reserved = parsed.value.object.get("x-zigbase-reserved-routes").?.array.items;
    for (reserved) |entry| {
        const path = entry.object.get("path").?.string;
        try std.testing.expect(!std.mem.eql(u8, path, "/api/analytics/events"));
        try std.testing.expect(!std.mem.eql(u8, path, "/api/collections/{col}/auth/webauthn/register/begin"));
        try std.testing.expect(!std.mem.eql(u8, path, "/api/state"));
    }
    for ([_][]const u8{ "get", "head" }) |method|
        try std.testing.expect(reservedHasRoute(reserved, method, "/public/features"));
    const prefixes = parsed.value.object.get("x-zigbase-reserved-prefixes").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), prefixes.len);
    try std.testing.expectEqualStrings("/_", prefixes[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("admin", prefixes[0].object.get("source").?.string);

    const no_admin_doc = try generate(&.{}, .{ .gates = .{ .admin = false } }, a, &.{}, .{ .api_version = "dev" });
    defer a.free(no_admin_doc);
    const no_admin = try std.json.parseFromSlice(Value, a, no_admin_doc, .{});
    defer no_admin.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        no_admin.value.object.get("x-zigbase-reserved-prefixes").?.array.items.len,
    );
}

test "feature route metadata distinguishes default, remapped, and disabled configurations" {
    const a = std.testing.allocator;
    inline for (.{
        .{ .namespace = Namespace{}, .expected = "/api/state", .is_null = false },
        .{ .namespace = Namespace{ .features_public_route = null }, .expected = "", .is_null = true },
    }) |case| {
        const doc = try generate(&.{}, case.namespace, a, &.{}, .{ .api_version = "dev" });
        defer a.free(doc);
        const parsed = try std.json.parseFromSlice(Value, a, doc, .{});
        defer parsed.deinit();
        const marker = parsed.value.object.get("x-zigbase-feature-public-route").?;
        if (case.is_null) {
            try std.testing.expectEqual(.null, std.meta.activeTag(marker));
        } else {
            try std.testing.expectEqualStrings(case.expected, marker.string);
        }
        const reserved = parsed.value.object.get("x-zigbase-reserved-routes").?.array.items;
        for ([_][]const u8{ "get", "head" }) |method|
            try std.testing.expectEqual(!case.is_null, reservedHasRoute(reserved, method, "/api/state"));
    }
}

test "typed HEAD route exports query parameters without a request body" {
    const a = std.testing.allocator;
    const Input = struct { report_id: u32 };
    const routes = [_]events.RouteMeta{.{
        .method = .HEAD,
        .path = "/api/report",
        .name = "report",
        .auth = .public,
        .Input = Input,
        .Output = struct { count: u32 },
    }};
    const doc = try generate(&routes, .{}, a, &.{}, .{ .api_version = "dev" });
    defer a.free(doc);
    const parsed = try std.json.parseFromSlice(Value, a, doc, .{});
    defer parsed.deinit();
    const head_operation = parsed.value.object.get("paths").?.object
        .get("/api/report").?.object.get("head").?.object;
    try std.testing.expect(head_operation.get("requestBody") == null);
    const success = head_operation.get("responses").?.object.get("200").?.object;
    try std.testing.expect(success.get("content") == null);
    try std.testing.expect(head_operation.get("responses").?.object.get("204") == null);
    const parameters = head_operation.get("parameters").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), parameters.len);
    try std.testing.expectEqualStrings("report_id", parameters[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("query", parameters[0].object.get("in").?.string);
}

test "OpenAPI generation disambiguates collection operation ids and rejects consumer collisions" {
    const a = std.testing.allocator;
    const cols = [_]schema.Collection{.{ .id = "posts-id", .name = "posts", .fields = &.{} }};
    const duplicate_id = [_]events.RouteMeta{.{
        .method = .POST,
        .path = "/api/publish",
        .name = "listPosts",
        .auth = .superuser,
        .Input = void,
        .Output = void,
    }};
    const disambiguated = try generate(&duplicate_id, .{}, a, &cols, .{ .api_version = "dev" });
    defer a.free(disambiguated);
    const parsed = try std.json.parseFromSlice(Value, a, disambiguated, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    try std.testing.expectEqualStrings(
        "listPosts_posts",
        paths.get("/api/collections/posts/records").?.object.get("get").?.object.get("operationId").?.string,
    );
    try std.testing.expectEqualStrings(
        "listPosts",
        paths.get("/api/publish").?.object.get("post").?.object.get("operationId").?.string,
    );

    const builtin_id = [_]events.RouteMeta{.{
        .method = .POST,
        .path = "/api/logout-wrapper",
        .name = "logout",
        .auth = .public,
        .Input = void,
        .Output = void,
    }};
    try std.testing.expectError(error.DuplicateOperationId, generate(&builtin_id, .{}, a, &.{}, .{ .api_version = "dev" }));

    const duplicate_route = [_]events.RouteMeta{.{
        .method = .GET,
        .path = "/api/collections/posts/records",
        .name = "shadowPosts",
        .auth = .superuser,
        .Input = void,
        .Output = void,
    }};
    try std.testing.expectError(error.DuplicateRoute, generate(&duplicate_route, .{}, a, &cols, .{ .api_version = "dev" }));
}

test "collection symbols remain unique when friendly names collapse" {
    const a = std.testing.allocator;
    const snake_fields = [_]schema.Field{.{ .id = "snake", .name = "snake_only", .options = .{ .text = .{} } }};
    const camel_fields = [_]schema.Field{.{ .id = "camel", .name = "camel_only", .options = .{ .text = .{} } }};
    const cols = [_]schema.Collection{
        .{ .id = "snake-id", .name = "my_posts", .fields = &snake_fields },
        .{ .id = "camel-id", .name = "myPosts", .fields = &camel_fields },
        .{ .id = "upper-id", .name = "Foo", .fields = &.{} },
        .{ .id = "lower-id", .name = "foo", .fields = &.{} },
        .{ .id = "single-id", .name = "a_b", .fields = &.{} },
        .{ .id = "double-id", .name = "a__b", .fields = &.{} },
    };
    const doc = try generateCollections(a, &cols, .{ .api_version = "dev" });
    defer a.free(doc);
    const parsed = try std.json.parseFromSlice(Value, a, doc, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const schemas = root.get("components").?.object.get("schemas").?.object;
    try std.testing.expect(schemas.get("MyPosts_my_postsRecord").?.object.get("properties").?.object.get("snake_only") != null);
    try std.testing.expect(schemas.get("MyPosts_myPostsRecord").?.object.get("properties").?.object.get("camel_only") != null);
    inline for (&.{ "Foo_FooRecord", "Foo_fooRecord", "AB_a_bRecord", "AB_a__bRecord" }) |name|
        try std.testing.expect(schemas.get(name) != null);

    const paths = root.get("paths").?.object;
    try std.testing.expectEqualStrings(
        "listMyPosts_my_posts",
        paths.get("/api/collections/my_posts/records").?.object.get("get").?.object.get("operationId").?.string,
    );
    try std.testing.expectEqualStrings(
        "listMyPosts_myPosts",
        paths.get("/api/collections/myPosts/records").?.object.get("get").?.object.get("operationId").?.string,
    );
}

test "template-equivalent routes merge under one canonical OpenAPI path item" {
    const a = std.testing.allocator;
    const routes = [_]events.RouteMeta{
        .{ .method = .GET, .path = "/api/items/:id", .name = "getItem", .auth = .public, .Input = void, .Output = bool },
        .{ .method = .DELETE, .path = "/api/items/:item_id", .name = "deleteItem", .auth = .public, .Input = void, .Output = void, .path_secret = .{ .param = "item_id", .in = .path, .on_mismatch = .not_found } },
        .{ .method = .POST, .path = "/api/collections/posts/records/:record", .name = "restorePost", .auth = .public, .Input = void, .Output = void, .path_secret = .{ .param = "record", .in = .path, .on_mismatch = .not_found } },
    };
    const cols = [_]schema.Collection{.{ .id = "posts-id", .name = "posts", .fields = &.{} }};
    const doc = try generate(&routes, .{}, a, &cols, .{ .api_version = "dev" });
    defer a.free(doc);
    const parsed = try std.json.parseFromSlice(Value, a, doc, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    try std.testing.expect(paths.get("/api/items/{item_id}") == null);
    const items = paths.get("/api/items/{id}").?.object;
    try std.testing.expect(items.get("get") != null);
    const delete_params = items.get("delete").?.object.get("parameters").?.array.items;
    try std.testing.expectEqualStrings("id", delete_params[0].object.get("name").?.string);
    try std.testing.expect(delete_params[0].object.get("schema").?.object.get("writeOnly").?.bool);

    try std.testing.expect(paths.get("/api/collections/posts/records/{record}") == null);
    const post_item = paths.get("/api/collections/posts/records/{id}").?.object;
    const restore_params = post_item.get("post").?.object.get("parameters").?.array.items;
    try std.testing.expectEqualStrings("id", restore_params[0].object.get("name").?.string);
    try std.testing.expect(restore_params[0].object.get("schema").?.object.get("writeOnly").?.bool);
}

test "path secret route metadata is useful and contains no configured secret source" {
    const routes = [_]events.RouteMeta{.{
        .method = .GET,
        .path = "/api/share/:token",
        .name = "share",
        .auth = .public,
        .Input = void,
        .Output = []const u8,
        .path_secret = .{ .param = "token", .in = .path, .on_mismatch = .forbidden },
    }};
    const a = std.testing.allocator;
    const doc = try generate(&routes, .{}, a, &.{}, .{ .api_version = "dev" });
    defer a.free(doc);
    const parsed = try std.json.parseFromSlice(Value, a, doc, .{});
    defer parsed.deinit();
    const op = parsed.value.object.get("paths").?.object.get("/api/share/{token}").?.object.get("get").?.object;
    try std.testing.expectEqualStrings("path-secret", op.get("x-zigbase-auth").?.string);
    try std.testing.expectEqualStrings("forbidden", op.get("x-zigbase-secret-mismatch").?.string);
    try std.testing.expectEqual(@as(usize, 0), op.get("security").?.array.items.len);
    const param_schema = op.get("parameters").?.array.items[0].object.get("schema").?.object;
    try std.testing.expect(param_schema.get("writeOnly").?.bool);
    try std.testing.expect(op.get("x-zigbase-secret-source") == null);
    try std.testing.expect(param_schema.get("default") == null);
    try std.testing.expect(param_schema.get("example") == null);
}
