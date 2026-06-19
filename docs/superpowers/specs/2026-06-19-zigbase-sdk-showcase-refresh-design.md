# ZigBase — SDK Showcase Refresh (marketing site + examples)

**Status:** Approved design (2026-06-19)
**Context:** The three-tier TypeScript SDK is complete and published to npm (`@zigbase/client@0.1.0`, `@zigbase/server@0.4.0`, `@zigbase/typegen@0.1.1`). The marketing site doesn't mention the SDK on its homepage, the comprehensive SDK docs page is orphaned from the nav and still says "not yet published," and the examples don't deliberately showcase the three tiers. This refresh fixes all of that.

---

## 1. Goal

Make the now-published three-tier TypeScript SDK a first-class, discoverable story across the marketing site, docs, examples, and READMEs — and have each example deliberately demonstrate one tier.

**The three tiers (the narrative anchor):**
- **Base dynamic** — `@zigbase/client`: hand-written client, dynamic records/auth/realtime/files; you pass types as parameters.
- **Comptime-generated typed** — `zig build gen-client` (`genClientStep`): a fully-typed `zbase.gen.ts` (typed `zb.db.*`, typed `zb.rpc.*`) generated from your Zig schema at build time.
- **Runtime introspection** — `npx @zigbase/typegen --data-dir … | --url …`: a typed client generated from any running instance's live schema, no Zig toolchain (no typed `rpc.*` — routes aren't introspectable at runtime).

## 2. Non-goals

- No new SDK features or API changes — this is presentation/examples only.
- `fixtures/dating` stays a private test fixture (not showcased).
- The example React frontends are NOT rewired to consume the SDK (the lightweight per-example demo/e2e + README approach was chosen over frontend integration).
- In-repo examples keep their `file:` SDK dependency (so their build/tests run against local SDK source); READMEs show the real `npm install` / `npx` commands users run.

## 3. Components

### 3.1 Homepage marketing (`site/`)
The site is custom Astro (not Starlight): a landing page (`site/src/pages/index.astro` composing `landing/*` components) + MDX/MD docs (`site/src/content/docs/*`).

- **Features card (`site/src/components/landing/Features.astro`):** add a 9th card — "Typed TypeScript SDK" — matching the existing card markup/style (icon + title + one-line blurb): "Generate a fully-typed client from your schema — or any running instance. Records, realtime, files, and typed custom-route RPC."
- **New section `site/src/components/landing/SdkShowcase.astro`**, modeled on the existing `ExamplesShowcase.astro` (same section shell, heading style, and dual-theme Shiki code block), placed in `index.astro` after `ExamplesShowcase` (or adjacent — wherever it reads best in the existing flow). It presents the three tiers as three cards/columns:
  - *Base dynamic* — `npm install @zigbase/client`; a 3–4 line `createClient` + `zb.collection(...).getList()` snippet.
  - *Comptime-typed* — `zig build gen-client`; a snippet showing typed `zb.db.<collection>.create(...)` + `zb.rpc.<route>(...)`.
  - *Runtime introspection* — `npx @zigbase/typegen --url https://api.example.com --out src/zbase.gen.ts`; one line, "no Zig toolchain."
  - A short lead-in line + a "Read the SDK docs →" link to `typescript-sdk`.
- The hero is unchanged (per the chosen "feature card + dedicated section," not "hero mention").

### 3.2 Docs — surface + de-stale (`site/src/content/docs/` + `site/src/config/sidebar.ts`)
- **Sidebar (`site/src/config/sidebar.ts`):** add a **TypeScript SDK** entry pointing at `typescript-sdk`, in the **Guides** group beside **Framework**. (Today `typescript-sdk.md` exists but is absent from the sidebar array → unreachable except by direct URL.)
- **De-stale `site/src/content/docs/typescript-sdk.md`** (and its `docs/typescript-sdk.md` mirror):
  - Replace the "Pre-release: `@zigbase/client` is not yet published to npm" block with the real install: `npm install @zigbase/client` (note the `/typed` and `/realtime` subpath exports ship in the same package), and the runtime tool `npx @zigbase/typegen`.
  - State the published versions in the intro: `@zigbase/client@0.1.0`, `@zigbase/server@0.4.0`, `@zigbase/typegen@0.1.1`.
  - Add a **"Which tier should I use?"** table near the top:

    | Tier | Get it | Typing | Typed custom-route RPC | Needs Zig source |
    |---|---|---|---|---|
    | Base dynamic | `npm install @zigbase/client` | you pass `<Type>` | no | no |
    | Comptime-generated | `zig build gen-client` | full, from schema | **yes** (`zb.rpc.*`) | yes |
    | Runtime introspection | `npx @zigbase/typegen` | full (db/realtime/files) | no | no |
- **Framework doc (`framework.md` + mirror):** verify the `enable_typegen` + `typegen` section is current (it is); no stale-publish copy there. Only touch if something is stale.

### 3.3 Examples — one tier each (lightweight)
Each example's README gets a clearly-labelled "TypeScript SDK" section naming the tier it demonstrates; each gets a runnable demonstration.

- **`examples/blog` → Tier 1 (base dynamic).** Add a small SDK demo: a script (e.g. `examples/blog/clients/typescript/demo.ts` or a test) that `createClient`s against the blog server and does base-client auth + dynamic CRUD on `posts`/`users` (no codegen). Wire a `@zigbase/client` `file:` dep + a minimal `package.json`/script. An e2e (mirroring golfsim's harness pattern) that builds the blog binary, serves it, runs the demo, asserts results. README section: "Using the base TypeScript SDK (`@zigbase/client`)" with the real `npm install @zigbase/client` for users.
- **`examples/golfsim` → Tier 2 (comptime-generated).** Already uses the generated `zbase.gen.ts` (`zb.db.*` + `zb.rpc.*`) via `genClientStep`. Add a README callout identifying this as the **comptime-generated typed** tier and pointing at the SDK docs. No code change beyond README/comment unless something is stale.
- **`examples/plugins` → Tier 3 (runtime introspection).** Set `.enable_typegen = true` on the plugins `App(.{ … })` config (one line) so the example's own binary carries the `typegen` subcommand — the realistic "your server generates its client" story. README shows the real `npx @zigbase/typegen --url <plugins server> --out zbase.gen.ts` (and the `--data-dir` offline form) for end users. In-repo verification (a script/e2e) runs the **locally-built plugins binary** itself — `./plugins typegen --data-dir <provisioned data dir> --out zbase.gen.ts` against a data dir the plugins server provisioned — so CI needs no network and no extra binary. README section: "Generate a typed client at runtime — no Zig toolchain." (typegen is schema-agnostic: it reads `_collections` from the data dir, so any `enable_typegen=true` build works; using the example's own binary keeps the demo self-contained.)

### 3.4 READMEs
- **`clients/typescript/README.md`:** remove the "Pre-release / not yet published" block; show published `@zigbase/client@0.1.0` install, the three tiers (with the `npx @zigbase/typegen` pointer), and a link to the SDK docs.
- **Root `README.md`:** update the one-line SDK pitch to reflect "published, three tiers (base / comptime-generated / runtime `npx @zigbase/typegen`)".
- Any `examples/*/README.md` touched per §3.3.

## 4. Mirror & freshness rules (binding)

- Every edit to a `site/src/content/docs/*.md` file is mirrored into the corresponding `docs/*.md` (and vice-versa), preserving each file's pre-existing front-matter and link conventions (site uses `./`-relative + Astro front-matter; `docs/` uses bare/`.md` links). This is a strict, severe project requirement.
- After the refresh, a repo-wide grep for stale phrases — "not yet published", "pre-release", "coming soon", "once the first … release" — must return nothing in the SDK/marketing surface (site, docs, READMEs).

## 5. Testing / Verification

- **Site build:** `cd site && npm run build` exits clean; the TypeScript SDK page is reachable from the sidebar; the homepage renders the new Features card + `SdkShowcase` section (no broken links/anchors; the "Read the SDK docs" link resolves).
- **Examples:** the new blog SP1 demo/e2e passes; the plugins SP3 demo (local binary) generates a client and the README's npx command is accurate; the existing golfsim e2e stays green.
- **Mirror parity:** `diff docs/<f> site/src/content/docs/<f>` for each edited doc shows only the pre-existing front-matter/link-convention differences.
- **Stale-copy gate:** the grep in §4 returns nothing.
- **CI:** the existing `build`/`ts-sdk`/`browser` jobs stay green (the blog/plugins example demos must not break their builds or the example e2e jobs).

## 6. Decomposition (for the plan)

Cohesive single spec; the plan will break into ~tasks: (a) homepage — Features card + `SdkShowcase.astro` + wire into `index.astro`; (b) docs — sidebar entry + de-stale `typescript-sdk.md` + "which tier" table (+ mirror); (c) blog SP1 demo + e2e + README; (d) golfsim README callout; (e) plugins SP3 demo + README; (f) READMEs (`clients/typescript`, root) + stale-copy sweep.
