# ZigBase SP5 Plan 5a: Auth Crypto Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pure, tested crypto primitives for auth: argon2id password hashing/verification, a per-record JWT signing-key derivation, and HS256 JWT sign/verify with typed claims.

**Architecture:** Two small leaf modules with no project dependencies beyond `std` (and `id.zig` for random strings): `crypto.zig` (passwords, key derivation, random tokens) and `jwt.zig` (base64url + HS256 sign/verify). `jwt.verify` takes the current time as a parameter so it stays pure and deterministically testable; the auth layer (5c) supplies "now".

**Tech Stack:** Zig 0.16.0 (mise), `std.crypto.argon2`, `std.crypto.auth.hmac.sha2.HmacSha256`, `std.base64.url_safe_no_pad`, `std.crypto.timing_safe`, `std.json`.

---

## Toolchain (read once)
Run zig via the pinned 0.16.0 toolchain from repo root: `mise exec zig@0.16.0 -- zig <args>`. Do NOT use `mise -C`. On `main`; 99 tests pass.

## Verified APIs (grounding)
- `std.crypto.argon2.strHash(password, options, out: []u8, io: std.Io) ![]const u8` — `options = .{ .allocator = alloc, .params = std.crypto.argon2.Params.interactive_2id }` (mode defaults `.argon2id`, encoding `.phc`). Writes a PHC string into `out` and returns the slice. **Needs `io` + an allocator.**
- `std.crypto.argon2.strVerify(phc, password, .{ .allocator = alloc }, io) !void` — returns void on match, errors on mismatch. **Needs `io`.**
- `std.crypto.auth.hmac.sha2.HmacSha256` — `mac_length = 32`; `HmacSha256.create(out: *[32]u8, msg: []const u8, key: []const u8) void`.
- `std.base64.url_safe_no_pad` — `.Encoder.calcSize(n) usize`, `.Encoder.encode(dest, src) []const u8`; `.Decoder.calcSizeForSlice(s) !usize`, `.Decoder.decode(dest, src) !void`.
- `std.crypto.timing_safe.eql(comptime T, a: T, b: T) bool` — constant-time compare.
- `std.json.Stringify.valueAlloc(alloc, v, .{}) ![]u8`; `std.json.parseFromSlice(T, alloc, s, .{})` — parses an enum field from its tag string.
- `src/id.zig`: `pub fn generate(io: std.Io, out: []u8) void` (fills base36) — reused for random tokens.
- **interactive_2id** params are memory-hard (~64 MiB, 2 passes) — password tests are a bit slow but correct; that's expected.

## File Structure
| File | Responsibility |
|---|---|
| `src/crypto.zig` | argon2 password hash/verify; per-record key derivation; random token strings |
| `src/jwt.zig` | base64url; `TokenType`/`Claims`/`JwtError`; HS256 `sign`/`verify(now)` |
| `src/main.zig` (modify) | test aggregator |

---

## Task 1: `crypto.zig` — passwords, key derivation, random tokens

**Files:** Create `src/crypto.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Write `src/crypto.zig`**

```zig
const std = @import("std");
const id = @import("id.zig");

const argon2 = std.crypto.argon2;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Hash a password with argon2id, returning a PHC-format string allocated from `alloc`.
pub fn hashPassword(io: std.Io, alloc: std.mem.Allocator, password: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const phc = try argon2.strHash(password, .{
        .allocator = alloc,
        .params = argon2.Params.interactive_2id,
    }, &buf, io);
    return alloc.dupe(u8, phc);
}

/// Verify a password against a PHC hash. Constant-time; returns false on any mismatch/parse error.
pub fn verifyPassword(io: std.Io, alloc: std.mem.Allocator, phc: []const u8, password: []const u8) bool {
    argon2.strVerify(phc, password, .{ .allocator = alloc }, io) catch return false;
    return true;
}

/// Per-record JWT signing key = HMAC-SHA256(app_secret, token_key). Rotating token_key
/// (on password change) changes the key, invalidating all prior tokens for that record.
pub fn deriveKey(app_secret: []const u8, token_key: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    HmacSha256.create(&out, token_key, app_secret);
    return out;
}

/// A random base36 token string of `len` chars (used for tokenKey and the CSRF value).
pub fn genToken(io: std.Io, alloc: std.mem.Allocator, len: usize) ![]u8 {
    const buf = try alloc.alloc(u8, len);
    id.generate(io, buf);
    return buf;
}

test "password hash verifies the right password and rejects the wrong one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const phc = try hashPassword(std.testing.io, a, "correct horse");
    try std.testing.expect(std.mem.startsWith(u8, phc, "$argon2id$"));
    try std.testing.expect(verifyPassword(std.testing.io, a, phc, "correct horse"));
    try std.testing.expect(!verifyPassword(std.testing.io, a, phc, "wrong password"));
}

test "deriveKey is deterministic and changes with the token key" {
    const k1 = deriveKey("app-secret", "tokkey-1");
    const k1b = deriveKey("app-secret", "tokkey-1");
    const k2 = deriveKey("app-secret", "tokkey-2");
    try std.testing.expectEqualSlices(u8, &k1, &k1b);
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "genToken produces a string of the requested length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try genToken(std.testing.io, arena.allocator(), 32);
    try std.testing.expectEqual(@as(usize, 32), t.len);
}
```

- [ ] **Step 2: Aggregate + run** — add `_ = @import("crypto.zig");` to `src/main.zig`'s `test {}`. Run `mise exec zig@0.16.0 -- zig build test` (expect 102; password tests run argon2 so the suite is a little slower). If the argon2 `HashOptions`/`Params` field names differ slightly in this std, grep `std/crypto/argon2.zig` for `HashOptions`/`Params.interactive_2id` and match; the call shape (password, options, out, io) is confirmed.

- [ ] **Step 3: Commit**
```bash
git add src/crypto.zig src/main.zig
git commit -m "feat(crypto): argon2id password hashing + per-record key derivation"
```

---

## Task 2: `jwt.zig` — HS256 sign/verify

**Files:** Create `src/jwt.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Write `src/jwt.zig`**

```zig
const std = @import("std");
const crypto = @import("crypto.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

pub const TokenType = enum { auth, verification, password_reset };

pub const Claims = struct {
    id: []const u8,
    collection: []const u8,
    type: TokenType,
    csrf: []const u8 = "",
    iat: i64,
    exp: i64,
};

pub const JwtError = error{ Malformed, BadSignature, Expired } || std.mem.Allocator.Error;

const header_b64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // base64url of {"alg":"HS256","typ":"JWT"}

fn b64enc(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, b64.Encoder.calcSize(data.len));
    _ = b64.Encoder.encode(out, data);
    return out;
}

fn b64dec(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, try b64.Decoder.calcSizeForSlice(s));
    try b64.Decoder.decode(out, s);
    return out;
}

/// Produce a compact JWS (header.payload.signature), HS256-signed with `key`.
pub fn sign(alloc: std.mem.Allocator, claims: Claims, key: []const u8) ![]u8 {
    const payload_json = try std.json.Stringify.valueAlloc(alloc, claims, .{});
    const p = try b64enc(alloc, payload_json);
    const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ header_b64, p });
    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, signing_input, key);
    const s = try b64enc(alloc, &sig);
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ signing_input, s });
}

/// Verify signature + expiry (against `now`, unix seconds) and return the claims.
pub fn verify(alloc: std.mem.Allocator, token: []const u8, key: []const u8, now: i64) JwtError!Claims {
    var it = std.mem.splitScalar(u8, token, '.');
    const h = it.next() orelse return error.Malformed;
    const p = it.next() orelse return error.Malformed;
    const s = it.next() orelse return error.Malformed;
    if (it.next() != null) return error.Malformed;

    const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ h, p });
    var expected: [32]u8 = undefined;
    HmacSha256.create(&expected, signing_input, key);

    const provided = b64dec(alloc, s) catch return error.Malformed;
    if (provided.len != 32) return error.BadSignature;
    if (!std.crypto.timing_safe.eql([32]u8, expected, provided[0..32].*)) return error.BadSignature;

    const payload_json = b64dec(alloc, p) catch return error.Malformed;
    const parsed = std.json.parseFromSlice(Claims, alloc, payload_json, .{}) catch return error.Malformed;
    const claims = parsed.value;
    if (claims.exp <= now) return error.Expired;
    return claims;
}

test "sign then verify round-trips claims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .csrf = "c1", .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    const out = try verify(a, token, &key, 1500);
    try std.testing.expectEqualStrings("u1", out.id);
    try std.testing.expectEqualStrings("users", out.collection);
    try std.testing.expectEqual(TokenType.auth, out.type);
    try std.testing.expectEqualStrings("c1", out.csrf);
}

test "tampered payload fails the signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    // flip a character in the payload segment
    const buf = try a.dupe(u8, token);
    const dot = std.mem.indexOfScalar(u8, buf, '.').?;
    buf[dot + 1] = if (buf[dot + 1] == 'A') 'B' else 'A';
    try std.testing.expectError(error.BadSignature, verify(a, buf, &key, 1500));
}

test "expired token is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    try std.testing.expectError(error.Expired, verify(a, token, &key, 2000)); // exp <= now
}

test "a token signed with a rotated tokenKey no longer verifies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old_key = crypto.deriveKey("secret", "tk-old");
    const new_key = crypto.deriveKey("secret", "tk-new");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &old_key);
    try std.testing.expectError(error.BadSignature, verify(a, token, &new_key, 1500));
}

test "malformed token shapes are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    try std.testing.expectError(error.Malformed, verify(a, "not-a-jwt", &key, 0));
    try std.testing.expectError(error.Malformed, verify(a, "only.two", &key, 0));
}
```

- [ ] **Step 2: Aggregate + run** — add `_ = @import("jwt.zig");` to `src/main.zig`'s `test {}`. Run `mise exec zig@0.16.0 -- zig build test` (expect 108). If `b64.Encoder.encode`'s return type differs (some versions return `void`, others the slice), adjust the `_ =` accordingly. If `header_b64` doesn't decode to the expected header, recompute it: it must be the unpadded base64url of exactly `{"alg":"HS256","typ":"JWT"}` (you can verify by decoding it in a throwaway test). The signature only covers `header_b64.payload`, so as long as sign and verify use the same `header_b64` constant, correctness holds regardless.

- [ ] **Step 3: Commit**
```bash
git add src/jwt.zig src/main.zig
git commit -m "feat(jwt): HS256 sign/verify with typed claims and expiry"
```

---

## Self-Review (completed by plan author)

**Spec coverage (SP5 design §2 Crypto):**
- argon2id `hashPassword`/`verifyPassword` (constant-time) → Task 1 ✓
- `deriveKey` per-record signing key (`HMAC(app_secret, tokenKey)`) → Task 1 ✓
- `genToken` for tokenKey/csrf → Task 1 ✓
- JWT HS256 `sign`/`verify` with `TokenType`/`Claims`/`JwtError`, base64url, expiry → Task 2 ✓
- Token-invalidation-on-tokenKey-rotation → Task 2 test ✓
- **Deferred to 5b/5c (intentional):** obtaining "now" (passed into `verify`), the app secret wiring, and all DB/endpoint use — 5a is pure primitives only.

**Type consistency:** `crypto.{hashPassword,verifyPassword,deriveKey,genToken}` (hash/verify take `io`+`alloc`; deriveKey returns `[32]u8`); `jwt.{TokenType,Claims,JwtError,sign,verify}` (`verify` takes `key: []const u8` + `now: i64`; `sign`/`verify` use the shared `header_b64`). `deriveKey` returns `[32]u8` and is passed to `sign`/`verify` as `&key` (a `[]const u8`). Consistent.

**Placeholder scan:** both tasks contain complete code. The only flagged uncertainties (argon2 `HashOptions` field spelling, `b64.Encoder.encode` return type, the `header_b64` constant) have concrete fallback instructions, and the security-critical properties are pinned by tests (verify rejects wrong password, tampered token, expired token, rotated-key token, and malformed shapes).
