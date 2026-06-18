# ZigBase TS SDK — SP2.1b Plan 2 (Validation & Grounding) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the generated typed client is correct at the type level and against a live server running the exact comptime schema it was generated from, and ground it in the golfsim example.

**Architecture:** Refine the dating fixture (collection-scoped photo privacy + access rules), build it as a runnable `dating-server` binary, generalize the existing TS integration harness to spawn any schema-baked binary, then add a dating e2e suite + an exhaustive `*.test-d.ts` type-level suite. Wire golfsim to the generator (hoist `pub const App`, `genClientStep`), commit its generated client, and add a self-contained golfsim e2e. Extend CI with staleness gates + the new suites; sync docs.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 -- zig …`), build.zig, TypeScript + Vitest (`mise exec node@24 -- npm …` in `clients/typescript`), GitHub Actions.

## Global Constraints

- Build/test Zig only via `mise exec zig@0.16.0 -- zig …` (plain `zig` is 0.15.2 and fails). Run from the repo/worktree root.
- TS: run from `clients/typescript` via `mise exec node@24 -- npm …`. Unit/type-level = `npm test` + `npm run typecheck`; live-server e2e = `npm run test:integration` (vitest config `vitest.integration.config.ts`, `pool: forks`, `fileParallelism: false`).
- `zig build test` prints a `failed command: …/test …` line plus provision warnings even on SUCCESS (exit 0) — judge by exit code 0 + absence of real `error:`/`panic`/assertion-failure lines, not that line.
- Access-rule sentinels: `null` = locked/superuser-only; `""` = also locked; `"@public"` = allow-all; `"@request.auth.id != \"\""` = any authed user; expression rules like `"@request.auth.id = owner"` are owner-scoped. File access to a record is gated identically to that record's `viewRule`.
- The committed generated clients are build artifacts: never hand-edit `zbase.gen.ts`; regenerate via `zig build gen-dating-client` (dating) / `zig build gen-client` (golfsim) and commit. CI runs `--check` staleness gates.
- No flaky e2e: synchronize realtime/file tests on explicit polled conditions (`waitFor`), never fixed sleeps.
- Keep published docs/examples in sync (golfsim README, `site/` mirror, `docs/*.md`).

---

## File Structure

- `fixtures/dating/schema.zig` — **modify**: add `.rules` to every collection, drop `visibility` from `photos`, add `privatePhotos`.
- `clients/typescript/test/codegen/dating/zbase.gen.ts` — **regenerated** (build artifact).
- `clients/typescript/test/codegen/dating/typecheck.ts` — **delete** (superseded by the `.test-d.ts` suite).
- `build.zig` — **modify**: add a `dating-server` executable target + `zig build dating-server` step.
- `clients/typescript/test/integration/harness.ts` — **modify**: add `startAppServer({ bin, seedSuperuser })`; refactor `startServer` to use it.
- `clients/typescript/test/integration/dating.integration.test.ts` — **create**: live dating e2e.
- `clients/typescript/test/codegen/dating/zbase.gen.test-d.ts` — **create**: type-level suite.
- `examples/golfsim/src/main.zig` — **modify**: hoist `pub const App`; `main` calls `App.runCli`.
- `examples/golfsim/build.zig` — **modify**: wire `genClientStep` + `gen-client`/`gen-client-check` steps.
- `examples/golfsim/build.zig.zon` — **modify/verify**: `zigbase` dependency present (for `@import("zigbase")` in build.zig).
- `examples/golfsim/clients/typescript/zbase.gen.ts` — **create** (committed generated golfsim client).
- `examples/golfsim/package.json`, `examples/golfsim/tsconfig.json`, `examples/golfsim/vitest.config.ts`, `examples/golfsim/test/golfsim.e2e.test.ts`, `examples/golfsim/test/harness.ts` — **create**: self-contained golfsim e2e.
- `.github/workflows/ci.yml` — **modify**: staleness gates + new suites in the `ts-sdk` job (+ build the binaries).
- `examples/golfsim/README.md`, `site/` mirror, `docs/*.md` codegen pages — **modify**: docs sync.

---

## Task 1: Dating fixture refinement + regenerate golden

**Files:**
- Modify: `fixtures/dating/schema.zig`
- Regenerate: `clients/typescript/test/codegen/dating/zbase.gen.ts`
- Delete: `clients/typescript/test/codegen/dating/typecheck.ts`

**Interfaces:**
- Produces: a refined dating schema where `photos` is public (no `visibility` field) and a new auth-required `privatePhotos` collection exists (fields `owner: relation→profiles`, `image: file`, `caption: text`), all collections carry `.rules`. The regenerated golden gains `PrivatePhoto*` symbols and drops `PhotoVisibility`/`photos.visibility`.
- **Naming:** the collection is `privatePhotos` (camelCase), the project's first multi-word collection. camelCase is the generator's proven path (camelCase field names like `sentAt` already round-trip), so it deterministically yields `PrivatePhoto` (record), `PrivatePhotosService`, `PrivatePhotoFileField`, and `db.privatePhotos` — avoiding any ambiguity in how an underscore would map through `pascal`/`recordName`. Step 4 confirms the exact symbol; if it differs, Tasks 4 & 5 must use the actual generated name.

- [ ] **Step 1: Rewrite the dating fixture with rules + privatePhotos.** Replace `fixtures/dating/schema.zig` `.collections` block. Final file:

```zig
//! The SP2.1b dating-app coverage fixture — exercises every schema capability in
//! one coherent domain. The generator reads this via @import("app").App.collections.
//! Plan 2: collection-scoped photo privacy (public `photos` vs auth-required
//! `privatePhotos`) + access rules so a live client can exercise the API.
const std = @import("std");
const zigbase = @import("zigbase");

pub const App = zigbase.App(.{
    .collections = .{
        .profiles = .{
            .type = .auth,
            .fields = .{
                .{ .name = "name", .type = .text },
                .{ .name = "bio", .type = .editor },
                .{ .name = "website", .type = .url },
                .{ .name = "age", .type = .number, .mode = .int },
                .{ .name = "gender", .type = .select, .values = .{ "female", "male", "nonbinary", "other" } },
                .{ .name = "avatar", .type = .file },
            },
            // Public signup + public profile browsing; self-service edits.
            .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
        },
        .tags = .{
            .fields = .{
                .{ .name = "label", .type = .text, .required = true, .unique = true },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@public", .delete = "@public" },
        },
        .photos = .{
            .fields = .{
                .{ .name = "owner", .type = .relation, .target = "profiles" },
                .{ .name = "image", .type = .file },
                .{ .name = "caption", .type = .text },
                .{ .name = "tags", .type = .relation, .target = "tags", .maxSelect = 20 },
            },
            // Public photos: anyone can browse; create/edit need auth.
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
        // Private photos as a separate dependent collection (no per-field privacy):
        // owner-only list/view, so the IMAGE FILE is gated by the auth-required
        // viewRule — accessing it requires a files/token. Individual records so a
        // future feature could grant access to a specific private photo.
        .privatePhotos = .{
            .fields = .{
                .{ .name = "owner", .type = .relation, .target = "profiles" },
                .{ .name = "image", .type = .file },
                .{ .name = "caption", .type = .text },
            },
            .rules = .{ .list = "@request.auth.id = owner", .view = "@request.auth.id = owner", .create = "@request.auth.id != \"\"", .update = "@request.auth.id = owner", .delete = "@request.auth.id = owner" },
        },
        .messages = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "body", .type = .text, .required = true },
                .{ .name = "sentAt", .type = .autodate, .onCreate = true },
                .{ .name = "read", .type = .@"bool" },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
        .winks = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "createdAt", .type = .autodate, .onCreate = true },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
        .subscriptions = .{
            .fields = .{
                .{ .name = "profile", .type = .relation, .target = "profiles" },
                .{ .name = "plan", .type = .select, .values = .{ "free", "plus", "premium" } },
                .{ .name = "price", .type = .number, .mode = .fixed, .scale = 2 },
                .{ .name = "renewsAt", .type = .date, .min = "2020-01-01", .max = "2099-12-31" },
                .{ .name = "active", .type = .@"bool" },
                .{ .name = "metadata", .type = .json },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
    },
});

// The generator's `app` module import resolves `App.collections`. A thin `main`
// keeps the module runnable as a normal zigbase app (Task 2 builds it as a server).
pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
```

- [ ] **Step 2: Verify the fixture compiles.** Run: `mise exec zig@0.16.0 -- zig build`. Expected: exit 0, no `error:`.

- [ ] **Step 3: Regenerate the golden.** Run: `mise exec zig@0.16.0 -- zig build gen-dating-client`. Expected: `info: gen_client: wrote clients/typescript/test/codegen/dating/zbase.gen.ts (… bytes)`.

- [ ] **Step 4: Verify the golden reflects the refinement.** Run:
```bash
grep -c "PrivatePhoto" clients/typescript/test/codegen/dating/zbase.gen.ts   # > 0
grep -c "PhotoVisibility\|visibility" clients/typescript/test/codegen/dating/zbase.gen.ts  # 0
```
Expected: `PrivatePhoto` symbols present; no `PhotoVisibility`/`visibility`.

- [ ] **Step 5: Verify the byte-exact golden test + staleness gate pass.** Run: `mise exec zig@0.16.0 -- zig build gen-test` then `mise exec zig@0.16.0 -- zig build gen-dating-client-check`. Expected: both exit 0.

- [ ] **Step 6: Delete the superseded smoke + confirm typecheck.** Delete `clients/typescript/test/codegen/dating/typecheck.ts`. Run: `cd clients/typescript && mise exec node@24 -- npm run typecheck`. Expected: exit 0 (the golden is valid TS; the smoke is replaced by Task 5's `.test-d.ts`).

- [ ] **Step 7: Commit.**
```bash
git add fixtures/dating/schema.zig clients/typescript/test/codegen/dating/zbase.gen.ts
git rm clients/typescript/test/codegen/dating/typecheck.ts
git commit -m "feat(ts-sdk): dating fixture — collection-scoped photo privacy + access rules; regenerate golden"
```

---

## Task 2: `dating-server` build target

**Files:**
- Modify: `build.zig` (add after the existing main-exe block, ~line 44)

**Interfaces:**
- Consumes: `fixtures/dating/schema.zig` (its `pub fn main` / `pub const App`).
- Produces: `zig build dating-server` → installs `zig-out/bin/dating-server`, a runnable zigbase server for the dating schema (subcommands `serve` / `migrate` / `superuser create`). Used by the harness in Task 3.

- [ ] **Step 1: Add the dating-server exe target.** In `build.zig`, after the main `zigbase` exe block (the `run_step` for "Run zigbase"), insert:

```zig
// --- dating-server: the dating fixture compiled as a runnable server ----------
// Plan 2: the e2e harness spawns THIS binary so client and server share the exact
// comptime schema the dating client was generated from. Links libc (facil.io C deps).
const dating_srv_mod = b.createModule(.{
    .root_source_file = b.path("fixtures/dating/schema.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
dating_srv_mod.addImport("zigbase", zigbase_mod);
const dating_srv_exe = b.addExecutable(.{ .name = "dating-server", .root_module = dating_srv_mod });
const dating_srv_step = b.step("dating-server", "Build the dating fixture as a runnable server");
dating_srv_step.dependOn(&b.addInstallArtifact(dating_srv_exe, .{}).step);
```

- [ ] **Step 2: Build the target.** Run: `mise exec zig@0.16.0 -- zig build dating-server`. Expected: exit 0, `zig-out/bin/dating-server` exists (`ls zig-out/bin/dating-server`).

- [ ] **Step 3: Smoke-run the server.** Run this one-liner (seeds a superuser, serves, health-checks, tears down):
```bash
D=$(mktemp -d); ./zig-out/bin/dating-server superuser create --email a@b.c --password test-password-123 --data-dir "$D" && \
./zig-out/bin/dating-server serve --http-port 28099 --data-dir "$D" --insecure-cookies & SRV=$!; \
sleep 1; curl -fsS http://127.0.0.1:28099/api/health && echo " OK"; kill $SRV; rm -rf "$D"
```
Expected: `{"status":"ok"...}` (or similar) + ` OK`.

- [ ] **Step 4: Confirm the full build/test still passes.** Run: `mise exec zig@0.16.0 -- zig build` then `mise exec zig@0.16.0 -- zig build test`. Expected: exit 0 (ignore the harness `failed command:` line per Global Constraints).

- [ ] **Step 5: Commit.**
```bash
git add build.zig
git commit -m "feat(build): dating-server target — dating fixture as a runnable server"
```

---

## Task 3: Generalize the integration harness

**Files:**
- Modify: `clients/typescript/test/integration/harness.ts`

**Interfaces:**
- Consumes: `zig-out/bin/dating-server` (Task 2).
- Produces:
  - `startAppServer(opts: { bin: string; seedSuperuser?: { email: string; password: string } }): Promise<TestServer>` — spawns a schema-baked binary (absolute path or a name under `zig-out/bin/`), seeds a superuser, health-polls, returns `{ url, superuser, stop }`.
  - `DATING_BIN: string` — absolute path to `zig-out/bin/dating-server`.
  - existing `startServer()` / `superuserToken()` / `createCollection()` unchanged in signature (the 4 existing integration tests keep working).

- [ ] **Step 1: Refactor harness.ts to add the generalized spawn path.** Replace the body of `harness.ts` from the `BIN` const through `startServer` with:

```typescript
const BIN = join(REPO_ROOT, "zig-out", "bin", "zigbase");
/** Absolute path to the dating fixture compiled as a server (Task 2: `zig build dating-server`). */
export const DATING_BIN = join(REPO_ROOT, "zig-out", "bin", "dating-server");

export interface TestServer {
  url: string;
  superuser: { email: string; password: string };
  stop(): void;
}

let built = false;
function ensureBuilt(): void {
  if (built) return;
  // The binary MUST be built with zig 0.16.0; plain `zig` on PATH may be older.
  const r = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build", "dating-server"], {
    cwd: REPO_ROOT,
    stdio: "inherit",
  });
  if (r.status !== 0) throw new Error("zig build failed");
  built = true;
}

async function waitForHealth(url: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const res = await fetch(`${url}/api/health`);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    if (Date.now() > deadline) throw new Error("server did not become healthy");
    await new Promise((r) => setTimeout(r, 200));
  }
}

/**
 * Spawn an already-built zigbase app binary (schema baked in), seed a superuser,
 * and wait for health. `bin` may be an absolute path (e.g. DATING_BIN) or a bare
 * name resolved under zig-out/bin/.
 */
export async function startAppServer(opts: {
  bin: string;
  seedSuperuser?: { email: string; password: string };
}): Promise<TestServer> {
  ensureBuilt();
  const bin = opts.bin.includes("/") ? opts.bin : join(REPO_ROOT, "zig-out", "bin", opts.bin);
  const dataDir = mkdtempSync(join(tmpdir(), "zb-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const { email, password } = opts.seedSuperuser ?? {
    email: "admin@test.local",
    password: "test-password-123",
  };

  const su = spawnSync(
    bin,
    ["superuser", "create", "--email", email, "--password", password, "--data-dir", dataDir],
    { stdio: "inherit" },
  );
  if (su.status !== 0) throw new Error("superuser create failed");

  const proc: ChildProcess = spawn(
    bin,
    ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"],
    { stdio: "inherit" },
  );

  const url = `http://127.0.0.1:${port}`;
  await waitForHealth(url);

  return {
    url,
    superuser: { email, password },
    stop() {
      proc.kill("SIGTERM");
      try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
    },
  };
}

/** Backward-compatible: spawn the generic zigbase binary (runtime-created collections). */
export async function startServer(): Promise<TestServer> {
  // Ensure the generic binary is built too (the existing tests create collections at runtime).
  const r = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], { cwd: REPO_ROOT, stdio: "inherit" });
  if (r.status !== 0) throw new Error("zig build failed");
  return startAppServer({ bin: BIN });
}
```
Keep `superuserToken()` and `createCollection()` exactly as they are below this block.

- [ ] **Step 2: Verify the existing integration tests still pass.** Run: `cd clients/typescript && mise exec node@24 -- npm run test:integration`. Expected: all existing integration test files pass (records/auth/realtime/typed-blog). (This builds both the generic binary and dating-server.)

- [ ] **Step 3: Commit.**
```bash
git add clients/typescript/test/integration/harness.ts
git commit -m "feat(ts-sdk): generalize integration harness — startAppServer for schema-baked binaries"
```

---

## Task 4: Dating live-binary e2e suite

**Files:**
- Create: `clients/typescript/test/integration/dating.integration.test.ts`
- Test: itself (vitest integration config)

**Interfaces:**
- Consumes: `startAppServer`, `DATING_BIN` (Task 3); `createClient` + types from the regenerated `../codegen/dating/zbase.gen.js` (Task 1).

- [ ] **Step 1: Write the dating e2e.** Create `clients/typescript/test/integration/dating.integration.test.ts`:

```typescript
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startAppServer, DATING_BIN, type TestServer } from "./harness.js";
import { createClient } from "../codegen/dating/zbase.gen.js";

let server: TestServer;

beforeAll(async () => {
  server = await startAppServer({ bin: DATING_BIN });
});
afterAll(() => server?.stop());

/** Poll until cond() is true or timeoutMs elapses (no fixed sleeps). */
function waitFor(cond: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (cond()) return resolve();
      if (Date.now() > deadline) return reject(new Error("timeout waiting for condition"));
      setTimeout(tick, 25);
    };
    tick();
  });
}

/** Register a profile (public signup) and authenticate it; returns an authed client + the profile. */
async function authedProfile(email: string) {
  const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
  const profile = await zb.db.profiles.create({
    email,
    password: "member-pass-1",
    passwordConfirm: "member-pass-1",
    name: email.split("@")[0]!,
  });
  await zb.db.profiles.authWithPassword(email, "member-pass-1");
  return { zb, profile };
}

describe("dating client (live dating-server)", () => {
  it("CRUD + nested-relation filter + expand (single & multi) + native cursor", async () => {
    const { zb, profile } = await authedProfile("crud@d.app");
    const t1 = await zb.db.tags.create({ label: "hiking" });
    const t2 = await zb.db.tags.create({ label: "coffee" });

    // create photos owned by the profile, tagged.
    const p1 = await zb.db.photos.create({ owner: profile.id, caption: "trail", tags: [t1.id, t2.id] });
    await zb.db.photos.create({ owner: profile.id, caption: "espresso", tags: [t2.id] });
    expect(p1.id.length).toBeGreaterThan(0);

    // nested-relation filter: photos whose owner.name matches.
    const byOwner = await zb.db.photos.getList({ where: { owner: { name: { like: profile.name } } } });
    expect(byOwner.items.length).toBe(2);

    // expand single (owner -> Profile) and multi (tags -> Tag[]).
    const withOwner = await zb.db.photos.getOne(p1.id, { expand: ["owner"] });
    expect(withOwner.expand.owner.id).toBe(profile.id);
    const withTags = await zb.db.photos.getOne(p1.id, { expand: ["tags"] });
    expect(withTags.expand.tags.map((t) => t.label).sort()).toEqual(["coffee", "hiking"]);

    // update + delete.
    const upd = await zb.db.photos.update(p1.id, { caption: "summit" });
    expect(upd.caption).toBe("summit");
    await zb.db.photos.delete(p1.id);
    const remaining = await zb.db.photos.getList({ where: { owner: profile.id } });
    expect(remaining.items.length).toBe(1);

    // native cursor: walk the 2 tags one per page.
    const page1 = await zb.db.tags.getPage({ limit: 1, sort: "-created" });
    expect(page1.items.length).toBe(1);
    expect(page1.hasNext).toBe(true);
    const page2 = await zb.db.tags.getPage({ limit: 1, sort: "-created", cursor: page1.nextCursor! });
    expect(page2.items[0]!.id).not.toBe(page1.items[0]!.id);
  });

  it("realtime create -> typed event", async () => {
    const { zb, profile } = await authedProfile("rt@d.app");
    const events: string[] = [];
    const off = await zb.realtime.photos.subscribe((e) => events.push(`${e.action}:${e.record.id}`));
    const made = await zb.db.photos.create({ owner: profile.id, caption: "live" });
    await waitFor(() => events.some((s) => s === `create:${made.id}`), 5000);
    off();
    expect(events.some((s) => s === `create:${made.id}`)).toBe(true);
  });

  it("file upload: public avatar via fileUrl; private photo gated, accessible only with a token", async () => {
    const { zb, profile } = await authedProfile("files@d.app");

    // public avatar on the (public) profile -> fileUrl is fetchable anonymously.
    const avatar = new File([new Uint8Array([1, 2, 3, 4])], "a.png", { type: "image/png" });
    const withAvatar = await zb.db.profiles.update(profile.id, { avatar });
    const avatarUrl = zb.db.profiles.fileUrl(withAvatar, "avatar");
    const pub = await fetch(avatarUrl);
    expect(pub.ok).toBe(true);

    // private photo: owner-only view -> the image file is gated by the viewRule.
    const img = new File([new Uint8Array([5, 6, 7, 8])], "secret.png", { type: "image/png" });
    const priv = await zb.db.privatePhotos.create({ owner: profile.id, image: img, caption: "hidden" });
    const privUrlNoTok = zb.db.privatePhotos.fileUrl(priv, "image");

    // Anonymous fetch (no token) is denied.
    const anon = await fetch(privUrlNoTok);
    expect(anon.ok).toBe(false);

    // With a fresh file-access token (owner is authed), the file is fetchable.
    const token = await zb.files.getToken();
    const privUrlTok = zb.db.privatePhotos.fileUrl(priv, "image", { token });
    const ok = await fetch(privUrlTok);
    expect(ok.ok).toBe(true);
  });
});
```

- [ ] **Step 2: Run the dating e2e.** Run: `cd clients/typescript && mise exec node@24 -- npm run test:integration -- dating`. Expected: `dating.integration.test.ts` passes (3 tests). If `privatePhotos` file gating behaves unexpectedly, confirm the fixture's `privatePhotos` `viewRule` is `"@request.auth.id = owner"` (Task 1) and that `getToken()` is called while authed as the owner.

- [ ] **Step 3: Run the whole integration suite (no regressions).** Run: `cd clients/typescript && mise exec node@24 -- npm run test:integration`. Expected: all pass.

- [ ] **Step 4: Commit.**
```bash
git add clients/typescript/test/integration/dating.integration.test.ts
git commit -m "test(ts-sdk): dating live-binary e2e — CRUD/filter/expand/cursor/realtime/file privacy"
```

---

## Task 5: Dating type-level (`*.test-d.ts`) suite

**Files:**
- Create: `clients/typescript/test/codegen/dating/zbase.gen.test-d.ts`

**Interfaces:**
- Consumes: `createClient` + types from `./zbase.gen.js` (the regenerated golden).

- [ ] **Step 1: Write the type-level suite.** Create `clients/typescript/test/codegen/dating/zbase.gen.test-d.ts`:

```typescript
import { expectTypeOf, assertType } from "vitest";
import { createClient } from "./zbase.gen.js";
import type {
  Profile, Tag, Photo, PrivatePhoto, Subscription,
  ProfileCreate, PhotoCreate, ProfileGender, SubscriptionPlan,
} from "./zbase.gen.js";

const zb = createClient("http://api.test", { WebSocket: globalThis.WebSocket });

// --- field -> TS mapping -----------------------------------------------------
function recordShapes() {
  expectTypeOf<Profile["age"]>().toEqualTypeOf<number>();        // number
  expectTypeOf<Profile["website"]>().toEqualTypeOf<string>();    // url -> string
  expectTypeOf<Profile["gender"]>().toEqualTypeOf<ProfileGender>(); // select union
  expectTypeOf<Profile["avatar"]>().toEqualTypeOf<string>();     // file -> filename
  expectTypeOf<Photo["tags"]>().toEqualTypeOf<string[]>();       // multi relation -> string[]
  expectTypeOf<Photo["owner"]>().toEqualTypeOf<string>();        // single relation -> id
  expectTypeOf<Subscription["metadata"]>().toEqualTypeOf<unknown>(); // json -> unknown
  expectTypeOf<Subscription["active"]>().toEqualTypeOf<boolean>(); // bool
  expectTypeOf<ProfileGender>().toEqualTypeOf<"female" | "male" | "nonbinary" | "other">();
  expectTypeOf<SubscriptionPlan>().toEqualTypeOf<"free" | "plus" | "premium">();
}

// --- expand narrowing (single + multi) --------------------------------------
async function expandSingle() {
  const p = await zb.db.photos.getOne("x", { expand: ["owner"] });
  expectTypeOf(p.expand.owner).toEqualTypeOf<Profile>();
}
async function expandMulti() {
  const p = await zb.db.photos.getOne("x", { expand: ["tags"] });
  expectTypeOf(p.expand.tags).toEqualTypeOf<Tag[]>();
}
async function expandList() {
  const r = await zb.db.photos.getList({ expand: ["owner"] });
  expectTypeOf(r.items[0]!.expand.owner).toEqualTypeOf<Profile>();
}
async function noExpand() {
  const p = await zb.db.photos.getOne("x");
  // @ts-expect-error owner was not expanded
  p.expand.owner;
}

// --- where: operators, nested relation, AND/OR ------------------------------
async function whereOk() {
  await zb.db.profiles.getList({ where: { age: { gte: 18 }, gender: "female" } });
  await zb.db.photos.getList({ where: { owner: { name: { like: "An" } } } }); // nested relation
  await zb.db.profiles.getList({ where: { AND: [{ age: { gt: 18 } }, { verified: true }] } });
  await zb.db.profiles.getList({ where: { OR: [{ name: { like: "a" } }, { name: { like: "b" } }] } });
}
async function whereBadOperand() {
  // @ts-expect-error age expects number/NumberOps, not a string
  await zb.db.profiles.getList({ where: { age: "old" } });
}
async function whereBadEnum() {
  // @ts-expect-error 'unknown' is not a ProfileGender
  await zb.db.profiles.getList({ where: { gender: "unknown" } });
}
async function whereUnknownField() {
  // @ts-expect-error `nope` is not a field
  await zb.db.profiles.getList({ where: { nope: 1 } });
}

// --- create/update ----------------------------------------------------------
async function createOk() {
  await zb.db.profiles.create({ email: "a@b.c", password: "p", passwordConfirm: "p" });
  await zb.db.photos.create({ owner: "id1", caption: "hi" });
}
function fileTyping() {
  // file field is File | Blob on create.
  assertType<PhotoCreate>({ image: new Blob([]) });
  assertType<ProfileCreate>({ email: "a@b.c", password: "p", passwordConfirm: "p", avatar: new Blob([]) });
}
async function createMissingRequired() {
  // @ts-expect-error email/password/passwordConfirm are required on an auth create
  await zb.db.profiles.create({ name: "x" });
}
async function createRejectsUnknown() {
  // @ts-expect-error `slug` is not a ProfileCreate field
  await zb.db.profiles.create({ email: "a@b.c", password: "p", passwordConfirm: "p", slug: "x" });
}
function updateOmitsPassword() {
  // ProfileUpdate = Partial<Omit<ProfileCreate, password|passwordConfirm>> -> password not allowed.
  // @ts-expect-error password cannot be patched via update
  assertType<Parameters<typeof zb.db.profiles.update>[1]>({ password: "p" });
}

// --- fluent builder ---------------------------------------------------------
function fluentOk() {
  return zb.db.profiles.filter((f) => f.age.gte(18).and(f.gender.eq("female")));
}
function fluentBadEnum() {
  // @ts-expect-error 'unknown' is not a ProfileGender operand
  return zb.db.profiles.filter((f) => f.gender.eq("unknown"));
}
function fluentUnknownField() {
  // @ts-expect-error `nope` is not a fields accessor
  return zb.db.profiles.filter((f) => f.nope.eq("x"));
}

// --- service signatures + realtime alias ------------------------------------
function serviceShapes() {
  // Methods confirmed against the generated ProfilesService surface.
  expectTypeOf(zb.db.profiles.authWithPassword).toBeFunction();
  expectTypeOf(zb.db.profiles.getPage).toBeFunction();
  expectTypeOf(zb.db.profiles.getFirstListItem).toBeFunction();
  // realtime alias exists per collection.
  expectTypeOf(zb.realtime.photos.subscribe).toBeFunction();
}

// --- per-collection fileUrl typing (single-value only) ----------------------
function fileUrlTyping() {
  const profile = {} as Profile;
  // ProfileFileField is "avatar"; fileUrl accepts it.
  zb.db.profiles.fileUrl(profile, "avatar");
  // @ts-expect-error "name" is not a file field
  zb.db.profiles.fileUrl(profile, "name");
  const priv = {} as PrivatePhoto;
  zb.db.privatePhotos.fileUrl(priv, "image");
}
```

- [ ] **Step 2: Verify the type-level suite typechecks (negatives included).** Run: `cd clients/typescript && mise exec node@24 -- npm run typecheck`. Expected: exit 0 — every `@ts-expect-error` is genuinely an error (tsc fails if any is a false positive), and the positive assertions hold. If tsc reports an "Unused '@ts-expect-error'" error, that negative is wrong — fix the assertion to match the actual generated types (do NOT weaken a real check).

- [ ] **Step 3: Verify vitest runs it as part of the unit suite.** Run: `cd clients/typescript && mise exec node@24 -- npm test`. Expected: exit 0 (vitest collects `.test-d.ts` under `test/`).

- [ ] **Step 4: Commit.**
```bash
git add clients/typescript/test/codegen/dating/zbase.gen.test-d.ts
git commit -m "test(ts-sdk): exhaustive type-level suite for the generated dating client"
```

---

## Task 6: golfsim — refactor to `pub const App` + wire `genClientStep` + commit client

**Files:**
- Modify: `examples/golfsim/src/main.zig` (hoist App to module scope)
- Modify: `examples/golfsim/build.zig` (wire genClientStep)
- Modify/verify: `examples/golfsim/build.zig.zon` (zigbase dep present for `@import("zigbase")` in build.zig)
- Create: `examples/golfsim/clients/typescript/zbase.gen.ts` (committed generated client)

**Interfaces:**
- Consumes: `zigbase` build module (`genClientStep`, `GenOpts`) from the dependency's `build.zig`.
- Produces: `zig build gen-client` (in `examples/golfsim`) emits `examples/golfsim/clients/typescript/zbase.gen.ts`; `zig build gen-client-check` is the staleness gate.

- [ ] **Step 1: Hoist `pub const App` in golfsim's main.zig.** In `examples/golfsim/src/main.zig`, change the inline `pub fn main(init) { return zigbase.App(.{…}).runCli(init); }` so the config is a module-scope const and `main` delegates:

```zig
pub const App = zigbase.App(.{
    // … the entire existing config block verbatim (hooks/routes/jobs/cron/
    //    onFileUpload/pagination/static_files/collections) …
});

pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
```
(Move the exact `.{ … }` that was passed to `zigbase.App(...)` inside `main` up to the const; do not change any field.)

- [ ] **Step 2: Verify golfsim still builds + runs as before.** Run: `cd examples/golfsim && mise exec zig@0.16.0 -- zig build`. Expected: exit 0, `zig-out/bin/golfsim` builds. (Behavior unchanged — App is identical, just hoisted.)

- [ ] **Step 3: Ensure golfsim's build.zig.zon declares the zigbase dependency by name.** Confirm `examples/golfsim/build.zig.zon` has a `zigbase` dependency entry (so `@import("zigbase")` resolves the dependency's `build.zig`). Run: `grep -n "zigbase" examples/golfsim/build.zig.zon`. If absent, add it (path dependency to the repo root):
```zig
.dependencies = .{
    .zigbase = .{ .path = "../.." },
},
```

- [ ] **Step 4: Wire `genClientStep` in golfsim's build.zig.** Replace `examples/golfsim/build.zig` with:

```zig
const std = @import("std");
const zigbase_build = @import("zigbase");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zigbase", zigbase.module("zigbase"));
    const exe = b.addExecutable(.{ .name = "golfsim", .root_module = exe_mod });
    b.installArtifact(exe);

    // --- codegen: golfsim's typed client (Plan 2) ---
    // app_mod's root is the same main.zig that defines `pub const App` at module scope.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("zigbase", zigbase.module("zigbase"));

    const out = "clients/typescript/zbase.gen.ts";
    const gen = zigbase_build.genClientStep(b, zigbase, app_mod, .{ .out = out, .api_prefix = "/api", .in_repo = true });
    b.step("gen-client", "Generate the golfsim typed TS client").dependOn(&gen.step);

    const check = zigbase_build.genClientStep(b, zigbase, app_mod, .{ .out = out, .api_prefix = "/api", .check = true, .in_repo = true });
    b.step("gen-client-check", "Fail if the golfsim client snapshot is stale").dependOn(&check.step);
}
```

- [ ] **Step 5: Generate the golfsim client (verifies the external-consumer genClientStep path).** Run: `cd examples/golfsim && mise exec zig@0.16.0 -- zig build gen-client`. Expected: `info: gen_client: wrote clients/typescript/zbase.gen.ts (… bytes)`.
  - **RISK / fallback:** `genClientStep` resolves the generator source via `zigbase_dep.builder.path("src/codegen/gen_main.zig")` and was flagged "Plan-2 / unverified for external consumers" in the zigbase `build.zig`. If generation fails to resolve the generator source (e.g. a path error referencing `gen_main.zig`), this is the verification the comment anticipated: fix `genClientStepInner` in the root `build.zig` so the generator-module root + its `app` import resolve from the dependency builder (`zigbase_builder.path(...)`) rather than the consumer `b`. Re-run until `gen-client` writes the file. (Capture exactly what failed for the task report.)

- [ ] **Step 6: Typecheck the generated golfsim client in isolation.** Run: `cd examples/golfsim && mise exec node@24 -- npx tsc --noEmit clients/typescript/zbase.gen.ts` — Expected: it imports `@zigbase/client` / `@zigbase/client/typed`; if module resolution fails here, that's wired up in Task 7 (package.json). For this step just confirm the FILE was generated and is non-empty: `test -s examples/golfsim/clients/typescript/zbase.gen.ts && echo OK`.

- [ ] **Step 7: Confirm the staleness gate passes against the committed file.** Run: `cd examples/golfsim && mise exec zig@0.16.0 -- zig build gen-client-check`. Expected: exit 0 (no drift).

- [ ] **Step 8: Commit.**
```bash
git add examples/golfsim/src/main.zig examples/golfsim/build.zig examples/golfsim/build.zig.zon examples/golfsim/clients/typescript/zbase.gen.ts
git commit -m "feat(golfsim): hoist pub const App, wire genClientStep, commit generated client"
```

---

## Task 7: golfsim self-contained e2e

**Files:**
- Create: `examples/golfsim/package.json`, `examples/golfsim/tsconfig.json`, `examples/golfsim/vitest.config.ts`
- Create: `examples/golfsim/test/harness.ts`, `examples/golfsim/test/golfsim.e2e.test.ts`

**Interfaces:**
- Consumes: the committed `examples/golfsim/clients/typescript/zbase.gen.ts` (Task 6); `@zigbase/client` + `@zigbase/client/typed` (workspace link to `clients/typescript`); the built `golfsim` binary.

- [ ] **Step 1: Add golfsim's JS package wiring.** Create `examples/golfsim/package.json`:

```json
{
  "name": "@zigbase-examples/golfsim",
  "private": true,
  "type": "module",
  "scripts": {
    "typecheck": "tsc --noEmit",
    "test:e2e": "vitest run"
  },
  "dependencies": {
    "@zigbase/client": "file:../../clients/typescript"
  },
  "devDependencies": {
    "vitest": "^1.6.0",
    "typescript": "^5.4.0"
  }
}
```

Create `examples/golfsim/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "types": ["node"]
  },
  "include": ["clients/typescript", "test"]
}
```

Create `examples/golfsim/vitest.config.ts`:
```typescript
import { defineConfig } from "vitest/config";
export default defineConfig({
  test: {
    include: ["test/**/*.e2e.test.ts"],
    environment: "node",
    testTimeout: 60_000,
    hookTimeout: 120_000,
    pool: "forks",
    fileParallelism: false,
  },
});
```

- [ ] **Step 2: Add a golfsim harness that spawns the golfsim binary.** Create `examples/golfsim/test/harness.ts`:

```typescript
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const EXAMPLE_ROOT = resolve(HERE, ".."); // examples/golfsim
const BIN = join(EXAMPLE_ROOT, "zig-out", "bin", "golfsim");

export interface GolfServer { url: string; stop(): void; }

async function waitForHealth(url: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { if ((await fetch(`${url}/api/health`)).ok) return; } catch { /* not up */ }
    if (Date.now() > deadline) throw new Error("golfsim did not become healthy");
    await new Promise((r) => setTimeout(r, 200));
  }
}

export async function startGolfsim(): Promise<GolfServer> {
  const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
  if (b.status !== 0) throw new Error("golfsim build failed");
  const dataDir = mkdtempSync(join(tmpdir(), "golf-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const su = spawnSync(BIN, ["superuser", "create", "--email", "admin@golf.local", "--password", "test-password-123", "--data-dir", dataDir], { stdio: "inherit" });
  if (su.status !== 0) throw new Error("superuser create failed");
  const proc: ChildProcess = spawn(BIN, ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"], { stdio: "inherit" });
  const url = `http://127.0.0.1:${port}`;
  await waitForHealth(url);
  return { url, stop() { proc.kill("SIGTERM"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } } };
}
```

- [ ] **Step 3: Write the golfsim e2e.** Create `examples/golfsim/test/golfsim.e2e.test.ts` — fuller CRUD/auth across the collections (mind golfsim's real rules: simulators/listings are owner-scoped, reviews public-read):

```typescript
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { startGolfsim, type GolfServer } from "./harness.js";
import { createClient } from "../clients/typescript/zbase.gen.js";

let server: GolfServer;
beforeAll(async () => { server = await startGolfsim(); });
afterAll(() => server?.stop());

/** Public signup + auth (users has @public create/list/view). */
async function host(email: string) {
  const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
  const user = await zb.db.users.create({ email, password: "member-pass-1", passwordConfirm: "member-pass-1", name: email.split("@")[0]! });
  await zb.db.users.authWithPassword(email, "member-pass-1");
  return { zb, user };
}

describe("golfsim generated client (live golfsim server)", () => {
  it("auth + owner-scoped CRUD across simulators/listings, public review read", async () => {
    const { zb, user } = await host("host@golf.app");

    // simulator (owner = the authed user).
    const sim = await zb.db.simulators.create({ label: "Bay 1", owner: user.id });
    expect(sim.label).toBe("Bay 1");

    // listing referencing the simulator; published so it is publicly viewable.
    const listing = await zb.db.listings.create({
      title: "Prime tee time", price_per_hour: 40, status: "published", simulator: sim.id,
    });
    expect(listing.status).toBe("published");

    // public list (anonymous client sees published listings).
    const anon = createClient(server.url, { WebSocket: globalThis.WebSocket });
    const published = await anon.db.listings.getList({ where: { status: "published" } });
    expect(published.items.some((l) => l.id === listing.id)).toBe(true);

    // expand the listing's simulator relation.
    const withSim = await zb.db.listings.getOne(listing.id, { expand: ["simulator"] });
    expect(withSim.expand.simulator.label).toBe("Bay 1");

    // a second user books, then reviews (reviews are public-read).
    const { zb: guest, user: guestUser } = await host("guest@golf.app");
    const booking = await guest.db.bookings.create({
      listing: listing.id, guest: guestUser.id,
      starts_at: "2027-01-01 10:00:00.000Z", ends_at: "2027-01-01 11:00:00.000Z",
    });
    const review = await guest.db.reviews.create({ booking: booking.id, author: guestUser.id, rating: 5, body: "great" });
    const reviews = await anon.db.reviews.getList({ where: { rating: { gte: 4 } } });
    expect(reviews.items.some((r) => r.id === review.id)).toBe(true);
  });
});
```

- [ ] **Step 4: Install deps + typecheck + run the e2e.** Run:
```bash
cd examples/golfsim && mise exec node@24 -- npm install && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm run test:e2e
```
Expected: typecheck exit 0 (the committed generated client resolves `@zigbase/client`), e2e passes. If date formats are rejected, adjust `starts_at`/`ends_at` to the server's accepted date format (check an existing date round-trip in the dating e2e or `src/` date handling).

- [ ] **Step 5: Commit.**
```bash
git add examples/golfsim/package.json examples/golfsim/tsconfig.json examples/golfsim/vitest.config.ts examples/golfsim/test/
git commit -m "test(golfsim): self-contained live-binary e2e through the generated client"
```

---

## Task 8: CI extensions

**Files:**
- Modify: `.github/workflows/ci.yml` (the `ts-sdk` job)

**Interfaces:**
- Consumes: `zig build dating-server` (Task 2), `zig build gen-dating-client-check` (existing), golfsim `gen-client-check` + e2e (Tasks 6–7).

- [ ] **Step 1: Add staleness gates + binaries + suites to the `ts-sdk` job.** In `.github/workflows/ci.yml`, in the `ts-sdk` job, change the "Build zigbase binary" step and append steps. After `- name: Build zigbase binary / run: mise exec zig@0.16.0 -- zig build`, add:

```yaml
    - name: Build dating-server (e2e fixture binary)
      run: mise exec zig@0.16.0 -- zig build dating-server
    - name: Dating client snapshot is fresh
      run: mise exec zig@0.16.0 -- zig build gen-dating-client-check
    - name: Golfsim client snapshot is fresh
      working-directory: examples/golfsim
      run: mise exec zig@0.16.0 -- zig build gen-client-check
```

Then after the existing `- name: Integration tests` step, add:

```yaml
    - name: Golfsim e2e
      working-directory: examples/golfsim
      run: mise exec node@24 -- npm install && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm run test:e2e
```

(The dating type-level suite + dating e2e already run via the existing `Typecheck` / `Unit tests` / `Integration tests` steps, since the `.test-d.ts` lives under `test/` and the e2e under `test/integration/`.)

- [ ] **Step 2: Validate the workflow YAML.** Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('yaml ok')"`. Expected: `yaml ok`.

- [ ] **Step 3: Locally dry-run the new CI commands** (proves the steps are real, since CI runs remotely):
```bash
mise exec zig@0.16.0 -- zig build dating-server && \
mise exec zig@0.16.0 -- zig build gen-dating-client-check && \
( cd examples/golfsim && mise exec zig@0.16.0 -- zig build gen-client-check )
```
Expected: all exit 0.

- [ ] **Step 4: Commit.**
```bash
git add .github/workflows/ci.yml
git commit -m "ci(ts-sdk): build dating-server, staleness gates for dating+golfsim, golfsim e2e"
```

---

## Task 9: Docs sync

**Files:**
- Modify: `examples/golfsim/README.md`
- Modify: any `site/` mirror of the golfsim README + `docs/*.md` codegen pages that describe the example or the generated-client flow

**Interfaces:** none (docs).

- [ ] **Step 1: Find what references golfsim / the codegen flow.** Run:
```bash
grep -rln "golfsim" docs site examples/golfsim/README.md 2>/dev/null
grep -rln "gen-client\|zbase.gen\|generated client\|comptime" docs site 2>/dev/null
```
List the files to update.

- [ ] **Step 2: Update golfsim's README** to document the generated-client flow: that `src/main.zig` exposes `pub const App` at module scope, `zig build gen-client` emits `clients/typescript/zbase.gen.ts`, and the e2e (`npm run test:e2e`) drives the generated typed client against the live `golfsim` binary. Show the exact commands:
```bash
zig build gen-client          # regenerate the typed client
zig build gen-client-check    # CI staleness gate
npm install && npm run test:e2e
```

- [ ] **Step 3: Update the `site/` mirror + any `docs/*.md`** found in Step 1 so the published codegen/example docs reflect: (a) golfsim now ships a generated typed client, (b) the `pub const App` convention as the codegen prerequisite, (c) the dating fixture is the SDK's coverage fixture (validated by type-level + live e2e). Keep wording consistent with existing docs; do not invent new pages.

- [ ] **Step 4: Verify no broken internal links / stale commands.** Re-grep for any now-wrong references (e.g. an old "no generated client" claim about golfsim): `grep -rn "no code\|hand-written client" docs site examples/golfsim/README.md 2>/dev/null` and fix any that contradict the new flow.

- [ ] **Step 5: Commit.**
```bash
git add examples/golfsim/README.md docs site
git commit -m "docs(ts-sdk): document golfsim generated-client flow + Plan 2 validation"
```

---

## Final verification (whole-branch, before finishing)

- [ ] `mise exec zig@0.16.0 -- zig build` — exit 0.
- [ ] `mise exec zig@0.16.0 -- zig build test` — exit 0 (ignore the `failed command:` quirk line).
- [ ] `mise exec zig@0.16.0 -- zig build dating-server` — exit 0.
- [ ] `mise exec zig@0.16.0 -- zig build gen-dating-client-check` — exit 0.
- [ ] `( cd examples/golfsim && mise exec zig@0.16.0 -- zig build gen-client-check )` — exit 0.
- [ ] `( cd clients/typescript && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm test && mise exec node@24 -- npm run test:integration )` — all exit 0.
- [ ] `( cd examples/golfsim && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm run test:e2e )` — exit 0.
- [ ] Docs (golfsim README + `site/` mirror + `docs/*.md`) updated and consistent.
