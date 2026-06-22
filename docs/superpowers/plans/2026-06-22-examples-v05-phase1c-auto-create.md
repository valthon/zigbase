# E4 — `auto_create` for magic_link and otp auth methods

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** When `initiate` is called for a `magic_link` or `otp` auth collection whose method opts carry `auto_create = true`, and the supplied identity is **not** found in the collection, create a minimal auth record (email/username set from the identity, `verified = false`, empty `passwordHash`, fresh `tokenKey`) and then proceed exactly as if the identity had already existed — mint and mail the link/OTP. The change is invisible to callers (still always 204). Duplicate identities are never created.

**Architecture:** A shared `resolveOrCreate` helper added directly to `AuthCtx` in `src/auth/method.zig`. Both `magic_link.zig` and `otp.zig` call it instead of bare `findByIdentity` when their respective `auto_create` opt is set. The helper acquires the writer (always needed for the create case) and does a single writer-scoped lookup + optional insert: findByIdentity under the writer, create if missing, return the record id. The writer is released before any SMTP send (same pattern the existing code already follows).

**Tech stack:** Zig 0.16.0 (mise-pinned), `records.create`, `crypto.genToken`, `api/auth.findByIdentity`.

---

## Global Constraints

- Build/test ONLY via `mise exec zig@0.16.0 -- zig build test --summary all`; signal is `Build Summary: N/N tests passed`.
- No new `src/*.zig` files — all changes are to existing files (`src/auth/method.zig`, `src/auth/methods/magic_link.zig`, `src/auth/methods/otp.zig`). No `root.zig` change required.
- Changelog fragment at `changelog.d/auto-create-auth.md` (section: `### Features`).
- Update `docs/framework.md` table row for `magic_link` and `otp` to note that `auto_create` now **works** (currently both rows document the flag but otp's row doesn't mention it at all, and magic_link's row silently omits its effect). Mirror the same edits to `site/src/content/docs/framework.md`.
- Enumeration-safety: `initiate` ALWAYS returns 204 regardless of whether a record was found, created, or nothing happened.
- `verified = false` on all auto-created records. This is intentional for v1: completing the magic-link or OTP flow proves email control, but we leave verification as a separate concern. This matters only if `require_verified = true` is set on the collection — document this note in `docs/framework.md`.

---

## Verified API Facts

These were confirmed by reading the source before writing this plan:

- **`records.create` signature** (`src/records.zig:505`): `pub fn create(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, col: schema.Collection, data: std.json.Value) RecordError!std.json.Value`. Returns the created record as a JSON object with `id` as a top-level string field.
- **`createOAuthRecord` precedent** (`src/api/oauth.zig:169–185`): generates `tokenKey` via `crypto.genToken(app.io, alloc, 32)`, builds a `std.json.ObjectMap` with `email`, `username`, `passwordHash = ""`, `tokenKey`, `verified`, then calls `records.create(ctx.allocator, app.io, conn, col, .{ .object = data })` and returns `rec.object.get("id").?.string`. This is the exact pattern to mirror for `auto_create`.
- **`api/auth.findByIdentity`** (`src/api/auth.zig:76–85`): iterates `col.options.auth.identityFields` (default `&.{"email"}`), queries by equality. The auto-created record must set the first (or all) identity field(s) to the supplied identity string so subsequent `findByIdentity` calls resolve it.
- **`identityFields` default** (`src/schema.zig:148`): `&.{"email"}`. Auth collections also have `username` (non-unique text) as a system field; the simplest approach is to set only the fields listed in `col.options.auth.identityFields` from the submitted `identity`.
- **`AuthCtx` has `app`, `ctx`, `collection`, and `writer()`/`reader()` RAII handles** (`src/auth/method.zig:10–83`). It already imports `api_auth` (for `findByIdentity`). Adding `records` and `crypto` imports to `method.zig` is needed for the helper.
- **Magic-link `initiate` currently uses a READER** (`src/auth/methods/magic_link.zig:53–68`): the READER is sufficient for `findByIdentity` + `mintLinkToken` (both read-only). When `auto_create` is true and the identity is missing, we must switch to the WRITER for the insert. The revised flow: always acquire the WRITER when `auto_create = true` (simple); keep the existing READER-only path when `auto_create = false` (no regression). Alternatively, try READER first, then upgrade on miss — but acquiring writer-then-create is simpler and correct.
- **OTP `initiate` already uses a WRITER** (`src/auth/methods/otp.zig:95–111`): the OTP code is stored via `ChallengeStore.put` which needs the writer. Auto-create fits naturally: do `findByIdentity` + optional `create` + `store.put` all inside the same writer block, then release before SMTP.
- **`auto_create` flag access**:
  - magic_link: `if (ac.collection.options.auth.methods.magic_link) |ml| ml.auto_create else false`
  - otp: `if (ac.collection.options.auth.methods.otp) |o| o.auto_create else false`
- **No duplicate-identity risk**: `records.create` will pass through `records.createImpl` which validates field values; the `email` field has a partial unique index (`idx_email`, `src/schema.zig:1052`). A race between two concurrent `auto_create` initiates for the same unknown email will cause the second `INSERT` to fail with a unique-constraint violation (SQLite UNIQUE). The helper should handle this by attempting `findByIdentity` again on create failure — the "loser" of the race simply reads the record the "winner" created.

---

## Shared Helper Design

Add `resolveOrCreate` to `AuthCtx` in `src/auth/method.zig`:

```zig
// In the AuthCtx struct body, alongside findByIdentity.
// Add these two const declarations alongside the existing imports (around line 16-22):
//   const records_mod = @import("../records.zig");
//   const crypto_mod  = @import("../crypto.zig");

/// Find-or-create an auth record for `identity` under an already-held writer.
/// Returns the record id (arena-allocated). When the identity is not found and
/// `auto_create` is false, returns null. When `auto_create` is true and the
/// identity is not found, inserts a minimal auth record (identity field(s) set to
/// `identity`, passwordHash = "", fresh tokenKey, verified = false) and returns
/// its id. If insert fails with a unique constraint race, retries findByIdentity
/// once and returns whatever is there.
pub fn resolveOrCreate(
    ac: *AuthCtx,
    conn: *db.Db,
    identity: []const u8,
    auto_create: bool,
) !?[]const u8 {
    // 1. Try the cheap path first — works for existing records regardless of auto_create.
    if (try ac.findByIdentity(conn, identity)) |rid| return rid;
    if (!auto_create) return null;

    // 2. Build the minimal auth record data.
    const tk = try crypto_mod.genToken(ac.app.io, ac.ctx.allocator, 32);
    var data: std.json.ObjectMap = .empty;
    // Set each identity field to the supplied identity (covers both email-only and
    // email+username collections — setting username too costs nothing and ensures
    // findByIdentity finds the record regardless of which field is listed first).
    for (ac.collection.options.auth.identityFields) |idf| {
        try data.put(ac.ctx.allocator, idf, .{ .string = identity });
    }
    try data.put(ac.ctx.allocator, "passwordHash", .{ .string = "" });
    try data.put(ac.ctx.allocator, "tokenKey",    .{ .string = tk });
    try data.put(ac.ctx.allocator, "verified",    .{ .bool = false });

    // 3. Insert. On unique-constraint collision (concurrent initiate for same identity),
    //    fall back to findByIdentity — the other request already created the record.
    const rec = records_mod.create(
        ac.ctx.allocator, ac.app.io, conn, ac.collection,
        std.json.Value{ .object = data },
    ) catch |err| {
        if (err == error.Validation) {
            // Unique constraint fires as a Validation error — retry lookup.
            return try ac.findByIdentity(conn, identity);
        }
        return err;
    };
    return rec.object.get("id").?.string;
}
```

**Location:** inside the `AuthCtx` struct in `src/auth/method.zig`, alongside `findByIdentity`. This keeps both methods' changes minimal (they call `ac.resolveOrCreate(...)` instead of `ac.findByIdentity(...)`), and the logic is tested once.

---

## Task 1: Add `resolveOrCreate` to `AuthCtx` + unit tests

**Files to modify:**
- `src/auth/method.zig` — add helper + tests (no new file)

### Steps

- [ ] **Step 1: Write the failing tests** in `src/auth/method.zig`'s test block.

  Test A — `resolveOrCreate, auto_create=false, unknown identity → null`:
  ```zig
  test "AuthCtx.resolveOrCreate: unknown identity + auto_create=false returns null" {
      const api_auth = @import("../api/auth.zig");
      const http = @import("../http.zig");
      const collections = @import("../collections.zig");

      var env = try api_auth.TestEnv.initAuth("rc_nocreate");
      defer env.deinit();
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();

      const col = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "rc_nocreate")).?;
      };
      var req = env.ctx(a, .POST, "", &[_]http.Param{});
      var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

      const w = env.pool.acquireWriter();
      defer env.pool.releaseWriter();
      const rid = try ac.resolveOrCreate(w, "nobody@x.io", false);
      try std.testing.expectEqual(@as(?[]const u8, null), rid);
  }
  ```

  Test B — `resolveOrCreate, auto_create=true, unknown identity → creates record, findByIdentity finds it`:
  ```zig
  test "AuthCtx.resolveOrCreate: unknown identity + auto_create=true creates record" {
      const api_auth = @import("../api/auth.zig");
      const http = @import("../http.zig");
      const collections = @import("../collections.zig");

      var env = try api_auth.TestEnv.initAuth("rc_create");
      defer env.deinit();
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();

      const col = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "rc_create")).?;
      };
      var req = env.ctx(a, .POST, "", &[_]http.Param{});
      var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

      const w = env.pool.acquireWriter();
      defer env.pool.releaseWriter();

      const rid1 = (try ac.resolveOrCreate(w, "new@x.io", true)).?;
      try std.testing.expect(rid1.len > 0);

      // Idempotent: a second call returns the same id (no duplicate created).
      const rid2 = (try ac.resolveOrCreate(w, "new@x.io", true)).?;
      try std.testing.expectEqualStrings(rid1, rid2);
  }
  ```

  Test C — `resolveOrCreate, auto_create=true, KNOWN identity → returns existing id, no creation`:
  ```zig
  test "AuthCtx.resolveOrCreate: known identity + auto_create=true returns existing record" {
      const api_auth = @import("../api/auth.zig");
      const http = @import("../http.zig");
      const collections = @import("../collections.zig");

      var env = try api_auth.TestEnv.initAuth("rc_existing");
      defer env.deinit();
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();

      try env.createUser(a, "rc_existing", "u@x.io", "longenough");

      const col = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "rc_existing")).?;
      };
      var req = env.ctx(a, .POST, "", &[_]http.Param{});
      var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

      const w = env.pool.acquireWriter();
      defer env.pool.releaseWriter();

      // Get the expected rid from findByIdentity
      const expected_rid = (try ac.findByIdentity(w, "u@x.io")).?;

      // resolveOrCreate with auto_create=true must return the same id, not insert another row
      const rid = (try ac.resolveOrCreate(w, "u@x.io", true)).?;
      try std.testing.expectEqualStrings(expected_rid, rid);
  }
  ```

- [ ] **Step 2: Run, verify all three tests fail** (symbol `resolveOrCreate` does not exist yet):
  ```sh
  mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -5
  ```

- [ ] **Step 3: Implement `resolveOrCreate`** inside the `AuthCtx` struct in `src/auth/method.zig`.
  - Add `const records_mod = @import("../records.zig");` and `const crypto_mod = @import("../crypto.zig");` to the `AuthCtx` `const` declarations block (around line 16–22, alongside the existing `const auth_helpers`, `const api_auth`).
  - Add the `resolveOrCreate` pub function as specified in the design above.

- [ ] **Step 4: Run, verify all three tests pass.**

- [ ] **Step 5: Commit** — `feat(auth): add AuthCtx.resolveOrCreate — find-or-create helper for auto_create`

---

## Task 2: Wire `auto_create` into `magic_link.zig`'s `initiateImpl`

**Files to modify:**
- `src/auth/methods/magic_link.zig`

### Key design note on locking

Currently `initiateImpl` uses a **READER** for `findByIdentity` + `mintLinkToken` (both read-only). With `auto_create`, creating a record requires the WRITER. The cleanest approach: when `auto_create = true`, switch to the WRITER for the identity-resolve block. When `auto_create = false`, keep the READER. This avoids always serializing through the writer for the common case.

Revised pseudocode for `initiateImpl` (replace the `{var r ... }` block):

```zig
const auto_create: bool =
    if (ac.collection.options.auth.methods.magic_link) |ml| ml.auto_create else false;
const ttl: i64 =
    if (ac.collection.options.auth.methods.magic_link) |ml| ml.ttl_s else 900;

var pending: ?struct { email: []const u8, mail_body: []const u8 } = null;

if (auto_create) {
    // Need the writer: create if missing, then mintLinkToken.
    // mintLinkToken reads tokenKey via SELECT — fine under the writer in WAL mode.
    var w = ac.writer();
    defer w.deinit();

    if (try ac.resolveOrCreate(w.conn, email, true)) |rid| {
        const token = try ac.mintLinkToken(w.conn, rid, ttl, .{});
        const mail_body = try std.fmt.allocPrint(ac.ctx.allocator,
            "Your sign-in link token:\n\n{s}\n", .{token});
        pending = .{ .email = email, .mail_body = mail_body };
    }
} else {
    // Original path: READER only (no change to existing behavior)
    var r = try ac.reader();
    defer r.deinit();

    if (try ac.findByIdentity(&r.conn, email)) |rid| {
        const token = try ac.mintLinkToken(&r.conn, rid, ttl, .{});
        const mail_body = try std.fmt.allocPrint(ac.ctx.allocator,
            "Your sign-in link token:\n\n{s}\n", .{token});
        pending = .{ .email = email, .mail_body = mail_body };
    }
}
// Writer/reader released above. SMTP send happens outside either lock, as before.
```

### Steps

- [ ] **Step 1: Write the failing tests** in `src/auth/methods/magic_link.zig`:

  Test A — `initiate with auto_create=true + unknown identity creates the record`:
  ```zig
  test "MagicLinkMethod: initiate auto_create=true creates record for unknown identity" {
      const http = @import("../../http.zig");
      const collections = @import("../../collections.zig");
      const schema_mod = @import("../../schema.zig");

      var env = try api_auth.TestEnv.initAuth("ml_ac");
      defer env.deinit();
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();

      // Replace with a collection that has magic_link.auto_create = true
      {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          const existing = (try collections.get(a, w, "ml_ac")).?;
          try collections.delete(a, w, existing.id);
          _ = try collections.create(a, std.testing.io, w, .{
              .id = "", .name = "ml_ac", .type = .auth,
              .fields = &[_]schema_mod.Field{},
              .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
              .options = .{ .auth = .{ .methods = .{ .magic_link = .{ .auto_create = true } } } },
          });
      }

      const col = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "ml_ac")).?;
      };

      var req = env.ctx(a, .POST, "{\"identity\":\"brand_new@x.io\"}", &[_]http.Param{});
      var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

      var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
      const am = m.method();
      const res = try am.vtable.initiate(am.ctx, &ac);
      try std.testing.expectEqual(@as(u16, 204), res.status);

      // Verify the record now exists
      const w2 = env.pool.acquireWriter();
      defer env.pool.releaseWriter();
      const col2 = (try collections.get(a, w2, "ml_ac")).?;
      var req2 = env.ctx(a, .POST, "", &[_]http.Param{});
      var ac2 = AuthCtx{ .app = &env.app, .ctx = &req2, .collection = col2, .config = .null };
      const rid = try ac2.findByIdentity(w2, "brand_new@x.io");
      try std.testing.expect(rid != null);
  }
  ```

  Test B — `initiate with auto_create=false + unknown identity creates nothing`:
  ```zig
  test "MagicLinkMethod: initiate auto_create=false creates nothing for unknown identity" {
      const http = @import("../../http.zig");
      const collections = @import("../../collections.zig");
      const schema_mod = @import("../../schema.zig");

      var env = try api_auth.TestEnv.initAuth("ml_noac");
      defer env.deinit();
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();

      {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          const existing = (try collections.get(a, w, "ml_noac")).?;
          try collections.delete(a, w, existing.id);
          _ = try collections.create(a, std.testing.io, w, .{
              .id = "", .name = "ml_noac", .type = .auth,
              .fields = &[_]schema_mod.Field{},
              .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
              .options = .{ .auth = .{ .methods = .{ .magic_link = .{ .auto_create = false } } } },
          });
      }

      const col = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "ml_noac")).?;
      };

      var req = env.ctx(a, .POST, "{\"identity\":\"ghost@x.io\"}", &[_]http.Param{});
      var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

      var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
      const am = m.method();
      const res = try am.vtable.initiate(am.ctx, &ac);
      try std.testing.expectEqual(@as(u16, 204), res.status);

      // Record must NOT exist
      const w2 = env.pool.acquireWriter();
      defer env.pool.releaseWriter();
      const col2 = (try collections.get(a, w2, "ml_noac")).?;
      var req2 = env.ctx(a, .POST, "", &[_]http.Param{});
      var ac2 = AuthCtx{ .app = &env.app, .ctx = &req2, .collection = col2, .config = .null };
      const rid = try ac2.findByIdentity(w2, "ghost@x.io");
      try std.testing.expectEqual(@as(?[]const u8, null), rid);
  }
  ```

  Test C — `auto_create initiate then complete succeeds end-to-end`:
  ```zig
  test "MagicLinkMethod: auto_create initiate then complete succeeds end-to-end" {
      const http = @import("../../http.zig");
      const collections = @import("../../collections.zig");
      const schema_mod = @import("../../schema.zig");

      var env = try api_auth.TestEnv.initAuth("ml_e2e");
      defer env.deinit();
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();

      {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          const existing = (try collections.get(a, w, "ml_e2e")).?;
          try collections.delete(a, w, existing.id);
          _ = try collections.create(a, std.testing.io, w, .{
              .id = "", .name = "ml_e2e", .type = .auth,
              .fields = &[_]schema_mod.Field{},
              .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
              .options = .{ .auth = .{ .methods = .{ .magic_link = .{ .auto_create = true } } } },
          });
      }

      const col = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "ml_e2e")).?;
      };

      // initiate creates the record
      var req_init = env.ctx(a, .POST, "{\"identity\":\"fresh@x.io\"}", &[_]http.Param{});
      var ac_init = AuthCtx{ .app = &env.app, .ctx = &req_init, .collection = col, .config = .null };
      var m = try MagicLinkMethod.create(std.testing.allocator, std.testing.io, .{});
      const am = m.method();
      _ = try am.vtable.initiate(am.ctx, &ac_init);

      // Retrieve the rid + mint a fresh token directly (bypass opaque mailer delivery)
      var token: []const u8 = undefined;
      var rid_buf: [64]u8 = undefined;
      var rid_len: usize = 0;
      {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          const col2 = (try collections.get(a, w, "ml_e2e")).?;
          var req_mint = env.ctx(a, .POST, "", &[_]http.Param{});
          var ac_mint = AuthCtx{ .app = &env.app, .ctx = &req_mint, .collection = col2, .config = .null };
          const rid = (try ac_mint.findByIdentity(w, "fresh@x.io")).?;
          @memcpy(rid_buf[0..rid.len], rid);
          rid_len = rid.len;
          token = try ac_mint.mintLinkToken(w, rid, 900, .{});
      }

      // complete resolves to the auto-created record's id
      const body = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\"}}", .{token});
      var req_comp = env.ctx(a, .POST, body, &[_]http.Param{});
      const col3 = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "ml_e2e")).?;
      };
      var ac_comp = AuthCtx{ .app = &env.app, .ctx = &req_comp, .collection = col3, .config = .null };
      const res = try am.vtable.complete(am.ctx, &ac_comp);
      switch (res) {
          .record => |r| try std.testing.expectEqualStrings(rid_buf[0..rid_len], r),
          .fail => |f| {
              std.debug.print("Expected .record, got .fail: {d} {s}\n", .{ f.status, f.message });
              return error.TestFailed;
          },
      }
  }
  ```

- [ ] **Step 2: Run, verify new tests fail** (existing suite still passes, new tests fail).

- [ ] **Step 3: Implement** the `auto_create` branch in `src/auth/methods/magic_link.zig`'s `initiateImpl` per the design above.

- [ ] **Step 4: Run, verify all tests pass** including new ones. Check suite count increased by 3.

- [ ] **Step 5: Commit** — `feat(auth): magic_link initiate respects auto_create — create account for unknown identity`

---

## Task 3: Wire `auto_create` into `otp.zig`'s `initiateImpl`

**Files to modify:**
- `src/auth/methods/otp.zig`

### Key design note on locking

OTP `initiateImpl` already acquires the WRITER (for `ChallengeStore.put`). The `auto_create` path fits naturally inside the same writer block — call `ac.resolveOrCreate(w.conn, email, auto_create)` instead of `ac.findByIdentity(w.conn, email)`. No locking change needed.

Revised pseudocode for the writer block in `initiateImpl` (replace the `if (try ac.findByIdentity...)` line):

```zig
const auto_create: bool =
    if (ac.collection.options.auth.methods.otp) |o| o.auto_create else false;

var pending: ?struct { email: []const u8, code: []const u8 } = null;
{
    var w = ac.writer();
    defer w.deinit();

    // resolveOrCreate: returns existing rid, creates one if auto_create=true + unknown, or null
    if (try ac.resolveOrCreate(w.conn, email, auto_create)) |_| {
        const code = try ac.ctx.allocator.alloc(u8, length);
        generateCode(ac.app.io, code);
        const store = ChallengeStore{ .conn = w.conn };
        _ = try store.put(ac.ctx.allocator, ac.app.io, ac.collection.name, "otp", email, code, ttl_s);
        pending = .{ .email = email, .code = code };
    }
}
// SMTP send outside lock, as before.
```

Note: `resolveOrCreate` returns the record id, which OTP `initiate` doesn't need (the challenge is keyed by identity, not rid). The `if (... |_|)` pattern discards the id and only branches on found/created vs not-found.

### Steps

- [ ] **Step 1: Write the failing tests** in `src/auth/methods/otp.zig`:

  Test A — `initiate with auto_create=true + unknown identity creates record and stores code`:
  ```zig
  test "OtpMethod: initiate auto_create=true creates record for unknown identity" {
      const http = @import("../../http.zig");
      const collections = @import("../../collections.zig");
      const schema_mod = @import("../../schema.zig");

      var env = try api_auth.TestEnv.initAuth("otp_ac");
      defer env.deinit();
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();

      {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          const existing = (try collections.get(a, w, "otp_ac")).?;
          try collections.delete(a, w, existing.id);
          _ = try collections.create(a, std.testing.io, w, .{
              .id = "", .name = "otp_ac", .type = .auth,
              .fields = &[_]schema_mod.Field{},
              .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
              .options = .{ .auth = .{ .methods = .{ .otp = .{ .auto_create = true } } } },
          });
      }

      const col = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "otp_ac")).?;
      };

      var req = env.ctx(a, .POST, "{\"identity\":\"brand_new@x.io\"}", &[_]http.Param{});
      var ac = AuthCtx{ .app = &env.app, .ctx = &req, .collection = col, .config = .null };

      var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
      const am = m.method();
      const res = try am.vtable.initiate(am.ctx, &ac);
      try std.testing.expectEqual(@as(u16, 204), res.status);

      // Record now exists
      const w2 = env.pool.acquireWriter();
      defer env.pool.releaseWriter();
      const col2 = (try collections.get(a, w2, "otp_ac")).?;
      var req2 = env.ctx(a, .POST, "", &[_]http.Param{});
      var ac2 = AuthCtx{ .app = &env.app, .ctx = &req2, .collection = col2, .config = .null };
      const rid = try ac2.findByIdentity(w2, "brand_new@x.io");
      try std.testing.expect(rid != null);
  }
  ```

  Test B — `initiate auto_create=false + unknown identity creates nothing`:
  (Mirror magic_link Test B structure; use collection name `"otp_noac"`, `auto_create = false`.)

  Test C — `auto_create initiate then complete succeeds end-to-end`:
  ```zig
  test "OtpMethod: auto_create initiate then complete succeeds end-to-end" {
      const http = @import("../../http.zig");
      const collections = @import("../../collections.zig");
      const schema_mod = @import("../../schema.zig");

      var env = try api_auth.TestEnv.initAuth("otp_e2e");
      defer env.deinit();
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();

      {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          const existing = (try collections.get(a, w, "otp_e2e")).?;
          try collections.delete(a, w, existing.id);
          _ = try collections.create(a, std.testing.io, w, .{
              .id = "", .name = "otp_e2e", .type = .auth,
              .fields = &[_]schema_mod.Field{},
              .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
              .options = .{ .auth = .{ .methods = .{ .otp = .{ .auto_create = true } } } },
          });
      }

      const col = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "otp_e2e")).?;
      };

      // initiate creates record + stores a code (unknown to us — consume and replace)
      var req_init = env.ctx(a, .POST, "{\"identity\":\"fresh@x.io\"}", &[_]http.Param{});
      var ac_init = AuthCtx{ .app = &env.app, .ctx = &req_init, .collection = col, .config = .null };
      var m = try OtpMethod.create(std.testing.allocator, std.testing.io, .{});
      const am = m.method();
      _ = try am.vtable.initiate(am.ctx, &ac_init);

      // Consume the auto-stored code and replace with a known one
      {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          const cs = challenge_store.ChallengeStore{ .conn = w };
          _ = try cs.takeByIdentity(a, "otp_e2e", "otp", "fresh@x.io");
          _ = try cs.put(a, std.testing.io, "otp_e2e", "otp", "fresh@x.io", "999999", 300);
      }

      const col2 = blk: {
          const w = env.pool.acquireWriter();
          defer env.pool.releaseWriter();
          break :blk (try collections.get(a, w, "otp_e2e")).?;
      };
      const body = "{\"identity\":\"fresh@x.io\",\"code\":\"999999\"}";
      var req_comp = env.ctx(a, .POST, body, &[_]http.Param{});
      var ac_comp = AuthCtx{ .app = &env.app, .ctx = &req_comp, .collection = col2, .config = .null };
      const res = try am.vtable.complete(am.ctx, &ac_comp);
      switch (res) {
          .record => {},
          .fail => |f| {
              std.debug.print("Expected .record, got .fail: {d} {s}\n", .{ f.status, f.message });
              return error.TestFailed;
          },
      }
  }
  ```

- [ ] **Step 2: Run, verify new tests fail.**

- [ ] **Step 3: Implement** the `auto_create` branch in `src/auth/methods/otp.zig`'s `initiateImpl` per the design above.

- [ ] **Step 4: Run, verify all tests pass.** Suite count increases by ~3.

- [ ] **Step 5: Commit** — `feat(auth): otp initiate respects auto_create — create account for unknown identity`

---

## Task 4: Docs + changelog fragment

**Files to modify:**
- `docs/framework.md`
- `site/src/content/docs/framework.md`
- `changelog.d/auto-create-auth.md` (NEW — one fragment file only)

### Steps

- [ ] **Step 1: Update `docs/framework.md`** table row for `magic_link` and `otp`.

  Current (around line 398–399 in `docs/framework.md`, line 363–364 in the site mirror):
  ```
  | Magic link | `magic_link` | `ttl_s: i64` (default 900), `auto_create: bool` (default false) | initiate emails link; complete verifies+consumes |
  | OTP | `otp` | `length: u8` (default 6), `ttl_s: i64` (default 300) | initiate emails code; complete verifies code |
  ```

  Replace with:
  ```
  | Magic link | `magic_link` | `ttl_s: i64` (default 900), `auto_create: bool` (default false) | when `auto_create=true`, provisions an account for unknown identities; initiate emails link; complete verifies+consumes |
  | OTP | `otp` | `length: u8` (default 6), `ttl_s: i64` (default 300), `auto_create: bool` (default false) | when `auto_create=true`, provisions an account for unknown identities; initiate emails code; complete verifies code |
  ```

  Also add a note in the prose below the table (after the `rate_limit` bullet list paragraph, before the example block):
  ```
  > **`auto_create`** (on `magic_link` and `otp`, default `false`) — when `true`, `initiate` automatically provisions a passwordless auth record (`verified = false`) for email addresses not yet in the collection, then sends the link/code as usual. Enables "sign up or sign in" with a single step. **Note:** auto-created accounts have `verified = false`; if the collection also sets `require_verified = true`, those accounts cannot log in until verified. Consider whether to pair these settings.
  ```

- [ ] **Step 2: Mirror the same changes** to `site/src/content/docs/framework.md` (identical edits at the corresponding line numbers — site mirror is around line 363).

- [ ] **Step 3: Create `changelog.d/auto-create-auth.md`**:
  ```markdown
  ### Features

  - `magic_link` and `otp` auth methods now honour `auto_create: true` — when an unknown identity calls `initiate`, a passwordless account is provisioned automatically (email set from the identity, `verified = false`) and the link or code is sent as usual. Enables "sign up or sign in" in one step. Accounts are created with `verified = false`; pair with `require_verified` only when a verification flow is in place.
  ```

- [ ] **Step 4: Run full test suite one final time**, confirm green.

- [ ] **Step 5: Commit** — `docs(auth): document auto_create now works for magic_link and otp; add changelog fragment`

---

## Task count summary

| Task | Steps | New tests |
|---|---|---|
| 1: `resolveOrCreate` helper | 5 | 3 |
| 2: magic_link wiring | 5 | 3 |
| 3: otp wiring | 5 | ~3 |
| 4: docs + changelog | 5 | 0 |
| **Total** | **20** | **~9** |

---

## Open Questions / Risks

1. **`records.create` error for unique collision** (`src/records.zig:550–580`): `createImpl` returns `error.Validation` when `errs.items.len > 0`. A SQLite UNIQUE constraint violation on INSERT fires as a raw `db.DbError` (e.g. `error.Constraint`), not wrapped as `error.Validation`. **Before implementing Task 1 Step 3, check exactly what error `records.create` returns on a duplicate email insert.** The collision-recovery catch in `resolveOrCreate` may need to catch `error.Constraint` or `error.SQLITE_CONSTRAINT` instead of `error.Validation`. Read `src/db.zig` for the error mapping of `SQLITE_CONSTRAINT`.

2. **`mintLinkToken` under writer lock (magic_link auto_create path)**: `mintLinkToken` reads `tokenKey` from the DB via `auth_helpers.mintLinkToken → api_auth.tokenKeyFor`. That is a SELECT — fine to run while holding the writer in WAL mode. No issue expected.

3. **Locking upgrade for magic_link**: The existing non-auto_create path uses a READER. The plan uses a WRITER only when `auto_create=true`. This correctly preserves the existing non-serializing read path for the common (auto_create=false) case.

4. **Identity-field mapping for non-email collections**: The plan sets all `identityFields` from the single submitted `identity` string. For `email`-only collections (the default) this is unambiguous. For `username`-only or dual-field collections, the submitted `identity` becomes both fields — which may produce non-email usernames. Acceptable for v1; document in the `auto_create` note in `docs/framework.md` that auto_create works best with single-field `identityFields`.

5. **No `OTP complete` change needed**: `completeImpl` already calls `findByIdentity` after verifying the code (`otp.zig:163`). Since the auto-created record is findable by the identity it was created with, `complete` will resolve it with zero changes.
