# Single-Source Docs (kill the docs ↔ site-mirror drift) — Design

**Date:** 2026-07-08
**Status:** Approved (direction), pending spec review
**Branch:** `refactor/docs-single-source`

## Problem

Every published doc exists twice: a canonical file (`docs/X.md`, or `CHANGELOG.md`
/ `KNOWN_LIMITATIONS.md` at the repo root) and a hand-maintained site mirror
(`site/src/content/docs/X.md`) that adds Astro frontmatter and uses site-relative
links. The two must be kept identical by discipline, and they **drift**:

- `site/.../known-limitations.md` still lists the admin "plain textarea for
  editor/json fields (no WYSIWYG)" limitation that was **removed** from the
  canonical in #258 — the published page shows a limitation that no longer exists.
- It also dropped the version line ("v0.11.0" → nothing), has an extra
  `ZIGBASE_FAKE_SEED` bullet the canonical lacks, and diverges in wording/wrapping.
- The changelog and known-limitations mirrors carry GitHub-style links
  (`docs/framework.md#anchor`) that are **broken on the Astro site** (wrong base).

Root cause: two sources of truth for one document.

## Goal

Make the canonical file the **single source of truth**; the site mirror becomes a
**generated build artifact** (gitignored), regenerated from the canonical on every
site build/dev-start with frontmatter injected and links rewritten. Editing a doc
means editing one file; the sync chore and the whole drift class disappear.

## Scope (registry-driven, not a blanket glob)

The `docs/` ↔ site mapping is **not** 1:1, so the generator is driven by an explicit
registry, which doubles as the "what is published" allowlist:

- **Single-sourced (generated):** the ~15 `docs/X.md` ↔ mirror pairs (`abilities`,
  `analytics`, `api`, `dart-sdk`, `docker`, `email`, `fields`, `framework`,
  `jobs-and-webhooks`, `oauth`, `realtime`, `recipes`, `search`, `tenancy`, …) **plus**
  the 2 root-canonical files: `CHANGELOG.md` → `changelog.md`, `KNOWN_LIMITATIONS.md`
  → `known-limitations.md`.
- **NOT touched — genuinely site-only** (no `docs/` source, authored in the site):
  `configuration.md`, `overview.md`. Left out of the registry, hand-authored as today.
- **NOT touched — intentionally unpublished** (`docs/` exists but no mirror):
  `dx-assessment.md`, `ideas.md`, `security-audit.md`, `tutorial.md`. Not in the registry.

The registry is a table of `{ canonicalPath, mirrorPath, frontmatter }`. The
frontmatter (`title`/`description`/`order`/`group`) is captured verbatim from each
mirror's CURRENT frontmatter (which is correct) before the mirror is deleted.

## Design

### 1. Generator — `site/scripts/gen-docs-mirror.mjs`

A dependency-free Node ESM script. For each registry entry:
1. Read the canonical file (`../<canonicalPath>` relative to `site/`).
2. Prepend the entry's frontmatter block (`---\ntitle: …\n---\n`).
3. **Rewrite links** (below).
4. Write to `site/src/content/docs/<mirrorPath>`.

Emit a header comment into each generated file:
`<!-- GENERATED from <canonicalPath> by scripts/gen-docs-mirror.mjs — DO NOT EDIT. -->`

Wired in `site/package.json`:
```json
"scripts": {
  "gen:docs": "node scripts/gen-docs-mirror.mjs",
  "predev": "node scripts/gen-docs-mirror.mjs",
  "prebuild": "node scripts/gen-docs-mirror.mjs",
  ...
}
```
So `npm run dev` and `npm run build` (which CI + the release use) regenerate first.
Runnable standalone via `npm run gen:docs`. (Astro-integration alternative — hooks
`astro:config:setup` so even a bare `astro build` regenerates — is more robust but
more Astro-version-coupled; the prebuild script is chosen for simplicity since CI and
the release always go through `npm run build`. Noted for a later upgrade if needed.)

### 2. Link rewrite (the transform that makes one source work in both renderers)

Canonical files use GitHub-relative links; the site needs Astro doc-route links.
Rewrite only the URL, never the link text:

- `](docs/<name>.md#<anchor>)` → `](./<name>#<anchor>)`
- `](docs/<name>.md)` → `](./<name>)`
- `](./<name>.md#<anchor>)` and `](<name>.md#<anchor>)` (root-file cross-refs like
  the changelog's `[framework.md](docs/framework.md#…)`) → normalized to `](./<name>#<anchor>)`
- Leave untouched: absolute `http(s)://…`, in-page `](#anchor)`, and links whose
  target has no `docs/`-page counterpart in the registry (log a warning so a typo
  or a link to an unpublished doc — e.g. `security-audit.md` — is visible, not silently
  broken).

A link whose `<name>` is NOT a published mirror (e.g. `security-audit.md`,
`tutorial.md`) is rewritten to the canonical GitHub blob URL
(`https://github.com/valthon/zigbase/blob/main/docs/<name>.md`) so the site link
still resolves instead of 404-ing into a non-existent doc route.

### 3. Remove the committed mirrors

`git rm` the 17 generated mirror files; add to `site/.gitignore`:
```
# Generated from canonical docs by scripts/gen-docs-mirror.mjs
src/content/docs/<each generated mirror>
```
(Enumerate exactly the registry's mirror paths, so the 2 site-only pages stay tracked.)
CI builds the site, so the mirrors regenerate there; a fresh checkout has them after
the first `npm run build`/`dev`.

### 4. Reconciliation (one-time, the careful part)

For each registry pair, before deleting the mirror, verify the canonical is the
correct source of truth — the generated output must not LOSE content the site mirror
had. Concretely:
- Diff canonical-body vs mirror-body (frontmatter + link-syntax excluded).
- If identical (the common case — most were hand-synced): nothing to do.
- If the mirror has content the canonical lacks that is genuinely wanted (e.g.
  known-limitations' `ZIGBASE_FAKE_SEED` bullet, or newer wording): fold it into the
  **canonical**, then generate. If the mirror is simply STALE (e.g. the removed admin
  clause): the canonical already wins — generating fixes it.
- **known-limitations** specifically: make the canonical authoritative (restore the
  version line, keep the admin clause removed, reconcile the FAKE_SEED bullet), fix its
  links to the rewritable form.

### 5. Simplify the changelog assembler + process docs

- `scripts/assemble-changelog.sh`: drop the dual-insert into
  `site/src/content/docs/changelog.md`; write only `CHANGELOG.md`. The mirror is now
  generated. (Its `MIRROR=` handling and second-file insertion are removed.)
- `CLAUDE.md` + `.github/pull_request_template.md`: remove the "sync the `site/`
  mirror" instruction for docs/changelog; replace with "edit the canonical `docs/*.md`
  / `CHANGELOG.md` / `KNOWN_LIMITATIONS.md`; the site mirror is generated."

## Staged delivery (two PRs, same end state)

The mechanism is identical for all pages, but the per-pair reconciliation is where the
risk (losing site content) lives, so land it in two reviewable PRs:

- **PR 1 (this spec's first plan):** the generator + link-rewrite + `.gitignore` + the
  assembler/process-doc simplification, applied to **`CHANGELOG.md` + `KNOWN_LIMITATIONS.md`
  only** (the two drift-proven files, incl. the known-limitations reconciliation). The
  other mirrors stay committed + hand-synced for now (registry has 2 entries).
- **PR 2 (follow-up plan):** extend the registry to the remaining ~15 pairs, reconciling
  each, and `git rm` those mirrors.

End state after PR 2: every published doc has one source; the mirror is a build artifact.

## Testing / verification

- `cd site && npm run build` regenerates and builds green (28 pages).
- `git status` clean after a build (generated mirrors are gitignored).
- The regenerated `known-limitations.md` no longer contains the admin-textarea clause
  and carries the v0.11.0 line; its `docs/*.md` links resolve to `./…` routes (spot-check
  a built page under `site/dist/docs/known-limitations/`).
- `tests/admin/test_docs_parity.py` still passes (it checks README/help env tables, not
  the mirror; unaffected).
- `scripts/assemble-changelog.sh --dry-run` still parses fragments (its mirror-write is
  gone; a future real release writes only `CHANGELOG.md`, and the mirror regenerates).

## File map (PR 1)

| File | Change |
|------|--------|
| `site/scripts/gen-docs-mirror.mjs` | **Create** — registry (2 entries: CHANGELOG, KNOWN_LIMITATIONS) + frontmatter + link-rewrite + write. |
| `site/package.json` | `predev`/`prebuild`/`gen:docs` scripts. |
| `site/.gitignore` | ignore the 2 generated mirrors. |
| `site/src/content/docs/changelog.md`, `known-limitations.md` | **`git rm`** (now generated). |
| `KNOWN_LIMITATIONS.md` | reconcile to source-of-truth; fix links to the rewritable form. |
| `scripts/assemble-changelog.sh` | write only `CHANGELOG.md`. |
| `CLAUDE.md`, `.github/pull_request_template.md` | drop the changelog/docs mirror-sync rule. |

## Out of scope

- Creating canonicals for the site-only pages (`configuration.md`, `overview.md`) —
  they have no `docs/` source and are left hand-authored.
- Publishing the intentionally-unpublished `docs/` files.
- Any change to doc CONTENT beyond the one-time known-limitations reconciliation.
