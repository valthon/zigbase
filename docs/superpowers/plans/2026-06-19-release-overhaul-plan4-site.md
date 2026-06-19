# Release Overhaul — Plan 4: Site & Docs Auto-Version

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The marketing site and docs reflect the current versions automatically with no per-release edits: the site reads `build.zig.zon` (server) + `clients/typescript/package.json` (client) at build time, the README uses a dynamic release badge, and version-pinned doc prose is de-pinned (so it can't drift) — fixing the existing `v0.1.0` drift.

**Architecture:** `site/src/config/site.ts` becomes the single place that reads the out-of-tree manifests (`build.zig.zon`, the client `package.json`, and `server/targets.json`) at build time and exports `SERVER_VERSION`, `CLIENT_VERSION`, the tag, `REPO_URL`, and the download `TARGETS`. The `.astro` surfaces that show a version already import from this config (Nav/Hero/download badge) and now get it dynamically; the two hardcoded-`v0.1.0` `.astro` spots are wired to the config. Doc prose (overview, known-limitations, typescript-sdk + their `docs/*.md` mirrors, and `clients/typescript/README.md`) is **de-pinned** — version numbers replaced with "latest release" + links — which preserves the strict docs↔site mirror (a remark token plugin can't, since the GitHub-rendered mirror wouldn't process tokens). The root README uses a shields.io release badge.

**Tech Stack:** Astro (custom, not Starlight), TypeScript config read via `node:fs`, Markdown, shields.io.

## Global Constraints

- Two canonical sources: server version = `build.zig.zon` `.version`; client version = `clients/typescript/package.json` `version`. The site DERIVES both; it commits no version number. (spec §3, §8)
- The platform/target list comes from `clients/typescript/npm/server/targets.json` (the Plan-2 single source); the download page must not duplicate it. (spec §6.1, §8)
- **Mirror rule (binding, user cares a lot):** every edit to a `site/src/content/docs/*.md` is mirrored to `docs/*.md` and vice-versa, preserving each file's front-matter/link conventions; `diff` of the two must show ONLY those pre-existing convention differences.
- De-pin (don't tokenize) version literals in the mirrored docs so site + mirror stay identical AND can't drift. The changelog's version HEADINGS and release-tag links are historical CONTENT — leave them.
- After this plan, a repo-wide grep for `v0.1.0` / `0.1.0` / `0.4.0` over the user-facing surface (site `.astro`/config, the de-pinned docs, README) returns nothing except: the changelog's historical entries/links, and `clients/typescript/package.json` itself (the canonical client `0.1.0`).
- DRY/YAGNI/TDD. After each task `cd site && npm run build` exits clean.
- Run Node via `mise exec node@24 -- …`.

---

## File Structure

- `site/src/config/site.ts` — **modify**: read `SERVER_VERSION`/`CLIENT_VERSION`/`TARGETS` from the manifests at build time (replacing the hardcoded `ZIGBASE_VERSION`); keep `ZIGBASE_VERSION`/`ZIGBASE_VERSION_TAG`/`REPO_URL` as before (back-compat for existing importers).
- `site/src/pages/download.astro` — **modify**: de-pin the description; source the target table from `TARGETS` (config) instead of its inline array.
- `site/src/components/landing/QuickStart.astro` — **modify**: build the curl URL from the config version + linux-x64 triple.
- `README.md` — **modify**: dynamic shields.io release badge; de-pin the `@zigbase/client@0.1.0` prose.
- `site/src/content/docs/{overview,known-limitations,typescript-sdk}.md` + their `docs/*.md` mirrors — **modify**: de-pin version literals.
- `clients/typescript/README.md` — **modify**: de-pin `@zigbase/client@0.1.0`.

---

## Task 1: Site config reads manifests; wire the `.astro` surfaces + README badge

**Files:**
- Modify: `site/src/config/site.ts`, `site/src/pages/download.astro`, `site/src/components/landing/QuickStart.astro`, `README.md`
- Test: `cd site && npm run build` (clean) + assertions on the built HTML

**Interfaces:**
- Produces: `site/src/config/site.ts` exports `SERVER_VERSION`, `CLIENT_VERSION`, `ZIGBASE_VERSION` (= `SERVER_VERSION`), `ZIGBASE_VERSION_TAG`, `REPO_URL`, and `TARGETS: { platform: string, arch: string, triple: string }[]`. Task 2 doesn't consume this (docs side), but downstream releases rely on it auto-updating.

- [ ] **Step 1: Rewrite `site/src/config/site.ts` to read manifests at build time**

Replace the entire file with:

```ts
// Single source of truth for ZigBase *release* facts shown across the site.
// Versions are DERIVED at build time — server from build.zig.zon, client from
// the SDK package.json — so the site never hard-codes a release number and can't
// drift. Targets come from the npm server package's targets.json (Plan 2).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, '..', '..', '..'); // site/src/config -> repo root

function serverVersion(): string {
  const zon = readFileSync(join(REPO_ROOT, 'build.zig.zon'), 'utf8');
  const m = zon.match(/^\s*\.version\s*=\s*"([^"]+)"/m);
  if (!m) throw new Error('site config: could not read .version from build.zig.zon');
  return m[1];
}

function clientVersion(): string {
  const pkg = JSON.parse(readFileSync(join(REPO_ROOT, 'clients/typescript/package.json'), 'utf8'));
  return pkg.version;
}

type Target = { platform: string; arch: string; triple: string };
function targets(): Target[] {
  const raw = JSON.parse(
    readFileSync(join(REPO_ROOT, 'clients/typescript/npm/server/targets.json'), 'utf8'),
  ) as Array<{ key: string; zig: string; os: string; cpu: string }>;
  const osLabel: Record<string, string> = { linux: 'Linux', darwin: 'macOS' };
  return raw.map((t) => ({
    platform: osLabel[t.os] ?? t.os,
    arch: t.zig.split('-')[0], // x86_64 / aarch64
    triple: t.zig,
  }));
}

export const SERVER_VERSION = serverVersion();
export const CLIENT_VERSION = clientVersion();

/** Back-compat alias: existing importers use ZIGBASE_VERSION for the server release. */
export const ZIGBASE_VERSION = SERVER_VERSION;
/** Display form, e.g. "v0.4.0". */
export const ZIGBASE_VERSION_TAG = `v${SERVER_VERSION}`;

export const REPO_URL = 'https://github.com/valthon/zigbase';

export const TARGETS: Target[] = targets();
```

- [ ] **Step 2: Verify the config resolves the real versions**

Run:
```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2/site
mise exec node@24 -- node --input-type=module -e "import('./src/config/site.ts').catch(async()=>{}); " 2>/dev/null || true
mise exec node@24 -- npx tsx -e "import('./src/config/site.ts').then(m=>console.log('server',m.SERVER_VERSION,'client',m.CLIENT_VERSION,'targets',m.TARGETS.length))" 2>/dev/null || echo "(tsx not available; rely on the build in later steps)"
```
Expected: if `tsx` runs, prints `server 0.4.0 client 0.1.0 targets 4`. If `tsx` isn't available, skip — Step 6's `npm run build` is the real gate. (Do not block on this step.)

- [ ] **Step 3: De-pin + wire `download.astro`**

In `site/src/pages/download.astro` frontmatter, replace the import + inline `targets` array. Change:

```ts
import { ZIGBASE_VERSION, ZIGBASE_VERSION_TAG, REPO_URL } from '../config/site';
```
to:
```ts
import { ZIGBASE_VERSION, ZIGBASE_VERSION_TAG, REPO_URL, TARGETS } from '../config/site';
```

Delete the inline `const targets = [ … ];` block and rename its use: replace
```ts
const binaries = targets.map((t) => ({
  ...t,
  file: `zigbase-${ZIGBASE_VERSION}-${t.triple}.tar.gz`,
}));
```
with
```ts
const binaries = TARGETS.map((t) => ({
  ...t,
  file: `zigbase-${ZIGBASE_VERSION}-${t.triple}.tar.gz`,
}));
```

Then de-pin the hardcoded `v0.1.0` in the `<Base description=…>`:
```astro
  description="Download a prebuilt ZigBase v0.1.0 binary for Linux or macOS, build it from source, or use it as a Zig library."
```
becomes:
```astro
  description="Download a prebuilt ZigBase binary for Linux or macOS, build it from source, or use it as a Zig library."
```

- [ ] **Step 4: Wire `QuickStart.astro` curl URL to the current version**

In `site/src/components/landing/QuickStart.astro` frontmatter, add the import at the top (after the existing imports):
```ts
import { ZIGBASE_VERSION, ZIGBASE_VERSION_TAG, REPO_URL } from '../../config/site';
```
Then change the hardcoded `downloadCode` curl line:
```ts
const downloadCode = `# Download the prebuilt Linux binary
curl -L https://github.com/valthon/zigbase/releases/download/v0.1.0/zigbase-0.1.0-x86_64-linux-musl.tar.gz | tar xz
```
to use the config:
```ts
const downloadCode = `# Download the prebuilt Linux binary
curl -L ${REPO_URL}/releases/download/${ZIGBASE_VERSION_TAG}/zigbase-${ZIGBASE_VERSION}-x86_64-linux-musl.tar.gz | tar xz
```

- [ ] **Step 5: Root README — dynamic badge + de-pin**

In `README.md`, the status line near the top reads (around line 11):
```
`v0.4.0 — early release` · `License: Apache-2.0` · see [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)
```
Replace the hardcoded version with a dynamic shields.io release badge:
```
[![Release](https://img.shields.io/github/v/release/valthon/zigbase)](https://github.com/valthon/zigbase/releases) · `early release` · `License: Apache-2.0` · see [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)
```
And de-pin the SDK mention (around line 43): `@zigbase/client@0.1.0` → `@zigbase/client`.

- [ ] **Step 6: Build the site and assert dynamic versions + no drift**

Run:
```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2/site
mise exec node@24 -- npm run build 2>&1 | tail -5
echo "--- download page shows current version (0.4.0), not 0.1.0 ---"
grep -o "v0.4.0" dist/download.html | head -1 && echo "DOWNLOAD VERSION OK"
! grep -q "v0.1.0\|zigbase-0.1.0" dist/download.html && echo "DOWNLOAD NO DRIFT OK"
echo "--- quickstart curl uses 0.4.0 ---"
! grep -rq "releases/download/v0.1.0\|zigbase-0.1.0-x86_64" dist/index.html && echo "QUICKSTART NO DRIFT OK"
```
Expected: build exits clean (page count printed); `DOWNLOAD VERSION OK`, `DOWNLOAD NO DRIFT OK`, `QUICKSTART NO DRIFT OK`. If `npm run build` errors because `node:fs` can't be used in `site.ts`, STOP and report — that means the config read must move (fallback: read in each `.astro` frontmatter); but the established pattern (this same fs read) is expected to work in Astro's SSR build.

- [ ] **Step 7: Commit**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2
git add site/src/config/site.ts site/src/pages/download.astro site/src/components/landing/QuickStart.astro README.md
git commit -m "feat(site): derive versions from build.zig.zon + package.json; dynamic README badge; fix v0.1.0 drift"
```

---

## Task 2: De-pin the mirrored docs + client README; stale sweep

**Files:**
- Modify: `site/src/content/docs/overview.md` + `docs/overview.md`
- Modify: `site/src/content/docs/known-limitations.md` + `docs/known-limitations.md`
- Modify: `site/src/content/docs/typescript-sdk.md` + `docs/typescript-sdk.md`
- Modify: `clients/typescript/README.md`

**Interfaces:**
- Consumes: nothing (independent of Task 1).
- Produces: doc prose with no hardcoded release numbers; the docs↔site mirror stays in parity.

- [ ] **Step 1: De-pin `overview.md` (both copies)**

In BOTH `site/src/content/docs/overview.md` and `docs/overview.md`, change the early-release line:
```
It is an **early release** (`v0.1.0`, Apache-2.0). Read the
```
to:
```
It is an **early release** (Apache-2.0). Read the
```

- [ ] **Step 2: De-pin `known-limitations.md` (both copies)**

In BOTH `site/src/content/docs/known-limitations.md` and `docs/known-limitations.md`:
- front-matter `description:` — `Current caveats in ZigBase v0.1.0 —` → `Current caveats in ZigBase —`
- body line `ZigBase v0.1.0 is an early release. The gaps below are known and tracked for post-v0.1.` → `ZigBase is an early release. The gaps below are known and tracked for future releases.`
- body line `These are tracked for post-v0.1. Contributions welcome.` → `These are tracked for future releases. Contributions welcome.`

(Apply the same edits to whichever of the two files contains each line; keep the two copies identical except for their pre-existing front-matter/link conventions.)

- [ ] **Step 3: De-pin `typescript-sdk.md` (both copies)**

In BOTH `site/src/content/docs/typescript-sdk.md` and `docs/typescript-sdk.md`:
- `The SDK is published: \`@zigbase/client@0.1.0\`. Its \`@zigbase/client/typed\` and` → `The SDK is published to npm as \`@zigbase/client\`. Its \`@zigbase/client/typed\` and`
- `no install needed beyond \`npx @zigbase/typegen\` (which pulls \`@zigbase/server@0.4.0\`).` → `no install needed beyond \`npx @zigbase/typegen\` (which pulls \`@zigbase/server\`).`

- [ ] **Step 4: De-pin `clients/typescript/README.md`**

Change `Published: \`@zigbase/client@0.1.0\`.` → `Published on npm as \`@zigbase/client\`.` (preserve the rest of that sentence).

- [ ] **Step 5: Verify mirror parity**

For each edited doc, the two copies must differ ONLY in their pre-existing front-matter/link conventions:
```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2
for f in overview known-limitations typescript-sdk; do
  echo "=== $f ==="
  diff <(grep -vE '^---$|^(title|description|sidebar):' "docs/$f.md") \
       <(grep -vE '^---$|^(title|description|sidebar):' "site/src/content/docs/$f.md") \
    && echo "  (identical modulo front-matter)" || echo "  (review the diff above — should be only link-convention lines)"
done
```
Expected: each shows either identical or only the known link-convention differences (`./api` vs `api.md` style) — NO version-number differences.

- [ ] **Step 6: Stale-version sweep over the user-facing surface**

Run:
```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2
grep -rnE "v?0\.1\.0|@zigbase/(client|server)@[0-9]" \
  site/src README.md clients/typescript/README.md docs/overview.md docs/known-limitations.md docs/typescript-sdk.md 2>/dev/null \
  | grep -vE "changelog|releases/tag/v0|releases/download" \
  || echo "NO STALE VERSION PINS"
```
Expected: `NO STALE VERSION PINS` (the changelog history + release-tag/download links are allowed; they're matched out).

- [ ] **Step 7: Site build stays clean**

Run: `cd site && mise exec node@24 -- npm run build 2>&1 | tail -3`
Expected: builds clean (page count printed), no errors from the edited docs.

- [ ] **Step 8: Commit**

```bash
git add site/src/content/docs/overview.md docs/overview.md site/src/content/docs/known-limitations.md docs/known-limitations.md site/src/content/docs/typescript-sdk.md docs/typescript-sdk.md clients/typescript/README.md
git commit -m "docs: de-pin release-version prose (site + docs mirror + SDK README); rely on dynamic display"
```

---

## Notes for the executor

- **Deviation from the spec's mechanism (intentional):** the spec §8 proposed a remark token plugin for the site docs. That would break docs↔site mirror parity (the GitHub-rendered `docs/*.md` can't process `{{…}}` tokens), so this plan DE-PINS the doc prose instead — same outcome (no drift), and the mirror stays identical. The live "current version" UI is the site config + badge (Task 1), which is where a visitor actually looks for it.
- After Plan 4, every version reference is either derived (site/config/badge) or absent (de-pinned prose) — except the two canonical sources and the changelog history. Cutting a release needs no site/doc edits.
- This is the last plan of the overhaul. After it merges, the finale is cutting the real `v0.4.1` through the unified pipeline (Plan 3) — shipping the stripped binaries (Plan 1) via the generated packages (Plan 2), with the site auto-reflecting `0.4.1` on its next deploy.
