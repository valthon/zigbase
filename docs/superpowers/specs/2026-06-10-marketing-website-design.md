# ZigBase marketing website — design spec

**Date:** 2026-06-10
**Status:** Approved (design gate passed; straight-through execution).

## Goal

A GitHub-Pages marketing + documentation website for ZigBase that takes its visual
design cues from ziglang.org and reaches rough feature/content parity with
pocketbase.io and trailbase.io. It covers the standard project surface: a landing
page, quick start, tutorial, API documentation, a configuration reference, and a
page for each example project.

## Decisions (locked)

- **Generator:** Astro. Bespoke, hand-designed landing/marketing pages for full control
  of the ziglang.org aesthetic; Astro **content collections** render the documentation
  and example pages. Near-zero client JS (islands only for nav/theme/tabs/copy).
- **Hosting:** GitHub Actions → GitHub Pages. URL `https://valthon.github.io/zigbase`
  (project page). Astro `site: 'https://valthon.github.io'`, `base: '/zigbase'`.
- **Docs content:** rewritten **web-native** (not transcluded). The site is the canonical
  published documentation. Repo `docs/*.md` stay for in-repo/GitHub reading and get a
  one-line pointer banner to the live site. (Drift between the two is the accepted cost
  of the "polish" choice.)
- **Positioning:** **backend-first**, the embeddable-Zig-framework angle as the prominent
  differentiator immediately below. Hero ≈ "Open-source backend in a single binary —
  and an embeddable Zig framework."
- **Toolchain:** Node (pinned via `mise`, alongside python/zig).

## Out of scope

- **Live demo instance** (TrailBase has one) — impossible on static Pages; replaced by
  admin-UI **screenshots**. Noted as future.
- No blog, no i18n, no full-text search (Pagefind can be added later for search parity).
- No unverified benchmark claims (we have no benchmark harness; "Why ZigBase" sells
  architecture, not numbers).

## Information architecture

Global nav (sticky): `⚡ ZigBase` wordmark · **Docs** · **Examples** · **Download** ·
`v0.1.0` badge · GitHub icon · dark-mode toggle.

### 1. Landing (`/`)
Bespoke sections, top to bottom:
1. **Hero** — bold headline w/ amber-emphasized keywords, subhead, primary CTAs
   (*Get started* → /docs/quick-start, *GitHub*), a one-line install snippet, the
   `⚡ Z` logo mark, a `v0.1.0 · Apache-2.0` badge.
2. **Feature callouts** — a row of 6 cards: Collections & schema · Auth + OAuth2 ·
   Realtime (WebSocket) · File storage · **Single static binary** · **Embeddable Zig
   framework**. Each with an inline SVG icon and one line of copy.
3. **Tabbed code sample** — two tabs: *Use the REST API* (curl + JS) and *Extend it in
   Zig* (a `beforeCreate` slug hook from examples/blog). Framework tab is the wedge and
   is visually first-class.
4. **"Ready out of the box"** — expandable feature modules (PocketBase-style): schema +
   REST, auth + OAuth2, realtime, files, admin UI, framework hooks/routes/jobs. Each
   links to the relevant docs page.
5. **Quick start** — OS/method tabs: *Download a binary* (per target), *Build from
   source* (`mise install` → `zig build`), *Use as a library* (`zig fetch --save`).
6. **Admin UI showcase** — one or two screenshots captured via Playwright against a
   locally-run server, in a framed/browser-chrome container.
7. **"Why ZigBase"** — architecture differentiators: one static binary, SQLite-backed,
   comptime framework, tiny footprint (comptime pool levers). No numeric benchmarks.
8. **Footer** — columns: Docs (links), Project (GitHub, releases, changelog, license),
   small print.

### 2. Docs (`/docs/*`)
Astro content collection with a two-column docs layout (left sidebar nav, right content,
optional on-page TOC). Pages (web-native rewrites of existing markdown):
`overview`, `quick-start`, `tutorial`, `api` (REST + WebSocket), `fields`, `recipes`,
`framework`, `configuration` (env-var table from README), `known-limitations`,
`changelog`. Sidebar groups: **Getting started** (overview, quick-start, tutorial),
**Guides** (recipes, framework, configuration), **Reference** (api, fields,
known-limitations, changelog).

### 3. Examples (`/examples` + page each)
- `/examples` — gallery framing the three examples as a ladder
  (packaging proof → realistic app → advanced framework surface).
- `/examples/blog`, `/examples/golfsim`, `/examples/plugins` — each rewritten from the
  example README with what-it-proves, key code, and how-to-run, plus a GitHub source link.

### 4. Download (`/download`)
Release table for all 4 targets (`x86_64`/`aarch64` × `linux-musl`/`macos`) linking the
v0.1.0 release assets + `SHA256SUMS`; build-from-source; and library use (`zig fetch`).
Links are derived from the published GitHub release.

## Visual system (ziglang.org cues)

- **Palette (light):** bg `#ffffff` / surface `#f9f9f9` / border `#e6e6e6`; text `#1a1a1a`
  / muted `#555`; **accent amber `#f7a41d`**, accent-hover `#e08e00`, link `#c47d00` on
  light for contrast.
- **Palette (dark):** bg `#0f1011` / surface `#17191c` / border `#2a2d31`; text `#e8e8e8`
  / muted `#a0a4ab`; accent amber `#f7a41d` retained.
- **Type:** system sans stack for UI/body; monospace stack (`'JetBrains Mono','Fira
  Code',ui-monospace,SFMono-Regular,Menlo,monospace`) for code. Large bold hero
  (clamp-scaled). Amber bold emphasis on hero keywords (ziglang.org pattern).
- **Logo:** lightweight inline SVG — a lightning bolt forming/adjacent to a "Z", amber.
  No existing logo; create a minimal one (`site/src/assets/logo.svg` + favicon).
- **Components:** `FeatureCard`, `CodeTabs` (island), `Callout`, `CopyButton` (island),
  `ThemeToggle` (island), `Nav`, `Footer`, `Hero`, `Browser` (screenshot frame).
- **Highlighting:** Astro built-in Shiki; languages zig, bash, json, js, http. A light +
  dark Shiki theme pair following the site theme.
- **Quality bar:** responsive (mobile nav), accessible (landmarks, focus states, color
  contrast AA, prefers-reduced-motion), fast (Lighthouse-ish: minimal JS, no layout
  shift), all internal links resolve under the `/zigbase` base.

## Build & deploy

- Project root: **`site/`**. `package.json` (astro, sharp for images), `astro.config.mjs`
  (`site`, `base`, Shiki config), `tsconfig.json`, content collection config.
- **`.github/workflows/pages.yml`:** trigger on push to `main` under `site/**` (and
  manual `workflow_dispatch`); `actions/checkout` → `actions/setup-node` (Node 24,
  `npm ci`) → `npm run build` (in `site/`) → `actions/upload-pages-artifact` (path
  `site/dist`) → `actions/deploy-pages`. Concurrency-guarded; `permissions: pages: write,
  id-token: write`.
- **One manual repo setting:** Settings → Pages → Source = "GitHub Actions" (documented
  in the site README; cannot be set from code).
- `.gitignore`: add `site/node_modules`, `site/dist`, `site/.astro`.
- `mise.toml`: pin `node = "24"`.

## Acceptance criteria

- `cd site && npm ci && npm run build` succeeds with no broken internal links.
- Landing page renders all 8 sections; dark/light toggle works and persists.
- Docs sidebar lists all pages; every page renders with working code highlighting and
  copy buttons; cross-links resolve under `/zigbase`.
- `/examples` lists 3 examples; each example page renders.
- `/download` lists all 4 release binaries + checksums with correct asset URLs.
- Pages workflow file is valid and, on push, would build+deploy (verified by a
  successful local build + workflow lint).
- Visual parity sanity: side-by-side, the landing page is recognizably in the
  ziglang.org family (light/amber, monospace code, feature cards) and covers the
  section types pocketbase.io/trailbase.io present.
- Repo `docs/*.md` carry a one-line pointer to the live site.

## Risks / notes

- **Base path correctness** is the most common Pages-project-page bug — every asset/link
  must respect `base: '/zigbase'` (use Astro's `<a href>` with `import.meta.env.BASE_URL`
  or relative links / the `astro:assets` + `getRelativeLocaleUrl`-style helpers). QA task
  explicitly checks this.
- **Screenshots** require running the server + a superuser + Playwright; if that proves
  flaky in this environment, fall back to a styled static mock of the admin UI rather
  than blocking the build.
- Docs drift: accepted; mitigated by the pointer banners.
