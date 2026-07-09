# Single-Source Docs — PR 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or executing-plans.

**Goal:** Migrate the remaining 15 `docs/*.md` ↔ site-mirror pairs onto the generator built in PR 1, so **every** published doc is single-sourced from its canonical. Accepts the cosmetic loss of the site's hand-tuned heading IDs / link text (user-approved 2026-07-09).

**Spec:** `docs/superpowers/specs/2026-07-08-docs-single-source-design.md` (PR 2 = the "remaining ~15 pairs" stage).

## Audit findings (already done — the reconciliation surface)

- **8 pairs are content-identical** to their canonical after banner-strip + link-rewrite (abilities, analytics, email, jobs-and-webhooks, postgres, realtime-broadcast, search, tenancy) — trivial.
- **7 pairs diverge** but the divergence is **site-adaptation, not content drift** (framework, fields, api, recipes, docker, typescript-sdk, dart-sdk): the mirrors carry custom heading IDs (`{#…}`), polished link text, and GitHub-URL forms of `../` links. **Decision: regenerate from canonical, accepting those cosmetic reversions** — after a content-safety check confirms no site-only *prose* is lost.
- Every canonical opens with a `> 📖 This documentation is also published … — the site is the canonical reading experience.` banner that must be stripped when generating (it's a "read this on the site" pointer, wrong ON the site).

## Global Constraints

- Generated mirrors are gitignored build artifacts; do NOT hand-edit them.
- Do NOT touch the site-only pages (`configuration.md`, `overview.md`) or the `.mdx` pages (`tutorial.mdx`, `quick-start.mdx`) — they are authored in the site.
- Verify: `cd site && npm run build` → `Complete!`; `git status` clean after build; the content-safety diff (below) shows only accepted-cosmetic differences.

---

## Task 1: Enhance the generator + a persisted registry, migrate all 15

**Files:**
- Create: `site/scripts/docs-registry.json` (the {canonical → mirror + frontmatter} table for all 17 entries)
- Modify: `site/scripts/gen-docs-mirror.mjs` (read the JSON; robust banner-strip; link resolver)
- Modify: `site/.gitignore` (ignore all 17 generated mirrors)
- `git rm`: the 15 site mirrors
- Modify (reconcile if content-safety flags anything): the affected `docs/*.md`
- Modify: `CLAUDE.md`, `.github/pull_request_template.md` (full single-sourcing now)

- [ ] **Step 1: Build the persisted registry `site/scripts/docs-registry.json`**

Extract each current mirror's frontmatter (title/description/order/group) so it survives the mirror's deletion. Run from `site/`:
```bash
node -e '
const fs=require("fs");
const dir="src/content/docs";
// canonical path (repo-relative) for each generated route:
const CANON={changelog:"CHANGELOG.md",["known-limitations"]:"KNOWN_LIMITATIONS.md"};
const routes=["changelog","known-limitations","abilities","analytics","api","dart-sdk","docker","email","fields","framework","jobs-and-webhooks","postgres","realtime-broadcast","recipes","search","tenancy","typescript-sdk"];
const reg=routes.map(r=>{
  const f=fs.readFileSync(`${dir}/${r}.md`,"utf8");
  const m=f.match(/^---\n([\s\S]*?)\n---/);
  const fm={}; for(const line of m[1].split("\n")){const i=line.indexOf(":"); const k=line.slice(0,i).trim(); let v=line.slice(i+1).trim(); if(/^\d+$/.test(v))v=+v; fm[k]=v;}
  return {canonical: CANON[r]||`docs/${r}.md`, mirror:`${r}.md`, frontmatter:fm};
});
fs.writeFileSync("scripts/docs-registry.json", JSON.stringify(reg,null,2)+"\n");
console.log("wrote scripts/docs-registry.json with",reg.length,"entries");
'
```
Confirm 17 entries, each with a canonical path, mirror name, and 4 frontmatter fields. (This is run BEFORE the mirrors are `git rm`'d, so their frontmatter is captured.)

- [ ] **Step 2: Rewrite `site/scripts/gen-docs-mirror.mjs`**

```js
// Generate site doc mirrors from canonical sources. Mirrors under
// site/src/content/docs/ are gitignored build artifacts — edit the canonical
// (repo-root CHANGELOG.md/KNOWN_LIMITATIONS.md, or docs/*.md), never the mirror.
// Runs via package.json predev/prebuild (CI/release use `npm run build`).
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const siteDir = dirname(dirname(fileURLToPath(import.meta.url)));
const repoRoot = dirname(siteDir);
const REGISTRY = JSON.parse(readFileSync(join(siteDir, 'scripts/docs-registry.json'), 'utf8'));

// Every published doc-route name (mirror .md basenames + the site-authored .mdx
// pages) — a link to one of these resolves to `./<route>`; anything else in the
// repo becomes a GitHub URL.
const PUBLISHED = new Set([
  'abilities', 'analytics', 'api', 'changelog', 'configuration', 'dart-sdk',
  'docker', 'email', 'fields', 'framework', 'jobs-and-webhooks', 'known-limitations',
  'overview', 'postgres', 'quick-start', 'realtime-broadcast', 'recipes', 'search',
  'tenancy', 'tutorial', 'typescript-sdk',
]);
// Root canonicals linked by UPPER_CASE basename → their route.
const ROOT_ROUTE = new Map([['CHANGELOG', 'changelog'], ['KNOWN_LIMITATIONS', 'known-limitations']]);
const BLOB = 'https://github.com/valthon/zigbase/blob/main/';
const TREE = 'https://github.com/valthon/zigbase/tree/main/';

// Strip the canonical-only "also published on the site" banner blockquote wherever
// it sits (it usually follows the H1). Matches the blockquote line(s) + trailing blank.
function stripBanner(body) {
  return body.replace(/(^|\n)> 📖 This documentation is also published[^\n]*(\n>[^\n]*)*\n?/, '$1');
}

// Resolve a relative link target to a repo-root-relative path, given the canonical's
// directory (`docs` for docs/*.md, `` for the root CHANGELOG/KNOWN_LIMITATIONS).
function resolveRepoPath(path, canonicalDir) {
  const stack = canonicalDir ? canonicalDir.split('/') : [];
  for (const p of path.split('/')) {
    if (p === '' || p === '.') continue;
    else if (p === '..') stack.pop();
    else stack.push(p);
  }
  return stack.join('/');
}

// Rewrite link TARGETS (never text). `.md` links to a published doc → `./route`;
// any other repo file/dir (../README.md, ../clients/…, ../examples/blog/) → a
// GitHub URL; absolute + in-page links untouched. Warn on the GitHub fallback.
function rewriteLinks(body, canonicalPath) {
  const dir = canonicalPath.includes('/') ? canonicalPath.slice(0, canonicalPath.lastIndexOf('/')) : '';
  return body.replace(/\]\(([^)\s]+)\)/g, (m, target) => {
    const h = target.indexOf('#');
    const path = h >= 0 ? target.slice(0, h) : target;
    const anchor = h >= 0 ? target.slice(h) : '';
    if (path === '') return m;                       // in-page #anchor
    if (/^(https?:|mailto:)/i.test(path)) return m;  // absolute
    const isMd = path.endsWith('.md');
    const isRel = path.startsWith('../') || path.startsWith('./') || !path.includes(':');
    if (!isMd && !path.startsWith('../')) return m;  // only .md links and ../ repo links
    if (!isRel) return m;
    const repoPath = resolveRepoPath(path, dir);
    if (repoPath.startsWith('docs/') && repoPath.endsWith('.md')) {
      const name = repoPath.slice(5, -3);
      if (PUBLISHED.has(name)) return `](./${name}${anchor})`;
    }
    if (repoPath.endsWith('.md') && !repoPath.includes('/')) {
      const stem = repoPath.slice(0, -3);
      if (ROOT_ROUTE.has(stem)) return `](./${ROOT_ROUTE.get(stem)}${anchor})`;
    }
    console.warn(`gen-docs-mirror: [${canonicalPath}] "${path}" → GitHub (${repoPath})`);
    const url = (repoPath.endsWith('/') ? TREE : BLOB) + repoPath;
    return `](${url}${anchor})`;
  });
}

function frontmatter(fm) {
  return `---\ntitle: ${fm.title}\ndescription: ${fm.description}\norder: ${fm.order}\ngroup: ${fm.group}\n---\n`;
}

for (const e of REGISTRY) {
  const raw = readFileSync(join(repoRoot, e.canonical), 'utf8');
  const out =
    frontmatter(e.frontmatter) +
    `\n<!-- GENERATED from ${e.canonical} by site/scripts/gen-docs-mirror.mjs — DO NOT EDIT; edit the canonical file. -->\n\n` +
    rewriteLinks(stripBanner(raw), e.canonical);
  writeFileSync(join(siteDir, 'src/content/docs', e.mirror), out);
  console.log(`gen-docs-mirror: ${e.mirror} <- ${e.canonical}`);
}
```

- [ ] **Step 3: Generate + CONTENT-SAFETY check (the guardrail)**

Run: `cd site && node scripts/gen-docs-mirror.mjs` — expect 17 lines + warnings only for the `../README.md`/`../clients`/`../examples` GitHub fallbacks (those are correct).

For EACH of the 7 diverged files, diff the newly-generated mirror against the **committed** (pre-migration) mirror and confirm the ONLY differences are the accepted cosmetic classes — custom heading IDs (`{#…}`), link text, `./x` vs GitHub-URL for `../` links, and whitespace/blockquote formatting. **If any file shows a run of site-only PROSE (a sentence/paragraph the canonical lacks), STOP and fold that prose into the canonical `docs/<file>.md`, then regenerate.** Helper (word-level diff, ignores wrapping):
```bash
for b in framework fields api recipes docker typescript-sdk dart-sdk; do
  echo "===== $b ====="
  git show HEAD:site/src/content/docs/$b.md | tail -n +$(($(git show HEAD:site/src/content/docs/$b.md | grep -n '^---$' | sed -n 2p | cut -d: -f1)+1)) \
    | tr -s '[:space:]' '\n' > /tmp/old.txt
  tail -n +2 site/src/content/docs/$b.md | tr -s '[:space:]' '\n' > /tmp/new.txt
  diff /tmp/old.txt /tmp/new.txt | grep -E '^[<>]' | grep -vE '\{#|^[<>] \./|github.com|^[<>] >$' | head -40
done
```
A near-empty result per file = only cosmetic differences (safe). Any surviving prose lines = reconcile into the canonical.

- [ ] **Step 4: gitignore + remove all committed mirrors**

`site/.gitignore` — replace the PR-1 two-line block with all 17:
```
# Generated from canonical docs by scripts/gen-docs-mirror.mjs — do not commit.
src/content/docs/changelog.md
src/content/docs/known-limitations.md
src/content/docs/abilities.md
src/content/docs/analytics.md
src/content/docs/api.md
src/content/docs/dart-sdk.md
src/content/docs/docker.md
src/content/docs/email.md
src/content/docs/fields.md
src/content/docs/framework.md
src/content/docs/jobs-and-webhooks.md
src/content/docs/postgres.md
src/content/docs/realtime-broadcast.md
src/content/docs/recipes.md
src/content/docs/search.md
src/content/docs/tenancy.md
src/content/docs/typescript-sdk.md
```
Then: `git rm` the 15 newly-migrated mirrors (changelog + known-limitations were already removed in PR 1):
```bash
git rm site/src/content/docs/{abilities,analytics,api,dart-sdk,docker,email,fields,framework,jobs-and-webhooks,postgres,realtime-broadcast,recipes,search,tenancy,typescript-sdk}.md
```
Confirm the 2 site-only pages (`configuration.md`, `overview.md`) and the `.mdx` pages remain tracked.

- [ ] **Step 5: Build + verify clean**

Run: `cd site && npm run build 2>&1 | tail -3` → `Complete!`.
Run (repo root): `git status --porcelain site/src/content/docs/` → empty (all 17 generated mirrors gitignored; the 2 site-only + `.mdx` untouched).
Spot-check a built page: `grep -c 'also published' site/dist/docs/framework.html` → 0 (banner stripped); `grep -o 'href="[^"]*clients[^"]*"' site/dist/docs/dart-sdk.html` → a github.com URL (not a broken `../clients` link).
Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q` → passes.

- [ ] **Step 6: Finish the process-doc single-sourcing + commit**

- `CLAUDE.md`: update the docs-sync rule — ALL published docs under `site/src/content/docs/` (except the site-only `configuration.md`/`overview.md` and the `.mdx` pages) are now **generated** from their canonical (`docs/*.md`, `CHANGELOG.md`, `KNOWN_LIMITATIONS.md`) by `site/scripts/gen-docs-mirror.mjs`; edit the canonical, never the mirror. Remove the "PR 1 of 2 / rest still hand-synced" interim wording added in PR 1.
- `.github/pull_request_template.md`: replace the "update `site/src/content/docs/` to match" checklist item with "edit the canonical `docs/*.md` (the site mirror regenerates); `configuration.md`/`overview.md` and the `.mdx` pages are site-authored."
```bash
git add -A
git commit -m "refactor(docs): single-source all remaining docs/*.md mirrors"
```

## Self-Review Notes
- The link resolver handles the three real cases from the audit: published `.md` → `./route`; `../CHANGELOG.md`/`../KNOWN_LIMITATIONS.md` → their routes; other `../` repo links (README, clients, examples) → GitHub blob/tree URLs. In-page + absolute links untouched.
- `PUBLISHED` now includes the `.mdx` routes (`tutorial`, `quick-start`) so links to them resolve to `./tutorial` rather than a GitHub URL.
- Content-safety (step 3) is the guardrail against silently dropping site-only prose; cosmetic reversions are accepted per the user's decision.
- Frontmatter is persisted in `docs-registry.json` (captured from the current mirrors) so it survives their deletion.
