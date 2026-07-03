# SP3 Theme D — Files & Storage Round 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship (1) correct HTTP Range + conditional-request semantics for record-file downloads via a ZigBase-planned / facil.io-transmitted owned path (fixing the duplicate-Cache-Control bug), (2) a ~20-line Range-normalization shim + a facil.io-native tunable Cache-Control knob for static serving (facil.io keeps ALL static serving), and (3) a production S3-compatible storage backend behind a new `-Ds3` build gate, reusing a generalized SigV4 signer and serving through a local spool cache so Range/ETag/tenancy behavior is byte-identical to local storage.

**Architecture:** Four independent, dependency-ordered PRs off `origin/main` (`0ae3289`). PR1 — record-file route: pure planner (`src/files/serve_file.zig`) + `Response.file{path,offset,len}` transport + facil.io's public `http_sendfile(h, fd, len, offset)` extern (zap `src/fio.zig:426`); the owned static layer from the first draft is **WITHDRAWN — do not resurrect it**. PR2 — static: request-header Range rewrite shim + owned 416 + `Vary`, `HTTP_HVALUE_MAX_AGE` FIOBJ swap via `fio_state_callback_add(FIO_CALL_PRE_START, …)`, embedded-static Range + Cache-Control, SPA-shell `no-cache`. PR3 — SigV4 generalization (`src/mail/sigv4.zig` → `src/aws/sigv4.zig`, SES vectors pinned byte-identically). PR4 — `-Ds3` gate mirroring `-Dpostgres`, S3 client + spool cache, the one Breaking vtable change (`localPath` → `fetch`), startup HeadObject probe, MinIO CI. The spec is `/home/valthon/.claude/jobs/85efdf24/tmp/spec-files-storage-2.md`.

**Tech Stack:** Zig 0.16 (mise-pinned), vendored facil.io 0.7.x via zap 0.10.6 (READ-ONLY — never edit `~/.cache/zig/p/zap-*` or any vendored dep), Python 3.13 + pytest/Playwright browser suite (`tests/admin/`), MinIO via `docker run` in CI, Astro site mirror (`site/`).

## Global Constraints

- **Baseline & worktrees:** every PR branches from **current `origin/main`** (spec baseline `0ae3289`) — `git fetch origin && git switch -c <branch> origin/main` first. The session's local checkout may be stale (`e71eac5`); NEVER trust it as the baseline. Verify head/base freshness before opening each PR; merge with `gh pr merge --merge` (no squash, no auto-merge); use `gh api -X PATCH` (not `gh pr edit`) to edit a PR.
- **Zig build/test:** `mise exec zig@0.16.0 -- zig build` and `mise exec zig@0.16.0 -- zig build test --summary all`. The authoritative signal is the `Build Summary: N/N tests passed` line — a spurious `failed command: …` line appears even on success. There is no per-test filter. CI also re-runs the suite with `-Ddev-clock=false`; any test using `testcapture` must start with `if (!testcapture.enabled) return error.SkipZigTest;`.
- **New `src/*.zig` files MUST be added to the `test { _ = @import(...); }` block in `src/root.zig`** or their tests silently never run. This plan adds `src/files/serve_file.zig` (Task 1), `src/aws/sigv4.zig` replacing `src/mail/sigv4.zig` (Task 8), and `src/files/s3.zig` gated as `if (@import("build_options").s3) { _ = @import("files/s3.zig"); }` (Task 11) — mirroring the existing `build_options.postgres` block at `src/root.zig:341`.
- **Tenancy cache-control invariant (0.10.0, PINned — must not regress):** `cacheControlFor` in `src/api/files.zig` is a property of the **collection/URL, never the requester** — a tenant-owned collection is `private` even for a superuser, even with a `@public` viewRule. The two PIN tests in `api/files.zig` (`PIN: file-download view-authz…` and `PIN: cacheControlFor forces private…`) must pass **unchanged** — do not edit them, do not change `cacheControlFor`. The static Cache-Control knob (§C) must never touch record-file responses.
- **Authorization order is untouched:** record lookup → `recordReferencesFile` → `fileIdentity` → `tenancy.resolveRequest` → `policy.decide/authorizes(.view)` → `file.beforeServe` hook, all failing closed as 404, runs BEFORE any Range/conditional logic. No new code path may serve bytes today's path denies.
- **The Storage vtable change (`localPath` → `fetch(ctx, io, alloc, …)`) is Breaking:** it ships with its `changelog.d` fragment (`### Breaking` section) **and** the `examples/plugins` `AuditStorage` migration **and** the `docs/framework.md` §9 (+ site mirror) update **in the same task/PR** (Task 10). Same rule for the `Response.file_path` → `Response.file` rename (Task 2/3, PR1 fragment).
- **`-Ds3` mirrors `-Dpostgres` exactly:** `b.option(bool, "s3", …) orelse false` + `build_options.addOption`, conditional `@import` (db.zig:27 pattern) so the default build compiles ZERO S3 code, a **stock binary with `ZIGBASE_S3_BUCKET` set logs a warning and falls back to local storage** (the `postgres_url_without_build` precedent, `db.zig:477` / `framework.zig:1517-1524`) — fail-loud, never silent, never fatal. `ZIGBASE_S3_*` config fields parse in every build.
- **MinIO CI runs via `docker run`** (the `services:` block cannot pass the `server /data` command — same reason `postgres-tls` uses `docker run`, `ci.yml:195-226`), including a readiness poll and an `if: always()` teardown step. Live tests skip cleanly when `ZIGBASE_S3_TEST_ENDPOINT` is unset (the `ZIGBASE_PG_TEST_URL` pattern).
- **Docs + mirrors:** every `docs/*.md` change is mirrored to `site/src/content/docs/*.md`; `cd site && mise exec node@24 -- npm run build` must pass in every docs-touching task. `docs/superpowers/` is a historical archive — never rewrite it. `README.md` + `KNOWN_LIMITATIONS.md` per the tasks below.
- **Never edit `CHANGELOG.md`** or its site mirror. Each PR adds its own fragment file under `changelog.d/` (four fragments total; recognized sections only: Breaking, Features, Fixes, Changed, Performance, Deprecated, Removed, Security, Internal).
- **Browser suite for static/file-serving changes:** a green `zig build test` has repeatedly hidden real e2e regressions. Before merging PR1 and PR2, run locally: `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_static_files.py tests/admin/test_file_upload.py tests/admin/test_file_range.py -q` (plus the full `tests/admin` run before the PR2 merge). The conftest harness builds/launches the server itself; run from repo root.
- **Vendored deps are read-only.** The facil.io/zap sources cited here (`~/.cache/zig/p/zap-0.10.6-GoeB8y-IJAD3m9zkAkeTQalzU1NuvO072u8hA78Irdp8/…`) are evidence, not edit targets. No upstream patching (spec directive table, row 6).
- Commit after each task with the message given in the task. All paths are relative to the repo root.

**Verified source facts this plan builds on (do not re-litigate, but re-confirm the line numbers against your checkout before editing):**
- `zap src/fio.zig:426`: `pub extern fn http_sendfile(h: [*c]http_s, fd: c_int, length: usize, offset: usize) c_int;` — facil.io's public fd primitive. `http.c:367-377`: it `add_content_length`/`add_content_type`/`add_date` **set-if-missing** (so pre-set headers survive, exactly once), takes fd ownership (closes on every path), and does NOT set Cache-Control/ETag/Content-Range.
- `http.c:484`: `http_sendfile2` sets `Cache-Control: fiobj_dup(HTTP_HVALUE_MAX_AGE)` via `http_set_header` → `set_header_add` (`http_internal.h:208`) which **arrays** duplicates — the double-header bug.
- `http_internal.h:81` declares `extern FIOBJ HTTP_HVALUE_MAX_AGE;` (non-static); `http_internal.c:223` creates it (`fiobj_str_new("max-age=3600", 12)`) at `FIO_CALL_ON_INITIALIZE`; `fio.c:3925` (`fio_start`) forces `FIO_CALL_PRE_START` strictly after. `callback_type_e` ordinals (`fio.h:1578-1608`): `ON_INITIALIZE=0`, **`PRE_START=1`**.
- facil.io's Range parser (`http.c:507-560`) mishandles `bytes=X-` (→200), `bytes=-n` (offset past EOF + `%lu` of a negative), overlong `a-b` (bogus length), `a>=size` (→200 not 416). Its gz-sidecar probe is `http.c:449-470` (Accept-Encoding contains "gzip" → stat `<path>.gz`).
- `zap.fio.fiobj_hash_set` (`fio.zig:137`) dups key+value on insert and frees the replaced value; the caller frees its own key ref via `fiobj_free_wrapped` (`fio.zig:225`); the value ref is consumed by the call.
- `http1_sendfile` (`http1.c:190`) does **NOT** suppress the body for HEAD — the owned route must answer HEAD itself with an explicit `Content-Length` header + empty body (facil.io's `add_content_length` in `http_send_body` is set-if-missing, so the real length survives while zero bytes go on the wire — exactly how `http.c:585-590` answers HEAD for static).
- Zig 0.16: `std.Io.Dir.cwd().openFile(io, path, .{})` → `std.Io.File{ .handle: fd }`; `statFile` → `Stat{ .size: u64, .kind, .mtime: Io.Timestamp{ .nanoseconds: i96 }, … }`.

---

# PR 1 — Record-file route: planner + owned-header `http_sendfile` transport (branch `feat/files-range-record`)

### Task 1: Pure serve planner `src/files/serve_file.zig` (Range/ETag/conditional, no I/O)

**Files:**
- Create: `src/files/serve_file.zig`
- Modify: `src/root.zig` (test block + no new public export — internal module)
- Modify: `src/static_files.zig:101-118` (move `opaqueTag`/`etagMatches` out; call the new home)

**Interfaces:**
- Produces (consumed by Tasks 3 and 6/7):
  - `pub const PlanInput = struct { size: u64, etag: []const u8, range: []const u8 = "", if_none_match: []const u8 = "", if_range: []const u8 = "", head: bool = false }`
  - `pub const Plan = struct { status: u16, offset: u64 = 0, len: u64 = 0, content_range: ?[]const u8 = null }`
  - `pub fn plan(alloc: std.mem.Allocator, in: PlanInput) !Plan`
  - `pub fn parseRange(raw: []const u8, size: u64) ParsedRange` with `pub const ParsedRange = union(enum) { none, unsatisfiable, slice: struct { offset: u64, len: u64 } }` (Task 4's `normalizeRange` reuses it)
  - `pub fn fileEtag(alloc: std.mem.Allocator, col: []const u8, rid: []const u8, name: []const u8) ![]const u8` — quoted strong hex FNV-1a-64
  - `pub fn etagMatches(if_none_match: []const u8, etag: []const u8) bool` (moved from `static_files.zig`, now `pub`)

- [ ] **Step 1: Create `src/files/serve_file.zig`** with the complete module:

```zig
//! Pure HTTP Range/conditional planner for ZigBase-OWNED file responses (SP3 Theme D §B.2).
//! No I/O: given an entity's size + strong quoted ETag and the request's conditional headers,
//! decide the status (200 | 206 | 304 | 416), the byte window to transmit, and the
//! Content-Range value. Consumers: the record-file download route (api/files.zig) and the
//! EMBEDDED static path (static_files.zig, §A.4). Dir-mode static NEVER uses this planner —
//! that path stays 100% facil.io's (§A.3); only its Range *request header* is normalized
//! (static_files.normalizeRange, which reuses parseRange below).
const std = @import("std");

pub const PlanInput = struct {
    size: u64,
    /// Strong entity tag INCLUDING its surrounding quotes (e.g. "\"a1b2c3d4\"").
    etag: []const u8,
    range: []const u8 = "", // raw Range header value; "" = absent
    if_none_match: []const u8 = "", // raw If-None-Match value; "" = absent
    if_range: []const u8 = "", // raw If-Range value; "" = absent
    /// HEAD gets the identical plan (status/len/content_range); the caller sends no body.
    head: bool = false,
};

pub const Plan = struct {
    status: u16, // 200 | 206 | 304 | 416
    offset: u64 = 0,
    len: u64 = 0,
    content_range: ?[]const u8 = null, // "bytes a-b/N" (206) or "bytes */N" (416)
};

/// RFC 9110 §13.2.2 evaluation order: If-None-Match (weak comparison, list + `*`) → 304;
/// else If-Range (STRONG comparison — exact match required, a `W/` prefix always refuses);
/// else a single `bytes=` range; unsatisfiable → 416 with `Content-Range: bytes */N`.
pub fn plan(alloc: std.mem.Allocator, in: PlanInput) !Plan {
    if (etagMatches(in.if_none_match, in.etag)) return .{ .status = 304 };
    // If-Range: honor Range only when the validator exactly equals our strong ETag.
    // RFC 9110 §13.1.5 requires the strong comparison function here — weak tags refuse.
    const range_ok = in.if_range.len == 0 or
        std.mem.eql(u8, std.mem.trim(u8, in.if_range, " \t"), in.etag);
    if (in.range.len > 0 and range_ok) {
        switch (parseRange(in.range, in.size)) {
            .none => {}, // malformed / multi-range / non-bytes: ignore → full 200 (RFC-permitted)
            .unsatisfiable => return .{
                .status = 416,
                .content_range = try std.fmt.allocPrint(alloc, "bytes */{d}", .{in.size}),
            },
            .slice => |s| return .{
                .status = 206,
                .offset = s.offset,
                .len = s.len,
                .content_range = try std.fmt.allocPrint(
                    alloc,
                    "bytes {d}-{d}/{d}",
                    .{ s.offset, s.offset + s.len - 1, in.size },
                ),
            },
        }
    }
    return .{ .status = 200, .offset = 0, .len = in.size };
}

pub const ParsedRange = union(enum) {
    none,
    unsatisfiable,
    slice: struct { offset: u64, len: u64 },
};

/// Parse a SINGLE `bytes=` range against an entity of `size` bytes (RFC 9110 §14.1.2).
/// Syntactically-multi ("a-b,c-d"), malformed, and non-bytes units all yield `.none`
/// (callers then serve the full 200 — a server MAY ignore Range). Forms:
///   `a-b` — closed; `b` clamped to size-1; `b < a` is malformed → .none
///   `a-`  — open-ended, a..EOF
///   `-n`  — suffix, the final n bytes; n >= size → the whole entity as a 206;
///           `-0` → .unsatisfiable (RFC: a suffix-length of zero is unsatisfiable)
///   `a >= size` (incl. size == 0) → .unsatisfiable
pub fn parseRange(raw: []const u8, size: u64) ParsedRange {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (!std.mem.startsWith(u8, trimmed, "bytes=")) return .none;
    const spec = trimmed["bytes=".len..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .none; // multi-range: ignore
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .none;
    const first = spec[0..dash];
    const second = spec[dash + 1 ..];
    if (first.len == 0) {
        // suffix form "-n"
        if (second.len == 0) return .none; // bare "bytes=-" is malformed
        const n = std.fmt.parseInt(u64, second, 10) catch return .none;
        if (n == 0 or size == 0) return .unsatisfiable;
        const len = @min(n, size);
        return .{ .slice = .{ .offset = size - len, .len = len } };
    }
    const a = std.fmt.parseInt(u64, first, 10) catch return .none;
    if (a >= size) return .unsatisfiable; // covers size == 0 too
    if (second.len == 0) {
        // open-ended "a-": a..EOF (the form video players send when seeking)
        return .{ .slice = .{ .offset = a, .len = size - a } };
    }
    const b = std.fmt.parseInt(u64, second, 10) catch return .none;
    if (b < a) return .none; // malformed: ignore
    const end = @min(b, size - 1);
    return .{ .slice = .{ .offset = a, .len = end - a + 1 } };
}

/// Strong, content-immutable ETag for a stored record file. Stored names are minted with a
/// random 10-char base36 suffix and an UPDATE always mints a NEW stored name
/// (files/naming.zig storedName), so (collection, record id, stored name) is content-stable:
/// hex FNV-1a-64 of `col ++ "/" ++ rid ++ "/" ++ name`, quoted. No stat-derived component —
/// identical for local and S3-spooled serving (§B.3).
pub fn fileEtag(alloc: std.mem.Allocator, col: []const u8, rid: []const u8, name: []const u8) ![]const u8 {
    var h = std.hash.Fnv1a_64.init();
    h.update(col);
    h.update("/");
    h.update(rid);
    h.update("/");
    h.update(name);
    return std.fmt.allocPrint(alloc, "\"{x:0>16}\"", .{h.final()});
}

/// Strip an RFC 7232 weak-validator prefix ("W/") from an entity tag.
fn opaqueTag(tag: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tag, "W/")) tag[2..] else tag;
}

/// True when the request's If-None-Match matches this entity tag ("*", or a list member).
/// RFC 7232 §3.2: If-None-Match MUST use the WEAK comparison function — W/ prefixes are
/// ignored on both sides (proxies may weaken our strong tag). Moved here (was a private fn
/// in static_files.zig) so the record route, embedded static, and the SPA shell share one
/// implementation; static_files.zig re-imports it.
pub fn etagMatches(if_none_match: []const u8, etag: []const u8) bool {
    if (if_none_match.len == 0) return false;
    if (std.mem.eql(u8, if_none_match, "*")) return true;
    const ours = opaqueTag(etag);
    var it = std.mem.splitScalar(u8, if_none_match, ',');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, opaqueTag(std.mem.trim(u8, raw, " \t")), ours)) return true;
    }
    return false;
}
```

- [ ] **Step 2: Write the test matrix in the same file** (~30 cases; the pinned contract for Tasks 3/4/6):

```zig
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn expectSlice(pr: ParsedRange, offset: u64, len: u64) !void {
    try testing.expect(pr == .slice);
    try testing.expectEqual(offset, pr.slice.offset);
    try testing.expectEqual(len, pr.slice.len);
}

test "parseRange: closed, open-ended, suffix, clamping" {
    try expectSlice(parseRange("bytes=0-99", 1000), 0, 100);
    try expectSlice(parseRange("bytes=500-999", 1000), 500, 500);
    try expectSlice(parseRange(" bytes=0-0", 1000), 0, 1); // leading space trimmed
    // open-ended "X-" — the video-seek form facil.io drops to a 200 (KNOWN_LIMITATIONS bullet)
    try expectSlice(parseRange("bytes=200-", 1000), 200, 800);
    try expectSlice(parseRange("bytes=999-", 1000), 999, 1);
    // suffix "-n"
    try expectSlice(parseRange("bytes=-100", 1000), 900, 100);
    try expectSlice(parseRange("bytes=-1", 1000), 999, 1);
    // suffix longer than the entity: the whole entity (RFC 9110 §14.1.2)
    try expectSlice(parseRange("bytes=-5000", 1000), 0, 1000);
    // overlong closed range: end clamped to size-1
    try expectSlice(parseRange("bytes=900-5000", 1000), 900, 100);
}

test "parseRange: unsatisfiable forms -> 416" {
    try testing.expect(parseRange("bytes=1000-", 1000) == .unsatisfiable); // a == size
    try testing.expect(parseRange("bytes=1001-2000", 1000) == .unsatisfiable); // a > size
    try testing.expect(parseRange("bytes=-0", 1000) == .unsatisfiable); // zero suffix
    try testing.expect(parseRange("bytes=0-", 0) == .unsatisfiable); // empty entity
    try testing.expect(parseRange("bytes=-5", 0) == .unsatisfiable); // suffix on empty entity
}

test "parseRange: malformed / multi-range / non-bytes are ignored (.none -> full 200)" {
    try testing.expect(parseRange("", 1000) == .none);
    try testing.expect(parseRange("bytes=0-99,200-299", 1000) == .none); // multi: RFC-permitted ignore
    try testing.expect(parseRange("bytes=99-0", 1000) == .none); // b < a
    try testing.expect(parseRange("bytes=abc-def", 1000) == .none);
    try testing.expect(parseRange("bytes=-", 1000) == .none);
    try testing.expect(parseRange("bytes=", 1000) == .none);
    try testing.expect(parseRange("items=0-99", 1000) == .none); // non-bytes unit
    try testing.expect(parseRange("0-99", 1000) == .none); // missing unit
}

test "plan: If-None-Match wins over Range; weak comparison; list; star" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const etag = "\"0123456789abcdef\"";
    // single + Range present: 304 still wins (evaluation order)
    const p1 = try plan(a, .{ .size = 100, .etag = etag, .if_none_match = etag, .range = "bytes=0-9" });
    try testing.expectEqual(@as(u16, 304), p1.status);
    // weak comparison: W/ on the client's side matches our strong tag
    try testing.expectEqual(@as(u16, 304), (try plan(a, .{ .size = 100, .etag = etag, .if_none_match = "W/\"0123456789abcdef\"" })).status);
    // list member
    try testing.expectEqual(@as(u16, 304), (try plan(a, .{ .size = 100, .etag = etag, .if_none_match = "\"x\", \"0123456789abcdef\"" })).status);
    // star
    try testing.expectEqual(@as(u16, 304), (try plan(a, .{ .size = 100, .etag = etag, .if_none_match = "*" })).status);
    // mismatch: falls through to the Range
    const p2 = try plan(a, .{ .size = 100, .etag = etag, .if_none_match = "\"nope\"", .range = "bytes=0-9" });
    try testing.expectEqual(@as(u16, 206), p2.status);
    try testing.expectEqualStrings("bytes 0-9/100", p2.content_range.?);
}

test "plan: If-Range strong match honors Range; mismatch/weak refuse it (full 200)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const etag = "\"0123456789abcdef\"";
    const hit = try plan(a, .{ .size = 100, .etag = etag, .if_range = etag, .range = "bytes=10-19" });
    try testing.expectEqual(@as(u16, 206), hit.status);
    try testing.expectEqual(@as(u64, 10), hit.offset);
    try testing.expectEqual(@as(u64, 10), hit.len);
    // mismatched validator: Range ignored, full 200 with the whole entity
    const miss = try plan(a, .{ .size = 100, .etag = etag, .if_range = "\"old\"", .range = "bytes=10-19" });
    try testing.expectEqual(@as(u16, 200), miss.status);
    try testing.expectEqual(@as(u64, 100), miss.len);
    // WEAK validator: strong comparison required -> refused even for the same opaque tag
    const weak = try plan(a, .{ .size = 100, .etag = etag, .if_range = "W/\"0123456789abcdef\"", .range = "bytes=10-19" });
    try testing.expectEqual(@as(u16, 200), weak.status);
    // If-Range mismatch also suppresses a WOULD-BE-416 range (the range is ignored, not evaluated)
    const not416 = try plan(a, .{ .size = 100, .etag = etag, .if_range = "\"old\"", .range = "bytes=500-" });
    try testing.expectEqual(@as(u16, 200), not416.status);
}

test "plan: 200 / 206 / 416 shapes + HEAD parity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const etag = "\"0123456789abcdef\"";
    const full = try plan(a, .{ .size = 42, .etag = etag });
    try testing.expectEqual(@as(u16, 200), full.status);
    try testing.expectEqual(@as(u64, 42), full.len);
    try testing.expect(full.content_range == null);
    const p206 = try plan(a, .{ .size = 1000, .etag = etag, .range = "bytes=200-" });
    try testing.expectEqual(@as(u16, 206), p206.status);
    try testing.expectEqualStrings("bytes 200-999/1000", p206.content_range.?);
    const p416 = try plan(a, .{ .size = 1000, .etag = etag, .range = "bytes=2000-" });
    try testing.expectEqual(@as(u16, 416), p416.status);
    try testing.expectEqualStrings("bytes */1000", p416.content_range.?);
    // HEAD: byte-identical plan (the caller just doesn't transmit the body)
    const head = try plan(a, .{ .size = 1000, .etag = etag, .range = "bytes=200-", .head = true });
    try testing.expectEqual(p206.status, head.status);
    try testing.expectEqual(p206.len, head.len);
}

test "fileEtag: quoted 16-hex, deterministic, distinct per identity component" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e1 = try fileEtag(a, "docs", "r1", "a_ab12cd34ef.png");
    try testing.expectEqual(@as(usize, 18), e1.len); // 2 quotes + 16 hex
    try testing.expectEqual(@as(u8, '"'), e1[0]);
    try testing.expectEqual(@as(u8, '"'), e1[e1.len - 1]);
    try testing.expectEqualStrings(e1, try fileEtag(a, "docs", "r1", "a_ab12cd34ef.png"));
    try testing.expect(!std.mem.eql(u8, e1, try fileEtag(a, "docs", "r2", "a_ab12cd34ef.png")));
    try testing.expect(!std.mem.eql(u8, e1, try fileEtag(a, "docs2", "r1", "a_ab12cd34ef.png")));
    // The separator prevents (col="a", rid="b/c") colliding with (col="a/b", rid="c")
    try testing.expect(!std.mem.eql(u8, try fileEtag(a, "ab", "c", "n"), try fileEtag(a, "a", "bc", "n")));
}

test "etagMatches uses RFC 7232 weak comparison (moved from static_files.zig)" {
    try testing.expect(etagMatches("W/\"22222222\"", "\"22222222\""));
    try testing.expect(etagMatches("\"x\", W/\"22222222\"", "\"22222222\""));
    try testing.expect(etagMatches("\"22222222\"", "W/\"22222222\""));
    try testing.expect(!etagMatches("W/\"junk\"", "\"22222222\""));
    try testing.expect(!etagMatches("", "\"22222222\""));
    try testing.expect(etagMatches("*", "\"anything\""));
}
```

- [ ] **Step 3: Move `etagMatches` out of `static_files.zig`.** Delete the private `opaqueTag` + `etagMatches` fns (`static_files.zig:101-118`) and their test `test "etagMatches uses RFC 7232 weak comparison (W/ prefix ignored)"` (~line 633 — it moved into serve_file.zig above). Add near the imports at the top:
  ```zig
  const serve_file = @import("files/serve_file.zig");
  ```
  and change the one call site in `serveEmbedded` (line 136) to `serve_file.etagMatches(ctx.if_none_match, hit.etag)`.
- [ ] **Step 4: Register the new file in `src/root.zig`'s test block** — insert alphabetically next to the other `files/` imports (root.zig:262-266):
  ```zig
  _ = @import("files/serve_file.zig");
  ```
- [ ] **Step 5: Run** `mise exec zig@0.16.0 -- zig build test --summary all` — expect `Build Summary: N/N tests passed` including every new `serve_file` test (temporarily break one expectation first if you want proof of discovery, then restore it).
- [ ] **Step 6: Commit**
  ```bash
  git add src/files/serve_file.zig src/root.zig src/static_files.zig
  git commit -m "feat(files): pure Range/conditional serve planner (RFC 9110) + content-immutable file ETag"
  ```

---

### Task 2: `Response.file` transport + `http_sendfile` owned sink in server.zig

**Files:**
- Modify: `src/http.zig:112-120` (Response), `src/http.zig:149-156` (test)
- Modify: `src/server.zig:910-916` (sink), + new `sendFileRange` helper above `onRequest`
- Modify: `src/static_files.zig:456-462, 1008, 1025-1042, 1050-1139` (`.file_path` → `.file` at the serveDir return + every test assertion)
- Modify: `src/api/files.zig:150` (mechanical `.file = .{ .path = path }`; the full rewrite is Task 3)

**Interfaces:**
- Produces: `http.FileRef = struct { path: []const u8, offset: u64 = 0, len: ?u64 = null }`; `Response.file: ?FileRef` (replaces `Response.file_path`). **Sink discriminator:** `len == null` → wholesale `r.sendFile(path)` delegation exactly as today (dir-mode static rides this untouched); `len != null` → the owned-header path: server.zig opens the file and transmits `[offset, offset+len)` via `zap.fio.http_sendfile`, and sets `content-type` from `resp.content_type`. Consumed by Task 3 (record route always sets `len`) and Task 7 (embedded stays body-based, unaffected).

- [ ] **Step 1: `src/http.zig`** — replace the `file_path` field (line 117-118) with:
  ```zig
      /// A filesystem file (or a byte window of one) to stream instead of `body`.
      /// `len == null` => server.zig DELEGATES wholesale to facil.io's sendFile
      /// (http_sendfile2: stat, mime, ETag, 304, `.gz` sidecar, Range — dir-mode
      /// static rides this). `len != null` => the ZigBase-OWNED path (§B): the
      /// handler has already planned status + headers; server.zig opens the path
      /// and transmits `[offset, offset+len)` through facil.io's public
      /// `http_sendfile(h, fd, len, offset)` fd primitive — the same call
      /// http_sendfile2 itself finishes through. 0.10.0, Breaking: replaces
      /// `Response.file_path` (migrate `.file_path = p` -> `.file = .{ .path = p }`).
      file: ?FileRef = null,
  ```
  and add above `Response`:
  ```zig
  pub const FileRef = struct {
      path: []const u8,
      offset: u64 = 0,
      len: ?u64 = null,
  };
  ```
  Update the test at line 149:
  ```zig
  test "Response file ref and UploadedFile default/usage" {
      const r = Response{ .status = 200, .body = "", .file = .{ .path = "/x/y.png" } };
      try std.testing.expectEqualStrings("/x/y.png", r.file.?.path);
      try std.testing.expect(r.file.?.len == null); // default: wholesale facil.io delegation
      const ranged = Response{ .status = 206, .body = "", .file = .{ .path = "/x/y.png", .offset = 10, .len = 5 } };
      try std.testing.expectEqual(@as(u64, 10), ranged.file.?.offset);
      const u = UploadedFile{ .field = "cover", .filename = "a.png", .mimetype = "image/png", .bytes = "x" };
      try std.testing.expectEqualStrings("cover", u.field);
      const ctx = RequestCtx{ .method = .POST, .path = "/", .allocator = std.testing.allocator };
      try std.testing.expect(ctx.files.len == 0 and ctx.form_fields == null);
  }
  ```
- [ ] **Step 2: `src/server.zig`** — add above `sendRawEnvelope` (~line 808):
  ```zig
  /// §B transport: transmit `[offset, offset+len)` of `path` through facil.io's PUBLIC
  /// `http_sendfile(h, fd, length, offset)` extern (zap src/fio.zig:426) — the same fd
  /// primitive `http_sendfile2` itself finishes through, so ZigBase reimplements no
  /// socket/streaming code. facil.io takes ownership of the fd (closes it on every path,
  /// http.c:367-377) and adds Content-Length / Content-Type / Date ONLY-IF-MISSING, so
  /// every header the handler set goes on the wire exactly once (the §B.1 double-header
  /// analysis). The zap handle is consumed on success — mark the request finished so
  /// zap's implicit-response machinery stays quiet.
  fn sendFileRange(r: zap.Request, io: std.Io, path: []const u8, offset: u64, len: u64) !void {
      const f = try std.Io.Dir.cwd().openFile(io, path, .{});
      if (zap.fio.http_sendfile(r.h, f.handle, len, offset) != 0) return error.SendFile;
      r.markAsFinished(true);
  }
  ```
  and replace the sink (lines 910-916):
  ```zig
      for (resp.extra_headers) |h| r.setHeader(h.name, h.value) catch {};
      if (resp.file) |f| {
          if (f.len) |len| {
              // ZigBase-owned plan (record files, §B): status + headers were set above;
              // Content-Type comes from the handler's Response (facil.io's
              // add_content_type is set-if-missing, so this value wins, exactly once).
              r.setHeader("content-type", resp.content_type) catch {};
              sendFileRange(r, self.app.io, f.path, f.offset, len) catch {
                  // Open failure => the existing 404 raw envelope (unchanged semantics).
                  sendRawEnvelope(r, 404, "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}");
              };
          } else {
              // Wholesale facil.io delegation (dir-mode static): mime, ETag, 304,
              // `.gz` sidecar, Range are ALL facil.io's (§A.3) — byte-identical to today.
              r.sendFile(f.path) catch {
                  sendRawEnvelope(r, 404, "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}");
              };
          }
          return;
      }
      r.setHeader("content-type", resp.content_type) catch {};
      r.sendBody(resp.body) catch {};
  ```
- [ ] **Step 3: mechanical `.file_path` → `.file` sweep.** `git grep -n "file_path" src/` and update every remaining site:
  - `src/static_files.zig` `serveDir` return (line ~456-462): `.file_path = full,` → `.file = .{ .path = full },` (NO offset/len — delegation stays wholesale).
  - Every test assertion `r.file_path` → `r.file.?.path` and `r.file_path != null` → `r.file != null` (lines ~658, 665, 1008, 1037-1038, 1075-1076, 1121-1138 — trust grep, not this list).
  - `src/api/files.zig:150`: `return .{ .status = 200, .body = "", .file = .{ .path = path }, .extra_headers = headers };` (still wholesale here; Task 3 flips it to the owned path).
- [ ] **Step 4: Run** `mise exec zig@0.16.0 -- zig build test --summary all` — expect all tests pass (`Build Summary:` line). Then boot-smoke the delegated path: `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_static_files.py -q` — expect pass (dir-mode static must be byte-identical).
- [ ] **Step 5: Commit**
  ```bash
  git add src/http.zig src/server.zig src/static_files.zig src/api/files.zig
  git commit -m "feat(http)!: Response.file{path,offset,len} transport + owned http_sendfile range sink (replaces Response.file_path)"
  ```

---

### Task 3: Record-file route — planner wiring, headers exactly once, 206/304/416/HEAD, e2e + docs + fragment

**Files:**
- Modify: `src/api/files.zig:79-151` (`serve`) + new unit tests
- Create: `tests/admin/test_file_range.py`
- Create: `changelog.d/files-range-record.md`
- Modify: `docs/api.md` §Files (~line 1002-1030) + `site/src/content/docs/api.md` (same section)

**Interfaces:**
- Consumes: Task 1 `serve_file.plan/fileEtag`, Task 2 `Response.file` (this route ALWAYS sets `len` — even a full-body 200 — so it deterministically takes the owned path).
- Produces: the wire contract pinned by `tests/admin/test_file_range.py` — every 200/206 carries exactly ONE `Cache-Control`, `Accept-Ranges: bytes`, a quoted strong `ETag`, explicit `Content-Type`; 206 adds `Content-Range`; 304 replays `ETag`+`Cache-Control` only; 416 carries `Content-Range: bytes */N` + the standard security headers; HEAD mirrors GET (status/headers/Content-Length, no body).

- [ ] **Step 1: rewrite the tail of `serve()`** in `src/api/files.zig`. Add imports at the top:
  ```zig
  const serve_file = @import("../files/serve_file.zig");
  const mime = @import("../files/mime.zig");
  ```
  Then replace everything from `const storage = app.storage orelse …` (line 127) to the final `return` (line 150) with:
  ```zig
      const storage = app.storage orelse return ApiError.internal().toResponse(ctx.allocator);
      const path = (try storage.localPath(ctx.allocator, col.name, rid, name)) orelse return ApiError.internal().toResponse(ctx.allocator);
      // The DB references this file but the backend can't produce it: 404 (hide existence),
      // matching the old sendFile-catch behavior — but planned here so the conditional
      // headers below never describe a file we can't stat. (PR4 renames localPath -> fetch
      // and adds the loud std.log.err for the null case; the 404 shape is set up now.)
      const st = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch
          return ApiError.notFound().toResponse(ctx.allocator);

      // §B.2/§B.3: plan status + byte window from the request's conditional headers.
      // Authorization (above) already completed — no plan output can leak denied bytes.
      const etag = try serve_file.fileEtag(ctx.allocator, col.name, rid, name);
      const p = try serve_file.plan(ctx.allocator, .{
          .size = st.size,
          .etag = etag,
          .range = ctx.header("range") orelse "",
          .if_none_match = ctx.if_none_match,
          .if_range = ctx.header("if-range") orelse "",
          .head = ctx.method == .HEAD,
      });
      const cache = cacheControlFor(col);
      if (p.status == 304) {
          // RFC 9110 §15.4.5: a 304 replays the validator + cache policy only.
          const hs304 = try ctx.allocator.dupe(http.Header, &.{
              .{ .name = "ETag", .value = etag },
              .{ .name = "Cache-Control", .value = cache },
          });
          return .{ .status = 304, .body = "", .extra_headers = hs304 };
      }

      const qp = params_mod.parse(ctx.allocator, ctx.query) catch null;
      const force_download = if (qp) |pq| (pq.get("download") != null) else false;
      // Only render inline for known-safe types; everything else downloads
      // (neutralizes HTML/SVG/JS XSS). ?download and ?token compose orthogonally
      // with Range — disposition/identity are resolved before/independent of the plan.
      const ext = blk: {
          const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :blk "";
          break :blk name[dot + 1 ..];
      };
      const inline_safe = isInlineSafeExt(ext);
      const disp_kind: []const u8 = if (force_download or !inline_safe) "attachment" else "inline";
      const disposition = try std.fmt.allocPrint(ctx.allocator, "{s}; filename=\"{s}\"", .{ disp_kind, name });
      // facil.io no longer infers Content-Type on this route (the owned path bypasses
      // http_sendfile2's mime lookup): set it explicitly; unknown -> octet-stream.
      const content_type = mime.fromExtension(name);

      var hs: std.ArrayList(http.Header) = .empty;
      try hs.appendSlice(ctx.allocator, &.{
          .{ .name = "Referrer-Policy", .value = "no-referrer" },
          .{ .name = "X-Content-Type-Options", .value = "nosniff" },
          .{ .name = "Content-Security-Policy", .value = "default-src 'none'; sandbox" },
          .{ .name = "Cache-Control", .value = cache }, // exactly ONCE now (§B.1 fix)
          .{ .name = "Content-Disposition", .value = disposition },
          .{ .name = "ETag", .value = etag },
          .{ .name = "Accept-Ranges", .value = "bytes" },
      });
      if (p.content_range) |cr| try hs.append(ctx.allocator, .{ .name = "Content-Range", .value = cr });
      if (p.status == 416) {
          return .{ .status = 416, .body = "", .content_type = content_type, .extra_headers = try hs.toOwnedSlice(ctx.allocator) };
      }
      if (ctx.method == .HEAD) {
          // facil.io's http1_sendfile does NOT strip bodies for HEAD, so mirror
          // facil.io's own static HEAD handling (http.c:585-590): explicit
          // Content-Length + empty body — http_send_body's add_content_length is
          // set-if-missing, so the real length survives while zero bytes are sent.
          try hs.append(ctx.allocator, .{
              .name = "Content-Length",
              .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{p.len}),
          });
          return .{ .status = p.status, .body = "", .content_type = content_type, .extra_headers = try hs.toOwnedSlice(ctx.allocator) };
      }
      // 200 or 206: ALWAYS set len (the planner computed it even for the full body), so
      // this route deterministically takes server.zig's owned http_sendfile path.
      return .{
          .status = p.status,
          .body = "",
          .content_type = content_type,
          .file = .{ .path = path, .offset = p.offset, .len = p.len },
          .extra_headers = try hs.toOwnedSlice(ctx.allocator),
      };
  ```
  Note the pre-existing `const qp` for `?download` moved below the 304 return (it is not needed for 304); delete the now-duplicated original lines 130-150.
- [ ] **Step 2: unit tests in `src/api/files.zig`** — an end-to-end handler test mirroring `api/records.zig`'s `TestEnv` (records.zig:663 — tmp-dir file DB + `db.Pool.init`; read it first and reuse its shape). Add:
  ```zig
  test "serve: header emission — exactly one Cache-Control, ETag, Accept-Ranges; 206/304/416/HEAD" {
      // Env: tmp-dir pool (api/records.zig TestEnv pattern), one @public collection with a
      // file field, one record referencing "a_0000000000.png", LocalStorage rooted in the
      // same tmp dir holding 1000 bytes for it, and an App wired with pool + storage.
      const migrations = @import("../migrations.zig");
      const files_storage = @import("../files/storage.zig");
      const app_mod = @import("../app.zig");
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();
      const ga = std.testing.allocator;
      var arena = std.heap.ArenaAllocator.init(ga);
      defer arena.deinit();
      const a = arena.allocator();
      const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
      const db_path = try std.fmt.allocPrintSentinel(a, "{s}/test.db", .{dir_path}, 0);
      var pool = try db.Pool.init(ga, std.testing.io, db_path);
      defer pool.deinit();
      {
          const w = pool.acquireWriter();
          defer pool.releaseWriter();
          try migrations.run(w);
          _ = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "docs", .viewRule = "@public", .fields = &[_]schema.Field{
              .{ .id = "d1", .name = "file", .options = .{ .file = .{ .maxSelect = 1 } } },
          } });
          try w.exec("INSERT INTO docs (id,created,updated,file) VALUES ('r1','t','t','a_0000000000.png');");
      }
      var local = files_storage.LocalStorage.init(dir_path);
      const storage_iface = local.storage();
      try storage_iface.put(std.testing.io, "docs", "r1", "a_0000000000.png", "x" ** 1000);
      var app = app_mod.App{ .allocator = ga, .io = std.testing.io, .pool = &pool, .storage = &storage_iface };

      const params = [_]http.Param{
          .{ .key = "col", .value = "docs" }, .{ .key = "rec", .value = "r1" }, .{ .key = "name", .value = "a_0000000000.png" },
      };
      // Plain GET: 200, exactly one Cache-Control, ETag + Accept-Ranges, owned file ref.
      var ctx = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params };
      const r200 = try serve(&ctx);
      try std.testing.expectEqual(@as(u16, 200), r200.status);
      try std.testing.expect(r200.file != null);
      try std.testing.expectEqual(@as(?u64, 1000), r200.file.?.len); // ALWAYS len => owned path
      var cc_count: usize = 0;
      var etag_val: []const u8 = "";
      for (r200.extra_headers) |h| {
          if (std.mem.eql(u8, h.name, "Cache-Control")) cc_count += 1;
          if (std.mem.eql(u8, h.name, "ETag")) etag_val = h.value;
      }
      try std.testing.expectEqual(@as(usize, 1), cc_count); // §B.1 regression pin
      try std.testing.expectEqual(@as(usize, 18), etag_val.len);
      try std.testing.expectEqualStrings("image/png", r200.content_type); // explicit Content-Type

      // Range GET: 206 window + Content-Range.
      const range_hdrs = [_]http.Param{.{ .key = "range", .value = "bytes=100-" }};
      var ctx206 = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params, .headers = &range_hdrs };
      const r206 = try serve(&ctx206);
      try std.testing.expectEqual(@as(u16, 206), r206.status);
      try std.testing.expectEqual(@as(u64, 100), r206.file.?.offset);
      try std.testing.expectEqual(@as(?u64, 900), r206.file.?.len);

      // Conditional GET with the minted ETag: 304 with ETag + Cache-Control ONLY.
      var ctx304 = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params, .if_none_match = etag_val };
      const r304 = try serve(&ctx304);
      try std.testing.expectEqual(@as(u16, 304), r304.status);
      try std.testing.expectEqual(@as(usize, 2), r304.extra_headers.len);

      // Unsatisfiable range: 416 + `bytes */1000`, security headers intact, no file ref.
      const bad = [_]http.Param{.{ .key = "range", .value = "bytes=5000-" }};
      var ctx416 = http.RequestCtx{ .method = .GET, .path = "/", .allocator = a, .app = &app, .params = &params, .headers = &bad };
      const r416 = try serve(&ctx416);
      try std.testing.expectEqual(@as(u16, 416), r416.status);
      try std.testing.expect(r416.file == null);
      var got_cr = false;
      for (r416.extra_headers) |h| if (std.mem.eql(u8, h.name, "Content-Range")) {
          try std.testing.expectEqualStrings("bytes */1000", h.value);
          got_cr = true;
      };
      try std.testing.expect(got_cr);

      // HEAD mirrors GET: explicit Content-Length, empty body, no file ref.
      var ctxh = http.RequestCtx{ .method = .HEAD, .path = "/", .allocator = a, .app = &app, .params = &params };
      const rh = try serve(&ctxh);
      try std.testing.expectEqual(@as(u16, 200), rh.status);
      try std.testing.expect(rh.file == null);
      var got_cl = false;
      for (rh.extra_headers) |h| if (std.mem.eql(u8, h.name, "Content-Length")) {
          try std.testing.expectEqualStrings("1000", h.value);
          got_cl = true;
      };
      try std.testing.expect(got_cl);
  }
  ```
  (`ctx.header("range")` reads the `headers` list in unit tests — `RequestCtx.header` consults `raw_header_fn` first, then the list. If `collections.create`'s exact signature differs — read the PIN test at the top of this file, which already calls it — mirror that call shape.)
- [ ] **Step 3: Run** `mise exec zig@0.16.0 -- zig build test --summary all` — expect PASS incl. the two untouched PIN tests.
- [ ] **Step 4: e2e `tests/admin/test_file_range.py`** (raw-HTTP; launches its own server like `test_static_files.py` — copy its `_free_port/_wait_up/_get/_hdr` helpers verbatim). Superuser auth body is `{"identity": …, "password": …}` (see `clients/typescript/test/integration/harness.ts:178`); collection-create input shape is docs/api.md §"Input vs. output shape":
  ```python
  import io, json, socket, subprocess, tempfile, time, os, pathlib, shutil, urllib.request, urllib.error, uuid
  import pytest
  from _bin import resolve_binary

  REPO = pathlib.Path(__file__).resolve().parents[2]

  # ... copy _free_port, _wait_up, _get, _hdr from test_static_files.py ...

  def _post_json(url, obj, token=None):
      data = json.dumps(obj).encode()
      req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
      if token: req.add_header("Authorization", f"Bearer {token}")
      with urllib.request.urlopen(req, timeout=5) as r:
          return r.status, json.loads(r.read() or b"{}")

  def _multipart(fields, file_field, filename, blob):
      b = uuid.uuid4().hex
      out = io.BytesIO()
      for k, v in fields.items():
          out.write(f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
      out.write(f"--{b}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{filename}\"\r\n"
                f"Content-Type: application/octet-stream\r\n\r\n".encode())
      out.write(blob)
      out.write(f"\r\n--{b}--\r\n".encode())
      return out.getvalue(), f"multipart/form-data; boundary={b}"

  @pytest.fixture()
  def file_server():
      binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
      data = tempfile.mkdtemp(prefix="zb_files_")
      subprocess.run([str(binary), "superuser", "create", "--email", "admin@x.io",
                      "--password", "adminpassword", "--data-dir", data], check=True)
      port = _free_port()
      proc = subprocess.Popen(
          [str(binary), "serve", "--insecure-cookies", "--http-port", str(port), "--data-dir", data],
          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
      base = f"http://127.0.0.1:{port}"
      _wait_up(f"{base}/api/health")
      try:
          yield base
      finally:
          proc.terminate(); proc.wait(timeout=5); shutil.rmtree(data, ignore_errors=True)

  def _setup_record(base, blob, view_rule="@public"):
      _, auth = _post_json(f"{base}/api/collections/_superusers/auth-with-password",
                           {"identity": "admin@x.io", "password": "adminpassword"})
      token = auth["token"]
      _post_json(f"{base}/api/collections",
                 {"name": "media", "type": "base", "viewRule": view_rule,
                  "fields": [{"name": "clip", "type": "file", "options": {"maxSelect": 1}}]},
                 token=token)
      body, ctype = _multipart({}, "clip", "video.mp4", blob)
      req = urllib.request.Request(f"{base}/api/collections/media/records", data=body,
                                   headers={"Content-Type": ctype, "Authorization": f"Bearer {token}"}, method="POST")
      with urllib.request.urlopen(req, timeout=5) as r:
          rec = json.loads(r.read())
      return token, rec["id"], rec["clip"]  # stored name (suffixed)

  def test_record_file_range_matrix(file_server):
      """206 for bytes=a-b / bytes=X- / bytes=-n, Accept-Ranges, EXACTLY ONE Cache-Control,
      quoted ETag -> 304, If-Range, 416, HEAD parity — the §B wire pin."""
      blob = bytes(range(256)) * 4  # 1024 recognizable bytes
      base = file_server
      _, rid, stored = _setup_record(base, blob)
      url = f"{base}/api/files/media/{rid}/{stored}"

      st, hdr, body = _get(url)
      assert st == 200 and body == blob
      # exactly one Cache-Control on the wire (the duplicate-header regression pin)
      assert len(hdr.get_all("Cache-Control") or []) == 1
      assert _hdr(hdr, "Accept-Ranges") == "bytes"
      etag = _hdr(hdr, "ETag")
      assert etag.startswith('"') and etag.endswith('"')

      st, hdr, body = _get(url, {"Range": "bytes=100-199"})
      assert st == 206 and body == blob[100:200]
      assert _hdr(hdr, "Content-Range") == f"bytes 100-199/{len(blob)}"

      st, _, body = _get(url, {"Range": "bytes=1000-"})  # open-ended video-seek form
      assert st == 206 and body == blob[1000:]
      st, _, body = _get(url, {"Range": "bytes=-24"})  # suffix form
      assert st == 206 and body == blob[-24:]

      st, hdr, _ = _get(url, {"If-None-Match": etag})
      assert st == 304 and _hdr(hdr, "ETag") == etag

      st, _, body = _get(url, {"Range": "bytes=0-9", "If-Range": etag})
      assert st == 206 and body == blob[:10]
      st, _, body = _get(url, {"Range": "bytes=0-9", "If-Range": '"stale"'})
      assert st == 200 and body == blob  # mismatched validator ignores the Range

      st, hdr, _ = _get(url, {"Range": f"bytes={len(blob)}-"})
      assert st == 416 and _hdr(hdr, "Content-Range") == f"bytes */{len(blob)}"

      req = urllib.request.Request(url, method="HEAD")
      with urllib.request.urlopen(req, timeout=5) as r:
          assert r.status == 200
          assert r.headers.get("Content-Length") == str(len(blob))
          assert len(r.read()) == 0

  def test_locked_collection_file_stays_private_single_header(file_server):
      """A non-public collection's file: superuser-token GET serves with Cache-Control:
      private (tenancy/cacheability invariant is requester-independent), exactly once."""
      base = file_server
      token, rid, stored = _setup_record(base, b"secret-bytes", view_rule="")
      url = f"{base}/api/files/media/{rid}/{stored}"
      st, _, _ = _get(url)
      assert st == 404  # blank rule = Locked; anonymous never sees it
      st, hdr, body = _get(url, {"Authorization": f"Bearer {token}"})
      assert st == 200 and body == b"secret-bytes"
      ccs = hdr.get_all("Cache-Control") or []
      assert ccs == ["private"]
  ```
- [ ] **Step 5: Run the browser-suite slice** — `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_file_range.py tests/admin/test_file_upload.py tests/admin/test_static_files.py -q` — expect all pass (upload regression + static untouched + the new matrix).
- [ ] **Step 6: Docs.** In `docs/api.md` §Files (after "### Content handling", ~line 1027) add a new subsection, and mirror it verbatim into `site/src/content/docs/api.md`:
  ```markdown
  ### Range and conditional requests

  File downloads support HTTP range and conditional requests (0.10.0):

  - `Accept-Ranges: bytes` on every 200/206. A single `Range: bytes=a-b`, `bytes=a-`,
    or `bytes=-n` answers `206 Partial Content` with `Content-Range`; a syntactically
    multi-range request is served as a full `200` (RFC-permitted). An unsatisfiable
    range answers `416` with `Content-Range: bytes */<size>`.
  - Every response carries a strong `ETag` derived from the stored file's identity
    (stored names are content-immutable — an update mints a new name), so
    `If-None-Match` revalidation answers `304`. `If-Range` requires an exact strong
    match, otherwise the range is ignored.
  - `HEAD` mirrors `GET` (status, headers, `Content-Length`) with no body.
  - `?download` and `?token=` compose with `Range` unchanged.
  - **File tokens vs. seeking:** `ZIGBASE_FILE_TOKEN_TTL` defaults to 120 s; a video
    player seeking via `?token=` URLs gets 404s once the token expires mid-playback.
    Use cookie/bearer auth for long media, or re-mint tokens per seek.
  ```
  Run `cd site && mise exec node@24 -- npm run build` — expect success.
- [ ] **Step 7: fragment `changelog.d/files-range-record.md`:**
  ```markdown
  ### Breaking
  - Custom-route surface: `http.Response.file_path` is now `Response.file` (`.file_path = p` → `.file = .{ .path = p }`). Plain-path delegation behavior is unchanged; the new optional `offset`/`len` window enables handler-planned partial responses.

  ### Features
  - Record-file downloads (`GET /api/files/:col/:rec/:name`) support HTTP Range and conditional requests: `206` with `Content-Range` for `bytes=a-b` / `bytes=a-` / `bytes=-n`, `Accept-Ranges: bytes`, a strong content-immutable `ETag` with `304` revalidation, `If-Range`, `416` for unsatisfiable ranges, and `HEAD` parity.

  ### Fixes
  - Record-file downloads no longer emit a duplicate `Cache-Control` header (the handler's per-collection value used to be joined on the wire by facil.io's global `max-age=3600`).
  ```
- [ ] **Step 8: Commit, push, open PR1** (verify branch freshness vs `origin/main` first):
  ```bash
  git add src/api/files.zig tests/admin/test_file_range.py changelog.d/files-range-record.md docs/api.md site/src/content/docs/api.md
  git commit -m "feat(files): Range/conditional record-file downloads via owned http_sendfile path (fixes duplicate Cache-Control)"
  ```
  PR title: `feat(files): HTTP Range + conditional requests for record-file downloads`. Before merge: full `mise exec python@3.13 -- python -m pytest tests/admin -q` locally.

---

# PR 2 — Static serving: Range shim, Cache-Control knob, embedded Range, SPA-shell no-cache (branch `feat/static-range-cache`)

### Task 4: Range-normalization shim + owned 416 + `Vary` + request-header write-back plumbing

**Files:**
- Modify: `src/static_files.zig` (`normalizeRange` pure helper + `serveDir` shim + `Vary`), tests
- Modify: `src/http.zig` (`raw_header_set_fn` + `setRequestHeader` — mirrors the existing `raw_header_fn` lookup pattern at http.zig:40-43)
- Modify: `src/server.zig` (`zapHeaderSet` + wiring in `onRequest` next to `ctx.raw_header_fn = zapHeaderLookup;`)

**Interfaces:**
- Consumes: Task 1 `serve_file.parseRange`.
- Produces: `static_files.normalizeRange(alloc, raw, size) !?RangeNorm` with `pub const RangeNorm = union(enum) { rewrite: []const u8, unsatisfiable }`; `RequestCtx.setRequestHeader(name, value) void` (no-op when unwired — pure-handler unit tests assert via a stub). Dir-mode `extra_headers` becomes `[nosniff, Vary: Accept-Encoding]`.

- [ ] **Step 1: `src/http.zig`** — below `raw_header_fn` (line 43) add:
  ```zig
      /// Live request-header SETTER (lowercase name), wired by server.zig onto facil.io's
      /// request-header hash (replace semantics — fiobj_hash_set frees the old value).
      /// Used by the static Range-normalization shim (§A.2) to rewrite the request's
      /// Range header into the one form the vendored facil.io parses correctly, BEFORE
      /// delegating to facil.io's sendFile. No-op when unwired (unit tests stub it).
      raw_header_set_fn: ?*const fn (*anyopaque, name: []const u8, value: []const u8) void = null,
  ```
  and next to `header()`:
  ```zig
      /// Replace a request header on the live request (see raw_header_set_fn). No-op
      /// when no live request is wired.
      pub fn setRequestHeader(self: *const RequestCtx, name: []const u8, value: []const u8) void {
          if (self.raw_header_set_fn) |f| f(self.raw_header_ctx.?, name, value);
      }
  ```
- [ ] **Step 2: `src/server.zig`** — next to `zapHeaderLookup` add:
  ```zig
  /// §A.2 write-back: replace a REQUEST header in facil.io's header hash.
  /// fiobj_hash_set (zap fio.zig:137) dups key+value on insert and frees any replaced
  /// value; it consumes our value reference, and we free our key reference ourselves.
  fn zapHeaderSet(ctx: *anyopaque, name: []const u8, value: []const u8) void {
      const rp: *zap.Request = @ptrCast(@alignCast(ctx));
      const key = zap.fio.fiobj_str_new(name.ptr, name.len);
      const val = zap.fio.fiobj_str_new(value.ptr, value.len);
      _ = zap.fio.fiobj_hash_set(rp.h.*.headers, key, val);
      zap.fio.fiobj_free_wrapped(key);
  }
  ```
  and in `onRequest`, directly after `ctx.raw_header_fn = zapHeaderLookup;` (line ~842):
  ```zig
      ctx.raw_header_set_fn = zapHeaderSet;
  ```
- [ ] **Step 3: `src/static_files.zig`** — add the pure helper (near `sanitize`):
  ```zig
  pub const RangeNorm = union(enum) { rewrite: []const u8, unsatisfiable };

  /// §A.2: rewrite the REQUEST's Range header value into the canonical, closed,
  /// in-bounds `bytes=a-b` form — the ONLY form the vendored facil.io parses correctly
  /// (http.c ~507-560: `bytes=X-` falls through to a 200, `bytes=-n` computes an offset
  /// past EOF and prints a negative into Content-Range, an overlong `a-b` produces a
  /// bogus length, `a >= size` yields 200 instead of 416). Returns:
  ///   .rewrite       — write this back over the request's Range header, then delegate;
  ///                    facil.io's own machinery then produces the 206/Content-Range.
  ///   .unsatisfiable — a >= size or "-0": the CALLER answers 416 (facil.io's
  ///                    alternative is a WRONG 200 — the one status it can't emit).
  ///   null           — leave untouched (already the canonical in-bounds form,
  ///                    malformed, multi-range, non-bytes): facil.io ignores -> 200,
  ///                    RFC-permitted. A fixed upstream parser makes rewrites no-ops.
  pub fn normalizeRange(alloc: std.mem.Allocator, raw: []const u8, size: u64) !?RangeNorm {
      return switch (serve_file.parseRange(raw, size)) {
          .none => null,
          .unsatisfiable => .unsatisfiable,
          .slice => |s| blk: {
              const canonical = try std.fmt.allocPrint(alloc, "bytes={d}-{d}", .{ s.offset, s.offset + s.len - 1 });
              // Already exactly what facil.io handles? Don't touch the request.
              if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t"), canonical)) break :blk null;
              break :blk .{ .rewrite = canonical };
          },
      };
  }
  ```
- [ ] **Step 4: wire the shim into `serveDir`** — insert after the F10 `withinRoot` check (line ~448) and BEFORE building the response:
  ```zig
      // §A.2 shim: normalize the Range header against the size of the file facil.io
      // WILL serve — mirroring its .gz sidecar probe (http.c:449-470: Accept-Encoding
      // contains "gzip" -> stat "<path>.gz") — then keep delegating. If-Range ORDERING
      // is preserved: the shim only edits the header VALUE — facil.io still compares
      // If-Range against ITS OWN etag and deletes the Range header itself on a
      // mismatch, exactly as today, so a REWRITE is always safe (and an If-Range video
      // seek is precisely the case that needs it). Only the OWNED 416 is gated on
      // If-Range being ABSENT: with one present we cannot know whether facil.io would
      // ignore the Range, so an unsatisfiable form then passes through untouched
      // (facil.io's 200 — today's behavior for that corner).
      const raw_range = ctx.header("range") orelse "";
      if (raw_range.len > 0) {
          var size = st.size;
          if (ctx.header("accept-encoding")) |ae| {
              if (std.mem.indexOf(u8, ae, "gzip") != null and !std.mem.endsWith(u8, full, ".gz")) {
                  const gz = try std.fmt.allocPrint(ctx.allocator, "{s}.gz", .{full});
                  if (std.Io.Dir.cwd().statFile(io, gz, .{})) |gst| {
                      if (gst.kind == .file) size = gst.size; // one extra stat, worst case
                  } else |_| {}
              }
          }
          if (try normalizeRange(ctx.allocator, raw_range, size)) |norm| switch (norm) {
              .rewrite => |v| ctx.setRequestHeader("range", v),
              .unsatisfiable => if (ctx.header("if-range") == null) {
                  // Tiny owned response — the one static status facil.io cannot emit.
                  const hs416 = try ctx.allocator.dupe(http.Header, &.{
                      .{ .name = "Content-Range", .value = try std.fmt.allocPrint(ctx.allocator, "bytes */{d}", .{size}) },
                      nosniff,
                  });
                  return .{ .status = 416, .body = "", .content_type = mime.fromExtension(full), .extra_headers = hs416 };
              },
          };
      }
  ```
  and change the response headers two lines below from one header to two (shared-cache correctness for the `.gz` sidecar; facil.io never sets `Vary`, so no duplicate is possible):
  ```zig
      const hs = try ctx.allocator.alloc(http.Header, 2);
      hs[0] = nosniff;
      hs[1] = .{ .name = "Vary", .value = "Accept-Encoding" };
  ```
  Update the two existing dir-mode tests asserting `extra_headers.len == 1` / `[0].name == "X-Content-Type-Options"` (lines ~660-661 and ~1040-1041) to expect 2 headers with `Vary`/`Accept-Encoding` at index 1.
- [ ] **Step 5: tests** (in `static_files.zig`):
  ```zig
  test "normalizeRange matrix (§A.2): open/suffix/overlong rewritten; in-bounds/malformed/multi passthrough; 416 forms" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      // rewrites into the canonical closed form
      try std.testing.expectEqualStrings("bytes=200-999", (try normalizeRange(a, "bytes=200-", 1000)).?.rewrite);
      try std.testing.expectEqualStrings("bytes=900-999", (try normalizeRange(a, "bytes=-100", 1000)).?.rewrite);
      try std.testing.expectEqualStrings("bytes=0-999", (try normalizeRange(a, "bytes=-5000", 1000)).?.rewrite); // n >= size
      try std.testing.expectEqualStrings("bytes=900-999", (try normalizeRange(a, "bytes=900-5000", 1000)).?.rewrite); // clamp
      // unsatisfiable -> caller's 416
      try std.testing.expect((try normalizeRange(a, "bytes=1000-", 1000)).? == .unsatisfiable);
      try std.testing.expect((try normalizeRange(a, "bytes=-0", 1000)).? == .unsatisfiable);
      // passthrough (null): facil.io already correct, or RFC-permitted ignore
      try std.testing.expect((try normalizeRange(a, "bytes=0-99", 1000)) == null); // in-bounds a-b
      try std.testing.expect((try normalizeRange(a, "bytes=0-99,200-", 1000)) == null); // multi
      try std.testing.expect((try normalizeRange(a, "garbage", 1000)) == null);
      try std.testing.expect((try normalizeRange(a, "items=0-5", 1000)) == null);
  }

  test "dir shim: open-ended Range is rewritten via setRequestHeader; unsatisfiable answers owned 416; gz sidecar drives the size" {
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();
      try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.bin", .data = "x" ** 1000 });
      // sidecar SMALLER than the base file, so a sidecar-selected rewrite is observable
      try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.bin.gz", .data = "z" ** 100 });
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
      const src = Source{ .dir = root };

      const Capture = struct {
          var name_buf: [64]u8 = undefined;
          var value_buf: [64]u8 = undefined;
          var name: []const u8 = "";
          var value: []const u8 = "";
          fn set(_: *anyopaque, n: []const u8, v: []const u8) void {
              name = name_buf[0..n.len];
              @memcpy(name_buf[0..n.len], n);
              value = value_buf[0..v.len];
              @memcpy(value_buf[0..v.len], v);
          }
      };
      var dummy: u8 = 0;

      // Open-ended seek on the base file: rewritten to the closed in-bounds form.
      const rh = [_]http.Param{.{ .key = "range", .value = "bytes=200-" }};
      var ctx = http.RequestCtx{ .method = .GET, .path = "/big.bin", .allocator = a, .headers = &rh, .raw_header_ctx = &dummy, .raw_header_set_fn = Capture.set };
      const r = (try serve(std.testing.io, &ctx, src, .{})).?;
      try std.testing.expectEqual(@as(u16, 200), r.status); // still DELEGATED (facil.io does the 206)
      try std.testing.expect(r.file != null);
      try std.testing.expectEqualStrings("range", Capture.name);
      try std.testing.expectEqualStrings("bytes=200-999", Capture.value);

      // Accept-Encoding gzip: the SIDECAR's size (100) drives the rewrite.
      Capture.name = "";
      const rh_gz = [_]http.Param{ .{ .key = "range", .value = "bytes=50-" }, .{ .key = "accept-encoding", .value = "gzip, br" } };
      var ctx_gz = http.RequestCtx{ .method = .GET, .path = "/big.bin", .allocator = a, .headers = &rh_gz, .raw_header_ctx = &dummy, .raw_header_set_fn = Capture.set };
      _ = (try serve(std.testing.io, &ctx_gz, src, .{})).?;
      try std.testing.expectEqualStrings("bytes=50-99", Capture.value);

      // Unsatisfiable: the shim's OWNED 416 with Content-Range: bytes */N.
      const rh_bad = [_]http.Param{.{ .key = "range", .value = "bytes=5000-" }};
      var ctx_bad = http.RequestCtx{ .method = .GET, .path = "/big.bin", .allocator = a, .headers = &rh_bad, .raw_header_ctx = &dummy, .raw_header_set_fn = Capture.set };
      const r416 = (try serve(std.testing.io, &ctx_bad, src, .{})).?;
      try std.testing.expectEqual(@as(u16, 416), r416.status);
      try std.testing.expectEqualStrings("Content-Range", r416.extra_headers[0].name);
      try std.testing.expectEqualStrings("bytes */1000", r416.extra_headers[0].value);

      // If-Range present: the REWRITE still happens (facil.io deletes the Range itself
      // on an If-Range mismatch — ordering preserved; a matching If-Range seek is the
      // case that needs the rewrite)...
      Capture.name = "";
      Capture.value = "";
      const rh_ifr = [_]http.Param{ .{ .key = "range", .value = "bytes=200-" }, .{ .key = "if-range", .value = "\"whatever\"" } };
      var ctx_ifr = http.RequestCtx{ .method = .GET, .path = "/big.bin", .allocator = a, .headers = &rh_ifr, .raw_header_ctx = &dummy, .raw_header_set_fn = Capture.set };
      _ = (try serve(std.testing.io, &ctx_ifr, src, .{})).?;
      try std.testing.expectEqualStrings("bytes=200-999", Capture.value);
      // ...but an UNSATISFIABLE range with If-Range present is passed through untouched
      // (no owned 416 — facil.io may be about to ignore the Range entirely).
      const rh_ifr_bad = [_]http.Param{ .{ .key = "range", .value = "bytes=5000-" }, .{ .key = "if-range", .value = "\"whatever\"" } };
      var ctx_ifr_bad = http.RequestCtx{ .method = .GET, .path = "/big.bin", .allocator = a, .headers = &rh_ifr_bad, .raw_header_ctx = &dummy, .raw_header_set_fn = Capture.set };
      const r_ifr_bad = (try serve(std.testing.io, &ctx_ifr_bad, src, .{})).?;
      try std.testing.expectEqual(@as(u16, 200), r_ifr_bad.status); // delegated, not 416
  }
  ```
- [ ] **Step 6: Run** `mise exec zig@0.16.0 -- zig build test --summary all` — expect PASS.
- [ ] **Step 7: Commit**
  ```bash
  git add src/http.zig src/server.zig src/static_files.zig
  git commit -m "feat(static): Range-normalization shim + owned 416 + Vary on dir mode (facil.io keeps serving)"
  ```

---

### Task 5: Tunable static Cache-Control — comptime key + flag + env + PRE_START FIOBJ swap

**Files:**
- Modify: `src/config.zig` (field + env line + test)
- Modify: `src/cli.zig` (`ServeArgs`/`ParseOpts`/parse + test)
- Modify: `src/framework.zig` (allowed-keys list, comptime validation + lowering, `ServeOpts` field, `loadCfg`, `serveImpl` resolution, `--help` text)
- Modify: `src/app.zig` (`static_cache_control` field)
- Modify: `src/server.zig` (externs + `replaceStaticMaxAge` + registration in `listen()`)

**Interfaces:**
- Produces: `App(.{ .static_cache_control = "…" })` comptime default (validated: non-empty, ≤ 256 bytes, no CR/LF — `@compileError` on violation); runtime `--static-cache-control <value>` flag + `ZIGBASE_STATIC_CACHE_CONTROL` env (flag wins over env, both win over comptime — matching `--serve-static`/`cfg.static_dir` precedence); `app.App.static_cache_control: ?[]const u8` (null = knob unset → callback never registered → facil.io's stock `max-age=3600` byte-identical). Consumed by Task 6 (embedded/SPA) and Task 7 (e2e/docs).

- [ ] **Step 1: `src/config.zig`** — add after `static_dir` (line 59):
  ```zig
      // Cache-Control VALUE for static responses (§C). "" = unset: the comptime
      // `.static_cache_control` default applies if configured, else facil.io's stock
      // `max-age=3600` for dir mode / the same default for embedded assets. Applies to
      // STATIC serving only — record-file downloads keep their authorization-derived
      // Cache-Control (the tenancy invariant in api/files.zig, NEVER knob-controlled).
      // Env: ZIGBASE_STATIC_CACHE_CONTROL. Validated at startup (CR/LF, length <= 256).
      static_cache_control: []const u8 = "",
  ```
  and in `load()` next to the `ZIGBASE_SENTRY_DSN` line:
  ```zig
      if (getter.get("ZIGBASE_STATIC_CACHE_CONTROL")) |v| cfg.static_cache_control = v;
  ```
  plus a test:
  ```zig
  test "static_cache_control defaults empty, overridable via env" {
      const G0 = struct {
          fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
      };
      try std.testing.expectEqualStrings("", (try Config.load(G0{})).static_cache_control);
      const G1 = struct {
          fn get(_: @This(), key: []const u8) ?[]const u8 {
              if (std.mem.eql(u8, key, "ZIGBASE_STATIC_CACHE_CONTROL")) return "public, max-age=86400, immutable";
              return null;
          }
      };
      try std.testing.expectEqualStrings("public, max-age=86400, immutable", (try Config.load(G1{})).static_cache_control);
  }
  ```
- [ ] **Step 2: `src/cli.zig`** — `ServeArgs` gains `static_cache_control: ?[]const u8 = null,`; `ParseOpts` gains:
  ```zig
      /// --static-cache-control is rejected as unknown when static serving is disabled
      /// at comptime (`.static_files = .disabled`), mirroring the --serve-static gate.
      /// Unlike serve_static it stays available in .dir/.embedded modes (the knob
      /// applies to comptime-configured sources too).
      static_cache_control: bool = true,
  ```
  In the `serve` arg loop (next to the `--serve-static` branch at line ~224):
  ```zig
          } else if (popts.static_cache_control and std.mem.eql(u8, a, "--static-cache-control")) {
              i += 1;
              if (i >= args.len) return ParseError.MissingValue;
              sa.static_cache_control = args[i];
  ```
  Tests:
  ```zig
  test "--static-cache-control parses, requires a value, and is gated by ParseOpts" {
      const c = try parse(&.{ "serve", "--static-cache-control", "public, max-age=86400" }, .{});
      try std.testing.expectEqualStrings("public, max-age=86400", c.serve.static_cache_control.?);
      try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--static-cache-control" }, .{}));
      try std.testing.expectError(ParseError.UnknownFlag, parse(
          &.{ "serve", "--static-cache-control", "x" },
          .{ .static_cache_control = false },
      ));
  }
  ```
- [ ] **Step 3: `src/framework.zig`** — four edits:
  1. Add `"static_cache_control"` to the `allowed` tuple (line 277).
  2. Add the shared validator near `validateRoutePattern`:
     ```zig
     /// §C.2: one rule for the comptime default AND the runtime override — non-empty,
     /// <= 256 bytes, CR/LF-free (header-injection guard; the value goes on the wire
     /// verbatim as the Cache-Control header value).
     fn validCacheControl(v: []const u8) bool {
         if (v.len == 0 or v.len > 256) return false;
         for (v) |c| if (c == '\r' or c == '\n') return false;
         return true;
     }
     ```
  3. Inside `App(cfg)`, next to where `.static_files` is lowered into the comptime static mode (search `static_mode` in the returned struct), add:
     ```zig
         /// §C.2 comptime DEFAULT for the static Cache-Control knob (null = not configured).
         pub const static_cache_control: ?[]const u8 = blk: {
             if (!@hasField(@TypeOf(cfg), "static_cache_control")) break :blk null;
             const v: []const u8 = cfg.static_cache_control;
             if (!validCacheControl(v))
                 @compileError(".static_cache_control must be a non-empty, CR/LF-free Cache-Control value of at most 256 bytes");
             break :blk v;
         };
     ```
     and thread it into the `ServeOpts` literal the App builds for `serveImpl` (search for `.static_routes =` in the same construction): `.static_cache_control = static_cache_control,`. Also pass the parser gate where `cli.ParseOpts` is constructed (search `ParseOpts{`): `.static_cache_control = (comptime std.meta.activeTag(static mode expr) != .disabled)` — mirror exactly how `.serve_static` is computed there, with `.disabled` as the only rejecting mode.
  4. `ServeOpts` gains:
     ```zig
         /// §C.2: comptime default for the static Cache-Control knob; runtime flag/env override it.
         static_cache_control: ?[]const u8 = null,
     ```
     `loadCfg` gains (next to `if (sa.serve_static)`): `if (sa.static_cache_control) |v| cfg.static_cache_control = v;`
     `serveImpl` — after the static-source resolution block (line ~1864) add:
     ```zig
         // §C.2: flag/env (cfg) wins over the comptime default; unset everywhere = null,
         // and the PRE_START callback is then never registered — facil.io's stock
         // max-age=3600 stays byte-identical to today.
         const static_cc: ?[]const u8 = if (cfg.static_cache_control.len > 0)
             cfg.static_cache_control
         else
             opts.static_cache_control;
         if (static_cc) |v| {
             if (!validCacheControl(v)) {
                 std.log.err("refusing to start: ZIGBASE_STATIC_CACHE_CONTROL / --static-cache-control is invalid (empty, longer than 256 bytes, or contains CR/LF)", .{});
                 return error.InvalidStaticCacheControl;
             }
         }
     ```
     and add `.static_cache_control = static_cc,` to the `app_mod.App{…}` literal.
     Also add the flag to `printServeUsage`/`printUsage` beside `--serve-static` (gate the line on nothing — it's mode-independent except `.disabled`; keep the help text one line: `--static-cache-control V  Cache-Control value for static responses (also ZIGBASE_STATIC_CACHE_CONTROL). [default max-age=3600]`).
- [ ] **Step 4: `src/app.zig`** — next to `static_source` (line 45): `static_cache_control: ?[]const u8 = null,`
- [ ] **Step 5: `src/server.zig`** — the §C.1 mechanism, above the `Server` struct:
  ```zig
  // ── §C.1: tunable static Cache-Control via facil.io's OWN state-callback API ────────
  // There is no facil.io settings field and no compile-time define for the static
  // max-age; the value is a runtime FIOBJ created by http_lib_init at
  // FIO_CALL_ON_INITIALIZE (vendored http_internal.c:223) and held in a NON-static C
  // global (http_internal.h:81). We link the same compiled facil.io, so declare the
  // global + the callback API and swap the FIOBJ exactly once at FIO_CALL_PRE_START —
  // which fio_start forces strictly AFTER ON_INITIALIZE (fio.c:3925), so the object
  // exists and our replacement is never clobbered. facil.io's header-emission path is
  // untouched: http_sendfile2 keeps fiobj_dup-ing this global (http.c:484); it just
  // dups our value. Scope (documented): the global affects EVERY http_sendfile2
  // response process-wide — in ZigBase that is exactly dir-mode static (record files
  // left this path in §B), but a consumer route calling r.sendFile directly inherits
  // it too; that IS the knob. Single process; PRE_START runs in the master before any
  // worker forks, so the swap is fork-safe.
  extern var HTTP_HVALUE_MAX_AGE: zap.fio.FIOBJ;
  extern fn fio_state_callback_add(
      event: c_int,
      func: ?*const fn (?*anyopaque) callconv(.c) void,
      arg: ?*anyopaque,
  ) void;
  /// callback_type_e ordinal (vendored fio.h:1578-1608): ON_INITIALIZE=0, PRE_START=1.
  const FIO_CALL_PRE_START: c_int = 1;
  /// The knob value; static lifetime (points into env/argv/comptime memory that
  /// outlives the server — set once in listen(), read once in the callback).
  var static_cache_control_value: []const u8 = "";

  fn replaceStaticMaxAge(_: ?*anyopaque) callconv(.c) void {
      zap.fio.fiobj_free_wrapped(HTTP_HVALUE_MAX_AGE);
      HTTP_HVALUE_MAX_AGE = zap.fio.fiobj_str_new(static_cache_control_value.ptr, static_cache_control_value.len);
  }
  ```
  and in `Server.listen()` before `try listener.listen();`:
  ```zig
          if (self.app.static_cache_control) |v| {
              static_cache_control_value = v;
              fio_state_callback_add(FIO_CALL_PRE_START, replaceStaticMaxAge, null);
          }
  ```
- [ ] **Step 6: Run** `mise exec zig@0.16.0 -- zig build test --summary all` (validator + parser + config tests). Then a manual smoke: `mise exec zig@0.16.0 -- zig build && ./zig-out/bin/zigbase serve --insecure-cookies --data-dir /tmp/zbcc --serve-static /tmp/pub --static-cache-control "public, max-age=86400" &` with a file in `/tmp/pub`, then `curl -sI localhost:8090/<file> | grep -i cache-control` — expect exactly `public, max-age=86400`; re-run WITHOUT the flag — expect `max-age=3600`. Kill the server.
- [ ] **Step 7: Commit**
  ```bash
  git add src/config.zig src/cli.zig src/framework.zig src/app.zig src/server.zig
  git commit -m "feat(static): tunable Cache-Control knob (comptime + --static-cache-control + env) via facil.io PRE_START FIOBJ swap"
  ```

---

### Task 6: Embedded-static Range + Cache-Control; SPA fallback shell `no-cache` (embedded + dir)

**Files:**
- Modify: `src/static_files.zig` (`Fallback.cache_control`, `serveEmbedded` planner rewrite, `serveRel`/`serve` cc threading, `serveShellOwned` for dir tier-1) + tests
- Modify: `src/server.zig` (thread `self.app.static_cache_control` into the `Fallback` literal at line ~879)

**Interfaces:**
- Consumes: Task 1 planner (`serve_file.plan`), Task 5 `app.static_cache_control`.
- Produces: embedded assets emit `Cache-Control: <knob orelse "max-age=3600">` + `Accept-Ranges: bytes` + single-range 206 by subslicing the embedded bytes (CRC32 ETag format UNCHANGED — existing Playwright assertions keep passing); the Tier-1 SPA fallback shell always emits `Cache-Control: no-cache` (embedded: CRC32 ETag; dir: owned sendBody with stat-derived strong ETag `"<hex size>-<hex mtime-seconds>"`). Tier-2 `static_routes` targets and dir-mode direct hits keep knob/default semantics.

- [ ] **Step 1: `Fallback` gains the knob** (static_files.zig:56-60):
  ```zig
      /// §C.2: the resolved static Cache-Control knob (app.static_cache_control).
      /// null = unset. Embedded assets emit `orelse "max-age=3600"`; dir-mode direct
      /// hits get the value via the facil.io global swap instead (server.zig §C.1).
      cache_control: ?[]const u8 = null,
  ```
  and `server.zig`'s static call site (line ~879) adds `.cache_control = self.app.static_cache_control,` to the `.{ .routes = …, .spa_roots = …, .spa_marker_enabled = … }` literal.
- [ ] **Step 2: rewrite `serveEmbedded`** (planner-driven; §A.4 — this path never touched facil.io's file machinery, so improving it replaces nothing):
  ```zig
  fn serveEmbedded(ctx: *http.RequestCtx, files: []const StaticFile, rel: []const u8, cache_control: []const u8) !?http.Response {
      const hit = blk: {
          if (rel.len == 0) break :blk findEmbedded(files, "index.html");
          if (findEmbedded(files, rel)) |f| break :blk f;
          const idx = try std.fmt.allocPrint(ctx.allocator, "{s}/index.html", .{rel});
          break :blk findEmbedded(files, idx);
      } orelse return null;
      const content_type = mime.fromExtension(hit.path);
      // §A.4: reuse the §B planner over the embedded bytes. ETag format unchanged
      // (build-time CRC32, quoted) — revalidation and the Playwright assertions hold.
      const p = try serve_file.plan(ctx.allocator, .{
          .size = hit.bytes.len,
          .etag = hit.etag,
          .range = ctx.header("range") orelse "",
          .if_none_match = ctx.if_none_match,
          .if_range = ctx.header("if-range") orelse "",
          .head = ctx.method == .HEAD,
      });
      var hs: std.ArrayList(http.Header) = .empty;
      try hs.appendSlice(ctx.allocator, &.{
          .{ .name = "ETag", .value = hit.etag },
          nosniff,
          .{ .name = "Cache-Control", .value = cache_control },
      });
      if (p.status == 304) return notModified(content_type, try hs.toOwnedSlice(ctx.allocator));
      try hs.append(ctx.allocator, .{ .name = "Accept-Ranges", .value = "bytes" });
      if (p.content_range) |cr| try hs.append(ctx.allocator, .{ .name = "Content-Range", .value = cr });
      if (p.status == 416) return .{ .status = 416, .body = "", .content_type = content_type, .extra_headers = try hs.toOwnedSlice(ctx.allocator) };
      return .{
          .status = p.status,
          .body = hit.bytes[@intCast(p.offset)..@intCast(p.offset + p.len)],
          .content_type = content_type,
          .extra_headers = try hs.toOwnedSlice(ctx.allocator),
      };
  }
  ```
  (HEAD keeps today's serve-the-plan-and-let-zap-transport behavior on this body path — unchanged semantics.)
- [ ] **Step 3: thread cc through `serveRel` and `serve`:**
  ```zig
  fn serveRel(io: std.Io, ctx: *http.RequestCtx, source: Source, rel: []const u8, cache_control: []const u8) !?http.Response {
      return switch (source) {
          .none => unreachable, // gated in serve()
          .embedded => |files| serveEmbedded(ctx, files, rel, cache_control),
          .dir => |root| serveDir(io, ctx, root, rel), // dir-mode CC = the facil.io global (§C.1)
      };
  }
  ```
  In `serve()`: compute `const cc_default: []const u8 = fb.cache_control orelse "max-age=3600";` right after the api-guard; direct hit + Tier-2 route calls pass `cc_default`; the Tier-1 **embedded** branch passes `"no-cache"`:
  ```zig
      .embedded => {
          if (matchSpaRoot(fb.spa_roots, rel)) |root| {
              const shell = if (root.len == 0)
                  "index.html"
              else
                  try std.fmt.allocPrint(ctx.allocator, "{s}/index.html", .{root});
              // §C.3: a FALLBACK-served shell is always no-cache — a cached stale shell
              // after a redeploy references hashed assets that no longer exist, breaking
              // deep links. Direct hits on the same file still get the knob value.
              return serveRel(io, ctx, source, shell, "no-cache");
          }
          return null;
      },
  ```
  and the Tier-1 **dir** branch becomes the owned shell:
  ```zig
      .dir => |root| {
          const shell = (try resolveSpaMarkerDirLive(io, ctx.allocator, root, rel)) orelse return null;
          return serveShellOwned(io, ctx, root, shell);
      },
  ```
- [ ] **Step 4: add `serveShellOwned`** (below `serveDir`):
  ```zig
  /// §C.3 (dir source, Tier-1 fallback only): serve the SPA shell OWNED — read the file
  /// and sendBody with `Cache-Control: no-cache` + a stat-derived strong ETag
  /// ("<hex size>-<hex mtime-seconds>") so revalidation is one cheap 304. Per-response
  /// Cache-Control is impossible through http_sendfile2 (§B.1 items 1-2), and the
  /// alternative (knob value on the fallback shell) breaks deployments — this is a
  /// deliberate, tiny widening of the owned surface, confined to one small HTML file.
  /// F10 still applies: the canonicalized shell must live under the canonicalized root.
  fn serveShellOwned(io: std.Io, ctx: *http.RequestCtx, root: []const u8, shell_rel: []const u8) !?http.Response {
      const full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ root, shell_rel });
      const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch return null;
      if (st.kind != .file) return null;
      const real_root = std.Io.Dir.cwd().realPathFileAlloc(io, root, ctx.allocator) catch return null;
      const real_full = std.Io.Dir.cwd().realPathFileAlloc(io, full, ctx.allocator) catch return null;
      if (!withinRoot(real_root, real_full)) return null;
      const mtime_s: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
      const etag = try std.fmt.allocPrint(ctx.allocator, "\"{x}-{x}\"", .{ st.size, @as(u64, @bitCast(mtime_s)) });
      const hs = try ctx.allocator.dupe(http.Header, &.{
          .{ .name = "ETag", .value = etag },
          nosniff,
          .{ .name = "Cache-Control", .value = "no-cache" },
      });
      if (serve_file.etagMatches(ctx.if_none_match, etag)) return notModified("text/html; charset=utf-8", hs);
      const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, ctx.allocator, .limited(16 << 20)) catch return null;
      return .{ .status = 200, .body = bytes, .content_type = "text/html; charset=utf-8", .extra_headers = hs };
  }
  ```
- [ ] **Step 5: update every `serveRel(` call site** for the new parameter (`git grep -n "serveRel(" src/static_files.zig`): the direct-hit call and the Tier-2 loop pass `cc_default`. Update existing embedded tests that assert `extra_headers.len == 2` / header ordering (lines ~593-595, 613-614) — embedded 200s now carry 4 headers `[ETag, nosniff, Cache-Control, Accept-Ranges]` (index 0 stays ETag, so the exemplar assertions on `[0]` survive); embedded 304s carry 3. REWRITE the test `"spa fallback: dir-mode fallback streams via file_path (facil.io owns caching)"` (~line 1025) — the dir shell is now OWNED:
  ```zig
  test "spa fallback (dir): shell is served OWNED — no-cache, stat ETag, 304 revalidation (§C.3)" {
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();
      try tmp.dir.createDirPath(std.testing.io, "app");
      try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/index.html", .data = "<h1>dir shell</h1>" });
      try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/.spa", .data = "" });
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
      var deep = http.RequestCtx{ .method = .GET, .path = "/app/orders/1234", .allocator = arena.allocator() };
      const r = (try serve(std.testing.io, &deep, Source{ .dir = root }, .{ .spa_marker_enabled = true })).?;
      try std.testing.expectEqual(@as(u16, 200), r.status);
      try std.testing.expect(r.file == null); // OWNED body, not a sendFile delegation
      try std.testing.expectEqualStrings("<h1>dir shell</h1>", r.body);
      try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
      try std.testing.expectEqualStrings("Cache-Control", r.extra_headers[2].name);
      try std.testing.expectEqualStrings("no-cache", r.extra_headers[2].value);
      // revalidation: 304 on the stat ETag
      var cond = http.RequestCtx{ .method = .GET, .path = "/app/orders/1234", .allocator = arena.allocator(), .if_none_match = r.extra_headers[0].value };
      try std.testing.expectEqual(@as(u16, 304), (try serve(std.testing.io, &cond, Source{ .dir = root }, .{ .spa_marker_enabled = true })).?.status);
  }
  ```
  Other dir Tier-1 tests asserting `.file.?.path` endings for the shell (`spa live (dir)` group, lines ~1050-1139) switch to asserting `r.body` contents / `r.file == null` — the resolution SEMANTICS (which shell, deepest-wins, cap) are unchanged, only the transport differs. Direct-hit dir tests are untouched.
  Also add the new embedded coverage:
  ```zig
  test "embedded: Range 206 subslice + 416 + Cache-Control default and knob (§A.4/§C.2)" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const src = Source{ .embedded = &fixture };
      // knob unset: embedded now sends the max-age=3600 default (was: NO Cache-Control)
      var plain = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = a };
      const rp = (try serve(std.testing.io, &plain, src, .{})).?;
      try std.testing.expectEqualStrings("Cache-Control", rp.extra_headers[2].name);
      try std.testing.expectEqualStrings("max-age=3600", rp.extra_headers[2].value);
      try std.testing.expectEqualStrings("Accept-Ranges", rp.extra_headers[3].name);
      // knob set: the configured value rides through Fallback.cache_control
      var knob = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = a };
      const rk = (try serve(std.testing.io, &knob, src, .{ .cache_control = "public, max-age=86400" })).?;
      try std.testing.expectEqualStrings("public, max-age=86400", rk.extra_headers[2].value);
      // 206 subslice ("console.log(1)" is 14 bytes)
      const rh = [_]http.Param{.{ .key = "range", .value = "bytes=8-" }};
      var ranged = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = a, .headers = &rh };
      const r206 = (try serve(std.testing.io, &ranged, src, .{})).?;
      try std.testing.expectEqual(@as(u16, 206), r206.status);
      try std.testing.expectEqualStrings("log(1)", r206.body);
      var got_cr = false;
      for (r206.extra_headers) |h| if (std.mem.eql(u8, h.name, "Content-Range")) {
          try std.testing.expectEqualStrings("bytes 8-13/14", h.value);
          got_cr = true;
      };
      try std.testing.expect(got_cr);
      // 416
      const rb = [_]http.Param{.{ .key = "range", .value = "bytes=99-" }};
      var bad = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = a, .headers = &rb };
      try std.testing.expectEqual(@as(u16, 416), (try serve(std.testing.io, &bad, src, .{})).?.status);
  }

  test "embedded spa fallback shell is no-cache even with the knob set (§C.3)" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const src = Source{ .embedded = &spa_fixture };
      const fb = Fallback{ .spa_roots = &.{"app"}, .spa_marker_enabled = true, .cache_control = "public, max-age=86400" };
      // fallback-resolved miss: no-cache wins over the knob
      var miss = http.RequestCtx{ .method = .GET, .path = "/app/deep/link", .allocator = a };
      const rm = (try serve(std.testing.io, &miss, src, fb)).?;
      try std.testing.expectEqualStrings("no-cache", rm.extra_headers[2].value);
      // a DIRECT hit on the same shell file keeps the knob value (deploy-owner's choice)
      var direct = http.RequestCtx{ .method = .GET, .path = "/app/index.html", .allocator = a };
      const rd = (try serve(std.testing.io, &direct, src, fb)).?;
      try std.testing.expectEqualStrings("public, max-age=86400", rd.extra_headers[2].value);
  }
  ```
- [ ] **Step 6: Run** `mise exec zig@0.16.0 -- zig build test --summary all` — expect PASS (fix any missed `serveRel` arity/test-assertion sites the compiler flags).
- [ ] **Step 7: Commit**
  ```bash
  git add src/static_files.zig src/server.zig
  git commit -m "feat(static): embedded Range 206/416 + Cache-Control; SPA fallback shell always no-cache (owned dir shell w/ stat ETag)"
  ```

---

### Task 7: PR2 e2e pins, KNOWN_LIMITATIONS, docs, fragment

**Files:**
- Modify: `tests/admin/test_static_files.py` (extensions — these are THE pin for delegated facil.io behavior)
- Modify: `KNOWN_LIMITATIONS.md:36-37` (delete "No Range"), `:44-46` (delete "not configurable yet"), add the dir-mode-conditional-semantics bullet
- Modify: `docs/api.md` §Static files + `docs/framework.md` §13 + mirrors; `site/src/content/docs/configuration.md` (env/flag tables)
- Create: `changelog.d/static-range-cache.md`

**Interfaces:**
- Consumes: Tasks 4-6 wire behavior. Produces: the merged PR2.

- [ ] **Step 1: extend `tests/admin/test_static_files.py`** (reuse its `_get/_hdr` helpers and the `test_serve_static_runtime_mode` server-launch shape; each new test spins its own server with the flags it needs):
  ```python
  def test_dir_static_range_seek_forms():
      """§A.2 pin: bytes=X- and bytes=-n now produce correct 206 BYTES through
      facil.io (the shim rewrites the request header; facil.io assembles the 206)."""
      binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
      with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
          blob = bytes(range(256)) * 4  # 1024 recognizable bytes
          (pathlib.Path(static) / "clip.bin").write_bytes(blob)
          port = _free_port()
          proc = subprocess.Popen(
              [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
               "--serve-static", static],
              env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
          )
          try:
              base = f"http://127.0.0.1:{port}"
              _wait_up(f"{base}/api/health")
              url = f"{base}/clip.bin"

              st, hdr, body = _get(url, {"Range": "bytes=200-"})  # open-ended seek
              assert st == 206 and body == blob[200:]
              assert _hdr(hdr, "Content-Range") == "bytes 200-1023/1024"
              st, _, body = _get(url, {"Range": "bytes=-100"})  # suffix
              assert st == 206 and body == blob[-100:]
              st, _, body = _get(url, {"Range": "bytes=100-199"})  # already canonical
              assert st == 206 and body == blob[100:200]
              st, hdr, _ = _get(url, {"Range": "bytes=5000-"})  # owned 416
              assert st == 416 and _hdr(hdr, "Content-Range") == "bytes */1024"
              st, hdr, body = _get(url)  # plain 200: Vary present, single stock Cache-Control
              assert st == 200 and body == blob
              assert _hdr(hdr, "Vary") == "Accept-Encoding"
              assert (hdr.get_all("Cache-Control") or []) == ["max-age=3600"]
          finally:
              proc.terminate(); proc.wait(timeout=5)

  def test_static_cache_control_knob_flag_env_and_default():
      # server A: no knob -> Cache-Control is exactly "max-age=3600" (stock facil.io, single header)
      # server B: --static-cache-control "public, max-age=86400, immutable" -> exact value, single header
      # server C: env ZIGBASE_STATIC_CACHE_CONTROL=... (no flag) -> env value on the wire
      # server D: both -> the FLAG value wins

  def test_embedded_static_emits_cache_control_and_range():
      # plugins example binary (resolve_plugins_binary, embedded frontend):
      # GET an embedded asset -> Cache-Control present (max-age=3600 default), Accept-Ranges: bytes
      # Range: bytes=0-9 -> 206 with the first 10 bytes; ETag format (quoted 8-hex CRC32) unchanged

  def test_spa_fallback_shell_no_cache_and_etag():
      # dir server with .spa marker: deep-link miss -> 200 shell, Cache-Control: no-cache,
      # quoted ETag; repeat with If-None-Match -> 304. Direct GET /index.html -> NOT no-cache.

  def test_gz_sidecar_still_served_with_vary():
      # file + file.gz in the static root; GET with Accept-Encoding: gzip ->
      # Content-Encoding: gzip (facil.io behavior kept verbatim) AND Vary: Accept-Encoding.
  ```
  Write these fully (concrete bytes, exact header assertions as sketched — the comments above are the assertions to encode, not placeholders to leave). Follow `test_serve_static_runtime_mode` for process management; use `resolve_plugins_binary` (already imported at the top of the file) for the embedded case exactly as the existing embedded tests in this file do — read them first.
- [ ] **Step 2: run the browser suite** — `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_static_files.py -q` — expect all (old + new) pass. The old tests pin that everything NOT listed in the spec is byte-identical.
- [ ] **Step 3: `KNOWN_LIMITATIONS.md`** — under "## Static file serving": delete the `No Range/partial-content requests` bullet (lines 36-37); replace the dir-mode caching bullet (44-46) with:
  ```markdown
  - In **dir** mode, conditional requests (`If-None-Match`/`If-Range`) use facil.io's
    exact-match ETag semantics (an unquoted base64 size^mtime tag), not RFC 7232
    list/weak comparison — self-consistent, and kept as-is by design (facil.io-first).
  ```
  Mirror the section edit if the site duplicates it (grep `site/src/content` for the bullet text).
- [ ] **Step 4: docs.** `docs/api.md` §Static files (+ site mirror): document (a) working Range forms (`bytes=a-b`/`a-`/`-n`, multi-range served as 200, 416 on unsatisfiable), (b) the Cache-Control knob (`--static-cache-control` / `ZIGBASE_STATIC_CACHE_CONTROL` / comptime `.static_cache_control`; default `max-age=3600`), (c) embedded assets now emit Cache-Control + Range, (d) the SPA fallback shell is always `no-cache` (direct hits keep the knob), (e) the **`.gz` sidecar negotiation documented for the first time**: when `Accept-Encoding` contains `gzip` and `<file>.gz` exists next to `<file>`, the sidecar is served with `Content-Encoding: gzip` and (new) `Vary: Accept-Encoding`, (f) dir-mode conditional semantics remain facil.io's. `docs/framework.md` §13 (+ mirror): the `.static_cache_control` comptime key, the flag/env override order, the process-wide scope note ("a consumer route calling `r.sendFile` directly inherits the knob — that IS the knob"), and the SPA-shell `no-cache` composition. `site/src/content/docs/configuration.md`: add `ZIGBASE_STATIC_CACHE_CONTROL` to the env table + `--static-cache-control` to the flags table. Run `cd site && mise exec node@24 -- npm run build`.
- [ ] **Step 5: fragment `changelog.d/static-range-cache.md`:**
  ```markdown
  ### Features
  - Static serving now answers `bytes=X-` (video seek), `bytes=-n`, and overlong Range requests with correct `206` responses, and unsatisfiable ranges with `416` (previously these fell through to a full `200` or worse). Embedded static assets gain single-range `206` support.
  - Tunable static `Cache-Control`: comptime `App(.{ .static_cache_control = … })`, `--static-cache-control` flag, and `ZIGBASE_STATIC_CACHE_CONTROL` env (flag > env > comptime; unset keeps the stock `max-age=3600`).

  ### Fixes
  - Embedded static assets now send a `Cache-Control` header (previously none — revalidation still works via the unchanged CRC32 ETag).
  - `.gz` sidecar responses now carry `Vary: Accept-Encoding` (shared-cache correctness).
  - The SPA fallback shell is always served `Cache-Control: no-cache` with a revalidation ETag, so a redeploy can no longer strand deep links on a stale cached shell.

  ### Internal
  - Static Range support is a ~20-line request-header normalization shim + `HTTP_HVALUE_MAX_AGE` FIOBJ swap at `FIO_CALL_PRE_START` — facil.io keeps ALL static serving (directive 1); no owned static layer.
  ```
- [ ] **Step 6: full local browser suite** `mise exec python@3.13 -- python -m pytest tests/admin -q` — expect pass. **Step 7: Commit, push, open PR2:**
  ```bash
  git add tests/admin/test_static_files.py KNOWN_LIMITATIONS.md docs/ site/ changelog.d/static-range-cache.md
  git commit -m "feat(static): Range fixes + Cache-Control knob e2e pins, docs, KNOWN_LIMITATIONS"
  ```

---

# PR 3 — SigV4 generalization (branch `feat/sigv4-generalize`)

### Task 8: `src/mail/sigv4.zig` → `src/aws/sigv4.zig` — parameterized method/path/headers/service, SES vectors pinned

**Files:**
- Create: `src/aws/sigv4.zig` (move + generalize; `git mv src/mail/sigv4.zig src/aws/sigv4.zig` then edit)
- Modify: `src/mail/ses.zig:13,48-57` (import path + new call shape)
- Modify: `src/root.zig` test block (`mail/sigv4.zig` → `aws/sigv4.zig`)
- Create: `changelog.d/sigv4-generalize.md`

**Interfaces:**
- Produces (consumed by Task 11's S3 client; default build — NOT gated; this is a refactor of code every stock binary already ships via `SesMailer`):
  - `pub const Header = struct { name: []const u8, value: []const u8 }` — lowercase name, value pre-trimmed
  - `pub const SignInput = struct { access_key, secret_key, region, service, method, host, path: []const u8, query: []const u8 = "", headers: []const Header = &.{}, payload_sha256: []const u8, amz_date: []const u8 }`
  - `pub fn signRequest(alloc: std.mem.Allocator, in: SignInput) ![]const u8` — the `Authorization` header value; `host` + `x-amz-date` always signed, `in.headers` merged + sorted into the canonical/signed lists
  - `pub fn uriEncodePath(alloc: std.mem.Allocator, path: []const u8) ![]const u8` — S3 `UriEncode` of each segment, `/` preserved
  - `pub fn sha256Hex(alloc, data) ![]u8` and `pub fn signingKey(secret, date, region, service)` — unchanged

- [ ] **Step 1:** `git mv src/mail/sigv4.zig src/aws/sigv4.zig`; update `src/root.zig`'s test block line `_ = @import("mail/sigv4.zig");` → `_ = @import("aws/sigv4.zig");` and `src/mail/ses.zig:13` → `const sigv4 = @import("../aws/sigv4.zig");`.
- [ ] **Step 2: generalize the signer.** Replace the SES-shaped `Request`/`Signed`/`sign` with (keep `algorithm`, `sha256Hex`, `hmac`, `signingKey`, and the module doc updated to name both SES and S3 as consumers):
  ```zig
  pub const Header = struct { name: []const u8, value: []const u8 };

  /// The inputs to sign one HTTP request (SigV4, header-based signing; query-string
  /// signing/presigning is a future additive mode on this same surface).
  pub const SignInput = struct {
      access_key: []const u8,
      secret_key: []const u8,
      region: []const u8,
      service: []const u8, // "ses", "s3", ...
      method: []const u8, // "GET" | "PUT" | "POST" | "DELETE" | "HEAD"
      host: []const u8,
      /// RAW request path ("/" prefixed). Each '/'-separated segment is S3-UriEncoded
      /// into the canonical URI ('/' preserved). SES's fixed paths are unaffected
      /// (no reserved characters).
      path: []const u8,
      /// Pre-canonicalized query string (sorted, encoded). "" for every current caller;
      /// the seam presigning will use later.
      query: []const u8 = "",
      /// EXTRA headers to sign beyond host + x-amz-date (e.g. content-type,
      /// x-amz-content-sha256 — S3 REQUIRES the latter signed). Names must be
      /// lowercase, values trimmed; the signer sorts the merged list.
      headers: []const Header = &.{},
      /// Lowercase-hex SHA-256 of the payload (sha256Hex; empty body => hash of "").
      payload_sha256: []const u8,
      /// `YYYYMMDDTHHMMSSZ` UTC timestamp (the X-Amz-Date header value).
      amz_date: []const u8,
  };

  /// S3 `UriEncode` of one path: unreserved chars (A-Z a-z 0-9 - . _ ~) verbatim,
  /// '/' preserved as the segment separator, EVERYTHING else (incl. space as %20,
  /// '+', and each raw UTF-8 byte) percent-encoded uppercase-hex.
  pub fn uriEncodePath(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
      var out: std.ArrayList(u8) = .empty;
      for (path) |c| {
          const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
              (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~' or c == '/';
          if (unreserved) {
              try out.append(alloc, c);
          } else {
              try out.print(alloc, "%{X:0>2}", .{c});
          }
      }
      return out.toOwnedSlice(alloc);
  }

  /// Produce the `Authorization` header value for `in`. `host` and `x-amz-date` are
  /// always signed; `in.headers` are merged in and the canonical list is sorted by
  /// lowercase name (AWS requirement). Caller owns the returned slice.
  pub fn signRequest(alloc: std.mem.Allocator, in: SignInput) ![]const u8 {
      const date = in.amz_date[0..8]; // YYYYMMDD

      // Merge host + x-amz-date + extras, then sort by name.
      var hdrs: std.ArrayList(Header) = .empty;
      defer hdrs.deinit(alloc);
      try hdrs.append(alloc, .{ .name = "host", .value = in.host });
      try hdrs.append(alloc, .{ .name = "x-amz-date", .value = in.amz_date });
      try hdrs.appendSlice(alloc, in.headers);
      std.mem.sort(Header, hdrs.items, {}, struct {
          fn lt(_: void, x: Header, y: Header) bool {
              return std.mem.lessThan(u8, x.name, y.name);
          }
      }.lt);

      var canonical_headers: std.ArrayList(u8) = .empty;
      defer canonical_headers.deinit(alloc);
      var signed_names: std.ArrayList(u8) = .empty;
      defer signed_names.deinit(alloc);
      for (hdrs.items, 0..) |h, i| {
          try canonical_headers.print(alloc, "{s}:{s}\n", .{ h.name, h.value });
          if (i != 0) try signed_names.append(alloc, ';');
          try signed_names.appendSlice(alloc, h.name);
      }

      const canonical_uri = try uriEncodePath(alloc, in.path);
      defer alloc.free(canonical_uri);
      const canonical_request = try std.fmt.allocPrint(
          alloc,
          "{s}\n{s}\n{s}\n{s}\n{s}\n{s}",
          .{ in.method, canonical_uri, in.query, canonical_headers.items, signed_names.items, in.payload_sha256 },
      );
      defer alloc.free(canonical_request);
      const canonical_hash = try sha256Hex(alloc, canonical_request);
      defer alloc.free(canonical_hash);

      const scope = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}/aws4_request", .{ date, in.region, in.service });
      defer alloc.free(scope);
      const string_to_sign = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}", .{ algorithm, in.amz_date, scope, canonical_hash });
      defer alloc.free(string_to_sign);

      const key = signingKey(in.secret_key, date, in.region, in.service);
      const sig = hmac(&key, string_to_sign);
      const sig_hex = std.fmt.bytesToHex(sig, .lower);
      return std.fmt.allocPrint(
          alloc,
          "{s} Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
          .{ algorithm, in.access_key, scope, signed_names.items, sig_hex },
      );
  }
  ```
  (If `ArrayList.print` is not available in this std revision, build the pieces with `std.fmt.allocPrint` + `appendSlice` — the compiler will tell you; the byte-level contract is the vectors below.)
- [ ] **Step 3: port `src/mail/ses.zig`** — replace the `sigv4.sign(alloc, .{ … })` call (lines 48-57):
  ```zig
          const payload_hash = try sigv4.sha256Hex(alloc, body);
          defer alloc.free(payload_hash);
          const authorization = try sigv4.signRequest(alloc, .{
              .access_key = self.access_key,
              .secret_key = self.secret_key,
              .region = self.region,
              .service = "ses",
              .method = "POST",
              .host = host,
              .path = path,
              .headers = &.{.{ .name = "content-type", .value = "application/json" }},
              .payload_sha256 = payload_hash,
              .amz_date = &amz_date,
          });
          defer alloc.free(authorization);
  ```
  and update the outbound header list to use `authorization` / `payload_hash` (the `X-Amz-Content-Sha256` header keeps being sent unsigned for SES — wire bytes unchanged).
- [ ] **Step 4: PIN the SES vectors byte-identically.** Port the four existing sigv4 tests to the new call shape and KEEP EVERY ASSERTION STRING VERBATIM — in particular `"AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/ses/aws4_request"` and `"SignedHeaders=content-type;host;x-amz-date"` (the merged-and-sorted list must reproduce the old hardcoded order exactly: content-type < host < x-amz-date). Add a stronger pin BEFORE refactoring (write it against the OLD code first, capture the full Authorization string it produces, then assert the new code emits the identical string):
  ```zig
  test "PIN: SES-shaped signature is byte-identical across the generalization" {
      const a = testing.allocator;
      const payload_hash = try sha256Hex(a, "{\"x\":1}");
      defer a.free(payload_hash);
      const auth = try signRequest(a, .{
          .access_key = "AKIDEXAMPLE",
          .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
          .region = "us-east-1",
          .service = "ses",
          .method = "POST",
          .host = "email.us-east-1.amazonaws.com",
          .path = "/v2/email/outbound-emails",
          .headers = &.{.{ .name = "content-type", .value = "application/json" }},
          .payload_sha256 = payload_hash,
          .amz_date = "20150830T123600Z",
      });
      defer a.free(auth);
      // <FULL-AUTH-STRING>: run this exact input through the PRE-refactor sign() first
      // (e.g. `git stash`, add a temp debug print in the old test, `zig build test`)
      // and paste the complete Authorization value here. The refactor must reproduce it.
      try testing.expectEqualStrings("<FULL-AUTH-STRING>", auth);
  }
  ```
- [ ] **Step 5: S3 + UriEncode vectors.** Add:
  ```zig
  test "uriEncodePath: S3 UriEncode edges (space, plus, tilde, unicode, '/')" {
      const a = testing.allocator;
      const cases = [_][2][]const u8{
          .{ "/col/rid/a file.png", "/col/rid/a%20file.png" },
          .{ "/a+b", "/a%2Bb" },
          .{ "/a~b-c_d.e", "/a~b-c_d.e" }, // unreserved verbatim
          .{ "/ä", "/%C3%A4" }, // raw UTF-8 bytes, uppercase hex
          .{ "/a/b/c", "/a/b/c" }, // '/' preserved
          .{ "/a=b&c", "/a%3Db%26c" },
      };
      for (cases) |c| {
          const got = try uriEncodePath(a, c[0]);
          defer a.free(got);
          try testing.expectEqualStrings(c[1], got);
      }
  }

  test "signRequest: AWS SigV4 official test-suite vector (get-vanilla shape)" {
      // Official aws-sig-v4-test-suite creds/date/host; service "service".
      const a = testing.allocator;
      const empty_hash = try sha256Hex(a, "");
      defer a.free(empty_hash);
      const auth = try signRequest(a, .{
          .access_key = "AKIDEXAMPLE",
          .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
          .region = "us-east-1",
          .service = "service",
          .method = "GET",
          .host = "example.amazonaws.com",
          .path = "/",
          .payload_sha256 = empty_hash,
          .amz_date = "20150830T123600Z",
      });
      defer a.free(auth);
      try testing.expectEqualStrings(
          "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=<SIG>",
          auth,
      );
  }
  ```
  Compute `<SIG>` with the reference one-liner and paste it (do NOT guess):
  ```sh
  mise exec python@3.13 -- python - <<'EOF'
  import hashlib, hmac
  def h(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
  cr = "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\n" + hashlib.sha256(b"").hexdigest()
  sts = "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n" + hashlib.sha256(cr.encode()).hexdigest()
  k = h(h(h(h(b"AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY","20150830"),"us-east-1"),"service"),"aws4_request")
  print(hmac.new(k, sts.encode(), hashlib.sha256).hexdigest())
  EOF
  ```
  Add one more vector the same way for an S3-shaped PUT (`.service = "s3"`, `.method = "PUT"`, `.path = "/bucket/col/rid/a file.png"`, `.headers = &.{ .{ .name = "content-type", .value = "image/png" }, .{ .name = "x-amz-content-sha256", .value = <payload hash> } }`) — adapt the python canonical-request string to match (`PUT\n/bucket/col/rid/a%20file.png\n\ncontent-type:image/png\nhost:…\nx-amz-content-sha256:…\nx-amz-date:…\n\ncontent-type;host;x-amz-content-sha256;x-amz-date\n…`).
- [ ] **Step 6: Run** `mise exec zig@0.16.0 -- zig build test --summary all` — expect PASS, incl. the byte-identical PIN.
- [ ] **Step 7: fragment `changelog.d/sigv4-generalize.md`:**
  ```markdown
  ### Internal
  - Generalized the AWS SigV4 signer (`src/mail/sigv4.zig` → `src/aws/sigv4.zig`): parameterized method / canonical URI (S3 `UriEncode`) / signed-header list / service, SES signatures pinned byte-identical. Groundwork for the S3 storage backend; zero behavior change.
  ```
- [ ] **Step 8: Commit, push, open PR3:**
  ```bash
  git add src/aws/sigv4.zig src/mail/ses.zig src/root.zig changelog.d/sigv4-generalize.md
  git rm src/mail/sigv4.zig 2>/dev/null || true
  git commit -m "refactor(aws): generalize SigV4 signer for S3 (method/uri/headers/service), SES vectors pinned byte-identical"
  ```

---

# PR 4 — `-Ds3` S3-compatible storage backend (branch `feat/s3-storage`) — branch AFTER PR1 and PR3 are merged

### Task 9: `-Ds3` build gate + `ZIGBASE_S3_*` config + stock-binary warning

**Files:**
- Modify: `build.zig:50-52` (beside the postgres option), `src/config.zig`, `src/framework.zig` (`DefaultStoragePlugin`), `src/root.zig` (conditional export)

**Interfaces:**
- Produces: `build_options.s3: bool` (default false); `Config.s3_*` fields parsed in EVERY build; `DefaultStoragePlugin` warns + falls back to local when the bucket is set without the flag. Consumed by Tasks 11-13.

- [ ] **Step 1: `build.zig`** — after the postgres option (line 51):
  ```zig
      // Opt-in S3-compatible storage backend (SP3 Theme D §D). OFF by default: when false,
      // src/files/s3.zig is comptime-unreachable (conditional @import in framework.zig /
      // root.zig — the db.zig:27 postgres pattern), so the default build compiles zero S3
      // code. Pure Zig (the shared http_client + the aws/sigv4 signer, both of which the
      // default build already ships via SES) — no extra C sources.
      const s3 = b.option(bool, "s3", "Compile in the opt-in S3-compatible storage backend (default: off)") orelse false;
      build_options.addOption(bool, "s3", s3);
  ```
- [ ] **Step 2: `src/config.zig`** — add the field cluster (after `static_cache_control`) + `load()` lines (SMTP-cluster pattern; parse errors abort startup):
  ```zig
      // S3-compatible remote storage (§D). Parsed in EVERY build — a stock (no -Ds3)
      // binary needs them to detect-and-warn (the postgres_url_without_build precedent);
      // the backend itself is compiled only under -Ds3. Secrets are never logged.
      s3_bucket: []const u8 = "", // non-empty enables S3 (in an -Ds3 build)
      s3_region: []const u8 = "us-east-1",
      s3_endpoint: []const u8 = "", // "" = https://s3.<region>.amazonaws.com; MinIO/R2 set this
      s3_access_key_id: []const u8 = "",
      s3_secret_access_key: []const u8 = "",
      s3_force_path_style: ?bool = null, // null = auto: true when an endpoint is set
      s3_key_prefix: []const u8 = "",
      s3_cache_dir: []const u8 = "", // "" = <data_dir>/storage_cache
      s3_cache_max_bytes: u64 = 1 << 30, // 1 GiB spool cap
  ```
  ```zig
      if (getter.get("ZIGBASE_S3_BUCKET")) |v| cfg.s3_bucket = v;
      if (getter.get("ZIGBASE_S3_REGION")) |v| cfg.s3_region = v;
      if (getter.get("ZIGBASE_S3_ENDPOINT")) |v| cfg.s3_endpoint = v;
      if (getter.get("ZIGBASE_S3_ACCESS_KEY_ID")) |v| cfg.s3_access_key_id = v;
      if (getter.get("ZIGBASE_S3_SECRET_ACCESS_KEY")) |v| cfg.s3_secret_access_key = v;
      if (getter.get("ZIGBASE_S3_FORCE_PATH_STYLE")) |v| cfg.s3_force_path_style = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
      if (getter.get("ZIGBASE_S3_KEY_PREFIX")) |v| cfg.s3_key_prefix = v;
      if (getter.get("ZIGBASE_S3_CACHE_DIR")) |v| cfg.s3_cache_dir = v;
      if (getter.get("ZIGBASE_S3_CACHE_MAX_BYTES")) |v| cfg.s3_cache_max_bytes = try std.fmt.parseInt(u64, v, 10);
  ```
  + a defaults/overrides test in the file's existing style.
- [ ] **Step 3: `src/framework.zig`** — teach `DefaultStoragePlugin` the config-driven selection (mirrors `DefaultMailerPlugin`'s precedence comment style). Add near the top: `const s3mod = if (build_options.s3) @import("files/s3.zig") else struct {};` and rework:
  ```zig
  /// Default storage plugin, config-driven with no code change to switch backends
  /// (the DefaultMailerPlugin precedent):
  ///   1. `cfg.s3_bucket` non-empty AND the binary was built with -Ds3 → `S3Storage`.
  ///   2. else → `LocalStorage` rooted at `<data_dir>/storage` (unchanged default).
  /// A stock (no -Ds3) binary with ZIGBASE_S3_BUCKET set warns LOUDLY and falls back
  /// to local — never silent, never fatal (the ZIGBASE_DB_URL postgres:// contract).
  pub const DefaultStoragePlugin = struct {
      gpa: std.mem.Allocator,
      root: []const u8,
      backend: Backend,

      const Backend = if (build_options.s3) union(enum) {
          local: files_storage.LocalStorage,
          s3: s3mod.S3Storage,
      } else union(enum) {
          local: files_storage.LocalStorage,
      };

      pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !DefaultStoragePlugin {
          const root = try std.fmt.allocPrint(gpa, "{s}/storage", .{cfg.data_dir});
          errdefer gpa.free(root);
          if (cfg.s3_bucket.len > 0) {
              if (comptime build_options.s3) {
                  return .{ .gpa = gpa, .root = root, .backend = .{ .s3 = try s3mod.S3Storage.create(gpa, io, cfg) } };
              } else {
                  std.log.warn(
                      "ZIGBASE_S3_BUCKET is set but this binary was built without -Ds3; " ++
                          "falling back to local storage at {s}/storage (build with -Ds3=true to use S3)",
                      .{cfg.data_dir},
                  );
              }
          }
          return .{ .gpa = gpa, .root = root, .backend = .{ .local = files_storage.LocalStorage.init(root) } };
      }

      pub fn interface(self: *DefaultStoragePlugin) files_storage.Storage {
          switch (self.backend) {
              inline else => |*b| return b.storage(),
          }
      }

      pub fn deinit(self: *DefaultStoragePlugin) void {
          if (comptime build_options.s3) {
              switch (self.backend) {
                  .s3 => |*s| s.deinit(),
                  else => {},
              }
          }
          self.gpa.free(self.root);
      }
  };
  ```
  (Until Task 12 exists, an `-Ds3` build won't compile — that's fine; this PR's tasks land as ONE PR and every task still keeps the DEFAULT build green. If you want a green `-Ds3` checkpoint per task, stub `S3Storage` in Task 11.) Add the stock-binary test (default build — always compiled):
  ```zig
  test "DefaultStoragePlugin: ZIGBASE_S3_BUCKET without -Ds3 warns and falls back to LocalStorage" {
      if (comptime build_options.s3) return error.SkipZigTest; // this test pins the STOCK binary
      const a = std.testing.allocator;
      var p = try DefaultStoragePlugin.create(a, std.testing.io, .{ .data_dir = "/tmp/zb-s3-fallback", .s3_bucket = "prod-bucket" });
      defer p.deinit();
      try std.testing.expect(p.backend == .local); // fail-loud (warn), not fatal, not S3
  }
  ```
- [ ] **Step 4: `src/root.zig`** — conditional export next to `LocalStorage` (line 40):
  ```zig
  /// Opt-in S3-compatible storage backend (`-Ds3`; §D). A stub type in a default build —
  /// naming it compiles, constructing it requires `-Ds3=true` (the PG-gated pattern).
  pub const S3Storage = if (@import("build_options").s3) @import("files/s3.zig").S3Storage else struct {};
  ```
- [ ] **Step 5: Run** `mise exec zig@0.16.0 -- zig build test --summary all` (default build green; `-Ds3` intentionally not yet buildable). **Step 6: Commit** `git add build.zig src/config.zig src/framework.zig src/root.zig && git commit -m "feat(s3): -Ds3 build gate, ZIGBASE_S3_* config, stock-binary fail-loud fallback"`

---

### Task 10: Storage vtable `localPath` → `fetch(ctx, io, alloc, …)` (BREAKING) + examples/plugins + docs §9 + fragment

**Files:**
- Modify: `src/files/storage.zig` (vtable, wrapper, `LocalStorage`, test), `src/api/files.zig` (call site + null/error semantics), `examples/plugins/src/main.zig:8-151` + `examples/plugins/README.md`
- Modify: `docs/framework.md` §9 + `site/src/content/docs/framework.md` (same section)
- Create: `changelog.d/s3-storage.md` (started here with the Breaking entry; Tasks 12/13 append)

**Interfaces:**
- Produces (all builds): `Storage.VTable.fetch: *const fn (ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8` — contract: *"return a local filesystem path whose contents are the file, materializing it locally if necessary; null = the backend has no such object."* Wrapper: `pub fn fetch(self: Storage, io: std.Io, alloc: std.mem.Allocator, col, record_id, filename) anyerror!?[]const u8`. Consumed by Task 12 (`S3Storage.fetch` spools) and by `api/files.zig`.

- [ ] **Step 1: `src/files/storage.zig`** — rename the vtable slot + wrapper and add `io`:
  ```zig
  /// Backend-agnostic blob storage for record files. `fetch` returns a local filesystem
  /// path whose contents ARE the file — materializing it locally first if necessary
  /// (remote backends spool to a local cache); `null` = the backend has no such object.
  /// (0.10.0, Breaking: was `localPath(ctx, alloc, …)` — the rename is forced anyway,
  /// since a remote backend needs the `io` for network/disk I/O.)
  ```
  ```zig
          fetch: *const fn (ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8,
  ```
  ```zig
      pub fn fetch(self: Storage, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8 {
          return self.vtable.fetch(self.ctx, io, alloc, col, record_id, filename);
      }
  ```
  `LocalStorage`: rename `fn localPath` → `fn fetch` with the added `io: std.Io` param (body unchanged — the same pure path-join; add `_ = io;`), update `const vtable = …{ .fetch = fetch, … }` and the round-trip test's calls (`st.fetch(std.testing.io, a, …)`).
- [ ] **Step 2: `src/api/files.zig`** — the call site (from Task 3) becomes, with the §D.5 semantics split:
  ```zig
      const storage = app.storage orelse return ApiError.internal().toResponse(ctx.allocator);
      // §D.5: null = the DB references an object the backend has lost — hide existence
      // (404) but SCREAM in the logs; a transport/backend error (post retry-once inside
      // the backend) = transient -> 500.
      const maybe_path = storage.fetch(app.io, ctx.allocator, col.name, rid, name) catch |e| {
          std.log.err("storage.fetch failed for {s}/{s}/{s}: {s}", .{ col.name, rid, name, @errorName(e) });
          return ApiError.internal().toResponse(ctx.allocator);
      };
      const path = maybe_path orelse {
          std.log.err("storage backend has no object for referenced file {s}/{s}/{s}", .{ col.name, rid, name });
          return ApiError.notFound().toResponse(ctx.allocator);
      };
  ```
  and delete the Task-3 transitional comment about the upcoming rename.
- [ ] **Step 3: `examples/plugins/src/main.zig`** — mechanical migration of `AuditStorage`: doc comments (lines 8-13, 70-83: "four methods" text now names `fetch(ctx, io, alloc, col, record_id, filename) anyerror!?[]const u8`), the vtable literal (`.fetch = auditFetch`), and:
  ```zig
      fn auditFetch(
          ctx: *anyopaque,
          io: std.Io,
          alloc: std.mem.Allocator,
          col: []const u8,
          record_id: []const u8,
          filename: []const u8,
      ) anyerror!?[]const u8 {
          const self: *AuditStorage = @ptrCast(@alignCast(ctx));
          self.local_paths += 1;
          std.log.debug("[audit-storage] fetch col={s} id={s} file={s}", .{ col, record_id, filename });
          return self.inner.vtable.fetch(self.inner.ctx, io, alloc, col, record_id, filename);
      }
  ```
  Rename the `local_paths` counter to `fetches` if the example's README prints it — grep the README and sync. Build the example: `cd examples/plugins/frontend && mise exec node@24 -- npm ci && mise exec node@24 -- npm run build && cd .. && mise exec zig@0.16.0 -- zig build` — expect success (this compile IS the public-surface test).
- [ ] **Step 4: docs.** `docs/framework.md` §9 + mirror: update the `Storage` vtable listing and the `MyStorage` example to `fetch`, and add the migration one-liner: *"0.10.0: `localPath(ctx, alloc, …)` → `fetch(ctx, io, alloc, …)` — rename + one new parameter; return a local path, materializing the file locally if necessary; `null` = object missing."* `cd site && mise exec node@24 -- npm run build`.
- [ ] **Step 5: start `changelog.d/s3-storage.md`:**
  ```markdown
  ### Breaking
  - Storage plugin vtable: `localPath(ctx, alloc, col, record_id, filename)` is now `fetch(ctx, io, alloc, col, record_id, filename)` — return a local filesystem path whose contents are the file, **materializing it locally if necessary**; `null` = the backend has no such object. Local-disk backends migrate mechanically (rename + the `io` parameter).
  ```
- [ ] **Step 6: Run** `mise exec zig@0.16.0 -- zig build test --summary all` + the examples builds (blog/golfsim compile-verified: `cd examples/blog && mise exec zig@0.16.0 -- zig build`; same for golfsim — they don't define storage plugins, but prove the dependency graph). **Commit:** `git add -A && git commit -m "feat(storage)!: vtable localPath -> fetch(io, ...) — materializing fetch contract (examples + docs migrated)"`

---

### Task 11: `HttpClient.download` + S3 client ops (`src/files/s3.zig`, gated)

**Files:**
- Modify: `src/http_client.zig` (+`download`), `src/root.zig` (gated test import)
- Create: `src/files/s3.zig` (client half; `S3Storage` follows in Task 12)

**Interfaces:**
- Produces:
  - `HttpClient.download(opts: RequestOptions, writer: *std.Io.Writer) !DownloadResult` with `pub const DownloadResult = struct { status: u16, headers: []const Header }` — streams the body through `writer` (no `max_response_bytes` cap on this path); same TLS stance; same `testcapture` intercept (a mocked body is written through the writer). Ungated source, zero default-build cost (no default-build caller → lazy analysis never codegens it).
  - `s3.Client` (gated): `init(cfg: config.Config) Client` resolving endpoint/path-style defaults; `objectKey(alloc, self, col, rid, name)` → `<prefix><col>/<rid>/<name>`; `put(io, alloc, key, bytes, content_type) !void`; `getToWriter(io, alloc, key, w) !u16`; `delete(io, alloc, key) !void`; `head(io, alloc, key) !u16`; `listKeys(io, alloc, prefix) ![][]const u8`. `put`/`getToWriter` retry ONCE on transport error or 5xx (idempotent).

- [ ] **Step 1: `HttpClient.download`.** Add beside `request()` — it is `request()` with the fixed buffer swapped for the caller's writer. Concretely: copy the body of `request`, (a) in the testcapture branch, on `.response => |r|` do `try writer.writeAll(r.body); return .{ .status = r.status, .headers = r.headers };`, (b) drop the `resp_buf`/`fw` allocation and `streamRemaining(&fw)` becomes `streamRemaining(writer)` mapping `error.WriteFailed => return error.WriteFailed` (the caller's writer failed — e.g. disk full), (c) return `.{ .status = @intFromEnum(response.head.status), .headers = captured_headers }`. Factor the shared head/headers logic into a private helper only if the duplication exceeds ~40 lines — do not restructure `request()`'s error mapping. Add a loopback test next to the existing two (reuse `TestHttpServer`):
  ```zig
  test "HttpClient.download streams the body through the caller's writer" {
      var server = try TestHttpServer.start("STREAMED-BYTES", 200);
      defer server.stop();
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const client = HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };
      var buf: [64]u8 = undefined;
      var fw = std.Io.Writer.fixed(&buf);
      const res = try client.download(.{ .url = try server.url(arena.allocator()) }, &fw);
      try std.testing.expectEqual(@as(u16, 200), res.status);
      try std.testing.expectEqualStrings("STREAMED-BYTES", fw.buffered());
  }
  ```
- [ ] **Step 2: `src/files/s3.zig` (client half).** Complete module skeleton (the vtable/S3Storage half lands in Task 12 in this same file):
  ```zig
  //! S3-compatible object storage client + spool-cached Storage backend (§D). Compiled
  //! ONLY under -Ds3 (conditional @import in framework.zig/root.zig). Pure Zig: the
  //! shared http_client + the aws/sigv4 signer. Key layout mirrors local disk:
  //! `<prefix><col>/<rid>/<filename>` (col/rid are validated ids, filename is a
  //! naming-sanitized stored name; keys are additionally UriEncoded per SigV4).
  const std = @import("std");
  const config = @import("../config.zig");
  const sigv4 = @import("../aws/sigv4.zig");
  const http_client = @import("../http_client.zig");
  const clock = @import("../clock.zig");
  const testcapture = @import("../testcapture.zig");

  pub const Client = struct {
      bucket: []const u8,
      region: []const u8,
      /// Host (no scheme) + scheme split out of cfg.s3_endpoint; defaults to
      /// s3.<region>.amazonaws.com over https.
      host: []const u8,
      scheme: []const u8, // "https" | "http" (http = loud startup warning, MinIO dev/CI)
      access_key: []const u8,
      secret_key: []const u8,
      key_prefix: []const u8,
      path_style: bool,

      /// Resolve endpoint defaults: "" endpoint => https://s3.<region>.amazonaws.com
      /// (virtual-hosted addressing unless forced); an explicit endpoint (MinIO/R2) =>
      /// its scheme + host, PATH-STYLE by default. `host_storage` receives the derived
      /// default host string when no endpoint is set (the Client borrows it; all other
      /// fields borrow cfg, which outlives the server).
      pub fn init(cfg: config.Config, host_storage: []u8) Client {
          var scheme: []const u8 = "https";
          var host: []const u8 = undefined;
          if (cfg.s3_endpoint.len > 0) {
              var ep = cfg.s3_endpoint;
              if (std.mem.startsWith(u8, ep, "http://")) {
                  scheme = "http"; // loud dev-only warning happens in S3Storage.create
                  ep = ep["http://".len..];
              } else if (std.mem.startsWith(u8, ep, "https://")) {
                  ep = ep["https://".len..];
              }
              host = std.mem.trimEnd(u8, ep, "/");
          } else {
              host = std.fmt.bufPrint(host_storage, "s3.{s}.amazonaws.com", .{cfg.s3_region}) catch
                  unreachable; // region is a short AWS identifier; 256 bytes cannot overflow
          }
          return .{
              .bucket = cfg.s3_bucket,
              .region = cfg.s3_region,
              .host = host,
              .scheme = scheme,
              .access_key = cfg.s3_access_key_id,
              .secret_key = cfg.s3_secret_access_key,
              .key_prefix = cfg.s3_key_prefix,
              .path_style = cfg.s3_force_path_style orelse (cfg.s3_endpoint.len > 0),
          };
      }

      /// "<prefix><col>/<rid>/<name>" — the object key (unencoded; the signer encodes).
      pub fn objectKey(alloc: std.mem.Allocator, self: Client, col: []const u8, rid: []const u8, name: []const u8) ![]const u8 {
          return std.fmt.allocPrint(alloc, "{s}{s}/{s}/{s}", .{ self.key_prefix, col, rid, name });
      }

      /// Request path for `key`: path-style => "/<bucket>/<key>"; virtual-hosted =>
      /// "/<key>" (the bucket rides the host instead — see effectiveHost).
      fn requestPath(alloc: std.mem.Allocator, self: Client, key: []const u8) ![]const u8 {
          return if (self.path_style)
              std.fmt.allocPrint(alloc, "/{s}/{s}", .{ self.bucket, key })
          else
              std.fmt.allocPrint(alloc, "/{s}", .{key});
      }

      /// Host to sign + dial: path-style => the endpoint host; virtual-hosted =>
      /// "<bucket>.<host>".
      fn effectiveHost(alloc: std.mem.Allocator, self: Client) ![]const u8 {
          return if (self.path_style)
              alloc.dupe(u8, self.host)
          else
              std.fmt.allocPrint(alloc, "{s}.{s}", .{ self.bucket, self.host });
      }
  };
  ```
  Implement the five ops on `Client`; each: build `path` (+ query for List), `amz_date` from `clock.nowUnix(io)` via the same `amzDate` formatting as `ses.zig` (copy that tiny helper), `payload_sha256 = sigv4.sha256Hex(alloc, body-or-"")`, sign with `.service = "s3"` and headers `[{content-type?}, {x-amz-content-sha256, payload_sha256}]` (S3 requires the latter SIGNED), then call `HttpClient.request` (put/delete/head/list) or `HttpClient.download` (get). URL = `{scheme}://{effective_host}{sigv4.uriEncodePath(path)}{?query}`. Sent headers: `X-Amz-Date`, `X-Amz-Content-Sha256`, `Authorization`, plus `Content-Type` on put. Status mapping: put 200 → ok; get 200 → status returned; head returns the raw status (the probe interprets); delete 204/200/404 → ok (best-effort); anything 5xx/transport on put/get → retry once, then `error.S3RequestFailed`. `listKeys`: `?list-type=2&prefix=<UriEncode(prefix)>` (note: in the QUERY string, `/` must be encoded too — write a tiny `uriEncodeQueryValue` local helper that reuses the same table but also encodes `/`; the canonical query passed to the signer is exactly this encoded `list-type=2&prefix=…` string, already sorted), then a minimal bounded `<Key>…</Key>` tag scan over the XML body — no general parser:
  ```zig
  /// Minimal, bounded <Key> extraction from a ListObjectsV2 body. NOT a general XML
  /// parser: keys are ZigBase-written (validated ids + sanitized stored names, no '<'),
  /// so a plain tag scan is sufficient; anything malformed simply yields fewer keys.
  fn scanKeys(alloc: std.mem.Allocator, xml: []const u8) ![][]const u8 {
      var out: std.ArrayList([]const u8) = .empty;
      errdefer {
          for (out.items) |k| alloc.free(k);
          out.deinit(alloc);
      }
      var rest = xml;
      while (std.mem.indexOf(u8, rest, "<Key>")) |start| {
          rest = rest[start + "<Key>".len ..];
          const end = std.mem.indexOf(u8, rest, "</Key>") orelse break; // truncated tag: stop
          try out.append(alloc, try alloc.dupe(u8, rest[0..end]));
          rest = rest[end + "</Key>".len ..];
      }
      return out.toOwnedSlice(alloc);
  }
  ```
- [ ] **Step 3: gated tests in `s3.zig`** via the mock seam (each starts with `if (!testcapture.enabled) return error.SkipZigTest;` and `testcapture.http.enable(true); defer testcapture.http.reset();` — read `src/testcapture.zig`'s `MockResponse` + `requests()` accessors first and use their exact field names):
  - put sends signed headers: mock the URL substring, call `client.put`, assert the recorded request's headers include `Authorization` starting `"AWS4-HMAC-SHA256 Credential=AKID"`, an `X-Amz-Content-Sha256` equal to `sha256Hex` of the body, and the path-style URL `/zbtest/col/r1/a%20b.png` (space encoded).
  - status→error mapping + retry-once: mock 500 → expect `error.S3RequestFailed` after exactly 2 recorded requests; mock 200 → ok with 1.
  - `head` returns raw status for 200/404/403 mocks.
  - `scanKeys` on hostile input: truncated tag, nested junk, 10k keys bound — yields only well-formed keys, never crashes.
  Also `Client.init` endpoint parsing: default host `s3.eu-central-1.amazonaws.com` for region `eu-central-1`; `http://127.0.0.1:9000` endpoint → scheme http + path_style default true; explicit `s3_force_path_style=false` respected.
- [ ] **Step 4: `src/root.zig` test block** — after the postgres block:
  ```zig
      // Opt-in S3 backend (§D): compiled/tested only under -Ds3 (the postgres pattern).
      if (@import("build_options").s3) {
          _ = @import("files/s3.zig");
      }
  ```
- [ ] **Step 5: Run BOTH configs:** `mise exec zig@0.16.0 -- zig build test --summary all` (default — download test runs, s3 module ignored) — expect PASS. `-Ds3=true` still fails to link `S3Storage` until Task 12 — acceptable mid-PR; if you need a green `-Ds3` checkpoint, add a temporary `pub const S3Storage = struct { pub fn create(…) !@This() { return error.NotYetImplemented; } pub fn storage(…) … pub fn deinit(…) void {} };` and note it is replaced next task.
- [ ] **Step 6: Commit** `git add src/http_client.zig src/files/s3.zig src/root.zig && git commit -m "feat(s3): streaming HttpClient.download + SigV4-signed S3 client ops (put/get/delete/head/list, gated -Ds3)"`

---

### Task 12: `S3Storage` — spool cache, startup HeadObject probe, failure semantics

**Files:**
- Modify: `src/files/s3.zig` (the Storage half), `src/framework.zig` (nothing new — Task 9 already wired selection)

**Interfaces:**
- Consumes: Task 10 vtable (`fetch`), Task 11 `Client`.
- Produces: `pub const S3Storage = struct { pub fn create(gpa, io, cfg) !S3Storage; pub fn storage(self: *S3Storage) Storage; pub fn deinit(self: *S3Storage) void; }` — `create` validates config + runs the HeadObject probe (fail-fast); `fetch` spools via the cache; served files ride the §B path so Range/ETag/tenancy are byte-identical to local.

- [ ] **Step 1: implement `S3Storage`** in `s3.zig`:
  ```zig
  pub const S3Storage = struct {
      gpa: std.mem.Allocator,
      client: Client,
      cache_dir: []const u8, // owned
      cache_max_bytes: u64,
      host_buf: [256]u8 = undefined, // backing for a derived default host string

      /// §D.7 startup (fail-fast): config validation, the 5 GiB single-PUT guard, then a
      /// HeadObject PROBE on `<prefix>.zigbase/probe` — 200 OR 404 proves DNS/TLS/SigV4/
      /// bucket/permissions end-to-end (404 expected; it needs exactly the permission
      /// serving needs); 403/301/5xx/connect-failure => refuse to start (the JWT-secret /
      /// FieldKeyRequired precedent). Deliberately a NEW precedent vs SMTP (no probe
      /// there): storage sits on the synchronous request path; mail is queued+retryable.
      pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !S3Storage {
          if (cfg.s3_access_key_id.len == 0) {
              std.log.err("refusing to start: ZIGBASE_S3_BUCKET is set but ZIGBASE_S3_ACCESS_KEY_ID is empty", .{});
              return error.S3ConfigMissing;
          }
          if (cfg.s3_secret_access_key.len == 0) {
              std.log.err("refusing to start: ZIGBASE_S3_BUCKET is set but ZIGBASE_S3_SECRET_ACCESS_KEY is empty", .{});
              return error.S3ConfigMissing;
          }
          inline for (.{ cfg.s3_bucket, cfg.s3_region, cfg.s3_endpoint, cfg.s3_key_prefix }) |v| {
              if (std.mem.indexOfAny(u8, v, "\r\n") != null) return error.S3ConfigInvalid;
          }
          // Request bodies are capped by the zap listener (ZIGBASE_MAX_UPLOAD_SIZE);
          // a single PutObject tops out at 5 GiB — fail fast so the gap can never
          // silently open (multipart upload is an explicit non-goal this round).
          if (cfg.max_upload_size > (5 << 30)) {
              std.log.err("refusing to start: ZIGBASE_MAX_UPLOAD_SIZE ({d}) exceeds the S3 single-PUT limit of 5 GiB", .{cfg.max_upload_size});
              return error.S3UploadCapTooLarge;
          }
          var self = S3Storage{
              .gpa = gpa,
              .client = undefined,
              .cache_dir = if (cfg.s3_cache_dir.len > 0)
                  try gpa.dupe(u8, cfg.s3_cache_dir)
              else
                  try std.fmt.allocPrint(gpa, "{s}/storage_cache", .{cfg.data_dir}),
              .cache_max_bytes = cfg.s3_cache_max_bytes,
          };
          self.client = Client.init(cfg, &self.host_buf);
          if (std.mem.eql(u8, self.client.scheme, "http")) {
              std.log.warn("S3 endpoint {s} is PLAIN HTTP — credentials and objects transit unencrypted; dev/CI only", .{cfg.s3_endpoint});
          }
          var arena = std.heap.ArenaAllocator.init(gpa);
          defer arena.deinit();
          const probe_key = try std.fmt.allocPrint(arena.allocator(), "{s}.zigbase/probe", .{self.client.key_prefix});
          const status = self.client.head(io, arena.allocator(), probe_key) catch |e| {
              std.log.err("refusing to start: S3 HeadObject probe to {s} failed ({s}) — check endpoint/DNS/TLS/credentials", .{ self.client.host, @errorName(e) });
              return error.S3ProbeFailed;
          };
          if (status != 200 and status != 404) {
              std.log.err("refusing to start: S3 HeadObject probe returned {d} (expected 200 or 404) — check bucket name, region, and credentials/permissions", .{status});
              return error.S3ProbeFailed;
          }
          return self;
      }

      pub fn storage(self: *S3Storage) @import("storage.zig").Storage {
          return .{ .ctx = self, .vtable = &vtable };
      }

      pub fn deinit(self: *S3Storage) void {
          self.gpa.free(self.cache_dir);
      }

      const vtable = @import("storage.zig").Storage.VTable{
          .put = putImpl, .fetch = fetchImpl, .delete = deleteImpl, .deleteRecord = deleteRecordImpl,
      };

      /// PutObject with Content-Type from content sniffing (stored as object metadata).
      /// Runs inside the global write transaction — a failure errors into the existing
      /// rollback-plus-best-effort-cleanup path in api/records.zig:147/390 unchanged
      /// (deliberate: a storage failure rolls the row back); the writer-lock latency
      /// trade-off is documented in KNOWN_LIMITATIONS (Task 13). Retry-once lives in
      /// Client.put.
      fn putImpl(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void {
          const self: *S3Storage = @ptrCast(@alignCast(ctx));
          var arena = std.heap.ArenaAllocator.init(self.gpa);
          defer arena.deinit();
          const a = arena.allocator();
          const key = try self.client.objectKey(a, col, record_id, filename);
          try self.client.put(io, a, key, bytes, @import("mime.zig").sniff(bytes));
      }

      /// §D.6 spool: cache hit -> path; miss -> stream GetObject to a .tmp<rand> then
      /// atomically rename (a concurrently-served reader can never see a partial file;
      /// concurrent misses may download twice — both renames idempotent, no
      /// singleflight). Stored names are content-immutable -> no invalidation problem.
      /// 404 from S3 -> null (the backend has no such object); other failures error.
      fn fetchImpl(ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8 {
          const self: *S3Storage = @ptrCast(@alignCast(ctx));
          const path = try std.fs.path.join(alloc, &.{ self.cache_dir, col, record_id, filename });
          if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
              if (st.kind == .file) return path; // spool hit
          } else |_| {}
          var arena = std.heap.ArenaAllocator.init(self.gpa);
          defer arena.deinit();
          const a = arena.allocator();
          const dir = try std.fs.path.join(a, &.{ self.cache_dir, col, record_id });
          try std.Io.Dir.cwd().createDirPath(io, dir);
          var rand_hex: [8]u8 = undefined;
          var rand_bytes: [4]u8 = undefined;
          std.crypto.random.bytes(&rand_bytes);
          _ = std.fmt.bufPrint(&rand_hex, "{x:0>8}", .{std.mem.readInt(u32, &rand_bytes, .big)}) catch unreachable;
          const tmp_path = try std.fmt.allocPrint(a, "{s}.tmp{s}", .{ path, rand_hex });
          const key = try self.client.objectKey(a, col, record_id, filename);
          const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
          var write_buf: [64 * 1024]u8 = undefined;
          var fwriter = f.writer(io, &write_buf);
          const status = self.client.getToWriter(io, a, key, &fwriter.interface) catch |e| {
              f.close(io);
              std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
              return e;
          };
          fwriter.interface.flush() catch {};
          f.close(io);
          if (status == 404) {
              std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
              return null;
          }
          if (status != 200) {
              std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
              return error.S3RequestFailed;
          }
          try std.Io.Dir.cwd().renameFile(io, tmp_path, path); // atomic fill
          self.evictIfOver(io);
          return path;
      }
      // (If std.Io's file-writer/rename spelling differs in this std revision —
      // e.g. `renameFile` lives on Dir with two sub_paths — mirror how records/dumpload
      // code writes+renames files; the CONTRACT is: write tmp, fsync-free atomic rename,
      // never expose a partial file.)

      /// Best-effort remote delete + spool-entry removal (hygiene, not security —
      /// recordReferencesFile already 404s de-referenced names before storage is hit).
      fn deleteImpl(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void {
          const self: *S3Storage = @ptrCast(@alignCast(ctx));
          var arena = std.heap.ArenaAllocator.init(self.gpa);
          defer arena.deinit();
          const a = arena.allocator();
          try self.client.delete(io, a, try self.client.objectKey(a, col, record_id, filename));
          const spool = try std.fs.path.join(a, &.{ self.cache_dir, col, record_id, filename });
          std.Io.Dir.cwd().deleteFile(io, spool) catch {};
      }

      fn deleteRecordImpl(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void {
          const self: *S3Storage = @ptrCast(@alignCast(ctx));
          var arena = std.heap.ArenaAllocator.init(self.gpa);
          defer arena.deinit();
          const a = arena.allocator();
          const prefix = try std.fmt.allocPrint(a, "{s}{s}/{s}/", .{ self.client.key_prefix, col, record_id });
          const keys = try self.client.listKeys(io, a, prefix);
          for (keys) |k| self.client.delete(io, a, k) catch {};
          const spool_dir = try std.fs.path.join(a, &.{ self.cache_dir, col, record_id });
          std.Io.Dir.cwd().deleteTree(io, spool_dir) catch {};
      }

      /// Size-triggered eviction on miss-fill: when the spool exceeds the cap, delete
      /// oldest-mtime entries down to a 3/4 low-water mark. Walk failures are logged
      /// and swallowed — eviction is best-effort, never a serve failure.
      fn evictIfOver(self: *S3Storage, io: std.Io) void {
          var arena = std.heap.ArenaAllocator.init(self.gpa);
          defer arena.deinit();
          const a = arena.allocator();
          const Entry = struct { path: []const u8, mtime: i96, size: u64 };
          var entries: std.ArrayList(Entry) = .empty;
          var total: u64 = 0;
          var dir = std.Io.Dir.cwd().openDir(io, self.cache_dir, .{ .iterate = true }) catch return;
          defer dir.close(io);
          var walker = dir.walk(a) catch return;
          defer walker.deinit();
          while (walker.next(io) catch null) |entry| {
              if (entry.kind != .file) continue;
              const st = dir.statFile(io, entry.path, .{}) catch continue;
              total += st.size;
              entries.append(a, .{ .path = a.dupe(u8, entry.path) catch continue, .mtime = st.mtime.nanoseconds, .size = st.size }) catch continue;
          }
          if (total <= self.cache_max_bytes) return;
          std.mem.sort(Entry, entries.items, {}, struct {
              fn lt(_: void, x: Entry, y: Entry) bool {
                  return x.mtime < y.mtime; // oldest first
              }
          }.lt);
          const low_water = self.cache_max_bytes * 3 / 4;
          for (entries.items) |e| {
              if (total <= low_water) break;
              dir.deleteFile(io, e.path) catch continue;
              total -= e.size;
          }
      }
  };
  ```
  Note `Client.init(cfg, &self.host_buf)` writing the derived default host into caller-owned storage — if the returned-by-value + self-referential buffer is awkward in practice, allocate the host with `gpa` in `create` and free it in `deinit` instead; pick one and keep `Client` non-self-referential.
- [ ] **Step 2: gated tests** (in `s3.zig`; mock seam for network, real tmpDir for the cache):
  - `create` config errors: missing secret names the var (`error.S3ConfigMissing`); `max_upload_size = 6 << 30` → `error.S3UploadCapTooLarge`.
  - probe: mock head → 404 ⇒ create succeeds; 200 ⇒ succeeds; 403 ⇒ `error.S3ProbeFailed`; unmocked+blocked (transport fail) ⇒ `error.S3ProbeFailed`.
  - fetch spool: mock GetObject body "SPOOLME" → fetch returns a path whose contents read back "SPOOLME"; second fetch does NOT issue a second HTTP request (assert the captured request count); mocked 404 → `null`.
  - eviction: `cache_max_bytes = 100`, spool three 60-byte objects (distinct mtimes via direct file writes + `setFilePermissions`-style mtime nudge or just ordering) → oldest evicted, newest survives.
  - delete-evicts: after `deleteImpl` the spool entry is gone.
- [ ] **Step 3: Run** `mise exec zig@0.16.0 -- zig build test --summary all -Ds3=true` — expect PASS (first fully-green `-Ds3` build), and re-run the default build too. **Step 4: Commit** `git add src/files/s3.zig && git commit -m "feat(s3): S3Storage — atomic spool cache, LRU eviction, startup HeadObject probe, fail-fast config"`

---

### Task 13: MinIO CI job + `tests/s3/` e2e + remaining docs + fragment completion

**Files:**
- Modify: `.github/workflows/ci.yml` (new `s3` job after `postgres-tls`)
- Create: `tests/s3/__init__.py` (empty), `tests/s3/test_s3_e2e.py`
- Modify: `src/files/s3.zig` (gated LIVE tests reading `ZIGBASE_S3_TEST_*`), `KNOWN_LIMITATIONS.md`, `README.md`, `docs/framework.md` §9 env table + mirror, `site/src/content/docs/configuration.md`, `changelog.d/s3-storage.md`

**Interfaces:**
- Consumes: everything above. Produces: the merged PR4 + green `s3` CI job.

- [ ] **Step 1: gated live tests** in `s3.zig` (run only when the env is present — the `ZIGBASE_PG_TEST_URL` skip pattern; FIRST read `src/backend/seam_test.zig` and copy its env-reading helper verbatim as a local `fn testEnv(name: []const u8) ?[]const u8`):
  ```zig
  test "LIVE MinIO: put/head/get/list/delete round-trip (object verifiably GONE)" {
      // Deletion-verification lives HERE, where the signer is available (the python
      // e2e can't issue signed S3 requests without a client library).
      const endpoint = testEnv("ZIGBASE_S3_TEST_ENDPOINT") orelse return error.SkipZigTest;
      const bucket = testEnv("ZIGBASE_S3_TEST_BUCKET") orelse return error.SkipZigTest;
      const key_id = testEnv("ZIGBASE_S3_TEST_KEY") orelse return error.SkipZigTest;
      const secret = testEnv("ZIGBASE_S3_TEST_SECRET") orelse return error.SkipZigTest;
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      var host_buf: [256]u8 = undefined;
      const client = Client.init(.{
          .s3_bucket = bucket,
          .s3_endpoint = endpoint,
          .s3_access_key_id = key_id,
          .s3_secret_access_key = secret,
      }, &host_buf);
      const key = "livetest/r1/a_0000000000.png";
      try client.put(std.testing.io, a, key, "LIVE-BYTES", "image/png");
      try std.testing.expectEqual(@as(u16, 200), try client.head(std.testing.io, a, key));
      var buf: [64]u8 = undefined;
      var fw = std.Io.Writer.fixed(&buf);
      try std.testing.expectEqual(@as(u16, 200), try client.getToWriter(std.testing.io, a, key, &fw));
      try std.testing.expectEqualStrings("LIVE-BYTES", fw.buffered());
      const keys = try client.listKeys(std.testing.io, a, "livetest/r1/");
      try std.testing.expectEqual(@as(usize, 1), keys.len);
      try std.testing.expectEqualStrings(key, keys[0]);
      try client.delete(std.testing.io, a, key);
      try std.testing.expectEqual(@as(u16, 404), try client.head(std.testing.io, a, key)); // GONE in MinIO
  }
  ```
- [ ] **Step 2: `tests/s3/test_s3_e2e.py`** — raw-HTTP e2e (urllib pattern from `tests/admin/test_static_files.py`; multipart + superuser helpers from `tests/admin/test_file_range.py` — copy them, tests/s3 has no conftest):
  ```python
  import os, pytest
  pytestmark = pytest.mark.skipif(
      not os.environ.get("ZIGBASE_S3_TEST_ENDPOINT"),
      reason="ZIGBASE_S3_TEST_ENDPOINT not set (MinIO CI job only)")
  ```
  - `test_s3_file_lifecycle`: launch `zigbase serve` (the `-Ds3` binary from `ZIGBASE_TEST_BINARY`) with `ZIGBASE_S3_BUCKET/REGION/ENDPOINT/ACCESS_KEY_ID/SECRET_ACCESS_KEY` mapped from the `ZIGBASE_S3_TEST_*` values → superuser create → collection with a file field (`viewRule: "@public"`) → multipart upload → full GET equals the blob → `Range: bytes=100-` → 206 with correct bytes → `If-None-Match` → 304 → `Range: bytes=<size>-` → 416 → DELETE the record → GET → 404. (Byte-identical §B behavior over the spool — the whole point of §D.6.)
  - `test_s3_bad_credentials_refuses_to_start`: launch with a wrong secret; `proc.wait(timeout=30)` exits non-zero and stderr contains `refusing to start` (capture stderr with `subprocess.PIPE`).
- [ ] **Step 3: CI job** — add after `postgres-tls` (mirrors its docker-run + readiness + `if: always()` teardown; cache key prefix `zig-local-s3-`):
  ```yaml
    # Opt-in S3 storage backend (§D). Builds and tests with -Ds3=true against a real
    # MinIO started via `docker run` (the services: block can't pass the `server /data`
    # command — same reason postgres-tls uses docker run). The default jobs above keep
    # the stock flags, so both configurations compile on every PR (the postgres two-
    # config precedent).
    s3:
      runs-on: ubuntu-latest
      env:
        ZIG_GLOBAL_CACHE_DIR: ${{ github.workspace }}/.zig-global
        ZIG_LOCAL_CACHE_DIR: ${{ github.workspace }}/.zig-local
        ZIGBASE_S3_TEST_ENDPOINT: http://127.0.0.1:9000
        ZIGBASE_S3_TEST_BUCKET: zbtest
        ZIGBASE_S3_TEST_KEY: minioadmin
        ZIGBASE_S3_TEST_SECRET: minioadmin
      steps:
        - uses: actions/checkout@v7
        - uses: jdx/mise-action@v4
        - name: Cache zig global cache
          uses: actions/cache@v5
          with:
            path: ${{ github.workspace }}/.zig-global
            key: zig-global-${{ runner.os }}-zig0.16.0-${{ hashFiles('vendor/sqlite/sqlite3.c', 'build.zig', 'build.zig.zon') }}
            restore-keys: zig-global-${{ runner.os }}-zig0.16.0-
        - name: Cache zig local cache
          uses: actions/cache@v5
          with:
            path: ${{ github.workspace }}/.zig-local
            key: zig-local-s3-${{ runner.os }}-zig0.16.0-${{ hashFiles('vendor/sqlite/sqlite3.c', 'build.zig', 'build.zig.zon') }}-${{ github.sha }}
            restore-keys: |
              zig-local-s3-${{ runner.os }}-zig0.16.0-${{ hashFiles('vendor/sqlite/sqlite3.c', 'build.zig', 'build.zig.zon') }}-
              zig-local-s3-${{ runner.os }}-zig0.16.0-
        - name: Start MinIO + create bucket
          run: |
            docker run -d --name minio -p 9000:9000 \
              -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
              minio/minio:latest server /data
            for i in $(seq 1 30); do
              if curl -sf http://127.0.0.1:9000/minio/health/ready >/dev/null 2>&1; then
                echo "minio ready"; break
              fi
              sleep 2
            done
            docker run --rm --network host --entrypoint sh minio/mc:latest -c \
              "mc alias set local http://127.0.0.1:9000 minioadmin minioadmin && mc mb local/zbtest"
        - name: Unit + live S3 tests (-Ds3=true)
          run: mise exec zig@0.16.0 -- zig build test --summary all -Ds3=true
        - name: Build zigbase (-Ds3=true) for the raw-HTTP e2e
          run: mise exec zig@0.16.0 -- zig build -Ds3=true -Dcpu=baseline
        - name: S3 end-to-end (upload -> Range/304/416 -> delete)
          run: |
            mise exec python@3.13 -- python -m pip install --quiet pytest
            ZIGBASE_TEST_BINARY="$PWD/zig-out/bin/zigbase" \
              mise exec python@3.13 -- python -m pytest tests/s3 -q
        - name: Stop MinIO
          if: always()
          run: docker rm -f minio || true
  ```
- [ ] **Step 4: local verification** — run the MinIO container locally with the same `docker run` lines, then `ZIGBASE_S3_TEST_ENDPOINT=http://127.0.0.1:9000 ZIGBASE_S3_TEST_BUCKET=zbtest ZIGBASE_S3_TEST_KEY=minioadmin ZIGBASE_S3_TEST_SECRET=minioadmin mise exec zig@0.16.0 -- zig build test --summary all -Ds3=true` and the pytest line — expect PASS end-to-end before pushing.
- [ ] **Step 5: docs + limitations.**
  - `docs/framework.md` §9 (+ mirror): the S3 backend section — the `-Ds3` **build requirement**, the full `ZIGBASE_S3_*` env table (spec §D.1 — copy the 9 rows verbatim incl. defaults), proxy-serving via the spool cache ("Range/ETag/tenancy identical to local; presigned-redirect serving is a deferred follow-on"), and the plugin note ("`S3Storage` is exported so custom plugins can wrap it").
  - `site/src/content/docs/configuration.md`: `ZIGBASE_S3_*` env rows; `-Ds3` beside `-Dpostgres`/`-Dvector` in the build-flags section.
  - `README.md`: feature bullet gains S3 noted as `-Ds3`.
  - `KNOWN_LIMITATIONS.md`: remove "an S3 (or other remote) storage backend" from the "Other deferred work" line (52); add a "## S3 storage (`-Ds3`)" section: PutObject runs inside the global write transaction (a slow S3 PUT holds the writer lock — deliberate: a storage failure rolls the row back); deletes are best-effort (orphans possible exactly as with local storage; S3 lifecycle rules are the mitigation); proxy-only serving (no presigned redirects yet); single-PUT ≤ 5 GiB (upload cap enforced at startup).
  - `cd site && mise exec node@24 -- npm run build`.
- [ ] **Step 6: complete `changelog.d/s3-storage.md`** (append below the Task-10 Breaking entry):
  ```markdown
  ### Features
  - Opt-in S3-compatible storage backend (`-Ds3` build flag; AWS S3, MinIO, Cloudflare R2), selected by configuration alone — set `ZIGBASE_S3_*` env vars on an `-Ds3` binary, no code change. Downloads are served through a local spool cache, so Range/ETag/tenancy behavior is byte-identical to local storage. A stock binary with `ZIGBASE_S3_BUCKET` set warns loudly and falls back to local storage. Startup runs a fail-fast HeadObject probe (DNS/TLS/SigV4/bucket/permissions verified before serving).

  ### Internal
  - New `s3` CI job: MinIO via `docker run` + gated live Zig tests + a raw-HTTP upload→Range→delete e2e (`tests/s3/`).
  ```
- [ ] **Step 7: final verification + PR.** Default build: `mise exec zig@0.16.0 -- zig build test --summary all` AND `-Ds3=true` variant; all three examples build; compare `zig build -Doptimize=ReleaseSafe` binary sizes before/after on the default flags (spec §E: expect roughly +15-35 KiB across the whole theme — record the numbers in the PR body, the postgres-gate procedure). Run `mise exec python@3.13 -- python -m pytest tests/admin -q` once more (storage vtable touched the file-serving path). Commit, push, open PR4:
  ```bash
  git add .github/workflows/ci.yml tests/s3 src/files/s3.zig KNOWN_LIMITATIONS.md README.md docs/ site/ changelog.d/s3-storage.md
  git commit -m "feat(s3): MinIO CI job + live/e2e tests, docs, KNOWN_LIMITATIONS"
  ```

---

## Execution notes

- **PR dependency order:** PR1 → merge → PR2 (branches from updated main; Task 6 reuses the Task 1 planner) — PR3 is independent of PR1/PR2 and may run in parallel; PR4 requires PR1 (Response.file / serve() shape) AND PR3 (signer) merged first.
- **Per-PR gate:** unit suite green (both `-Ddev-clock` variants if hooks/clock-adjacent code changed), relevant browser-suite files green locally, site build green when docs changed, fragment present, PR-template sync checklist ticked.
- **What NOT to build (spec non-goals, enforced):** no owned static layer, no nginx-style dir-mode ETags, no RFC-weak dir-mode conditionals, no owned `.gz` handling, no `multipart/byteranges`, no presigned URLs, no S3 multipart upload, no thumbnails, no resumable uploads, no per-path cache rules, no S3 orphan reconciler, no upstream facil.io patch.
