# Dev Field-Crypto Modes — Design

**Date:** 2026-07-07
**Status:** Approved (design), pending spec review
**Branch:** `feat/dev-field-crypto`
**Closes:** #260 (`zigbase.testing` can't boot an app with `.encrypted` fields)

## Goal

Make `.encrypted`-field apps trivially **testable** and locally **debuggable**,
without weakening production. Two capabilities, one `Cipher` seam:

1. **Real crypto with a caller-supplied key in the test harness** — closes #260
   with full fidelity (exercises the real `seal`/`open` path).
2. **A dev-only "fake encrypt" mode** — a readable, self-labeling passthrough so
   you can eyeball the plaintext right in the SQLite file, tagged with the key
   that produced it. Impossible to enable on a production build.

**Delivery:** one PR, two atomic chapters — (1) rename the `dev_clock` gate to
`dev_mode` (pure refactor, no behavior change), then (2) the field-crypto feature
gated by `dev.enabled`. Each is independently reviewable.

## Background (the seam)

Field encryption is centralized in `field_policy.Cipher` (`src/field_policy.zig`):
`seal(plaintext) → "v<N>:"+base64(nonce‖ct‖tag)` and `open(stored) → plaintext`,
resolved once at boot and stamped onto pooled DB connections; applied at the
`values.zig` read/write chokepoint. Above the DB everything is plaintext; only
SQLite holds the envelope. `open` is **strict/fail-closed** — a non-`v<N>:` blob
is `error.BadEnvelope`.

Boot resolution (`framework.zig:2723`):
```zig
if (cfg.field_key.len > 0) {
    holder.field_cipher = Cipher.resolve(io, EnvGetter, cfg.field_key, cfg.field_key_generation) …;
    db.poolSetFieldCipher(&holder.pool, &holder.field_cipher);
} else if (anyEncryptedField(schema_collections)) {
    return error.FieldKeyRequired;      // <- what #260 hits
}
```

The **prod-protection pattern** to mirror is `dev_clock` (`clock.zig`): a build
option (default = Debug, forced false by the release cross-compiles) drives a
comptime `enabled` flag; when false the override is comptime-dead and the env var
is never read. `fake_seed` rides the same flag.

## Design

### 1. `Cipher` gains a mode (`field_policy.zig`)

```zig
pub const Mode = enum { real, fake };

pub const Cipher = struct {
    mode: Mode = .real,
    // real:
    keys: [MAX_GENERATION + 1]?[32]u8 = @splat(null),
    primary_gen: u16 = 1,
    // fake:
    fake_key: []const u8 = "",   // the label embedded in / verified on the envelope
    io: std.Io,

    pub fn fake(io: std.Io, key: []const u8) Cipher {
        return .{ .mode = .fake, .io = io, .fake_key = key };
    }
    // fromEnv / resolve unchanged (they build .real ciphers).
};
```

- **`seal`** branches on mode:
  - `.real` → today's `aead.seal` (`v<primary>:…`).
  - `.fake` → `std.fmt.allocPrint(alloc, "fake:{s}:{s}", .{ fake_key, plaintext })`
    → e.g. `fake:@test@:John Doe loves cheese`.
- **`open`** branches on mode:
  - `.real` → today's strict envelope open.
  - `.fake` → require the exact prefix `"fake:" ++ fake_key ++ ":"` (prefix-match,
    so a `:` inside the key is unambiguous); on match, return the remainder as
    plaintext; otherwise `error.BadEnvelope`. A blob sealed under a *different*
    fake key therefore fails closed, mirroring "wrong key" on the real path.

**Mutual unreadability (a safety property, not a coincidence):** `fake:` is not a
`v<N>:` envelope, so a `.real` cipher's `open` rejects fake data
(`parseVersion → null → BadEnvelope`), and a `.fake` cipher's `open` rejects any
real `v<N>:` blob (prefix mismatch). A fake-encrypted DB can **never** be silently
served by a production binary — every encrypted read errors.

### 2. Unify the dev gate: `dev_clock` → `dev_mode` (prerequisite refactor)

Rather than add a third `dev_*` flag, this work **renames the existing gate to its
honest name**. `dev_clock` is already a misnomer: it gates the frozen clock, seeded
entropy (`entropy.enabled = clock.enabled`), and test-capture
(`testcapture.enabled = build_options.dev_clock`) — i.e. it is already the
"dev/test-only, never-in-prod" gate. Fake field-crypto is one more thing under the
same umbrella, so it rides the same flag under a clearer name.

Refactor (small at the source — only **2 files** read `build_options.dev_clock`
directly; ~8 others chain through `clock.enabled`):

1. `build.zig`: rename the option `dev-clock` → `dev-mode`, emit
   `build_options.addOption(bool, "dev_mode", dev_mode)` (same default:
   `optimize == .Debug`; forced false in release cross-compiles).
2. New leaf module **`src/dev.zig`** — the single, honestly-named gate:
   ```zig
   const build_options = @import("build_options");
   /// True on a dev/test build (Debug or `-Ddev-mode=true`); comptime-false on any
   /// release/shipped binary. The one gate for every dev-only-never-in-prod seam:
   /// the frozen clock, seeded entropy, test-capture mailer/sms/push, and fake
   /// field-crypto. When false, each of those folds to comptime-dead code.
   pub const enabled = build_options.dev_mode;
   ```
3. Point the two direct readers at it: `clock.zig` and `testcapture.zig` become
   `pub const enabled = dev.enabled;`. Every chained `clock.enabled` /
   `entropy.enabled` / `testcapture.enabled` reference is then unchanged — minimal
   churn, no behavior change.
4. CI: the prod-gate step `-Ddev-clock=false` → `-Ddev-mode=false`
   (`.github/workflows/ci.yml`). The release script needs no change (it never passes
   the flag; release builds default it off).
5. User-facing docs that name the build option (`docs/framework.md`,
   `KNOWN_LIMITATIONS.md`, `docs/email.md`, `docs/configuration.md` + their
   `site/src/content/docs/` mirrors) update `dev_clock`/`-Ddev-clock` → `dev_mode`/
   `-Ddev-mode`. **Do NOT** touch the historical `docs/superpowers/plans|specs`
   archive or past `CHANGELOG.md` entries (they record what was true then).
6. Breaking changelog entry: the build option `-Ddev-clock` is renamed to
   `-Ddev-mode` (pre-1.0; a niche flag used mainly by CI/e2e).

### 3. Field-crypto mode selection

New config field `Config.field_crypto: field_policy.Mode = .real` (`config.zig`
imports `field_policy` for the enum — one-way, no cycle, since `field_policy`
does not import `config`), resolved from the env by a **gated** resolver mirroring
`clock.resolveFromEnv` and reading the unified `dev.enabled`:
```zig
// field_policy.zig
const dev = @import("dev.zig");
pub fn resolveModeFromEnv(raw: ?[]const u8) Mode {   // ZIGBASE_FIELD_CRYPTO
    if (!dev.enabled) return .real;                  // comptime-dead on prod
    const s = raw orelse return .real;
    return if (std.mem.eql(u8, std.mem.trim(u8, s, " \t\r\n"), "fake")) .fake else .real;
}
```
Wired in `Config.load`: `cfg.field_crypto = resolveModeFromEnv(getter.get("ZIGBASE_FIELD_CRYPTO"));`

### 4. Boot path (`framework.zig:2723`)

Add the fake branch **first**, comptime-gated so it is dead on a prod build:
```zig
if (dev.enabled and cfg.field_crypto == .fake) {
    const label = if (cfg.field_key.len > 0) cfg.field_key else "@test@";
    holder.field_cipher = field_policy.Cipher.fake(io, label);
    db.poolSetFieldCipher(&holder.pool, @ptrCast(&holder.field_cipher));
    std.log.warn(
        "FAKE FIELD CRYPTO ACTIVE (ZIGBASE_FIELD_CRYPTO=fake, label \"{s}\") — .encrypted values are stored READABLE as `fake:<label>:<plaintext>`. This must NEVER appear on a production build.",
        .{label});
} else if (cfg.field_key.len > 0) {
    … existing real resolve …
} else if (anyEncryptedField(schema_collections)) {
    return error.FieldKeyRequired;
}
```
Because `dev.enabled` is comptime-false on a release binary, the entire fake branch
folds away: `ZIGBASE_FIELD_CRYPTO=fake` is ignored, `cfg.field_crypto` is forced
`.real` by the resolver, and an encrypted app with no key still fails closed exactly
as today. The runtime-created-encrypted-field guard (`framework.zig:2785`) is
unaffected — a fake cipher is a non-null cipher, so it passes.

### 5. Test harness (`testing.zig`) — closes #260

Add to `StartOptions`:
```zig
/// Field-encryption key. When set, boots REAL AES-GCM at-rest crypto (full
/// fidelity). When null, an .encrypted-field app defaults to fake-encrypt (below).
field_key: ?[]const u8 = null,
/// Field-crypto mode. null = infer: real when `field_key` is set, else fake.
/// `.fake` stores readable `fake:<label>:<value>` at rest (dev builds only);
/// `.real` requires `field_key`. Requires a dev-crypto build (Debug/`zig build test`).
field_crypto: ?field_policy.Mode = null,
```
Lowering (in `start`, alongside `fake_now_unix`/`fake_seed`):
```zig
const mode: field_policy.Mode = opts.field_crypto orelse
    (if (opts.field_key != null) .real else .fake);
// ... cfg:
.field_crypto = mode,
.field_key = opts.field_key orelse (if (mode == .fake) "@test@" else ""),
```
Result:
- `start(App, .{})` on an encrypted app → **fake**, label `@test@` → at-rest
  `fake:@test@:value`, zero ceremony, boots immediately. (Your chosen default.)
- `start(App, .{ .field_key = "k" })` → **real** AES with key `"k"`.
- `start(App, .{ .field_crypto = .fake, .field_key = "k1" })` → fake, label `k1`
  → `fake:k1:value`.
- `start(App, .{ .field_crypto = .real })` (no key) → `error.FieldKeyRequired`
  (real needs a key).

The empty-environ boot design (#260's "workaround" section) is preserved: the
harness lowers the mode onto `cfg` directly, never through the env map — exactly
how `fake_now_unix`/`fake_seed` already work.

**Release-build harness:** on a release build of a consumer using the harness,
`dev.enabled` is false, so the fake branch is comptime-dead — an encrypted app
booted with `.{}` fails closed (needs a real `field_key`). Tests run in Debug, so
this is transparent for normal use. Documented, not surprising.

### 6. Server (`zigbase serve`)

Unchanged default: `.real` / fail-closed (prod parity). Local dev opt-in:
```
ZIGBASE_FIELD_CRYPTO=fake zigbase serve --insecure-cookies …
```
→ fake mode, label = `ZIGBASE_FIELD_KEY` if set else `@test@`. Dev builds only.

## Config-plane placement (docs/framework.md §3)

- `ZIGBASE_FIELD_CRYPTO` — **env** (deploy/dev-varying), **build-flag-gated**
  (`dev_mode` = binary cost + prod safety). Consistent with `ZIGBASE_FAKE_NOW`.
- `StartOptions.field_key` / `.field_crypto` — harness API surface (test-time),
  mirroring `fake_now_unix`/`fake_seed`.

## Testing

### Zig unit — `field_policy.zig`
- fake `seal` produces exactly `fake:@test@:<plaintext>` (and `fake:<label>:…` for
  a custom label); it is NOT an `aead.isEnvelope`.
- fake `seal`→`open` round-trips; `open` returns the plaintext.
- **wrong fake key fails closed**: a `fake:k1:…` blob opened by a `Cipher.fake(io,"k2")`
  → `error.BadEnvelope`.
- **mutual unreadability**: `Cipher.fromEnv(...).open(fake_blob)` → `BadEnvelope`;
  `Cipher.fake(...).open(real_v1_blob)` → `BadEnvelope`.
- gated resolver: `resolveModeFromEnv("fake")` → `.fake` when `dev.enabled`, else
  `.real` (mirror clock.zig's gated test with an `if (dev.enabled) … else …`).
- the existing prod-gate CI step now runs under `-Ddev-mode=false`; the prod-gate
  assertions (clock/entropy/test-capture compiled out) still execute, and the new
  fake-crypto path is comptime-dead there too.

### Zig in-process harness — `testing.zig` (dogfoods the harness + #260)
An `App` with an `.encrypted` text field:
- `start(App, .{})` boots (no `FieldKeyRequired`); create a record via the real
  pipeline (`t.request`), read it back → **plaintext** round-trips; then read the
  raw column from the data-dir DB → it is `fake:@test@:<plaintext>` (readable).
- `start(App, .{ .field_key = "k" })` boots real; the raw column is a `v1:` blob
  (opaque, not readable, not equal to the plaintext).

### Docs-parity — `tests/admin/test_docs_parity.py`
New env var `ZIGBASE_FIELD_CRYPTO` must be added to the env-var table in the docs
(the parity test fails on env-table drift). No new comptime config-key-table row
(field_crypto is env + harness-option, not an `App(.{})` key).

## Docs & changelog

- `docs/fields.md` (encryption-at-rest section) — document fake mode: what it
  stores (`fake:<key>:<value>`), that it is **dev-build-only and never on a prod
  binary**, and that a fake-encrypted DB is unreadable by a real binary.
- `docs/framework.md` — §15 (testing harness): `StartOptions.field_key` /
  `.field_crypto` (closes #260); the env-var table: `ZIGBASE_FIELD_CRYPTO`; the
  config-plane note.
- `site/src/content/docs/` mirrors of both.
- `changelog.d/dev-field-crypto.md` — `### Breaking` (the `-Ddev-clock` build
  option is renamed to `-Ddev-mode`) + `### Features` (harness `field_key` +
  fake-encrypt dev mode; #260).
- Help text (`framework.zig` env list): mention `ZIGBASE_FIELD_CRYPTO` as a
  dev-only knob (alongside where `ZIGBASE_FAKE_NOW` is described, if listed).

## File map

**Gate consolidation (chapter 1):**

| File | Change |
|------|--------|
| `build.zig` | rename option `dev-clock` → `dev-mode`; `addOption("dev_mode", …)`. |
| `src/dev.zig` | **Create** — `pub const enabled = build_options.dev_mode` (the one dev gate). |
| `src/clock.zig`, `src/testcapture.zig` | `pub const enabled = dev.enabled` (was `build_options.dev_clock`). Chained `clock.enabled`/`entropy.enabled`/`testcapture.enabled` refs unchanged. |
| `.github/workflows/ci.yml` | prod-gate step `-Ddev-clock=false` → `-Ddev-mode=false`. |
| `docs/framework.md`, `KNOWN_LIMITATIONS.md`, `docs/email.md`, `docs/configuration.md` + site mirrors | rename `dev_clock`/`-Ddev-clock` → `dev_mode`/`-Ddev-mode` (NOT the historical `docs/superpowers/**` or past `CHANGELOG.md`). |

**Field-crypto feature (chapter 2):**

| File | Change |
|------|--------|
| `src/field_policy.zig` | `Mode` enum; `Cipher.mode`/`fake_key`; `Cipher.fake`; mode branch in `seal`/`open`; `resolveModeFromEnv` (reads `dev.enabled`); unit tests. |
| `src/config.zig` | import `field_policy`; `field_crypto: field_policy.Mode = .real`; resolve from `ZIGBASE_FIELD_CRYPTO` in `load` (gated). |
| `src/framework.zig` | fake branch at the boot cipher resolution (comptime-gated on `dev.enabled`); loud warning; env help line. |
| `src/testing.zig` | `StartOptions.field_key` + `.field_crypto`; lowering onto `cfg`; harness tests. |
| `docs/fields.md`, `docs/framework.md` + site mirrors | fake-mode + harness-knob docs; `ZIGBASE_FIELD_CRYPTO` env-table row. |
| `changelog.d/dev-field-crypto.md` | `### Breaking` (`-Ddev-clock` → `-Ddev-mode`) + `### Features` (harness `field_key` + fake-encrypt, #260). |

## Out of scope (deliberate)

- Multi-generation rotation testing in the harness (`field_keys: ?[]const Generation`)
  — #260 explicitly defers it; the single-key/real + fake modes are the ask.
- Fake mode for anything other than `.encrypted` fields (it's a Cipher-seam
  behavior only).
- Any change to real-crypto semantics, envelope format, or the prod boot posture.
