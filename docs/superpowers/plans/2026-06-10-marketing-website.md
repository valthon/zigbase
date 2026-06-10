# ZigBase Marketing Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an Astro-based GitHub-Pages marketing + docs site for ZigBase, styled after ziglang.org, with rough content parity to pocketbase.io and trailbase.io.

**Architecture:** A single Astro project in `site/`. Bespoke hand-designed marketing pages (landing, download) own the ziglang.org aesthetic; Astro content collections render docs and example pages from web-native markdown. Deployed by a GitHub Actions workflow to `https://valthon.github.io/zigbase` (base `/zigbase`). Near-zero client JS — Astro islands only for theme toggle, code tabs, copy buttons, mobile nav.

**Tech Stack:** Astro 4/5, Shiki highlighting (built-in), Sharp (images), Node 24 via mise, GitHub Pages via Actions. Vanilla CSS with design tokens (no Tailwind) to match ziglang.org's hand-crafted feel.

**Spec:** `docs/superpowers/specs/2026-06-10-marketing-website-design.md`

**Source content to transform:** `README.md`, `docs/{tutorial,api,framework,fields,recipes}.md`, `CHANGELOG.md`, `KNOWN_LIMITATIONS.md`, `examples/{blog,golfsim,plugins}/README.md`. Release assets: `zigbase-0.1.0-{x86_64,aarch64}-{linux-musl,macos}.tar.gz` + `SHA256SUMS` at `https://github.com/valthon/zigbase/releases/download/v0.1.0/<asset>`.

**Conventions for every task:**
- Work in `site/` unless stated. Run Node via mise (`mise exec node@24 -- <cmd>`) or directly (node 24 is on PATH).
- After any page/component change, `npm run build` must still succeed. Astro's build fails on broken internal links if `astro check` is wired; at minimum no 404-y relative paths.
- All internal links MUST respect `base: '/zigbase'`. Use relative links from page location OR `import.meta.env.BASE_URL`. Never hardcode a leading `/docs/...` without the base.
- Commit after each task with a clear message; do not bump the Zig project version.

---

### Task 1: Scaffold the Astro project + design tokens + base layout

**Files:**
- Create: `site/package.json`, `site/astro.config.mjs`, `site/tsconfig.json`, `site/.gitignore`
- Create: `site/src/styles/tokens.css`, `site/src/styles/global.css`
- Create: `site/src/layouts/Base.astro`
- Create: `site/src/pages/index.astro` (temporary placeholder — replaced in Task 3)
- Modify: repo root `.gitignore` (add `site/node_modules`, `site/dist`, `site/.astro`)
- Modify: `mise.toml` (add `node = "24"`)

- [ ] **Step 1: Scaffold + config.** Initialize a minimal Astro project (no starter template — author files directly). `astro.config.mjs` sets `site: 'https://valthon.github.io'`, `base: '/zigbase'`, `trailingSlash: 'ignore'`, and a Shiki config with `themes: { light: 'github-light', dark: 'github-dark' }`. `package.json` deps: `astro`, `sharp`; scripts: `dev`, `build`, `preview`, `check` (`astro check`). Add `@astrojs/check` + `typescript` as devDeps.
- [ ] **Step 2: Design tokens.** `tokens.css` defines CSS custom properties for the light palette on `:root` and the dark palette on `:root[data-theme='dark']` (and an `@media (prefers-color-scheme: dark)` fallback when no explicit theme set). Use the exact hex values from the spec's Visual System. Include type scale, spacing scale, radius, max-width container, monospace + sans font stacks.
- [ ] **Step 3: Global CSS + Base layout.** `global.css`: reset, base typography, link/focus styles (visible focus ring in amber), `.container`, code-block styling that complements Shiki, `prefers-reduced-motion` guard. `Base.astro`: `<html lang="en">` with `<head>` (meta, title/description props, favicon, canonical built from `Astro.site`+`base`, OpenGraph tags), imports the styles, an inline no-flash theme script that reads `localStorage.theme` and sets `data-theme` before paint, and a `<slot/>`.
- [ ] **Step 4: Placeholder index + build.** A trivial `index.astro` using `Base.astro` saying "ZigBase". Run `npm install` then `npm run build`. Expected: `site/dist/` produced, exit 0.
- [ ] **Step 5: Commit.** `chore(site): scaffold Astro project, design tokens, base layout`.

**Acceptance:** `cd site && npm run build` exits 0; `dist/index.html` exists; tokens cover light+dark; root `.gitignore` and `mise.toml` updated.

---

### Task 2: Shared components + logo + nav/footer

**Files:**
- Create: `site/src/assets/logo.svg`, `site/public/favicon.svg`
- Create: `site/src/components/{Nav,Footer,ThemeToggle,CodeTabs,CopyButton,Callout,FeatureCard,Browser,Button}.astro`
- May add tiny client scripts inline in the island components.

- [ ] **Step 1: Logo + favicon.** A minimal inline-friendly SVG: a lightning bolt forming or crossing a "Z", in amber `#f7a41d`, that works on light and dark. Favicon variant in `public/`.
- [ ] **Step 2: Nav + ThemeToggle + mobile menu.** `Nav.astro`: sticky top bar — logo+wordmark (links to `BASE_URL`), links Docs/Examples/Download, `v0.1.0` badge, GitHub icon link (`https://github.com/valthon/zigbase`), `ThemeToggle`. Responsive: collapses to a hamburger on narrow screens (minimal JS island). `ThemeToggle` flips `data-theme` and persists to `localStorage`.
- [ ] **Step 3: Footer.** Columns: Docs (Overview, Quick start, Tutorial, API, Framework), Project (GitHub, Releases, Changelog, License Apache-2.0). Small print: "Built with Astro · ZigBase is not affiliated with the Zig project."
- [ ] **Step 4: Content components.** `FeatureCard` (icon slot + title + body), `Callout` (note/warning variants), `Button` (primary amber / secondary), `Browser` (a frame with fake browser chrome wrapping a slotted `<img>`/content), `CopyButton` (island; copies sibling code), `CodeTabs` (island; labelled tabs switching between slotted code panels, accessible with roving tabindex).
- [ ] **Step 5: Build + smoke render.** Add the components to the placeholder index temporarily to confirm they compile, then revert that. `npm run build` exits 0.
- [ ] **Step 6: Commit.** `feat(site): logo, nav, footer, and shared UI components`.

**Acceptance:** all components compile; nav is responsive; theme toggle persists; `npm run build` exits 0.

---

### Task 3: Landing page

**Files:**
- Modify/replace: `site/src/pages/index.astro`
- May add: `site/src/components/landing/*.astro` for section components.

- [ ] **Step 1: Hero.** Headline leads backend-first with the framework wedge (e.g. "Open-source backend in a single binary — **and** an embeddable Zig framework"), amber-emphasized keywords, subhead summarizing collections/auth/realtime/files/admin/framework, primary CTAs (*Get started* → `docs/quick-start`, *View on GitHub*), a copyable one-line install (`zig fetch --save git+https://github.com/valthon/zigbase` OR the binary download), and the `v0.1.0 · Apache-2.0` badge.
- [ ] **Step 2: Feature callouts.** Six `FeatureCard`s per spec (Collections & schema, Auth + OAuth2, Realtime, File storage, Single static binary, Embeddable Zig framework) with inline SVG icons.
- [ ] **Step 3: Tabbed code sample.** `CodeTabs` with two tabs — *Use the REST API* (a curl create + a JS fetch list) and *Extend it in Zig* (the `slugify` `beforeCreate` hook adapted from `examples/blog/README.md`). Zig tab first/prominent.
- [ ] **Step 4: "Ready out of the box" modules.** Feature modules (schema+REST, auth+OAuth2, realtime, files, admin UI, framework) each linking to the matching docs page.
- [ ] **Step 5: Quick start tabs.** `CodeTabs`: *Download binary* (curl the linux-musl asset + run `serve`), *Build from source* (`mise install` → `zig build` → `superuser create` → `serve`), *Use as a library* (`zig fetch --save` + the `build.zig` import snippet from README). Commands copy-pasteable and accurate to the README.
- [ ] **Step 6: Admin showcase + Why ZigBase + verify.** A `Browser`-framed admin screenshot placeholder (real image wired in Task 6), then the "Why ZigBase" architecture section (single binary, SQLite, comptime framework, small footprint — no benchmark numbers). `npm run build` exits 0; eyeball via `npm run preview`.
- [ ] **Step 7: Commit.** `feat(site): landing page`.

**Acceptance:** all 8 spec sections present; CTAs/links resolve under base; code snippets accurate to README/examples; build exits 0.

---

### Task 4: Docs content collection + layout + pages

**Files:**
- Create: `site/src/content.config.ts` (or `src/content/config.ts`) defining a `docs` collection.
- Create: `site/src/layouts/DocsLayout.astro` (sidebar + content + TOC).
- Create: `site/src/pages/docs/[...slug].astro` (renders the collection) and `site/src/pages/docs/index.astro` (redirects/links to overview).
- Create: `site/src/content/docs/{overview,quick-start,tutorial,api,fields,recipes,framework,configuration,known-limitations,changelog}.md` (or `.mdx`).
- Create: `site/src/config/sidebar.ts` (nav structure).

- [ ] **Step 1: Collection + sidebar + layout.** Define the `docs` collection schema (`title`, `description`, `order`, `group`). `sidebar.ts` lists the three groups (Getting started / Guides / Reference) and page order. `DocsLayout.astro`: left sidebar from `sidebar.ts` (active-page highlight), main content with prose styles, right-hand auto-TOC from headings. Mobile: collapsible sidebar.
- [ ] **Step 2: Getting-started pages.** Write `overview.md` (what ZigBase is, when to use it, backend-first + framework — distilled from README), `quick-start.md` (the README Quickstart, web-native: download/build, create superuser, serve, hit /api/health, open admin), `tutorial.md` (web-native rewrite of `docs/tutorial.md`, the golfsim end-to-end). Keep code accurate.
- [ ] **Step 3: Guides pages.** `recipes.md` (from `docs/recipes.md`), `framework.md` (from `docs/framework.md` — hooks/routes/jobs/comptime schema/plugins/pools), `configuration.md` (the full env-var table from README + flags + precedence note).
- [ ] **Step 4: Reference pages.** `api.md` (from `docs/api.md` — REST + WebSocket), `fields.md` (from `docs/fields.md`), `known-limitations.md` (from `KNOWN_LIMITATIONS.md`), `changelog.md` (from `CHANGELOG.md`).
- [ ] **Step 5: Build + link check.** `npm run build` (and `npm run check` if wired). Verify sidebar lists all pages, internal cross-links resolve under base, code highlights. Fix any broken links.
- [ ] **Step 6: Commit.** `feat(site): documentation section (web-native rewrites)`.

**Acceptance:** all 10 docs pages render with sidebar+TOC; highlighting + copy work; no broken internal links; build exits 0.

---

### Task 5: Examples gallery + per-example pages + Download page

**Files:**
- Create: `site/src/content/examples/{blog,golfsim,plugins}.md` + an `examples` collection in content config.
- Create: `site/src/pages/examples/index.astro`, `site/src/pages/examples/[...slug].astro`.
- Create: `site/src/pages/download.astro`.

- [ ] **Step 1: Examples collection + gallery.** Define an `examples` collection (`title`, `summary`, `rung` label, `repoPath`). `examples/index.astro` renders the three as a "ladder" (packaging proof → realistic app → advanced framework) with cards linking to each detail page and to GitHub source.
- [ ] **Step 2: Per-example pages.** Rewrite each `examples/*/README.md` into a content page: what it proves, key code excerpt, how to run (`zig build` in the example dir), and a "View source on GitHub" link (`https://github.com/valthon/zigbase/tree/main/examples/<name>`). `[...slug].astro` renders them.
- [ ] **Step 3: Download page.** Table of all 4 release binaries with direct asset URLs (`.../releases/download/v0.1.0/zigbase-0.1.0-<target>.tar.gz`), the `SHA256SUMS` link, the GitHub release link, a build-from-source block, and a "use as a library" (`zig fetch --save`) block. Note: prebuilt macOS binaries are unsigned (Gatekeeper note).
- [ ] **Step 4: Build + verify.** `npm run build` exits 0; `/examples` and each example + `/download` render; asset URLs correct.
- [ ] **Step 5: Commit.** `feat(site): examples gallery, example pages, and download page`.

**Acceptance:** examples gallery + 3 pages render; download page lists 4 binaries + checksums with correct URLs; build exits 0.

---

### Task 6: Admin UI screenshots

**Files:**
- Create: `site/src/assets/screenshots/*.png` (committed) — or a styled static mock fallback.
- Create: `scripts/screenshots.sh` (or `.mjs`) documenting how shots were produced.
- Modify: landing page + admin showcase to use the real image(s) via `astro:assets`.

- [ ] **Step 1: Produce screenshots.** Build the server (`zig build`), create a superuser in a temp data-dir, `serve` on a free port, then use Playwright (via mise python or node) to capture the admin login + a collections/records view at a desktop viewport (light theme). Save PNGs into `site/src/assets/screenshots/`. If running the server or Playwright is too flaky here, build a clean static HTML/CSS **mock** of the admin shell and screenshot that instead — record which path was taken in the script header.
- [ ] **Step 2: Wire images.** Replace the `Browser`-framed placeholders on the landing page (and add to the docs overview if useful) with the real `Image` component (`astro:assets`), with width/height to avoid layout shift and descriptive alt text.
- [ ] **Step 3: Build + verify.** `npm run build` exits 0; images optimized into `dist/`.
- [ ] **Step 4: Commit.** `feat(site): admin UI screenshots in showcase`.

**Acceptance:** at least one real admin screenshot (or a clearly-acceptable mock) framed on the landing page; build exits 0; no large layout shift.

---

### Task 7: GitHub Actions Pages deploy + repo docs pointers + final QA

**Files:**
- Create: `.github/workflows/pages.yml`
- Create: `site/README.md` (how to dev/build the site + the one manual Pages setting)
- Modify: repo `docs/*.md` (add a one-line pointer banner to the live site)
- Modify: repo root `README.md` (add a "Website" link near the top)

- [ ] **Step 1: Workflow.** `pages.yml`: triggers `push` to `main` paths `site/**` + `workflow_dispatch`; `permissions: contents: read, pages: write, id-token: write`; `concurrency: group: pages, cancel-in-progress: false`; build job (`actions/checkout`, `actions/setup-node@v4` node 24 with `cache: npm` + `cache-dependency-path: site/package-lock.json`, `npm ci` + `npm run build` in `site/`, `actions/configure-pages`, `actions/upload-pages-artifact` path `site/dist`); deploy job (`actions/deploy-pages`, environment `github-pages`). Lint the YAML.
- [ ] **Step 2: Site README + repo pointers.** `site/README.md` documents local dev (`npm ci && npm run dev`), build, and the **one manual step**: Settings → Pages → Source = "GitHub Actions". Add a one-line "📖 Docs are also published at https://valthon.github.io/zigbase" banner to the top of each repo `docs/*.md`, and a Website badge/link in repo `README.md`.
- [ ] **Step 3: Final QA pass.** From `site/`: `npm ci && npm run build` clean. Crawl `dist/` for broken internal links and missing assets (grep for `href`/`src` that don't resolve, and that the `/zigbase` base prefix is present on absolute internal links). Check: dark/light toggle, mobile nav, all nav targets, every docs sidebar entry, examples, download URLs. Fix issues. Confirm `git status` only has intended files (no `node_modules`/`dist` tracked).
- [ ] **Step 4: Commit.** `ci(site): GitHub Pages deploy workflow + repo docs pointers`.

**Acceptance:** workflow YAML valid and complete; `npm ci && npm run build` clean from scratch; no broken internal links / base-path bugs; repo docs point to the site; `node_modules`/`dist` untracked.

---

## Self-review notes

- **Spec coverage:** quick start (landing §5 + docs/quick-start), tutorial (docs/tutorial), API docs (docs/api + docs/fields), page per example (Task 5), ziglang.org design (Tasks 1–3), pocketbase/trailbase parity (landing sections, download tabs, admin showcase) — all mapped.
- **Base-path correctness** is the top risk; Task 1 sets it, Task 7 QA verifies it.
- **No live demo** is intentional (static host) — screenshots substitute (Task 6).
- **Type/name consistency:** component names (`CodeTabs`, `FeatureCard`, `Browser`, `Callout`, `ThemeToggle`, `CopyButton`, `Button`) are used identically across Tasks 2–6; the `docs` and `examples` collections are defined in one content config (Tasks 4–5).
