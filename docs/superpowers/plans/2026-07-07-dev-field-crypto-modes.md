# Dev Field-Crypto Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close #260 (test harness can't boot `.encrypted`-field apps) and add a dev-only, debuggable "fake encrypt" mode — while consolidating the existing `dev_clock` prod-gate into an honestly-named `dev_mode` gate.

**Architecture:** `field_policy.Cipher` gains a `Mode` (`.real`/`.fake`). Fake `seal` writes readable `fake:<key>:<value>`; fake `open` reverses it. Selection is env (`ZIGBASE_FIELD_CRYPTO`) + harness `StartOptions`, all gated by a new `src/dev.zig` (`enabled = build_options.dev_mode`) so fake crypto is comptime-dead on a release binary.

**Tech Stack:** Zig 0.16; the `values.zig`/`Cipher` at-rest encryption seam; the `build_options` comptime-gate pattern (from `clock.zig`).

## Global Constraints

- **Prod safety is the whole point:** fake crypto MUST be impossible on a release binary. It is gated by `build_options.dev_mode` (default `optimize == .Debug`, off in every release build). Every fake path is `if (dev.enabled) …`.
- **Real crypto semantics, the envelope format, and the production boot posture do NOT change.**
- **Zig 0.16:** `std.mem.startsWith`, `std.fmt.allocPrint` return `error{OutOfMemory}`; `aead.Error = error{BadEnvelope} || std.mem.Allocator.Error`.
- **Test commands:**
  - `mise exec zig@0.16.0 -- zig build` and `… zig build test --summary all` (authoritative: `Build Summary: N/N tests passed`; ignore the spurious `failed command:` line).
  - **Prod-gate:** `… zig build test --summary all -Ddev-mode=false` MUST pass (this is the renamed CI gate; dev-only tests self-skip via `if (!dev.enabled) return error.SkipZigTest;`).
  - `… zig fmt --check src build.zig` must pass.
- **Docs sync:** any `docs/*.md` change mirrors into `site/src/content/docs/*.md`. Changelog goes in `changelog.d/`, never `CHANGELOG.md`. Do NOT edit the historical `docs/superpowers/**` archive or past `CHANGELOG.md` entries when renaming the flag.

---

## Task 1: Consolidate the dev gate — `dev_clock` → `dev_mode`

Pure refactor, no behavior change. `dev_clock` already gates the clock, seeded entropy, and test-capture; rename it to its honest name and add one leaf module.

**Files:**
- Create: `src/dev.zig`
- Modify: `build.zig`, `src/clock.zig`, `src/testcapture.zig`, `.github/workflows/ci.yml`
- Modify (docs): `docs/framework.md`, `KNOWN_LIMITATIONS.md`, `docs/email.md`, `docs/configuration.md` + their `site/src/content/docs/` mirrors

**Interfaces:**
- Produces: `dev.enabled` (`bool`, comptime) — the single dev-only-never-in-prod gate. `clock.enabled` and `testcapture.enabled` become aliases of it, so all chained `clock.enabled`/`entropy.enabled`/`testcapture.enabled` references are unchanged.

- [ ] **Step 1: Create `src/dev.zig`**

```zig
//! The single dev-only build gate. True on a dev/test build (Debug by default, or
//! `-Ddev-mode=true`); comptime-FALSE on any release/shipped binary (the release
//! script cross-compiles ReleaseSafe, so `dev_mode` defaults off there). It gates
//! every dev-only-never-in-production seam so a prod binary can't use any of them:
//! the frozen clock (`ZIGBASE_FAKE_NOW`), seeded entropy (`ZIGBASE_FAKE_SEED`),
//! the test-capture mailer/sms/push, and fake field-crypto (`ZIGBASE_FIELD_CRYPTO`).
//! When false, each of those folds to comptime-dead code and its env var is never read.
const build_options = @import("build_options");

/// Comptime gate — see the module doc comment. Every dev-only override is `if (dev.enabled) …`.
pub const enabled = build_options.dev_mode;
```

- [ ] **Step 2: Rename the build option in `build.zig`**

Replace (build.zig:33-34):
```zig
    const dev_clock = b.option(bool, "dev-clock", "Compile in the dev-only ZIGBASE_FAKE_NOW test clock (default: on in Debug, off in release)") orelse (optimize == .Debug);
    build_options.addOption(bool, "dev_clock", dev_clock);
```
with:
```zig
    const dev_mode = b.option(bool, "dev-mode", "Compile in the dev-only, never-in-prod seams: ZIGBASE_FAKE_NOW clock, ZIGBASE_FAKE_SEED entropy, test-capture, and ZIGBASE_FIELD_CRYPTO fake crypto (default: on in Debug, off in release)") orelse (optimize == .Debug);
    build_options.addOption(bool, "dev_mode", dev_mode);
```
Also update the 3-line comment just above (build.zig:30-32) to say `-Ddev-mode=true` instead of `-Ddev-clock=true` and describe the broader gate.

- [ ] **Step 3: Point the two direct readers at `dev.enabled`**

In `src/clock.zig` (line ~42) replace:
```zig
pub const enabled = build_options.dev_clock;
```
with:
```zig
const dev = @import("dev.zig");
pub const enabled = dev.enabled;
```
(Keep the existing doc comment; the `build_options` import stays if still used elsewhere in clock.zig — leave it.) Do the identical change in `src/testcapture.zig` (line ~36): `const dev = @import("dev.zig"); pub const enabled = dev.enabled;`.

- [ ] **Step 4: Rename the CI prod-gate step (`.github/workflows/ci.yml:124-125`)**

```yaml
      - name: "Unit tests (prod gate: -Ddev-mode=false)"
        run: mise exec zig@0.16.0 -- zig build test --summary all -Ddev-mode=false
```

- [ ] **Step 5: Verify the refactor builds and both gate states pass**

Run: `mise exec zig@0.16.0 -- zig fmt --check src build.zig`
Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Run: `mise exec zig@0.16.0 -- zig build test --summary all -Ddev-mode=false`
Expected: all pass (`Build Summary: N/N tests passed`). This proves the rename is behavior-preserving in both gate states.

- [ ] **Step 6: Confirm no stale flag references remain in code/CI**

Run: `git grep -nE "dev.clock" -- '*.zig' 'build.zig' '.github/workflows/ci.yml'`
Expected: **no matches** (all renamed). (Historical `docs/superpowers/**` and `CHANGELOG.md` are intentionally left; they are not searched here.)

- [ ] **Step 7: Update user-facing docs that name the flag**

In each of `docs/framework.md`, `KNOWN_LIMITATIONS.md`, `docs/email.md`, `docs/configuration.md` **and** their `site/src/content/docs/` mirrors, replace `dev_clock` → `dev_mode` and `-Ddev-clock` → `-Ddev-mode`, and where a sentence says the flag gates "the clock", broaden it to "the dev-only seams (frozen clock, seeded entropy, test-capture)". Keep each doc and its mirror identical. (Find them with `git grep -nl "dev.clock" -- 'docs/*.md' 'site/src/content/docs/*.md'`, excluding `docs/superpowers/`.)

- [ ] **Step 8: Rebuild the site (docs changed) + commit**

Run: `cd site && mise exec node@24 -- npm ci >/dev/null 2>&1 && mise exec node@24 -- npm run build 2>&1 | tail -3` — expect `Complete!`.
```bash
git add src/dev.zig build.zig src/clock.zig src/testcapture.zig .github/workflows/ci.yml docs site
git commit -m "refactor: unify dev-only build gates under dev_mode (was dev_clock)"
```

---

## Task 2: `Cipher` fake mode + config + boot

**Files:**
- Modify: `src/field_policy.zig` (Mode, fake seal/open, resolver, unit tests)
- Modify: `src/config.zig` (`field_crypto` field + env resolve)
- Modify: `src/framework.zig` (boot fake branch)

**Interfaces:**
- Consumes: `dev.enabled` (Task 1).
- Produces: `field_policy.Mode` (`enum { real, fake }`); `Cipher.fake(io, key) Cipher`; `field_policy.env_var`/`resolveModeFromEnv`; `Config.field_crypto: field_policy.Mode`.

- [ ] **Step 1: Add the mode to `Cipher` (`src/field_policy.zig`)**

At the top, add the import and the `Mode` enum (after the existing `const … = @import(...)` lines):
```zig
const dev = @import("dev.zig");

/// Field-crypto mode. `.real` = AES-GCM envelopes (production). `.fake` = a dev-only,
/// build-gated readable passthrough (`fake:<key>:<value>`) for debugging/testing.
pub const Mode = enum { real, fake };

/// Env var selecting the mode (dev builds only): `ZIGBASE_FIELD_CRYPTO=fake`.
pub const env_var = "ZIGBASE_FIELD_CRYPTO";

/// Resolve the mode from the env, gated by `dev.enabled`. On a prod build this is
/// comptime `.real` — the env var is never consulted, so fake crypto can't be selected.
pub fn resolveModeFromEnv(raw: ?[]const u8) Mode {
    if (!dev.enabled) return .real;
    const s = raw orelse return .real;
    const t = std.mem.trim(u8, s, " \t\r\n");
    return if (std.mem.eql(u8, t, "fake")) .fake else .real;
}
```

In the `Cipher` struct, add two fields (after `primary_gen`):
```zig
    /// Field-crypto mode. `.real` uses the key-ring below; `.fake` uses `fake_key`.
    mode: Mode = .real,
    /// Fake-mode label: embedded in the readable envelope and required on open.
    fake_key: []const u8 = "",
```

Add the fake constructor (next to `fromEnv`):
```zig
    /// Dev-only fake cipher: `seal` writes readable `fake:<key>:<value>`. Callers must
    /// gate construction on `dev.enabled` (the boot path does). `key` is the label.
    pub fn fake(io: std.Io, key: []const u8) Cipher {
        return .{ .io = io, .mode = .fake, .fake_key = key };
    }
```

- [ ] **Step 2: Branch `seal`/`open` on mode (`src/field_policy.zig`)**

Replace `seal`:
```zig
    pub fn seal(self: *const Cipher, alloc: std.mem.Allocator, plaintext: []const u8) std.mem.Allocator.Error![]u8 {
        switch (self.mode) {
            .real => {
                const key = self.keys[self.primary_gen].?;
                return aead.seal(self.io, alloc, key, self.primary_gen, plaintext);
            },
            // Readable, self-labeling, deterministic. Dev-only (construction is gated).
            .fake => return std.fmt.allocPrint(alloc, "fake:{s}:{s}", .{ self.fake_key, plaintext }),
        }
    }
```

Replace `open`:
```zig
    pub fn open(self: *const Cipher, alloc: std.mem.Allocator, stored: []const u8) aead.Error![]u8 {
        switch (self.mode) {
            .real => {
                const ver = aead.parseVersion(stored) orelse return error.BadEnvelope;
                if (ver < 1 or ver > MAX_GENERATION) return error.BadEnvelope;
                const key = self.keys[ver] orelse return error.BadEnvelope;
                return aead.open(alloc, key, stored);
            },
            .fake => {
                // Require the exact `fake:<fake_key>:` prefix (prefix-walk tolerates a ':'
                // inside the key). A different label, or a real `v<N>:` envelope, fails closed.
                if (!std.mem.startsWith(u8, stored, "fake:")) return error.BadEnvelope;
                const rest = stored["fake:".len..];
                if (!std.mem.startsWith(u8, rest, self.fake_key)) return error.BadEnvelope;
                const after = rest[self.fake_key.len..];
                if (after.len == 0 or after[0] != ':') return error.BadEnvelope;
                return alloc.dupe(u8, after[1..]);
            },
        }
    }
```

- [ ] **Step 3: Add fake-mode unit tests (`src/field_policy.zig`)**

Append:
```zig
test "fake mode: seal is readable and self-labeling; open round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cph = Cipher.fake(std.testing.io, "@test@");
    const blob = try cph.seal(a, "John Doe loves cheese");
    try std.testing.expectEqualStrings("fake:@test@:John Doe loves cheese", blob);
    try std.testing.expect(!aead.isEnvelope(blob)); // not a v<N>: envelope
    try std.testing.expectEqualStrings("John Doe loves cheese", try cph.open(a, blob));
}

test "fake mode: a different label fails closed (verifies which key)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try Cipher.fake(std.testing.io, "k1").seal(a, "x");
    try std.testing.expectError(error.BadEnvelope, Cipher.fake(std.testing.io, "k2").open(a, blob));
}

test "fake and real envelopes are mutually unreadable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const real = Cipher.fromEnv(std.testing.io, "operator-key");
    const fake_c = Cipher.fake(std.testing.io, "@test@");
    const real_blob = try real.seal(a, "s");
    const fake_blob = try fake_c.seal(a, "s");
    try std.testing.expectError(error.BadEnvelope, real.open(a, fake_blob)); // prod can't read fake
    try std.testing.expectError(error.BadEnvelope, fake_c.open(a, real_blob)); // fake can't read real
}

test "resolveModeFromEnv is gated by the dev build" {
    if (dev.enabled) {
        try std.testing.expectEqual(Mode.fake, resolveModeFromEnv("fake"));
        try std.testing.expectEqual(Mode.real, resolveModeFromEnv("real"));
        try std.testing.expectEqual(Mode.real, resolveModeFromEnv(null));
    } else {
        try std.testing.expectEqual(Mode.real, resolveModeFromEnv("fake")); // comptime-off on prod
    }
}
```

- [ ] **Step 4: Add `field_crypto` to `Config` (`src/config.zig`)**

Add the import at the top (near the other `@import`s): `const field_policy = @import("field_policy.zig");`

After the `fake_seed` field (config.zig:156), add:
```zig
    // DEV-ONLY fake field-crypto (`ZIGBASE_FIELD_CRYPTO=fake`). When `.fake`, `.encrypted`
    // fields are stored READABLE as `fake:<key>:<value>` for debugging. ALWAYS `.real` on a
    // production build — `field_policy.resolveModeFromEnv` is comptime-gated off when
    // `dev_mode` is false, so a prod binary ignores the env var entirely. `.real` = AES-GCM.
    field_crypto: field_policy.Mode = .real,
```

In `load`, after the `fake_seed` resolve line (config.zig:227), add:
```zig
        // Dev-only fake field-crypto. resolveModeFromEnv is comptime-gated off on a prod build.
        cfg.field_crypto = field_policy.resolveModeFromEnv(getter.get(field_policy.env_var));
```

- [ ] **Step 5: Add the boot fake branch (`src/framework.zig`)**

Ensure `const dev = @import("dev.zig");` is imported at the top of framework.zig (add it near the other imports if absent).

Prepend a branch to the boot cipher block (framework.zig:2723). Change:
```zig
    if (cfg.field_key.len > 0) {
```
to:
```zig
    if (dev.enabled and cfg.field_crypto == .fake) {
        // Dev-only readable at-rest crypto (build-gated: dead on a release binary).
        const label = if (cfg.field_key.len > 0) cfg.field_key else "@test@";
        holder.field_cipher = field_policy.Cipher.fake(io, label);
        db.poolSetFieldCipher(&holder.pool, @ptrCast(&holder.field_cipher));
        std.log.warn("FAKE FIELD CRYPTO ACTIVE (ZIGBASE_FIELD_CRYPTO=fake, label \"{s}\") — .encrypted values are stored READABLE as `fake:<label>:<plaintext>`. This must NEVER appear on a production build.", .{label});
    } else if (cfg.field_key.len > 0) {
```
(The existing `if (cfg.field_key.len > 0)` body and the trailing `else if (anyEncryptedField(...))` are unchanged — they now follow the new leading branch.)

- [ ] **Step 6: Build + run the field_policy tests**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: pass, including the four new `field_policy` tests.
Run: `mise exec zig@0.16.0 -- zig build test --summary all -Ddev-mode=false`
Expected: pass — the gated `resolveModeFromEnv` test takes its `else` branch; the seal/open tests use `Cipher.fake` directly (not gated) and still pass.

- [ ] **Step 7: Commit**

```bash
git add src/field_policy.zig src/config.zig src/framework.zig
git commit -m "feat: add dev-only fake field-crypto mode to the Cipher seam"
```

---

## Task 3: Harness knobs + tests + docs (#260)

**Files:**
- Modify: `src/testing.zig` (`StartOptions` + lowering + fixture + tests)
- Modify: `docs/fields.md`, `docs/framework.md` + site mirrors
- Create: `changelog.d/dev-field-crypto.md`

**Interfaces:**
- Consumes: `Config.field_crypto`, `field_policy.Mode`, the boot fake branch (Task 2); `dev.enabled` (Task 1).

- [ ] **Step 1: Add `StartOptions` knobs + imports (`src/testing.zig`)**

Ensure these imports exist at the top of testing.zig (add if absent):
`const dev = @import("dev.zig");` and `const field_policy = @import("field_policy.zig");`

After the `fake_seed` field in `StartOptions` (testing.zig:88), add:
```zig
    /// Field-encryption key. When set, boots REAL AES-GCM at-rest crypto (full fidelity),
    /// closing #260 for encrypted-field apps. When null, an `.encrypted`-field app defaults
    /// to fake-encrypt (below).
    field_key: ?[]const u8 = null,
    /// Field-crypto mode. `null` = infer: `.real` when `field_key` is set, else `.fake`.
    /// `.fake` stores readable `fake:<label>:<value>` at rest (label = `field_key` or `@test@`);
    /// requires a dev-mode build (`zig build test`). `.real` requires `field_key`.
    field_crypto: ?field_policy.Mode = null,
```

- [ ] **Step 2: Lower the knobs onto `cfg` (`src/testing.zig`)**

Just before the `const cfg = config.Config{` literal (testing.zig:122), add:
```zig
    const fc_mode: field_policy.Mode = opts.field_crypto orelse
        (if (opts.field_key != null) .real else .fake);
    const fc_key: []const u8 = opts.field_key orelse (if (fc_mode == .fake) "@test@" else "");
```
Add these two fields inside the `config.Config{ … }` literal (alongside `.fake_now_unix`/`.fake_seed`):
```zig
        .field_crypto = fc_mode,
        .field_key = fc_key,
```

- [ ] **Step 3: Add an encrypted-field fixture + tests (`src/testing.zig`)**

After the `HarnessTestApp` definition (testing.zig:~569), add the fixture:
```zig
/// App with an `.encrypted` field, for the field-crypto harness tests (#260).
const EncryptedTestApp = framework.App(.{
    .collections = .{
        .notes = .{
            .fields = .{
                .{ .name = "title", .type = .text, .max = 100 },
                .{ .name = "body", .type = .text, .encrypted = true },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@public" },
        },
    },
});
```
Then the tests:
```zig
test "harness: encrypted-field app boots via fake-encrypt default (#260)" {
    if (!dev.enabled) return error.SkipZigTest; // fake mode is dev-only (build-gated)
    // No crypto opts -> fake-encrypt, label "@test@". Booting AT ALL proves fake engaged:
    // real mode with no key would fail closed (error.FieldKeyRequired).
    var t = try start(EncryptedTestApp, .{});
    defer t.deinit();
    const created = try t.request(.POST, "/api/collections/notes/records", .{ .json = .{ .title = "t", .body = "John Doe loves cheese" } });
    try std.testing.expectEqual(@as(u16, 201), created.status);
    const listed = try t.request(.GET, "/api/collections/notes/records", .{});
    const page = try listed.json(struct { items: []struct { body: []const u8 } });
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("John Doe loves cheese", page.items[0].body); // plaintext round-trips
}

test "harness: encrypted-field app boots with a real field_key" {
    // Real AES-GCM is not build-gated, so this runs in both gate states.
    var t = try start(EncryptedTestApp, .{ .field_key = "test-operator-key" });
    defer t.deinit();
    const created = try t.request(.POST, "/api/collections/notes/records", .{ .json = .{ .title = "t", .body = "secret" } });
    try std.testing.expectEqual(@as(u16, 201), created.status);
    const listed = try t.request(.GET, "/api/collections/notes/records", .{});
    const page = try listed.json(struct { items: []struct { body: []const u8 } });
    try std.testing.expectEqualStrings("secret", page.items[0].body);
}
```

- [ ] **Step 4: Build + run the harness tests (both gate states)**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: pass, including both new harness tests.
Run: `mise exec zig@0.16.0 -- zig build test --summary all -Ddev-mode=false`
Expected: pass — the fake-default test self-skips; the real-key test still runs green.

- [ ] **Step 5: Docs — harness knobs, fake mode, env var**

- `docs/framework.md` §15 (testing harness): document `StartOptions.field_key` and `.field_crypto` — closing #260, the fake-default (`@test@`) behavior, and that fake is dev-build-only. Add `ZIGBASE_FIELD_CRYPTO` to the env-var table with a note that it is dev-only/build-gated (mirror the `ZIGBASE_FAKE_NOW` row's phrasing).
- `docs/fields.md` (encryption-at-rest section): document fake mode — what it stores (`fake:<key>:<value>`), that it is **dev-build-only and never on a prod binary**, and that a fake-encrypted DB is unreadable by a real binary (fail-closed).
- Mirror both into `site/src/content/docs/framework.md` and `site/src/content/docs/fields.md` (keep each identical to its `docs/` source).

- [ ] **Step 6: Changelog fragment**

Create `changelog.d/dev-field-crypto.md`:
```markdown
### Breaking

- The dev-only build option `-Ddev-clock` is renamed `-Ddev-mode` (it already gated the frozen clock, seeded entropy, and test-capture; it now also gates the new fake field-crypto). Update any CI/e2e invocation of `-Ddev-clock=…` to `-Ddev-mode=…`.

### Features

- `zigbase.testing` can now boot apps that declare `.encrypted` fields (#260): pass `StartOptions.field_key` for real AES-GCM, or let it default to a dev-only **fake-encrypt** mode that stores readable `fake:<key>:<value>` at rest (label defaults to `@test@`) so encrypted values are eyeball-able while debugging. Also selectable on `zigbase serve` via `ZIGBASE_FIELD_CRYPTO=fake`. Fake crypto is compiled out of release binaries (the `dev_mode` gate) and its envelopes are mutually unreadable with real ciphertext, so a fake DB can never be served by a production binary.
```

- [ ] **Step 7: Build the site + docs-parity check + commit**

Run: `cd site && mise exec node@24 -- npm run build 2>&1 | tail -3` — expect `Complete!`.
Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q` — expect pass (the new `ZIGBASE_FIELD_CRYPTO` env row must be present in the docs env table the test checks).
```bash
git add src/testing.zig docs site changelog.d/dev-field-crypto.md
git commit -m "feat(testing): field_key + fake-encrypt harness knobs; docs (#260)"
```

---

## Self-Review Notes

- **Spec coverage:** gate rename + `src/dev.zig` (T1); `Cipher.Mode`/fake seal-open/mutual-unreadability/resolver (T2 s1-3); config+boot gated on `dev.enabled` (T2 s4-5); harness `field_key`/`field_crypto` + `@test@` default + #260 tests (T3); docs+env-row+changelog Breaking+Features (T1 s7, T3 s5-6). Covered.
- **Prod gate:** every fake path is `dev.enabled`-gated (resolver, boot branch, harness fake-default test self-skips). The `-Ddev-mode=false` run is required in every task's verify step.
- **Type consistency:** `field_policy.Mode` used identically in `Config.field_crypto`, `StartOptions.field_crypto`, `Cipher.mode`, and `resolveModeFromEnv`. `Cipher.fake(io, key)` signature matches all call sites (boot + tests).
- **No behavior change in T1:** `clock.enabled`/`entropy.enabled`/`testcapture.enabled` keep their values (now via `dev.enabled`), so the ~8 chained-reference files need no edits and the prod-gate test still passes.
