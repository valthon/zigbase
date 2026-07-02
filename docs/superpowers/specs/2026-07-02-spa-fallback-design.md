# Design spec — SPA fallback routing: `.spa` marker (default) + comptime `static_routes` (custom builds)

Issue: valthon/zigbase#183 (authoritative requirements). Baseline: `main` @ `e71eac5` (v0.9.0).

Locked decisions from the issue owner:
1. The `.spa` file is **presence-only** — no contents, no custom fallback filename.
2. The marker filename is **`.spa`**.
3. The comptime matcher is **minimal segment matching** — `:name` = one segment, `*`/`**` rest-matchers, **first match wins**.

## Goal

Host client-routed apps (History-API SPAs) on a ZigBase origin without 404s on deep
links / hard refreshes:

- **Tier 1 (shipped binary, zero config):** a directory in the static tree containing a
  file named `.spa` becomes an SPA root — any GET/HEAD *miss* at or below that
  directory serves that directory's `index.html` with status 200. Real files and all
  API-handled paths always win.
- **Tier 2 (custom build, comptime):** an `App(.{ .static_routes = &.{...} })` key
  declares explicit `match → serve` mappings, validated at compile time (or startup for
  filesystem sources), resolved with no runtime rule engine.

## Non-goals

- No runtime rewrite-rule DSL, no config-file/CLI/env knob for the shipped binary
  (the marker is the entire runtime surface).
- No parsing of `.spa` contents (presence-only; an alternate fallback document is a
  Tier-2 comptime route).
- No hot-reload of markers — the scan is startup-only (see Tier 1).
- No `:name` capture forwarding into the served document, no regex, no query-string
  matching, no method-conditional rewrites.
- No change to admin (`/_/`) serving, file-storage serving (`/api/files/...`), or the
  realtime WebSocket upgrade.

## Where this lands in the existing code

Static serving today (all confirmed on `main`):

- `src/static_files.zig` — `serve(io, ctx, source)` handles both sources:
  `.dir` (filesystem root, streamed via `Response.file_path` → facil.io `sendFile`, which
  owns ETag/Last-Modified/Cache-Control/304) and `.embedded` (build-generated manifest,
  CRC32 ETag + zigbase's own `If-None-Match`/304 handling). `sanitize()` normalizes the
  request path and rejects `..`/backslash/NUL; `serveDir` additionally canonicalizes via
  `realPathFileAlloc` + `withinRoot` so in-root symlinks cannot escape (F10).
  A miss returns `null`.
- `src/server.zig:onRequest` — resolution order: multipart error → admin (`/_/` prefix,
  `src/admin.zig`, which already does internal SPA fallback for the admin UI) → built-in
  API routes (`router.tryDispatch`) → features public route → custom routes
  (`dispatchCustom`) → static branch (only GET/HEAD, only when `static_source != .none`,
  and **never** for `/api` or `/api/*`) → JSON `ApiError.notFound()`. A static miss
  today returns a **plain-text 404** inside the static branch.
- `src/framework.zig` — `static_mode` comptime key (`.default`/`.disabled`/`.dir`/
  `.embedded`) lowered from `cfg.static_files` with `@compileError` on bad shapes;
  `serveImpl` resolves `static_source`, probes a configured dir at startup (missing dir
  = fatal `error.StaticDirUnavailable`), and stores the source on `app_mod.App`.
- `build.zig:embedStaticDir` — walks a dist dir (dotfiles **included**) into a generated
  `static_assets.zig` manifest (`path`/`bytes`/`etag` with CRC32).

Both tiers slot into `static_files.serve` as a *miss handler*: nothing upstream of the
static branch changes.

## Tier 1 — the `.spa` marker (runtime)

### Marker discovery (startup-only)

- **When:** in `framework.serveImpl`, immediately after `static_source` is resolved and
  the existing dir probe passes — i.e. once per process, before the listener starts.
- **`.dir` source (incl. `--serve-static`):** recursively walk the static root
  (`std.Io.Dir.walk`, same mechanism `embedStaticDir` uses at build time) collecting
  every file named exactly `.spa`. Each marker's containing directory, as a
  root-relative `/`-separated prefix (`""` for the root itself), is an **SPA root**.
- **`.embedded` source:** derive the same set from the manifest — every entry whose
  `path` is `.spa` or ends in `/.spa`. No filesystem I/O. (This is deliberate: the
  marker "travels with the build output", so a bundler that writes `dist/.spa` works
  identically whether the dist is embedded or served from disk.)
- **Missing `index.html`:** a marked directory whose `index.html` does not exist (statFile
  for `.dir`; manifest lookup for `.embedded`) gets a **startup warning**
  (`std.log.warn("SPA marker at '{s}/' has no index.html; marker ignored", ...)`) and is
  **dropped from the set — treated as unmarked**. Rationale: it degrades to exactly
  today's behavior (real files serve, misses 404 *or fall through to an enclosing
  marker*), fails obviously at deploy time, and introduces no new request-time failure
  mode. (If `index.html` is deleted *after* startup, the fallback serve misses at
  request time and the existing `sendFile` catch yields a 404 — acceptable; the scan is
  startup-only.)
- The result is stored on `app_mod.App` as `spa_roots: []const []const u8`, **sorted
  longest-first** (allocated once from the app allocator; empty slice when the feature
  is off or no markers exist — zero per-request cost on the happy path).
- **No re-scan.** Adding/removing a `.spa` marker requires a server restart. This is
  documented, matches the issue's "scan once at startup" requirement and the
  "cheap, predictable" ethos, and mirrors how the static dir itself is only probed at
  startup.

### Request resolution order (normative)

Unchanged outer order, with the static branch extended. For a request:

1. Admin: `/_/` and `/_` → `admin.serve` (own internal fallback, untouched).
2. Built-in API routes (`/api/...` table) — includes the realtime HTTP endpoints; the
   WS upgrade itself happens in the listener's `on_upgrade` before `onRequest` runs.
3. Features public route, then consumer custom routes (`dispatchCustom`).
4. Static branch — entered only for GET/HEAD, `static_source != .none`, and path not
   `/api` / `/api/*`:
   1. `sanitize(path)` → `rel` (unsafe path ⇒ miss).
   2. **Refuse the marker file:** if the final segment of `rel` is exactly `.spa`,
      skip file lookup (see Security). Other dotfiles are unaffected — `.well-known/`
      must keep serving.
   3. **Real file wins:** existing `serveEmbedded`/`serveDir` lookup (incl. directory
      → `index.html` resolution). Hit ⇒ serve it.
   4. **Tier 2:** first matching `static_routes` entry (custom builds only) ⇒ serve its
      target through the same source (details below).
   5. **Tier 1:** if the marker feature is enabled, find the **longest** `spa_root` in
      `spa_roots` that is a `/`-bounded prefix of `rel` (the root marker `""` matches
      everything). Hit ⇒ serve `<root>/index.html` through the same
      `serveDir`/`serveEmbedded` path with status **200**.
   6. Plain-text 404 (unchanged).
5. JSON `ApiError.notFound()` for everything that never entered the static branch
   (unchanged).

**Nested markers: longest prefix wins.** With `public/.spa` and `public/app/.spa`, a
miss at `/app/orders/1` serves `app/index.html`; a miss at `/pricing` serves the root
`index.html`. If `public/app/.spa` was dropped for a missing `index.html`, `/app/orders/1`
falls through to the root marker — the graceful-degradation consequence of
"treat as unmarked".

**Every miss under a root gets the shell — including extension-bearing paths** (a
missing `/app/assets/old.js` serves the HTML shell with 200). Some hosts special-case
"looks like a file" paths; we deliberately don't — one fixed, predictable behavior, per
the issue's presence-only philosophy. Bundlers emit hashed assets, so stale-asset
requests are rare and a 200-HTML answer is what every `try_files $uri /index.html`
deployment already produces.

### Fallback response semantics

The fallback is served **through the existing serve functions** with a rewritten `rel`
(`<spa_root>/index.html`), so it inherits everything for free:

- **Status 200**, `Content-Type: text/html` (`mime.fromExtension`), `X-Content-Type-Options: nosniff`.
- **Conditional requests:** `.embedded` — CRC32 ETag + `If-None-Match` ⇒ 304 exactly as
  any embedded asset; `.dir` — facil.io `sendFile` owns ETag/Last-Modified/
  `Cache-Control: max-age=3600`/304, exactly as any dir-mode file. No new caching code.
- **HEAD:** identical response; the transport strips the body (existing contract in
  `static_files.serve`).
- **Traversal safety:** the fallback path is built from a startup-scanned root plus the
  literal `index.html` — no request bytes flow into it beyond *selecting* a root via a
  `/`-bounded prefix match on the already-sanitized `rel`. Dir mode additionally runs
  the F10 `realPathFileAlloc` + `withinRoot` check on the resolved `index.html` (a
  symlinked shell escaping the static root is refused). The fallback cannot escape the
  marked subtree by construction.

### API sketch

```zig
// static_files.zig
pub const StaticRoute = struct { match: []const u8, serve: []const u8 };
pub const Fallback = struct {
    routes: []const StaticRoute = &.{},     // Tier 2, comptime-lowered
    spa_roots: []const []const u8 = &.{},   // Tier 1, startup scan (longest-first)
};
pub fn serve(io: std.Io, ctx: *http.RequestCtx, source: Source, fb: Fallback) !?http.Response;
```

`server.zig` passes `.{ .routes = App.static_routes, .spa_roots = self.app.spa_roots }`.
The scan helper (`scanSpaRoots(io, alloc, source) ![]const []const u8`, with the
index.html check + warning) lives in `static_files.zig` so it is unit-testable.

## Tier 2 — comptime `static_routes` (custom builds)

### Config shape and comptime lowering

Two new `App(.{...})` keys, added to the `allowed` list in `framework.zig` (so a typo
stays a `@compileError`, matching every other key):

```zig
zigbase.App(.{
    .static_files = .{ .embedded = &@import("static_assets").files },
    .static_routes = &.{
        .{ .match = "/app/orders/:id", .serve = "/app/orders/_shell.html" },
        .{ .match = "/admin/*",        .serve = "/admin/index.html" },
        .{ .match = "/app/a/b/c",      .serve = "/app/c" },
        .{ .match = "/app/**",         .serve = "/app/index.html" },
    },
    .enable_spa_marker = false, // optional; see default story
})
```

Lowered like `static_mode`: a `pub const static_routes: []const static_files.StaticRoute`
decl on the App type (empty when the field is absent). Accepts a slice or tuple of
anonymous structs; each entry must have **exactly** the fields `match` and `serve`
(string literals). Mirroring the `.migrations` guard, a bare tuple is coerced;
anything else is a loud `@compileError`.

### Matcher semantics (normative)

Matching runs against the **normalized** request path: `"/" ++ sanitize(path)` — so
`//app//x`, `/app/./x`, and `/app/x/` all normalize before matching, and a trailing
slash never changes the outcome (`/app/` ≡ `/app`). Patterns are split on `/` and
compared segment-wise:

- **Literal segment** — exact byte match.
- **`:name`** — matches exactly **one** non-empty segment (never `/`, never zero
  segments). The capture is discarded (`serve` is a fixed path).
- **`*`** — terminal only; matches **one or more** remaining segments (the rest of the
  path, but the bare prefix itself does *not* match).
- **`**`** — terminal only; matches **zero or more** remaining segments (the bare
  prefix *does* match).

Both `*` and `**` "match the rest" per the issue; the pinned distinction is solely
whether the bare prefix matches. **First match wins, in declaration order** — no
specificity ranking; the consumer orders exact → shell → catch-all themselves.

Examples (given the config above):

| Request | Matches | Serves |
|---|---|---|
| `/app/orders/42` | `/app/orders/:id` | `/app/orders/_shell.html` |
| `/app/orders/42/edit` | `/app/**` (`:id` is one segment only) | `/app/index.html` |
| `/admin/x/y` | `/admin/*` | `/admin/index.html` |
| `/admin` | *(no route: `*` needs ≥1 segment)* | falls through (marker/404) |
| `/app` and `/app/` | `/app/**` | `/app/index.html` |
| `/app/a/b/c` | `/app/a/b/c` (declared first) | `/app/c` |

`@compileError` cases (validated while lowering): entry without exactly
`match` + `serve`; either not starting with `/`; empty pattern segment other than the
leading one (i.e. `//` inside a pattern); `*`/`**` in a non-final segment; a wildcard or
`:` mixed with literal text inside one segment (`/f*.html`, `/x:y`); `:` with an empty
name; `serve` containing `:`/`*`/`..`; `.static_routes` non-empty while
`.static_files = .disabled`.

### Serve-target existence

- **`.embedded` mode** — checked at **comptime**: each `serve` target must resolve in
  the manifest (exact path, or `path ++ "/index.html"`, or `index.html` for `/`);
  otherwise `@compileError("static_routes: serve target '<p>' not in the embedded manifest")`.
  This is the issue's "validated at build time" payoff.
- **`.dir` / `.default` mode** — checked at **startup** (comptime can't see the
  filesystem): after the static-dir probe, `statFile` each target; a missing target is a
  **fatal startup error**, matching the existing missing-static-dir precedent
  (`error.StaticDirUnavailable`). In `.default` mode, a build that declares
  `static_routes` but starts without `--serve-static` (source `.none`) is also a fatal
  startup error — routes that can serve nothing are a misconfiguration, not a no-op.

### Resolution and applicability

`static_routes` applies to **whichever static source is active** (embedded or dir) —
the route only rewrites the *relative path* handed to the existing serve functions, so
ETag/304/HEAD/nosniff/F10 behavior is inherited per source exactly as in Tier 1.
Routes are consulted **only on a real-file miss** (real files always win, uniform with
Tier 1 — a rewrite that must shadow an existing file is out of scope) and **before** the
marker fallback (explicit config beats convention). Status is 200; Content-Type comes
from the *served* target's extension.

### `enable_spa_marker` default story

`enable_spa_marker: bool`, comptime-lowered; `@compileError` on a non-bool value.

**Default: `true` when `static_routes` is absent/empty; `false` when `static_routes` is
non-empty. An explicit value always wins.** Rationale: a plain custom build (no routes)
stays byte-identical to the shipped binary, while a build that compiled explicit routes
doesn't get a stray dotfile silently adding behavior — exactly the issue's "off by
default in custom builds [with routes]" without making zero-config custom builds
diverge. When explicitly `true` alongside routes, routes match first and the marker is
the residual fallback. When `false`, the scan never runs (`spa_roots` stays empty) and a
`.spa` file is just another never-served dotfile.

## Security

- **API-handled paths are never rewritten.** The fallback lives inside the static
  branch, which is reachable only after admin (`/_/*`), built-in routes, the features
  route, and custom routes have declined — and is hard-gated against `/api` and
  `/api/*` (JSON 404 envelope preserved). The `/api/realtime` WebSocket upgrade is
  handled by the listener's `on_upgrade` before `onRequest` executes, so it is
  structurally unreachable by either tier. Non-GET/HEAD methods never enter the branch.
- **Traversal:** inherited defenses unchanged (`sanitize` rejects `..`/`\`/NUL on the
  percent-decoded path; dir mode canonicalizes and enforces `withinRoot`). New
  invariants: (a) the fallback path is `<scanned-root>/index.html` — request input only
  *selects* among startup-scanned roots via `/`-bounded prefix match, so the fallback
  can never name a path outside the marked subtree; (b) Tier-2 `serve` targets are
  comptime/startup-validated literals with `..` and wildcards rejected.
- **The `.spa` file is never servable.** Any request whose sanitized final segment is
  `.spa` skips file lookup in both sources (embedded manifests do embed dotfiles today,
  and dir mode would happily stream one). It then falls through the normal miss chain —
  typically serving the shell. Scope is deliberately the literal `.spa` name only:
  other dotfiles keep serving (`.well-known/` ACME/security.txt deployments must not
  break).
- **Trust model:** the marker is filesystem-scoped by definition — whoever can write the
  static root already controls every byte served from it, so controlling *fallback*
  behavior adds no privilege. ZigBase itself never writes into the static dir (record
  file uploads land under the data dir via the storage backend), and no API or config
  string can plant a marker; there is no path from request data to the prefix set.
- **Resource cost:** one recursive walk at startup (same order of work `embedStaticDir`
  does at build time); per-request cost on a miss is an O(#roots) prefix scan over a
  usually-empty or 1-element list, plus O(#routes) segment matching in custom builds.
  No per-request filesystem stat is added on the hit path.

## Config & compat

- **Shipped binary (`App(.{})`):** `static_routes` empty ⇒ marker **on**, always. No new
  CLI flags or env vars. With no `.spa` present, behavior is byte-identical to v0.9.0.
- **Custom builds:** two new comptime keys (`static_routes`, `enable_spa_marker`);
  absent ⇒ identical to today. `.static_files = .disabled` still disables everything
  (and rejects `static_routes` at comptime).
- **Behavior deltas to call out:** (1) a file literally named `.spa` in a served tree
  now returns the fallback/404 instead of its bytes — consumer-visible, goes in the
  changelog; (2) with a marker present, static misses under it change from plain-text
  404 to 200 HTML — that is the feature.
- **New runtime state:** `app_mod.App.spa_roots` (startup-allocated, freed on shutdown);
  `App.static_routes` is a comptime constant — zero runtime storage.

## Acceptance criteria (verbatim) → design mapping

1. *"Shipped binary, `public/app/.spa` present: hard GET `/app/orders/1234` →
   `public/app/index.html` (200); `/app/assets/app.js` and other real files serve
   directly; `/` and other paths outside `/app/` are unaffected."* → startup scan +
   step 4.v longest-prefix fallback; step 4.iii real-file precedence; `/`-bounded prefix
   restricts scope to the marked subtree.
2. *"`public/.spa` present: any miss under `/` → `/index.html` (200); real files still
   win."* → root marker is the `""` prefix, matching every sanitized path; same
   precedence.
3. *"No marker, no comptime routes: behavior is exactly as today (misses 404)."* →
   empty `spa_roots` + empty `static_routes` short-circuit; steps 4.iv/4.v are no-ops;
   plain-text 404 unchanged. (Sole exception: a file named exactly `.spa`, see deltas.)
4. *"The marker never rewrites a request that an API route handles."* → fallback is
   inside the static branch, downstream of all route dispatch and the `/api` guard;
   WS upgrade precedes `onRequest` entirely.
5. *"Custom build with `static_routes`: mappings resolve per the examples above; with
   `enable_spa_marker = false` a stray `.spa` file has no effect."* → Tier-2 matcher +
   first-match-wins; `enable_spa_marker=false` (the default with routes) skips the scan,
   so `spa_roots` is empty.

## Test plan

### Zig unit tests

`src/static_files.zig` (new files here are already wired via `root.zig`; this file is):

- `"spa scan: dir mode finds markers, drops roots missing index.html with a warning"` —
  tmpDir with `.spa` at root and `app/.spa` (one without `index.html`); assert the
  prefix set + longest-first order. (AC1/AC2 discovery; missing-index decision.)
- `"spa scan: embedded manifest markers derive roots"` — fixture with `.spa` entries.
- `"spa fallback: miss under marked root serves its index.html with 200/text/html"` —
  dir + embedded variants; assert ETag present in embedded, `file_path` in dir. (AC1)
- `"spa fallback: root marker catches every miss; real files still win"` (AC2)
- `"spa fallback: nested markers — longest prefix wins; dropped inner root falls through to outer"`
- `"spa fallback: no marker/no routes ⇒ serve returns null (miss 404s)"` (AC3)
- `"spa fallback: '.spa' itself is never served (dir + embedded)"`
- `"spa fallback: prefix is '/'-bounded (marker at app/ does not claim /application)"`
- `"spa fallback: If-None-Match on the embedded fallback yields 304; HEAD mirrors GET"`
- `"static_routes: ':name' one segment, '*' one-or-more, '**' zero-or-more, first match wins"` —
  the examples table above as assertions, incl. trailing-slash normalization and
  `/admin` not matching `/admin/*`.
- `"static_routes: match only on miss (real file wins); routes checked before marker"`

`src/framework.zig` (mirroring the existing `"App(cfg) static_files modes"` test):

- `"App(cfg) static_routes lowering: absent ⇒ empty; entries coerced; order preserved"`
- `"App(cfg) enable_spa_marker default: true without routes, false with routes, explicit wins"`
- (Comptime-rejection cases — bad pattern, missing embedded target, routes with
  `.disabled` — are `@compileError`s and can't be unit-tested; they follow the
  documented pattern of the session_store/experiments guards. Verify manually once.)

`src/server.zig` (existing listener-based test harness):

- `"root spa marker does not swallow /api: unknown /api path keeps the JSON 404 envelope"` (AC4)

### Python browser suite

Extend `tests/admin/test_static_files.py` (the established pattern: temp static dir +
`--serve-static` + urllib):

- `test_spa_marker_fallback` — `.spa` in `app/`; deep GET `/app/orders/1234` ⇒ 200,
  `text/html`, shell body; `/app/assets/app.js` ⇒ direct; `/nope` outside ⇒ 404;
  `/app/.spa` ⇒ not the marker bytes; `/api/definitely-missing` ⇒ 404 JSON. (AC1, AC4 e2e)
- `test_spa_marker_root` — root `.spa`; miss ⇒ 200 shell; real file wins. (AC2)
- The existing tests double as the AC3 regression (no marker ⇒ unchanged).
- Also run `tests/admin/` broadly before merge per repo policy (admin `/_/` must be
  unaffected).

### Examples

`examples/plugins` (the advanced rung of the ladder, built in CI) is **in scope,
minimally**: add one `static_routes` catch-all for its embedded Astro frontend plus a
deep-link fetch assertion in its vitest e2e (`test/typegen.e2e.test.ts` harness). This
gives CI coverage of the comptime lowering + embedded-target validation for free.
`blog` and `golfsim` stay untouched (a `.spa` file in their frontends is a follow-up if
their frontends ever gain client routing — keep blog simplest).

## Docs & release checklist

- `docs/framework.md` §13 (static files): document the `.spa` marker (behavior, scope,
  startup-only scan/restart note, missing-index warning, `.spa` never served), the
  `static_routes` key + matcher table, `enable_spa_marker` defaults. **Mirror to
  `site/src/content/docs/framework.md`.**
- `site/src/content/docs/configuration.md`: one paragraph under `--serve-static`
  describing the marker (this page has no `docs/` counterpart — site-only).
- `docs/api.md` static-files subsection (miss behavior changes under a marker) +
  `site/src/content/docs/api.md` mirror.
- `README.md`: extend the existing "Static files" bullet with "…with `.spa` SPA-fallback
  markers" — no new bullet (it's a sub-feature of static serving).
- Changelog fragment `changelog.d/spa-fallback.md`: `### Features` (both tiers) and
  `### Changed` (a file literally named `.spa` is no longer servable). Never touch
  `CHANGELOG.md` directly.
- `cd site && npm run build` to verify the mirror.
- PR template sync checklist; examples/plugins e2e + `tests/admin/` browser suite run
  locally before merge.

## Flagged for the owner

- The issue's example labels `/admin/*` a "catch-all"; under the pinned semantics
  (`*` = one-or-more rest segments, `**` = zero-or-more) it catches everything *below*
  `/admin` but not `/admin` itself — use `/admin/**` for a true catch-all. The two
  spellings are otherwise both rest-matchers per the issue's prose; the bare-prefix
  distinction is the only daylight between them.
- Deliberate refinement: the marker works for **embedded** static sources too (derived
  from the manifest), not just the filesystem dir — "the marker travels with the build
  output" would otherwise silently stop applying the moment a consumer switches to
  `embedStaticDir`.

## Owner revision (2026-07-02): dir-mode failure matrix + live marker resolution

Final whole-branch review surfaced a startup fault-tolerance gap in the original Tier 1
implementation: `scanSpaRoots`'s dir-mode walk used `while (try walker.next(io))`, and
`std.Io.Dir.Walker.next` propagates `enter`/`openDir` errors (`AccessDenied`,
`FileNotFound`, `SymLinkLoop`, ...) from *any* subtree, not just the ones near a marker.
Since the marker scan is on by default, a `--serve-static` tree with an unreadable
subdirectory anywhere (a root-owned `0700` dir, `lost+found`, a dir deleted mid-walk)
refused to boot at all — a regression versus pre-#183 behavior, where such subtrees just
404'd at request time. Fixing that surfaced a bigger question — what SHOULD dir-mode
startup behavior be, and should the marker set even be cached — which produced two
design changes superseding §"Marker discovery (startup-only)" and the "No hot-reload of
markers" non-goal above, **for dir mode only** (embedded mode is unchanged: still
derived once at startup from the comptime-static manifest, still cached, still no live
filesystem to go stale).

**1. Dir-mode failure matrix (replaces the single "scan, warn-and-drop-on-missing-index"
rule):**

| Condition | Outcome |
|---|---|
| Root static dir inaccessible | **Fatal** at startup (unchanged — the existing `openDir` probe in `serveImpl`). |
| A discovered `.spa` directory has no `index.html` | **Fatal** at startup (**changed** — was warn + drop; a marker with nothing to serve as the shell is now treated as a build/deploy mistake, not a degrade-to-unmarked). |
| A `static_routes` dir-mode `serve` target is inaccessible | **Fatal** at startup (unchanged — `validateRouteTargetsDir`). |
| An unreadable subdirectory/file (permissions, transient) during the startup walk | **Not fatal** — skipped, with a `std.log.warn` naming the path; treated as if it doesn't exist, matching how dir-mode serving already 404s cleanly on an unreadable file rather than erroring. |
| Anything filesystem-related after boot | **Never fatal** — see live resolution below; a post-boot permission change, deletion, or vanished `index.html` degrades to "no marker here" (404 at worst), never a 500 or a crash. |

**2. Dir-mode marker resolution goes LIVE, not cached.** The startup walk's job is
reduced to *validation only* (the fatal/non-fatal cases above) — it no longer builds a
`spa_roots` list for dir mode. Instead, `static_files.resolveSpaMarkerDirLive` runs on
every dir-mode MISS: it walks the missed path's ancestor directories from deepest to the
static root (inclusive), stat'ing each for a `.spa` file then, if found, that
directory's `index.html`; the **deepest** matching ancestor wins (preserving the
existing longest-`/`-bounded-prefix semantics), and a marked-but-indexless directory is
"absent" (does not fall through to an enclosing marker — mirrors the startup-validation
rule). This means a `.spa` (or its `index.html`) added, removed, or edited after boot
takes effect on the **very next request**, with no restart, no watcher, and no cache to
invalidate — only misses pay the extra ancestor-stat cost, and a hit under a real file
never reaches this path at all. `App.spa_roots` (the startup-derived, sorted,
longest-first prefix list) now applies to **embedded sources only**; dir-mode threading
uses a new `App.spa_marker_enabled: bool` instead, gating the live resolver the same way
`enable_spa_marker` always gated the old cached lookup.

**Why live instead of just "fatal + keep the cache":** the owner's stated preference was
that the server should never need a restart for markers/index.html to take effect in dir
mode (the natural expectation for a `--serve-static <dir>` deployment, where the served
tree is routinely redeployed independently of the binary), while startup should still
fail loudly for the one class of mistake (`.spa` with no shell) that can't be a per-miss
runtime concern. Embedded manifests get neither problem — they're comptime-baked, so the
old cached-scan design is unchanged there.

Superseded by this revision: the "No hot-reload of markers" bullet under Non-goals
(dir mode now hot-reloads by construction — there is no cache to invalidate) and the
"scanned once at startup" framing throughout Tier 1 (still true for **embedded**;
false for **dir**, which is now request-time). `docs/framework.md` and its site mirror,
`docs/api.md` and its site mirror, and `site/src/content/docs/configuration.md` were
updated to describe the failure matrix and live resolution instead of a single
startup-only scan.
