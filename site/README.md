# ZigBase website

The public marketing and documentation site for ZigBase, built with the
published Zigapagos **v0.4.0** release and deployed at
<https://valthon.github.io/zigbase/>.

## Source of truth

- `content/`, `layouts/`, and `assets/` are the Zigapagos site.
- Repository-root `docs/*.md`, `CHANGELOG.md`, and `KNOWN_LIMITATIONS.md` remain
  canonical for reference documentation. `npm run generate` mirrors them into
  SuperMD using `scripts/docs-registry.json`.
- `sources/` contains the site-authored getting-started and example guides.
- The same generation pass writes `llms.txt`, `docs-index.json`, `sitemap.xml`,
  and `robots.txt`, so discovery artifacts cannot drift from the published set.

## Commands

Node 24 is pinned in the repository root. The site has no installed npm
dependencies; `package.json` only provides command aliases. The repository
launcher fetches the exact Zigapagos v0.4.0 package through `npx`.

```sh
cd site
npm run validate       # fast JSON diagnostics, no output tree
npm run build          # release output -> site/zig-out/site
npm run doctor         # built-link and social metadata audit
npm run test:static    # routes, links, metadata, assets, accessibility contracts
npm run test:generated # deterministic docs/discovery generation
npm run test:browser   # real browser smoke through Zigapagos e2e
npm run dev            # generated-content sync + background dev loop
```

The site is a GitHub project page. `zigapagos.ziggy` owns the `zigbase` URL
prefix; internal links should use `$site.page(...)` or `$site.asset(...)`, not
hand-authored root-relative paths.

## Deployment

The Pages workflow runs `build.sh` directly and uploads `site/zig-out/site`.
GitHub Pages must be configured with “GitHub Actions” as its source once at the
repository level.
