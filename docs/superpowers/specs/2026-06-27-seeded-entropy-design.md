# Issue #95 — Seeded Entropy for Deterministic IDs/Tokens in Test Mode

**Status:** Implemented 2026-06-27. See PR at `feat/seeded-entropy`.

## Background

ZigBase already has a dev-only "now" seam (`src/clock.zig`) that freezes every
framework-controlled timestamp when `ZIGBASE_FAKE_NOW` is set on a dev build. This
lets a test suite freeze time and exercise TTL/expiry/scheduling scenarios
deterministically.

**The gap (issue #95):** Record IDs, field IDs, and token keys are generated from the
OS CSPRNG via `id.generate → io.random`. Every test run produces different IDs, so
snapshot tests asserting specific IDs or tokens cannot be made deterministic. This is
the seeded-entropy follow-up to the determinism theme.

## Goal

When `ZIGBASE_FAKE_SEED` is set to a decimal `u64` (e.g. `12345`) on a dev build, the
framework's ID/token generation becomes deterministic: every call to `id.generate`
(and by extension `crypto.genToken`, `id.collectionId`, `id.fieldId`) draws from a
seeded Xoshiro256++ PRNG instead of the OS CSPRNG. Two runs with the same seed produce
byte-for-byte identical IDs and tokens.

When no seed is set, or on a production build, the real OS CSPRNG is always used.

## Seam selection

The single seam is `id.generate(io: std.Io, out: []u8)`. It calls `io.random` byte by
byte (with rejection sampling for uniform base36 output). All IDs and tokens in the
system flow through this function:

- `id.collectionId`, `id.fieldId` — collection and field IDs.
- `crypto.genToken` — the `tokenKey` per auth record and the OAuth CSRF state value.

Other randomness calls (`aead.zig` AEAD nonces, `mail/mailer.zig` SMTP entropy,
`auth/methods/otp.zig` OTP codes, WebAuthn challenges) are explicitly **not** routed
through the seam. Those are security-critical at runtime and reproducibility there is
neither requested nor safe.

## Approach: mirror the clock seam exactly

`src/entropy.zig` mirrors `src/clock.zig` in structure and gating:

| clock seam | entropy seam |
|---|---|
| `clock.enabled = build_options.dev_clock` | `entropy.enabled = clock.enabled` (same gate) |
| `ZIGBASE_FAKE_NOW` (ISO-8601 instant → i64) | `ZIGBASE_FAKE_SEED` (decimal u64) |
| `clock.resolveFromEnv` | `entropy.resolveFromEnv` |
| `clock.install(unix: ?i64)` | `entropy.install(seed: ?u64)` |
| `clock.frozenUnix() ?i64` | `entropy.isActive() bool` |
| process-global atomic `i64` | process-global atomic `u64` + Xoshiro256++ state |
| `clock.setForTest` / `clock.resetForTest` | `entropy.setForTest` / `entropy.resetForTest` |

The seam is installed in `framework.serveImpl` immediately after `clock.install`:
```zig
clock.install(cfg.fake_now_unix);
entropy_mod.install(cfg.fake_seed);
```

`src/config.zig` reads `ZIGBASE_FAKE_SEED` via `entropy.resolveFromEnv` and stores it
as `fake_seed: ?u64 = null`.

## Thread safety

The seeded PRNG is a mutable `std.Random.DefaultPrng` (Xoshiro256++) that advances on
every call. Multiple zap worker threads call `entropy.fill` concurrently, so the PRNG
state is guarded by a `std.atomic.Mutex` spinlock — the same pattern as
`src/ratelimit.zig` and `src/clock_sql.zig`. The critical section is tiny (one
Xoshiro256++ step per byte); spinlock contention is negligible.

## Production-unaffected guarantee (hard requirement)

`entropy.enabled` is `clock.enabled` which is `build_options.dev_clock`, a `comptime`
constant. On a release build it is `false`:

- `resolveFromEnv` returns `comptime null` — the env var is never read.
- `install` is a no-op body (`if (!enabled) return;`).
- `isActive()` is `comptime false`.
- `fill(io, buf)` compiles down to a plain `io.random(buf)` call — the seeded branch
  is comptime-dead.

Verified:
- `zig build -Doptimize=ReleaseSafe` compiles cleanly.
- `zig build test -Ddev-clock=false --summary all` passes with the prod-gate test
  (`PROD GATE: a non-dev build never activates the seeded PRNG`) running and asserting
  `isActive()` is always false.

## Files changed

| File | Change |
|---|---|
| `src/entropy.zig` | New module: the seam implementation + tests |
| `src/id.zig` | Route `io.random` call through `entropy.fill`; add determinism tests |
| `src/root.zig` | Add `_ = @import("entropy.zig");` to test-discovery block |
| `src/config.zig` | Add `fake_seed: ?u64` field; call `entropy.resolveFromEnv` in `load` |
| `src/framework.zig` | Import entropy module; call `entropy_mod.install(cfg.fake_seed)` in `serveImpl` |
| `docs/framework.md` | Add dev/test-mode section documenting both `ZIGBASE_FAKE_NOW` and `ZIGBASE_FAKE_SEED` |
| `site/src/content/docs/framework.md` | Mirror of above |
| `site/src/content/docs/configuration.md` | Add `ZIGBASE_FAKE_SEED` row alongside `ZIGBASE_FAKE_NOW` |
| `site/src/content/docs/known-limitations.md` | Update Testing section to include seeded entropy |
| `changelog.d/seeded-entropy.md` | Feature changelog fragment |

## What is NOT seeded

Explicitly out of scope (security-critical; reproducibility not requested):
- `aead.zig`: per-seal AEAD nonces (12 bytes, must be random for IND-CPA security)
- `mail/mailer.zig`: SMTP entropy
- `auth/methods/otp.zig`: OTP digits
- `auth/methods/webauthn.zig` / `api/webauthn_register.zig`: WebAuthn challenges
