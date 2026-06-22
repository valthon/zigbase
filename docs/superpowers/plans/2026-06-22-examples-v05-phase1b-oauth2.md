# Phase 1b (E3) — comptime `.auth.oauth2` provider config + provisioning-time secret injection

**Date:** 2026-06-22
**Status:** Proposed (awaiting review)
**Spec:** `docs/superpowers/specs/2026-06-22-examples-v05-features-design.md` (E3 bullet, lines 80–95 + 165–172)
**Depends on:** Phase 1 (E1 `.indexes` lowering already landed; this plan does not need it). Independent of Phase 2/4.
**Blocks:** golfsim's "Sign in with Google" (Phase 3, OAuth2 sub-feature only).

---

## Goal

Let a consumer declare an OAuth2 provider in the comptime `.collections` literal:

```zig
.users = .{ .type = .auth, .auth = .{
    .oauth2 = .{
        .enabled = true,
        .providers = .{
            .{ .name = "google", .redirectUrls = .{ "https://app.example/oauth/callback" } },
        },
    },
} },
```

The provider's runtime `clientId`/`clientSecret` are **NOT** in the literal (a comptime literal
cannot hold a runtime secret). They are sourced from environment variables at provisioning time
(`ZIGBASE_OAUTH_<UPPER(NAME)>_CLIENT_ID` / `_SECRET`), and the plaintext `clientSecret` is encrypted
via `oauth/secrets.encryptSecret` before it is persisted into `_collections.options` — exactly as the
admin-API path already does in `api/collections.zig:prepareOAuthConfig`.

---

## Global Constraints (read before every task)

- **Toolchain pinned via mise.** Run Zig as `mise exec zig@0.16.0 -- zig <cmd>` (or `eval "$(mise activate bash)"` once). Another 0.16.x is not guaranteed to work.
- **Authoritative test signal:** `mise exec zig@0.16.0 -- zig build test --summary all` → the `Build Summary: N/N tests passed` line. `zig build test` prints a spurious `failed command: …` line even on success — ignore it; trust the summary.
- **No new src file is planned.** All new code lands in existing files (`src/provision.zig`, `src/collections.zig` OR a tiny new `src/oauth/provision_secrets.zig` if Task 2 chooses the shared-helper option — see decision). **If a new `src/*.zig` file is introduced, it MUST be added to the `test { _ = @import("…"); }` block in `src/root.zig` or its tests will not run.**
- **Changelog:** never edit `CHANGELOG.md`. Add one fragment `changelog.d/comptime-oauth2.md` with a `### Features` section (consumer-visible: comptime `.auth.oauth2` + env-secret convention).
- **Docs/site sync (user cares a lot):** any `docs/framework.md` edit MUST be mirrored into `site/src/content/docs/framework.md`; run `cd site && npm run build` after. Document the new comptime `.auth.oauth2` shape AND the `ZIGBASE_OAUTH_<NAME>_CLIENT_ID/_SECRET` env convention.
- **CI caveat:** this feature cannot be exercised end-to-end (no real Google creds in CI). All verification is unit-level: comptime lowering + encrypt-on-create with a stub env getter and a fake app secret. State this in docs and the changelog.
- **TDD per `superpowers:test-driven-development`:** write the failing test first, watch it fail for the right reason, then implement. Revert any throwaway compile-error probe with `Edit`, never `git checkout` (per memory: subagent-temp-test-revert-footgun).
- **No `before`/transaction subtleties here** — this is provisioning-path code, not a hook.

---

## Verified facts (re-confirmed against code; design against these)

1. **`schema.OAuth2Provider` / `OAuth2Options` (`src/schema.zig:75–91`)** — verbatim:
   ```zig
   pub const OAuth2Provider = struct {
       name: []const u8,
       clientId: []const u8 = "",
       clientSecret: []const u8 = "", // persisted as a "v1:" AES-GCM blob; redacted in API output
       enabled: bool = true,
       redirectUrls: []const []const u8 = &.{},
       authURL: ?[]const u8 = null,
       tokenURL: ?[]const u8 = null,
       userinfoURL: ?[]const u8 = null,
       scopes: ?[]const []const u8 = null,
   };
   pub const OAuth2Options = struct { enabled: bool = false, providers: []const OAuth2Provider = &.{} };
   ```
   `AuthOptions.oauth2` is at `schema.zig:154`; `CollectionOptions.auth` at `schema.zig:157–159`.

2. **`optionsToJson` / `optionsFromJson` already round-trip oauth2** (`schema.zig:170–193` write; `275–304` read). So a `col.options.auth.oauth2` set at create time is persisted by `collections.insertRow` (`collections.zig:95` → `optionsToJson(…, false)` = unredacted) and reloaded on later boots. **No schema-serialization work is needed.**

3. **`buildCollection` (`provision.zig:91–142`)** lowers `type/fields/rules/.auth.methods/.auth.require_verified/.indexes` but **NOT `.auth.oauth2`**. The `.auth` branch is `provision.zig:130–138`. `buildMethodsOptions` is the parallel helper at `provision.zig:154–198`. `strTupleToSlice` (`provision.zig:324`) coerces a comptime string tuple → `[]const []const u8`.

4. **`secrets.encryptSecret(io, alloc, app_secret, plaintext) ![]u8`** (`oauth/secrets.zig:25`) and **`secrets.isEncrypted(blob) bool`** (`oauth/secrets.zig:20`). Blob format `"v1:" ++ base64url(nonce‖ct‖tag)`; key derived from `app_secret` (the app JWT secret) via HKDF.

5. **API encryption path** (`api/collections.zig:18–43` `prepareOAuthConfig`): for each provider — `resolveProvider(np) == null → error.BadOAuthConfig` (validates preset OR generic authURL/tokenURL/userinfoURL all-https); empty incoming secret on update preserves the stored one; **only encrypts when `!secrets.isEncrypted(np.clientSecret)`** (idempotent — never double-encrypts). Uses `app.io`, `ctx.allocator`, `app.jwt_secret`.

6. **`resolveProvider(cfg)` (`api/oauth.zig:18–38`)**: preset (`providers.lookup`, `oauth/providers.zig:66`) supplies authURL/tokenURL/userinfoURL/scopes; a generic (non-preset) provider REQUIRES `authURL`+`tokenURL`+`userinfoURL` (returns `null` otherwise); all three must be `https://`. Returns `null` on any failure. Presets: `google`, `github`, `microsoft`, `discord` (`oauth/providers.zig:30–63`).

7. **Provisioning path** `provision.applySpecs` → `ensureCollection` (`provision.zig:489–567`):
   - `existing == null` → `collections.create(alloc, io, w, spec)` applies the **full** comptime spec including `options.auth.oauth2` (`provision.zig:501–504`).
   - On an EXISTING collection it preserves live DB options (does NOT re-apply `options.auth`) and early-returns when no field changed. **Examples run on a fresh DB → first-creation applies everything.**
   - `collections.create` (`collections.zig:19–64`) calls `insertRow` → `optionsToJson(…, false)` persisting the provider unredacted (encrypted blob).

8. **`collections.create` signature** = `(alloc, io: std.Io, w: *db.Db, def: schema.Collection)`. It receives `io` (needed for the encrypt nonce) but **NOT** `app_secret`/`jwt_secret` and **NOT** env. → plumbing required (see Decision).

9. **Bootstrap provisioning call** (`framework.zig:703–735` `serveImpl`): `cfg.jwt_secret` is resolved into `cfg` at `framework.zig:705–707` BEFORE the provisioning block; the block calls `provision.applySpecs(allocator, io, w, schema_collections)` at `framework.zig:734`. **`serveImpl` does NOT currently receive the environ map** — `loadCfg(init.environ_map, sa)` builds `cfg` at `framework.zig:386` and passes only `cfg` onward. The env getter (`config.EnvGetter`, `config.zig:142`) wraps `*const std.process.Environ.Map` from `init.environ_map`.

10. **`migrate` CLI path** (`framework.zig:636–644`) runs only `migrations.run` — it does NOT call `applySpecs`. So **only the `serve` path provisions collections**; the env-secret injection only needs to happen in `serveImpl`.

---

## Decisions (the crux)

### D-1 — Where env is read & where encryption happens

**Decision: inject in `serveImpl`, before `applySpecs`, behind a small free function `provision.injectOAuthSecrets`.** Do NOT change `collections.create`'s signature.

Rationale: `collections.create` is a low-level engine call with many callers (API, provisioning, tests); threading `app_secret`+env through it is invasive and would force every caller to supply secrets. The env+jwt_secret are both cleanly available at exactly one place — the `serveImpl` provisioning block (`cfg.jwt_secret` is resolved; the environ is reachable with one new parameter). So we resolve providers into a **mutated copy of the spec slice** there, then hand the resolved specs to the unchanged `applySpecs`.

**Plumbing (minimal):**
- Add a parameter `environ: *const std.process.Environ.Map` to `serveImpl` (and thread it from the two callers: `runCliImpl` `.serve` arm at `framework.zig:386–387`, and the public `App.run` at `framework.zig:333–334`). For `App.run` (consumer calls it directly with a runtime cfg), pass `init.environ_map`.
- In the `serveImpl` provisioning block, BEFORE `applySpecs`, compute resolved specs:
  ```zig
  const resolved = try provision.injectOAuthSecrets(
      allocator, io, jwt_secret,
      config.EnvGetter{ .environ = environ },
      schema_collections,
  );
  try provision.applySpecs(allocator, io, w, resolved);
  ```
  (`jwt_secret` is the local resolved secret at `framework.zig:705`; pass it, not `cfg.jwt_secret`, so we get the auto-generated/persisted value.)

**`provision.injectOAuthSecrets` contract** (new pub fn in `src/provision.zig`):
```zig
/// Return a copy of `specs` where every auth collection's oauth2 providers have their
/// clientId/clientSecret filled in from the environment and the secret encrypted. A provider
/// whose env CLIENT_ID/SECRET are both absent is left as declared (clientId/clientSecret = "").
/// Generic `getter` so tests pass a stub (same `.get(key) ?[]const u8` shape as config.EnvGetter).
pub fn injectOAuthSecrets(
    alloc: std.mem.Allocator,
    io: std.Io,
    app_secret: []const u8,
    getter: anytype,
    specs: []const schema.Collection,
) ![]const schema.Collection
```
- For each spec with `type == .auth` and `options.auth.oauth2.providers.len > 0`, build a new providers slice from `alloc`:
  - env keys: `ZIGBASE_OAUTH_<UPPER(name)>_CLIENT_ID` and `…_SECRET` (uppercase the provider name; non-`[A-Z0-9_]` chars are not expected for valid provider names but uppercase only — provider names are validated as identifiers at comptime, see Task 1).
  - if `CLIENT_ID` present → set `clientId`.
  - if `CLIENT_SECRET` present and non-empty → encrypt via `secrets.encryptSecret(io, alloc, app_secret, raw)` and set `clientSecret`. (Skip if already `secrets.isEncrypted` — defensive; env values are always plaintext, so this is just symmetry with the API path.)
  - leave `enabled`, `redirectUrls`, `authURL/tokenURL/userinfoURL/scopes` from the comptime literal untouched.
- Collections without oauth2 providers are passed through unchanged (no copy). Only allocate when there is something to rewrite.

This **reuses the exact `secrets.encryptSecret` call the API path uses** → identical blob format and key derivation (DRY at the crypto layer; the loop differs because the API sources from request JSON and this sources from env — factoring a shared "resolve+encrypt one provider" helper is optional and noted as a stretch in Task 3).

### D-2 — Secret drift across boots (idempotency)

**Decision: accept first-create-encrypts-once; subsequent boots are no-ops. Document it.**

- AES-GCM uses a fresh random nonce each call, so re-encrypting the same plaintext yields a *different* blob each boot. If we re-injected on every boot, the persisted secret would churn (cosmetic, not a security bug — decrypts identically).
- This is naturally avoided because `ensureCollection` only applies `options.auth` on **first creation** (verified fact #7): on an existing collection it preserves the live (already-encrypted) options and early-returns. So `injectOAuthSecrets` runs every boot, but its output only reaches persistence on the very first boot for a given collection. **No drift.**
- Caveat to document (matches the spec's "Provisioning caveat", lines 91–95): **rotating the env secret does NOT update an already-provisioned collection.** To rotate, the operator updates the secret via the admin API (which re-encrypts), or drops/recreates the collection, or (future) uses an explicit migration. Out of scope here; documented in framework.md + golfsim README (Phase 3).

### D-3 — Comptime validation in `buildOAuth2Options`

- `.name` is REQUIRED (`@compileError` if missing) and must be `schema.isValidIdentifier` (it is uppercased into an env var name and used as a slug — reject hyphens/spaces). NOTE: preset names (`google`/`github`/`microsoft`/`discord`) are all valid identifiers.
- `.clientId`/`.clientSecret` are accepted in the literal but **discouraged** (they'd bake a secret into the binary). Lower them if present (so a consumer *can* hard-code a non-secret clientId), but env always wins at provision time (env overrides the literal). Document: prefer env.
- Generic provider check is **runtime** (in `resolveProvider`, already enforced when the endpoints are used), NOT comptime — because the comptime literal legitimately omits authURL/tokenURL for presets and we can't know at comptime whether `name` is a preset without duplicating the preset table. Do not add a comptime preset check (keeps the lowering simple and the preset list single-sourced in `oauth/providers.zig`). A generic provider missing endpoints simply fails `resolveProvider` at request time (returns 404/null), same as the API path.
- `.enabled` default `true` (struct default); `.redirectUrls`/`.scopes` via `strTupleToSlice`; `authURL`/`tokenURL`/`userinfoURL` optional strings via `optStr`.

---

## Tasks (TDD, bite-sized, in order)

### Task 1 — `buildOAuth2Options` comptime helper + `buildCollection` branch

**Files:** `src/provision.zig`.

**1a — Failing test first.** Add to the test block in `provision.zig` (after the `buildCollection lowers .auth.methods` test, ~line 1083):
```zig
test "buildCollection lowers .auth.oauth2 providers" {
    const specs = comptime buildCollections(.{
        .users = .{ .type = .auth, .fields = .{}, .auth = .{ .oauth2 = .{
            .enabled = true,
            .providers = .{
                .{ .name = "google", .redirectUrls = .{"https://app.example/cb"} },
                .{ .name = "github", .enabled = false, .clientId = "baked-id" },
            },
        } } },
    });
    const o = specs[0].options.auth.oauth2;
    try std.testing.expect(o.enabled);
    try std.testing.expectEqual(@as(usize, 2), o.providers.len);
    try std.testing.expectEqualStrings("google", o.providers[0].name);
    try std.testing.expectEqual(@as(usize, 1), o.providers[0].redirectUrls.len);
    try std.testing.expectEqualStrings("https://app.example/cb", o.providers[0].redirectUrls[0]);
    try std.testing.expect(o.providers[0].enabled); // struct default true
    try std.testing.expect(!o.providers[1].enabled);
    try std.testing.expectEqualStrings("baked-id", o.providers[1].clientId);
    // comptime literal carries NO secret
    try std.testing.expectEqualStrings("", o.providers[0].clientSecret);
}
```
Run `zig build test` → expect FAIL (oauth2 ignored: `o.enabled` is false, `o.providers.len` is 0).

**1b — Implement.** In `buildCollection`, inside the existing `if (@hasField(S, "auth"))` block (after the `require_verified` branch at `provision.zig:135–137`):
```zig
if (@hasField(A, "oauth2")) {
    col.options.auth.oauth2 = buildOAuth2Options(spec.auth.oauth2);
}
```
Add the helper (place it right after `buildMethodsOptions`, ~line 198):
```zig
fn buildOAuth2Options(comptime o: anytype) schema.OAuth2Options {
    comptime {
        const O = @TypeOf(o);
        var out = schema.OAuth2Options{};
        if (@hasField(O, "enabled")) out.enabled = o.enabled;
        if (@hasField(O, "providers")) {
            const pt = o.providers;
            const PT = @TypeOf(pt);
            const pinfo = @typeInfo(PT);
            if (pinfo != .@"struct")
                @compileError(".auth.oauth2.providers must be a tuple of provider literals");
            const pf = pinfo.@"struct".fields;
            var provs: [pf.len]schema.OAuth2Provider = undefined;
            for (pf, 0..) |pff, i| {
                provs[i] = buildOAuth2Provider(@field(pt, pff.name));
            }
            const frozen = provs;
            out.providers = &frozen;
        }
        return out;
    }
}

fn buildOAuth2Provider(comptime p: anytype) schema.OAuth2Provider {
    comptime {
        const P = @TypeOf(p);
        if (!@hasField(P, "name"))
            @compileError(".auth.oauth2 provider is missing .name");
        const pname: []const u8 = p.name;
        if (!schema.isValidIdentifier(pname))
            @compileError("oauth2 provider name '" ++ pname ++ "' must be a valid identifier (it is used as a slug and uppercased into an env var name)");
        var out = schema.OAuth2Provider{ .name = pname };
        if (@hasField(P, "clientId")) out.clientId = p.clientId;
        if (@hasField(P, "clientSecret")) out.clientSecret = p.clientSecret;
        if (@hasField(P, "enabled")) out.enabled = p.enabled;
        if (@hasField(P, "redirectUrls")) out.redirectUrls = strTupleToSlice(p.redirectUrls);
        if (@hasField(P, "authURL")) out.authURL = p.authURL;
        if (@hasField(P, "tokenURL")) out.tokenURL = p.tokenURL;
        if (@hasField(P, "userinfoURL")) out.userinfoURL = p.userinfoURL;
        if (@hasField(P, "scopes")) out.scopes = strTupleToSlice(p.scopes);
        return out;
    }
}
```
Run `zig build test --summary all` → expect the new test passes and `N/N tests passed` rises by 1.

**1c — Negative (compile-error) test, documented not compiled.** Add a comment near the helper noting that a provider literal missing `.name`, or a `.name` that isn't a valid identifier, is a `@compileError` (consistent with field/collection/index validation). Do NOT add a compiled negative test (Zig has no "expect this fails to compile" in the unit suite). Optionally, during development only, temporarily add a bad literal to confirm the `@compileError` fires, then **revert with `Edit`** (memory: subagent-temp-test-revert-footgun).

---

### Task 2 — `provision.injectOAuthSecrets` (env-source + encrypt at create)

**Files:** `src/provision.zig` (add `const secrets = @import("oauth/secrets.zig");` import near the top imports, `provision.zig:16–22`).

**2a — Failing test first.** Add to `provision.zig` test block:
```zig
test "injectOAuthSecrets sources clientId/secret from env and encrypts the secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Getter = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_OAUTH_GOOGLE_CLIENT_ID")) return "gid-123";
            if (std.mem.eql(u8, key, "ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET")) return "raw-secret";
            return null;
        }
    };
    const provs = [_]schema.OAuth2Provider{.{ .name = "google", .redirectUrls = &.{"https://x/cb"} }};
    const cols = [_]schema.Collection{.{
        .id = "", .name = "users", .type = .auth, .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};

    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret-32-bytes-long-xxxxxxx", Getter{}, &cols);
    const p = out[0].options.auth.oauth2.providers[0];
    try std.testing.expectEqualStrings("gid-123", p.clientId);
    try std.testing.expect(secrets.isEncrypted(p.clientSecret));
    // round-trips back to the raw env value
    const pt = try secrets.decryptSecret(a, "app-secret-32-bytes-long-xxxxxxx", p.clientSecret);
    try std.testing.expectEqualStrings("raw-secret", pt);
}

test "injectOAuthSecrets leaves providers untouched when env is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Getter = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    const provs = [_]schema.OAuth2Provider{.{ .name = "google" }};
    const cols = [_]schema.Collection{.{
        .id = "", .name = "users", .type = .auth, .fields = &.{},
        .options = .{ .auth = .{ .oauth2 = .{ .enabled = true, .providers = &provs } } },
    }};
    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret", Getter{}, &cols);
    const p = out[0].options.auth.oauth2.providers[0];
    try std.testing.expectEqualStrings("", p.clientId);
    try std.testing.expectEqualStrings("", p.clientSecret);
}

test "injectOAuthSecrets passes non-oauth collections through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Getter = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 { return null; }
    };
    const cols = [_]schema.Collection{.{ .id = "", .name = "posts", .fields = &.{} }};
    const out = try injectOAuthSecrets(a, std.testing.io, "app-secret", Getter{}, &cols);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("posts", out[0].name);
}
```
Run → expect FAIL (function does not exist / won't compile).

**2b — Implement** `injectOAuthSecrets` in `src/provision.zig` (place near `resolveTargets`, ~line 599). Use the contract from Decision D-1. Sketch:
```zig
pub fn injectOAuthSecrets(
    alloc: std.mem.Allocator,
    io: std.Io,
    app_secret: []const u8,
    getter: anytype,
    specs: []const schema.Collection,
) ![]const schema.Collection {
    // Cheap pre-scan: only allocate a new outer slice if any auth collection has providers.
    var any = false;
    for (specs) |c| if (c.type == .auth and c.options.auth.oauth2.providers.len > 0) { any = true; break; };
    if (!any) return specs;

    const out = try alloc.alloc(schema.Collection, specs.len);
    for (specs, 0..) |c, ci| {
        out[ci] = c;
        if (c.type != .auth or c.options.auth.oauth2.providers.len == 0) continue;
        const src = c.options.auth.oauth2.providers;
        const np = try alloc.alloc(schema.OAuth2Provider, src.len);
        for (src, 0..) |p, i| {
            np[i] = p;
            // ZIGBASE_OAUTH_<UPPER(NAME)>_CLIENT_ID / _SECRET
            const upper = try std.ascii.allocUpperString(alloc, p.name);
            const id_key = try std.fmt.allocPrint(alloc, "ZIGBASE_OAUTH_{s}_CLIENT_ID", .{upper});
            const sec_key = try std.fmt.allocPrint(alloc, "ZIGBASE_OAUTH_{s}_CLIENT_SECRET", .{upper});
            if (getter.get(id_key)) |v| if (v.len > 0) { np[i].clientId = try alloc.dupe(u8, v); };
            if (getter.get(sec_key)) |v| if (v.len > 0) {
                np[i].clientSecret = if (secrets.isEncrypted(v))
                    try alloc.dupe(u8, v)
                else
                    try secrets.encryptSecret(io, alloc, app_secret, v);
            };
        }
        out[ci].options.auth.oauth2.providers = np;
    }
    return out;
}
```
Notes for the implementer:
- `std.ascii.allocUpperString` exists in Zig 0.16 std; confirm the exact name during impl (`std.ascii.upperString` writes into a buffer; `allocUpperString` allocates). If the alloc variant is absent, allocate `p.name.len` bytes and `std.ascii.upperString(buf, p.name)`.
- The error set is `anyerror`-ish via `!`; the concrete set is `Allocator.Error || secrets.SecretError`. Keep the `!` inferred return; `applySpecs`/`serveImpl` already use `try`.
- This deliberately mirrors `prepareOAuthConfig`'s `isEncrypted`-guard (verified fact #5) so the two paths never double-encrypt and produce identical blob formats.

Run `zig build test --summary all` → expect the 3 new tests pass.

---

### Task 3 — Wire `injectOAuthSecrets` into `serveImpl` (the only provisioning path)

**Files:** `src/framework.zig`.

**3a — Thread the environ into `serveImpl`.**
- Add param `environ: *const std.process.Environ.Map` to `serveImpl` (`framework.zig:703`).
- Caller 1 — `runCliImpl` `.serve` arm (`framework.zig:386–387`): `try serveImpl(allocator, init.io, cfg, …, init.environ_map);`
- Caller 2 — public `App.run` (`framework.zig:333–334`): `return serveImpl(init.gpa, init.io, cfg_runtime, …, init.environ_map);` (it already has `init`).

**3b — Resolve specs before provisioning.** In the provisioning block (`framework.zig:733–735`), replace:
```zig
if (schema_collections.len > 0) {
    try provision.applySpecs(allocator, io, w, schema_collections);
}
```
with:
```zig
if (schema_collections.len > 0) {
    const resolved = try provision.injectOAuthSecrets(
        allocator, io, jwt_secret,
        config.EnvGetter{ .environ = environ },
        schema_collections,
    );
    try provision.applySpecs(allocator, io, w, resolved);
}
```
(`jwt_secret` is the resolved local at `framework.zig:705`; `config` is already imported in framework.zig.)

**3c — Verify it still builds + all tests pass.** `zig build test --summary all`. There is no unit test that drives `serveImpl` end-to-end (no CI Google creds — verified-fact caveat); coverage is Task 1 + Task 2. The build itself is the regression guard for the wiring (signature + caller updates compile).

**Optional stretch (only if time permits):** factor the per-provider "validate via resolveProvider + isEncrypted-guard + encryptSecret" into a shared helper callable by both `prepareOAuthConfig` and `injectOAuthSecrets`. NOT required — the two loops legitimately differ (request-JSON vs env source), and the only truly shared primitive (`secrets.encryptSecret`) is already shared. Skip unless the reviewer asks; document the intentional non-DRY in a code comment.

---

### Task 4 — Changelog fragment

**File:** `changelog.d/comptime-oauth2.md` (new).
```
### Features

- Comptime OAuth2 providers: declare `.auth.oauth2 = .{ .enabled = true, .providers = .{ .{ .name = "google", .redirectUrls = .{…} } } }` on an auth collection in `.collections`. The runtime `clientId`/`clientSecret` are sourced from `ZIGBASE_OAUTH_<NAME>_CLIENT_ID` / `ZIGBASE_OAUTH_<NAME>_CLIENT_SECRET` at provisioning time and the secret is encrypted (AES-256-GCM) before it is persisted — secrets never live in the binary. (Applied on first creation only; rotate via the admin API.)
```
Do NOT run `assemble-changelog.sh`; only add the fragment (per CLAUDE.md).

---

### Task 5 — Docs + site mirror

**Files:** `docs/framework.md` AND `site/src/content/docs/framework.md` (identical edits).

Add a `### OAuth2 providers (`.auth.oauth2`)` subsection in the auth-methods area (after the `.auth.methods` table/example, ~`docs/framework.md:442`), documenting:
- the comptime shape (the literal at the top of this plan);
- that `clientId`/`clientSecret` come from env: `ZIGBASE_OAUTH_<UPPER(NAME)>_CLIENT_ID` / `_SECRET`, secret encrypted on persist; prefer env over baking into the literal;
- preset names (`google`, `github`, `microsoft`, `discord`) supply endpoints automatically; a generic provider must set `authURL`/`tokenURL`/`userinfoURL` (all `https://`);
- the **applied-on-first-creation-only** caveat + how to rotate (admin API), cross-referencing the existing "Provisioning caveat";
- the CI caveat: cannot be exercised without real provider credentials.

Then `cd site && npm run build` to confirm the mirror builds.

---

### Task 6 — Final verification

- `mise exec zig@0.16.0 -- zig build test --summary all` → confirm `Build Summary: N/N tests passed` (no failures; ignore the spurious `failed command` line).
- `mise exec zig@0.16.0 -- zig build` → binary builds.
- `cd site && npm run build` → docs site builds.
- Confirm the worktree is clean of any throwaway compile-error probe (Edit-reverted, not `git checkout`).
- (No browser suite required — no admin-UI change. golfsim's consumption of this is Phase 3, a separate plan/PR.)

---

## Risk / open questions for the human before execution

1. **Worktree is stale.** `git log` in the worktree shows it branched from `origin/main` and is MISSING the design spec + this plan's sibling Phase-1 work (spec exists only as an uncommitted/new file in the worktree). Per memory (`worktree-agents-branch-from-origin`): if Phase 1 (E1 `.indexes`) hasn't been pushed/merged, the worktree may lack it. **Confirm the base branch has E1 landed before executing** — Task 1's `.auth` branch sits next to E1's `.indexes` branch; a merge conflict is likely if both land independently. Recommend rebasing this work on top of merged Phase 1.

2. **`serveImpl` signature change touches `App.run`** (public-ish framework entry). Adding the `environ` param is the minimal plumbing, but if any other caller of `serveImpl` exists (none found beyond `runCliImpl` + `App.run`), it must be updated. Re-grep `serveImpl(` before editing.

3. **`std.ascii.allocUpperString` name/availability in Zig 0.16** — verify the exact std API at impl time (fallback: `upperString` into a stack/alloc buffer). Low risk, 1-line.

4. **Generic-provider comptime validation deliberately omitted** (D-3): a non-preset provider missing endpoints fails silently at request time (404), not at startup. If the reviewer wants a louder signal, add a *runtime* startup warning in `injectOAuthSecrets` when `oauth_api.resolveProvider(p) == null` (would require importing `api/oauth.zig` into provision.zig — a new dependency edge; flagged, not chosen, to keep provision.zig free of api/ imports).

5. **Multi-value relation / no interaction** — none; oauth2 lives entirely in `options`, orthogonal to fields/indexes.

6. **No e2e/CI coverage** is an accepted limitation per the spec (no Google creds). The encrypt-on-create unit test (Task 2a) with a fake app secret is the strongest available proof.
