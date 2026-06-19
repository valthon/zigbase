# ZigBase SDK Showcase Refresh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the published three-tier TypeScript SDK a first-class, discoverable story across the marketing homepage, docs, examples, and READMEs — with each example deliberately demonstrating one tier.

**Architecture:** Presentation + examples only (no SDK API changes). Add a homepage Features card + a new `SdkShowcase` section; surface and de-stale the existing SDK docs page + sidebar; give blog/golfsim/plugins one tier each (base dynamic / comptime-generated / runtime typegen) with committed CI-gated e2e demos; refresh READMEs and sweep stale "pre-release" copy.

**Tech Stack:** Astro (custom site, not Starlight) + the built-in `<Code>` highlighter; vitest e2e (mirroring `examples/golfsim`); `@zigbase/client` base SDK; the Zig `typegen` subcommand.

## Global Constraints

- **Mirror rule (binding):** every edit to a `site/src/content/docs/*.md` file is mirrored into the corresponding `docs/*.md` (and vice-versa), preserving each file's pre-existing front-matter and link conventions (site has Astro front-matter; `docs/` is raw). This is a strict project requirement.
- **Stale-copy gate:** after the refresh, `grep -rniE "not yet published|pre-release|coming soon|once the first .* release" --include=*.md --include=*.astro --include=*.ts .` (excluding `.claude/`) returns nothing.
- **Published versions (use verbatim):** `@zigbase/client@0.1.0`, `@zigbase/server@0.4.0`, `@zigbase/typegen@0.1.1`.
- **Three tiers (the narrative):** Base dynamic (`@zigbase/client`, you pass `<Type>`); Comptime-generated (`zig build gen-client` → typed `zb.db.*` + `zb.rpc.*`); Runtime introspection (`npx @zigbase/typegen`, db/realtime/files, no typed `rpc.*`).
- **In-repo examples keep the `file:` SDK dep** (`"@zigbase/client": "file:../../clients/typescript"`) so build/tests run against local source; READMEs show the real `npm install`/`npx` commands.
- **Zig 0.16 only** via `mise exec zig@0.16.0 -- zig …`; **Node** via `mise exec node@24 -- …`. `dating` stays a test fixture (untouched).
- **Site build check:** `cd site && mise exec node@24 -- npm run build` (install deps first if needed).

---

### Task 1: Homepage — Features card + SdkShowcase section

**Files:**
- Modify: `site/src/components/landing/Features.astro` (add a 9th card)
- Create: `site/src/components/landing/SdkShowcase.astro`
- Modify: `site/src/pages/index.astro` (import + place after `<ExamplesShowcase />`)

**Interfaces:**
- Consumes: `FeatureCard` (`site/src/components/FeatureCard.astro`, props `title: string`, slots `icon` + default body); the built-in `import { Code } from 'astro:components'` used by `CodeSample.astro`; the design tokens already in the codebase (`--space-*`, `--color-surface`, `--color-border`, `--color-accent`, `--radius-lg`).

- [ ] **Step 1: Add the 9th Features card**

In `site/src/components/landing/Features.astro`, insert this card as the last `<FeatureCard>` (immediately before the closing `</div>` of the cards grid, after the existing 8th card). Match the surrounding indentation:

```astro
        <FeatureCard title="Typed TypeScript SDK">
          <svg slot="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 6h16M4 12h10M4 18h7" />
            <path d="M16 16l3 3 5-6" transform="translate(-2 -3)" />
          </svg>
          Generate a fully-typed client from your Zig schema — or from any running instance with <code>npx @zigbase/typegen</code>. Records, realtime, files, and typed custom-route RPC.
        </FeatureCard>
```

- [ ] **Step 2: Create `SdkShowcase.astro`**

First read `site/src/components/landing/ExamplesShowcase.astro` (for the section shell/heading class names) and `site/src/components/landing/CodeSample.astro` (for the `<Code>` usage). Then create `site/src/components/landing/SdkShowcase.astro`:

```astro
---
import { Code } from 'astro:components';

const tiers = [
  {
    title: 'Base — dynamic',
    blurb: 'Zero-config client for any ZigBase server. You bring the types.',
    install: 'npm install @zigbase/client',
    code: `import { createClient } from "@zigbase/client";

const zb = createClient("http://localhost:8090");
const posts = await zb
  .collection("posts")
  .getList(1, 20, { filter: "status = 'published'" });`,
    lang: 'ts',
  },
  {
    title: 'Comptime — generated',
    blurb: 'A fully-typed client generated from your Zig schema at build time — typed records and typed custom-route RPC.',
    install: 'zig build gen-client',
    code: `import { createClient } from "./zbase.gen.js";

const zb = createClient("http://localhost:8090");
const post = await zb.db.posts.create({
  title: "Hello", status: "published",
});
const res = await zb.rpc.bookingsConfirm({ id });`,
    lang: 'ts',
  },
  {
    title: 'Runtime — introspection',
    blurb: 'Generate a typed client from any running instance — no Zig toolchain. Records, realtime, files.',
    install: 'npx @zigbase/typegen',
    code: `npx @zigbase/typegen \\
  --url https://api.example.com \\
  --out src/zbase.gen.ts`,
    lang: 'bash',
  },
];
---

<section class="sdk" id="typescript-sdk">
  <div class="sdk__inner">
    <header class="sdk__head">
      <h2>A TypeScript SDK in three forms</h2>
      <p>
        From a zero-config dynamic client to a fully-typed client generated from your schema —
        at build time, or from any running instance with no Zig toolchain.
      </p>
    </header>

    <div class="sdk__grid">
      {tiers.map((t) => (
        <article class="sdk__card">
          <h3 class="sdk__title">{t.title}</h3>
          <p class="sdk__blurb">{t.blurb}</p>
          <div class="sdk__install"><code>{t.install}</code></div>
          <div class="sdk__code">
            <Code code={t.code} lang={t.lang} />
          </div>
        </article>
      ))}
    </div>

    <p class="sdk__more">
      <a href="/zigbase/docs/typescript-sdk">Read the TypeScript SDK docs →</a>
    </p>
  </div>
</section>

<style>
  .sdk { padding: var(--space-2xl, 4rem) 0; }
  .sdk__inner { max-width: 72rem; margin: 0 auto; padding: 0 var(--space-lg, 1.5rem); }
  .sdk__head { text-align: center; margin-bottom: var(--space-xl, 2.5rem); }
  .sdk__head h2 { font-size: clamp(1.6rem, 3vw, 2.2rem); margin: 0 0 var(--space-sm, 0.75rem); }
  .sdk__head p { color: var(--color-text-muted, #888); max-width: 46rem; margin: 0 auto; }
  .sdk__grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 20rem), 1fr));
    gap: var(--space-lg, 1.5rem);
  }
  .sdk__card {
    border: 1px solid var(--color-border, #2a2a2a);
    background: var(--color-surface, #161616);
    border-radius: var(--radius-lg, 0.75rem);
    padding: var(--space-lg, 1.5rem);
    display: flex;
    flex-direction: column;
    gap: var(--space-sm, 0.75rem);
  }
  .sdk__title { margin: 0; font-size: 1.15rem; color: var(--color-accent, #7dd3fc); }
  .sdk__blurb { margin: 0; color: var(--color-text-muted, #aaa); font-size: 0.95rem; }
  .sdk__install code {
    display: inline-block;
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 0.85rem;
    background: var(--color-bg, #0d0d0d);
    border: 1px solid var(--color-border, #2a2a2a);
    border-radius: var(--radius-sm, 0.375rem);
    padding: 0.25rem 0.5rem;
  }
  .sdk__code :global(pre) { border-radius: var(--radius-md, 0.5rem); font-size: 0.82rem; }
  .sdk__more { text-align: center; margin-top: var(--space-xl, 2.5rem); }
  .sdk__more a { color: var(--color-accent, #7dd3fc); font-weight: 600; }
</style>
```

> The `href="/zigbase/docs/typescript-sdk"` uses the site's `base: '/zigbase'` (from `astro.config.mjs`) + the `typescript-sdk` slug. If the codebase has a `<DocLink>` / base-aware helper used by other components, prefer it; otherwise this absolute path is correct for GitHub Pages.

- [ ] **Step 3: Wire `<SdkShowcase />` into the homepage**

In `site/src/pages/index.astro`, add the import after the `ExamplesShowcase` import:
```astro
import SdkShowcase from '../components/landing/SdkShowcase.astro';
```
And place the component immediately after `<ExamplesShowcase />` in the page body:
```astro
      <ExamplesShowcase />
      <SdkShowcase />
      <WhyZigBase />
```

- [ ] **Step 4: Build the site**

Run: `cd site && mise exec node@24 -- npm install && mise exec node@24 -- npm run build`
Expected: build exits 0, no errors. The homepage includes the new card + section; `<Code>` blocks render (no "lang not found" or import errors).

- [ ] **Step 5: Commit**

```bash
git add site/src/components/landing/Features.astro site/src/components/landing/SdkShowcase.astro site/src/pages/index.astro
git commit -m "feat(site): homepage TypeScript SDK feature card + SdkShowcase section"
```

---

### Task 2: Docs — surface the SDK page in nav + de-stale + which-tier table

**Files:**
- Modify: `site/src/config/sidebar.ts`
- Modify: `site/src/content/docs/typescript-sdk.md`
- Modify: `docs/typescript-sdk.md` (mirror)

- [ ] **Step 1: Add the SDK page to the sidebar**

In `site/src/config/sidebar.ts`, in the `guides` group's `entries` array, add after the `framework` entry:
```ts
      { slug: 'typescript-sdk', label: 'TypeScript SDK' },
```

- [ ] **Step 2: De-stale the install block (site)**

In `site/src/content/docs/typescript-sdk.md`, replace the stale block (currently around lines 15–23):
```md
## Install

> **Pre-release:** `@zigbase/client` is not yet published to npm. Until the first
> release you can build it from source (`clients/typescript/`). The `npm install`
> command below will work once the first `client-v*` release is published.

```bash
npm install @zigbase/client
```
```
with:
````md
## Install

```bash
npm install @zigbase/client
```

The SDK is published: `@zigbase/client@0.1.0`. Its `@zigbase/client/typed` and
`@zigbase/client/realtime` entry points ship in the same package. For the runtime
generator, see [Runtime introspection](#runtime-introspection-zigbase-typegen) —
no install needed beyond `npx @zigbase/typegen` (which pulls `@zigbase/server@0.4.0`).
````

> Verify the exact anchor for the "Runtime introspection" section heading in this file and use its real GitHub-Markdown slug in the link; adjust if the heading text differs.

- [ ] **Step 3: Add the "Which tier should I use?" table (site)**

In `site/src/content/docs/typescript-sdk.md`, immediately after the `## Install` block from Step 2, add:
```md
## Which tier should I use?

| Tier | Get it | Typing | Typed custom-route RPC | Needs Zig source |
|---|---|---|---|---|
| **Base dynamic** | `npm install @zigbase/client` | you pass `<Type>` | no | no |
| **Comptime-generated** | `zig build gen-client` | full, from your schema | **yes** (`zb.rpc.*`) | yes |
| **Runtime introspection** | `npx @zigbase/typegen` | full (db/realtime/files) | no | no |

All three share the same runtime (`@zigbase/client`); the generated tiers add fully-typed
`zb.db.*` (and, for comptime, `zb.rpc.*`) on top.
```

- [ ] **Step 4: Mirror the same edits into `docs/typescript-sdk.md`**

Apply the identical Step-2 + Step-3 prose to `docs/typescript-sdk.md` (its stale block is around lines 10–16; it has no Astro front-matter). Keep the prose identical; use this file's own link/anchor convention (bare relative, no `/zigbase` base) for the "Runtime introspection" cross-link.

- [ ] **Step 5: Verify parity + build**

Run:
```bash
diff docs/typescript-sdk.md site/src/content/docs/typescript-sdk.md
cd site && mise exec node@24 -- npm run build && cd ..
```
Expected: the `diff` shows only the pre-existing front-matter + link-convention differences (the new prose matches in both); site builds clean and the SDK page is now linked in the sidebar.

- [ ] **Step 6: Commit**

```bash
git add site/src/config/sidebar.ts site/src/content/docs/typescript-sdk.md docs/typescript-sdk.md
git commit -m "docs(site): surface SDK page in nav, de-stale install, add which-tier table"
```

---

### Task 3: blog → Tier 1 (base dynamic) committed e2e

**Files:**
- Create: `examples/blog/package.json`, `examples/blog/vitest.config.ts`, `examples/blog/tsconfig.json`
- Create: `examples/blog/test/harness.ts`, `examples/blog/test/blog.e2e.test.ts`
- Modify: `examples/blog/README.md` (add "Using the base TypeScript SDK")
- Modify: `.github/workflows/ci.yml` (blog e2e step in the `ts-sdk` job)

**Interfaces:**
- Consumes: `@zigbase/client` base API — `createClient(url, opts)`, `zb.collection(name)` → `.create/.getList/.getOne/.update/.delete`, `.authWithPassword(identity, password)`. Blog schema: `users` (auth: `name`, implicit `email`/`password`), `posts` (`title`, `slug`, `body`, `status` select draft|published, `author` relation→users, `updated_at`, `reading_time`). Create rule on `posts` requires auth; list/view rule requires `status = 'published'`.

- [ ] **Step 1: package.json (mirror golfsim)**

`examples/blog/package.json`:
```json
{
  "name": "@zigbase-examples/blog",
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
    "@types/node": "^20.12.0",
    "vitest": "^1.6.0",
    "typescript": "^5.4.0"
  }
}
```

- [ ] **Step 2: vitest config + tsconfig (mirror golfsim)**

`examples/blog/vitest.config.ts`:
```ts
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
`examples/blog/tsconfig.json` (read `examples/golfsim/tsconfig.json` and copy it verbatim; if golfsim has none, use):
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "skipLibCheck": true,
    "noEmit": true,
    "types": ["node"]
  },
  "include": ["test"]
}
```

- [ ] **Step 3: Harness (mirror golfsim's `test/harness.ts`, blog binary, no frontend)**

`examples/blog/test/harness.ts`:
```ts
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const EXAMPLE_ROOT = resolve(HERE, ".."); // examples/blog
const BIN = process.env.ZIGBASE_TEST_BLOG_BINARY || join(EXAMPLE_ROOT, "zig-out", "bin", "blog");

export interface BlogServer {
  url: string;
  superuser: { email: string; password: string };
  stop(): void;
}

async function waitForHealth(url: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { if ((await fetch(`${url}/api/health`)).ok) return; } catch { /* not up */ }
    if (Date.now() > deadline) throw new Error("blog did not become healthy");
    await new Promise((r) => setTimeout(r, 200));
  }
}

export async function startBlog(): Promise<BlogServer> {
  if (!process.env.ZIGBASE_TEST_BLOG_BINARY) {
    const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
    if (b.status !== 0) throw new Error("blog build failed");
  }
  const dataDir = mkdtempSync(join(tmpdir(), "blog-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const email = "admin@blog.local", password = "test-password-123";
  const su = spawnSync(BIN, ["superuser", "create", "--email", email, "--password", password, "--data-dir", dataDir], { stdio: "inherit" });
  if (su.status !== 0) throw new Error("superuser create failed");
  const proc: ChildProcess = spawn(BIN, ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
  const url = `http://127.0.0.1:${port}`;
  try { await waitForHealth(url); }
  catch (err) { proc.kill("SIGKILL"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } throw err; }
  return { url, superuser: { email, password }, stop() { proc.kill("SIGTERM"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } } };
}
```

- [ ] **Step 4: The SP1 base-client e2e**

`examples/blog/test/blog.e2e.test.ts`:
```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { createClient } from "@zigbase/client";
import { startBlog, type BlogServer } from "./harness.js";

// Tier 1 — base dynamic client (@zigbase/client). No codegen: collections are
// addressed by name via zb.collection(...), and types are supplied by the caller.

let server: BlogServer;
beforeAll(async () => { server = await startBlog(); });
afterAll(() => server?.stop());

interface Post { id: string; title: string; status: string; author: string }

describe("blog — base @zigbase/client (Tier 1: dynamic)", () => {
  it("signs up, authenticates, and does CRUD on posts", async () => {
    const zb = createClient(server.url);

    // sign up an author on the `users` auth collection, then authenticate.
    const email = `writer-${Date.now()}@blog.local`;
    const user = await zb.collection("users").create({
      email, password: "writer-pass-1", passwordConfirm: "writer-pass-1", name: "Ada",
    });
    expect(user.id).toBeTruthy();
    await zb.collection("users").authWithPassword(email, "writer-pass-1");
    expect(zb.authStore.token).toBeTruthy();

    // create a published post (create rule requires auth; list/view require published).
    const created = await zb.collection("posts").create<Post>({
      title: "Hello from the base SDK", body: "Dynamic client, no codegen.",
      status: "published", author: user.id,
    });
    expect(created.title).toBe("Hello from the base SDK");

    // read it back (list is filtered to published server-side).
    const list = await zb.collection("posts").getList<Post>(1, 20, { filter: "status = 'published'" });
    expect(list.items.some((p) => p.id === created.id)).toBe(true);

    const one = await zb.collection("posts").getOne<Post>(created.id);
    expect(one.id).toBe(created.id);

    // update + delete (update/delete rule: author only).
    const updated = await zb.collection("posts").update<Post>(created.id, { title: "Edited" });
    expect(updated.title).toBe("Edited");
    await zb.collection("posts").delete(created.id);
  });
});
```

> Before finalizing assertions, confirm the blog schema field/collection names against `examples/blog/src/main.zig` (users/posts; `status`, `author`, `title`, `body`). If the `posts.create` rule or field names differ, adjust the demo to match the real schema (do not change the schema).

- [ ] **Step 5: README section**

In `examples/blog/README.md`, add a section "## Using the base TypeScript SDK (`@zigbase/client`)":
- One line: this example demonstrates **Tier 1 — the base dynamic client**: address collections by name (`zb.collection("posts")`), bring your own types.
- The user-facing install: `npm install @zigbase/client`.
- A short code snippet matching the e2e (createClient + collection CRUD + authWithPassword).
- Pointer: "For a fully-typed client, see golfsim (comptime-generated) and the [TypeScript SDK docs](../../docs/typescript-sdk.md)."
- How to run it here: `mise exec node@24 -- npm install && npm run test:e2e`.

- [ ] **Step 6: CI — blog e2e step**

In `.github/workflows/ci.yml`, in the `ts-sdk` job: (a) in the "Export prebuilt binary path" step, add a line exporting the blog binary from the artifact:
```sh
echo "ZIGBASE_TEST_BLOG_BINARY=$GITHUB_WORKSPACE/artifacts/examples/blog/zig-out/bin/blog" >> "$GITHUB_ENV"
chmod +x artifacts/examples/blog/zig-out/bin/blog
```
(b) Add a step after the golfsim e2e step, mirroring it:
```yaml
      - name: Blog e2e (base SDK)
        working-directory: examples/blog
        run: mise exec node@24 -- npm install && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm run test:e2e
```
> Confirm the blog binary is already in the `zigbase-binaries` artifact (the build job builds `examples/blog` and uploads `examples/blog/zig-out/bin/blog`). If it is NOT in the upload list, add it to the build job's `upload-artifact` `path:` list.

- [ ] **Step 7: Verify locally**

Run: `cd examples/blog && mise exec node@24 -- npm install && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm run test:e2e`
Expected: typecheck clean; the e2e builds the blog binary (first run), serves it, and the CRUD test passes.

- [ ] **Step 8: Commit**

```bash
git add examples/blog/package.json examples/blog/vitest.config.ts examples/blog/tsconfig.json examples/blog/test examples/blog/README.md .github/workflows/ci.yml
git commit -m "test(blog): base @zigbase/client e2e (SDK Tier 1) + README + CI"
```

---

### Task 4: golfsim → Tier 2 README callout

**Files:**
- Modify: `examples/golfsim/README.md`

- [ ] **Step 1: Add a tier callout**

In `examples/golfsim/README.md`, in the existing "Generated TypeScript client" section, add a short callout identifying the tier:
> **SDK Tier 2 — comptime-generated typed client.** `zig build gen-client` reads this example's `pub const App` at build time and emits a fully-typed `zbase.gen.ts`: typed `zb.db.<collection>.*` and typed custom-route RPC via `zb.rpc.*` (e.g. `zb.rpc.bookingsConfirm({ id })`). This is the richest tier — it's the only one with typed custom-route RPC. See the [TypeScript SDK docs](../../docs/typescript-sdk.md) and, for runtime generation without Zig source, the plugins example (Tier 3).

- [ ] **Step 2: Verify the cross-links resolve** (the `../../docs/typescript-sdk.md` path is correct from `examples/golfsim/`). No build needed.

- [ ] **Step 3: Commit**

```bash
git add examples/golfsim/README.md
git commit -m "docs(golfsim): label the comptime-generated typed client (SDK Tier 2)"
```

---

### Task 5: plugins → Tier 3 (runtime typegen) demo

**Files:**
- Modify: `examples/plugins/src/main.zig` (add `.enable_typegen = true`)
- Create: `examples/plugins/package.json`, `examples/plugins/vitest.config.ts`, `examples/plugins/tsconfig.json`
- Create: `examples/plugins/test/harness.ts`, `examples/plugins/test/typegen.e2e.test.ts`
- Modify: `examples/plugins/README.md`
- Modify: `.github/workflows/ci.yml` (plugins typegen e2e step)

**Interfaces:**
- Produces a runtime-generated client file via `<plugins-bin> typegen --data-dir <dir> --out <file>`. Plugins collections: `authors`, `posts`, `comments` (no auth collection). The plugins binary embeds an Astro frontend (`embedStaticDir("frontend/dist")`) — the harness must build the frontend before a local `zig build`.

- [ ] **Step 1: Enable typegen on the plugins App**

In `examples/plugins/src/main.zig`, in the `zigbase.App(.{ … })` config, add `.enable_typegen = true,` immediately after the closing `},` of the `.collections = .{ … }` block (before `.migrations`):
```zig
        },
        .enable_typegen = true,
        .migrations = &[_]zigbase.Migration{
```

- [ ] **Step 2: Verify the plugins binary gains typegen**

Run:
```bash
cd examples/plugins/frontend && mise exec node@24 -- npm install && mise exec node@24 -- npm run build && cd ..
mise exec zig@0.16.0 -- zig build -Dcpu=baseline
./zig-out/bin/plugins typegen 2>&1 | head -3
cd ../..
```
Expected: build succeeds; `plugins typegen` (no args) prints a usage/`--out required`-style message and does NOT say "was not built with .enable_typegen".

- [ ] **Step 3: package.json + vitest + tsconfig**

`examples/plugins/package.json`:
```json
{
  "name": "@zigbase-examples/plugins",
  "private": true,
  "type": "module",
  "scripts": {
    "typecheck": "tsc --noEmit",
    "test:e2e": "vitest run"
  },
  "devDependencies": {
    "@types/node": "^20.12.0",
    "vitest": "^1.6.0",
    "typescript": "^5.4.0"
  }
}
```
`examples/plugins/vitest.config.ts`: copy `examples/blog/vitest.config.ts` (from Task 3 Step 2) verbatim.
`examples/plugins/tsconfig.json`: copy `examples/blog/tsconfig.json` (Task 3 Step 2) verbatim.

- [ ] **Step 4: Harness (spawn plugins serve to provision a data dir; build frontend first locally)**

`examples/plugins/test/harness.ts`:
```ts
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const EXAMPLE_ROOT = resolve(HERE, ".."); // examples/plugins
const FRONTEND_ROOT = join(EXAMPLE_ROOT, "frontend");
const FRONTEND_DIST = join(FRONTEND_ROOT, "dist");
const BIN = process.env.ZIGBASE_TEST_PLUGINS_BINARY || join(EXAMPLE_ROOT, "zig-out", "bin", "plugins");

export interface PluginsServer {
  url: string;
  dataDir: string;
  bin: string;
  stop(): void;
}

function ensureFrontend(): void {
  if (existsSync(FRONTEND_DIST)) return;
  const i = spawnSync("mise", ["exec", "node@24", "--", "npm", "install"], { cwd: FRONTEND_ROOT, stdio: "inherit" });
  if (i.status !== 0) throw new Error("plugins frontend npm install failed");
  const b = spawnSync("mise", ["exec", "node@24", "--", "npm", "run", "build"], { cwd: FRONTEND_ROOT, stdio: "inherit" });
  if (b.status !== 0) throw new Error("plugins frontend build failed");
}

async function waitForHealth(url: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { if ((await fetch(`${url}/api/health`)).ok) return; } catch { /* not up */ }
    if (Date.now() > deadline) throw new Error("plugins did not become healthy");
    await new Promise((r) => setTimeout(r, 200));
  }
}

export async function startPlugins(): Promise<PluginsServer> {
  if (!process.env.ZIGBASE_TEST_PLUGINS_BINARY) {
    ensureFrontend();
    const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
    if (b.status !== 0) throw new Error("plugins build failed");
  }
  const dataDir = mkdtempSync(join(tmpdir(), "plug-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const su = spawnSync(BIN, ["superuser", "create", "--email", "admin@plug.local", "--password", "test-password-123", "--data-dir", dataDir], { stdio: "inherit" });
  if (su.status !== 0) throw new Error("superuser create failed");
  const proc: ChildProcess = spawn(BIN, ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
  const url = `http://127.0.0.1:${port}`;
  try { await waitForHealth(url); } // health == collections provisioned into the data dir
  catch (err) { proc.kill("SIGKILL"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } throw err; }
  return { url, dataDir, bin: BIN, stop() { proc.kill("SIGTERM"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } } };
}
```

- [ ] **Step 5: The SP3 runtime-typegen e2e**

`examples/plugins/test/typegen.e2e.test.ts`:
```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startPlugins, type PluginsServer } from "./harness.js";

// Tier 3 — runtime introspection. The example's own (enable_typegen=true) binary
// generates a typed client from the data dir it just provisioned — no Zig source
// needed by the consumer, no network. The README shows the published
// `npx @zigbase/typegen` form users run against a remote URL.

let server: PluginsServer;
let outDir: string;
beforeAll(async () => { server = await startPlugins(); outDir = mkdtempSync(join(tmpdir(), "plug-gen-")); });
afterAll(() => { server?.stop(); try { rmSync(outDir, { recursive: true, force: true }); } catch { /* ignore */ } });

describe("plugins — runtime typegen (SDK Tier 3)", () => {
  it("generates a typed client from the running data dir (offline --data-dir)", () => {
    const out = join(outDir, "zbase.gen.ts");
    const r = spawnSync(server.bin, ["typegen", "--data-dir", server.dataDir, "--out", out], { stdio: "inherit" });
    expect(r.status).toBe(0);
    const gen = readFileSync(out, "utf8");
    // the generated client should carry the plugins collections + the typed factory.
    expect(gen).toContain("// generated by zigbase");
    expect(gen).toMatch(/createClient/);
    for (const col of ["authors", "posts", "comments"]) expect(gen).toContain(col);
  });
});
```

- [ ] **Step 6: README section**

In `examples/plugins/README.md`, add "## Generate a typed client at runtime — no Zig toolchain (SDK Tier 3)":
- This example sets `.enable_typegen = true`, so its binary carries the `typegen` subcommand.
- The end-user command (published tool, no Zig): `npx @zigbase/typegen --url http://localhost:8090 --out src/zbase.gen.ts` (and the offline form `npx @zigbase/typegen --data-dir ./pb_data --out src/zbase.gen.ts`).
- Note: runtime introspection generates the db/realtime/files surface (no typed `rpc.*` — for that, use the comptime tier, see golfsim).
- How it's verified here: the e2e runs `./zig-out/bin/plugins typegen --data-dir <provisioned dir> --out …` in-process.
- Pointer to the [TypeScript SDK docs](../../docs/typescript-sdk.md).

- [ ] **Step 7: CI — plugins typegen e2e step**

In `.github/workflows/ci.yml`, in the `ts-sdk` job's "Export prebuilt binary path" step, add:
```sh
echo "ZIGBASE_TEST_PLUGINS_BINARY=$GITHUB_WORKSPACE/artifacts/examples/plugins/zig-out/bin/plugins" >> "$GITHUB_ENV"
chmod +x artifacts/examples/plugins/zig-out/bin/plugins
```
And add a step after the blog e2e step:
```yaml
      - name: Plugins typegen e2e (runtime SDK)
        working-directory: examples/plugins
        run: mise exec node@24 -- npm install && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm run test:e2e
```
> Confirm the plugins binary is in the `zigbase-binaries` artifact (the build job builds `examples/plugins` and uploads `examples/plugins/zig-out/bin/plugins`); add it to the upload `path:` if missing. Since the artifact binary is built with the new `.enable_typegen = true`, no frontend rebuild is needed in the e2e job (it uses the prebuilt binary).

- [ ] **Step 8: Verify locally**

Run: `cd examples/plugins && mise exec node@24 -- npm install && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm run test:e2e`
Expected: the e2e builds the plugins binary (frontend first), serves it to provision the data dir, runs `plugins typegen --data-dir`, and asserts the generated client contains the three collections. Passes.

- [ ] **Step 9: Commit**

```bash
git add examples/plugins/src/main.zig examples/plugins/package.json examples/plugins/vitest.config.ts examples/plugins/tsconfig.json examples/plugins/test examples/plugins/README.md .github/workflows/ci.yml
git commit -m "feat(plugins): enable_typegen + runtime-typegen e2e (SDK Tier 3) + README + CI"
```

---

### Task 6: README freshness + stale-copy sweep

**Files:**
- Modify: `clients/typescript/README.md`
- Modify: `README.md` (root)

- [ ] **Step 1: De-stale the SDK package README**

In `clients/typescript/README.md`, remove the "Pre-release" block (around lines 11–17):
```md
> **Pre-release:** `@zigbase/client` is not yet published to npm. Until the first
> release you can build it from source (`clients/typescript/`). The `npm install`
> command below will work once the first `client-v*` release is published.

```bash
npm install @zigbase/client
```
```
Replace with:
````md
```bash
npm install @zigbase/client
```

Published: `@zigbase/client@0.1.0`. Three tiers — the base dynamic client (this package),
the comptime-generated typed client (`zig build gen-client`), and runtime introspection
(`npx @zigbase/typegen`). See the [TypeScript SDK docs](../../docs/typescript-sdk.md).
````

- [ ] **Step 2: Refresh the root README SDK line**

In root `README.md`, update the TypeScript SDK bullet to reflect published + three tiers:
```md
- **TypeScript SDK** — published official client (`@zigbase/client@0.1.0`): auth, records,
  offset + cursor pagination, files, realtime + live store — plus a fully-typed client
  generated from your schema (`zig build gen-client`) or from any running instance
  (`npx @zigbase/typegen`). → [docs/typescript-sdk.md](docs/typescript-sdk.md)
```

- [ ] **Step 3: Stale-copy sweep (the gate)**

Run:
```bash
grep -rniE "not yet published|pre-release|coming soon|once the first .* release" --include=*.md --include=*.astro --include=*.ts . | grep -v "/.claude/"
```
Expected: **no output.** If any hit remains (e.g. a changelog or another README), fix it (or, if it's a legitimate historical changelog entry that must stay, leave it and note it in the commit). The SDK/marketing surface (site, docs, the two READMEs above) must be clean.

- [ ] **Step 4: Commit**

```bash
git add clients/typescript/README.md README.md
git commit -m "docs: SDK READMEs reflect published v0.1.0 + three tiers; stale-copy swept"
```

---

## Self-Review

**Spec coverage:**
- Homepage Features card + `SdkShowcase` after `ExamplesShowcase` → Task 1. ✓
- Sidebar entry + de-stale `typescript-sdk.md` + which-tier table + mirror → Task 2. ✓
- blog SP1 committed CI-gated e2e (base `@zigbase/client`) + README → Task 3. ✓
- golfsim SP2 README callout → Task 4. ✓
- plugins SP3 (`.enable_typegen=true` + in-repo typegen e2e) + README → Task 5. ✓
- READMEs (clients/typescript + root) + stale sweep → Task 6. ✓
- Mirror rule (site↔docs) → Task 2; published versions used verbatim → Tasks 1/2/6; file: deps kept → Tasks 3/5. ✓

**Placeholder scan:** No TBD/TODO. Verification points (not placeholders) flagged for the implementer: confirm the "Runtime introspection" anchor slug in `typescript-sdk.md` (Task 2 Step 2); confirm blog schema field/rule names against `src/main.zig` (Task 3 Step 4); confirm blog/plugins binaries are in the CI artifact (Tasks 3/5); copy golfsim's `tsconfig.json` if it exists (Task 3 Step 2).

**Type/name consistency:** `createClient`, `zb.collection(name).{create,getList,getOne,update,delete,authWithPassword}` (base, Task 3); `<plugins-bin> typegen --data-dir/--out` (Task 5); the `file:../../clients/typescript` dep (Tasks 3/5 match golfsim); the CI env vars `ZIGBASE_TEST_BLOG_BINARY`/`ZIGBASE_TEST_PLUGINS_BINARY` match the harnesses; the `typescript-sdk` slug matches the sidebar entry + the SdkShowcase link. Published versions consistent across tasks.

**Cross-task notes for the executor:**
- Tasks are independent except both Task 3 and Task 5 edit `.github/workflows/ci.yml` (different steps) — apply each task's CI edit additively; the second implementer should re-read the file (don't clobber the other's env-export line).
- The homepage `SdkShowcase` link and the sidebar slug both depend on `typescript-sdk` being the page slug — keep them in lockstep.
