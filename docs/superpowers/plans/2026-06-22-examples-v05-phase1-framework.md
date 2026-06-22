# Examples v0.5+ — Phase 1: Framework Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the three framework enablers the example apps need — comptime `.indexes` lowering (E1) and a `public_url`→clickable magic-link email (E2) — plus the D2 documentation fix, as one independently shippable PR that unblocks the per-example PRs.

**Architecture:** E1 adds a comptime `buildIndexes` lowering to `provision.buildCollection` so a collection literal's `.indexes` tuple flows into `schema.Collection.indexes` (already provisioned by `collections.create` → `ddl.createIndexSql`). E2 adds a `public_url` config field that `magic_link.initiate` uses to email a clickable link to the existing GET consume endpoint instead of a raw token. D2 corrects the false "provisioned columns are id-named" claim (columns are human-named; `field.id` is only an internal rebuild-matching key).

**Tech Stack:** Zig 0.16.0 (pinned via mise), embedded SQLite, zap. No new dependencies.

## Global Constraints

- Zig is pinned: run every Zig command as `mise exec zig@0.16.0 -- zig …`.
- Authoritative unit-test signal is the `Build Summary: N/N tests passed` line — use `mise exec zig@0.16.0 -- zig build test --summary all`. Ignore the spurious trailing `failed command: …` line.
- A new `src/*.zig` file's tests do not run until added to `src/root.zig`'s `test { _ = @import(...) }` block. (This plan adds tests only to existing files — no root.zig change needed.)
- NEVER edit `CHANGELOG.md` or its site mirror directly — add a `changelog.d/<slug>.md` fragment with `### <Section>` headings (recognized: Breaking, Features, Fixes, Changed, Performance, Deprecated, Removed, Security, Internal).
- Any `docs/*.md` change must be mirrored into `site/src/content/docs/…`; build the site with `cd site && npm run build` when docs change.
- `main` is protected: land via PR + green CI; merge with `gh pr merge --merge` (no squash, no auto-merge). `gh pr edit` is broken here — use `gh api -X PATCH`.
- Work happens on branch `worktree-examples-v05-features` (already checked out in this worktree).

---

### Task 1: E1 — comptime `.indexes` lowering in `buildCollection`

**Files:**
- Modify: `src/provision.zig` (add `buildIndexes` helper near `strTupleToSlice` at line 323; add an `.indexes` branch in `buildCollection` after the `.auth` block at line 138; add a unit test in the test section)
- Modify: `docs/framework.md:835-841` and `site/src/content/docs/framework.md` (align the documented index-literal shape to the tuple form this lowering accepts)

**Interfaces:**
- Consumes: `schema.Index` (`{ name: []const u8, fields: []const []const u8, unique: bool = false, collation: schema.Collation = .binary, where: ?[]const u8 = null }`), `schema.Collation` (`.binary`/`.nocase`), `schema.isValidIdentifier(s: []const u8) bool`, existing `strTupleToSlice(comptime t) []const []const u8`.
- Produces: `buildIndexes(comptime col_name: []const u8, comptime t: anytype) []const schema.Index`; `buildCollection` now sets `col.indexes` when the literal has `.indexes`. Collection literals may carry `.indexes = .{ .{ .name=…, .fields=.{…}, .unique=…, .collation=…, .where=… }, … }`.

- [ ] **Step 1: Write the failing test** (append to the test section of `src/provision.zig`)

```zig
test "buildCollection lowers .indexes with collation and partial predicate" {
    const cols = comptime buildCollections(.{
        .users = .{
            .type = .auth,
            .fields = .{.{ .name = "name", .type = .text }},
            .indexes = .{
                .{ .name = "idx_users_email", .fields = .{"email"}, .unique = true, .collation = .nocase },
                .{ .name = "idx_named", .fields = .{"name"}, .where = "name != ''" },
            },
        },
    });
    const u = cols[0];
    try std.testing.expectEqual(@as(usize, 2), u.indexes.len);
    try std.testing.expectEqualStrings("idx_users_email", u.indexes[0].name);
    try std.testing.expect(u.indexes[0].unique);
    try std.testing.expectEqual(schema.Collation.nocase, u.indexes[0].collation);
    try std.testing.expectEqualStrings("email", u.indexes[0].fields[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), u.indexes[0].where);
    try std.testing.expect(!u.indexes[1].unique);
    try std.testing.expectEqual(schema.Collation.binary, u.indexes[1].collation);
    try std.testing.expectEqualStrings("name != ''", u.indexes[1].where.?);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — the `.indexes` key is currently ignored, so `u.indexes.len` is `0`, not `2` (assertion failure on the first `expectEqual`).

- [ ] **Step 3: Add the `buildIndexes` helper** (insert in `src/provision.zig` immediately after `strTupleToSlice`, which ends at ~line 337)

```zig
fn buildIndexes(comptime col_name: []const u8, comptime t: anytype) []const schema.Index {
    comptime {
        const T = @TypeOf(t);
        const info = @typeInfo(T);
        if (info != .@"struct")
            @compileError("collection '" ++ col_name ++ "' .indexes must be a tuple of index literals");
        const tf = info.@"struct".fields;
        var out: [tf.len]schema.Index = undefined;
        for (tf, 0..) |tff, i| {
            const idx = @field(t, tff.name);
            const I = @TypeOf(idx);
            if (!@hasField(I, "name"))
                @compileError("an index in collection '" ++ col_name ++ "' is missing .name");
            if (!@hasField(I, "fields"))
                @compileError("an index in collection '" ++ col_name ++ "' is missing .fields");
            const iname: []const u8 = idx.name;
            if (!schema.isValidIdentifier(iname))
                @compileError("index name '" ++ iname ++ "' in collection '" ++ col_name ++ "' is not a valid identifier");
            const fields = strTupleToSlice(idx.fields);
            for (fields) |fname| {
                if (!schema.isValidIdentifier(fname))
                    @compileError("index '" ++ iname ++ "' in collection '" ++ col_name ++ "' references an invalid field identifier '" ++ fname ++ "'");
            }
            var oi = schema.Index{ .name = iname, .fields = fields };
            if (@hasField(I, "unique")) oi.unique = idx.unique;
            if (@hasField(I, "collation")) oi.collation = idx.collation;
            if (@hasField(I, "where")) oi.where = idx.where;
            out[i] = oi;
        }
        const frozen = out;
        return &frozen;
    }
}
```

- [ ] **Step 4: Wire it into `buildCollection`** (in `src/provision.zig`, immediately before `return col;` at line 139, after the `if (@hasField(S, "auth")) { … }` block)

```zig
        if (@hasField(S, "indexes")) col.indexes = buildIndexes(name, spec.indexes);
        return col;
```

(Replace the existing bare `return col;` with the two lines above.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed` (N increased by one); the new test passes.

- [ ] **Step 6: Align the documented index-literal shape** (the doc currently shows slice syntax `&.{…}`; this lowering uses tuple syntax `.{…}` to match the rest of the comptime API)

In `docs/framework.md` replace lines 835-842 (the `.indexes = &.{ … }` example) with:

```markdown
.indexes = .{
    // unique, case-sensitive (default collation)
    .{ .name = "idx_users_handle", .fields = .{"handle"}, .unique = true },
    // case-insensitive: emits ("email" COLLATE NOCASE)
    .{ .name = "idx_users_email",  .fields = .{"email"}, .unique = true, .collation = .nocase },
    // partial / conditional-unique: emits ... WHERE deleted_at IS NULL
    .{ .name = "idx_active_slug",  .fields = .{"slug"}, .unique = true, .where = "deleted_at IS NULL" },
},
```

Apply the identical replacement to `site/src/content/docs/framework.md` (same lines). Add one sentence after the block in both files: "Index `.fields` reference fields by their declared name (not an internal id); `.name` and each field are validated as identifiers at compile time."

- [ ] **Step 7: Build the site to confirm the docs mirror compiles**

Run: `cd site && npm run build`
Expected: build succeeds (no MDX/asciidoc errors).

- [ ] **Step 8: Commit**

```bash
git add src/provision.zig docs/framework.md site/src/content/docs/framework.md
git commit -m "feat(provision): lower comptime .indexes on collection literals

buildCollection now reads an .indexes tuple and lowers it into
schema.Collection.indexes (collation + partial where), which
collections.create already provisions via ddl.createIndexSql. The
.indexes key was documented but silently ignored before.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: E2 — `public_url` config + clickable magic-link email

**Files:**
- Modify: `src/config.zig` (add `public_url` field near line 13; parse `ZIGBASE_PUBLIC_URL` in `load()` near line 102)
- Modify: `src/app.zig` (add `public_url: []const u8 = ""` field near line 29)
- Modify: `src/framework.zig` (copy `.public_url = cfg.public_url` in the App init near lines 797-801)
- Modify: `src/auth/methods/magic_link.zig` (add a pure `buildMailBody` helper; call it from `initiateImpl`; add tests)

**Interfaces:**
- Consumes: `AuthCtx.app` (`*App`), `AuthCtx.collection.options.auth.methods.magic_link` (`?schema.MagicLinkMethodOpts` with `ttl_s` and `redirect_default`), `ac.deliverMail(to, subject, body)`.
- Produces: `config.Config.public_url: []const u8 = ""`; `App.public_url: []const u8 = ""`; `magic_link.buildMailBody(alloc, public_url, col_name, token, redirect) ![]const u8`. When `public_url` is empty the email body is the legacy raw-token text (backward compatible); when set it is a clickable consume URL.

- [ ] **Step 1: Write the failing test for the pure body builder** (append to the test section of `src/auth/methods/magic_link.zig`)

```zig
test "buildMailBody: raw token when public_url is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try buildMailBody(arena.allocator(), "", "users", "TOK.EN", "/");
    try std.testing.expect(std.mem.indexOf(u8, body, "TOK.EN") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "http") == null);
}

test "buildMailBody: clickable consume link when public_url is set (trailing slash trimmed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try buildMailBody(arena.allocator(), "http://blog.test/", "users", "TOK.EN", "/dashboard");
    try std.testing.expectEqualStrings(
        "Click the link to sign in:\n\nhttp://blog.test/api/collections/users/auth/magic_link/consume?token=TOK.EN&redirect=/dashboard\n",
        body,
    );
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — compile error `buildMailBody` is not defined.

- [ ] **Step 3: Add the `buildMailBody` helper** (insert in `src/auth/methods/magic_link.zig` above `const vtable = AuthMethod.VTable{ … }` near line 109)

```zig
/// Build the magic-link email body. With no configured public base URL the
/// server cannot form an absolute link, so it falls back to emailing the raw
/// token (legacy behavior). With `public_url` set, it emits a clickable link to
/// the GET consume endpoint, which verifies+consumes the token, sets the session
/// cookie, and 302-redirects to `redirect`. JWT link tokens use the URL-safe
/// base64url alphabet (plus `.`), so the token needs no escaping; `redirect`
/// should be a simple origin-relative path (it is re-validated server-side).
fn buildMailBody(
    alloc: std.mem.Allocator,
    public_url: []const u8,
    col_name: []const u8,
    token: []const u8,
    redirect: []const u8,
) ![]const u8 {
    if (public_url.len == 0) {
        return std.fmt.allocPrint(alloc, "Your sign-in link token:\n\n{s}\n", .{token});
    }
    const base = std.mem.trimRight(u8, public_url, "/");
    return std.fmt.allocPrint(
        alloc,
        "Click the link to sign in:\n\n{s}/api/collections/{s}/auth/magic_link/consume?token={s}&redirect={s}\n",
        .{ base, col_name, token, redirect },
    );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed` (two new tests pass).

- [ ] **Step 5: Wire the helper into `initiateImpl`** (in `src/auth/methods/magic_link.zig`, replace the token-mint + mail-body block at lines 58-66)

Replace:

```zig
        if (try ac.findByIdentity(&r.conn, email)) |rid| {
            const ttl: i64 = if (ac.collection.options.auth.methods.magic_link) |ml| ml.ttl_s else 900;
            const token = try ac.mintLinkToken(&r.conn, rid, ttl, .{});
            const mail_body = try std.fmt.allocPrint(
                ac.ctx.allocator,
                "Your sign-in link token:\n\n{s}\n",
                .{token},
            );
            pending = .{ .email = email, .mail_body = mail_body };
        }
```

with:

```zig
        if (try ac.findByIdentity(&r.conn, email)) |rid| {
            const ml_opts = ac.collection.options.auth.methods.magic_link;
            const ttl: i64 = if (ml_opts) |ml| ml.ttl_s else 900;
            const redirect: []const u8 = if (ml_opts) |ml| ml.redirect_default else "/";
            const token = try ac.mintLinkToken(&r.conn, rid, ttl, .{});
            const mail_body = try buildMailBody(
                ac.ctx.allocator,
                ac.app.public_url,
                ac.collection.name,
                token,
                redirect,
            );
            pending = .{ .email = email, .mail_body = mail_body };
        }
```

- [ ] **Step 6: Add `public_url` to `config.Config`** (in `src/config.zig`, add after the `data_dir` field near line 11)

```zig
    /// Public base URL of this deployment (e.g. "https://app.example.com"). Used
    /// to build absolute links in auth emails (magic-link). Empty = no link is
    /// built (magic-link emails the raw token instead). Env: ZIGBASE_PUBLIC_URL.
    public_url: []const u8 = "",
```

And in `Config.load()` near line 102 (alongside the other `getter.get(...)` lines):

```zig
        if (getter.get("ZIGBASE_PUBLIC_URL")) |v| cfg.public_url = v;
```

- [ ] **Step 7: Add `public_url` to `App` and copy it from cfg**

In `src/app.zig`, add after the `sentry_dsn` field near line 29:

```zig
    public_url: []const u8 = "",
```

In `src/framework.zig`, in the App initializer near lines 797-801 (alongside `.jwt_secret = cfg.jwt_secret,`), add:

```zig
        .public_url = cfg.public_url,
```

- [ ] **Step 8: Run the full suite to verify wiring compiles and passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed`. The pre-existing magic_link `complete` tests still pass (the body change only affects `initiate`).

- [ ] **Step 9: Commit**

```bash
git add src/config.zig src/app.zig src/framework.zig src/auth/methods/magic_link.zig
git commit -m "feat(auth): emit a clickable magic-link email when public_url is set

Adds public_url (ZIGBASE_PUBLIC_URL) to Config/App. magic_link.initiate
now emails an absolute link to the GET consume endpoint when public_url
is configured, falling back to the raw token otherwise. Lets a stock
binary offer real magic-link login by config alone.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: D2 — correct the "columns are id-named" documentation

**Files:**
- Modify: `CLAUDE.md` (the provisioning gotcha sentence in the schema/provisioning paragraph)
- Modify: `docs/framework.md` + `site/src/content/docs/framework.md` (any matching claim — grep first)

**Interfaces:** none (docs only). Ground truth (verified): `stableFieldId` is consumed only at `provision.zig:210` to set `field.id`; `field.id` is used only to match columns across additive rebuilds (`ddl.rebuildPlan`). Physical SQLite columns are named by the human `field.name` (`ddl.createTableSql`/`columnDef`; proven by `collections.zig:279` asserting `pragma_table_info` contains `title`/`price`).

- [ ] **Step 1: Locate every occurrence of the false claim**

Run: `grep -rn "stable field id\|id-named\|8-char\|field id" CLAUDE.md docs/framework.md site/src/content/docs/framework.md`
Expected: at least the CLAUDE.md provisioning paragraph; note each hit.

- [ ] **Step 2: Rewrite the CLAUDE.md claim**

In `CLAUDE.md`, replace the sentence that begins "**Gotcha:** provisioned columns are named by an 8-char *stable field id* …" (through "raw SQL does not.") with:

```markdown
**Stable field ids:** each field carries an 8-char *stable field id* (FNV hash of
collection+field) used to match columns across additive rebuilds (`ddl.rebuildPlan`
matches old/new fields by id, preserving data through a table rebuild). The **physical
SQLite column is named by the human field name**, so a raw-SQL migration can
`CREATE INDEX ON posts(status)` directly, and the comptime `.indexes` key indexes
provisioned columns by field name. Migrations remain the escape hatch for tables the
migration itself owns and for non-additive DDL the provisioner won't perform.
```

- [ ] **Step 3: Fix any matching claim in the published docs**

For each hit from Step 1 in `docs/framework.md` / `site/src/content/docs/framework.md`, edit it to state that physical columns use the human field name and that `field.id` is an internal rebuild-matching key. (If Step 1 found no hits there, this step is a no-op — record that.)

- [ ] **Step 4: Rebuild the site if docs/framework.md changed**

Run: `cd site && npm run build`
Expected: success. (Skip only if Step 3 was a no-op.)

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/framework.md site/src/content/docs/framework.md
git commit -m "docs: correct the 'provisioned columns are id-named' claim

Physical SQLite columns are named by the human field name; the stable
field id is only used to match columns across additive rebuilds. Comptime
.indexes and raw migrations can both reference provisioned columns by name.
(The plugins example migration comment is corrected in the plugins PR.)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Changelog fragment + final verification

**Files:**
- Create: `changelog.d/comptime-indexes-and-magic-link-url.md`

**Interfaces:** none. This task gates the PR: changelog fragment present, full suite green, examples still build.

- [ ] **Step 1: Write the changelog fragment**

Create `changelog.d/comptime-indexes-and-magic-link-url.md`:

```markdown
### Features

- **Comptime `.indexes` on collection literals** — a `zigbase.App(.{ .collections = … })` collection may now declare `.indexes = .{ .{ .name, .fields, .unique?, .collation?, .where? }, … }`, lowered into the provisioned schema and emitted as `CREATE INDEX` DDL (case-insensitive via `.collation = .nocase`; conditional-unique via `.where`). Index `.fields` reference fields by their declared name.
- **`ZIGBASE_PUBLIC_URL` → clickable magic-link emails** — set `public_url` (env `ZIGBASE_PUBLIC_URL`) and the built-in `magic_link` method emails an absolute link to its consume endpoint (which sets the session cookie and redirects) instead of a bare token. Unset preserves the previous raw-token email. Lets a stock binary offer real magic-link login by configuration alone.

### Fixed

- **Comptime `.indexes` is no longer silently ignored** — the documented `.indexes` key on collection literals was never lowered by the provisioner; it is now applied.

### Internal

- Corrected the "provisioned columns are named by a stable field id" claim in `CLAUDE.md` and `docs/framework.md`: physical SQLite columns use the human field name; the stable field id only matches columns across additive rebuilds.
```

- [ ] **Step 2: Run the full unit suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed`.

- [ ] **Step 3: Confirm the examples still build** (the framework change must not break consumers)

Run: `mise exec zig@0.16.0 -- zig build` then for each example: `cd examples/blog && mise exec zig@0.16.0 -- zig build` (repeat for `golfsim`; `plugins` needs `cd frontend && npm install && npm run build` before its `zig build`).
Expected: all builds succeed. (No example uses `.indexes`/`public_url` yet, so this only proves no regression.)

- [ ] **Step 4: Commit and open the PR**

```bash
git add changelog.d/comptime-indexes-and-magic-link-url.md
git commit -m "docs(changelog): fragment for comptime .indexes + public_url magic-link"
git push -u origin worktree-examples-v05-features
gh pr create --title "feat: comptime .indexes + public_url magic-link links (examples v0.5 foundation)" \
  --body "Phase 1 of updating the examples to v0.5+ features. Adds the framework enablers the examples need: comptime .indexes lowering (E1) and a public_url->clickable magic-link email (E2), plus the D2 doc fix. Spec: docs/superpowers/specs/2026-06-22-examples-v05-features-design.md.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Expected: PR created; CI runs the Zig suite + browser suite + example builds.

---

## Self-Review

**Spec coverage:** E1 (Task 1), E2 (Task 2), D2 (Task 3), changelog/docs-sync/verify cross-cutting (Task 4) — all Phase-1 spec items mapped. E3 (comptime OAuth2) is intentionally deferred to its own plan (spec Phase 1b, cuttable). Phases 2-4 (examples) are separate plans per the spec.

**Placeholder scan:** Task 3 Step 3 is conditional ("if hits found") rather than fixed code — acceptable because it depends on a grep result that can't be known until run; the instruction is concrete (what to change, to what). No TBD/TODO/"handle edge cases" placeholders elsewhere; every code step shows complete code.

**Type consistency:** `buildIndexes(comptime []const u8, comptime anytype) []const schema.Index` and `buildMailBody(alloc, public_url, col_name, token, redirect) ![]const u8` are referenced with identical signatures where used. `public_url` is the consistent field name across `Config`, `App`, framework copy, and the `ac.app.public_url` read. `schema.Index`/`schema.Collation` field names match `src/schema.zig:449-471`.
