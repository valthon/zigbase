const std = @import("std");
const http = @import("../http.zig");

pub const Extracted = struct { form_fields: std.json.Value, files: []const http.UploadedFile };

pub const ParseError = error{BadMultipart} || std.mem.Allocator.Error;

/// Extract the boundary token from a `multipart/form-data; boundary=...` content-type.
/// Accepts an optionally quoted value; the parameter name is case-insensitive.
fn boundaryFromContentType(ct_header: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, ct_header, ';');
    _ = it.next(); // skip the media type itself
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len > 9 and std.ascii.eqlIgnoreCase(p[0..9], "boundary=")) {
            var v = p[9..];
            if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
            if (v.len > 0) return v;
        }
    }
    return null;
}

/// Extract a parameter value (`name` / `filename`) from a Content-Disposition
/// header value such as `form-data; name="title"; filename="a.jpg"`.
/// Handles quoted values (with backslash escapes) and bare tokens.
fn dispositionParam(alloc: std.mem.Allocator, header: []const u8, key: []const u8) std.mem.Allocator.Error!?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, header, i, ';')) |semi| {
        var j = semi + 1;
        while (j < header.len and (header[j] == ' ' or header[j] == '\t')) j += 1;
        const eq = std.mem.indexOfScalarPos(u8, header, j, '=') orelse return null;
        const pname = std.mem.trim(u8, header[j..eq], " \t");
        const matched = std.ascii.eqlIgnoreCase(pname, key);
        var k = eq + 1;
        if (k < header.len and header[k] == '"') {
            k += 1;
            var out: std.ArrayList(u8) = .empty;
            while (k < header.len and header[k] != '"') : (k += 1) {
                if (header[k] == '\\' and k + 1 < header.len) k += 1;
                try out.append(alloc, header[k]);
            }
            if (matched) return try out.toOwnedSlice(alloc);
            i = k; // resume the ';' scan after the closing quote
        } else {
            const end = std.mem.indexOfScalarPos(u8, header, k, ';') orelse header.len;
            if (matched) return try alloc.dupe(u8, std.mem.trim(u8, header[k..end], " \t"));
            i = end;
        }
    }
    return null;
}

/// Record one parsed part. A part with a `filename` disposition parameter is a file
/// (that is the discriminator browsers/curl use; text fields never carry one);
/// everything else is a form field whose value is kept as a verbatim string.
/// A repeated non-file key promotes the value to a JSON array of strings.
fn handlePart(
    alloc: std.mem.Allocator,
    fields: *std.json.ObjectMap,
    files: *std.ArrayList(http.UploadedFile),
    headers: []const u8,
    content: []const u8,
) ParseError!void {
    var disposition: ?[]const u8 = null;
    var part_ct: []const u8 = "";
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..colon], " \t");
        const hval = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(hname, "content-disposition")) {
            disposition = hval;
        } else if (std.ascii.eqlIgnoreCase(hname, "content-type")) {
            part_ct = hval;
        }
    }
    const d = disposition orelse return; // a part without a disposition carries no name; skip
    const name = (try dispositionParam(alloc, d, "name")) orelse return;
    if (try dispositionParam(alloc, d, "filename")) |fname| {
        // `filename=""` with no bytes is the browser's "no file chosen" sentinel.
        if (fname.len == 0 and content.len == 0) return;
        try files.append(alloc, .{
            .field = name,
            .filename = if (fname.len == 0) "file" else fname,
            .mimetype = part_ct,
            .bytes = content,
        });
        return;
    }
    const gop = try fields.getOrPut(alloc, name);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .string = content };
        return;
    }
    switch (gop.value_ptr.*) {
        .array => |*arr| try arr.append(.{ .string = content }),
        else => {
            var arr = std.json.Array.init(alloc);
            try arr.append(gop.value_ptr.*);
            try arr.append(.{ .string = content });
            gop.value_ptr.* = .{ .array = arr };
        },
    }
}

/// Parse a raw multipart/form-data body into neutral form fields + uploaded files.
///
/// This deliberately does NOT use facil.io's parsed params: fio type-guesses each
/// value at HTTP parse time (text "123" -> int 123, "true" -> bool, "45.00" -> float),
/// which destroys information ("007" -> 7) and breaks schema validation for fields
/// whose canonical JSON form is a string. Every non-file field value here is the
/// exact bytes the client sent. Schema-aware coercion happens later, in the records
/// layer, where the collection schema is known.
///
/// Field values and file bytes borrow from `body`; names are duped into `alloc`.
pub fn parse(alloc: std.mem.Allocator, content_type: []const u8, body: []const u8) ParseError!Extracted {
    var fields: std.json.ObjectMap = .empty;
    var files: std.ArrayList(http.UploadedFile) = .empty;

    const boundary = boundaryFromContentType(content_type) orelse return error.BadMultipart;
    const dash_boundary = try std.fmt.allocPrint(alloc, "--{s}", .{boundary});
    const delim = try std.fmt.allocPrint(alloc, "\r\n--{s}", .{boundary});

    // First delimiter: at the very start of the body (or after a preamble).
    var pos = (std.mem.indexOf(u8, body, dash_boundary) orelse return error.BadMultipart) + dash_boundary.len;
    while (true) {
        if (pos + 2 <= body.len and std.mem.eql(u8, body[pos .. pos + 2], "--")) break; // closing "--boundary--"
        // Skip optional transport padding up to the CRLF that ends the delimiter line.
        const hdr_start = (std.mem.indexOfPos(u8, body, pos, "\r\n") orelse return error.BadMultipart) + 2;
        const hdr_end = std.mem.indexOfPos(u8, body, hdr_start, "\r\n\r\n") orelse return error.BadMultipart;
        const content_start = hdr_end + 4;
        const next = std.mem.indexOfPos(u8, body, content_start, delim) orelse return error.BadMultipart;
        try handlePart(alloc, &fields, &files, body[hdr_start..hdr_end], body[content_start..next]);
        pos = next + delim.len;
    }
    return .{ .form_fields = .{ .object = fields }, .files = try files.toOwnedSlice(alloc) };
}

// ---------------------------------------------------------------------------
// Tests for the hand-rolled parser (`parse`). Written first (TDD): facil.io
// type-guesses multipart params, so "123"/"true"/"45.00" arrived as JSON
// numbers/bools and failed validation for text / int / fixed-mode fields.
// ---------------------------------------------------------------------------

const t = std.testing;

const ct = "multipart/form-data; boundary=XBOUND";

fn parseBody(a: std.mem.Allocator, body: []const u8) !Extracted {
    return parse(a, ct, body);
}

test "parse: scalar-looking text values stay verbatim strings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\nb\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"n1\"\r\n\r\n123\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"b1\"\r\n\r\ntrue\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"b2\"\r\n\r\nfalse\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"agent\"\r\n\r\n007\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"phone\"\r\n\r\n+15551234\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    const f = ex.form_fields.object;
    try t.expectEqualStrings("b", f.get("title").?.string);
    try t.expectEqualStrings("123", f.get("n1").?.string);
    try t.expectEqualStrings("true", f.get("b1").?.string);
    try t.expectEqualStrings("false", f.get("b2").?.string);
    try t.expectEqualStrings("007", f.get("agent").?.string);
    try t.expectEqualStrings("+15551234", f.get("phone").?.string);
    try t.expectEqual(@as(usize, 0), ex.files.len);
}

test "parse: decimal field + file part in the same request" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"price\"\r\n\r\n45.00\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"photos\"; filename=\"x.jpg\"\r\n" ++
        "Content-Type: image/jpeg\r\n\r\n\xff\xd8JPGDATA\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqualStrings("45.00", ex.form_fields.object.get("price").?.string);
    try t.expectEqual(@as(usize, 1), ex.files.len);
    try t.expectEqualStrings("photos", ex.files[0].field);
    try t.expectEqualStrings("x.jpg", ex.files[0].filename);
    try t.expectEqualStrings("image/jpeg", ex.files[0].mimetype);
    try t.expectEqualStrings("\xff\xd8JPGDATA", ex.files[0].bytes);
}

test "parse: repeated file key yields multiple files (multi-file upload)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"docs\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\nAAA\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"docs\"; filename=\"b.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\nBBB\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqual(@as(usize, 2), ex.files.len);
    try t.expectEqualStrings("a.txt", ex.files[0].filename);
    try t.expectEqualStrings("AAA", ex.files[0].bytes);
    try t.expectEqualStrings("b.txt", ex.files[1].filename);
    try t.expectEqualStrings("BBB", ex.files[1].bytes);
}

test "parse: '<field>-' removal key passes through verbatim (JSON-array string)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"photos-\"\r\n\r\n[\"old.jpg\"]\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqualStrings("[\"old.jpg\"]", ex.form_fields.object.get("photos-").?.string);
}

test "parse: unicode field value survives byte-for-byte" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\nh\xc3\xa9llo \xf0\x9f\x8c\x8d\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqualStrings("héllo 🌍", ex.form_fields.object.get("title").?.string);
}

test "parse: value containing CRLF and quotes survives" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"body\"\r\n\r\nline1\r\nline2 \"quoted\"\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqualStrings("line1\r\nline2 \"quoted\"", ex.form_fields.object.get("body").?.string);
}

test "parse: quoted boundary in the content-type header" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--q1=z\r\n" ++
        "Content-Disposition: form-data; name=\"x\"\r\n\r\nv\r\n" ++
        "--q1=z--\r\n";
    const ex = try parse(a, "multipart/form-data; boundary=\"q1=z\"", body);
    try t.expectEqualStrings("v", ex.form_fields.object.get("x").?.string);
}

test "parse: empty-filename empty-content file part is skipped (no file chosen)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"photos\"; filename=\"\"\r\n" ++
        "Content-Type: application/octet-stream\r\n\r\n\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqual(@as(usize, 0), ex.files.len);
    try t.expect(ex.form_fields.object.get("photos") == null);
}

test "parse: repeated non-file key promotes to an array of strings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"tags\"\r\n\r\nx\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"tags\"\r\n\r\ny\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    const v = ex.form_fields.object.get("tags").?;
    try t.expect(v == .array);
    try t.expectEqual(@as(usize, 2), v.array.items.len);
    try t.expectEqualStrings("x", v.array.items[0].string);
    try t.expectEqualStrings("y", v.array.items[1].string);
}

test "parse: missing boundary or malformed body errors" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.BadMultipart, parse(a, "multipart/form-data", "--x\r\n"));
    try t.expectError(error.BadMultipart, parseBody(a, "no delimiter here"));
    // part started but never terminated
    try t.expectError(error.BadMultipart, parseBody(a, "--XBOUND\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv"));
}

test "parse: final terminator without trailing CRLF is accepted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n\r\nv\r\n" ++
        "--XBOUND--";
    const ex = try parseBody(a, body);
    try t.expectEqualStrings("v", ex.form_fields.object.get("a").?.string);
}
