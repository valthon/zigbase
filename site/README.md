# ZigBase website

The marketing + documentation site for ZigBase, built with [Astro](https://astro.build)
and deployed to GitHub Pages at <https://valthon.github.io/zigbase>.

The site is the **canonical** published documentation. The repo `docs/*.md` files remain
for in-repo/GitHub reading; the pages here are web-native rewrites of that content plus
bespoke landing, examples, and download pages.

## Local development

Requires Node 24 (pinned via `mise` in the repo root, or use any Node 24 on your PATH).

```sh
cd site
npm ci          # install exact dependencies from package-lock.json
npm run dev      # start the dev server (http://localhost:4321/zigbase)
```

Other scripts:

```sh
npm run build    # production build into site/dist/
npm run preview  # serve the built site locally to verify the production output
npm run check    # astro check (type/content/link diagnostics)
```

## Base path

The site is a GitHub **project page**, so it is served under a base path of `/zigbase`.
This is configured in `astro.config.mjs` (`site: 'https://valthon.github.io'`,
`base: '/zigbase'`). All internal links must respect this base — use relative links or
`import.meta.env.BASE_URL`, never a hardcoded leading `/docs/...`.

## Deployment

Deployment is automated by `.github/workflows/pages.yml`: every push to `main` that
touches `site/**` (or the workflow itself) builds the Astro site and publishes
`site/dist/` to GitHub Pages. The workflow can also be run manually via
**workflow_dispatch**.

### One-time manual setup (required)

GitHub Pages must be told to deploy from Actions. This **cannot** be set from code — a
human must do it once in the GitHub UI:

> **Settings → Pages → Build and deployment → Source = "GitHub Actions"**

After that, the workflow handles every subsequent deploy automatically. The live site is
served at <https://valthon.github.io/zigbase>.
