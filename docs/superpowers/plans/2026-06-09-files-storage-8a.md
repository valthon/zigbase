# File Storage Core (Plan 8a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, unit-testable core of ZigBase file storage — filename sanitization/generation, server-side MIME sniffing, the `Storage` interface + a local-filesystem backend, and the `planFileField` add/remove/replace computation — plus the neutral request/response types, with no HTTP/zap glue yet.

**Architecture:** A new `src/files/` package: `naming.zig` (pure), `mime.zig` (pure sniffing), `storage.zig` (`Storage` vtable + `LocalStorage` over `std.Io.Dir`), and `plan.zig` (`planFileField` — the per-field upload computation reused by the create/update handlers in 8b). The neutral `UploadedFile`/`Header`/`Response.file_path` types land in `http.zig`. The multipart glue, endpoints, and wiring are Plan 8b.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 -- zig <args>` from repo root; bare `zig` is 0.15.2). `std.Io.Dir` filesystem, std.json, vendored SQLite (not needed in 8a). Reuses `schema.zig` (`FileOptions`), `id.zig` entropy.

**Build/test command:** `mise exec zig@0.16.0 -- zig build test --summary all`

**Branch:** Create and work on branch `files`. SP8 merges as a unit (8a+8b) after the holistic review at the end of 8b. Do NOT merge to `main` in this plan.

**Spec:** `docs/superpowers/specs/2026-06-09-files-design.md`.

---

## Verified facts (Zig 0.16.0 + current code — do not re-derive)

- **`std.Io.Dir` (compiles):** `var d = std.Io.Dir.cwd();` then `try d.createDirPath(io, path)`, `try d.writeFile(io, .{ .sub_path = path, .data = bytes })`, `const b = try d.readFileAlloc(io, path, alloc, .limited(max))`, `try d.deleteFile(io, path)`, `try d.deleteTree(io, path)`. (`io: std.Io`.)
- **`schema.zig`:** `FileOptions` is `file: struct { maxSelect: u32 = 1, maxSize: ?u64 = null, mimeTypes: ?[]const []const u8 = null }`. `Field{ id, name, required, unique, hidden, options }`; `field.options == .file` for file fields; `field.isMultiValue()` is `maxSelect > 1` for file. Access the file options as `field.options.file`.
- **`id.zig`:** `generate(io, out: []u8)` fills `out` with base36 chars (`io.random`).
- **`app.zig` `App`:** has `allocator, io, pool` + defaulted auth/realtime fields. Constructed in tests as `.{ .allocator, .io, .pool }` — any new field MUST be defaulted.
- **`http.zig`:** has `RequestCtx`, `Response{ status, content_type, body, cookies }`, `Cookie`, `SameSite`. We add `Header`, `UploadedFile`, and fields to `RequestCtx`/`Response`.
- **0.16 idioms:** `var l: std.ArrayList(T) = .empty; try l.append(alloc, x); try l.toOwnedSlice(alloc);`. `var o: std.json.ObjectMap = .empty;`. `std.json.Value` literals `.{ .string = s }`, `.{ .array = arr }`, `.null`. `std.fmt.allocPrint`. `std.ascii`. Build paths with `std.fs.path.join(alloc, &.{a,b,c})` (pure string join; works for our storage layout).
- **Test root:** `src/main.zig` `test { _ = @import("…"); }` — every new module must be added.

---

## File Structure

- **Create** `src/files/naming.zig` — `sanitizeBase`, `storedName`. Pure.
- **Create** `src/files/mime.zig` — `sniff(bytes) → []const u8`, `allowed(allowlist, sniffed) bool`. Pure.
- **Create** `src/files/storage.zig` — `Storage` vtable + `LocalStorage` (`init(root)`, `storage()` wrapper). Over `std.Io.Dir`.
- **Create** `src/files/plan.zig` — `PlannedWrite`, `FieldPlan`, `PlanError`, `planFileField`. Pure (reuses naming + mime).
- **Modify** `src/http.zig` — add `Header`, `UploadedFile`; add `content_type`/`form_fields`/`files` to `RequestCtx`; add `file_path`/`extra_headers` to `Response`.
- **Modify** `src/config.zig` / `src/app.zig` — `max_upload_size`, `file_token_ttl_s`; `App.storage: ?*const storage.Storage = null`.
- **Modify** `src/main.zig` — add the new modules to the test root.

---

### Task 0: Branch setup

- [ ] **Step 1**

```bash
cd /home/valthon/nothlav/zigbase
git checkout main
git checkout -b files
git status
```
Expected: on branch `files`, clean tree.

---

### Task 1: Filename sanitize + stored name (`files/naming.zig`)

**Files:** Create `src/files/naming.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Create `src/files/naming.zig` with the tests first**

```zig
const std = @import("std");
const id = @import("../id.zig");

test "sanitizeBase strips path components and unsafe chars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("passwd", try sanitizeBase(a, "../../etc/passwd"));
    try std.testing.expectEqualStrings("c.png", try sanitizeBase(a, "a/b/c.png"));
    try std.testing.expectEqualStrings("c.png", try sanitizeBase(a, "a\\b\\c.png"));
    try std.testing.expectEqualStrings("my_file.txt", try sanitizeBase(a, "my file.txt"));
    try std.testing.expectEqualStrings("file", try sanitizeBase(a, ".."));
    try std.testing.expectEqualStrings("file", try sanitizeBase(a, ""));
    try std.testing.expectEqualStrings("file", try sanitizeBase(a, "."));
    try std.testing.expectEqualStrings("a_b.c", try sanitizeBase(a, "a*b?.c")); // * and ? -> _
    // leading dot stripped (no hidden files)
    try std.testing.expectEqualStrings("bashrc", try sanitizeBase(a, ".bashrc"));
}

test "storedName keeps a sanitized stem + ext and adds a random suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n1 = try storedName(std.testing.io, a, "Photo Final.JPG");
    // shape: <stem>_<10 base36>.<ext-lowercased>
    try std.testing.expect(std.mem.startsWith(u8, n1, "Photo_Final_"));
    try std.testing.expect(std.mem.endsWith(u8, n1, ".jpg"));
    try std.testing.expect(std.mem.indexOfScalar(u8, n1, '/') == null);
    // two calls differ (random suffix)
    const n2 = try storedName(std.testing.io, a, "Photo Final.JPG");
    try std.testing.expect(!std.mem.eql(u8, n1, n2));
    // no extension
    const n3 = try storedName(std.testing.io, a, "README");
    try std.testing.expect(std.mem.startsWith(u8, n3, "README_"));
    try std.testing.expect(std.mem.indexOfScalar(u8, n3, '.') == null);
    // traversal can't survive
    const n4 = try storedName(std.testing.io, a, "../../x.png");
    try std.testing.expect(std.mem.indexOf(u8, n4, "..") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, n4, '/') == null);
}
```

Register in `src/main.zig` test root: add `_ = @import("files/naming.zig");`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `sanitizeBase`/`storedName` undefined.

- [ ] **Step 3: Implement — insert above the tests**

```zig
fn isSafe(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-';
}

/// The basename with unsafe characters replaced by `_`. Drops any path before the last `/` or `\`,
/// strips a leading `.` (no hidden files), and can never contain a path separator or `..`.
/// Empty / "." / ".." -> "file".
pub fn sanitizeBase(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    // basename: after the last '/' or '\'
    var base = name;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |i| base = base[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, base, '\\')) |i| base = base[i + 1 ..];
    // strip leading dots
    var start: usize = 0;
    while (start < base.len and base[start] == '.') start += 1;
    base = base[start..];
    if (base.len == 0) return alloc.dupe(u8, "file");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var prev_us = false;
    for (base) |ch| {
        if (isSafe(ch)) {
            try out.append(alloc, ch);
            prev_us = false;
        } else if (!prev_us) {
            try out.append(alloc, '_');
            prev_us = true;
        }
    }
    // trim trailing separators that turned to nothing meaningful
    const s = std.mem.trim(u8, out.items, "_");
    if (s.len == 0) return alloc.dupe(u8, "file");
    return alloc.dupe(u8, s);
}

/// "<stem>_<10 base36>.<ext>" where stem/ext come from the sanitized name (ext lowercased, <=16).
/// The random suffix guarantees uniqueness within a record dir and unguessability.
pub fn storedName(io: std.Io, alloc: std.mem.Allocator, original: []const u8) ![]const u8 {
    const clean = try sanitizeBase(alloc, original);
    var rand: [10]u8 = undefined;
    id.generate(io, &rand);
    // split stem/ext on the LAST dot (if any, and not the whole string)
    if (std.mem.lastIndexOfScalar(u8, clean, '.')) |dot| {
        if (dot > 0 and dot < clean.len - 1) {
            const stem = clean[0..dot];
            var ext_buf: [16]u8 = undefined;
            const raw_ext = clean[dot + 1 ..];
            const elen = @min(raw_ext.len, ext_buf.len);
            for (raw_ext[0..elen], 0..) |c, i| ext_buf[i] = std.ascii.toLower(c);
            return std.fmt.allocPrint(alloc, "{s}_{s}.{s}", .{ stem, rand, ext_buf[0..elen] });
        }
    }
    return std.fmt.allocPrint(alloc, "{s}_{s}", .{ clean, rand });
}
```

- [ ] **Step 4: Run + commit**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` → PASS.

```bash
git add src/files/naming.zig src/main.zig
git commit -m "feat(files): filename sanitize + stored-name generation"
```

---

### Task 2: MIME sniffing (`files/mime.zig`)

**Files:** Create `src/files/mime.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Create `src/files/mime.zig` with the tests first**

```zig
const std = @import("std");

test "sniff detects common types from magic bytes" {
    try std.testing.expectEqualStrings("image/png", sniff(&[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }));
    try std.testing.expectEqualStrings("image/jpeg", sniff(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 }));
    try std.testing.expectEqualStrings("image/gif", sniff("GIF89a....."));
    try std.testing.expectEqualStrings("application/pdf", sniff("%PDF-1.7"));
    try std.testing.expectEqualStrings("application/zip", sniff(&[_]u8{ 'P', 'K', 0x03, 0x04 }));
    try std.testing.expectEqualStrings("application/octet-stream", sniff("just some text"));
    try std.testing.expectEqualStrings("application/octet-stream", sniff("")); // empty safe
    try std.testing.expectEqualStrings("application/octet-stream", sniff("PK")); // truncated safe
}

test "allowed: null allowlist permits anything; otherwise membership" {
    try std.testing.expect(allowed(null, "image/png"));
    const list = [_][]const u8{ "image/png", "image/jpeg" };
    try std.testing.expect(allowed(&list, "image/png"));
    try std.testing.expect(!allowed(&list, "application/pdf"));
}
```

Register in `src/main.zig` test root: add `_ = @import("files/mime.zig");`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `sniff`/`allowed` undefined.

- [ ] **Step 3: Implement — insert above the tests**

```zig
const Sig = struct { magic: []const u8, mime: []const u8 };

const signatures = [_]Sig{
    .{ .magic = &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, .mime = "image/png" },
    .{ .magic = &[_]u8{ 0xFF, 0xD8, 0xFF }, .mime = "image/jpeg" },
    .{ .magic = "GIF87a", .mime = "image/gif" },
    .{ .magic = "GIF89a", .mime = "image/gif" },
    .{ .magic = "%PDF-", .mime = "application/pdf" },
    .{ .magic = &[_]u8{ 'P', 'K', 0x03, 0x04 }, .mime = "application/zip" },
    .{ .magic = &[_]u8{ 'P', 'K', 0x05, 0x06 }, .mime = "application/zip" },
};

/// Best-effort content type from leading magic bytes. Unknown/empty/truncated -> octet-stream.
pub fn sniff(bytes: []const u8) []const u8 {
    for (signatures) |s| {
        if (bytes.len >= s.magic.len and std.mem.eql(u8, bytes[0..s.magic.len], s.magic)) return s.mime;
    }
    // RIFF....WEBP
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP"))
        return "image/webp";
    return "application/octet-stream";
}

/// True if `allowlist` is null (unrestricted) or contains `sniffed`.
pub fn allowed(allowlist: ?[]const []const u8, sniffed: []const u8) bool {
    const list = allowlist orelse return true;
    for (list) |m| if (std.mem.eql(u8, m, sniffed)) return true;
    return false;
}
```

- [ ] **Step 4: Run + commit**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` → PASS.

```bash
git add src/files/mime.zig src/main.zig
git commit -m "feat(files): server-side MIME sniffing"
```

---

### Task 3: Neutral request/response types + config (`http.zig`, `config.zig`, `app.zig`)

**Files:** Modify `src/http.zig`, `src/config.zig`, `src/app.zig`, `src/main.zig`.

These are inert additions (defaults) that 8b consumes. The `App.storage` field references `files/storage.zig` (Task 4), so do Task 4 first OR forward-declare carefully — to avoid ordering issues, this task adds everything EXCEPT `App.storage` (added in Task 4 once `storage.zig` exists).

- [ ] **Step 1: Add types to `src/http.zig`**

Add (above `Response`):

```zig
pub const Header = struct { name: []const u8, value: []const u8 };

/// A file part from a multipart/form-data upload. `bytes` lives in the request arena.
pub const UploadedFile = struct {
    field: []const u8,
    filename: []const u8, // client-supplied original (untrusted)
    mimetype: []const u8, // client-supplied (untrusted; advisory)
    bytes: []const u8,
};
```

In `RequestCtx`, add (after the existing header fields):

```zig
    /// Request content-type (filled by server.zig). Multipart bodies populate form_fields/files.
    content_type: []const u8 = "",
    form_fields: ?std.json.Value = null,
    files: []const UploadedFile = &.{},
```

In `Response`, add (after `cookies`):

```zig
    /// When set, server.zig streams this filesystem path via sendFile instead of `body`.
    file_path: ?[]const u8 = null,
    extra_headers: []const Header = &.{},
```

- [ ] **Step 2: Add a trivial compile/usage test** (append to `src/http.zig` tests)

```zig
test "Response file_path and UploadedFile default/usage" {
    const r = Response{ .status = 200, .body = "", .file_path = "/x/y.png" };
    try std.testing.expectEqualStrings("/x/y.png", r.file_path.?);
    const u = UploadedFile{ .field = "cover", .filename = "a.png", .mimetype = "image/png", .bytes = "x" };
    try std.testing.expectEqualStrings("cover", u.field);
    var ctx = RequestCtx{ .method = .POST, .path = "/", .allocator = std.testing.allocator };
    try std.testing.expect(ctx.files.len == 0 and ctx.form_fields == null);
}
```

- [ ] **Step 3: Add config settings** to `src/config.zig` `Config` (after the realtime field):

```zig
    max_upload_size: u64 = 50 << 20, // 50 MiB per request body
    file_token_ttl_s: i64 = 120, // short-lived file-access token
```

In `Config.load`, add:

```zig
        if (getter("ZIGBASE_MAX_UPLOAD_SIZE")) |v| cfg.max_upload_size = try std.fmt.parseInt(u64, v, 10);
        if (getter("ZIGBASE_FILE_TOKEN_TTL")) |v| cfg.file_token_ttl_s = try std.fmt.parseInt(i64, v, 10);
```

In `src/app.zig` `App`, add defaulted fields:

```zig
    max_upload_size: u64 = 50 << 20,
    file_token_ttl_s: i64 = 120,
```

In `src/main.zig` `runServe`, add to the `App{…}` literal: `.max_upload_size = cfg.max_upload_size, .file_token_ttl_s = cfg.file_token_ttl_s,`.

- [ ] **Step 4: Run + commit**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` → PASS.

```bash
git add src/http.zig src/config.zig src/app.zig src/main.zig
git commit -m "feat(files): neutral upload/response types + upload config"
```

---

### Task 4: Storage interface + local backend (`files/storage.zig`)

**Files:** Create `src/files/storage.zig`; Modify `src/app.zig`, `src/main.zig`.

- [ ] **Step 1: Create `src/files/storage.zig` with the tests first**

```zig
const std = @import("std");

test "LocalStorage put/localPath/read/delete/deleteRecord round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);

    var local = LocalStorage.init(root);
    const st = local.storage();

    try st.put(std.testing.io, "posts", "rec1", "cover_ab12.png", "PNGDATA");
    const p = (try st.localPath(a, "posts", "rec1", "cover_ab12.png")).?;
    const back = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, a, .limited(1 << 20));
    try std.testing.expectEqualStrings("PNGDATA", back);

    try st.delete(std.testing.io, "posts", "rec1", "cover_ab12.png");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, a, .limited(16)));

    // deleteRecord removes the whole record dir
    try st.put(std.testing.io, "posts", "rec2", "a.txt", "A");
    try st.put(std.testing.io, "posts", "rec2", "b.txt", "B");
    try st.deleteRecord(std.testing.io, "posts", "rec2");
    const dir2 = (try st.localPath(a, "posts", "rec2", "a.txt")).?;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, dir2, a, .limited(16)));

    // deleting a missing file is a no-op (does not error)
    try st.delete(std.testing.io, "posts", "ghost", "none.txt");
}
```

Register in `src/main.zig` test root: add `_ = @import("files/storage.zig");`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `LocalStorage`/`Storage` undefined.

- [ ] **Step 3: Implement — insert above the tests**

```zig
/// Backend-agnostic blob storage for record files. `localPath` returns a filesystem path for
/// backends that have one (so server.zig can sendFile); non-local backends return null.
pub const Storage = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void,
        localPath: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8,
        delete: *const fn (ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void,
        deleteRecord: *const fn (ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void,
    };

    pub fn put(self: Storage, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void {
        return self.vtable.put(self.ctx, io, col, record_id, filename, bytes);
    }
    pub fn localPath(self: Storage, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8 {
        return self.vtable.localPath(self.ctx, alloc, col, record_id, filename);
    }
    pub fn delete(self: Storage, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void {
        return self.vtable.delete(self.ctx, io, col, record_id, filename);
    }
    pub fn deleteRecord(self: Storage, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void {
        return self.vtable.deleteRecord(self.ctx, io, col, record_id);
    }
};

/// Local filesystem backend rooted at `root` (absolute). Layout: <root>/<col>/<record_id>/<filename>.
/// `col`/`record_id` are validated identifiers/ids and `filename` is always a naming-sanitized stored
/// name, so no client string is ever a raw path component.
pub const LocalStorage = struct {
    root: []const u8,

    pub fn init(root: []const u8) LocalStorage {
        return .{ .root = root };
    }

    pub fn storage(self: *LocalStorage) Storage {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Storage.VTable{ .put = put, .localPath = localPath, .delete = delete, .deleteRecord = deleteRecord };

    fn dirPath(alloc: std.mem.Allocator, root: []const u8, col: []const u8, record_id: []const u8) ![]u8 {
        return std.fs.path.join(alloc, &.{ root, col, record_id });
    }

    fn put(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void {
        const self: *LocalStorage = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = fba.allocator();
        const dir = try dirPath(a, self.root, col, record_id);
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, dir);
        const path = try std.fs.path.join(a, &.{ dir, filename });
        try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    fn localPath(ctx: *anyopaque, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8 {
        const self: *LocalStorage = @ptrCast(@alignCast(ctx));
        return try std.fs.path.join(alloc, &.{ self.root, col, record_id, filename });
    }

    fn delete(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void {
        const self: *LocalStorage = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = fba.allocator();
        const path = try std.fs.path.join(a, &.{ self.root, col, record_id, filename });
        std.Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
            error.FileNotFound => {}, // missing -> no-op
            else => return e,
        };
    }

    fn deleteRecord(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void {
        const self: *LocalStorage = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = fba.allocator();
        const dir = try dirPath(a, self.root, col, record_id);
        std.Io.Dir.cwd().deleteTree(io, dir) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
};
```

Note: if `deleteTree`/`deleteFile` error sets in this std don't include `error.FileNotFound`, adjust the `switch` to the actual "not found" tag (read the std signature); the intent is "missing target is a no-op". If `std.fs.path.join` isn't the right namespace in 0.16, use the equivalent path-join (it's a pure string join of the parts with the OS separator).

- [ ] **Step 4: Add `App.storage`** — in `src/app.zig` `App`, add:

```zig
    storage: ?*const @import("files/storage.zig").Storage = null,
```

(Defaulted null; 8b constructs a `LocalStorage` in `runServe` and assigns its `.storage()`. Storing a `*const Storage` keeps `App` decoupled from `LocalStorage`.)

- [ ] **Step 5: Run + commit**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` → PASS.

```bash
git add src/files/storage.zig src/app.zig src/main.zig
git commit -m "feat(files): Storage interface + local filesystem backend"
```

---

### Task 5: File-field upload computation (`files/plan.zig`)

**Files:** Create `src/files/plan.zig`; Modify `src/main.zig`.

`planFileField` is the pure per-field decision: validate uploads, generate stored names, compute the new field value + the files to write + the files to delete, for create (existing=null) and update (add/remove/replace). The 8b handlers call it per file field and wire the result to `Storage` + `records`.

- [ ] **Step 1: Create `src/files/plan.zig` with the tests first**

```zig
const std = @import("std");
const schema = @import("../schema.zig");
const http = @import("../http.zig");

fn fileField(name: []const u8, max_select: u32, max_size: ?u64, mimes: ?[]const []const u8) schema.Field {
    return .{ .id = "f", .name = name, .options = .{ .file = .{ .maxSelect = max_select, .maxSize = max_size, .mimeTypes = mimes } } };
}
fn upload(field: []const u8, filename: []const u8, bytes: []const u8) http.UploadedFile {
    return .{ .field = field, .filename = filename, .mimetype = "application/octet-stream", .bytes = bytes };
}

test "create single: stores one file, value is the stored name string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("cover", 1, null, null);
    const ups = [_]http.UploadedFile{upload("cover", "pic.png", &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })};
    const plan = (try planFileField(std.testing.io, a, f, null, &ups, &.{}, true)).?;
    try std.testing.expect(plan.value == .string);
    try std.testing.expect(std.mem.endsWith(u8, plan.value.string, ".png"));
    try std.testing.expectEqual(@as(usize, 1), plan.writes.len);
    try std.testing.expectEqualStrings(plan.value.string, plan.writes[0].filename);
    try std.testing.expectEqual(@as(usize, 0), plan.deletes.len);
}

test "create multi: value is an array of stored names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("docs", 3, null, null);
    const ups = [_]http.UploadedFile{ upload("docs", "a.txt", "A"), upload("docs", "b.txt", "B") };
    const plan = (try planFileField(std.testing.io, a, f, null, &ups, &.{}, true)).?;
    try std.testing.expect(plan.value == .array);
    try std.testing.expectEqual(@as(usize, 2), plan.value.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), plan.writes.len);
}

test "update single: replace deletes the old file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("cover", 1, null, null);
    const existing = std.json.Value{ .string = "old_x1.png" };
    const ups = [_]http.UploadedFile{upload("cover", "new.png", &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })};
    const plan = (try planFileField(std.testing.io, a, f, existing, &ups, &.{}, true)).?;
    try std.testing.expectEqual(@as(usize, 1), plan.deletes.len);
    try std.testing.expectEqualStrings("old_x1.png", plan.deletes[0]);
}

test "update single: explicit clear (present, no upload) empties + deletes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("cover", 1, null, null);
    const existing = std.json.Value{ .string = "old_x1.png" };
    const plan = (try planFileField(std.testing.io, a, f, existing, &.{}, &.{}, true)).?;
    try std.testing.expect(plan.value == .string and plan.value.string.len == 0);
    try std.testing.expectEqual(@as(usize, 1), plan.deletes.len);
}

test "update multi: add + remove = (existing - removed) ++ added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("docs", 5, null, null);
    var ex = std.json.Array.init(a);
    try ex.append(.{ .string = "k1.txt" });
    try ex.append(.{ .string = "drop.txt" });
    try ex.append(.{ .string = "k2.txt" });
    const removals = [_][]const u8{"drop.txt"};
    const ups = [_]http.UploadedFile{upload("docs", "new.txt", "N")};
    const plan = (try planFileField(std.testing.io, a, f, .{ .array = ex }, &ups, &removals, true)).?;
    // net = k1, k2, new_xxx.txt
    try std.testing.expectEqual(@as(usize, 3), plan.value.array.items.len);
    try std.testing.expectEqualStrings("k1.txt", plan.value.array.items[0].string);
    try std.testing.expectEqualStrings("k2.txt", plan.value.array.items[1].string);
    try std.testing.expectEqual(@as(usize, 1), plan.writes.len);
    try std.testing.expectEqual(@as(usize, 1), plan.deletes.len);
    try std.testing.expectEqualStrings("drop.txt", plan.deletes[0]);
}

test "field absent -> unchanged (null plan)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = fileField("docs", 3, null, null);
    try std.testing.expect((try planFileField(std.testing.io, a, f, null, &.{}, &.{}, false)) == null);
}

test "validation: maxSize, maxSelect, mimeTypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // too large
    const big = fileField("cover", 1, 2, null);
    try std.testing.expectError(error.TooLarge, planFileField(std.testing.io, a, big, null, &[_]http.UploadedFile{upload("cover", "x", "ABC")}, &.{}, true));
    // too many (multi cap)
    const f2 = fileField("docs", 1, null, null);
    const ups2 = [_]http.UploadedFile{ upload("docs", "a", "A"), upload("docs", "b", "B") };
    try std.testing.expectError(error.TooMany, planFileField(std.testing.io, a, f2, null, &ups2, &.{}, true));
    // wrong mime (sniffed octet-stream not in [image/png])
    const mimes = [_][]const u8{"image/png"};
    const f3 = fileField("cover", 1, null, &mimes);
    try std.testing.expectError(error.BadMimeType, planFileField(std.testing.io, a, f3, null, &[_]http.UploadedFile{upload("cover", "x.txt", "hello")}, &.{}, true));
}
```

Register in `src/main.zig` test root: add `_ = @import("files/plan.zig");`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `planFileField`/types undefined.

- [ ] **Step 3: Implement — insert above the tests**

```zig
const naming = @import("naming.zig");
const mime = @import("mime.zig");

pub const PlannedWrite = struct { filename: []const u8, bytes: []const u8 };

pub const FieldPlan = struct {
    value: std.json.Value, // single: .string (""=cleared); multi: .array of strings
    writes: []const PlannedWrite,
    deletes: []const []const u8,
};

pub const PlanError = error{ TooMany, TooLarge, BadMimeType } || std.mem.Allocator.Error;

fn existingList(alloc: std.mem.Allocator, existing: ?std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const v = existing orelse return out.toOwnedSlice(alloc);
    switch (v) {
        .string => |s| if (s.len > 0) try out.append(alloc, s),
        .array => |arr| for (arr.items) |it| if (it == .string and it.string.len > 0) try out.append(alloc, it.string),
        else => {},
    }
    return out.toOwnedSlice(alloc);
}

fn validateAndName(io: std.Io, alloc: std.mem.Allocator, opts: anytype, u: http.UploadedFile) PlanError!PlannedWrite {
    if (opts.maxSize) |mx| if (u.bytes.len > mx) return error.TooLarge;
    if (!mime.allowed(opts.mimeTypes, mime.sniff(u.bytes))) return error.BadMimeType;
    const name = try naming.storedName(io, alloc, u.filename);
    return .{ .filename = name, .bytes = u.bytes };
}

/// Compute the new value + files to write/delete for one file `field`.
/// `existing` is the current stored value (null on create). `uploads`/`removals` are this field's
/// parts and `<field>-` values. `field_present` = was the field mentioned at all. Returns null when
/// the field is unchanged.
pub fn planFileField(
    io: std.Io,
    alloc: std.mem.Allocator,
    field: schema.Field,
    existing: ?std.json.Value,
    uploads: []const http.UploadedFile,
    removals: []const []const u8,
    field_present: bool,
) PlanError!?FieldPlan {
    const opts = field.options.file;

    if (opts.maxSelect == 1) {
        if (uploads.len > 1) return error.TooMany;
        if (uploads.len == 1) {
            const w = try validateAndName(io, alloc, opts, uploads[0]);
            const writes = try alloc.dupe(PlannedWrite, &.{w});
            const deletes = try existingList(alloc, existing);
            return .{ .value = .{ .string = w.filename }, .writes = writes, .deletes = deletes };
        }
        if (field_present) { // clear
            const deletes = try existingList(alloc, existing);
            return .{ .value = .{ .string = "" }, .writes = &.{}, .deletes = deletes };
        }
        return null;
    }

    // multi
    if (!field_present) return null;
    const existing_names = try existingList(alloc, existing);

    // removed = existing ∩ removals
    var deletes: std.ArrayList([]const u8) = .empty;
    var kept: std.ArrayList([]const u8) = .empty;
    for (existing_names) |name| {
        var is_removed = false;
        for (removals) |r| if (std.mem.eql(u8, r, name)) { is_removed = true; break; };
        if (is_removed) try deletes.append(alloc, name) else try kept.append(alloc, name);
    }

    var writes: std.ArrayList(PlannedWrite) = .empty;
    for (uploads) |u| try writes.append(alloc, try validateAndName(io, alloc, opts, u));

    if (kept.items.len + writes.items.len > opts.maxSelect) return error.TooMany;

    var arr = std.json.Array.init(alloc);
    for (kept.items) |name| try arr.append(.{ .string = name });
    for (writes.items) |w| try arr.append(.{ .string = w.filename });

    return .{
        .value = .{ .array = arr },
        .writes = try writes.toOwnedSlice(alloc),
        .deletes = try deletes.toOwnedSlice(alloc),
    };
}
```

- [ ] **Step 4: Run + commit**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` → PASS.

```bash
git add src/files/plan.zig src/main.zig
git commit -m "feat(files): planFileField upload computation (add/remove/replace)"
```

---

## Done criteria for 8a

- `mise exec zig@0.16.0 -- zig build test --summary all` green on branch `files`.
- Pure naming (traversal-safe) + MIME sniffing + the `Storage` interface/local backend (temp-dir tested) + `planFileField` (create/update add/remove/replace/validation across the matrix) + the neutral `UploadedFile`/`file_path`/`extra_headers` types + config. No HTTP/zap, no endpoints, no `main` merge — those are Plan 8b.

---

## Self-Review (author)

- **Spec coverage:** naming/sanitize (§3 → Task 1); MIME sniff (§6 → Task 2); neutral types + config (§2 → Task 3); `Storage`+local (§2 → Task 4); `planFileField` add/remove/replace/validation (§4,§6 → Task 5). Multipart glue, endpoints, file token, serving, wiring, smoke (§4,§5,§9-8b) are explicitly Plan 8b.
- **Placeholder scan:** none — full code in every step. The two "if the std error tag/namespace differs, adapt" notes (Task 4) are honest FFI/std-boundary guidance with the exact intent stated, not logic placeholders.
- **Type consistency:** `http.UploadedFile`/`Header`/`Response.file_path` (Task 3) consumed by `planFileField` (Task 5) and the storage tests; `Storage`/`LocalStorage` (Task 4) referenced by `App.storage`; `PlannedWrite`/`FieldPlan`/`PlanError` (Task 5) are the contract 8b's handlers consume; `mime.sniff`/`mime.allowed` (Task 2) + `naming.storedName` (Task 1) used by `planFileField`.
- **Deferred to 8b (intentional):** `files/multipart.zig`, `api/files.zig` (serve + token), `jwt.TokenType.file`, the `server.zig` multipart/sendFile wiring, the `api/records.zig` multipart-aware create/update/delete, `App.storage` construction in `runServe`.
