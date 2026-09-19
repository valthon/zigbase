//! Explicit authenticated JSON CRUD receipts. No middleware/state when omitted.
const std = @import("std");
const http = @import("http.zig");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const records = @import("records.zig");
const policy = @import("policy.zig");
const request = @import("request.zig");
const api = @import("api/records.zig");
const ApiError = @import("api/error.zig").ApiError;
const idem = @import("idempotency.zig");
const realtime = @import("realtime/ws.zig");

const Handler = *const fn (*http.RequestCtx) anyerror!http.Response;
pub fn resolve(comptime cfg: anytype) if (@import("build_options").rest_idempotency) ?Handler else void {
    if (!@hasField(@TypeOf(cfg), "rest_idempotency")) return if (@import("build_options").rest_idempotency) null else {};
    if (!@import("build_options").rest_idempotency) @compileError(".rest_idempotency requires -Drest-idempotency=true");
    const config = cfg.rest_idempotency;
    for (std.meta.fields(@TypeOf(config))) |field| {
        if (!std.mem.eql(u8, field.name, "collections") and !std.mem.eql(u8, field.name, "limits")) @compileError("unknown .rest_idempotency key: " ++ field.name);
    }
    if (!@hasField(@TypeOf(config), "collections") or !@hasField(@TypeOf(config), "limits")) @compileError(".rest_idempotency requires .collections and .limits");
    if (config.collections.len == 0 or config.collections.len > 64) @compileError(".rest_idempotency requires 1..64 collections");
    for (config.collections) |name| if (!schema.isValidIdentifier(name)) @compileError("invalid REST idempotency collection name");
    return Implementation(config).handle;
}

fn Implementation(comptime config: anytype) type {
    const limits: idem.Limits = blk: {
        var value: idem.Limits = .{ .namespace = config.limits.namespace };
        for (std.meta.fields(@TypeOf(config.limits))) |field| {
            if (!@hasField(idem.Limits, field.name)) @compileError("unknown REST idempotency limit: " ++ field.name);
            @field(value, field.name) = @field(config.limits, field.name);
        }
        break :blk value;
    };
    const Ledger = idem.Idempotency(limits);
    return struct {
        const State = struct {
            ctx: *http.RequestCtx,
            col: schema.Collection,
            rctx: request.RequestContext,
            auth_collection_id: []const u8,
            action: policy.Action,
            rid: []const u8,
            data: std.json.Value,
            result: std.json.Value = .null,
            delete_token: ?[]const u8 = null,
        };
        fn state(raw: *anyopaque) *State {
            return @ptrCast(@alignCast(raw));
        }

        fn authorize(conn: *db.Db, raw: *anyopaque) !void {
            const s = state(raw);
            // Hold the metadata writer lock through mutation/receipt commit. A
            // PostgreSQL namespace lock alone does not serialize schema writers.
            try @import("schema_gen.zig").lock(conn);
            // Reauthenticate after both namespace and metadata coordination.
            const current = api.buildContext(s.ctx, conn, if (s.action == .delete) null else s.data);
            const old = s.rctx.auth orelse return error.Unauthorized;
            const fresh = current.auth orelse return error.Unauthorized;
            if (!std.mem.eql(u8, s.rctx.collection, current.collection) or !std.mem.eql(u8, old.object.get("id").?.string, fresh.object.get("id").?.string) or !std.mem.eql(u8, s.rctx.account_id, current.account_id)) return error.Unauthorized;
            const auth_collection = (try collections.get(s.ctx.allocator.a, conn, current.collection)) orelse return error.Unauthorized;
            defer auth_collection.deinit(s.ctx.allocator.a);
            if (!std.mem.eql(u8, auth_collection.id, s.auth_collection_id)) return error.Unauthorized;
            s.rctx = current;
            // Reject concurrent schema/rule changes rather than use a stale lease.
            const live = (try collections.get(s.ctx.allocator.a, conn, s.col.id)) orelse return error.NotFound;
            defer live.deinit(s.ctx.allocator.a);
            const expected = try std.json.Stringify.valueAlloc(s.ctx.allocator.a, s.col, .{});
            const actual = try std.json.Stringify.valueAlloc(s.ctx.allocator.a, live, .{});
            if (!std.mem.eql(u8, expected, actual)) return error.PayloadConflict;
            switch (policy.decide(s.col, s.action, &s.rctx)) {
                .deny_locked => return error.Forbidden,
                .allow => {},
                .check => {
                    // Deleted rows cannot prove a current row predicate on replay.
                    if (s.action == .delete) return error.UnsupportedDeletePolicy;
                    if (s.action == .update and !try policy.authorizes(s.ctx.allocator.a, conn, s.col, .update, s.rid, &s.rctx)) return error.NotFound;
                },
            }
            if (s.rctx.tenancy_enabled and !s.rctx.is_superuser and s.col.options.tenant_field != null and s.rctx.account_id.len == 0) return error.Forbidden;
        }
        fn authorizeReplay(conn: *db.Db, raw: *anyopaque, body: []const u8) !void {
            const s = state(raw);
            if (s.action == .delete) return;
            const parsed = try std.json.parseFromSlice(std.json.Value, s.ctx.allocator.a, body, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidReceipt;
            const stored_id = parsed.value.object.get("id") orelse return error.InvalidReceipt;
            if (stored_id != .string) return error.InvalidReceipt;
            const id = stored_id.string;
            // Ledger's initial authorize already holds the schema lock through
            // commit. Acquire the record lock second; reauthorization below only
            // refreshes state after waiting, it is not the first schema lock.
            if (db.dbDialect(conn).kind == .postgres) {
                const table = try @import("ddl.zig").quoteIdent(s.ctx.allocator.a, s.col.name);
                defer s.ctx.allocator.a.free(table);
                const sql = try std.fmt.allocPrintSentinel(s.ctx.allocator.a, "SELECT \"id\" FROM {s} WHERE \"id\"=$1 FOR UPDATE;", .{table}, 0);
                defer s.ctx.allocator.a.free(sql);
                var locked = try conn.prepare(sql);
                defer locked.finalize();
                try locked.bindText(1, id);
                if (!try locked.step()) return error.NotFound;
                locked.reset();
                // Refresh identity/tenant state after waiting on a concurrent row
                // writer. Hold the row lock through policy, body checks and commit.
                try authorize(conn, raw);
            }
            if (!try policy.authorizes(s.ctx.allocator.a, conn, s.col, s.action, id, &s.rctx)) return error.NotFound;
            // Replay visibility must match an ordinary GET, not inherit mutation
            // method/body macros that could permit an otherwise unreadable record.
            var view_context = s.rctx;
            view_context.method = "GET";
            view_context.data = null;
            if (!try policy.authorizes(s.ctx.allocator.a, conn, s.col, .view, id, &view_context)) return error.NotFound;
            // Returning an old representation after another write could reveal fields
            // no longer present. Require the current public response to be identical.
            const current = (try records.get(s.ctx.allocator.a, conn, s.col, id)) orelse return error.NotFound;
            const bytes = try std.json.Stringify.valueAlloc(s.ctx.allocator.a, current, .{});
            if (!std.mem.eql(u8, bytes, body)) return error.RecordChanged;
        }
        fn mutate(conn: *db.Db, raw: *anyopaque, output: []u8) !usize {
            const s = state(raw);
            const a = s.ctx.allocator.a;
            const app = s.ctx.app.?;
            if (s.action == .delete) {
                const previous = (try records.get(a, conn, s.col, s.rid)) orelse return error.NotFound;
                // Preserve existing transactional delete transport preparation.
                const prepared = realtime.prepareDelete(a, app, conn, s.col, s.rid, previous);
                s.delete_token = prepared.token;
                if (comptime @import("build_options").durable_realtime) {
                    const snapshot = (try records.getAtRest(a, conn, s.col, s.rid)) orelse return error.NotFound;
                    try @import("realtime/durable.zig").capture(a, app.io, conn, s.col, .delete, s.rid, snapshot);
                }
                if (!try records.deleteInTxn(a, conn, s.col, s.rid)) return error.NotFound;
                s.result = previous;
                return 0;
            }
            var input = s.data;
            var stamped: std.json.ObjectMap = .empty;
            defer stamped.deinit(a);
            if (s.action == .create and s.rctx.tenancy_enabled and !s.rctx.is_superuser) if (s.col.options.tenant_field) |field| {
                // Only the outer map is mutated. Keep request.data's original
                // client values intact for identical first-attempt/replay policy.
                stamped = try s.data.object.clone(a);
                try stamped.put(a, field, .{ .string = s.rctx.account_id });
                input = .{ .object = stamped };
            };
            const result = if (s.action == .create) try records.createInTxnOpts(a, app.io, conn, s.col, input, .{}) else (try records.updateInTxn(a, conn, s.col, s.rid, input)) orelse return error.NotFound;
            const id = result.object.get("id").?.string;
            if (!try policy.authorizes(a, conn, s.col, s.action, id, &s.rctx)) return error.Forbidden;
            if (comptime @import("build_options").durable_realtime)
                try @import("realtime/durable.zig").capture(a, app.io, conn, s.col, if (s.action == .create) .create else .update, id, null);
            const bytes = try std.json.Stringify.valueAlloc(a, result, .{});
            if (bytes.len > output.len) return error.ResultTooLarge;
            @memcpy(output[0..bytes.len], bytes);
            s.result = result;
            return bytes.len;
        }
        fn handle(ctx: *http.RequestCtx) !http.Response {
            return attempt(ctx) catch |err| switch (err) {
                error.Unauthorized => ApiError.unauthorized().toResponse(ctx.allocator.a),
                error.Forbidden => ApiError.forbidden().toResponse(ctx.allocator.a),
                error.NotFound => ApiError.notFound().toResponse(ctx.allocator.a),
                error.PayloadConflict, error.RecordChanged => ApiError.conflict("Idempotency key conflicts with current input, schema, or record state.").toResponse(ctx.allocator.a),
                error.WriterUnavailable => ApiError.withCode(503, .internal, "Database writer unavailable; operator recovery required.").toResponse(ctx.allocator.a),
                error.CapacityExceeded, error.IdempotencyBusy => ApiError.withCode(503, .internal, "Idempotency capacity or coordination unavailable; retry later.").toResponse(ctx.allocator.a),
                error.InvalidScope, error.UnsupportedDeletePolicy, error.NotObject, error.PayloadTooLarge, error.ResultTooLarge => ApiError.badRequest("Unsupported idempotent mutation, invalid input, or receipt budget exceeded.").toResponse(ctx.allocator.a),
                error.Constraint => ApiError.conflict("A record with these values already exists.").toResponse(ctx.allocator.a),
                else => err,
            };
        }
        fn attempt(ctx: *http.RequestCtx) !http.Response {
            defer records.last_errors = null;
            const app = ctx.app.?;
            const a = ctx.allocator.a;
            const name = ctx.param("col") orelse return error.NotFound;
            var allowed = false;
            inline for (config.collections) |colname| if (std.mem.eql(u8, name, colname)) {
                allowed = true;
            };
            if (!allowed or ctx.query.len != 0 or ctx.form_fields != null or ctx.files.len != 0 or (app.dispatch != null and app.dispatch.?.record != null)) return ApiError.badRequest("Idempotency requires an allowlisted JSON collection without record hooks or query parameters.").toResponse(a);
            const conn = app.pool.acquireWriter();
            defer app.pool.releaseWriter();
            // Recovery runs before unlock, after all request statements finalize.
            // Never hand a failed transaction back to another request.
            defer app.pool.recoverWriter() catch |err| std.log.err("REST writer recovery failed: {s}; writer unavailable until operator recovery", .{@errorName(err)});
            if (!conn.isHealthy()) return error.WriterUnavailable;
            const col = (try collections.get(a, conn, name)) orelse return error.NotFound;
            defer col.deinit(a);
            if (col.type != .base or col.options.ttl_field != null) return ApiError.badRequest("Idempotency supports base collections without TTL.").toResponse(a);
            for (col.fields) |field| if (field.fieldType() == .file or field.encrypted or field.hidden) return ApiError.badRequest("Idempotent collections cannot contain file, encrypted, or hidden fields.").toResponse(a);
            const action: policy.Action = switch (ctx.method) {
                .POST => .create,
                .PATCH => .update,
                .DELETE => .delete,
                else => return error.InvalidScope,
            };
            if (ctx.body.len > limits.max_payload_bytes) return error.PayloadTooLarge;
            if (action == .delete and ctx.body.len != 0) return ApiError.badRequest("Idempotent DELETE requires an empty body.").toResponse(a);
            const data = if (action == .delete) std.json.Value.null else (std.json.parseFromSlice(std.json.Value, a, ctx.body, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.NotObject,
            }).value;
            if (action != .delete and data != .object) return error.NotObject;
            const rctx = api.buildContext(ctx, conn, if (action == .delete) null else data);
            const identity = rctx.auth orelse return error.Unauthorized;
            const auth_col = (try collections.get(a, conn, rctx.collection)) orelse return error.Unauthorized;
            defer auth_col.deinit(a);
            const rid = ctx.param("id") orelse "";
            const payload = try std.json.Stringify.valueAlloc(a, .{ .collection = col, .target = rid, .account = rctx.account_id, .body = ctx.body }, .{});
            var s: State = .{ .ctx = ctx, .col = col, .rctx = rctx, .auth_collection_id = auth_col.id, .action = action, .rid = rid, .data = data };
            const result = Ledger.execute(a, conn, .{
                .principal = .{ .collection = auth_col.id, .record = identity.object.get("id").?.string },
                .operation = try std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ @tagName(action), col.id, rid }),
                .key = ctx.header("idempotency-key").?,
                .payload = payload,
                .now = std.Io.Timestamp.now(app.io, .real).toSeconds(),
            }, .{ .context = &s, .authorize = authorize, .mutate = mutate, .authorize_replay = authorizeReplay }) catch |err| {
                // A rollback failure must override an ordinary validation/conflict
                // response: this pool can no longer accept writes safely.
                app.pool.recoverWriter() catch {
                    records.last_errors = null;
                    return error.WriterUnavailable;
                };
                // Detail field names borrow col: render before its deferred deinit.
                if (err == error.Validation) return validationResponse(a);
                return err;
            };
            defer result.deinit(a);
            if (!result.replayed) {
                const event_id = if (action == .create) s.result.object.get("id").?.string else rid;
                switch (action) {
                    .create => realtime.broadcast(app, col, .create, event_id, s.result, null),
                    .update => realtime.broadcast(app, col, .update, event_id, s.result, null),
                    .delete => realtime.broadcast(app, col, .delete, event_id, s.result, s.delete_token),
                    else => unreachable,
                }
            }
            return .{ .status = if (action == .create) 201 else if (action == .delete) 204 else 200, .body = try a.dupe(u8, result.body()) };
        }
    };
}

/// Borrows request-owned validation details; owns only the returned response body.
/// Always discard the thread-local arena pointers, including on response OOM.
fn validationResponse(allocator: std.mem.Allocator) !http.Response {
    defer records.last_errors = null;
    const details = records.last_errors orelse &[_]schema.ValidationError{};
    const fields = try allocator.alloc(@import("api/error.zig").FieldError, details.len);
    defer allocator.free(fields);
    for (details, 0..) |detail, i| fields[i] = .{ .field = detail.field, .code = detail.code, .message = detail.message };
    return ApiError.validation(fields).toResponse(allocator);
}

test "REST validation details are consumed before the request arena expires" {
    const details = [_]schema.ValidationError{.{ .field = "title", .code = "required", .message = "Required." }};
    records.last_errors = &details;
    defer records.last_errors = null;
    const response = try validationResponse(std.testing.allocator);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 400), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "validation_failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "title") != null);
    try std.testing.expectEqual(null, records.last_errors);
    records.last_errors = &details;
    try std.testing.expectError(error.OutOfMemory, validationResponse(std.testing.failing_allocator));
    try std.testing.expectEqual(null, records.last_errors);
}
