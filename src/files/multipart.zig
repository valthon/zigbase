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
        // Tolerate LWSP around '=' (legal in MIME structured fields; HTTP
        // senders must not generate it, but accepting it is harmless).
        const eq = std.mem.indexOfScalar(u8, raw, '=') orelse continue;
        const attr = std.mem.trim(u8, raw[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(attr, "boundary")) continue;
        var v = std.mem.trim(u8, raw[eq + 1 ..], " \t");
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        if (v.len > 0) return v;
    }
    return null;
}

const Disposition = struct { name: ?[]const u8 = null, filename: ?[]const u8 = null };

/// Parse a Content-Disposition header value such as
/// `form-data; name="title"; filename="a.jpg"` in ONE pass, extracting only
/// `name` and `filename`. Quoted values support backslash escapes; values are
/// borrowed from `header` unless unescaping forces a copy. A `;`-separated
/// segment without '=' is a valueless flag param and is skipped. Params we
/// don't care about are scanned past without allocating.
fn parseDisposition(alloc: std.mem.Allocator, header: []const u8) std.mem.Allocator.Error!Disposition {
    var out = Disposition{};
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, header, i, ';')) |semi| {
        var j = semi + 1;
        while (j < header.len and (header[j] == ' ' or header[j] == '\t')) j += 1;
        // Param name ends at '=' — bounded by the current segment: a ';' first
        // means this segment is a valueless flag param (e.g. "form-data; x; ...").
        var k = j;
        while (k < header.len and header[k] != '=' and header[k] != ';') k += 1;
        if (k >= header.len or header[k] == ';') {
            i = k;
            continue;
        }
        const pname = std.mem.trim(u8, header[j..k], " \t");
        const slot: ?*?[]const u8 = if (std.ascii.eqlIgnoreCase(pname, "name"))
            &out.name
        else if (std.ascii.eqlIgnoreCase(pname, "filename"))
            &out.filename
        else
            null;
        k += 1; // past '='
        if (k < header.len and header[k] == '"') {
            k += 1;
            const vstart = k;
            var escaped = false;
            while (k < header.len and header[k] != '"') : (k += 1) {
                if (header[k] == '\\' and k + 1 < header.len) {
                    k += 1;
                    escaped = true;
                }
            }
            if (slot) |s| {
                if (!escaped) {
                    s.* = header[vstart..k]; // borrow; no allocation
                } else {
                    var buf: std.ArrayList(u8) = .empty;
                    var m = vstart;
                    while (m < k) : (m += 1) {
                        if (header[m] == '\\' and m + 1 < k) m += 1;
                        try buf.append(alloc, header[m]);
                    }
                    s.* = try buf.toOwnedSlice(alloc);
                }
            }
            i = if (k < header.len) k + 1 else k; // past the closing quote
        } else {
            const end = std.mem.indexOfScalarPos(u8, header, k, ';') orelse header.len;
            if (slot) |s| s.* = std.mem.trim(u8, header[k..end], " \t");
            i = end;
        }
    }
    return out;
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
    const disp = try parseDisposition(alloc, d);
    const raw_name = disp.name orelse return;
    // PHP/jQuery convention (matched by the old facil.io path, which stripped it):
    // "photos[]" keys the same field as "photos".
    const name = if (std.mem.endsWith(u8, raw_name, "[]")) raw_name[0 .. raw_name.len - 2] else raw_name;
    if (disp.filename) |fname| {
        // Zero-byte file parts are dropped: browsers send filename="" with no bytes
        // for an empty file input, and the old fio path skipped all null-data
        // binfiles — a 0-byte part must never replace a stored file.
        if (content.len == 0) return;
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
const Delim = struct { start: usize, after: usize, kind: enum { open, close } };

/// Validate the bytes following "--<boundary>" at `end` per RFC 2046: "--" closes
/// the multipart; otherwise only optional SP/HT transport padding may precede the
/// CRLF that ends the delimiter line. Anything else means the match was content.
fn checkDelimTail(body: []const u8, start: usize, end: usize) ?Delim {
    if (end + 2 <= body.len and body[end] == '-' and body[end + 1] == '-')
        return .{ .start = start, .after = end + 2, .kind = .close };
    var k = end;
    while (k < body.len and (body[k] == ' ' or body[k] == '\t')) k += 1;
    if (k + 2 <= body.len and body[k] == '\r' and body[k + 1] == '\n')
        return .{ .start = start, .after = k + 2, .kind = .open };
    return null;
}

/// Find the next true delimiter ("\r\n--<boundary>" with a valid tail) at or after
/// `from`. A bare prefix match (e.g. "\r\n--XBOUNDZ" for boundary XBOUND) is body
/// content: keep searching from the next byte.
fn nextDelimiter(body: []const u8, delim: []const u8, from: usize) ?Delim {
    var i = from;
    while (std.mem.indexOfPos(u8, body, i, delim)) |cand| {
        if (checkDelimTail(body, cand, cand + delim.len)) |d| return d;
        i = cand + 1;
    }
    return null;
}

/// DoS cap (F9): the maximum number of parts a single multipart body may contain.
/// A 50 MiB body (the global upload cap) of many tiny parts would otherwise force
/// thousands of map insertions / file structs; 1024 parts is far above any real form
/// (typical uploads are a handful of fields + a few files) yet bounds the worst case.
pub const max_parts = 1024;

/// Field values and file bytes borrow from `body`; names are duped into `alloc`.
pub fn parse(alloc: std.mem.Allocator, content_type: []const u8, body: []const u8) ParseError!Extracted {
    var fields: std.json.ObjectMap = .empty;
    var files: std.ArrayList(http.UploadedFile) = .empty;

    const boundary = boundaryFromContentType(content_type) orelse return error.BadMultipart;
    const dash_boundary = try std.fmt.allocPrint(alloc, "--{s}", .{boundary});
    const delim = try std.fmt.allocPrint(alloc, "\r\n--{s}", .{boundary});

    // First delimiter: "--<boundary>" at the very start of the body, else a full
    // "\r\n--<boundary>" after a preamble — both with a valid RFC 2046 tail.
    var cur: Delim = blk: {
        if (std.mem.startsWith(u8, body, dash_boundary)) {
            if (checkDelimTail(body, 0, dash_boundary.len)) |d| break :blk d;
        }
        break :blk nextDelimiter(body, delim, 0) orelse return error.BadMultipart;
    };
    var part_count: usize = 0;
    while (cur.kind == .open) {
        part_count += 1;
        // DoS cap: refuse a body with an absurd number of parts (F9). Treated as a
        // malformed/abusive body rather than silently truncating it.
        if (part_count > max_parts) return error.BadMultipart;
        const hdr_start = cur.after;
        const hdr_end = std.mem.indexOfPos(u8, body, hdr_start, "\r\n\r\n") orelse return error.BadMultipart;
        const content_start = hdr_end + 4;
        // An empty part shares its CRLF with the header terminator, so the next
        // delimiter may begin at hdr_end + 2.
        const next = nextDelimiter(body, delim, hdr_end + 2) orelse return error.BadMultipart;
        const content = if (next.start < content_start) "" else body[content_start..next.start];
        try handlePart(alloc, &fields, &files, body[hdr_start..hdr_end], content);
        cur = next;
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

test "parse: whitespace around '=' in the boundary parameter is tolerated" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--bnd\r\n" ++
        "Content-Disposition: form-data; name=\"x\"\r\n\r\nv\r\n" ++
        "--bnd--\r\n";
    // MIME-origin clients may emit LWSP around '=' (RFC 822 structured fields);
    // HTTP senders must not generate it (RFC 9110) but tolerating it is harmless.
    for ([_][]const u8{
        "multipart/form-data; boundary = bnd",
        "multipart/form-data; boundary= bnd",
        "multipart/form-data; boundary =\"bnd\"",
        "multipart/form-data; charset=utf-8; boundary = bnd",
    }) |hdr| {
        const ex = try parse(a, hdr, body);
        try t.expectEqualStrings("v", ex.form_fields.object.get("x").?.string);
    }
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

test "parse: a boundary-prefixed decoy inside content is content, not a delimiter" {
    // RFC 2046: a delimiter is "\r\n--<boundary>" followed by "--" or by optional
    // SP/HT padding and CRLF. "\r\n--XBOUNDZ..." (boundary XBOUND) is body bytes.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const smuggled = "AA\r\n--XBOUNDZ\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nBB";
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n\r\n" ++ smuggled ++ "\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqualStrings(smuggled, ex.form_fields.object.get("a").?.string);
    try t.expect(ex.form_fields.object.get("b") == null); // nothing smuggled in
    try t.expectEqual(@as(usize, 1), ex.form_fields.object.count());
}

test "parse: only SP/HT transport padding is allowed before the delimiter CRLF" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // legit padding after the boundary line is accepted
    const padded = "--XBOUND  \t\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n\r\nv\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, padded);
    try t.expectEqualStrings("v", ex.form_fields.object.get("a").?.string);
    // a non-padding byte after "--XBOUND" inside content means it is NOT a delimiter
    const decoy_pad = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--XBOUND junk\r\nmore\r\n" ++
        "--XBOUND--\r\n";
    const ex2 = try parseBody(a, decoy_pad);
    try t.expectEqualStrings("x\r\n--XBOUND junk\r\nmore", ex2.form_fields.object.get("a").?.string);
}

test "parse: empty part content yields an empty string" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n\r\n\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqualStrings("", ex.form_fields.object.get("a").?.string);
}

test "parse: a valueless flag param in the disposition does not eat the name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; x; name=\"title\"\r\n\r\nv1\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"other\"; flag\r\n\r\nv2\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; decoy=\"a\\\"long;decoy\"; name=\"third\"\r\n\r\nv3\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqualStrings("v1", ex.form_fields.object.get("title").?.string);
    try t.expectEqualStrings("v2", ex.form_fields.object.get("other").?.string);
    try t.expectEqualStrings("v3", ex.form_fields.object.get("third").?.string);
}

test "parse: a zero-byte file part with a real filename is skipped (matches old fio behavior)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"photos\"; filename=\"photo.jpg\"\r\n" ++
        "Content-Type: image/jpeg\r\n\r\n\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqual(@as(usize, 0), ex.files.len);
    try t.expect(ex.form_fields.object.get("photos") == null);
}

test "parse: trailing '[]' (PHP/jQuery convention) is stripped from part names" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"photos[]\"; filename=\"a.jpg\"\r\n" ++
        "Content-Type: image/jpeg\r\n\r\nAA\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"photos[]\"; filename=\"b.jpg\"\r\n" ++
        "Content-Type: image/jpeg\r\n\r\nBB\r\n" ++
        "--XBOUND\r\n" ++
        "Content-Disposition: form-data; name=\"tags[]\"\r\n\r\nx\r\n" ++
        "--XBOUND--\r\n";
    const ex = try parseBody(a, body);
    try t.expectEqual(@as(usize, 2), ex.files.len);
    try t.expectEqualStrings("photos", ex.files[0].field);
    try t.expectEqualStrings("photos", ex.files[1].field);
    try t.expectEqualStrings("x", ex.form_fields.object.get("tags").?.string);
    try t.expect(ex.form_fields.object.get("tags[]") == null);
}

test "parse: a body exceeding the part-count cap is rejected (F9 DoS)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Build a body of (max_parts + 1) tiny parts.
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < max_parts + 1) : (i += 1) {
        try buf.appendSlice(a, "--XBOUND\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nx\r\n");
    }
    try buf.appendSlice(a, "--XBOUND--\r\n");
    try t.expectError(error.BadMultipart, parseBody(a, buf.items));

    // A body exactly at the cap parses fine (repeated key -> array of max_parts items).
    var ok: std.ArrayList(u8) = .empty;
    i = 0;
    while (i < max_parts) : (i += 1) {
        try ok.appendSlice(a, "--XBOUND\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nx\r\n");
    }
    try ok.appendSlice(a, "--XBOUND--\r\n");
    const ex = try parseBody(a, ok.items);
    try t.expectEqual(@as(usize, max_parts), ex.form_fields.object.get("f").?.array.items.len);
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
