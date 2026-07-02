# SPA Fallback Routing (.spa marker + comptime static_routes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Implement ZigBase issue #183 — host client-routed (History-API) SPAs without deep-link 404s. Tier 1: a presence-only file named `.spa` in the static tree makes its directory an SPA root; any GET/HEAD static *miss* at or below it serves that directory's `index.html` (200). Tier 2: a comptime `App(.{ .static_routes = &.{...} })` key declares explicit `match → serve` rewrites (minimal segment matching: `:name` = one segment, `*` = one-or-more rest, `**` = zero-or-more rest, first match wins), validated at comptime (embedded) or startup (dir). A new `enable_spa_marker` comptime bool gates Tier 1 (default: on without routes, off with routes).

**Architecture:** Everything lands as a *miss handler* inside the existing static branch — nothing upstream changes. `src/static_files.zig` gains `StaticRoute`/`Fallback` types, a startup scanner (`scanSpaRoots`), a pattern matcher (`matchRoute`), a dir-mode startup validator (`validateRouteTargetsDir`), and a widened `serve(io, ctx, source, fb)` whose fallback documents ride the existing `serveDir`/`serveEmbedded` paths (inheriting ETag/304/HEAD/nosniff/F10 symlink checks for free). `src/framework.zig` lowers two new comptime keys (`static_routes`, `enable_spa_marker`) following existing validation conventions, and `serveImpl` runs the startup scan/validation and threads results onto the runtime `app_mod.App` (two new fields in `src/app.zig`). `src/server.zig` only changes its one `static_files.serve(...)` call site. Python e2e in `tests/admin/test_static_files.py`; a minimal `static_routes` demo + vitest e2e in `examples/plugins`; docs + site mirror + changelog fragment.

**Tech Stack:** Zig 0.16 (mise-pinned), pytest/Playwright e2e harness, vitest (examples/plugins), Astro site build.

## Global Constraints

- Repo root: work in the repository checkout you are given (baseline: `main` @ `e71eac5`). All paths below are repo-root-relative.
- Zig tests: `mise exec zig@0.16.0 -- zig build test --summary all` — the authoritative signal is the `Build Summary: N/N tests passed` line; a spurious `failed command: …` line appears even on success. There is no per-test filter.
- Any new `src/*.zig` file's tests only run if `src/root.zig`'s `test { … }` block imports it. This plan adds **no** new src files — `static_files.zig`, `framework.zig`, `server.zig`, `app.zig` are all already imported there (verify, don't add duplicates).
- Comptime config keys follow `src/framework.zig`'s conventions: every key must be listed in the `allowed` tuple (line ~210) or it's a `@compileError`; malformed shapes get loud `@compileError`s in the lowering block (see how `static_mode` at line ~542 and `mail_config` at line ~809 do it); lowered values are `pub const` decls on the App type, threaded through `ServeOpts` into `serveImpl`.
- e2e: `mise exec python@3.13 -- python -m pytest tests/admin/test_static_files.py -q` (the tests build/resolve the binary and launch a real server themselves; follow the existing fixture pattern in that file — no conftest fixtures are used by it, it launches `subprocess.Popen` directly). Build the binary first with `mise exec zig@0.16.0 -- zig build`.
- Never edit `CHANGELOG.md` or `site/src/content/docs/changelog.md` — add a fragment `changelog.d/spa-fallback.md` (`### Features` + `### Changed`; reference issue #183).
- Docs sync is mandatory: `docs/framework.md` §13 (static files) AND its mirror `site/src/content/docs/framework.md`; `docs/api.md` "Static files" section AND its mirror `site/src/content/docs/api.md`; the site-only `site/src/content/docs/configuration.md` gets one marker paragraph; `README.md` extends the existing "Static files" bullet. `cd site && npm run build` must pass after site content changes.
- Examples: ONLY `examples/plugins` is in scope (the spec includes it minimally — one `static_routes` catch-all + a vitest deep-link e2e). Do NOT touch `examples/blog` or `examples/golfsim`, and never edit anything under any example's `zig-pkg/` (vendored deps).
- The `.spa` marker file itself must never be servable (in both dir and embedded sources); fallback documents inherit the existing ETag/304/HEAD/nosniff/F10 handling by riding `serveDir`/`serveEmbedded` — do not add new caching/header code.
- Commit after each task with the message given in the task. Do not run `scripts/assemble-changelog.sh`.

---

## Task 1 — Tier-1 pure logic: marker scan + prefix set (`scanSpaRoots`, `Fallback`, prefix matching)

**Files:**
- Modify: `src/static_files.zig`

**Interfaces:**
- Consumes (already in `src/static_files.zig`): `pub const StaticFile = struct { path: []const u8, bytes: []const u8, etag: []const u8 };`, `pub const Source = union(enum) { none, dir: []const u8, embedded: []const StaticFile };`, private `fn findEmbedded(files: []const StaticFile, rel: []const u8) ?*const StaticFile`.
- Produces (all in `src/static_files.zig`):
  - `pub const StaticRoute = struct { match: []const u8, serve: []const u8 };`
  - `pub const Fallback = struct { routes: []const StaticRoute = &.{}, spa_roots: []const []const u8 = &.{} };`
  - `pub fn scanSpaRoots(io: std.Io, alloc: std.mem.Allocator, source: Source) ![]const []const u8`
  - `pub fn freeSpaRoots(alloc: std.mem.Allocator, roots: []const []const u8) void`
  - private `fn markerPrefix(path: []const u8) ?[]const u8`
  - private `fn matchSpaRoot(roots: []const []const u8, rel: []const u8) ?[]const u8`
  - private `fn isSpaMarkerPath(rel: []const u8) bool`

Context you need: `src/static_files.zig` serves static files from either a filesystem dir or an embedded manifest. This task adds the *pure* Tier-1 logic for issue #183: at startup, every directory containing a file named exactly `.spa` becomes an SPA root, identified by its root-relative `/`-separated prefix (`""` = the static root itself). A marked directory with no `index.html` is warned about and **dropped** (treated as unmarked). The result is sorted **longest-first** so a `/`-bounded prefix scan finds the innermost (most specific) marker first. Nothing calls these functions yet — `serve()` is wired in Task 3, startup wiring in Task 5. The project is Linux/macOS only, so walker paths are `/`-separated.

- [ ] Read `src/static_files.zig` fully (it is ~365 lines) to absorb its conventions (`std.Io` param style, tmpDir test patterns, the `fixture` manifest).
- [ ] Add failing unit tests at the END of `src/static_files.zig` (they reference symbols that don't exist yet, so the build fails — that is the "failing test" state for Zig):

```zig
// ── Tier-1 SPA marker fixtures + tests (issue #183) ─────────────────────────

const spa_fixture = [_]StaticFile{
    .{ .path = "index.html", .bytes = "<h1>home</h1>", .etag = "\"aaaaaaaa\"" },
    .{ .path = ".spa", .bytes = "MARKER-SECRET", .etag = "\"eeeeeeee\"" },
    .{ .path = "app/index.html", .bytes = "<h1>app shell</h1>", .etag = "\"bbbbbbbb\"" },
    .{ .path = "app/.spa", .bytes = "MARKER-SECRET", .etag = "\"ffffffff\"" },
    .{ .path = "app/assets/app.js", .bytes = "console.log(2)", .etag = "\"cccccccc\"" },
    // a marker whose directory has NO index.html — must be warned about and dropped
    .{ .path = "bare/.spa", .bytes = "MARKER-SECRET", .etag = "\"dddddddd\"" },
};

test "spa scan: embedded manifest markers derive roots (missing index.html dropped)" {
    const a = std.testing.allocator;
    const roots = try scanSpaRoots(std.testing.io, a, .{ .embedded = &spa_fixture });
    defer freeSpaRoots(a, roots);
    // "bare" is dropped (no bare/index.html); longest-first order: "app" then "".
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqualStrings("app", roots[0]);
    try std.testing.expectEqualStrings("", roots[1]);
}

test "spa scan: dir mode finds markers, drops roots missing index.html" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".spa", .data = "" });
    try tmp.dir.createDirPath(std.testing.io, "app/admin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/index.html", .data = "<h1>app</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/.spa", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/admin/index.html", .data = "<h1>admin</h1>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/admin/.spa", .data = "" });
    try tmp.dir.createDirPath(std.testing.io, "broken");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "broken/.spa", .data = "" });

    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());

    const roots = try scanSpaRoots(std.testing.io, a, .{ .dir = root });
    defer freeSpaRoots(a, roots);
    try std.testing.expectEqual(@as(usize, 3), roots.len);
    try std.testing.expectEqualStrings("app/admin", roots[0]); // longest first
    try std.testing.expectEqualStrings("app", roots[1]);
    try std.testing.expectEqualStrings("", roots[2]);
}

test "spa scan: .none source and empty tree yield an empty (freeable) set" {
    const a = std.testing.allocator;
    const none = try scanSpaRoots(std.testing.io, a, .none);
    defer freeSpaRoots(a, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const plain = try scanSpaRoots(std.testing.io, a, .{ .embedded = &fixture });
    defer freeSpaRoots(a, plain);
    try std.testing.expectEqual(@as(usize, 0), plain.len);
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

test "spa marker path detection: final segment '.spa' only" {
    try std.testing.expect(isSpaMarkerPath(".spa"));
    try std.testing.expect(isSpaMarkerPath("app/.spa"));
    try std.testing.expect(!isSpaMarkerPath("app/.spare"));
    try std.testing.expect(!isSpaMarkerPath(".spa/x"));
    try std.testing.expect(!isSpaMarkerPath(".well-known/security.txt"));
    try std.testing.expect(!isSpaMarkerPath(""));
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect a COMPILE FAILURE (`scanSpaRoots` etc. undeclared). Ignore the spurious `failed command:` phrasing; the compile errors are the point.
- [ ] Implement the types and functions. Insert the types right after the existing `pub const Source` declaration, and the functions after `withinRoot` (before `serveDir`):

```zig
/// One Tier-2 rewrite (issue #183): a comptime-validated `match` pattern -> a fixed
/// `serve` target. Both start with '/'; `serve` names a real document in the active
/// static source (proven at comptime for embedded manifests, at startup for dirs).
pub const StaticRoute = struct { match: []const u8, serve: []const u8 };

/// Miss-handler inputs threaded into `serve` by server.zig (issue #183).
/// `routes` is the comptime-lowered App.static_routes (Tier 2, checked first);
/// `spa_roots` is the startup `.spa`-marker scan, sorted longest-first (Tier 1).
/// Both default empty: `serve(.., .{})` behaves exactly as before the feature.
pub const Fallback = struct {
    routes: []const StaticRoute = &.{},
    spa_roots: []const []const u8 = &.{},
};

/// "" for a root marker (".spa"), "app/x" for "app/x/.spa", null when `path` is not
/// a marker file path. `path` is root-relative and '/'-separated.
fn markerPrefix(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, ".spa")) return "";
    if (std.mem.endsWith(u8, path, "/.spa")) return path[0 .. path.len - "/.spa".len];
    return null;
}

/// True when the sanitized path's final segment is exactly ".spa" — the marker file
/// itself is never servable (its bytes are meaningless and dir/embedded sources would
/// otherwise happily serve it). Other dotfiles (.well-known/...) are unaffected.
fn isSpaMarkerPath(rel: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    return std.mem.eql(u8, base, ".spa");
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

/// Startup scan (Tier 1, issue #183): collect every directory in `source` containing a
/// file named exactly `.spa`, as root-relative '/'-separated prefixes ("" = the static
/// root itself), sorted longest-first. A marked directory without an `index.html` gets a
/// startup warning and is dropped (degrades to unmarked — misses there 404 or fall
/// through to an enclosing marker). Startup-only: adding/removing a marker requires a
/// restart. Caller frees via `freeSpaRoots`.
pub fn scanSpaRoots(io: std.Io, alloc: std.mem.Allocator, source: Source) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roots.items) |r| alloc.free(r);
        roots.deinit(alloc);
    }
    switch (source) {
        .none => {},
        .embedded => |files| {
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
        },
        .dir => |root| {
            var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walk(alloc);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
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
                    std.log.warn("SPA marker at '{s}/' has no index.html; marker ignored", .{prefix});
                    continue;
                }
                try roots.append(alloc, try alloc.dupe(u8, prefix));
            }
        },
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

/// Free a scanSpaRoots result. Safe to call on the comptime-empty slice the
/// marker-disabled path uses (no-op).
pub fn freeSpaRoots(alloc: std.mem.Allocator, roots: []const []const u8) void {
    if (roots.len == 0) return;
    for (roots) |r| alloc.free(r);
    alloc.free(roots);
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect `Build Summary: … N/N tests passed` (all green, including the 5 new tests). If the walker API differs (e.g. `entry.path` type), fix against `build.zig`'s `embedStaticDir` which uses the identical `dir.walk(alloc)` / `walker.next(io)` / `entry.kind` / `entry.path` pattern.
- [ ] `git add src/static_files.zig && git commit -m "feat(static): SPA marker scan — scanSpaRoots + '/'-bounded prefix matching (#183)"`

---

## Task 2 — Tier-2 pure logic: the `static_routes` segment matcher (`matchRoute`)

**Files:**
- Modify: `src/static_files.zig`

**Interfaces:**
- Consumes: nothing new (pure function over strings).
- Produces: `pub fn matchRoute(pattern: []const u8, rel: []const u8) bool` in `src/static_files.zig`.

Context: Tier 2 of issue #183 matches request paths against comptime-declared patterns. Semantics (normative, from the design spec): matching runs against the **sanitized** root-relative path (`""` = root; sanitize collapses `//`, `.`, and trailing slashes, so `/app/` ≡ `/app`). Patterns start with `/` and are split on `/`: a **literal** segment is an exact byte match; **`:name`** matches exactly one (non-empty) segment; **`*`** is terminal-only and matches **one or more** remaining segments (the bare prefix does NOT match); **`**`** is terminal-only and matches **zero or more** (the bare prefix DOES match). First match wins in declaration order — that ordering lives at the call site (Task 3); this function answers one pattern. Pattern grammar is enforced at comptime (Task 4), so `matchRoute` may assume a well-formed pattern.

- [ ] Add failing tests at the end of `src/static_files.zig`:

```zig
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
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect COMPILE FAILURE (`matchRoute` undeclared).
- [ ] Implement, placed next to `matchSpaRoot`:

```zig
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
    return rit.next() == null; // pattern exhausted: match iff the path is too
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect all green (`Build Summary: N/N tests passed`).
- [ ] `git add src/static_files.zig && git commit -m "feat(static): Tier-2 static_routes segment matcher (#183)"`

---

## Task 3 — Miss-path wiring: `serve()` gains a `Fallback` parameter (.spa refusal → real file → routes → marker)

**Files:**
- Modify: `src/static_files.zig` (serve signature + resolution order + tests)
- Modify: `src/app.zig` (two new runtime fields)
- Modify: `src/server.zig` (the single call site)

**Interfaces:**
- Consumes (from Tasks 1–2, all already in `src/static_files.zig`): `Fallback`, `StaticRoute`, `matchRoute`, `matchSpaRoot`, `isSpaMarkerPath`; existing privates `serveEmbedded(ctx, files, rel)`, `serveDir(io, ctx, root, rel)`, `sanitize`.
- Produces:
  - Changed signature: `pub fn serve(io: std.Io, ctx: *http.RequestCtx, source: Source, fb: Fallback) !?http.Response` (was 3 params).
  - New private `fn serveRel(io: std.Io, ctx: *http.RequestCtx, source: Source, rel: []const u8) !?http.Response`.
  - New fields on `pub const App` in `src/app.zig`: `static_routes: []const @import("static_files.zig").StaticRoute = &.{}` and `spa_roots: []const []const u8 = &.{}`.

Context: `src/server.zig:onRequest` (~line 858–866) enters the static branch only for GET/HEAD, `static_source != .none`, and paths not `/api`/`/api/*`; a miss currently returns a plain-text 404. This task extends `serve()`'s miss path per the normative resolution order: (1) refuse to serve the `.spa` file itself, (2) real file wins (existing lookup incl. directory→index.html), (3) first matching Tier-2 route serves its target (a matched route is **terminal** — explicit config beats convention, even if the target went missing post-startup), (4) the longest `/`-bounded Tier-1 marker root serves `<root>/index.html`, (5) null (caller's plain 404, unchanged). Fallback documents go through `serveRel` = the existing per-source serve functions, so status 200, `Content-Type` from the served file, nosniff, embedded CRC32 ETag + If-None-Match→304, dir-mode facil.io sendFile caching, HEAD-mirrors-GET, and the F10 realpath/withinRoot symlink check are ALL inherited — add no header/caching code. With `fb = .{}` behavior is byte-identical to today (acceptance criterion 3, sole delta: a file literally named `.spa` is no longer servable).

- [ ] Read `src/static_files.zig`, `src/app.zig`, and `src/server.zig` lines 800–899 first.
- [ ] Add failing tests at the end of `src/static_files.zig` (they call the 4-arg `serve`, so the build fails until implemented). Note `spa_fixture` was added in Task 1:

```zig
test "spa fallback: miss under marked root serves its index.html (embedded: 200/html/ETag)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &spa_fixture };
    const fb = Fallback{ .spa_roots = &.{ "app", "" } };

    var deep = http.RequestCtx{ .method = .GET, .path = "/app/orders/1234", .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &deep, src, fb)).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("<h1>app shell</h1>", r.body);
    try std.testing.expectEqualStrings("text/html", r.content_type);
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
    const fb = Fallback{ .spa_roots = &.{ "app", "" } };

    var out = http.RequestCtx{ .method = .GET, .path = "/pricing/enterprise", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &out, src, fb)).?.body);
    var in = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>app shell</h1>", (try serve(std.testing.io, &in, src, fb)).?.body);
    // '/'-bounded: /application/x belongs to the ROOT marker, not app/.
    var appl = http.RequestCtx{ .method = .GET, .path = "/application/x", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &appl, src, fb)).?.body);
    // A dropped inner root (fb without "app") falls through to the outer marker.
    const outer_only = Fallback{ .spa_roots = &.{""} };
    var fell = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    try std.testing.expectEqualStrings("<h1>home</h1>", (try serve(std.testing.io, &fell, src, outer_only)).?.body);
}

test "spa fallback: no marker/no routes => serve returns null (miss 404s, AC3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var miss = http.RequestCtx{ .method = .GET, .path = "/app/orders/1", .allocator = arena.allocator() };
    try std.testing.expect((try serve(std.testing.io, &miss, Source{ .embedded = &spa_fixture }, .{})) == null);
}

test "spa fallback: '.spa' itself is never served (embedded + dir)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Embedded: the marker bytes must never appear; with the marker active the
    // request falls through to the shell.
    const src = Source{ .embedded = &spa_fixture };
    var m1 = http.RequestCtx{ .method = .GET, .path = "/app/.spa", .allocator = a };
    const r1 = (try serve(std.testing.io, &m1, src, .{ .spa_roots = &.{"app"} })).?;
    try std.testing.expectEqualStrings("<h1>app shell</h1>", r1.body);
    // ...and with NO fallback configured it is a plain miss (null), not the bytes.
    var m2 = http.RequestCtx{ .method = .GET, .path = "/app/.spa", .allocator = a };
    try std.testing.expect((try serve(std.testing.io, &m2, src, .{})) == null);
    // Other dotfiles keep serving (.well-known must not break): add none here — the
    // refusal is scoped to the literal '.spa' final segment (see isSpaMarkerPath test).

    // Dir mode: a real .spa file on disk is refused too.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".spa", .data = "MARKER-SECRET" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<h1>root</h1>" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var m3 = http.RequestCtx{ .method = .GET, .path = "/.spa", .allocator = a };
    const r3 = (try serve(std.testing.io, &m3, Source{ .dir = root }, .{ .spa_roots = &.{""} })).?;
    try std.testing.expect(r3.file_path != null);
    try std.testing.expect(std.mem.endsWith(u8, r3.file_path.?, "index.html"));
}

test "spa fallback: If-None-Match on the embedded fallback yields 304; HEAD mirrors GET" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &spa_fixture };
    const fb = Fallback{ .spa_roots = &.{"app"} };
    var cond = http.RequestCtx{ .method = .GET, .path = "/app/deep/link", .allocator = arena.allocator(), .if_none_match = "\"bbbbbbbb\"" };
    try std.testing.expectEqual(@as(u16, 304), (try serve(std.testing.io, &cond, src, fb)).?.status);
    var head = http.RequestCtx{ .method = .HEAD, .path = "/app/deep/link", .allocator = arena.allocator() };
    const hr = (try serve(std.testing.io, &head, src, fb)).?;
    try std.testing.expectEqual(@as(u16, 200), hr.status);
    try std.testing.expectEqualStrings("text/html", hr.content_type);
}

test "spa fallback: dir-mode fallback streams via file_path (facil.io owns caching)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/index.html", .data = "<h1>dir shell</h1>" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    var deep = http.RequestCtx{ .method = .GET, .path = "/app/orders/1234", .allocator = arena.allocator() };
    const r = (try serve(std.testing.io, &deep, Source{ .dir = root }, .{ .spa_roots = &.{"app"} })).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(r.file_path != null);
    try std.testing.expect(std.mem.endsWith(u8, r.file_path.?, "app/index.html"));
    // Dir mode emits ONLY nosniff; ETag/304 belong to facil.io sendFile.
    try std.testing.expectEqual(@as(usize, 1), r.extra_headers.len);
    try std.testing.expectEqualStrings("X-Content-Type-Options", r.extra_headers[0].name);
}

test "static_routes: matched on miss only (real file wins); routes beat the marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = Source{ .embedded = &spa_fixture };
    const routes = [_]StaticRoute{
        .{ .match = "/app/orders/:id", .serve = "/app/index.html" },
        .{ .match = "/app/**", .serve = "/index.html" },
    };
    const fb = Fallback{ .routes = &routes, .spa_roots = &.{"app"} };

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
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect COMPILE FAILURE (serve arity).
- [ ] Replace the existing `serve` function in `src/static_files.zig` (currently the 3-param version at ~line 167) with:

```zig
/// Resolve `source` to serve one relative path (shared by the direct lookup and both
/// fallback tiers, so fallback documents inherit ETag/304/HEAD/nosniff/F10 for free).
fn serveRel(io: std.Io, ctx: *http.RequestCtx, source: Source, rel: []const u8) !?http.Response {
    return switch (source) {
        .none => unreachable, // gated in serve()
        .embedded => |files| serveEmbedded(ctx, files, rel),
        .dir => |root| serveDir(io, ctx, root, rel),
    };
}

/// Serve `ctx.path` from `source`. Returns null when nothing matches (the caller
/// emits its 404), including for non-GET/HEAD methods and `.none` sources.
/// HEAD gets the same response as GET (status + headers + body/file_path);
/// stripping the body for HEAD is the transport layer's (zap/facil.io) job.
///
/// Miss resolution (issue #183), in order:
///   1. the '.spa' marker file itself is never servable (skips the file lookup);
///   2. a real file always wins (incl. directory -> index.html resolution);
///   3. Tier 2: the first matching `fb.routes` entry serves its fixed target —
///      terminal even if the target went missing after startup validation;
///   4. Tier 1: the longest '/'-bounded `fb.spa_roots` prefix serves `<root>/index.html`;
///   5. null (the caller's plain-text 404, unchanged).
pub fn serve(io: std.Io, ctx: *http.RequestCtx, source: Source, fb: Fallback) !?http.Response {
    if (ctx.method != .GET and ctx.method != .HEAD) return null;
    if (std.meta.activeTag(source) == .none) return null;
    const rel = (try sanitize(ctx.allocator, ctx.path)) orelse return null;
    if (!isSpaMarkerPath(rel)) {
        if (try serveRel(io, ctx, source, rel)) |hit| return hit;
    }
    for (fb.routes) |rt| {
        if (matchRoute(rt.match, rel))
            return serveRel(io, ctx, source, std.mem.trimLeft(u8, rt.serve, "/"));
    }
    if (matchSpaRoot(fb.spa_roots, rel)) |root| {
        const shell = if (root.len == 0)
            "index.html"
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}/index.html", .{root});
        return serveRel(io, ctx, source, shell);
    }
    return null;
}
```

- [ ] Update every PRE-EXISTING `serve(...)` call in `src/static_files.zig`'s tests to pass `.{}` as the 4th argument. There are exactly these tests to touch: `"embedded: exact file, root index, directory index, miss"` (6 calls), `"embedded: If-None-Match yields 304; non-GET/HEAD and .none yield null"` (3 calls), `"dir: serves files via file_path; index resolution; miss; traversal"` (5 calls), `"dir: a symlink inside the root pointing OUTSIDE it is refused (F10)"` (2 calls). Each `serve(std.testing.io, &X, src)` becomes `serve(std.testing.io, &X, src, .{})` (and the `Source.none` call likewise).
- [ ] Add the two runtime fields to `pub const App` in `src/app.zig`, right after the existing `static_source` field (~line 45):

```zig
    /// Tier-2 comptime static rewrites (issue #183), lowered from `App(.{ .static_routes })`
    /// by framework.zig and threaded here by serveImpl. Comptime constant slice
    /// (static lifetime); empty = no routes.
    static_routes: []const @import("static_files.zig").StaticRoute = &.{},
    /// Tier-1 `.spa` marker roots (issue #183): startup-scanned root-relative prefixes
    /// ("" = the static root), sorted longest-first. Owned/freed by serveImpl; empty =
    /// marker disabled or no markers (zero per-request cost on the happy path).
    spa_roots: []const []const u8 = &.{},
```

- [ ] Update the single call site in `src/server.zig` (~line 863). Old:

```zig
            if (static_files.serve(self.app.io, &ctx, self.app.static_source) catch null) |hit| break :blk hit;
```

New:

```zig
            if (static_files.serve(self.app.io, &ctx, self.app.static_source, .{
                .routes = self.app.static_routes,
                .spa_roots = self.app.spa_roots,
            }) catch null) |hit| break :blk hit;
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect all green (`Build Summary: N/N tests passed`; the count grew by 7).
- [ ] `git add src/static_files.zig src/app.zig src/server.zig && git commit -m "feat(static): serve() miss fallback — .spa marker + static_routes tiers (#183)"`

---

## Task 4 — Comptime config: `.static_routes` + `.enable_spa_marker` lowering in `framework.zig`

**Files:**
- Modify: `src/framework.zig`

**Interfaces:**
- Consumes: `static_files.StaticRoute`, `static_files.StaticFile` (via the `static_files` import already at the top of `framework.zig`); the existing `pub const static_mode: static_files.Mode` decl (~line 542) on the same App type.
- Produces (decls on the `App(cfg)` returned type):
  - `pub const static_routes: []const static_files.StaticRoute` (empty when the field is absent)
  - `pub const enable_spa_marker: bool` (default: `static_routes.len == 0`; explicit value wins)
  - Two new `ServeOpts` fields: `static_routes: []const static_files.StaticRoute = &.{}` and `enable_spa_marker: bool = true`
  - Two new entries in the `allowed` key tuple: `"static_routes"`, `"enable_spa_marker"`
  - Private comptime helpers `fn validateRoutePattern(comptime m: []const u8) void`, `fn validateServeTarget(comptime sv: []const u8) void`, `fn manifestHas(files: []const static_files.StaticFile, path: []const u8) bool`

Context: `src/framework.zig`'s `App(comptime cfg)` builder validates every top-level cfg key against an `allowed` tuple (~line 210) and lowers each key into a `pub const` decl (see `static_mode` ~line 542, `provision_migrations` ~line 723, `enable_typegen` line 466, `mail_config` ~line 809 for the conventions: `@hasField` probing, loud `@compileError` for malformed shapes, coercion of structurally-identical anonymous types). Lowered values are threaded via the `Opts = ServeOpts{...}` literal (~line 830) into `serveImpl`. Comptime validation rules (normative, from the design spec): each entry must have exactly `match` + `serve` (strings); both must start with `/`; no empty pattern segment after the leading one; `*`/`**` terminal-only and never mixed with literal text in a segment; `:` must start its own segment and have a name; `serve` must contain no `:`/`*`/`..`; non-empty `.static_routes` with `.static_files = .disabled` is a compile error; in `.embedded` mode every `serve` target must resolve in the manifest (exact path, or `<path>/index.html`, or `index.html` for `/`). `enable_spa_marker` must be a `bool`; its default is `true` when `static_routes` is absent/empty, `false` when non-empty.

- [ ] Read `src/framework.zig` lines 196–262 (allowed keys), 460–470 (`enable_typegen`), 540–562 (`static_mode`), 716–730 (`migrations` guard), 826–865 (`Opts` + entry points), 950–1010 (`ServeOpts`), and the tests at lines 2270–2320.
- [ ] Add failing tests near the existing `"App(cfg) static_files modes"` test (~line 2318):

```zig
test "App(cfg) static_routes lowering: absent => empty; entries coerced; order preserved" {
    try std.testing.expectEqual(@as(usize, 0), App(.{}).static_routes.len);

    const manifest = struct {
        const F = struct { path: []const u8, bytes: []const u8, etag: []const u8 };
        pub const files = [_]F{
            .{ .path = "index.html", .bytes = "<p>hi</p>", .etag = "\"abc\"" },
            .{ .path = "app/index.html", .bytes = "<p>app</p>", .etag = "\"def\"" },
        };
    };
    const R = App(.{
        .static_files = .{ .embedded = &manifest.files },
        .static_routes = &.{
            .{ .match = "/app/orders/:id", .serve = "/app/index.html" },
            .{ .match = "/app/**", .serve = "/app" }, // directory target -> app/index.html
        },
    });
    try std.testing.expectEqual(@as(usize, 2), R.static_routes.len);
    try std.testing.expectEqualStrings("/app/orders/:id", R.static_routes[0].match);
    try std.testing.expectEqualStrings("/app/index.html", R.static_routes[0].serve);
    try std.testing.expectEqualStrings("/app/**", R.static_routes[1].match);
    try std.testing.expectEqualStrings("/app", R.static_routes[1].serve);

    // Dir mode: no comptime manifest to check against (targets are startup-validated).
    const D = App(.{
        .static_files = .{ .dir = "frontend/dist" },
        .static_routes = &.{.{ .match = "/**", .serve = "/index.html" }},
    });
    try std.testing.expectEqual(@as(usize, 1), D.static_routes.len);
}

test "App(cfg) enable_spa_marker default: true without routes, false with routes, explicit wins" {
    try std.testing.expect(App(.{}).enable_spa_marker);
    try std.testing.expect(!App(.{ .enable_spa_marker = false }).enable_spa_marker);

    const manifest = struct {
        const F = struct { path: []const u8, bytes: []const u8, etag: []const u8 };
        pub const files = [_]F{.{ .path = "index.html", .bytes = "<p>hi</p>", .etag = "\"abc\"" }};
    };
    const WithRoutes = App(.{
        .static_files = .{ .embedded = &manifest.files },
        .static_routes = &.{.{ .match = "/**", .serve = "/index.html" }},
    });
    try std.testing.expect(!WithRoutes.enable_spa_marker); // routes flip the default off

    const Explicit = App(.{
        .static_files = .{ .embedded = &manifest.files },
        .static_routes = &.{.{ .match = "/**", .serve = "/index.html" }},
        .enable_spa_marker = true,
    });
    try std.testing.expect(Explicit.enable_spa_marker); // explicit always wins
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect COMPILE FAILURE (unknown cfg field `static_routes` / missing decls).
- [ ] Add `"static_routes", "enable_spa_marker"` to the `allowed` tuple (~line 210, keep it one line, append before the closing `}`).
- [ ] Add the lowering decls right after the `static_mode` decl (~line 561), plus the file-scope helpers (place the three helper fns near `migrationsCoerce` at ~line 171):

```zig
        /// Tier-2 comptime static rewrites (issue #183): `.static_routes` lowered into a
        /// typed slice (empty when absent). Validates entry shape + pattern grammar with
        /// loud @compileErrors; in `.embedded` mode also proves every serve target exists
        /// in the manifest ("validated at build time"). Dir-mode targets are startup-
        /// validated in serveImpl instead (comptime can't see the filesystem).
        pub const static_routes: []const static_files.StaticRoute = blk: {
            if (!@hasField(@TypeOf(cfg), "static_routes")) break :blk &.{};
            const raw = cfg.static_routes;
            const RT = @TypeOf(raw);
            const list = lst: {
                switch (@typeInfo(RT)) {
                    .pointer => |p| switch (p.size) {
                        .one => break :lst raw.*, // &.{ ... } tuple/array pointer
                        .slice => break :lst raw,
                        else => {},
                    },
                    .@"struct" => |s| if (s.is_tuple) break :lst raw,
                    else => {},
                }
                @compileError(".static_routes must be a list of '.{ .match = \"/…\", .serve = \"/…\" }' entries; got '" ++ @typeName(RT) ++ "'");
            };
            const n = switch (@typeInfo(@TypeOf(list))) {
                .@"struct" => std.meta.fields(@TypeOf(list)).len,
                .array => |a| a.len,
                .pointer => list.len,
                else => unreachable,
            };
            if (n == 0) break :blk &.{};
            if (std.meta.activeTag(static_mode) == .disabled)
                @compileError(".static_routes requires static serving, but '.static_files = .disabled'; drop one of them");
            var out: [n]static_files.StaticRoute = undefined;
            inline for (0..n) |i| {
                const e = list[i];
                const ET = @TypeOf(e);
                if (ET != static_files.StaticRoute) {
                    if (@typeInfo(ET) != .@"struct")
                        @compileError(".static_routes: each entry must be '.{ .match = \"/…\", .serve = \"/…\" }'");
                    for (std.meta.fields(ET)) |f| {
                        if (!std.mem.eql(u8, f.name, "match") and !std.mem.eql(u8, f.name, "serve"))
                            @compileError(".static_routes: unknown key '." ++ f.name ++ "' (recognized: .match, .serve)");
                    }
                    if (!@hasField(ET, "match") or !@hasField(ET, "serve"))
                        @compileError(".static_routes: each entry needs BOTH .match and .serve");
                }
                const m: []const u8 = e.match;
                const sv: []const u8 = e.serve;
                validateRoutePattern(m);
                validateServeTarget(sv);
                out[i] = .{ .match = m, .serve = sv };
            }
            const final = out;
            if (std.meta.activeTag(static_mode) == .embedded) {
                const files = static_mode.embedded;
                for (final) |rt| {
                    const rel = rt.serve[1..];
                    const found = manifestHas(files, if (rel.len == 0) "index.html" else rel) or
                        (rel.len > 0 and manifestHas(files, rel ++ "/index.html"));
                    if (!found)
                        @compileError("static_routes: serve target '" ++ rt.serve ++ "' not in the embedded manifest");
                }
            }
            break :blk &final;
        };

        /// Tier-1 `.spa` marker enablement (issue #183). Default: ON when `static_routes`
        /// is absent/empty (a plain custom build stays byte-identical to the shipped
        /// binary), OFF when routes are declared (explicit config shouldn't gain stray-
        /// dotfile behavior). An explicit `.enable_spa_marker = true|false` always wins.
        pub const enable_spa_marker: bool = blk: {
            if (@hasField(@TypeOf(cfg), "enable_spa_marker")) {
                if (@TypeOf(cfg.enable_spa_marker) != bool)
                    @compileError(".enable_spa_marker must be a bool; got '" ++ @typeName(@TypeOf(cfg.enable_spa_marker)) ++ "'");
                break :blk cfg.enable_spa_marker;
            }
            break :blk static_routes.len == 0;
        };
```

File-scope helpers (NOT inside `App(cfg)`; place near `migrationsCoerce`):

```zig
/// Comptime grammar check for one `.static_routes` match pattern (issue #183):
/// leading '/'; segments are literals, ':name' (one segment), or a TERMINAL '*'
/// (one-or-more) / '**' (zero-or-more); wildcards/':' never mix with literal text.
fn validateRoutePattern(comptime m: []const u8) void {
    if (m.len == 0 or m[0] != '/')
        @compileError(".static_routes: match pattern '" ++ m ++ "' must start with '/'");
    if (m.len == 1) return; // "/" — the bare root literal
    var it = std.mem.splitScalar(u8, m[1..], '/');
    var rest_seen = false;
    while (it.next()) |seg| {
        if (rest_seen)
            @compileError(".static_routes: '*'/'**' must be the FINAL segment in '" ++ m ++ "'");
        if (seg.len == 0)
            @compileError(".static_routes: empty segment ('//' or trailing '/') in '" ++ m ++ "'");
        if (std.mem.eql(u8, seg, "*") or std.mem.eql(u8, seg, "**")) {
            rest_seen = true;
            continue;
        }
        if (std.mem.indexOfScalar(u8, seg, '*') != null)
            @compileError(".static_routes: '*' cannot mix with literal text in segment '" ++ seg ++ "' of '" ++ m ++ "'");
        if (seg[0] == ':') {
            if (seg.len == 1)
                @compileError(".static_routes: ':' needs a name in '" ++ m ++ "'");
            continue;
        }
        if (std.mem.indexOfScalar(u8, seg, ':') != null)
            @compileError(".static_routes: ':' must start its own segment in '" ++ m ++ "' (got '" ++ seg ++ "')");
    }
}

/// Comptime check for one `.static_routes` serve target: a fixed leading-'/' path,
/// no ':'/'*' and no '..' (targets are trusted literals interpolated into the
/// static source, so wildcards and traversal are rejected outright).
fn validateServeTarget(comptime sv: []const u8) void {
    if (sv.len == 0 or sv[0] != '/')
        @compileError(".static_routes: serve target '" ++ sv ++ "' must start with '/'");
    if (std.mem.indexOfScalar(u8, sv, ':') != null or std.mem.indexOfScalar(u8, sv, '*') != null)
        @compileError(".static_routes: serve target '" ++ sv ++ "' must be a fixed path (no ':' or '*')");
    var it = std.mem.splitScalar(u8, sv[1..], '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".."))
            @compileError(".static_routes: serve target '" ++ sv ++ "' must not contain '..'");
    }
}

/// Comptime manifest membership test for embedded serve-target validation.
fn manifestHas(files: []const static_files.StaticFile, path: []const u8) bool {
    for (files) |f| if (std.mem.eql(u8, f.path, path)) return true;
    return false;
}
```

- [ ] Add the two `ServeOpts` fields (after `static_mode: static_files.Mode = .default,` at ~line 963):

```zig
    /// Tier-2 comptime static rewrites (issue #183), threaded into `app.static_routes`.
    /// Embedded serve targets were proven at comptime; dir targets are startup-validated
    /// in serveImpl (missing target = fatal, like a missing static dir).
    static_routes: []const static_files.StaticRoute = &.{},
    /// Tier-1 `.spa` marker gate (issue #183); false skips the startup scan entirely
    /// (a `.spa` file is then just another never-served dotfile).
    enable_spa_marker: bool = true,
```

- [ ] Thread them through the `Opts = ServeOpts{...}` literal (~line 830): add `.static_routes = static_routes,` and `.enable_spa_marker = enable_spa_marker,`.
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect all green.
- [ ] Manual `@compileError` spot-check (these can't be unit tests): append a TEMPORARY test to `src/framework.zig`:

```zig
test "TEMP compile-error probe — DELETE ME" {
    _ = App(.{ .static_files = .disabled, .static_routes = &.{.{ .match = "/x/**", .serve = "/index.html" }} });
}
```

  Run the build — expect the `.static_routes requires static serving` compile error. Then swap the probe body once for each of: a bad pattern (`.match = "/f*.html"` with a valid embedded manifest config → wildcard-mixing error) and a missing embedded target (`.serve = "/nope.html"` against the 1-file manifest → `not in the embedded manifest`). After confirming all three messages, **remove the temporary test with the Edit tool** (do NOT `git checkout` the file — you have real changes in it).
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` once more — all green, temp test gone (`grep -n "DELETE ME" src/framework.zig` returns nothing).
- [ ] `git add src/framework.zig && git commit -m "feat(framework): comptime .static_routes + .enable_spa_marker lowering (#183)"`

---

## Task 5 — Startup wiring: marker scan, dir-target validation, fatal no-source guard in `serveImpl`

**Files:**
- Modify: `src/static_files.zig` (add `validateRouteTargetsDir` + unit tests)
- Modify: `src/framework.zig` (`serveImpl` wiring)

**Interfaces:**
- Consumes: `static_files.scanSpaRoots`, `static_files.freeSpaRoots` (Task 1); `ServeOpts.static_routes` / `ServeOpts.enable_spa_marker` (Task 4); `app_mod.App.static_routes` / `.spa_roots` (Task 3); the resolved `static_source: static_files.Source` local in `serveImpl` (~line 1684).
- Produces:
  - `pub fn validateRouteTargetsDir(io: std.Io, alloc: std.mem.Allocator, root: []const u8, routes: []const StaticRoute) !void` in `src/static_files.zig` (errors: `error.StaticRouteTargetMissing`).
  - `serveImpl` gains: fatal `error.StaticRoutesRequireStaticSource` when routes are configured but the source is `.none`; a call to `validateRouteTargetsDir` in `.dir` mode; the `scanSpaRoots` call gated on `opts.enable_spa_marker`, with `defer freeSpaRoots`; the two new fields set in the `app_mod.App{...}` literal.

Context: `src/framework.zig:serveImpl` resolves `static_source` from the comptime mode + `--serve-static` (~line 1684–1702: a `switch` probes a `.dir` source with `openDir` and returns fatal `error.StaticDirUnavailable` on failure), then constructs `var app = app_mod.App{ ... .static_source = static_source, ... }` (~line 1704). Design decisions (normative): dir-mode Tier-2 serve targets are checked at startup with `statFile` (a missing target is FATAL, mirroring the missing-dir precedent — a directory target counts as present when its `/index.html` exists); a build that declares `static_routes` but starts with source `.none` (`.default` mode without `--serve-static`) is also fatal ("routes that can serve nothing are a misconfiguration, not a no-op"); the marker scan runs once, immediately after the probe, only when `enable_spa_marker` — when disabled, `spa_roots` stays the comptime empty slice and no filesystem work happens. `serveImpl`'s stack vars outlive the listener via `defer` (see `storage_inst`/`rate_limiter` for the pattern), so `defer freeSpaRoots(...)` placed before `srv.listen()` frees on shutdown.

- [ ] Add failing unit tests at the end of `src/static_files.zig`:

```zig
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
    try validateRouteTargetsDir(std.testing.io, a, root, &good);

    const bad = [_]StaticRoute{.{ .match = "/x/**", .serve = "/missing.html" }};
    try std.testing.expectError(error.StaticRouteTargetMissing, validateRouteTargetsDir(std.testing.io, a, root, &bad));

    // A directory target WITHOUT an index.html is missing too.
    try tmp.dir.createDirPath(std.testing.io, "empty");
    const bad_dir = [_]StaticRoute{.{ .match = "/y/**", .serve = "/empty" }};
    try std.testing.expectError(error.StaticRouteTargetMissing, validateRouteTargetsDir(std.testing.io, a, root, &bad_dir));
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect COMPILE FAILURE (`validateRouteTargetsDir` undeclared).
- [ ] Implement in `src/static_files.zig` (place after `freeSpaRoots`):

```zig
/// Startup validation (Tier 2, dir mode; issue #183): every `serve` target must resolve
/// to a real file under `root` — the exact path, its `/index.html` when it names a
/// directory, or the root `index.html` for "/". A missing target is a FATAL startup
/// error, mirroring the missing-static-dir precedent (embedded targets are proven at
/// comptime instead; comptime can't see the filesystem).
pub fn validateRouteTargetsDir(io: std.Io, alloc: std.mem.Allocator, root: []const u8, routes: []const StaticRoute) !void {
    for (routes) |rt| {
        const rel = std.mem.trimLeft(u8, rt.serve, "/");
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
        if (!ok) {
            std.log.err("static_routes: serve target '{s}' not found under static dir '{s}'", .{ rt.serve, root });
            return error.StaticRouteTargetMissing;
        }
    }
}
```

- [ ] Run the test build — all green.
- [ ] Wire `serveImpl` in `src/framework.zig`. Directly AFTER the existing static-dir probe `switch (static_source) { .dir => |dir_path| { ... error.StaticDirUnavailable ... }, else => {} }` (ends ~line 1702) and BEFORE `var app = app_mod.App{` (~line 1704), insert:

```zig
    // Tier-2 startup validation (issue #183): embedded serve targets were proven at
    // comptime; dir targets are statted here (missing = fatal, like a missing static
    // dir). Routes with NO active source could never serve anything — also fatal.
    if (opts.static_routes.len > 0) switch (static_source) {
        .none => {
            std.log.err("static_routes is configured but no static source is active (run with --serve-static <dir> or set a comptime .static_files source)", .{});
            return error.StaticRoutesRequireStaticSource;
        },
        .dir => |dir_path| try static_files.validateRouteTargetsDir(io, allocator, dir_path, opts.static_routes),
        .embedded => {},
    };
    // Tier-1 startup scan (issue #183): collect `.spa` marker roots once per process
    // (startup-only by design — adding/removing a marker requires a restart). Empty
    // when the marker is disabled or no markers exist: zero per-request cost.
    const spa_roots: []const []const u8 = if (opts.enable_spa_marker)
        try static_files.scanSpaRoots(io, allocator, static_source)
    else
        &.{};
    defer static_files.freeSpaRoots(allocator, spa_roots);
```

- [ ] In the `var app = app_mod.App{ ... }` literal, right after `.static_source = static_source,` add:

```zig
        .static_routes = opts.static_routes,
        .spa_roots = spa_roots,
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — all green.
- [ ] Smoke-test the shipped binary end to end (Tier 1 live):

```sh
mise exec zig@0.16.0 -- zig build
mkdir -p /tmp/spa-smoke/app && printf '<h1>shell</h1>' > /tmp/spa-smoke/app/index.html && touch /tmp/spa-smoke/app/.spa && printf '<h1>home</h1>' > /tmp/spa-smoke/index.html
ZIGBASE_JWT_SECRET=test-secret-not-default-0123456789abcdef ./zig-out/bin/zigbase serve --http-port 8099 --data-dir /tmp/spa-smoke-data --serve-static /tmp/spa-smoke --insecure-cookies &
sleep 2
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8099/app/orders/1234   # expect 200
curl -s http://127.0.0.1:8099/app/orders/1234                                    # expect <h1>shell</h1>
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8099/nope              # expect 404
kill %1; rm -rf /tmp/spa-smoke /tmp/spa-smoke-data
```

- [ ] `git add src/static_files.zig src/framework.zig && git commit -m "feat(framework): startup .spa scan + Tier-2 dir-target validation wiring (#183)"`

---

## Task 6 — Python e2e: marker fallback acceptance tests (`tests/admin/test_static_files.py`)

**Files:**
- Modify: `tests/admin/test_static_files.py`

**Interfaces:**
- Consumes: the module's existing helpers `_free_port()`, `_wait_up(url)`, `_get(url, headers=None) -> (status, headers_msg, body)`, `_hdr(msg, name)`, and `resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")` from `from _bin import resolve_binary, resolve_plugins_binary`. Follow `test_serve_static_runtime_mode` exactly: temp static dir + temp data dir, `subprocess.Popen([binary, "serve", "--http-port", str(port), "--data-dir", data, "--serve-static", static], env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"})`, `try/finally: proc.terminate(); proc.wait(timeout=10)`.
- Produces: two new test functions `test_spa_marker_fallback` and `test_spa_marker_root`.

Context: These are the end-to-end acceptance tests for issue #183 Tier 1 in the shipped binary. This suite is the authority — a green `zig build test` does not prove e2e behavior. Each acceptance criterion below is quoted verbatim from the issue and must map to an assertion.

- **AC1:** *"Shipped binary, `public/app/.spa` present: hard GET `/app/orders/1234` → `public/app/index.html` (200); `/app/assets/app.js` and other real files serve directly; `/` and other paths outside `/app/` are unaffected."* → `test_spa_marker_fallback`.
- **AC2:** *"`public/.spa` present: any miss under `/` → `/index.html` (200); real files still win."* → `test_spa_marker_root`.
- **AC3:** *"No marker, no comptime routes: behavior is exactly as today (misses 404)."* → the pre-existing `test_serve_static_runtime_mode` (do not modify it) is the regression proof; it must still pass.
- **AC4:** *"The marker never rewrites a request that an API route handles."* → the `/api/definitely-missing` JSON-404 assertions inside BOTH new tests (with a root marker present, the JSON envelope must survive).

- [ ] Ensure a binary exists: `mise exec zig@0.16.0 -- zig build` (from the repo root; carries Tasks 1–5).
- [ ] Append the two tests to `tests/admin/test_static_files.py`:

```python
def test_spa_marker_fallback():
    """Issue #183 AC1 + AC4: 'Shipped binary, public/app/.spa present: hard GET
    /app/orders/1234 -> public/app/index.html (200); /app/assets/app.js and other real
    files serve directly; / and other paths outside /app/ are unaffected.' And: 'The
    marker never rewrites a request that an API route handles.'"""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>site home</h1>")
        (pub / "app").mkdir()
        (pub / "app" / "index.html").write_text("<h1>app shell</h1>")
        (pub / "app" / ".spa").write_text("MARKER-SECRET")  # contents are ignored (presence-only)
        (pub / "app" / "assets").mkdir()
        (pub / "app" / "assets" / "app.js").write_text("console.log('real asset')")
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")

            # AC1: deep link under the marked dir -> the app shell, 200 text/html
            st, hdr, body = _get(f"{base}/app/orders/1234")
            assert st == 200 and b"app shell" in body
            assert "text/html" in _hdr(hdr, "content-type")

            # AC1: real files under the marked dir serve directly
            st, _, body = _get(f"{base}/app/assets/app.js")
            assert st == 200 and b"real asset" in body

            # an extension-bearing MISS under the root still gets the shell (200 HTML)
            st, hdr, body = _get(f"{base}/app/assets/gone.js")
            assert st == 200 and b"app shell" in body

            # AC1: / serves the real root index; misses OUTSIDE /app/ still 404
            st, _, body = _get(f"{base}/")
            assert st == 200 and b"site home" in body
            st, hdr, _ = _get(f"{base}/pricing")
            assert st == 404
            assert "application/json" not in _hdr(hdr, "content-type")
            # '/'-bounded: /application is outside the app/ subtree
            st, _, _ = _get(f"{base}/application")
            assert st == 404

            # the marker file itself is never served (falls through to the shell)
            st, _, body = _get(f"{base}/app/.spa")
            assert b"MARKER-SECRET" not in body
            assert st == 200 and b"app shell" in body

            # AC4: unknown /api paths keep the JSON 404 envelope
            st, hdr, _ = _get(f"{base}/api/definitely-missing")
            assert st == 404
            assert "application/json" in _hdr(hdr, "content-type")
        finally:
            proc.terminate(); proc.wait(timeout=10)


def test_spa_marker_root():
    """Issue #183 AC2 + AC4: 'public/.spa present: any miss under / -> /index.html
    (200); real files still win.' API misses keep the JSON envelope."""
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
    with tempfile.TemporaryDirectory() as static, tempfile.TemporaryDirectory() as data:
        pub = pathlib.Path(static)
        (pub / "index.html").write_text("<h1>spa root shell</h1>")
        (pub / ".spa").write_text("")
        (pub / "assets").mkdir()
        (pub / "assets" / "app.js").write_text("console.log('root asset')")
        port = _free_port()
        proc = subprocess.Popen(
            [str(binary), "serve", "--http-port", str(port), "--data-dir", data,
             "--serve-static", static],
            env={**os.environ, "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef"},
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_up(f"{base}/api/health")

            # AC2: any miss -> the root shell (200)
            st, hdr, body = _get(f"{base}/some/deep/client/route")
            assert st == 200 and b"spa root shell" in body
            assert "text/html" in _hdr(hdr, "content-type")

            # AC2: real files still win
            st, _, body = _get(f"{base}/assets/app.js")
            assert st == 200 and b"root asset" in body

            # AC4: the root marker must NOT swallow the API namespace
            st, hdr, _ = _get(f"{base}/api/definitely-missing")
            assert st == 404
            assert "application/json" in _hdr(hdr, "content-type")
            st, hdr, _ = _get(f"{base}/api")
            assert st == 404
            assert "application/json" in _hdr(hdr, "content-type")

            # the admin SPA still wins over the root marker
            st, hdr, _ = _get(f"{base}/_/")
            assert st == 200 and "text/html" in _hdr(hdr, "content-type")
        finally:
            proc.terminate(); proc.wait(timeout=10)
```

- [ ] Run `mise exec python@3.13 -- python -m pytest tests/admin/test_static_files.py -q` — expect ALL tests in the file to pass (the two new ones plus the pre-existing three; `test_embedded_static_in_plugins_example` may `skip` if npm is unavailable — skip is acceptable, failure is not). Note the TDD failing-first state is not applicable here: Tasks 1–5 (the implementation) are already committed, so these tests assert the shipped behavior against the issue's acceptance criteria; the pre-existing `test_serve_static_runtime_mode` still passing is the AC3 no-regression proof.
- [ ] `git add tests/admin/test_static_files.py && git commit -m "test(admin): e2e .spa marker fallback coverage — AC1/AC2/AC4 (#183)"`

---

## Task 7 — `examples/plugins`: comptime `static_routes` demo + vitest deep-link e2e (AC5)

**Files:**
- Modify: `examples/plugins/src/main.zig`
- Create: `examples/plugins/test/spa.e2e.test.ts`

**Interfaces:**
- Consumes: the example's existing `zigbase.App(.{ ... .static_files = .{ .embedded = &@import("static_assets").files }, ... })` config (item 8, ~line 660 of `examples/plugins/src/main.zig`); the vitest harness `startPlugins(): Promise<PluginsServer>` from `examples/plugins/test/harness.ts` (it builds the frontend + binary itself and returns `{ url, dataDir, bin, stop() }` — see `typegen.e2e.test.ts` for the usage pattern).
- Produces: a `.static_routes` entry on the example App; a new vitest file exercising the embedded-manifest comptime validation + first-match serving end to end.

Context: This is the issue's acceptance criterion 5 vehicle: *"Custom build with `static_routes`: mappings resolve per the examples above; with `enable_spa_marker = false` a stray `.spa` file has no effect."* The plugins example is the advanced rung of the examples ladder and is built in CI, so adding one catch-all route gives free CI coverage of the comptime lowering + embedded-target validation. Note the default interplay: declaring `static_routes` flips `enable_spa_marker` to `false` automatically — the example demonstrates exactly the "off by default in custom builds with routes" story without setting the key. The embedded Astro frontend has a single page whose built `index.html` contains the phrase "one binary" (case-insensitively; the existing admin e2e asserts this). Do NOT touch `examples/plugins/zig-pkg/` (vendored) or the other two examples.

- [ ] In `examples/plugins/src/main.zig`, after the `.static_files = .{ .embedded = &@import("static_assets").files },` line (item 8), add:

```zig
        // 11. Tier-2 SPA fallback routing (issue #183): any GET/HEAD static MISS below
        //     /app/ serves the embedded frontend shell. The serve target is validated
        //     against the embedded manifest AT COMPTIME — misspell it and the build
        //     fails. Declaring routes also flips the Tier-1 `.spa` marker default OFF
        //     (set `.enable_spa_marker = true` to combine both).
        .static_routes = &.{
            .{ .match = "/app/**", .serve = "/index.html" },
        },
```

- [ ] Build the example (frontend first — its dist is embedded):

```sh
cd examples/plugins/frontend && mise exec node@24 -- npm install && mise exec node@24 -- npm run build
cd .. && mise exec zig@0.16.0 -- zig build
```

Expect: clean build (proves the comptime lowering + manifest validation accept a real manifest).
- [ ] Create `examples/plugins/test/spa.e2e.test.ts`:

```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startPlugins, type PluginsServer } from "./harness.js";

// Issue #183 AC5 — "Custom build with static_routes: mappings resolve per the
// examples; ..." The /app/** catch-all in src/main.zig serves the embedded
// frontend shell (comptime-validated against the static_assets manifest) for any
// static miss below /app/.

let server: PluginsServer;
beforeAll(async () => { server = await startPlugins(); }, 120_000);
afterAll(() => server?.stop());

describe("plugins — comptime static_routes SPA fallback (#183)", () => {
  it("serves the embedded shell for a deep link under /app/", async () => {
    const res = await fetch(`${server.url}/app/some/deep/client/route`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type") ?? "").toContain("text/html");
    const body = await res.text();
    expect(body.toLowerCase()).toContain("one binary"); // the frontend shell's copy
  });

  it("does not match the bare /app... prefix outside the segment boundary", async () => {
    // '/application' shares only a string prefix with '/app/**' — segment matching
    // must NOT rewrite it, so it stays a plain static 404.
    const res = await fetch(`${server.url}/application`);
    expect(res.status).toBe(404);
  });

  it("never rewrites the API namespace (JSON 404 envelope preserved)", async () => {
    const res = await fetch(`${server.url}/api/definitely-missing`);
    expect(res.status).toBe(404);
    expect(res.headers.get("content-type") ?? "").toContain("application/json");
  });
});
```

  Note: `/app/**` DOES match the bare `/app` (zero-or-more) — that request also serves the shell; the boundary test uses `/application` instead.
- [ ] Run the example's e2e suite: `cd examples/plugins && mise exec node@24 -- npm install && mise exec node@24 -- npm run test:e2e`. Expect: the new `spa.e2e.test.ts` AND the existing `typegen.e2e.test.ts` pass (the harness builds/starts the binary itself; the first run can take minutes).
- [ ] `git add examples/plugins/src/main.zig examples/plugins/test/spa.e2e.test.ts && git commit -m "feat(examples/plugins): static_routes catch-all + deep-link e2e (#183)"`

---

## Task 8 — Docs, README, site mirror, changelog fragment

**Files:**
- Modify: `docs/framework.md` (§13 "Serve a frontend: static files")
- Modify: `site/src/content/docs/framework.md` (mirror of §13 — same section text; the site copy has YAML frontmatter and its §13 sits at a different line, ~2789)
- Modify: `docs/api.md` ("Static files" section, ~line 1031)
- Modify: `site/src/content/docs/api.md` (mirror of the same section)
- Modify: `site/src/content/docs/configuration.md` (site-only page; one paragraph under the `serve` command bullet)
- Modify: `README.md` (the existing "Static files" bullet, line ~53)
- Create: `changelog.d/spa-fallback.md`

**Interfaces:** none (documentation). Consumes the shipped behavior from Tasks 1–7: `.spa` marker (presence-only, startup-only scan, longest-prefix-wins, missing-`index.html` warning+drop, `.spa` never served), `.static_routes` (matcher grammar + comptime/startup validation + first-match-wins + real-file-wins), `.enable_spa_marker` defaults.

- [ ] In `docs/framework.md` §13, after the existing dir-mode/fatal-startup paragraphs (before the "See [examples/blog/]…" line), add:

```markdown
### SPA fallback: the `.spa` marker

Client-routed apps (History-API SPAs) break on deep links: `/app/orders/42` is a
real URL in the browser but not a real file. Drop an empty file named **`.spa`**
into any directory of your static tree to mark it as an SPA root: any GET/HEAD
**miss** at or below that directory serves that directory's `index.html` with
status **200** (real files always win; every miss under the root gets the shell,
including extension-bearing paths like a stale hashed asset). The marker is
**presence-only** — its contents are ignored.

- Works in **both** static sources: a `--serve-static`/`.dir` tree on disk, and an
  `embedStaticDir` **embedded** manifest (bundlers that emit `dist/.spa` work
  identically either way — the marker travels with the build output).
- Markers **nest**: with `/.spa` and `/app/.spa`, a miss at `/app/orders/1` serves
  `app/index.html` and a miss at `/pricing` serves the root `index.html`
  (longest `/`-bounded prefix wins — `/application` is *not* under `app/`).
- The scan runs **once at startup** — adding or removing a marker requires a
  restart. A marked directory with no `index.html` logs a startup warning and is
  treated as unmarked.
- The `.spa` file itself is **never served** (other dotfiles — `.well-known/` —
  are unaffected). The `/api` namespace, the admin UI (`/_/`), and all custom
  routes always win over the fallback; non-GET/HEAD methods never reach it.
- Fallback responses ride the normal static pipeline: ETag/304 (embedded),
  facil.io caching (dir), `nosniff`, and HEAD-mirrors-GET all apply.

### SPA fallback: comptime `static_routes`

Custom builds can declare explicit `match → serve` rewrites instead of (or on top
of) the marker:

```zig
zigbase.App(.{
    .static_files = .{ .embedded = &@import("static_assets").files },
    .static_routes = &.{
        .{ .match = "/app/orders/:id", .serve = "/app/orders/_shell.html" },
        .{ .match = "/app/**",         .serve = "/app/index.html" },
    },
})
```

Patterns are matched segment-wise against the normalized path (trailing slashes
never matter), **first match wins in declaration order**, and only on a real-file
miss (real files always win). Routes are consulted **before** the marker.

| Segment | Matches |
|---|---|
| literal | exactly that segment |
| `:name` | exactly **one** segment (capture discarded — `serve` is a fixed path) |
| `*` | terminal only; **one or more** remaining segments (`/admin/*` does **not** match `/admin`) |
| `**` | terminal only; **zero or more** remaining segments (`/app/**` **does** match `/app`) |

Malformed patterns (wildcards mid-pattern or mixed with text, `//`, bare `:`),
entries without exactly `.match` + `.serve`, `serve` targets containing
`:`/`*`/`..`, and `.static_routes` alongside `.static_files = .disabled` are all
**compile errors**. In **embedded** mode every `serve` target is proven against
the manifest **at comptime**; in **dir** mode targets are checked **at startup**
(missing target = fatal, like a missing static dir), and declaring routes while
starting with no static source at all is also fatal.

### `enable_spa_marker`

`.enable_spa_marker = true|false` gates the marker scan. Default: **true** when
`static_routes` is absent/empty (the shipped-binary behavior), **false** when
routes are declared (explicit config shouldn't gain stray-dotfile behavior). An
explicit value always wins; with both enabled, routes match first and the marker
is the residual fallback. When false, a `.spa` file is just another never-served
dotfile.
```

- [ ] Mirror the same three subsections into `site/src/content/docs/framework.md` §13 at the equivalent position (~after line 2827 in the site copy; the section text is otherwise identical to `docs/framework.md`).
- [ ] In `docs/api.md` "Static files" (~line 1031): in the opening paragraph, change "while a static miss returns a plain-text 404 (`text/plain`)" to "while a static miss returns a plain-text 404 (`text/plain`) — unless an [SPA fallback](#spa-fallback) applies", and append to the bullet list:

```markdown
- **SPA fallback:** a directory containing a file named `.spa` is an SPA root —
  GET/HEAD misses at or below it serve that directory's `index.html` with 200
  (real files always win; the scan is startup-only; the `.spa` file itself is
  never served). Custom builds can also declare comptime `static_routes`
  rewrites, consulted before the marker. See
  [framework.md → Static files](framework.md) for details. <a id="spa-fallback"></a>
```

  Mirror the identical edit into `site/src/content/docs/api.md` (adjust the cross-link to the site's `./framework#13-serve-a-frontend-static-files` style used elsewhere in that file).
- [ ] In `site/src/content/docs/configuration.md`, extend the `**serve**` bullet (the one describing `--serve-static DIR`, ~line 35) with one sentence after "…(`.disabled`, `.dir`, or `.embedded`).":

```markdown
  A directory in the static tree containing an empty file named `.spa` becomes an
  SPA root: any GET/HEAD miss at or below it serves that directory's `index.html`
  (200) so client-routed apps survive deep links and hard refreshes — scanned once
  at startup; real files and `/api`/admin paths always win.
```

- [ ] In `README.md` line ~53, extend the existing bullet (do not add a new bullet):

```markdown
- **Static files** — serve a frontend from the same binary: `--serve-static <dir>` at runtime, or pin/embed it at comptime, with `.spa` SPA-fallback markers for client-routed apps. → [docs/framework.md](docs/framework.md)
```

- [ ] Create `changelog.d/spa-fallback.md`:

```markdown
### Features

- SPA fallback routing (#183): a presence-only `.spa` marker file makes its static
  directory an SPA root — GET/HEAD misses at or below it serve that directory's
  `index.html` (200), so client-routed apps survive deep links and hard refreshes.
  Works for both `--serve-static`/`.dir` trees and embedded manifests; scanned once
  at startup; real files, `/api`, admin, and custom routes always win.
- Comptime `static_routes` for custom builds (#183): declare `match → serve`
  rewrites on `App(.{ .static_routes = &.{...} })` with minimal segment matching
  (`:name` one segment, `*` one-or-more rest, `**` zero-or-more rest; first match
  wins). Patterns and embedded serve targets are validated at compile time; dir
  targets at startup. A new `enable_spa_marker` key gates the marker (default: on
  without routes, off with routes).

### Changed

- A static file literally named `.spa` is no longer servable (it now denotes an SPA
  root and falls through to the fallback/404); other dotfiles are unaffected (#183).
```

- [ ] Verify the site builds: `cd site && npm install && npm run build` — expect success.
- [ ] Final full verification from the repo root (repo policy: static-serving changes must pass the browser suite locally, not just unit tests):
  - `mise exec zig@0.16.0 -- zig build test --summary all` → `Build Summary: N/N tests passed`.
  - `mise exec zig@0.16.0 -- zig build` (fresh binary for the e2e suite).
  - `mise exec python@3.13 -- python -m pytest tests/admin/ -q` → the FULL admin browser suite passes (admin `/_/` serving must be unaffected by the fallback; this is where static/auth/realtime regressions that unit tests miss show up).
- [ ] `git add docs/framework.md docs/api.md site/src/content/docs/framework.md site/src/content/docs/api.md site/src/content/docs/configuration.md README.md changelog.d/spa-fallback.md && git commit -m "docs: .spa marker + static_routes — framework/api/config docs, site mirror, changelog fragment (#183)"`

---

## Acceptance-criteria coverage map

| # | Criterion (verbatim) | Covered by |
|---|---|---|
| 1 | "Shipped binary, `public/app/.spa` present: hard GET `/app/orders/1234` → `public/app/index.html` (200); `/app/assets/app.js` and other real files serve directly; `/` and other paths outside `/app/` are unaffected." | Task 6 `test_spa_marker_fallback` (e2e); Task 3 unit tests (`miss under marked root…`, `'/'-bounded`); Task 1 scan tests |
| 2 | "`public/.spa` present: any miss under `/` → `/index.html` (200); real files still win." | Task 6 `test_spa_marker_root` (e2e); Task 3 `root marker catches every miss` |
| 3 | "No marker, no comptime routes: behavior is exactly as today (misses 404)." | Task 3 `no marker/no routes => null` + all pre-existing static tests updated-but-unchanged; Task 6 keeps `test_serve_static_runtime_mode` green |
| 4 | "The marker never rewrites a request that an API route handles." | Task 6: `/api/definitely-missing` + bare `/api` JSON-404 assertions with markers active; Task 7 plugins e2e API test (structural: the fallback lives inside the static branch, downstream of the `/api` guard in `server.zig:onRequest`) |
| 5 | "Custom build with `static_routes`: mappings resolve per the examples above; with `enable_spa_marker = false` a stray `.spa` file has no effect." | Task 2 matcher table tests; Task 3 routes-before-marker/real-file-wins tests; Task 4 `enable_spa_marker` default tests (routes ⇒ scan off ⇒ `spa_roots` empty); Task 7 plugins e2e |
