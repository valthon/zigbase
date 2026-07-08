# Single-Source Docs — PR 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or executing-plans to implement task-by-task.

**Goal:** Build the registry-driven docs-mirror generator and apply it to the two drift-proven files (`CHANGELOG.md`, `KNOWN_LIMITATIONS.md`), making the canonical the single source of truth and the site mirror a gitignored build artifact. (Remaining ~15 pairs migrate in PR 2.)

**Spec:** `docs/superpowers/specs/2026-07-08-docs-single-source-design.md`

## Global Constraints

- The generator is **zero-dependency Node ESM**; the site is Astro 5.
- Generated mirrors are **gitignored build artifacts** — never edited by hand, regenerated on `npm run dev`/`build`.
- Do NOT touch the site-only pages (`configuration.md`, `overview.md`) or add the intentionally-unpublished docs.
- Link rewrite touches only the URL, never link text; absolute + in-page `#` links untouched.
- Verify: `cd site && npm run build` → `Complete!`; `git status` clean after build; regenerated `known-limitations.md` is correct.

---

## Task 1: Generator + wire-up + single-source the two files

**Files:**
- Create: `site/scripts/gen-docs-mirror.mjs`
- Modify: `site/package.json` (scripts), `site/.gitignore`
- `git rm`: `site/src/content/docs/changelog.md`, `site/src/content/docs/known-limitations.md`
- Modify: `KNOWN_LIMITATIONS.md` (reconcile — see step 6)
- Modify: `scripts/assemble-changelog.sh` (write only CHANGELOG.md)
- Modify: `CLAUDE.md`, `.github/pull_request_template.md` (drop the mirror-sync rule)

- [ ] **Step 1: Create the generator `site/scripts/gen-docs-mirror.mjs`**

```js
// Generate site doc mirrors from the canonical source files. The mirrors under
// site/src/content/docs/ are gitignored build artifacts — edit the canonical file
// (repo-root CHANGELOG.md / KNOWN_LIMITATIONS.md, or docs/*.md), never the mirror.
// Runs via package.json predev/prebuild, so `npm run dev` and `npm run build`
// (and CI/release, which use `npm run build`) always regenerate first.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const siteDir = dirname(dirname(fileURLToPath(import.meta.url))); // .../site
const repoRoot = dirname(siteDir);

// Published doc-route names (mirror basenames without .md). Used by the link
// rewriter: a `docs/<name>.md` link to a published route becomes `./<name>`;
// a link to an unpublished doc (dx-assessment, ideas, security-audit, tutorial)
// becomes a GitHub blob URL so it resolves instead of 404-ing.
const PUBLISHED = new Set([
  'abilities', 'analytics', 'api', 'changelog', 'configuration', 'dart-sdk',
  'docker', 'email', 'fields', 'framework', 'jobs-and-webhooks', 'known-limitations',
  'overview', 'postgres', 'realtime-broadcast', 'recipes', 'search', 'tenancy',
  'typescript-sdk',
]);

// { canonical (relative to repo root) -> mirror basename + frontmatter }.
// PR 1: the two drift-proven root files. PR 2 extends this to docs/*.md pairs.
const REGISTRY = [
  {
    canonical: 'CHANGELOG.md',
    mirror: 'changelog.md',
    fm: {
      title: 'Changelog',
      description: 'Release history for ZigBase, following Keep a Changelog and Semantic Versioning.',
      order: 4,
      group: 'reference',
    },
  },
  {
    canonical: 'KNOWN_LIMITATIONS.md',
    mirror: 'known-limitations.md',
    fm: {
      title: 'Known limitations',
      description: 'Current caveats in ZigBase — auth/email, framework hooks, schema migrations, fields, the scheduler, platform/UI gaps, and deferred work.',
      order: 3,
      group: 'reference',
    },
  },
];

// Rewrite markdown link TARGETS (never the text). Matches `](docs/x.md#a)`,
// `](./x.md#a)`, `](x.md#a)` — anchored on `](` so it never fires mid-URL, and
// the target-token charset excludes `:` `/` so absolute http(s) URLs never match.
function rewriteLinks(body) {
  return body.replace(
    /\]\((?:\.\/|docs\/)?([a-z0-9][a-z0-9-]*)\.md(#[^)]*)?\)/gi,
    (_m, name, anchor = '') =>
      PUBLISHED.has(name)
        ? `](./${name}${anchor})`
        : `](https://github.com/valthon/zigbase/blob/main/docs/${name}.md${anchor})`,
  );
}

function frontmatter(fm) {
  // Existing mirrors use unquoted scalars; none of these values contain a YAML
  // metacharacter (no leading-space, no `: ` mid-string). Keep it unquoted to match.
  return `---\ntitle: ${fm.title}\ndescription: ${fm.description}\norder: ${fm.order}\ngroup: ${fm.group}\n---\n`;
}

for (const e of REGISTRY) {
  const raw = readFileSync(join(repoRoot, e.canonical), 'utf8');
  const out =
    frontmatter(e.fm) +
    `\n<!-- GENERATED from ${e.canonical} by site/scripts/gen-docs-mirror.mjs — DO NOT EDIT; edit the canonical file. -->\n\n` +
    rewriteLinks(raw);
  writeFileSync(join(siteDir, 'src/content/docs', e.mirror), out);
  console.log(`gen-docs-mirror: ${e.mirror} <- ${e.canonical}`);
}
```

- [ ] **Step 2: Wire the generator into `site/package.json`**

Replace the `"scripts"` block with:
```json
  "scripts": {
    "gen:docs": "node scripts/gen-docs-mirror.mjs",
    "predev": "node scripts/gen-docs-mirror.mjs",
    "dev": "astro dev",
    "prebuild": "node scripts/gen-docs-mirror.mjs",
    "build": "astro build",
    "preview": "astro preview",
    "check": "astro check"
  },
```

- [ ] **Step 3: gitignore the two generated mirrors — `site/.gitignore`**

Append:
```
# Generated from canonical docs by scripts/gen-docs-mirror.mjs — do not commit.
src/content/docs/changelog.md
src/content/docs/known-limitations.md
```

- [ ] **Step 4: Remove the now-generated committed mirrors**

```bash
git rm site/src/content/docs/changelog.md site/src/content/docs/known-limitations.md
```

- [ ] **Step 5: Generate + build the site to verify the mechanism**

Run: `cd site && node scripts/gen-docs-mirror.mjs` — expect two `gen-docs-mirror:` lines; the two mirror files reappear (untracked, gitignored).
Run: `cd site && npm run build 2>&1 | tail -3` — expect `Complete!` (28 pages).
Run (from repo root): `git status --porcelain site/src/content/docs/` — expect **empty** (the regenerated mirrors are gitignored; no other doc mirror changed).

- [ ] **Step 6: Reconcile `KNOWN_LIMITATIONS.md` (canonical = source of truth)**

The canonical is already the fresher version (has the `v0.11.0` line, already dropped the admin-editor clause). Confirm and finish it so the generated page is correct:
- Verify it still opens with `ZigBase v0.11.0 is an early release.` (correct as of the 0.11.0 release).
- Verify its cross-doc links use the `docs/<name>.md#anchor` form (the rewriter handles that). Fix any bare `[text](../foo)` or site-style `./foo` links to the `docs/<name>.md` form so they rewrite correctly. (Grep: `grep -nE '\]\(' KNOWN_LIMITATIONS.md`.)
- The stale mirror had an extra `ZIGBASE_FAKE_SEED` bullet; the canonical intentionally folds dev-seam gating into the `ZIGBASE_FAKE_NOW` + "impossible on a production build" bullets — do NOT re-add a separate FAKE_SEED bullet (canonical wins). No content change needed unless a link fix is required.
- After any edit, re-run step 5's generate+build and open `site/dist/docs/known-limitations/index.html` (or grep the built HTML) to confirm: no "plain textarea"/"WYSIWYG" text, the `v0.11.0` line present, and `docs/*.md` links rendered as `/docs/<name>` routes.

- [ ] **Step 7: Simplify `scripts/assemble-changelog.sh` (write only CHANGELOG.md)**

- Remove the `MIRROR="site/src/content/docs/changelog.md"` line (33) and the `insert_into "$MIRROR"` call (150).
- Update the header comment (lines ~9-12) to say it assembles into `CHANGELOG.md` only; the site mirror is generated from it by `site/scripts/gen-docs-mirror.mjs`.
- Verify: `scripts/assemble-changelog.sh --dry-run` still prints an assembled section without error (no fragments currently exist post-release → it will report "no fragments"; that's the expected `::error::` exit for `--dry-run` with an empty `changelog.d/` — confirm behavior is unchanged from before this edit by checking it errors identically, i.e. the edit didn't break parsing). If `changelog.d/` is empty, instead assert the script's `MIRROR` references are gone: `! grep -q 'site/src/content/docs/changelog.md' scripts/assemble-changelog.sh`.

- [ ] **Step 8: Update the process docs (drop the mirror-sync rule)**

- `CLAUDE.md`:
  - Line ~70 ("Keep published docs and examples in sync…"): reword — the site docs under `site/src/content/docs/` for the single-sourced files are **generated** from the canonical by `site/scripts/gen-docs-mirror.mjs`; edit the canonical, the mirror follows. Keep the "build the site when docs change" note and the `docs/superpowers/` archive caveat. (Note this is PR 1 of 2; the non-migrated `docs/*.md` mirrors are still hand-synced until PR 2 — say so.)
  - Line ~72 ("Never edit `CHANGELOG.md` (or its mirror …)"): drop the "or its mirror `site/src/content/docs/changelog.md`" clause — there is no hand-maintained mirror now; keep the `changelog.d/` fragment workflow unchanged.
  - Line ~81 (assemble-changelog inserts into "both CHANGELOG.md and site/…/changelog.md"): change to "inserts into `CHANGELOG.md`; the site mirror is regenerated from it at build time."
- `.github/pull_request_template.md`:
  - Line 17 (the `site/src/content/docs/` mirror checklist): reword to "the *published* docs mirror `docs/*.md` (still hand-synced except the generated `changelog.md`/`known-limitations.md` — see `site/scripts/gen-docs-mirror.mjs`)." Keep it accurate for the PR-1 interim state.

- [ ] **Step 9: Final verification + commit**

Run: `cd site && npm run build 2>&1 | tail -2` → `Complete!`
Run: `git status --porcelain` → only the intended tracked changes (generator, package.json, .gitignore, removed 2 mirrors, KNOWN_LIMITATIONS.md if edited, assemble-changelog.sh, CLAUDE.md, PR template, spec+plan). No generated mirror appears (gitignored).
Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q` → passes (unaffected).
```bash
git add -A
git commit -m "refactor(docs): single-source changelog + known-limitations from canonical"
```

## Self-Review Notes
- The `.gitignore` entries and `git rm` cover exactly the 2 registry mirrors; the other 17 site docs stay tracked/hand-synced (PR 2 migrates them).
- Link rewriter is anchored on `](` and excludes `:`/`/` from the name token, so absolute URLs and mid-URL `.md` substrings never match; in-page `#` links have no `.md` and are untouched.
- Reconciliation is minimal here (canonical is already correct); the generation itself is what fixes the stale published page.
