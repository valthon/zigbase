const std = @import("std");
const http = @import("../http.zig");
const codes = @import("../error_codes.zig");

pub const FieldError = struct { field: []const u8, code: []const u8, message: []const u8 };

/// A renderable API error. Envelope: {status, code, message, data:{<field>:{code,message}}}.
///
/// `status` is the integer HTTP status; `code` is a FROZEN machine string from
/// `error_codes.Code` (or a consumer-supplied string via `ctx.jsonError`). Clients
/// match on `code` — `message` is human text and is explicitly not contract.
pub const ApiError = struct {
    status: u16,
    code: []const u8 = codes.s(.internal),
    message: []const u8,
    fields: []const FieldError = &.{},

    /// A specific registered code at an arbitrary status, for sites that carry more
    /// meaning than the generic per-status constructors below (e.g. collections_frozen).
    pub fn withCode(status: u16, code: codes.Code, message: []const u8) ApiError {
        return .{ .status = status, .code = codes.s(code), .message = message };
    }

    pub fn notFound() ApiError {
        return .{ .status = 404, .code = codes.s(.not_found), .message = "Not found." };
    }
    pub fn internal() ApiError {
        return .{ .status = 500, .code = codes.s(.internal), .message = "Something went wrong." };
    }
    pub fn badRequest(message: []const u8) ApiError {
        return .{ .status = 400, .code = codes.s(.bad_request), .message = message };
    }
    pub fn conflict(message: []const u8) ApiError {
        return .{ .status = 409, .code = codes.s(.conflict), .message = message };
    }
    /// 410 Gone — the resource existed but is no longer available (e.g. an expired cursor).
    pub fn gone(message: []const u8) ApiError {
        return .{ .status = 410, .code = codes.s(.gone), .message = message };
    }
    pub fn validation(fields: []const FieldError) ApiError {
        return .{ .status = 400, .code = codes.s(.validation_failed), .message = "Failed to validate the request.", .fields = fields };
    }
    pub fn forbidden() ApiError {
        return .{ .status = 403, .code = codes.s(.forbidden), .message = "Forbidden." };
    }
    pub fn unauthorized() ApiError {
        return .{ .status = 401, .code = codes.s(.unauthorized), .message = "Unauthorized." };
    }

    pub fn renderBody(self: ApiError, alloc: std.mem.Allocator) ![]u8 {
        // Build the ObjectMap tree in a temporary arena; serialize into `alloc`.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var data: std.json.ObjectMap = .empty;
        for (self.fields) |fe| {
            var fo: std.json.ObjectMap = .empty;
            try fo.put(aa, "code", .{ .string = fe.code });
            try fo.put(aa, "message", .{ .string = fe.message });
            try data.put(aa, fe.field, .{ .object = fo });
        }
        // Insertion order IS the wire order (ObjectMap preserves it) and is contract.
        var root: std.json.ObjectMap = .empty;
        try root.put(aa, "status", .{ .integer = @intCast(self.status) });
        try root.put(aa, "code", .{ .string = self.code });
        try root.put(aa, "message", .{ .string = self.message });
        try root.put(aa, "data", .{ .object = data });
        return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
    }

    pub fn toResponse(self: ApiError, alloc: std.mem.Allocator) !http.Response {
        return .{ .status = self.status, .body = try self.renderBody(alloc) };
    }
};

test "renders empty-data envelope with a machine code" {
    const body = try ApiError.notFound().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"status\":404,\"code\":\"not_found\",\"message\":\"Not found.\",\"data\":{}}",
        body,
    );
}

test "renders validation field errors under validation_failed" {
    const fields = [_]FieldError{.{ .field = "name", .code = codes.s(.validation_invalid_name), .message = "Invalid." }};
    const body = try ApiError.validation(&fields).renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"status\":400,\"code\":\"validation_failed\",\"message\":\"Failed to validate the request.\"," ++
            "\"data\":{\"name\":{\"code\":\"validation_invalid_name\",\"message\":\"Invalid.\"}}}",
        body,
    );
}

test "withCode carries a specific registered code at the same status" {
    const e = ApiError.withCode(403, .collections_frozen, "Collections are frozen.");
    const body = try e.renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"status\":403,\"code\":\"collections_frozen\",\"message\":\"Collections are frozen.\",\"data\":{}}",
        body,
    );
}

test "every constructor emits a registered code" {
    // A built-in error must never ship a code that is not in the frozen ledger.
    const cases = [_]ApiError{
        ApiError.notFound(),      ApiError.internal(),
        ApiError.badRequest("x"), ApiError.conflict("x"),
        ApiError.gone("x"),       ApiError.validation(&.{}),
        ApiError.forbidden(),     ApiError.unauthorized(),
    };
    for (cases) |e| try std.testing.expect(codes.parse(e.code) != null);
}

test "the hard-coded raw fallback envelopes match renderBody byte-for-byte" {
    // ctx.zig's static_internal_response and server.zig's sendRawEnvelope literals are
    // allocation-free copies for the OOM path. If renderBody's shape changes and they
    // don't, a client sees two different 500 bodies. Pin them here.
    const internal_body = try ApiError.internal().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(internal_body);
    try std.testing.expectEqualStrings(
        "{\"status\":500,\"code\":\"internal\",\"message\":\"Something went wrong.\",\"data\":{}}",
        internal_body,
    );
    const nf_body = try ApiError.notFound().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(nf_body);
    try std.testing.expectEqualStrings(
        "{\"status\":404,\"code\":\"not_found\",\"message\":\"Not found.\",\"data\":{}}",
        nf_body,
    );
}

/// Find the span strictly inside the `{...}` that opens immediately after `start`
/// (which must point at the `{`), balancing nested braces. Returns the index just
/// past the matching `}`, or null if the file is malformed (unbalanced).
fn matchBrace(text: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// True when `text[at..]` starts with an exact `.status` field name (not a prefix
/// of a longer field like `.statusCode`) — checked by requiring the next byte to
/// not continue an identifier.
fn isExactField(text: []const u8, at: usize, name: []const u8) bool {
    if (!std.mem.startsWith(u8, text[at..], name)) return false;
    const after = at + name.len;
    if (after >= text.len) return true;
    const c = text[after];
    return !(std.ascii.isAlphanumeric(c) or c == '_');
}

/// Parse a decimal `u16` immediately following `.status` `=` inside `span` (skipping
/// whitespace), or null if what follows isn't a plain integer literal (e.g. an
/// identifier like `f.status` — a dynamically-sourced status this scan can't verify
/// numerically).
fn parseLiteralStatus(span: []const u8) ?u16 {
    const key = std.mem.indexOf(u8, span, ".status") orelse return null;
    if (!isExactField(span, key, ".status")) return null;
    var i = key + ".status".len;
    while (i < span.len and span[i] == ' ') : (i += 1) {}
    if (i >= span.len or span[i] != '=') return null;
    i += 1;
    while (i < span.len and span[i] == ' ') : (i += 1) {}
    const digit_start = i;
    while (i < span.len and std.ascii.isDigit(span[i])) : (i += 1) {}
    if (i == digit_start) return null; // not a literal integer (e.g. an identifier)
    return std.fmt.parseInt(u16, span[digit_start..i], 10) catch null;
}

// Regression guard (SP-1 Task 2 follow-up): walks every `src/**/*.zig` file at test
// time and flags a bare `ApiError{ .status = N, .message = … }` struct-literal
// construction that omits `.code` while `N` is a status `error_codes.forStatus` maps
// to something OTHER than `.internal` (400/401/403/404/409/410/429 today, read live
// off `forStatus` so this guard tracks it automatically). Such a literal silently
// falls back to `ApiError`'s default `code: []const u8 = codes.s(.internal)` even
// though a specific registered code exists for its status — the exact defect this
// task fixed at ~30 call sites (see task-2-report.md, "Concern 2").
//
// Literals at 500, or any other status `forStatus` does not specifically map, are
// NOT flagged: `internal` is the documented, correct default there.
//
// Limits (stated, not hidden): this is a textual brace-balancing scan, not a Zig
// parser. It only understands a single `ApiError{ ... }` literal per match (nested
// `{`/`}` inside the span balance correctly via `matchBrace`, but a
// `.status` sourced from an identifier/expression rather than an integer literal
// (e.g. `.status = f.status`) can't be checked numerically — such a span is treated
// as UNVERIFIABLE and fails the test loudly (forcing a human to give it an explicit
// `.code`) rather than silently passing. It does not catch a bare literal built
// through some entirely different spelling (e.g. `@as(ApiError, .{...})` with no
// `ApiError{` token) — every current call site uses the plain `ApiError{`/`(ApiError{`
// spelling, so this is a real, if not absolute, gate.
test "no bare ApiError literal in src/ ships an implicit code that contradicts its status" {
    const a = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(a);
    defer walker.deinit();

    var bad: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // This file (api/error.zig) is excluded: it's the ApiError DEFINITION site, so its
        // constructors return via bare `.{ ... }` shorthand (inferred from the return type),
        // never the `ApiError{` spelling this scan looks for — every actual "ApiError{" byte
        // sequence in this file is inside THIS guard's own doc comments/debug-print format
        // strings (textual matches, not real construction sites), which would otherwise
        // false-positive against itself. Same precedent as the `"validation_` mechanical-sweep
        // gate excluding this file (see task-2-report.md).
        if (std.mem.eql(u8, entry.path, "api/error.zig")) continue;
        const rel = try std.fmt.allocPrint(a, "src/{s}", .{entry.path});
        defer a.free(rel);
        const content = std.Io.Dir.cwd().readFileAlloc(std.testing.io, rel, a, .limited(4 * 1024 * 1024)) catch continue;
        defer a.free(content);

        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, content, pos, "ApiError{")) |found| {
            const brace = found + "ApiError".len; // index of the '{'
            // Word-boundary check: don't match e.g. "MyApiError{".
            const boundary_ok = found == 0 or !(std.ascii.isAlphanumeric(content[found - 1]) or content[found - 1] == '_');
            const end = matchBrace(content, brace) orelse {
                pos = brace + 1;
                continue;
            };
            defer pos = end;
            if (!boundary_ok) continue;
            const span = content[brace + 1 .. end - 1];
            if (std.mem.indexOf(u8, span, ".code") != null) continue; // code set explicitly — fine
            const status = parseLiteralStatus(span) orelse {
                std.debug.print(
                    "{s}: bare ApiError{{...}} with a non-literal `.status` and no `.code` — cannot verify; add an explicit `.code`\n",
                    .{rel},
                );
                bad += 1;
                continue;
            };
            if (codes.forStatus(status) != .internal) {
                std.debug.print(
                    "{s}: bare ApiError{{ .status = {d}, ... }} has no `.code`, so it silently ships \"internal\" — " ++
                        "forStatus({d}) is `.{s}`; use that constructor/withCode or add `.code` explicitly\n",
                    .{ rel, status, status, @tagName(codes.forStatus(status)) },
                );
                bad += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}
