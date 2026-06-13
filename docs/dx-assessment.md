# ZigBase framework DX assessment

An evidence-based audit of the developer experience of **extending ZigBase as an
embeddable Zig framework** — `zig fetch --save`, `@import("zigbase")`, and
configuring `zigbase.App(.{...})`. Every claim is cited to `file:line`. This is an
audit, not marketing: it documents friction, papercuts, and gaps, then prioritizes
fixes.

Scope: the *embedding/extension* path (hooks, routes, cron, plugins, comptime
schema, migrations, static files, pool levers). The REST/admin runtime surface is
out of scope except where it intersects the embedding story.

Method: read the full extension surface (`src/framework.zig`, `src/events.zig`,
`src/data.zig`, `src/root.zig`, the storage/mailer plugin contracts, the three
examples, and all framework docs), built the framework (`zig build`, exit 0) and the
`examples/blog` consumer package (exit 0), and **empirically tested the comptime
failure modes** by editing a scratch consumer and capturing real compiler output
(reverted after each).

---

## Executive summary

ZigBase's framework surface is **unusually well-built for an early release**. The
comptime `App(cfg)` builder catches misconfiguration at build time with genuinely
good error messages, the docs are thorough, and the three-example ladder covers the
full surface. The biggest wins of the design:

- **Comptime validation actually works and the messages are good.** A typo'd config
  key, a typo'd hook phase, and a wrong-typed handler are all *compile errors* with
  *actionable* text — verified empirically (see [Footgun catalog](#footgun-catalog)).
- **The arena-vs-gpa footgun is well-guarded by docs and examples** — both hook
  examples use `ev.arena` correctly and explain why (`examples/blog/src/main.zig:16`,
  `examples/golfsim/src/main.zig:28`).
- **RAII DB accessors** (`ev.writer()` / `ev.reader()`) make connection lifetime
  explicit and leak-safe (`src/events.zig:38`–`88`).

The friction is concentrated in **the cold-start path and surface discoverability**,
not the runtime correctness:

1. **Version drift** across README / KNOWN_LIMITATIONS / CHANGELOG (FIXED here).
2. **The tutorial never shows the embedding setup** (`zig fetch` + `build.zig`); it
   jumps from curl recipes to a finished `main.zig`. The framework reference shows the
   wiring but the *learn-by-walking* doc doesn't.
3. **The `RouteEvent` dual-context** (`ev.ctx` for data, `ev.rctx` for auth) is a real
   papercut — and how to *read* a path param / set a dynamic body was undocumented in
   the framework reference (FIXED here).
4. **A documented public type (`zigbase.Migration`) surfaces an internal name
   (`provision.Migration`) in the compiler error** when you hit the bare-tuple footgun.
5. **The example `build.zig.zon` files use `.path = "../.."`**, which silently
   contradicts the `zig fetch --save git+...` story a copy-pasting integrator follows.

None of the above blocks an integrator who reads `docs/framework.md` end to end.
Together they tax the developer who learns by doing.

**What I fixed directly** (cheap, unambiguous): version strings in README +
KNOWN_LIMITATIONS; a new "Reading the request" subsection in `docs/framework.md`
documenting `ev.ctx.param` / `ev.ctx.allocator` / response-body lifetime.
**What I recommend** (needs a decision or is bigger than a doc tweak): see
[Prioritized recommendations](#prioritized-recommendations).

---

## Cold-start walkthrough (annotated)

The path a real integrator walks, with friction annotated.

### Step 1 — fetch the dependency

`README.md:48` and `docs/framework.md:46`:

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

This is correct and consistent. **Friction:** none for the README/framework reader;
but a developer who instead opens an example to copy its wiring finds
`.zigbase = .{ .path = "../.." }` in `examples/blog/build.zig.zon:7` (and the same in
`golfsim`/`plugins`). That relative path is correct *for the in-repo examples* but is
a broken pattern if copied into an external project. There is no in-file comment
saying "external consumers use the `git+` form."

### Step 2 — wire `build.zig`

`README.md:53`–`57` and `docs/framework.md:51`–`55`:

```zig
const zb = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zb.module("zigbase"));
exe_mod.link_libc = true;
```

**Friction (minor):** the docs show `exe_mod.link_libc = true` as a standalone
statement, but the real examples set it *inside* `createModule`
(`examples/blog/build.zig:11`: `.link_libc = true`). Both work, but a Zig newcomer
copying the doc snippet has no `exe_mod` in scope yet — the doc assumes you already
created the module with `.target`/`.optimize`. The reason `link_libc` is required
(bundled SQLite C + zap) is stated (`docs/framework.md:54`), which is good.

### Step 3 — `src/main.zig`

`docs/framework.md:62`–`69`. The minimal app is genuinely two lines of body. Clear.

### Step 4 — configure `App(.{...})`

The 18 config keys are tabulated at `docs/framework.md:76`–`94` and each has a
dedicated section. This is the strongest part of the cold-start story. **Friction:**
the *tutorial* (`docs/tutorial.md`) — the doc the README calls "**start here**"
(`README.md:171`) — is almost entirely a curl-against-the-stock-binary walkthrough
and only shows the finished `App(.{...})` block at the end (tutorial Step 7) without
the `zig fetch` / `build.zig` prerequisites. A reader who "starts here" to *build an
app* hits the framework wiring only by cross-navigating to `docs/framework.md`.

### Step 5 — build

`mise exec zig@0.16.0 -- zig build` at the repo root: **passes (exit 0)**.
`examples/blog` consumer build: **passes (exit 0)** — confirms the packaging story
works. (blog is `--serve-static` default mode, so it needs no `frontend/dist` at
build time; only the `plugins` embedded example needs the frontend built first.)

---

## Per-mechanism DX scorecard

Scale: **A** (ergonomic, discoverable, guarded) · **B** (good, minor papercut) ·
**C** (works, notable friction) · **D** (rough).

| Mechanism | Grade | Type you must NAME exported? | Notes |
|---|---|---|---|
| Record hooks (`.hooks`) | **A** | `zigbase.RecordEvent` ✓ (`root.zig:12`) | Best-guarded surface. Typo'd phase = compile error; arena footgun documented + exampled. |
| Custom routes (`.routes`) | **B** | `zigbase.RouteEvent`, `zigbase.http.Response` ✓ (`root.zig:14`, `:8`) | Dual-context (`ev.ctx` vs `ev.rctx`) papercut; request-reading was undocumented in the reference (fixed). |
| Cron / jobs (`.cron`/`.jobs`) | **B** | `zigbase.events.JobEvent`, `zigbase.schedule.*` ✓ (`root.zig:10`,`:11`) | `JobEvent` is *not* top-level re-exported like RecordEvent/RouteEvent — asymmetry. Reactive return type discoverable. |
| Error handler (`.onError`) | **A** | `zigbase.ErrorEvent` ✓ (`root.zig:13`) | Runs before the backstop; never propagates (`events.zig:394`). Clear. |
| Storage plugin (`.storage`) | **B** | `zigbase.Storage`, `zigbase.LocalStorage`, `zigbase.DefaultStoragePlugin` ✓ (`root.zig:21`,`:22`,`:33`) | Contract uniform with mailer; **no worked custom-storage example** (only mailer). 4-method vtable. |
| Mailer plugin (`.mailer`) | **A** | `zigbase.Mailer`, `zigbase.Email`, defaults ✓ (`root.zig:26`–`34`) | Fully worked in `examples/plugins`. Single-method vtable. |
| Comptime schema (`.collections`) | **A** | (struct literal; no named type) | Field-name = collection name; relation by name; reserved-name + bad-field compile errors (`framework.md:395`). |
| Migrations (`.migrations`) | **C** | `zigbase.Migration`, `zigbase.Db` ✓ (`root.zig:38`,`:39`) | Bare-tuple footgun surfaces internal `provision.Migration` in the error; typed-slice requirement is a sharp edge. |
| Static files (`.static_files`) | **A** | `zigbase.StaticFile` ✓ (`root.zig:43`); `embedStaticDir` from build.zig | Four modes, all exampled; clear comptime errors (`framework.zig:168`,`:180`). |
| Pool levers (`.pools`) | **A** | (struct literal) | Four optional fields, sane defaults, stack clamped-up so it can't crash (`framework.zig:148`). |

### Friction points by mechanism

**Hooks (`.hooks`).** Strong. The six phases, the `any` wildcard group, and the
ordering (wildcard then specific) are documented (`framework.md:96`–`118`) and tested
(`events.zig:340`). The arena footgun is the one real trap and it is *triple-guarded*:
prose (`framework.md:145`), the slugify example (`blog/src/main.zig:30`,`:49`), and the
recipe key-points (`recipes.md:402`). `ev.data` ops run on `app.allocator` (the gpa),
not an arena (`data.zig:9`–`12`) — so a value returned from `ev.data.findById` is
gpa-allocated and the caller is responsible for it; this lifetime asymmetry vs. the
arena-owned `ev.record` is subtle and only implied.

**Routes (`.routes`).** The handler/auth/response model is clear and the safe-default
auth (`.superuser`) is excellent (`events.zig:238`, `framework.md:200`). Two papercuts:
(1) **dual-context** — `RouteEvent` carries both `ctx: *http.RequestCtx` and
`rctx: request.RequestContext` (`events.zig:130`,`:133`); a developer must learn that
request data + the allocator live on `ev.ctx` while the resolved auth identity lives on
`ev.rctx`. (2) Until this audit, `docs/framework.md` §5 did not show how to *read* a
path param (`ev.ctx.param("id")`), where the response-body allocator comes from
(`ev.ctx.allocator`), or that `http.Response.body` must outlive the return but is
arena-freed (`http.zig:86`). The recipe covered it (`recipes.md:433`–`436`) but the
*reference* didn't — fixed by a new "Reading the request" subsection.

**Cron/jobs.** Good. The mode-dependent handler signature (void for cron/interval,
`Reactive` for reactive) is documented (`framework.md:286`–`302`). The discoverability
wart: cron is the place a developer most needs `JobEvent`, but unlike
`RecordEvent`/`RouteEvent`/`ErrorEvent` it is *not* re-exported at the top level
(`root.zig:12`–`14` lists only those three) — you must write the longer
`zigbase.events.JobEvent`. The docs are internally consistent about this, so it's a
mild asymmetry, not a breakage.

**Storage plugin.** The contract is uniform with the mailer
(`framework.md:455`–`459`) and the types are exported (`root.zig:21`,`:22`,`:33`). But
the *only* worked plugin example is the mailer (`examples/plugins`); there is **no
custom-storage example**, and the storage vtable is the harder of the two (4 methods
incl. `localPath` returning `?[]const u8` for backends that have a filesystem path —
`files/storage.zig:9`–`14`). An integrator writing an S3 backend has the contract but
no template.

**Migrations.** The sharpest edge in the surface. `.migrations` must be a *typed*
slice `&[_]zigbase.Migration{ ... }`; a bare anonymous tuple does not coerce
(`framework.md:420`). The docs warn about this, but when a developer hits it the
compiler says `expected type '[]const provision.Migration'` (verified) — surfacing the
**internal** module name `provision.Migration`, not the public `zigbase.Migration`
they typed. Mild confusion. The `up` signature
`fn(alloc, io, w: *zigbase.Db) anyerror!void` is documented and exampled
(`plugins/src/main.zig:78`).

**Static files & pools.** Both are A-grade: every mode/lever is exampled across the
ladder, comptime errors are clear, and the pool stack lever is clamped *up* to a safe
floor so it can only ever raise the stack, never EINVAL-crash `pthread_create`
(`framework.zig:148`, tested at `framework.zig:672`).

---

## Footgun catalog

Each entry: **how likely** a developer hits it, and **whether the framework guards**
against it. Compile-error behaviors below were verified by editing a scratch consumer
(`examples/blog/src/main.zig`) and capturing real `zig build` output.

| # | Footgun | How likely | Guarded? | Evidence |
|---|---|---|---|---|
| 1 | Use `ev.app.allocator` instead of `ev.arena` for record mutation | Medium | **Soft** (docs/examples, not the compiler) | `framework.md:145`; `blog:16`,`:30`,`:49`; `events.zig:106` |
| 2 | Rely on a `before*`-hook `ev.data` side-write being transactional with the main write | Medium | **Soft** (documented, not enforced) | `data.zig:14`–`18`; `framework.md:184`; `KNOWN_LIMITATIONS.md:10` |
| 3 | Typo a top-level `App` key (`.hook`) | High | **Hard** (compile error, names all valid keys) | verified ↓ |
| 4 | Typo a hook phase (`.beforeCreat`) | High | **Hard** (compile error, lists the six phases) | verified ↓ |
| 5 | Wrong-typed handler (RecordEvent fn in `.routes`) | Medium | **Hard** (compile error, expected-vs-found signature) | verified ↓ |
| 6 | `.migrations` as a bare tuple instead of typed slice | Medium | **Hard** (compile error) but leaks internal type name | verified ↓ |
| 7 | Name a field with a reserved name (`email`, `created`, …) | Medium | **Hard** (compile error, clear message) | `framework.md:395` |
| 8 | `app.submit` task outliving shutdown (detached thread) | Low | **Soft** (documented caveat) | `framework.md:339` |
| 9 | Copy `.path = "../.."` from an example into an external project | Medium | **Unguarded** | `blog/build.zig.zon:7` |

### Verified compiler output

**#3 — unknown App key** (`.hook` for `.hooks`):

```
src/framework.zig:113:26: error: unknown App cfg field 'hook'; expected one of
hooks/onError/routes/onAuth/onFileServe/onFileUpload/onBootstrap/onBeforeServe/
onBeforeTerminate/cron/jobs/storage/mailer/pools/collections/migrations/static_files
```
Excellent — names every valid key. Guard at `framework.zig:108`–`114`.

**#4 — typo'd hook phase** (`.beforeCreat`):

```
src/events.zig:294:17: error: unknown record hook 'posts.beforeCreat'; expected one
of beforeCreate/afterCreate/beforeUpdate/afterUpdate/beforeDelete/afterDelete
```
Excellent — names the offending `group.field` and the six valid phases. Guard at
`events.zig:285`–`301`.

**#5 — wrong-typed route handler** (a `*RecordEvent` fn passed as a route handler):

```
src/events.zig:221:35: error: expected type '*const fn (*events.RouteEvent)
anyerror!http.Response', found '*const fn (*events.RecordEvent) anyerror!void'
        const _h: RouteHandler = s.handler;
```
Very good — the deliberate coercion assertion (`events.zig:221`) turns a silent
mismatch into a precise expected-vs-found message.

**#6 — bare-tuple `.migrations`**:

```
src/framework.zig:195:16: error: expected type '[]const provision.Migration', found
'struct { comptime ... = .{ .id = "x", .up = undefined } }'
```
Correct rejection, but it surfaced the **internal** `provision.Migration` rather than
the public `zigbase.Migration` the developer wrote — minor confusion. **Now fixed**
(P2-b): a dedicated comptime guard fires first with a public-named message. See
[Prioritized recommendations → P2-b](#p2--papercuts).

**Net:** the comptime guard story is *real and good*. Footguns #1 and #2 (the two that
are only soft-guarded) are exactly the ones that can't easily be a compile error
(allocator identity and transaction timing are runtime properties), and both are
documented in multiple places.

---

## Error-message quality

**Compile-time:** strong (see verified output above). The pattern of asserting handler
coercion via a throwaway `const _h: RouteHandler = s.handler;` (`events.zig:221`,`:298`)
is a nice trick that converts structural mismatches into readable diagnostics. The one
blemish is internal type names leaking in the migrations error (#6).

**Runtime/startup:** good and specific. A missing static dir is a fatal startup error
that *names the path and its source* (`framework.zig:493`: "static dir '{s}' is missing
or unreadable (from {s})"). The insecure-JWT refusal is explicit
(`framework.zig:441`). The superuser-create duplicate-email path prints a helpful guess
(`framework.zig:586`). The CLI help screens are comprehensive (`framework.zig:272`–`410`).

**Hook rejection:** a `before*` hook returning an error rejects the write with `400`
and the message "Request rejected by a hook." (`recipes.md:408`) — fine, though the
specific error value is not surfaced to the client (by design).

**Gap:** there is no compile-time or startup guard that a custom storage/mailer plugin
*type* actually satisfies the `create`/`interface`/`deinit` contract beyond ordinary
Zig duck-typing — a plugin missing `deinit` fails with a generic "no member named
'deinit'" at the `serveImpl` call site (`framework.zig:469`/`:473`) rather than a
plugin-contract-specific message. Low impact (the example is a copy-paste template) but
worse than the bespoke messages elsewhere.

---

## Prioritized recommendations

Severity reflects DX impact on a real integrator. **[FIXED]** = done in this PR;
**[REC]** = recommended (needs a decision or exceeds a surgical doc tweak).

### P0 — correctness / trust

- **[FIXED] P0-a. Version drift.** `README.md:11` said `v0.2.0`,
  `KNOWN_LIMITATIONS.md:3` said `v0.1.0`, while `build.zig.zon:3` and the top
  `CHANGELOG.md` entry are `0.3.0`. Conflicting version strings erode trust on first
  read. Updated both to `v0.3.0`.

### P1 — cold-start & discoverability

- **[FIXED] P1-a. Reading the request was undocumented in the framework reference.**
  Added a "Reading the request (`ev.ctx`)" subsection to `docs/framework.md` §5
  covering `ev.ctx.param`, `ev.ctx.allocator`, the response-body lifetime, and the
  `ev.ctx` vs `ev.rctx` split, with a worked snippet and a link to the recipe.

- **[FIXED] P1-b. The tutorial omits the embedding prerequisites.** Added a "4.5 Set
  up the project (embed ZigBase)" section to `docs/tutorial.md` before the first
  framework step: the `zig fetch --save git+...` command, the full
  `createModule`/`addImport`/`link_libc` `build.zig` (matching
  `examples/blog/build.zig`), and a note that subsequent handlers live in
  `src/main.zig`.

- **[FIXED] P1-c. Example `build.zig.zon` files contradict the fetch story.** Added the
  clarifying comment `// in-repo example uses a relative path; external consumers run:
  zig fetch --save git+https://github.com/valthon/zigbase` above the `.zigbase` dep in
  all three of `examples/{blog,golfsim,plugins}/build.zig.zon`.

- **[FIXED] P1-d. Re-export `JobEvent` at the top level.** Added
  `pub const JobEvent = events.JobEvent;` to `src/root.zig` and switched the
  docs/tutorial cron examples to the shorter `zigbase.JobEvent`. The cheapest
  ergonomics win in the surface.

### P2 — papercuts

- **[FIXED] P2-a. Custom-storage example.** The merged examples PR added a real
  custom-storage plugin (`AuditStorage`, wrapping `zigbase.LocalStorage`, all four
  vtable methods) to `examples/plugins/src/main.zig`, so the gap is satisfied by a
  worked, compiling example. Additionally expanded `docs/framework.md` §9 with a
  custom-`Storage` skeleton (noting the four vtable methods) and a pointer to that
  example; no duplicate example was added.

- **[FIXED] P2-b. Migrations bare-tuple error leaks `provision.Migration`.** Added a
  comptime guard at the `provision_migrations` decl in `src/framework.zig` (helper
  `migrationsCoerce`) so a non-coercing `.migrations` value emits a `@compileError`
  naming the *public* `zigbase.Migration` type and the `&[_]zigbase.Migration{ ... }`
  fix. **Probe verified** (see below).

- **[FIXED] P2-c. Plugin-contract guard.** Added `assertPluginContract` in
  `src/framework.zig`, invoked at the `StoragePlugin`/`MailerPlugin` comptime decls: a
  plugin type missing `create`/`interface`/`deinit` now fails with a
  contract-specific `@compileError`. **Probe verified** (see below).

- **[FIXED] P2-d. Stale `Email` doc-comment.** `src/mail/mailer.zig:5` reworded from
  "v0.1 is text-only" to "text-only for now (no `html_body`)" (single comment line, to
  keep any later merge with the parallel mailer PR trivial).

### P3 — polish

- **[FIXED] P3-a.** Re-anchored the `KNOWN_LIMITATIONS.md` prose: the header now reads
  "v0.3.0 ... tracked for future releases" and the trailing line "tracked for post-v0.1"
  → "tracked for upcoming releases".
- **[FIXED] P3-b.** Documented the `ev.data` result-lifetime asymmetry in
  `docs/framework.md` §4 (the `ev.data` facade): `findById` results are gpa-allocated
  (per `data.zig`), **not** arena-scoped, so the arena rule applies only to data written
  *into* `ev.record`.

---

## What was verified

- `mise exec zig@0.16.0 -- zig build` (repo root) — **exit 0** (after the merge of
  `main` and all P1/P2 source changes).
- `mise exec zig@0.16.0 -- zig build test --summary all` — **361/361 tests pass**.
- `examples/blog` consumer build — **exit 0** (packaging/consumer story works).
- Compile-error footguns #3–#6 — **reproduced live** (initial audit), output captured
  above.
- **P2-b probe** (bare-tuple `.migrations`): emitted
  `error: '.migrations' must be a typed slice '&[_]zigbase.Migration{ ... }' (a bare
  tuple does not coerce to []const Migration); got 'struct { ... }'` at
  `framework.zig`. Probe reverted with Edit (no residual diff).
- **P2-c probe** (mailer type missing `deinit`): emitted
  `error: '.mailer' plugin type 'main.BrokenMailer' is missing the 'deinit' method; a
  plugin must declare create(gpa, io, cfg) !Self / interface(*Self) view / deinit(*Self)
  void` at `framework.zig`. Probe reverted with Edit (no residual diff).

## Changes made across this PR

Docs/version (turn 1):
- `README.md` — version `v0.2.0` → `v0.3.0`.
- `KNOWN_LIMITATIONS.md` — version → `v0.3.0`; "post-v0.1" prose re-anchored.
- `docs/framework.md` — "Reading the request (`ev.ctx`)" subsection; `ev.data`
  result-lifetime note; `zigbase.JobEvent` shorthand; custom-`Storage` skeleton + S3
  pointer; plugin-contract compile-error note.
- `docs/tutorial.md` — "4.5 Set up the project" embedding section; `zigbase.JobEvent`
  shorthand.

Source (turn 2):
- `src/root.zig` — `pub const JobEvent` re-export.
- `src/framework.zig` — `migrationsCoerce` + `.migrations` comptime guard (P2-b);
  `assertPluginContract` + storage/mailer contract guards (P2-c).
- `src/mail/mailer.zig` — `Email` doc-comment reword (P2-d).
- `examples/{blog,golfsim,plugins}/build.zig.zon` — relative-path clarifying comment.
