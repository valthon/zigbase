# OAuth2 Foundation (Plan 6a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the non-endpoint foundation for ZigBase OAuth2 — the `_externalAuths` table, AES-256-GCM secret encryption, the provider preset registry + identity mapping, the per-collection `oauth2` options (persisted full, redacted in API output), and an injectable `Transport` seam with `exchangeCode`/`fetchIdentity` exercised against a stub — all unit-tested, no HTTP endpoints yet.

**Architecture:** New `src/oauth/` package (`secrets.zig`, `providers.zig`, `client.zig`) plus a migration and `schema.zig` options. Identity is read from the provider's userinfo endpoint (no `id_token`/RSA). The outbound HTTP call goes through a `Transport` interface so the whole exchange/identity path is testable with canned responses; the real `std.http.Client` transport lands in Plan 6b.

**Tech Stack:** Zig 0.16.0 (run via `mise exec zig@0.16.0 -- zig <args>` from the repo root — bare `zig` is 0.15.2). std-only crypto: `std.crypto.aead.aes_gcm.Aes256Gcm`, `std.crypto.kdf.hkdf.HkdfSha256`, `std.base64.url_safe_no_pad`. Entropy via `io.random(&buf)` (Io-based; `std.crypto.random` does not exist in 0.16). Vendored SQLite.

**Build/test command (from repo root):** `mise exec zig@0.16.0 -- zig build test --summary all`

**Branch:** Create and work on branch `oauth2`. SP6 merges as a unit (6a+6b) after a holistic review at the end of 6b. Do NOT merge to `main` in this plan.

**Spec:** `docs/superpowers/specs/2026-06-09-oauth2-design.md`.

---

## Verified API facts (Zig 0.16.0 — do not re-derive)

- **AES-256-GCM:** `const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;` with `key_length=32`, `nonce_length=12`, `tag_length=16`.
  - `Aes256Gcm.encrypt(ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, ad: []const u8, npub: [12]u8, key: [32]u8) void` — arg order is `(c, tag, m, ad, npub, key)`; `ciphertext.len == plaintext.len`.
  - `Aes256Gcm.decrypt(plaintext: []u8, ciphertext: []const u8, tag: [16]u8, ad: []const u8, npub: [12]u8, key: [32]u8) error{AuthenticationFailed}!void`.
- **HKDF-SHA256:** `const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;` → `const prk = HkdfSha256.extract(salt, ikm);` then `var okm: [32]u8 = undefined; HkdfSha256.expand(&okm, info, prk);` (salt/ikm/info are `[]const u8`).
- **Base64url (no pad):** `const b64 = std.base64.url_safe_no_pad;` → `b64.Encoder.calcSize(n)`, `b64.Encoder.encode(dest, src)`, `b64.Decoder.calcSizeForSlice(s) !usize`, `b64.Decoder.decode(dest, src) !void`.
- **Entropy:** `io.random(&buf)` fills `buf: []u8` with random bytes (`io: std.Io`). The project's `id.zig` uses exactly this.
- **Unmanaged collections idioms:** `var list: std.ArrayList(T) = .empty;` then `try list.append(alloc, x);` / `try list.toOwnedSlice(alloc);`. `var m: std.json.ObjectMap = .empty;` then `try m.put(alloc, k, v);`. `var arr = std.json.Array.init(alloc); try arr.append(v);`. Serialize with `std.json.Stringify.valueAlloc(alloc, value, .{})`.
- **Migrations:** add an entry to `migrations.all` and an `init_NNNN(w: *db.Db) db.DbError!void` that runs `try w.exec("...")`. `Db.exec` takes `[:0]const u8` (string literals coerce). Constraint violations surface as `error.ExecFailed`.

---

## File Structure

- **Modify** `src/migrations.zig` — add migration `0003_external_auths` (`_externalAuths` table + 2 unique indexes).
- **Create** `src/oauth/secrets.zig` — `encryptSecret`/`decryptSecret`/`isEncrypted` (AES-256-GCM; key = HKDF(app_secret)).
- **Create** `src/oauth/providers.zig` — `Provider`, `ProviderMapping`, `Identity` types; preset registry (google/github/microsoft/discord); `lookup`, `extractIdentity`.
- **Modify** `src/schema.zig` — `OAuth2Provider` type + `AuthOptions.oauth2`; extend `optionsToJson` (add `redact: bool`) and `optionsFromJson`; redact `clientSecret` in API output.
- **Modify** `src/collections.zig` — pass `redact=false` at the two `optionsToJson` persist call sites.
- **Create** `src/oauth/client.zig` — `Transport` interface + `exchangeCode`/`fetchIdentity`; a `StubTransport` for tests.
- **Modify** `src/main.zig` — add the new modules to the `test { _ = @import(...); }` root so their tests run.

---

### Task 0: Branch setup

- [ ] **Step 1: Create the branch**

```bash
cd /home/valthon/nothlav/zigbase
git checkout main
git checkout -b oauth2
git status
```
Expected: on branch `oauth2`, clean tree.

---

### Task 1: `_externalAuths` migration (0003)

**Files:**
- Modify: `src/migrations.zig`

- [ ] **Step 1: Write the failing test** (append to `src/migrations.zig` tests)

```zig
test "0003 creates _externalAuths with unique provider/providerId and per-record indexes" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    // table exists
    var t = try d.prepare("SELECT COUNT(*) FROM pragma_table_info('_externalAuths');");
    defer t.finalize();
    _ = try t.step();
    try std.testing.expect(t.columnInt(0) >= 7); // id,collectionRef,recordRef,provider,providerId,created,updated
    // (provider, providerId) is unique
    try d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e1','users','r1','google','G1','','');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e2','users','r2','google','G1','','');"));
    // a record links a given provider at most once
    try d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e3','users','r1','github','H1','','');");
    try std.testing.expectError(error.ExecFailed, d.exec("INSERT INTO \"_externalAuths\" (\"id\",\"collectionRef\",\"recordRef\",\"provider\",\"providerId\",\"created\",\"updated\") VALUES ('e4','users','r1','github','H2','','');"));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — no `_externalAuths` table (the pragma count is 0).

- [ ] **Step 3: Add the migration to `src/migrations.zig`**

Add the function (after `init_0002`):

```zig
fn init_0003(w: *db.Db) db.DbError!void {
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_externalAuths" (
        \\  "id" TEXT PRIMARY KEY, "collectionRef" TEXT NOT NULL, "recordRef" TEXT NOT NULL,
        \\  "provider" TEXT NOT NULL, "providerId" TEXT NOT NULL,
        \\  "created" TEXT NOT NULL, "updated" TEXT NOT NULL
        \\);
    );
    try w.exec("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_extauth_provider_pid\" ON \"_externalAuths\" (\"provider\",\"providerId\");");
    try w.exec("CREATE UNIQUE INDEX IF NOT EXISTS \"idx_extauth_rec_provider\" ON \"_externalAuths\" (\"collectionRef\",\"recordRef\",\"provider\");");
}
```

Add it to the `all` array (after `0002_auth`):

```zig
pub const all = [_]Migration{
    .{ .name = "0001_init", .up = init_0001 },
    .{ .name = "0002_auth", .up = init_0002 },
    .{ .name = "0003_external_auths", .up = init_0003 },
};
```

Note: the existing `"migrations apply once and are idempotent"` test asserts `all.len` migrations were recorded; it reads `all.len` dynamically, so it stays correct.

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/migrations.zig
git commit -m "feat(oauth): _externalAuths table (migration 0003)"
```

---

### Task 2: Secret encryption (`oauth/secrets.zig`)

**Files:**
- Create: `src/oauth/secrets.zig`
- Modify: `src/main.zig` (test root)

Storage format: `"v1:" ++ base64url(nonce[12] ‖ ciphertext ‖ tag[16])`. The `"v1:"` prefix marks an encrypted blob (so the API layer can skip re-encrypting an already-encrypted secret in Plan 6b).

- [ ] **Step 1: Write the failing tests** — create `src/oauth/secrets.zig` with ONLY the tests first (so they fail to compile), then add the impl in Step 3. Put this whole file in place but with the functions unimplemented is awkward in Zig; instead, write the full file in Step 3 and the tests below are part of it. For TDD, first create the file containing just the tests referencing the not-yet-written functions:

```zig
const std = @import("std");

test "encrypt then decrypt round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try encryptSecret(std.testing.io, a, "app-secret", "my-client-secret");
    try std.testing.expect(std.mem.startsWith(u8, blob, "v1:"));
    try std.testing.expect(isEncrypted(blob));
    const pt = try decryptSecret(a, "app-secret", blob);
    try std.testing.expectEqualStrings("my-client-secret", pt);
}

test "wrong app secret fails authentication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try encryptSecret(std.testing.io, a, "app-secret", "s3cr3t");
    try std.testing.expectError(error.BadSecret, decryptSecret(a, "other-secret", blob));
}

test "tampered blob fails authentication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try encryptSecret(std.testing.io, a, "app-secret", "s3cr3t");
    const buf = try a.dupe(u8, blob);
    buf[buf.len - 1] = if (buf[buf.len - 1] == 'A') 'B' else 'A';
    try std.testing.expectError(error.BadSecret, decryptSecret(a, "app-secret", buf));
}

test "isEncrypted distinguishes plaintext from blobs; decrypt rejects non-blob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!isEncrypted("plaintext-secret"));
    try std.testing.expectError(error.BadSecret, decryptSecret(a, "app-secret", "plaintext-secret"));
}

test "empty plaintext round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try encryptSecret(std.testing.io, a, "app-secret", "");
    try std.testing.expectEqualStrings("", try decryptSecret(a, "app-secret", blob));
}
```

Also register the module in `src/main.zig` test root — add `_ = @import("oauth/secrets.zig");` to the `test { ... }` block near the bottom.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `encryptSecret`/`decryptSecret`/`isEncrypted` undefined.

- [ ] **Step 3: Implement — prepend this to `src/oauth/secrets.zig`** (above the tests)

```zig
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const b64 = std.base64.url_safe_no_pad;

pub const SecretError = error{BadSecret} || std.mem.Allocator.Error;

const PREFIX = "v1:";

/// Derive the 32-byte AES key from the app secret (domain-separated).
fn deriveKey(app_secret: []const u8) [32]u8 {
    const prk = HkdfSha256.extract("", app_secret);
    var key: [32]u8 = undefined;
    HkdfSha256.expand(&key, "zigbase-oauth-secret-v1", prk);
    return key;
}

/// True if `blob` is an encrypted secret (has the version prefix).
pub fn isEncrypted(blob: []const u8) bool {
    return std.mem.startsWith(u8, blob, PREFIX);
}

/// Encrypt `plaintext` -> "v1:" ++ base64url(nonce ‖ ciphertext ‖ tag). `io` supplies the nonce.
pub fn encryptSecret(io: std.Io, alloc: std.mem.Allocator, app_secret: []const u8, plaintext: []const u8) ![]u8 {
    const key = deriveKey(app_secret);
    var nonce: [12]u8 = undefined;
    io.random(&nonce);
    const ct = try alloc.alloc(u8, plaintext.len);
    var tag: [16]u8 = undefined;
    Aes256Gcm.encrypt(ct, &tag, plaintext, "", nonce, key);

    const raw = try alloc.alloc(u8, 12 + ct.len + 16);
    @memcpy(raw[0..12], &nonce);
    @memcpy(raw[12 .. 12 + ct.len], ct);
    @memcpy(raw[12 + ct.len ..], &tag);

    const enc = try alloc.alloc(u8, b64.Encoder.calcSize(raw.len));
    _ = b64.Encoder.encode(enc, raw);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ PREFIX, enc });
}

/// Decrypt a "v1:"-prefixed blob. Any tamper / wrong key / non-blob -> error.BadSecret.
pub fn decryptSecret(alloc: std.mem.Allocator, app_secret: []const u8, blob: []const u8) SecretError![]u8 {
    if (!isEncrypted(blob)) return error.BadSecret;
    const enc = blob[PREFIX.len..];
    const raw_len = b64.Decoder.calcSizeForSlice(enc) catch return error.BadSecret;
    if (raw_len < 12 + 16) return error.BadSecret;
    const raw = try alloc.alloc(u8, raw_len);
    b64.Decoder.decode(raw, enc) catch return error.BadSecret;

    const ct_len = raw_len - 12 - 16;
    const nonce: [12]u8 = raw[0..12].*;
    const ct = raw[12 .. 12 + ct_len];
    const tag: [16]u8 = raw[12 + ct_len ..][0..16].*;
    const key = deriveKey(app_secret);

    const pt = try alloc.alloc(u8, ct_len);
    Aes256Gcm.decrypt(pt, ct, tag, "", nonce, key) catch return error.BadSecret;
    return pt;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (5 new tests).

- [ ] **Step 5: Commit**

```bash
git add src/oauth/secrets.zig src/main.zig
git commit -m "feat(oauth): AES-256-GCM client_secret encryption"
```

---

### Task 3: Provider registry + identity mapping (`oauth/providers.zig`)

**Files:**
- Create: `src/oauth/providers.zig`
- Modify: `src/main.zig` (test root)

- [ ] **Step 1: Write the failing tests** — create `src/oauth/providers.zig` with the tests first:

```zig
const std = @import("std");

test "lookup returns presets and null for unknown" {
    try std.testing.expect(lookup("google") != null);
    try std.testing.expect(lookup("github") != null);
    try std.testing.expect(lookup("microsoft") != null);
    try std.testing.expect(lookup("discord") != null);
    try std.testing.expect(lookup("nope") == null);
    const g = lookup("google").?;
    try std.testing.expectEqualStrings("https://oauth2.googleapis.com/token", g.tokenURL);
    try std.testing.expectEqualStrings("sub", g.mapping.id);
}

test "extractIdentity reads google-shaped userinfo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"sub":"123","email":"u@x.io","email_verified":true,"name":"U","picture":"http://p"}
    ;
    const id = try extractIdentity(a, lookup("google").?, json);
    try std.testing.expectEqualStrings("123", id.providerUserId);
    try std.testing.expectEqualStrings("u@x.io", id.email.?);
    try std.testing.expectEqual(true, id.emailVerified);
    try std.testing.expectEqualStrings("U", id.name.?);
}

test "extractIdentity reads github-shaped userinfo (numeric id, no email_verified)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"id":456,"login":"octo","email":"o@x.io","avatar_url":"http://a"}
    ;
    const id = try extractIdentity(a, lookup("github").?, json);
    try std.testing.expectEqualStrings("456", id.providerUserId); // numeric coerced to string
    try std.testing.expectEqualStrings("o@x.io", id.email.?);
    try std.testing.expectEqual(false, id.emailVerified); // github userinfo has no email_verified -> false
}

test "extractIdentity fails when the id field is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NoProviderId, extractIdentity(a, lookup("google").?, "{\"email\":\"x@y.z\"}"));
}
```

Register in `src/main.zig` test root: add `_ = @import("oauth/providers.zig");`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `lookup`/`extractIdentity`/types undefined.

- [ ] **Step 3: Implement — prepend to `src/oauth/providers.zig`**

```zig
pub const ProviderMapping = struct {
    id: []const u8,
    email: ?[]const u8 = null,
    emailVerified: ?[]const u8 = null,
    name: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
};

pub const Provider = struct {
    name: []const u8,
    authURL: []const u8,
    tokenURL: []const u8,
    userinfoURL: []const u8,
    scopes: []const []const u8,
    mapping: ProviderMapping,
};

pub const Identity = struct {
    providerUserId: []const u8,
    email: ?[]const u8 = null,
    emailVerified: bool = false,
    name: ?[]const u8 = null,
    avatarUrl: ?[]const u8 = null,
};

pub const ExtractError = error{NoProviderId} || std.mem.Allocator.Error || error{InvalidJson};

const presets = [_]Provider{
    .{
        .name = "google",
        .authURL = "https://accounts.google.com/o/oauth2/v2/auth",
        .tokenURL = "https://oauth2.googleapis.com/token",
        .userinfoURL = "https://openidconnect.googleapis.com/v1/userinfo",
        .scopes = &.{ "openid", "email", "profile" },
        .mapping = .{ .id = "sub", .email = "email", .emailVerified = "email_verified", .name = "name", .avatar = "picture" },
    },
    .{
        .name = "github",
        .authURL = "https://github.com/login/oauth/authorize",
        .tokenURL = "https://github.com/login/oauth/access_token",
        .userinfoURL = "https://api.github.com/user",
        .scopes = &.{ "read:user", "user:email" },
        .mapping = .{ .id = "id", .email = "email", .emailVerified = null, .name = "name", .avatar = "avatar_url" },
    },
    .{
        .name = "microsoft",
        .authURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        .tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        .userinfoURL = "https://graph.microsoft.com/oidc/userinfo",
        .scopes = &.{ "openid", "email", "profile" },
        .mapping = .{ .id = "sub", .email = "email", .emailVerified = "email_verified", .name = "name", .avatar = null },
    },
    .{
        .name = "discord",
        .authURL = "https://discord.com/api/oauth2/authorize",
        .tokenURL = "https://discord.com/api/oauth2/token",
        .userinfoURL = "https://discord.com/api/users/@me",
        .scopes = &.{ "identify", "email" },
        .mapping = .{ .id = "id", .email = "email", .emailVerified = "verified", .name = "username", .avatar = "avatar" },
    },
};

/// Look up a built-in preset by name. Returns null for an unknown name.
pub fn lookup(name: []const u8) ?Provider {
    for (presets) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// Coerce a JSON value to an allocated string. Strings pass through; integers are formatted;
/// bools render "true"/"false"; everything else -> null.
fn jsonToStr(alloc: std.mem.Allocator, v: std.json.Value) !?[]const u8 {
    return switch (v) {
        .string => |s| try alloc.dupe(u8, s),
        .integer => |n| try std.fmt.allocPrint(alloc, "{d}", .{n}),
        .bool => |b| try alloc.dupe(u8, if (b) "true" else "false"),
        else => null,
    };
}

fn jsonToBool(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
        else => false,
    };
}

/// Extract a normalized Identity from a userinfo JSON document using `provider.mapping`.
pub fn extractIdentity(alloc: std.mem.Allocator, provider: Provider, json: []const u8) ExtractError!Identity {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return error.InvalidJson;
    const root = parsed.value;
    if (root != .object) return error.InvalidJson;
    const obj = root.object;

    const id_val = obj.get(provider.mapping.id) orelse return error.NoProviderId;
    const pid = (try jsonToStr(alloc, id_val)) orelse return error.NoProviderId;

    var out = Identity{ .providerUserId = pid };
    if (provider.mapping.email) |k| if (obj.get(k)) |v| {
        out.email = try jsonToStr(alloc, v);
    };
    if (provider.mapping.emailVerified) |k| if (obj.get(k)) |v| {
        out.emailVerified = jsonToBool(v);
    };
    if (provider.mapping.name) |k| if (obj.get(k)) |v| {
        out.name = try jsonToStr(alloc, v);
    };
    if (provider.mapping.avatar) |k| if (obj.get(k)) |v| {
        out.avatarUrl = try jsonToStr(alloc, v);
    };
    return out;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (4 new tests).

- [ ] **Step 5: Commit**

```bash
git add src/oauth/providers.zig src/main.zig
git commit -m "feat(oauth): provider preset registry + identity mapping"
```

---

### Task 4: Per-collection `oauth2` options (`schema.zig`, `collections.zig`)

**Files:**
- Modify: `src/schema.zig` (`AuthOptions`, `OAuth2Provider`, `optionsToJson`, `optionsFromJson`)
- Modify: `src/collections.zig` (two `optionsToJson` call sites)

The stored secret is carried verbatim by `optionsToJson`/`optionsFromJson` (encryption happens in the API layer in Plan 6b). API output (`collectionToJson`) must **redact** `clientSecret`. We add a `redact: bool` parameter to `optionsToJson`: persist call sites pass `false`; `collectionToJson` passes `true`.

- [ ] **Step 1: Write the failing tests** (append to `src/schema.zig` tests)

```zig
test "oauth2 options round-trip through optionsToJson(false)/optionsFromJson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = [_]OAuth2Provider{.{ .name = "google", .clientId = "cid", .clientSecret = "v1:blob", .enabled = true, .redirectUrls = &.{"https://app/cb"} }};
    const c = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &providers } } } };
    const s = try optionsToJson(a, c, false);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"clientSecret\":\"v1:blob\"") != null); // persisted form keeps the secret
    const back = try optionsFromJson(a, s);
    try std.testing.expectEqual(true, back.auth.oauth2.enabled);
    try std.testing.expectEqual(@as(usize, 1), back.auth.oauth2.providers.len);
    try std.testing.expectEqualStrings("cid", back.auth.oauth2.providers[0].clientId);
    try std.testing.expectEqualStrings("v1:blob", back.auth.oauth2.providers[0].clientSecret);
    try std.testing.expectEqualStrings("https://app/cb", back.auth.oauth2.providers[0].redirectUrls[0]);
}

test "optionsToJson(true) redacts clientSecret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = [_]OAuth2Provider{.{ .name = "google", .clientId = "cid", .clientSecret = "v1:blob", .redirectUrls = &.{} }};
    const c = Collection{ .id = "c", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &providers } } } };
    const s = try optionsToJson(a, c, true);
    try std.testing.expect(std.mem.indexOf(u8, s, "v1:blob") == null); // secret never present
    try std.testing.expect(std.mem.indexOf(u8, s, "\"clientSecret\":\"\"") != null); // redacted to ""
    try std.testing.expect(std.mem.indexOf(u8, s, "\"clientId\":\"cid\"") != null); // non-secret kept
}

test "collectionToJson redacts oauth2 clientSecret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = [_]OAuth2Provider{.{ .name = "google", .clientId = "cid", .clientSecret = "v1:topsecret", .redirectUrls = &.{} }};
    const c = Collection{ .id = "id1", .name = "users", .type = .auth, .fields = &.{}, .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &providers } } } };
    const out = try collectionToJson(a, c);
    try std.testing.expect(std.mem.indexOf(u8, out, "topsecret") == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `OAuth2Provider` undefined; `optionsToJson` arity mismatch.

- [ ] **Step 3: Add the types in `src/schema.zig`** — replace the `AuthOptions` struct and add `OAuth2Provider`/`OAuth2Options` above it:

```zig
pub const OAuth2Provider = struct {
    name: []const u8,
    clientId: []const u8 = "",
    clientSecret: []const u8 = "", // persisted as a "v1:" AES-GCM blob; redacted in API output
    enabled: bool = true,
    redirectUrls: []const []const u8 = &.{},
    // generic-provider overrides (ignored for presets):
    authURL: ?[]const u8 = null,
    tokenURL: ?[]const u8 = null,
    userinfoURL: ?[]const u8 = null,
    scopes: ?[]const []const u8 = null,
};

pub const OAuth2Options = struct {
    enabled: bool = false,
    providers: []const OAuth2Provider = &.{},
};

pub const AuthOptions = struct {
    identityFields: []const []const u8 = &.{"email"},
    minPasswordLength: u8 = 8,
    oauth2: OAuth2Options = .{},
};
```

(Note: `ProviderMapping` for generic providers is deferred to Plan 6b where generic providers are actually exercised end-to-end; presets cover 6a. Do not add a `mapping` field here yet — YAGNI.)

- [ ] **Step 4: Extend `optionsToJson`** — change its signature to take `redact: bool` and emit `oauth2`. Replace the function body:

```zig
pub fn optionsToJson(alloc: std.mem.Allocator, c: Collection, redact: bool) ![]u8 {
    var root: ObjectMap = .empty;
    var auth: ObjectMap = .empty;
    var ids = std.json.Array.init(alloc);
    for (c.options.auth.identityFields) |f| try ids.append(.{ .string = f });
    try auth.put(alloc, "identityFields", .{ .array = ids });
    try auth.put(alloc, "minPasswordLength", .{ .integer = c.options.auth.minPasswordLength });

    var oauth2: ObjectMap = .empty;
    try oauth2.put(alloc, "enabled", .{ .bool = c.options.auth.oauth2.enabled });
    var provs = std.json.Array.init(alloc);
    for (c.options.auth.oauth2.providers) |p| {
        var po: ObjectMap = .empty;
        try po.put(alloc, "name", .{ .string = p.name });
        try po.put(alloc, "clientId", .{ .string = p.clientId });
        try po.put(alloc, "clientSecret", .{ .string = if (redact) "" else p.clientSecret });
        try po.put(alloc, "enabled", .{ .bool = p.enabled });
        var rus = std.json.Array.init(alloc);
        for (p.redirectUrls) |u| try rus.append(.{ .string = u });
        try po.put(alloc, "redirectUrls", .{ .array = rus });
        if (p.authURL) |u| try po.put(alloc, "authURL", .{ .string = u });
        if (p.tokenURL) |u| try po.put(alloc, "tokenURL", .{ .string = u });
        if (p.userinfoURL) |u| try po.put(alloc, "userinfoURL", .{ .string = u });
        if (p.scopes) |sc| {
            var sa = std.json.Array.init(alloc);
            for (sc) |s| try sa.append(.{ .string = s });
            try po.put(alloc, "scopes", .{ .array = sa });
        }
        try provs.append(.{ .object = po });
    }
    try oauth2.put(alloc, "providers", .{ .array = provs });
    try auth.put(alloc, "oauth2", .{ .object = oauth2 });

    try root.put(alloc, "auth", .{ .object = auth });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
}
```

- [ ] **Step 5: Extend `optionsFromJson`** — parse `oauth2`. Add, after the `minPasswordLength` block and before `return opts;`:

```zig
    if (av.object.get("oauth2")) |ov| if (ov == .object) {
        opts.auth.oauth2.enabled = if (ov.object.get("enabled")) |ev| (ev == .bool and ev.bool) else false;
        if (ov.object.get("providers")) |pv| if (pv == .array) {
            var list: std.ArrayList(OAuth2Provider) = .empty;
            for (pv.array.items) |it| {
                if (it != .object) continue;
                const o = it.object;
                var p = OAuth2Provider{ .name = "" };
                if (o.get("name")) |x| if (x == .string) { p.name = try alloc.dupe(u8, x.string); };
                if (o.get("clientId")) |x| if (x == .string) { p.clientId = try alloc.dupe(u8, x.string); };
                if (o.get("clientSecret")) |x| if (x == .string) { p.clientSecret = try alloc.dupe(u8, x.string); };
                if (o.get("enabled")) |x| if (x == .bool) { p.enabled = x.bool; };
                if (o.get("redirectUrls")) |x| if (x == .array) {
                    var rl: std.ArrayList([]const u8) = .empty;
                    for (x.array.items) |ru| if (ru == .string) try rl.append(alloc, try alloc.dupe(u8, ru.string));
                    p.redirectUrls = try rl.toOwnedSlice(alloc);
                };
                if (o.get("authURL")) |x| if (x == .string) { p.authURL = try alloc.dupe(u8, x.string); };
                if (o.get("tokenURL")) |x| if (x == .string) { p.tokenURL = try alloc.dupe(u8, x.string); };
                if (o.get("userinfoURL")) |x| if (x == .string) { p.userinfoURL = try alloc.dupe(u8, x.string); };
                if (o.get("scopes")) |x| if (x == .array) {
                    var sl: std.ArrayList([]const u8) = .empty;
                    for (x.array.items) |sc| if (sc == .string) try sl.append(alloc, try alloc.dupe(u8, sc.string));
                    p.scopes = try sl.toOwnedSlice(alloc);
                };
                try list.append(alloc, p);
            }
            opts.auth.oauth2.providers = try list.toOwnedSlice(alloc);
        };
    };
```

- [ ] **Step 6: Update the `optionsToJson` callers** — fix the arity at three sites.
  - In `src/schema.zig` `collectionToJson` (the line `const oparsed = try std.json.parseFromSlice(... try optionsToJson(alloc, c), .{});`): change to `try optionsToJson(alloc, c, true)`.
  - In `src/collections.zig` line ~95 (`insertRow`): change `schema.optionsToJson(alloc, col)` → `schema.optionsToJson(alloc, col, false)`.
  - In `src/collections.zig` line ~227 (`updateRow`): change `schema.optionsToJson(alloc, col)` → `schema.optionsToJson(alloc, col, false)`.
  - If any existing schema test calls `optionsToJson(a, c)` with two args (the pre-existing `optionsToJson`/`optionsFromJson` round-trip test), update it to pass `false`.

- [ ] **Step 7: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (3 new tests + existing options/round-trip tests still green).

- [ ] **Step 8: Commit**

```bash
git add src/schema.zig src/collections.zig
git commit -m "feat(oauth): per-collection oauth2 options (persist full, redact in API output)"
```

---

### Task 5: Outbound `Transport` seam + `exchangeCode`/`fetchIdentity` (`oauth/client.zig`)

**Files:**
- Create: `src/oauth/client.zig`
- Modify: `src/main.zig` (test root)

This task adds the abstraction and the two functions, tested against a **stub** transport. The real `std.http.Client`-backed transport is added in Plan 6b.

- [ ] **Step 1: Write the failing tests** — create `src/oauth/client.zig` with the tests first:

```zig
const std = @import("std");
const providers = @import("providers.zig");

// A stub transport that returns canned responses keyed by URL substring.
const StubTransport = struct {
    token_status: u16 = 200,
    token_body: []const u8 = "{\"access_token\":\"AT123\",\"token_type\":\"bearer\"}",
    userinfo_status: u16 = 200,
    userinfo_body: []const u8 = "{\"sub\":\"P1\",\"email\":\"u@x.io\",\"email_verified\":true}",

    fn call(ctx: *anyopaque, alloc: std.mem.Allocator, method: Method, url: []const u8, headers: []const Header, body: ?[]const u8) TransportError!Response {
        _ = method;
        _ = headers;
        _ = body;
        const self: *StubTransport = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, url, "token") != null)
            return .{ .status = self.token_status, .body = try alloc.dupe(u8, self.token_body) };
        return .{ .status = self.userinfo_status, .body = try alloc.dupe(u8, self.userinfo_body) };
    }

    fn transport(self: *StubTransport) Transport {
        return .{ .ctx = self, .call = call };
    }
};

test "exchangeCode returns the access token on 200" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stub = StubTransport{};
    const tok = try exchangeCode(stub.transport(), a, providers.lookup("google").?, "cid", "secret", "code", "verifier", "https://app/cb");
    try std.testing.expectEqualStrings("AT123", tok);
}

test "exchangeCode fails on a non-2xx token response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stub = StubTransport{ .token_status = 400, .token_body = "{\"error\":\"invalid_grant\"}" };
    try std.testing.expectError(error.ProviderError, exchangeCode(stub.transport(), a, providers.lookup("google").?, "cid", "secret", "code", "verifier", "https://app/cb"));
}

test "fetchIdentity returns a normalized identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stub = StubTransport{};
    const id = try fetchIdentity(stub.transport(), a, providers.lookup("google").?, "AT123");
    try std.testing.expectEqualStrings("P1", id.providerUserId);
    try std.testing.expectEqualStrings("u@x.io", id.email.?);
    try std.testing.expectEqual(true, id.emailVerified);
}

test "fetchIdentity fails on a non-2xx userinfo response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stub = StubTransport{ .userinfo_status = 401, .userinfo_body = "unauthorized" };
    try std.testing.expectError(error.ProviderError, fetchIdentity(stub.transport(), a, providers.lookup("google").?, "AT"));
}
```

Register in `src/main.zig` test root: add `_ = @import("oauth/client.zig");`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `Transport`/`exchangeCode`/`fetchIdentity`/`Method`/`Header`/`Response`/`TransportError` undefined.

- [ ] **Step 3: Implement — prepend to `src/oauth/client.zig`** (above the tests; keep the `const std`/`const providers` lines at the very top)

```zig
pub const Method = enum { GET, POST };
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Response = struct { status: u16, body: []const u8 };

pub const TransportError = error{ TransportFailed, ResponseTooLarge } || std.mem.Allocator.Error;

/// Injectable HTTP transport. Production wraps std.http.Client (Plan 6b); tests inject a stub.
pub const Transport = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, method: Method, url: []const u8, headers: []const Header, body: ?[]const u8) TransportError!Response,
};

pub const ClientError = error{ ProviderError, InvalidResponse } || TransportError || providers.ExtractError;

fn is2xx(status: u16) bool {
    return status >= 200 and status < 300;
}

/// URL-encode `s` into `out` (RFC 3986 unreserved kept; everything else %XX). Returns the slice written.
fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        const unreserved = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(alloc, ch);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[ch >> 4]);
            try out.append(alloc, hex[ch & 0x0f]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Exchange an authorization code for an access token (form-encoded POST to tokenURL).
pub fn exchangeCode(
    transport: Transport,
    alloc: std.mem.Allocator,
    provider: providers.Provider,
    client_id: []const u8,
    client_secret: []const u8,
    code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
) ClientError![]const u8 {
    const body = try std.fmt.allocPrint(alloc, "grant_type=authorization_code&code={s}&redirect_uri={s}&code_verifier={s}&client_id={s}&client_secret={s}", .{
        try urlEncode(alloc, code),
        try urlEncode(alloc, redirect_uri),
        try urlEncode(alloc, code_verifier),
        try urlEncode(alloc, client_id),
        try urlEncode(alloc, client_secret),
    });
    const headers = [_]Header{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "accept", .value = "application/json" },
    };
    const resp = try transport.call(transport.ctx, alloc, .POST, provider.tokenURL, &headers, body);
    if (!is2xx(resp.status)) return error.ProviderError;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch return error.InvalidResponse;
    if (parsed.value != .object) return error.InvalidResponse;
    const at = parsed.value.object.get("access_token") orelse return error.InvalidResponse;
    if (at != .string) return error.InvalidResponse;
    return try alloc.dupe(u8, at.string);
}

/// Fetch + normalize the user's identity from the provider's userinfo endpoint.
pub fn fetchIdentity(
    transport: Transport,
    alloc: std.mem.Allocator,
    provider: providers.Provider,
    access_token: []const u8,
) ClientError!providers.Identity {
    const auth_value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
    const headers = [_]Header{
        .{ .name = "authorization", .value = auth_value },
        .{ .name = "accept", .value = "application/json" },
    };
    const resp = try transport.call(transport.ctx, alloc, .GET, provider.userinfoURL, &headers, null);
    if (!is2xx(resp.status)) return error.ProviderError;
    return providers.extractIdentity(alloc, provider, resp.body);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (4 new tests).

- [ ] **Step 5: Commit**

```bash
git add src/oauth/client.zig src/main.zig
git commit -m "feat(oauth): transport seam + token exchange / identity fetch (stub-tested)"
```

---

## Done criteria for 6a

- `mise exec zig@0.16.0 -- zig build test --summary all` is green on branch `oauth2`.
- `_externalAuths` exists with both unique indexes; secrets encrypt/decrypt with tamper detection; the provider registry resolves presets and maps identities; collections persist `oauth2` config but never emit `clientSecret`; `exchangeCode`/`fetchIdentity` work against the stub transport.
- No endpoints, no real HTTP, no `main` merge — those are Plan 6b.

---

## Self-Review (author)

- **Spec coverage:** `_externalAuths` (spec §3.1 → Task 1); secret AES-GCM/HKDF (§5.1 → Task 2); preset registry + userinfo mapping (§2, §5.2 → Task 3); per-collection `oauth2` options + persist/redact split (§3.2 → Task 4); `Transport` seam + `exchangeCode`/`fetchIdentity` (§5.2 → Task 5). Endpoints/decision-tree/real transport/unlink/`_externalAuths` cleanup (§4, §6b) are explicitly Plan 6b.
- **Placeholder scan:** none — every code step has complete code.
- **Type consistency:** `Provider`/`ProviderMapping`/`Identity`/`ExtractError` (Task 3) are consumed unchanged by Task 5; `OAuth2Provider`/`OAuth2Options` (Task 4) match the spec's option shape; `optionsToJson(alloc, c, redact)` arity is updated at all three call sites (Task 4 Step 6).
- **Deferred to 6b (intentional):** generic-provider `mapping` overrides; https-scheme validation of provider URLs; `clientSecret` encrypt-on-input at the collections API layer (6a persists verbatim; 6b wires the app secret in). These are noted so 6b picks them up.
