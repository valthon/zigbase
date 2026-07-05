//! Static file serving — the root-path fallback (spec:
//! docs/superpowers/specs/2026-06-10-static-files-design.md).
//! GET/HEAD requests that miss admin, built-in, and custom routes fall through
//! here (server.zig). Sources: a filesystem dir (streamed via Response.file
//! -> zap sendFile) or a build-generated embedded manifest (comptime bytes).
const std = @import("std");
const http = @import("http.zig");
const mime = @import("files/mime.zig");
const serve_file = @import("files/serve_file.zig");

/// One embedded asset. `etag` includes its surrounding quotes (e.g. "\"a1b2c3d4\"")
/// so it can be compared to / emitted as an ETag header value verbatim.
pub const StaticFile = struct {
    path: []const u8, // request path relative to root, '/'-separated, no leading slash
    bytes: []const u8,
    etag: []const u8,
};

/// Comptime mode selected via `App(.{ .static_files = ... })`.
///   .default  — field absent: the `--serve-static <dir>` runtime flag is enabled.
///   .disabled — no static serving; the flag is rejected.
///   .dir      — comptime-hardcoded directory (resolved against cwd at startup).
///   .embedded — assets compiled into the binary (see build.zig embedStaticDir).
pub const Mode = union(enum) {
    default,
    disabled,
    dir: []const u8,
    embedded: []const StaticFile,
};

/// Runtime source resolved in framework.serveImpl and stored on app.App.
pub const Source = union(enum) {
    none,
    dir: []const u8,
    embedded: []const StaticFile,
};

/// One Tier-2 rewrite (issue #183): a comptime-validated `match` pattern -> a fixed
/// `serve` target. Both start with '/'; `serve` names a real document in the active
/// static source (proven at comptime for embedded manifests, at startup for dirs).
pub const StaticRoute = struct { match: []const u8, serve: []const u8 };

/// Miss-handler inputs threaded into `serve` by server.zig (issue #183).
/// `routes` is the comptime-lowered App.static_routes (Tier 2, checked first).
///
/// Tier 1 (the `.spa` marker) resolves differently per source, both gated by
/// `spa_marker_enabled` (mirrors comptime `enable_spa_marker`, default true absent
/// `static_routes`):
///   - **embedded**: the manifest is comptime-static, so `spa_roots` is the startup-
///     derived root set (see `deriveEmbeddedSpaRoots`), matched via `matchSpaRoot`.
///   - **dir**: resolved LIVE, per miss, straight off the filesystem (see
///     `resolveSpaMarkerDirLive`) — adding/removing a `.spa` (or its `index.html`)
///     takes effect on the very next request, no restart, no cache to invalidate.
///     `spa_roots` is unused for `.dir` sources.
///
/// All fields default empty/false: `serve(.., .{})` behaves exactly as before the feature.
pub const Fallback = struct {
    routes: []const StaticRoute = &.{},
    spa_roots: []const []const u8 = &.{},
    spa_marker_enabled: bool = false,
    /// §C.2: the resolved static Cache-Control knob (app.static_cache_control).
    /// null = unset. Embedded assets emit `orelse "max-age=3600"`; dir-mode direct
    /// hits get the value via the facil.io global swap instead (server.zig §C.1).
    cache_control: ?[]const u8 = null,
};

const nosniff = http.Header{ .name = "X-Content-Type-Options", .value = "nosniff" };

pub const RangeNorm = union(enum) { rewrite: []const u8, unsatisfiable };

/// §A.2: rewrite the REQUEST's Range header value into the canonical, closed,
/// in-bounds `bytes=a-b` form — the ONLY form the vendored facil.io parses correctly
/// (http.c ~511-560: `bytes=X-` falls through to a 200, `bytes=-n` computes an offset
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

/// Value of an ASCII hex digit, or null if `c` is not `[0-9A-Fa-f]`.
fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// In-house, SINGLE-PASS percent-decoder for request paths. `%XX` (two ASCII hex
/// digits) decodes to the byte; a `%` NOT followed by two hex digits is emitted
/// literally (so `%2`, `%zz`, a trailing `%` yield a literal `%` — a filename that
/// won't exist, i.e. 404, fail-closed — never an error). `+` is NOT decoded to space
/// (that is query-string, not path, semantics). Single-pass by construction: the
/// output byte is never re-examined, so `%252e` -> the literal `%2e` (never `.`),
/// which is what stops double-encoding from smuggling a `..` past sanitize()'s
/// traversal checks. Caller owns the returned slice.
fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        // `i + 2 < s.len` guarantees s[i+1] and s[i+2] are both valid indices.
        if (c == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                out.appendAssumeCapacity((@as(u8, hi.?) << 4) | @as(u8, lo.?));
                i += 3;
                continue;
            }
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return try out.toOwnedSlice(alloc);
}

/// Normalize a request path into a root-relative, '/'-separated file path.
/// Returns null for unsafe paths (no leading '/', NUL, backslash, "..").
/// "" means "the root" (callers resolve it to index.html). Caller owns the slice.
pub fn sanitize(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    // NOTE (audited): the request path arrives raw (facil.io's http1 parser stores it
    // un-decoded, zap passes it through untouched, and facil.io's http_decode_path only
    // runs inside http_sendfile2 on an `encoded` arg that zap calls with NULL). We
    // percent-decode it HERE — SINGLE-PASS, in-house (see percentDecode) — BEFORE every
    // traversal check, so all the checks below see the DECODED bytes:
    //   * "%2e%2e" -> ".." -> caught (the per-segment ".." check).
    //   * "%2f" -> "/" -> a real segment boundary, and each segment is still ".."-checked,
    //     so "foo%2f%2e%2e%2fbar" -> "foo/../bar" -> the ".." segment is caught.
    //   * "%00" -> NUL -> caught; "%5c" -> backslash -> caught.
    //   * Double-encoding is NOT recursively decoded: "%252e" -> the literal "%2e"
    //     (never "."), so "%252e%252e" is the harmless segment "%2e%2e", not "..".
    //   * A malformed escape ("%2", "%zz", trailing "%") stays a literal "%": a filename
    //     that won't exist -> 404, fail-closed.
    // Net effect: percent-encoded filenames ("my file.pdf" -> /my%20file.pdf) are now
    // servable, while encoded traversal is decoded and then rejected fail-closed. The F10
    // symlink guard (a separate runtime realpath check on the resolved path) is unchanged
    // and still runs after these lexical checks.
    // Fast path: the vast majority of requests carry no `%`, and with no percent-escape the
    // decoded bytes are identical to `path` — so skip the decode allocation entirely and run
    // the checks on `path` directly. Only allocate a decoded buffer when a `%` is present.
    const needs_decode = std.mem.indexOfScalar(u8, path, '%') != null;
    const decoded = if (needs_decode) try percentDecode(alloc, path) else path;
    defer if (needs_decode) alloc.free(decoded);
    if (decoded.len == 0 or decoded[0] != '/') return null;
    if (std.mem.indexOfScalar(u8, decoded, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, decoded, '\\') != null) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, decoded, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            out.deinit(alloc);
            return null;
        }
        if (out.items.len > 0) try out.append(alloc, '/');
        try out.appendSlice(alloc, seg);
    }
    return try out.toOwnedSlice(alloc);
}

/// RFC 7232: a 304 carries the headers the 200 would have sent, so it reports
/// the file's real content type rather than a placeholder.
fn notModified(content_type: []const u8, headers: []const http.Header) http.Response {
    return .{ .status = 304, .body = "", .content_type = content_type, .extra_headers = headers };
}

fn findEmbedded(files: []const StaticFile, rel: []const u8) ?*const StaticFile {
    for (files) |*f| {
        if (std.mem.eql(u8, f.path, rel)) return f;
    }
    return null;
}

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

/// True iff `candidate` is the same path as `root` or lives strictly beneath it
/// (a '/'-bounded prefix, so "/a/rootEVIL" is NOT considered inside "/a/root").
fn withinRoot(root: []const u8, candidate: []const u8) bool {
    // Normalize a trailing slash OFF the root first, so "/srv/www/" and "/srv/www"
    // behave identically (the prefix/boundary checks below all run against `r`).
    const r = if (root.len > 0 and root[root.len - 1] == '/') root[0 .. root.len - 1] else root;
    if (!std.mem.startsWith(u8, candidate, r)) return false;
    if (candidate.len == r.len) return true; // exact same path
    return candidate[r.len] == '/'; // boundary must be a separator (so "/a/rootEVIL" is rejected)
}

/// "" for a root marker (".spa"), "app/x" for "app/x/.spa", null when `path` is not
/// a marker file path. `path` is root-relative and '/'-separated.
fn markerPrefix(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, ".spa")) return "";
    if (std.mem.endsWith(u8, path, "/.spa")) return path[0 .. path.len - "/.spa".len];
    return null;
}

/// True when the sanitized path's final segment is ".spa" (ASCII case-insensitive) —
/// the marker file itself is never servable (its bytes are meaningless and dir/embedded
/// sources would otherwise happily serve it). Other dotfiles (.well-known/...) are
/// unaffected. Case-insensitive because dir-mode stat on a case-insensitive filesystem
/// (macOS's default APFS/HFS+ volumes) resolves "GET /.SPA" to the same file as ".spa",
/// so the "never servable" invariant must hold regardless of request-path casing —
/// otherwise the marker's contents (deliberately meaningless, but still readable server
/// state) would leak on those platforms.
fn isSpaMarkerPath(rel: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    return std.ascii.eqlIgnoreCase(base, ".spa");
}

/// The longest scanned SPA root that is a '/'-bounded prefix of the sanitized `rel`
/// ("" matches everything). `roots` is sorted longest-first, so the first hit wins
/// (nested markers: the innermost marker claims the miss).
fn matchSpaRoot(roots: []const []const u8, rel: []const u8) ?[]const u8 {
    for (roots) |root| {
        if (root.len == 0) return root;
        if (std.mem.startsWith(u8, rel, root) and
            (rel.len == root.len or rel[root.len] == '/')) return root;
    }
    return null;
}

/// Minimal segment matcher for Tier-2 `static_routes` (issue #183). `pattern` is a
/// comptime-validated route pattern (leading '/'; segments are literals, ":name", or a
/// terminal "*"/"**"); `rel` is a sanitize()d root-relative path ("" = the root).
///   :name — exactly one segment (capture discarded; `serve` is a fixed path)
///   *     — one or more remaining segments (the bare prefix does NOT match)
///   **    — zero or more remaining segments (the bare prefix DOES match)
/// First-match-wins ordering is the caller's job; this answers a single pattern.
pub fn matchRoute(pattern: []const u8, rel: []const u8) bool {
    if (pattern.len <= 1) return rel.len == 0; // "/" matches only the root
    var pit = std.mem.splitScalar(u8, pattern[1..], '/');
    var rit = std.mem.splitScalar(u8, rel, '/');
    // splitScalar("") still yields one "" segment; treat the root as zero segments.
    const rel_empty = rel.len == 0;
    while (pit.next()) |pseg| {
        if (std.mem.eql(u8, pseg, "**")) return true; // rest-matcher, zero or more
        if (std.mem.eql(u8, pseg, "*")) // rest-matcher, one or more
            return !rel_empty and rit.next() != null;
        const rseg = (if (rel_empty) null else rit.next()) orelse return false;
        if (pseg.len > 1 and pseg[0] == ':') continue; // one segment, any (non-empty) value
        if (!std.mem.eql(u8, pseg, rseg)) return false;
    }
    return rit.next() == null; // pattern exhausted: match iff the path has no segments left either
}

/// Startup derivation (Tier 1, EMBEDDED source only, issue #183): collect every
/// directory in the manifest containing a file named exactly `.spa`, as root-relative
/// '/'-separated prefixes ("" = the static root itself), sorted longest-first. An
/// embedded manifest is comptime-static (baked into the binary), so this set never goes
/// stale — there's no live filesystem to re-check per request, unlike dir mode below.
/// A marked directory without an `index.html` gets a startup warning and is dropped
/// (degrades to unmarked — misses there 404 or fall through to an enclosing marker).
/// Caller frees via `freeSpaRoots`.
pub fn deriveEmbeddedSpaRoots(alloc: std.mem.Allocator, files: []const StaticFile) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roots.items) |r| alloc.free(r);
        roots.deinit(alloc);
    }
    for (files) |f| {
        const prefix = markerPrefix(f.path) orelse continue;
        const has_index = if (prefix.len == 0)
            findEmbedded(files, "index.html") != null
        else blk: {
            const idx = try std.fmt.allocPrint(alloc, "{s}/index.html", .{prefix});
            defer alloc.free(idx);
            break :blk findEmbedded(files, idx) != null;
        };
        if (!has_index) {
            std.log.warn("SPA marker at '{s}/' has no index.html; marker ignored", .{prefix});
            continue;
        }
        try roots.append(alloc, try alloc.dupe(u8, prefix));
    }
    // Longest-first so the first '/'-bounded hit in matchSpaRoot is the innermost
    // marker; equal-length ties break lexically for determinism.
    std.mem.sort([]const u8, roots.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            if (x.len != y.len) return x.len > y.len;
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return try roots.toOwnedSlice(alloc);
}

/// Free a `deriveEmbeddedSpaRoots` result. Safe to call on the comptime-empty slice the
/// marker-disabled path uses (no-op).
pub fn freeSpaRoots(alloc: std.mem.Allocator, roots: []const []const u8) void {
    if (roots.len == 0) return;
    for (roots) |r| alloc.free(r);
    alloc.free(roots);
}

/// A `validateSpaMarkersDir` startup failure: the offending `.spa`-marked directory
/// (root-relative, '/'-separated; "" = the static root) and why it's fatal.
pub const SpaValidateFailure = struct {
    /// Allocated with the `alloc` passed to `validateSpaMarkersDir` (alloc.dupe); only
    /// populated when that call returns `error.SpaValidationFailed`. The caller owns it
    /// and must free it once done (e.g. after logging it).
    path: []const u8,
    reason: enum { missing_index },
};

/// Startup VALIDATION (Tier 1, DIR source only, issue #183 — owner revision): unlike
/// embedded mode, dir-mode markers are resolved LIVE at request time (see
/// `resolveSpaMarkerDirLive`) — this function does NOT build a cached root set. Its only
/// job is to catch, once at startup, the one dir-mode marker mistake that must never
/// reach production silently: a `.spa`-marked directory with no `index.html` (nothing to
/// serve as the shell — almost certainly a build/deploy mistake). That is FATAL,
/// returned via `out_failure` + `error.SpaValidationFailed` (mirrors
/// `validateRouteTargetsDir`'s pattern: return the failure instead of logging directly,
/// so the caller can log — logging in here would trip the unit test runner's "logged N
/// errors" failure on the expected-failure test path).
///
/// A subdirectory the walk can't enter (permission-denied, vanished, symlink loop, ...)
/// is explicitly NOT fatal here — see the owner's failure matrix: unreadable content is
/// treated exactly like it doesn't exist (skipped, with a `std.log.warn` naming the
/// skipped path), matching how dir-mode serving already 404s cleanly on an unreadable
/// file rather than erroring. The root `openDir` probe in framework.zig remains the
/// fatal gate for an inaccessible static dir itself.
pub fn validateSpaMarkersDir(io: std.Io, alloc: std.mem.Allocator, root: []const u8, out_failure: ?*SpaValidateFailure) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    // SelectiveWalker (not the plain Walker) so `enter()` is called explicitly, per
    // entry — its failure is caught and skipped (warn + continue) rather than aborting
    // the whole validation pass, per the owner's "unreadable = act like it doesn't
    // exist" rule.
    var walker = try dir.walkSelectively(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            walker.enter(io, entry) catch |err| {
                std.log.warn("SPA marker scan: skipping unreadable path '{s}' ({t})", .{ entry.path, err });
                continue;
            };
            continue;
        }
        if (entry.kind != .file) continue;
        const prefix = markerPrefix(entry.path) orelse continue;
        const has_index = blk: {
            const idx = if (prefix.len == 0)
                try alloc.dupe(u8, "index.html")
            else
                try std.fmt.allocPrint(alloc, "{s}/index.html", .{prefix});
            defer alloc.free(idx);
            const st = dir.statFile(io, idx, .{}) catch break :blk false;
            break :blk st.kind == .file;
        };
        if (!has_index) {
            if (out_failure) |of| of.* = .{ .path = try alloc.dupe(u8, prefix), .reason = .missing_index };
            return error.SpaValidationFailed;
        }
    }
}

/// Cap on the number of ancestor levels `resolveSpaMarkerDirLive` will `statFile` before
/// giving up on the "walk every level" strategy and jumping straight to the root check —
/// deeper than any plausible static tree (a real SPA route nesting 64+ segments deep does
/// not exist in practice). Bounds the per-request-miss filesystem cost to O(1) `statFile`
/// calls regardless of how deep a crafted request path claims to be, instead of O(path
/// length): every cache-miss on a dir-mode static tree pays this walk, so an attacker
/// sending a request path with thousands of `/`-separated segments must not be able to
/// turn that into thousands of syscalls per request.
const spa_marker_walk_cap = 64;

/// Live per-miss resolution (Tier 1, DIR source only, issue #183 — owner revision):
/// walk `rel`'s ancestor directories from deepest to the static root (inclusive),
/// stat'ing each candidate for a `.spa` marker; the first (deepest, i.e. innermost)
/// marked ancestor wins — this preserves the same longest-'/'-bounded-prefix semantics
/// `matchSpaRoot` gives the embedded/comptime root set, but reads the filesystem fresh
/// on every miss instead of consulting a startup-cached list. That means a `.spa` (or
/// its `index.html`) added, removed, or edited after boot takes effect on the very next
/// request — no restart, no watcher, no cache invalidation.
///
/// Bounded to `spa_marker_walk_cap` ancestor levels (see its doc comment): if `rel` is
/// deeper than that, only the `spa_marker_walk_cap` innermost ancestors are actually
/// `statFile`'d for a marker — deepest-wins semantics are preserved exactly among those
/// checked levels — and then the walk jumps straight to the static root ("") as the
/// final check, skipping the (attacker-controlled, unboundedly many) intermediate levels
/// between the cap and the root. This never breaks a legitimate deployment: no real
/// static tree nests a `.spa` marker 64+ directories deep, and the root marker — the most
/// common case, "the whole site is one SPA" — is still always checked.
///
/// Returns the root-relative shell path to serve (e.g. "app/index.html", or
/// "index.html" for a root marker) via `serveRel`, or `null` when no ancestor is marked
/// OR the deepest marked ancestor's `index.html` is missing/unreadable (treated as "no
/// marker here", consistent with "unreadable = doesn't exist" — it does NOT fall
/// through to try the next-outer ancestor, mirroring the startup-scan precedent where a
/// missing index drops that one marker rather than promoting an enclosing one).
/// Every stat failure (`AccessDenied`, `FileNotFound`, ...) is swallowed as "absent"; a
/// permission problem here degrades to a plain 404, exactly like `serveDir` already does
/// for an ordinary unreadable file — it is never a request-time error.
fn resolveSpaMarkerDirLive(io: std.Io, alloc: std.mem.Allocator, root: []const u8, rel: []const u8) !?[]const u8 {
    var dir_root = std.Io.Dir.cwd().openDir(io, root, .{}) catch return null;
    defer dir_root.close(io);

    // Start at `rel`'s OWN containing directory (a miss at "app/orders/1" first checks
    // "app/orders", not "app/orders/1" — the marker lives in a directory, never beside a
    // file), then walk upward one segment at a time to "" (the static root), inclusive.
    var dir_rel: []const u8 = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[0..i] else "";
    var levels_checked: u32 = 0;
    while (true) {
        levels_checked += 1;
        // Cap hit before reaching the root: skip directly to the root as the final,
        // deepest-remaining check rather than continuing to walk the unboundedly many
        // intermediate levels a crafted path could otherwise force.
        if (levels_checked > spa_marker_walk_cap and dir_rel.len != 0) dir_rel = "";

        const marker_path = try std.fmt.allocPrint(alloc, "{s}{s}.spa", .{ dir_rel, if (dir_rel.len == 0) "" else "/" });
        defer alloc.free(marker_path);
        const marked = blk: {
            const st = dir_root.statFile(io, marker_path, .{}) catch break :blk false;
            break :blk st.kind == .file;
        };
        if (marked) {
            const idx_path = try std.fmt.allocPrint(alloc, "{s}{s}index.html", .{ dir_rel, if (dir_rel.len == 0) "" else "/" });
            errdefer alloc.free(idx_path);
            const has_index = blk: {
                const ist = dir_root.statFile(io, idx_path, .{}) catch break :blk false;
                break :blk ist.kind == .file;
            };
            if (has_index) return idx_path;
            alloc.free(idx_path);
            return null; // marked but no index.html: absent, do not fall through outward
        }

        if (dir_rel.len == 0) return null; // reached the root; no marker anywhere
        dir_rel = if (std.mem.lastIndexOfScalar(u8, dir_rel, '/')) |i| dir_rel[0..i] else "";
    }
}

/// Startup validation (Tier 2, dir mode; issue #183): every `serve` target must resolve
/// to a real file under `root` — the exact path, its `/index.html` when it names a
/// directory, or the root `index.html` for "/". A missing target is a FATAL startup
/// error, mirroring the missing-static-dir precedent (embedded targets are proven at
/// comptime instead; comptime can't see the filesystem).
///
/// Deliberately silent: unlike the sibling comptime `@compileError`s in framework.zig,
/// this returns the offending route (or `null` when every target resolves) instead of
/// logging directly, like `std.Io.Dir.openDir` failing for the missing-static-dir check
/// in `serveImpl`. The caller (the real startup path) logs and turns it into
/// `error.StaticRouteTargetMissing`; unit tests exercise the return value without
/// tripping the test runner's "logged N errors" failure on the expected-failure path.
pub fn validateRouteTargetsDir(io: std.Io, alloc: std.mem.Allocator, root: []const u8, routes: []const StaticRoute) !?StaticRoute {
    for (routes) |rt| {
        const rel = std.mem.trimStart(u8, rt.serve, "/");
        const full = if (rel.len == 0)
            try std.fmt.allocPrint(alloc, "{s}/index.html", .{root})
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, rel });
        defer alloc.free(full);
        const ok = blk: {
            const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch break :blk false;
            if (st.kind == .file) break :blk true;
            if (st.kind != .directory) break :blk false;
            const idx = try std.fmt.allocPrint(alloc, "{s}/index.html", .{full});
            defer alloc.free(idx);
            const ist = std.Io.Dir.cwd().statFile(io, idx, .{}) catch break :blk false;
            break :blk ist.kind == .file;
        };
        if (!ok) return rt;
    }
    return null;
}

fn serveDir(io: std.Io, ctx: *http.RequestCtx, root: []const u8, rel: []const u8) !?http.Response {
    const first = if (rel.len == 0) "index.html" else rel;
    var full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ root, first });
    var st = std.Io.Dir.cwd().statFile(io, full, .{}) catch return null;
    if (st.kind == .directory) {
        full = try std.fmt.allocPrint(ctx.allocator, "{s}/index.html", .{full});
        st = std.Io.Dir.cwd().statFile(io, full, .{}) catch return null;
    }
    if (st.kind != .file) return null;
    // F10: lexical sanitize() already blocks ".."/backslash/NUL, but a symlink INSIDE
    // the root can still point outside it (statFile follows symlinks). Canonicalize the
    // matched file AND the root, and refuse to serve anything whose real path escapes the
    // real root. realPathFile resolves every symlinked component; a miss/escape => 404.
    const real_root = std.Io.Dir.cwd().realPathFileAlloc(io, root, ctx.allocator) catch return null;
    const real_full = std.Io.Dir.cwd().realPathFileAlloc(io, full, ctx.allocator) catch return null;
    if (!withinRoot(real_root, real_full)) return null;
    // §A.2 shim: normalize the Range header against the size of the file facil.io
    // WILL serve — mirroring its .gz sidecar probe (http.c:449-470: Accept-Encoding
    // contains "gzip" -> stat "<path>.gz") — then keep delegating. The shim only edits
    // request-header VALUES; facil.io still assembles the 206/Content-Range itself.
    const raw_range = ctx.header("range") orelse "";
    if (raw_range.len > 0) {
        // #192 / RFC 9110 §13.1.5: the vendored facil.io If-Range branch is INVERTED
        // (http.c ~511-517) — it DELETES the Range header (forcing a wrong full 200) when
        // If-Range MATCHES the current ETag, and honors the Range (206) when it does NOT.
        // RFC says the opposite: a MATCH honors the Range (resume the transfer, 206); a
        // MISMATCH ignores it (the client's cached partial is stale, so 200). We cannot
        // recompute facil.io's dir-mode ETag to do the strong comparison ourselves — it is
        // seeded from ASLR'd function-pointer addresses (facil.io fio.h FIO_HASH_FN over
        // &fiobj_each2/&fiobj_free_complex_object), so it is non-reproducible outside the
        // process and even changes across restarts. Instead we BLANK If-Range before
        // delegating, which forces facil.io down its "no If-Range" else-branch — the one
        // that always HONORS a present Range. Net effect: the resume/MATCH case now
        // correctly yields 206 (the reported bug); the MISMATCH case is byte-identical to
        // today (facil.io already served 206 there). The residual RFC gap (a MISMATCH
        // should suppress the Range -> full 200) is undetectable here for the same
        // non-reproducible-ETag reason and is noted in KNOWN_LIMITATIONS; it IS fully
        // correct on the OWNED paths (record files, embedded static) where zigbase mints
        // and strong-compares its own ETag (files/serve_file.zig plan()).
        const had_if_range = ctx.header("if-range") != null;
        if (had_if_range) ctx.setRequestHeader("if-range", "");
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
            // If-Range originally ABSENT: facil.io is guaranteed to process the range, so
            // answer the unsatisfiable form with the owned 416 it cannot emit itself. If
            // If-Range was originally PRESENT (now blanked): keep today's behavior and let
            // facil.io serve its 200 for the unsatisfiable form (the MISMATCH-should-be-200
            // corner already yields a non-206 there — see the note above).
            .unsatisfiable => if (!had_if_range) {
                // Tiny owned response — the one static status facil.io cannot emit.
                const hs416 = try ctx.allocator.dupe(http.Header, &.{
                    .{ .name = "Content-Range", .value = try std.fmt.allocPrint(ctx.allocator, "bytes */{d}", .{size}) },
                    nosniff,
                });
                return .{ .status = 416, .body = "", .content_type = mime.fromExtension(full), .extra_headers = hs416 };
            },
        };
    }
    // Dir mode delegates ETag/Last-Modified/Cache-Control(max-age=3600)/If-None-Match/304
    // handling to facil.io's sendFile (http_sendfile2), which always emits its own etag
    // and answers conditional requests itself — adding ours would put two ETag headers
    // on the wire. Embedded mode keeps zigbase's CRC32 ETag because plain body responses
    // get no transport etag. The Vary is needed alongside the .gz sidecar probe above:
    // facil.io never sets Vary itself, so a shared cache in front of dir mode must be
    // told the body (and this shim's own size-driven Range math) depends on
    // Accept-Encoding — no duplicate header is possible.
    const hs = try ctx.allocator.alloc(http.Header, 2);
    hs[0] = nosniff;
    hs[1] = .{ .name = "Vary", .value = "Accept-Encoding" };
    return .{
        .status = 200,
        .body = "",
        .content_type = mime.fromExtension(full),
        .file = .{ .path = full },
        .extra_headers = hs,
    };
}

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

/// Resolve `source` to serve one relative path (shared by the direct lookup and both
/// fallback tiers, so fallback documents inherit ETag/304/HEAD/nosniff/F10 for free).
fn serveRel(io: std.Io, ctx: *http.RequestCtx, source: Source, rel: []const u8, cache_control: []const u8) !?http.Response {
    return switch (source) {
        .none => unreachable, // gated in serve()
        .embedded => |files| serveEmbedded(ctx, files, rel, cache_control),
        .dir => |root| serveDir(io, ctx, root, rel), // dir-mode CC = the facil.io global (§C.1)
    };
}

/// Serve `ctx.path` from `source`. Returns null when nothing matches (the caller
/// emits its 404), including for non-GET/HEAD methods and `.none` sources.
/// HEAD gets the same response as GET (status + headers + body/file);
/// stripping the body for HEAD is the transport layer's (zap/facil.io) job.
///
/// Miss resolution (issue #183, owner revision — dir-mode markers are LIVE), in order:
///   1. api-prefixed misses NEVER reach ANY static content (defense-in-depth, see below);
///   2. the '.spa' marker file itself is never servable (skips the file lookup);
///   3. a real file always wins (incl. directory -> index.html resolution);
///   4. Tier 2: the first matching `fb.routes` entry serves its fixed target —
///      terminal even if the target went missing after startup validation;
///   5. Tier 1: **embedded** — the longest '/'-bounded `fb.spa_roots` prefix (a startup-
///      derived, comptime-static set) serves `<root>/index.html`. **dir** — resolved
///      LIVE off the filesystem every miss (`resolveSpaMarkerDirLive`): no cached root
///      set, so a `.spa` added/removed/edited after boot takes effect immediately;
///   6. null (the caller's plain-text 404, unchanged).
pub fn serve(io: std.Io, ctx: *http.RequestCtx, source: Source, fb: Fallback) !?http.Response {
    if (ctx.method != .GET and ctx.method != .HEAD) return null;
    if (std.meta.activeTag(source) == .none) return null;
    const rel = (try sanitize(ctx.allocator, ctx.path)) orelse return null;
    // Defense-in-depth (final review; hoisted per follow-up review — owner decision):
    // server.zig already keeps the whole `/api` namespace out of static serving by
    // gating on the RAW request path, but that gate and this fallback's normalization
    // (sanitize() collapses "//api/x" -> "api/x") can disagree — a raw "//api/x" fails
    // the byte-literal "/api/" prefix check upstream yet normalizes to an api-looking
    // `rel` here. Refuse it on the normalized path BEFORE any file lookup (real file,
    // Tier 2, or Tier 1), so no such disagreement can ever serve an api-looking miss —
    // real static file or fallback document alike — instead of a 404. In the normal
    // (non-normalized) case this is a no-op: `/api/*` never reaches this function at
    // all, since server.zig's raw-path gate already routes it to the API's JSON 404.
    if (std.mem.eql(u8, rel, "api") or std.mem.startsWith(u8, rel, "api/")) return null;
    const cc_default: []const u8 = fb.cache_control orelse "max-age=3600";
    if (!isSpaMarkerPath(rel)) {
        if (try serveRel(io, ctx, source, rel, cc_default)) |hit| return hit;
    }
    for (fb.routes) |rt| {
        if (matchRoute(rt.match, rel))
            return serveRel(io, ctx, source, std.mem.trimStart(u8, rt.serve, "/"), cc_default);
    }
    if (!fb.spa_marker_enabled) return null;
    switch (source) {
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
        .dir => |root| {
            const shell = (try resolveSpaMarkerDirLive(io, ctx.allocator, root, rel)) orelse return null;
            return serveShellOwned(io, ctx, root, shell);
        },
        .none => unreachable, // gated above
    }
}

test "withinRoot: exact path, trailing-slash root, and sibling rejection (F10)" {
    // A file strictly beneath the root is within it.
    try std.testing.expect(withinRoot("/srv/www", "/srv/www/index.html"));
    // A trailing slash on the root must not change the result (regression: it used to make
    // the exact-same-path and same-path-vs-slashed-root cases wrongly return false).
    try std.testing.expect(withinRoot("/srv/www/", "/srv/www/index.html"));
    try std.testing.expect(withinRoot("/srv/www", "/srv/www")); // exact same path
    try std.testing.expect(withinRoot("/srv/www/", "/srv/www")); // same path, trailing-slash root
    // A sibling that merely shares the root as a string prefix is NOT inside it.
    try std.testing.expect(!withinRoot("/srv/www", "/srv/wwwEVIL/x"));
    try std.testing.expect(!withinRoot("/srv/www/", "/srv/wwwEVIL/x"));
    // A wholly unrelated path is rejected.
    try std.testing.expect(!withinRoot("/srv/www", "/etc/passwd"));
}

test "sanitize: normal paths normalize to root-relative" {
    const a = std.testing.allocator;
    const s1 = (try sanitize(a, "/index.html")).?;
    defer a.free(s1);
    try std.testing.expectEqualStrings("index.html", s1);
    const s2 = (try sanitize(a, "/a//b///c.js")).?;
    defer a.free(s2);
    try std.testing.expectEqualStrings("a/b/c.js", s2);
    const s3 = (try sanitize(a, "/")).?;
    defer a.free(s3);
    try std.testing.expectEqualStrings("", s3);
    const s4 = (try sanitize(a, "/docs/")).?;
    defer a.free(s4);
    try std.testing.expectEqualStrings("docs", s4);
    const s5 = (try sanitize(a, "/a/./b.css")).?;
    defer a.free(s5);
    try std.testing.expectEqualStrings("a/b.css", s5);
}

test "sanitize: traversal and junk are rejected" {
    const a = std.testing.allocator;
    try std.testing.expect((try sanitize(a, "/../etc/passwd")) == null);
    try std.testing.expect((try sanitize(a, "/a/../../b")) == null);
    try std.testing.expect((try sanitize(a, "/a/..")) == null);
    try std.testing.expect((try sanitize(a, "/a\\b")) == null);
    try std.testing.expect((try sanitize(a, "/a\x00b")) == null);
    try std.testing.expect((try sanitize(a, "no-leading-slash")) == null);
}

test "sanitize: percent-decoded filenames are servable" {
    const a = std.testing.allocator;
    const s1 = (try sanitize(a, "/my%20file.pdf")).?;
    defer a.free(s1);
    try std.testing.expectEqualStrings("my file.pdf", s1);
    // UTF-8 encoded filename decodes to its raw bytes.
    const s2 = (try sanitize(a, "/caf%C3%A9.txt")).?;
    defer a.free(s2);
    try std.testing.expectEqualStrings("café.txt", s2);
    // Encoded separator becomes a real segment boundary; neither segment is "..".
    const s3 = (try sanitize(a, "/a%2fb")).?;
    defer a.free(s3);
    try std.testing.expectEqualStrings("a/b", s3);
    // Uppercase hex works too.
    const s4 = (try sanitize(a, "/my%2Ofile")).?; // %2O is malformed (O is not hex) -> literal
    defer a.free(s4);
    try std.testing.expectEqualStrings("my%2Ofile", s4);
}

test "sanitize: encoded traversal is decoded then rejected fail-closed" {
    const a = std.testing.allocator;
    // %2e%2e -> ".." caught.
    try std.testing.expect((try sanitize(a, "/%2e%2e/secret")) == null);
    try std.testing.expect((try sanitize(a, "/foo/%2e%2e/bar")) == null);
    // %2f decodes to a separator, exposing the ".." segment.
    try std.testing.expect((try sanitize(a, "/%2e%2e%2fetc/passwd")) == null);
    try std.testing.expect((try sanitize(a, "/foo%2f%2e%2e%2fbar")) == null);
    // Encoded NUL and backslash are caught.
    try std.testing.expect((try sanitize(a, "/%00")) == null);
    try std.testing.expect((try sanitize(a, "/a%5cb")) == null);
    // Mixed-case hex still decodes and is caught.
    try std.testing.expect((try sanitize(a, "/%2E%2E/x")) == null);
}

test "sanitize: percent-decoding is single-pass (no recursive decode)" {
    const a = std.testing.allocator;
    // %25 -> '%', so %252e -> "%2e" (a literal, NOT "."). Double-encoding cannot
    // smuggle a "..": the decoded segment is "%2e%2e", which is not "..".
    const s = (try sanitize(a, "/%252e%252e")).?;
    defer a.free(s);
    try std.testing.expectEqualStrings("%2e%2e", s);
}

test "sanitize: malformed escapes are tolerated as literals" {
    const a = std.testing.allocator;
    // '%' not followed by two hex digits -> literal '%'.
    const s1 = (try sanitize(a, "/foo%2")).?;
    defer a.free(s1);
    try std.testing.expectEqualStrings("foo%2", s1);
    const s2 = (try sanitize(a, "/foo%zz")).?;
    defer a.free(s2);
    try std.testing.expectEqualStrings("foo%zz", s2);
    // Trailing '%'.
    const s3 = (try sanitize(a, "/foo%")).?;
    defer a.free(s3);
    try std.testing.expectEqualStrings("foo%", s3);
}

test "percentDecode: single-pass byte decoding" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "my%20file.pdf", .out = "my file.pdf" },
        .{ .in = "plain", .out = "plain" },
        .{ .in = "%2e%2e", .out = ".." },
        .{ .in = "%252e", .out = "%2e" }, // single pass: %25 -> '%', then "2e" literal
        .{ .in = "a+b", .out = "a+b" }, // '+' is NOT decoded to space (path semantics)
        .{ .in = "%2", .out = "%2" }, // truncated escape -> literal
        .{ .in = "%zz", .out = "%zz" }, // non-hex -> literal
        .{ .in = "%", .out = "%" }, // trailing '%'
        .{ .in = "%C3%A9", .out = "café"[3..] }, // the two UTF-8 bytes of é
    };
    for (cases) |c| {
        const got = try percentDecode(a, c.in);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

const fixture = [_]StaticFile{
    .{ .path = "index.html", .bytes = "<h1>home</h1>", .etag = "\"11111111\"" },
    .{ .path = "assets/app.js", .bytes = "console.log(1)", .etag = "\"22222222\"" },
    .{ .path = "docs/index.html", .bytes = "<h1>docs</h1>", .etag = "\"33333333\"" },
};

test "embedded: exact file, root index, directory index, miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &fixture };

    var ctx = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &ctx, src, .{})).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("console.log(1)", r.body);
    try std.testing.expectEqualStrings("application/javascript", r.content_type);
    // 200s now carry [ETag, nosniff, Cache-Control, Accept-Ranges] (§A.4/§C.2).
    try std.testing.expectEqual(@as(usize, 4), r.extra_headers.len);
    try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
    try std.testing.expectEqualStrings("\"22222222\"", r.extra_headers[0].value);

    var root = http.RequestCtx{ .method = .GET, .path = "/", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &root, src, .{})).?.body);

    var d1 = http.RequestCtx{ .method = .GET, .path = "/docs", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>docs</h1>", (try serve(std.testing.io, &d1, src, .{})).?.body);
    var d2 = http.RequestCtx{ .method = .GET, .path = "/docs/", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>docs</h1>", (try serve(std.testing.io, &d2, src, .{})).?.body);

    var miss = http.RequestCtx{ .method = .GET, .path = "/nope.png", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &miss, src, .{})) == null);

    // HEAD is served like GET (the transport strips the body).
    var head = http.RequestCtx{ .method = .HEAD, .path = "/assets/app.js", .allocator = arena.allocator() };
    const hr = (try serve(std.testing.io, &head, src, .{})).?;
    try std.testing.expectEqual(@as(u16, 200), hr.status);
    try std.testing.expectEqualStrings("application/javascript", hr.content_type);
    try std.testing.expectEqual(@as(usize, 4), hr.extra_headers.len);
    try std.testing.expectEqualStrings("\"22222222\"", hr.extra_headers[0].value);
}

test "embedded: If-None-Match yields 304; non-GET/HEAD and .none yield null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &fixture };

    var ctx = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = arena.allocator(), .if_none_match = "\"22222222\"" };
    const r = (try serve(std.testing.io, &ctx, src, .{})).?;
    try std.testing.expectEqual(@as(u16, 304), r.status);
    try std.testing.expectEqualStrings("", r.body);

    var post = http.RequestCtx{ .method = .POST, .path = "/index.html", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &post, src, .{})) == null);
    var none = http.RequestCtx{ .method = .GET, .path = "/index.html", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &none, Source.none, .{})) == null);
}

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

test "dir: serves files via file; index resolution; miss; traversal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.createDirPath(std.testing.io, "assets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "assets/app.js", .data = "let x = 1;" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const src = Source{ .dir = root };

    var ctx = http.RequestCtx{ .method = .GET, .path = "/assets/app.js", .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &ctx, src, .{})).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(r.file != null);
    try std.testing.expect(std.mem.endsWith(u8, r.file.?.path, "assets/app.js"));
    // Dir mode emits nosniff + Vary; ETag/304 are facil.io sendFile's job.
    try std.testing.expectEqual(@as(usize, 2), r.extra_headers.len);
    try std.testing.expectEqualStrings("X-Content-Type-Options", r.extra_headers[0].name);
    try std.testing.expectEqualStrings("Vary", r.extra_headers[1].name);
    try std.testing.expectEqualStrings("Accept-Encoding", r.extra_headers[1].value);

    var root_req = http.RequestCtx{ .method = .GET, .path = "/", .allocator = arena.allocator() };
    const ri = (try serve(std.testing.io, &root_req, src, .{})).?;
    try std.testing.expect(std.mem.endsWith(u8, ri.file.?.path, "index.html"));

    var dir_req = http.RequestCtx{ .method = .GET, .path = "/assets", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &dir_req, src, .{})) == null);

    var miss = http.RequestCtx{ .method = .GET, .path = "/nope.css", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &miss, src, .{})) == null);
    var trav = http.RequestCtx{ .method = .GET, .path = "/../secret", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &trav, src, .{})) == null);
}

test "withinRoot: prefix must be '/'-bounded (no sibling-prefix bypass)" {
    try std.testing.expect(withinRoot("/srv/www", "/srv/www"));
    try std.testing.expect(withinRoot("/srv/www", "/srv/www/a/b.js"));
    try std.testing.expect(withinRoot("/srv/www/", "/srv/www/a.js"));
    try std.testing.expect(!withinRoot("/srv/www", "/srv/wwwEVIL/x"));
    try std.testing.expect(!withinRoot("/srv/www", "/etc/passwd"));
}

test "dir: a symlink inside the root pointing OUTSIDE it is refused (F10)" {
    // Two sibling temp dirs: `root` is served; `outside` is not. A symlink planted
    // inside root that points at a file in `outside` must NOT be served, even though
    // the lexical path is clean and statFile would happily follow the link.
    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    var out_tmp = std.testing.tmpDir(.{});
    defer out_tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A legitimate in-root file still serves.
    try root_tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ok.txt", .data = "in-root" });
    // The secret lives outside the served root.
    try out_tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret.txt", .data = "TOPSECRET" });

    const root = try root_tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const out_abs = try out_tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const secret_abs = try std.fmt.allocPrint(a, "{s}/secret.txt", .{out_abs});
    // Plant the escaping symlink inside the served root: root/leak.txt -> outside/secret.txt
    try root_tmp.dir.symLink(std.testing.io, secret_abs, "leak.txt", .{});

    const src = Source{ .dir = root };

    // The escaping symlink is refused (404 / null).
    var leak = http.RequestCtx{ .method = .GET, .path = "/leak.txt", .allocator = a };
    try std.testing.expect((try serve(std.testing.io, &leak, src, .{})) == null);

    // The legitimate file is unaffected.
    var ok = http.RequestCtx{ .method = .GET, .path = "/ok.txt", .allocator = a };
    const r = (try serve(std.testing.io, &ok, src, .{})).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(r.file != null);
}

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
        // #192: the shim now ALSO blanks an If-Range header — record its set separately so
        // a later "range" rewrite in the same call doesn't clobber the observation.
        var if_range_buf: [64]u8 = undefined;
        var if_range_set: ?[]const u8 = null;
        fn set(_: *anyopaque, n: []const u8, v: []const u8) void {
            if (std.ascii.eqlIgnoreCase(n, "if-range")) {
                if_range_set = if_range_buf[0..v.len];
                @memcpy(if_range_buf[0..v.len], v);
                return;
            }
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

    // #192 / RFC 9110 §13.1.5: with an If-Range present, the shim BLANKS it (facil.io's
    // If-Range branch is inverted; blanking forces facil.io's honor-range else-branch so a
    // resume/MATCH correctly yields 206 instead of a wrong full 200). The Range rewrite
    // still happens too.
    Capture.name = "";
    Capture.value = "";
    Capture.if_range_set = null;
    const rh_ifr = [_]http.Param{ .{ .key = "range", .value = "bytes=200-" }, .{ .key = "if-range", .value = "\"whatever\"" } };
    var ctx_ifr = http.RequestCtx{ .method = .GET, .path = "/big.bin", .allocator = a, .headers = &rh_ifr, .raw_header_ctx = &dummy, .raw_header_set_fn = Capture.set };
    _ = (try serve(std.testing.io, &ctx_ifr, src, .{})).?;
    try std.testing.expectEqualStrings("bytes=200-999", Capture.value);
    try std.testing.expectEqualStrings("", Capture.if_range_set.?); // If-Range blanked
    // An UNSATISFIABLE range with If-Range present is still passed through to facil.io (no
    // owned 416): today's behavior is preserved for that corner (facil.io serves its 200;
    // the MISMATCH-should-be-200 case can't be distinguished — see the shim's doc comment).
    const rh_ifr_bad = [_]http.Param{ .{ .key = "range", .value = "bytes=5000-" }, .{ .key = "if-range", .value = "\"whatever\"" } };
    var ctx_ifr_bad = http.RequestCtx{ .method = .GET, .path = "/big.bin", .allocator = a, .headers = &rh_ifr_bad, .raw_header_ctx = &dummy, .raw_header_set_fn = Capture.set };
    const r_ifr_bad = (try serve(std.testing.io, &ctx_ifr_bad, src, .{})).?;
    try std.testing.expectEqual(@as(u16, 200), r_ifr_bad.status); // delegated, not 416
}

// ── Tier-1 SPA marker fixtures + tests (issue #183) ─────────────────────────

const spa_fixture = [_]StaticFile{
    .{ .path = "index.html", .bytes = "<h1>home</h1>", .etag = "\"aaaaaaaa\"" },
    .{ .path = ".spa", .bytes = "MARKER-SECRET", .etag = "\"eeeeeeee\"" },
    .{ .path = "app/index.html", .bytes = "<h1>app shell</h1>", .etag = "\"bbbbbbbb\"" },
    .{ .path = "app/.spa", .bytes = "MARKER-SECRET", .etag = "\"ffffffff\"" },
    .{ .path = "app/assets/app.js", .bytes = "console.log(2)", .etag = "\"cccccccc\"" },
    // a marker whose directory has NO index.html — must be warned about and dropped
    .{ .path = "bare/.spa", .bytes = "MARKER-SECRET", .etag = "\"dddddddd\"" },
    // a REAL static file that happens to live under an "api/" prefix — proves the
    // api-guard refuses it even though a normal file lookup would otherwise find it.
    .{ .path = "api/x", .bytes = "not-the-api", .etag = "\"11111111\"" },
};

test "spa scan: embedded manifest markers derive roots (missing index.html dropped)" {
    const a = std.testing.allocator;
    const roots = try deriveEmbeddedSpaRoots(a, &spa_fixture);
    defer freeSpaRoots(a, roots);
    // "bare" is dropped (no bare/index.html); longest-first order: "app" then "".
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqualStrings("app", roots[0]);
    try std.testing.expectEqualStrings("", roots[1]);
}

test "spa scan: .none / plain embedded source yields an empty (freeable) root set" {
    const a = std.testing.allocator;
    const plain = try deriveEmbeddedSpaRoots(a, &fixture);
    defer freeSpaRoots(a, plain);
    try std.testing.expectEqual(@as(usize, 0), plain.len);
}

test "spa validate (dir): passes for a clean marked tree; unused for embedded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".spa", .data = "" });
    try tmp.dir.createDirPath(std.testing.io, "app/admin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/index.html", .data = "<h1>app</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/.spa", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/admin/index.html", .data = "<h1>admin</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/admin/.spa", .data = "" });

    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());

    // No error: every `.spa` in this tree has a sibling index.html.
    try validateSpaMarkersDir(std.testing.io, a, root, null);
}

test "spa validate (dir): a marker with NO index.html is FATAL (owner revision)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.createDirPath(std.testing.io, "broken");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "broken/.spa", .data = "" });

    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());

    // Fatal, not a warn+drop: a `.spa`-marked directory with nothing to serve as the
    // shell is treated as a build/deploy mistake that must abort startup (owner's
    // failure matrix), not silently degrade to "unmarked" the way it used to.
    var failure: SpaValidateFailure = undefined;
    try std.testing.expectError(error.SpaValidationFailed, validateSpaMarkersDir(std.testing.io, a, root, &failure));
    defer a.free(failure.path);
    try std.testing.expectEqualStrings("broken", failure.path);
    try std.testing.expectEqual(.missing_index, failure.reason);
}

test "spa validate (dir): an unreadable subdirectory is SKIPPED, not fatal (owner revision)" {
    // chmod(0o000) is a no-op for root (root bypasses DAC permission checks), so this
    // assertion only holds for a non-root test runner — skip gracefully under root
    // (e.g. some CI/sandbox containers) rather than false-fail.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".spa", .data = "" });
    try tmp.dir.createDirPath(std.testing.io, "locked");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "locked/.spa", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "locked/index.html", .data = "<h1>locked</h1>" });
    // Lock the subdirectory AFTER populating it: no read/exec means the walker can list
    // the root fine but fails to open/enter "locked" (AccessDenied), same shape as a
    // root-owned 0700 dir or a "lost+found"-style directory under --serve-static.
    try tmp.dir.setFilePermissions(std.testing.io, "locked", .fromMode(0o000), .{});
    defer tmp.dir.setFilePermissions(std.testing.io, "locked", .fromMode(0o755), .{}) catch {};

    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());

    // NOT fatal: unreadable content is treated as if it doesn't exist (owner's failure
    // matrix) — validation completes successfully despite "locked" being unenterable.
    try validateSpaMarkersDir(std.testing.io, a, root, null);
}

test "spa prefix: '/'-bounded longest match; marker at app/ does not claim /application" {
    const roots = [_][]const u8{ "app/admin", "app", "" };
    try std.testing.expectEqualStrings("app/admin", matchSpaRoot(&roots, "app/admin/x/y").?);
    try std.testing.expectEqualStrings("app", matchSpaRoot(&roots, "app/orders/1").?);
    try std.testing.expectEqualStrings("app", matchSpaRoot(&roots, "app").?);
    try std.testing.expectEqualStrings("", matchSpaRoot(&roots, "pricing").?);
    try std.testing.expectEqualStrings("", matchSpaRoot(&roots, "application/x").?); // root marker, NOT "app"
    const app_only = [_][]const u8{"app"};
    try std.testing.expect(matchSpaRoot(&app_only, "application/x") == null);
    try std.testing.expect(matchSpaRoot(&app_only, "pricing") == null);
    try std.testing.expect(matchSpaRoot(&.{}, "anything") == null);
}

test "spa marker path detection: final segment '.spa' only, case-insensitive" {
    try std.testing.expect(isSpaMarkerPath(".spa"));
    try std.testing.expect(isSpaMarkerPath("app/.spa"));
    try std.testing.expect(!isSpaMarkerPath("app/.spare"));
    try std.testing.expect(!isSpaMarkerPath(".spa/x"));
    try std.testing.expect(!isSpaMarkerPath(".well-known/security.txt"));
    try std.testing.expect(!isSpaMarkerPath(""));
    // ASCII-case-insensitive: macOS's default (case-insensitive) APFS/HFS+ volumes stat
    // ".SPA"/".Spa" as the same file as ".spa" in dir mode, so "GET /.SPA" must be
    // refused too — otherwise the "never servable" invariant would be platform-dependent.
    try std.testing.expect(isSpaMarkerPath(".SPA"));
    try std.testing.expect(isSpaMarkerPath(".Spa"));
    try std.testing.expect(isSpaMarkerPath("app/.SPA"));
    try std.testing.expect(!isSpaMarkerPath("app/.SPARE"));
}

test "static_routes matcher: ':name' one segment, '*' one-or-more, '**' zero-or-more" {
    // The design-spec examples table, as assertions.
    try std.testing.expect(matchRoute("/app/orders/:id", "app/orders/42"));
    try std.testing.expect(!matchRoute("/app/orders/:id", "app/orders/42/edit")); // :id is ONE segment
    try std.testing.expect(!matchRoute("/app/orders/:id", "app/orders"));
    try std.testing.expect(matchRoute("/admin/*", "admin/x"));
    try std.testing.expect(matchRoute("/admin/*", "admin/x/y"));
    try std.testing.expect(!matchRoute("/admin/*", "admin")); // '*' needs >= 1 segment
    try std.testing.expect(matchRoute("/app/**", "app")); // '**' matches the bare prefix
    try std.testing.expect(matchRoute("/app/**", "app/a/b/c"));
    try std.testing.expect(matchRoute("/app/a/b/c", "app/a/b/c")); // exact literal
    try std.testing.expect(!matchRoute("/app/a/b/c", "app/a/b"));
    try std.testing.expect(!matchRoute("/app/x", "app/y"));
    // Root-form patterns against the root path ("" after sanitize).
    try std.testing.expect(matchRoute("/**", ""));
    try std.testing.expect(!matchRoute("/*", "")); // one-or-more can't match zero
    try std.testing.expect(matchRoute("/", ""));
    try std.testing.expect(!matchRoute("/", "x"));
    try std.testing.expect(!matchRoute("/app/**", "application")); // segment-wise, not prefix-wise
}

// ── serve() miss-path fallback wiring (issue #183, Task 3) ─────────────────

test "spa fallback: miss under marked root serves its index.html (embedded: 200/html/ETag)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &spa_fixture };
    const fb = Fallback{ .spa_roots = &.{ "app", "" }, .spa_marker_enabled = true };

    var deep = http.RequestCtx{ .method = .GET, .path = "/app/orders/1234", .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &deep, src, fb)).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("<h1>app shell</h1>", r.body);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", r.content_type);
    try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
    try std.testing.expectEqualStrings("\"bbbbbbbb\"", r.extra_headers[0].value);

    // Extension-bearing misses under the root get the shell too (deliberate: one
    // fixed behavior, same as try_files $uri /index.html).
    var stale = http.RequestCtx{ .method = .GET, .path = "/app/assets/old.js", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>app shell</h1>", (try serve(std.testing.io, &stale, src, fb)).?.body);

    // Real files always win over the fallback.
    var real = http.RequestCtx{ .method = .GET, .path = "/app/assets/app.js", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("console.log(2)", (try serve(std.testing.io, &real, src, fb)).?.body);
}

test "spa fallback: root marker catches every miss; nested markers longest-prefix-wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &spa_fixture };
    const fb = Fallback{ .spa_roots = &.{ "app", "" }, .spa_marker_enabled = true };

    var out = http.RequestCtx{ .method = .GET, .path = "/pricing/enterprise", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &out, src, fb)).?.body);
    var in = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>app shell</h1>", (try serve(std.testing.io, &in, src, fb)).?.body);
    // '/'-bounded: /application/x belongs to the ROOT marker, not app/.
    var appl = http.RequestCtx{ .method = .GET, .path = "/application/x", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &appl, src, fb)).?.body);
    // A dropped inner root (fb without "app") falls through to the outer marker.
    const outer_only = Fallback{ .spa_roots = &.{""}, .spa_marker_enabled = true };
    var fell = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &fell, src, outer_only)).?.body);
}

test "spa fallback: no marker/no routes => serve returns null (miss 404s, AC3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var miss = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &miss, Source{ .embedded = &spa_fixture }, .{})) == null);
}

test "spa fallback: spa_marker_enabled=false suppresses the marker even with roots present" {
    // A dropped-flag safety net: `spa_roots`/on-disk markers alone must not be enough —
    // `.enable_spa_marker = false` (mirrored at runtime by `spa_marker_enabled`) has to
    // actually gate the tier, not just be documentation.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var miss = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    const fb = Fallback{ .spa_roots = &.{ "app", "" }, .spa_marker_enabled = false };
    try std.testing.expect((try serve(std.testing.io, &miss, Source{ .embedded = &spa_fixture }, fb)) == null);
}

test "spa fallback: an api-looking miss never reaches the fallback, even double-slashed" {
    // Defense-in-depth (final review, finding 3): server.zig's own "/api" gate is
    // byte-literal on the RAW path, which "//api/x" (a leading double slash) bypasses —
    // sanitize() here normalizes it to "api/x" all the same, so this second, normalized
    // check must independently refuse it, regardless of what the caller's raw-path gate
    // did or didn't catch upstream.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &spa_fixture };
    const fb = Fallback{ .spa_roots = &.{""}, .spa_marker_enabled = true }; // root marker would otherwise catch every miss

    var dbl = http.RequestCtx{ .method = .GET, .path = "//api/x", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &dbl, src, fb)) == null);
    var bare = http.RequestCtx{ .method = .GET, .path = "/api", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &bare, src, fb)) == null);
    var normal = http.RequestCtx{ .method = .GET, .path = "/api/x", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &normal, src, fb)) == null);
    // Non-api misses under the same root marker are unaffected (sanity: the guard is scoped).
    var other = http.RequestCtx{ .method = .GET, .path = "/pricing", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &other, src, fb)).?.body);
}

test "spa fallback: //api/x refuses even when a REAL file exists at api/x (hoisted guard, review)" {
    // The gap the guard used to have: the normalized api-refusal ran AFTER the real-file
    // lookup in serve(), so a raw "//api/x" (which bypasses server.zig's byte-literal
    // "/api/" gate, then sanitizes to "api/x") could serve a genuine static file living
    // under an "api/" prefix in the static source — even though the equivalent normal-form
    // "/api/x" request never reaches this function at all (server.zig routes it to the
    // API's JSON 404 first). The guard must now run BEFORE any file lookup, so this must
    // be null for BOTH sources despite "api/x" being a real, servable file.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dbl_embedded = http.RequestCtx{ .method = .GET, .path = "//api/x", .allocator = a };
    try std.testing.expect((try serve(std.testing.io, &dbl_embedded, Source{ .embedded = &spa_fixture }, .{})) == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "api");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "api/x", .data = "not-the-api" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var dbl_dir = http.RequestCtx{ .method = .GET, .path = "//api/x", .allocator = a };
    try std.testing.expect((try serve(std.testing.io, &dbl_dir, Source{ .dir = root }, .{})) == null);
}

test "spa fallback: '.spa' itself is never served (embedded + dir, incl. dir live resolution)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Embedded: the marker bytes must never appear; with the marker active the
    // request falls through to the shell.
    const src = Source{ .embedded = &spa_fixture };
    var m1 = http.RequestCtx{ .method = .GET, .path = "/app/.spa", .allocator = a };
    const r1 = (try serve(std.testing.io, &m1, src, .{ .spa_roots = &.{"app"}, .spa_marker_enabled = true })).?;
    try std.testing.expectEqualStrings("<h1>app shell</h1>", r1.body);
    // ...and with NO fallback configured it is a plain miss (null), not the bytes.
    var m2 = http.RequestCtx{ .method = .GET, .path = "/app/.spa", .allocator = a };
    try std.testing.expect((try serve(std.testing.io, &m2, src, .{})) == null);
    // Other dotfiles keep serving (.well-known must not break): add none here — the
    // refusal is scoped to the literal '.spa' final segment (see isSpaMarkerPath test).

    // Dir mode (live resolution): a real .spa file on disk is refused too.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".spa", .data = "MARKER-SECRET" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var m3 = http.RequestCtx{ .method = .GET, .path = "/.spa", .allocator = a };
    const r3 = (try serve(std.testing.io, &m3, Source{ .dir = root }, .{ .spa_marker_enabled = true })).?;
    // The dir-mode Tier-1 shell is now served OWNED (§C.3), not via file delegation.
    try std.testing.expect(r3.file == null);
    try std.testing.expectEqualStrings("<h1>root</h1>", r3.body);
}

test "spa fallback: If-None-Match on the embedded fallback yields 304; HEAD mirrors GET" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &spa_fixture };
    const fb = Fallback{ .spa_roots = &.{"app"}, .spa_marker_enabled = true };
    var cond = http.RequestCtx{ .method = .GET, .path = "/app/deep/link", .allocator = arena.allocator(), .if_none_match = "\"bbbbbbbb\"" };
    try std.testing.expectEqual(@as(u16, 304), (try serve(std.testing.io, &cond, src, fb)).?.status);
    var head = http.RequestCtx{ .method = .HEAD, .path = "/app/deep/link", .allocator = arena.allocator() };
    const hr = (try serve(std.testing.io, &head, src, fb)).?;
    try std.testing.expectEqual(@as(u16, 200), hr.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", hr.content_type);
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

// ── Dir-mode LIVE marker resolution (owner revision, 2026-07-02) ────────────
// No cached root set for dir mode: `resolveSpaMarkerDirLive` re-reads the filesystem
// on every miss, so these tests specifically prove markers/index.html files created
// (or removed) AFTER the serve context existed still resolve correctly on the next
// call — the whole point of going live instead of a startup-only scan.

test "spa live (dir): a marker created AFTER boot is picked up on the very next miss" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/index.html", .data = "<h1>app shell</h1>" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const src = Source{ .dir = root };
    const fb = Fallback{ .spa_marker_enabled = true };

    // Before the marker exists: a miss under "app/" does NOT get the shell (404/null) —
    // "app" isn't marked yet, and the root has no marker either.
    var before = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &before, src, fb)) == null);

    // Simulates a post-boot deploy: the marker is dropped WITHOUT restarting the server
    // (no re-scan, no cache to invalidate — `serve` is never told this happened).
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/.spa", .data = "" });

    // The very next miss under "app/" now gets the shell.
    var after = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &after, src, fb)).?;
    try std.testing.expect(r.file == null); // OWNED shell (§C.3), not a sendFile delegation
    try std.testing.expectEqualStrings("<h1>app shell</h1>", r.body);
}

test "spa live (dir): removing a marker post-boot stops the fallback on the next miss" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/index.html", .data = "<h1>app shell</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/.spa", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const src = Source{ .dir = root };
    const fb = Fallback{ .spa_marker_enabled = true };

    var before = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &before, src, fb)) != null);

    try tmp.dir.deleteFile(std.testing.io, "app/.spa");

    var after = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &after, src, fb)) == null);
}

test "spa live (dir): deepest marker wins; vanished index.html on the deepest marker is null (no fall-through)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".spa", .data = "" });
    try tmp.dir.createDirPath(std.testing.io, "app/admin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/index.html", .data = "<h1>app shell</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/.spa", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/admin/index.html", .data = "<h1>admin shell</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/admin/.spa", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const src = Source{ .dir = root };
    const fb = Fallback{ .spa_marker_enabled = true };

    // Deepest ("app/admin") wins over "app" and the root. Shells are OWNED (§C.3),
    // so assert body content rather than a delegated file path.
    var deep = http.RequestCtx{ .method = .GET, .path = "/app/admin/orders/1", .allocator = arena.allocator() };
    const rd = (try serve(std.testing.io, &deep, src, fb)).?;
    try std.testing.expect(rd.file == null);
    try std.testing.expectEqualStrings("<h1>admin shell</h1>", rd.body);
    // A miss under "app/" (but not "app/admin/") gets the "app" shell.
    var mid = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    const rm = (try serve(std.testing.io, &mid, src, fb)).?;
    try std.testing.expect(rm.file == null);
    try std.testing.expectEqualStrings("<h1>app shell</h1>", rm.body);
    // A miss elsewhere gets the root shell.
    var out = http.RequestCtx{ .method = .GET, .path = "/pricing", .allocator = arena.allocator() };
    const ro = (try serve(std.testing.io, &out, src, fb)).?;
    try std.testing.expect(ro.file == null);
    try std.testing.expectEqualStrings("<h1>root</h1>", ro.body);

    // Now delete the DEEPEST marker's index.html (post-boot, live): a miss under
    // "app/admin/" must resolve to null — NOT fall through to the "app" marker. This
    // mirrors validateSpaMarkersDir/deriveEmbeddedSpaRoots: a marked-but-indexless
    // directory is "absent", not "defer to the next ancestor".
    try tmp.dir.deleteFile(std.testing.io, "app/admin/index.html");
    var vanished = http.RequestCtx{ .method = .GET, .path = "/app/admin/orders/1", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &vanished, src, fb)) == null);
    // A sibling still under "app/" (not "app/admin/") is unaffected.
    var sibling = http.RequestCtx{ .method = .GET, .path = "/app/orders/2", .allocator = arena.allocator() };
    const rs = (try serve(std.testing.io, &sibling, src, fb)).?;
    try std.testing.expect(rs.file == null);
    try std.testing.expectEqualStrings("<h1>app shell</h1>", rs.body);
}

test "spa live (dir): a request path deeper than the ancestor-walk cap still resolves the root marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".spa", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const src = Source{ .dir = root };
    const fb = Fallback{ .spa_marker_enabled = true };

    // Build a request path with far more than `spa_marker_walk_cap` (64) segments —
    // none of the intermediate directories exist on disk, so every one of those levels
    // is a miss; only the root ".spa" marker can satisfy this. This proves the capped
    // walk still reaches (and checks) the root rather than erroring out or silently
    // giving up once the cap is hit.
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(arena.allocator());
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try path_buf.appendSlice(arena.allocator(), "/seg");
    }
    const path = try path_buf.toOwnedSlice(arena.allocator());

    var deep = http.RequestCtx{ .method = .GET, .path = path, .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &deep, src, fb)).?;
    try std.testing.expect(r.file == null); // OWNED shell (§C.3)
    try std.testing.expectEqualStrings("<h1>root</h1>", r.body);
}

test "spa live (dir): a marker just past the ancestor-walk cap depth is NOT found (documents the bound)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });

    // A shallow, real marker directory (5 levels) that WOULD be found by an unbounded
    // walk-up. The request path descends far below it (200+ extra segments, none of
    // which exist on disk), which pushes the marker's ancestor level past the 64-level
    // cap: the capped walk checks only the innermost 64 levels below the request before
    // jumping straight to the root, so it never reaches this marker. This documents the
    // tradeoff: only the innermost `spa_marker_walk_cap` ancestor levels of a miss are
    // actually checked; the marker resolves to null (root has no marker either) rather
    // than erroring or scanning unboundedly many levels.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var marker_rel: std.ArrayList(u8) = .empty;
    defer marker_rel.deinit(arena.allocator());
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (i != 0) try marker_rel.append(arena.allocator(), '/');
        try marker_rel.appendSlice(arena.allocator(), "seg");
    }
    try tmp.dir.createDirPath(std.testing.io, marker_rel.items);
    const marker_path = try std.fmt.allocPrint(arena.allocator(), "{s}/.spa", .{marker_rel.items});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = marker_path, .data = "" });
    const idx_path = try std.fmt.allocPrint(arena.allocator(), "{s}/index.html", .{marker_rel.items});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = idx_path, .data = "<h1>deep shell</h1>" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const src = Source{ .dir = root };
    const fb = Fallback{ .spa_marker_enabled = true };

    // Request path: the 5-level marker dir + 200 more (nonexistent) segments below it,
    // so the marker sits far past the 64-level cap counted up from the request.
    var req_buf: std.ArrayList(u8) = .empty;
    defer req_buf.deinit(arena.allocator());
    try req_buf.appendSlice(arena.allocator(), marker_rel.items);
    var j: usize = 0;
    while (j < 200) : (j += 1) {
        try req_buf.appendSlice(arena.allocator(), "/deep");
    }
    const req_path = try std.fmt.allocPrint(arena.allocator(), "/{s}", .{req_buf.items});

    var deep = http.RequestCtx{ .method = .GET, .path = req_path, .allocator = arena.allocator() };
    // No root marker exists here, so the capped walk (jumping to root once exhausted)
    // finds nothing: null, not the deep marker's shell and not an error.
    try std.testing.expect((try serve(std.testing.io, &deep, src, fb)) == null);
}

test "static_routes: matched on miss only (real file wins); routes beat the marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &spa_fixture };
    const routes = [_]StaticRoute{
        .{ .match = "/app/orders/:id", .serve = "/app/index.html" },
        .{ .match = "/app/**", .serve = "/index.html" },
    };
    const fb = Fallback{ .routes = &routes, .spa_roots = &.{"app"}, .spa_marker_enabled = true };

    // Real file wins over a matching route.
    var real = http.RequestCtx{ .method = .GET, .path = "/app/assets/app.js", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("console.log(2)", (try serve(std.testing.io, &real, src, fb)).?.body);
    // First matching route wins, in declaration order.
    var order = http.RequestCtx{ .method = .GET, .path = "/app/orders/42", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>app shell</h1>", (try serve(std.testing.io, &order, src, fb)).?.body);
    // Routes are consulted BEFORE the marker: /app/x matches /app/** -> root index,
    // even though the "app" marker would have served the app shell.
    var routed = http.RequestCtx{ .method = .GET, .path = "/app/x", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &routed, src, fb)).?.body);
    // Trailing slash never changes the outcome (sanitize normalizes): /app/ == /app.
    var slash = http.RequestCtx{ .method = .GET, .path = "/app/orders/42/", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>app shell</h1>", (try serve(std.testing.io, &slash, src, fb)).?.body);
}

test "static_routes startup validation (dir): present + dir-index targets pass; missing is fatal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/index.html", .data = "<h1>app</h1>" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);

    // Exact-file target, directory target (resolves to app/index.html), and "/" (root index).
    const good = [_]StaticRoute{
        .{ .match = "/a/**", .serve = "/app/index.html" },
        .{ .match = "/b/**", .serve = "/app" },
        .{ .match = "/c/**", .serve = "/" },
    };
    try std.testing.expectEqual(@as(?StaticRoute, null), try validateRouteTargetsDir(std.testing.io, a, root, &good));

    const bad = [_]StaticRoute{.{ .match = "/x/**", .serve = "/missing.html" }};
    const missing = (try validateRouteTargetsDir(std.testing.io, a, root, &bad)).?;
    try std.testing.expectEqualStrings("/missing.html", missing.serve);

    // A directory target WITHOUT an index.html is missing too.
    try tmp.dir.createDirPath(std.testing.io, "empty");
    const bad_dir = [_]StaticRoute{.{ .match = "/y/**", .serve = "/empty" }};
    const missing_dir = (try validateRouteTargetsDir(std.testing.io, a, root, &bad_dir)).?;
    try std.testing.expectEqualStrings("/empty", missing_dir.serve);
}
