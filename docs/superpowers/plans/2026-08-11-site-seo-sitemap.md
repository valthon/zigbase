# Marketing-Site SEO (sitemap, robots, GSC, JSON-LD) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Astro marketing site the discoverability plumbing Google needs: a generated sitemap, a robots.txt that points at it, the owner's Search Console verification tag, and `SoftwareApplication` structured data on the landing page.

**Architecture:** All changes live under `site/` (static Astro build deployed to GitHub Pages at `https://valthon.github.io/zigbase`). The sitemap comes from the official `@astrojs/sitemap` integration so URL enumeration tracks the routes automatically; everything else is static head/body markup. There is no JS test framework in `site/` — verification is `npm run build` plus shell assertions against `site/dist/`, run failing-first where possible.

**Tech Stack:** Astro 5, `@astrojs/sitemap` v3, Node 24 via mise.

## Global Constraints

- Work in the worktree at `/home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap` — use absolute paths; never `cd` into the main checkout.
- Node runs through mise: `mise exec node@24 -- npm …` (or an activated mise shell).
- Site URL facts (from `site/astro.config.mjs`): `site: 'https://valthon.github.io'`, `base: '/zigbase'`, `trailingSlash: 'never'`, `build.format: 'file'`. Sitemap URLs MUST match the canonical form already emitted by `Base.astro`: `https://valthon.github.io/zigbase/<path>` with no `.html` suffix and no trailing slash (root is `https://valthon.github.io/zigbase/`).
- GSC verification token (verbatim): `NibV2pc_Q1_s1duZ69GK0SW5gmFT7rfyp5LKttrsG7Y`.
- Never hand-edit `site/src/content/docs/` (generated mirror) or `CHANGELOG.md` (use a `changelog.d/` fragment).
- Commit subjects are plain summaries — no `feat:`/`fix:` conventional prefixes.
- Spec: `docs/superpowers/specs/2026-08-11-site-seo-sitemap-design.md`.

---

### Task 1: Sitemap integration + robots.txt

**Files:**
- Modify: `site/package.json` (dependency added by `npm install`)
- Modify: `site/astro.config.mjs`
- Create: `site/public/robots.txt`

**Interfaces:**
- Consumes: existing `site`/`base`/`trailingSlash`/`format` values in `site/astro.config.mjs`.
- Produces: build artifacts `site/dist/sitemap-index.xml` and `site/dist/sitemap-0.xml`; `site/dist/robots.txt`. Task 4's verification sweep re-checks these.

- [ ] **Step 1: Baseline failing check — confirm no sitemap today**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap/site
mise exec node@24 -- npm install
mise exec node@24 -- npm run build
test -f dist/sitemap-index.xml && echo "UNEXPECTED: sitemap exists" || echo "OK: no sitemap yet"
```

Expected: `OK: no sitemap yet` (and the build itself succeeds — if the clean build fails, stop and report).

- [ ] **Step 2: Install the integration**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap/site
mise exec node@24 -- npm install @astrojs/sitemap
```

Expected: `site/package.json` gains `"@astrojs/sitemap": "^3.x"` under `dependencies`; `package-lock.json` updates.

- [ ] **Step 3: Wire it into `site/astro.config.mjs`**

Add the import next to the existing ones:

```js
import sitemap from '@astrojs/sitemap';
```

and change the integrations line from `integrations: [mdx()],` to:

```js
  integrations: [mdx(), sitemap()],
```

Touch nothing else in the file.

- [ ] **Step 4: Create `site/public/robots.txt`**

Exact content:

```text
User-agent: *
Allow: /

Sitemap: https://valthon.github.io/zigbase/sitemap-index.xml
```

- [ ] **Step 5: Build and assert the artifacts**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap/site
mise exec node@24 -- npm run build
test -f dist/sitemap-index.xml && test -f dist/sitemap-0.xml && test -f dist/robots.txt && echo ARTIFACTS-OK
grep -c '<loc>https://valthon.github.io/zigbase' dist/sitemap-0.xml
grep -c '\.html</loc>' dist/sitemap-0.xml || echo NO-HTML-SUFFIX-OK
grep -c '/zigbase/docs/[a-z-]*/</loc>' dist/sitemap-0.xml || echo NO-TRAILING-SLASH-OK
```

Expected: `ARTIFACTS-OK`; the first grep count > 0 (every `<loc>` is under the site prefix); `NO-HTML-SUFFIX-OK` and `NO-TRAILING-SLASH-OK` (grep exits 1 when zero matches, i.e. no `.html` URLs and no trailing-slash doc URLs).

**Contingency:** if `.html`-suffixed or trailing-slash URLs appear (older integration behavior under `build.format: 'file'`), add a `serialize` hook to the integration in `astro.config.mjs` that normalizes each entry to the canonical form used by `Base.astro`:

```js
    sitemap({
      serialize(item) {
        item.url = item.url.replace(/\/index\.html$/, '/').replace(/\.html$/, '');
        return item;
      },
    }),
```

then rebuild and re-run the assertions.

- [ ] **Step 6: Commit**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap
git add site/package.json site/package-lock.json site/astro.config.mjs site/public/robots.txt
git commit -m "Generate a sitemap for the marketing site and add robots.txt"
```

---

### Task 2: Google Search Console verification meta tag

**Files:**
- Modify: `site/src/layouts/Base.astro` (head section, around line 41)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a `google-site-verification` meta tag in every built page's `<head>`; Task 4 re-checks it site-wide.

- [ ] **Step 1: Baseline failing check**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap/site
grep -c google-site-verification dist/index.html || echo OK-ABSENT
```

Expected: `OK-ABSENT` (tag not in the current build output).

- [ ] **Step 2: Add the tag to `site/src/layouts/Base.astro`**

Directly after the canonical link line (`<link rel="canonical" href={canonicalURL} />`), insert:

```html
    <meta name="google-site-verification" content="NibV2pc_Q1_s1duZ69GK0SW5gmFT7rfyp5LKttrsG7Y" />
```

- [ ] **Step 3: Build and assert it renders on every page**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap/site
mise exec node@24 -- npm run build
find dist -name '*.html' | xargs grep -L google-site-verification
```

Expected: `grep -L` prints nothing (no HTML file lacks the tag; the command exit code will be non-zero because grep -L found no files to list — that is the passing outcome).

- [ ] **Step 4: Commit**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap
git add site/src/layouts/Base.astro
git commit -m "Add the Google Search Console verification tag to every site page"
```

---

### Task 3: SoftwareApplication JSON-LD on the landing page

**Files:**
- Modify: `site/src/pages/index.astro`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: one `<script type="application/ld+json">` block in `dist/index.html` whose body parses as JSON with `"@type": "SoftwareApplication"`; Task 4 re-checks it.

- [ ] **Step 1: Baseline failing check**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap/site
grep -c 'application/ld+json' dist/index.html || echo OK-ABSENT
```

Expected: `OK-ABSENT`.

- [ ] **Step 2: Add the schema to `site/src/pages/index.astro`**

In the frontmatter (after the existing imports, before the closing `---`), add:

```js
// SoftwareApplication structured data for the landing page. The description
// mirrors the default meta description in Base.astro — keep them in sync.
const structuredData = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  name: 'ZigBase',
  description:
    'ZigBase is an open-source, single-binary backend — collections, auth, realtime, search, multi-tenancy, jobs, email, admin UI — on SQLite or PostgreSQL, and an embeddable Zig framework.',
  url: 'https://valthon.github.io/zigbase/',
  applicationCategory: 'DeveloperApplication',
  operatingSystem: 'Linux, macOS',
  license: 'https://www.apache.org/licenses/LICENSE-2.0',
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
  sameAs: ['https://github.com/valthon/zigbase'],
};
```

In the template, directly after `<Base>` (before `<Nav />`), add:

```astro
  <script is:inline type="application/ld+json" set:html={JSON.stringify(structuredData)} />
```

(JSON-LD is valid inside `<body>`; `Base.astro` has no named head slot and Google parses it either way. `is:inline` + `set:html` keeps Astro from bundling or escaping it.)

- [ ] **Step 3: Build and assert the block parses as JSON**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap/site
mise exec node@24 -- npm run build
mise exec python@3.13 -- python -c "
import json, re
html = open('dist/index.html').read()
m = re.search(r'<script type=\"application/ld\+json\">(.*?)</script>', html, re.S)
assert m, 'JSON-LD block missing'
data = json.loads(m.group(1))
assert data['@type'] == 'SoftwareApplication', data
assert data['name'] == 'ZigBase', data
print('JSONLD-OK')
"
```

Expected: `JSONLD-OK`.

- [ ] **Step 4: Commit**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap
git add site/src/pages/index.astro
git commit -m "Describe ZigBase with SoftwareApplication structured data on the landing page"
```

---

### Task 4: Changelog fragment + full verification sweep

**Files:**
- Create: `changelog.d/site-seo-discoverability.md`

**Interfaces:**
- Consumes: the build artifacts produced by Tasks 1–3.
- Produces: the PR-ready branch state.

- [ ] **Step 1: Create `changelog.d/site-seo-discoverability.md`**

Exact content:

```markdown
### Internal

- The marketing site now generates a sitemap (`@astrojs/sitemap`), ships a `robots.txt` pointing at it, carries the Google Search Console verification tag on every page, and describes ZigBase with `SoftwareApplication` JSON-LD on the landing page.
```

- [ ] **Step 2: Full clean-build verification sweep**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap/site
rm -rf dist
mise exec node@24 -- npm run build
test -f dist/sitemap-index.xml && test -f dist/sitemap-0.xml && test -f dist/robots.txt && echo ARTIFACTS-OK
grep -c '<loc>https://valthon.github.io/zigbase' dist/sitemap-0.xml
grep -c '\.html</loc>' dist/sitemap-0.xml || echo NO-HTML-SUFFIX-OK
grep 'Sitemap: https://valthon.github.io/zigbase/sitemap-index.xml' dist/robots.txt && echo ROBOTS-OK
find dist -name '*.html' | xargs grep -L google-site-verification
grep -c 'application/ld+json' dist/index.html
```

Expected: `ARTIFACTS-OK`; loc-count > 0; `NO-HTML-SUFFIX-OK`; `ROBOTS-OK`; the `grep -L` prints nothing; the last count is `1`.

- [ ] **Step 3: Commit**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/site-seo-sitemap
git add changelog.d/site-seo-discoverability.md
git commit -m "Add a changelog fragment for the site SEO work"
```
