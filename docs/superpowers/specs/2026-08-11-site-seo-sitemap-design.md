# Marketing-site SEO: sitemap, robots.txt, GSC verification, structured data

**Date:** 2026-08-11
**Status:** Approved
**Scope:** `site/` only (the Astro marketing site published to GitHub Pages at
`https://valthon.github.io/zigbase`). No server, framework, docs-content, or
example changes.

## Problem

The marketing site gets little Google search traffic. On-page SEO is already
solid (`Base.astro` emits canonical URLs, meta descriptions, and OG/Twitter
cards on every page), but the discoverability plumbing is absent: no
`sitemap.xml`, no `robots.txt`, no structured data, and Google Search Console
(GSC) was never set up. The owner has just started GSC registration and has a
site-verification meta tag ready to insert.

## Decision

Add the discoverability layer in one small PR:

1. **Sitemap** — use the official `@astrojs/sitemap` integration rather than a
   hand-rolled endpoint. It reads the existing `site` + `base` +
   `trailingSlash: 'never'` config, so generated URLs automatically match the
   canonical extensionless form (`.../zigbase/docs/tutorial`), and new pages
   join the sitemap with zero maintenance. A hand-rolled generator was
   rejected: it would re-implement enumeration of the dynamic
   `docs/[...slug]` / `examples/[...slug]` routes and silently rot.
2. **robots.txt** — static `site/public/robots.txt`: allow all crawlers, and
   point at `Sitemap: https://valthon.github.io/zigbase/sitemap-index.xml`.
3. **GSC verification** — add the owner-supplied tag to `Base.astro`'s
   `<head>` so it renders on every page:
   `<meta name="google-site-verification" content="NibV2pc_Q1_s1duZ69GK0SW5gmFT7rfyp5LKttrsG7Y" />`.
   GSC only requires it on the homepage, but emitting it site-wide is harmless
   and survives page restructuring.
4. **Structured data** — one JSON-LD `<script type="application/ld+json">`
   block on the landing page (`site/src/pages/index.astro`) with
   `SoftwareApplication` schema: name, description, `operatingSystem:
   "Linux, macOS"`, `applicationCategory: "DeveloperApplication"`, the repo
   license, `offers` with price `0`, and the GitHub repository URL.

## Changes

| File | Change |
| --- | --- |
| `site/package.json` | add `@astrojs/sitemap` dependency |
| `site/astro.config.mjs` | add `sitemap()` to `integrations` |
| `site/public/robots.txt` | new: allow-all + `Sitemap:` line |
| `site/src/layouts/Base.astro` | add the `google-site-verification` meta tag |
| `site/src/pages/index.astro` | add the `SoftwareApplication` JSON-LD block |
| `changelog.d/<slug>.md` | fragment under `### Internal` (site-only; no consumer impact) |

The integration emits `dist/sitemap-index.xml` + `dist/sitemap-0.xml` at build
time. All pages are statically generated, so there is nothing to exclude;
`public/` assets (`og.png`, `favicon.svg`) are not routes and never appear in
the sitemap.

## Verification

- `cd site && npm run build` succeeds.
- `dist/sitemap-index.xml` and `dist/sitemap-0.xml` exist.
- Every URL in `sitemap-0.xml` starts with `https://valthon.github.io/zigbase`
  and uses the extensionless no-trailing-slash form — i.e. matches the
  `<link rel="canonical">` each built page already carries.
- `dist/robots.txt` is copied through and its `Sitemap:` URL resolves within
  the built output.
- The verification meta tag appears in every built HTML page; the JSON-LD
  block appears on `dist/index.html` and parses as valid JSON.

## Post-merge (owner actions, not in the PR)

- Finish GSC verification (the meta tag makes this a page-refresh).
- Submit `https://valthon.github.io/zigbase/sitemap-index.xml` in GSC.

## Out of scope

- Custom domain (site stays on `valthon.github.io/zigbase`).
- Copy, title, or heading rewrites; internal-linking audit.
- Any change under `docs/` or the generated `site/src/content/docs/` mirror.
