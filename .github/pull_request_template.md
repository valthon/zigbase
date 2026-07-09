<!--
Thanks for contributing to ZigBase! Keep this PR's docs and examples in sync —
stale published docs ship wrong (sometimes insecure) guidance to users.
-->

## Summary

<!-- What does this PR change, and why? -->

## Documentation & examples sync (required)

Published docs and the examples must stay current with every change. Check each item
that applies, or strike it through / mark `N/A`:

- [ ] **`README.md`** and other top-level docs (`CHANGELOG.md`, `KNOWN_LIMITATIONS.md`) reflect this change.
- [ ] **`docs/*.md`** (source-of-truth docs) updated.
- [ ] **`site/src/content/docs/`** — the published mirrors are **generated** from the canonical `docs/*.md` (plus `CHANGELOG.md`/`KNOWN_LIMITATIONS.md`) by `site/scripts/gen-docs-mirror.mjs`, so editing the canonical is enough — the mirror regenerates on `npm run build`; never hand-edit a mirror. Only `configuration.md`, `overview.md`, and the `.mdx` pages are site-authored (no `docs/` canonical) — edit those directly.
- [ ] **`examples/{blog,golfsim,plugins}`** — code *and* READMEs — updated if behavior, defaults, fields, APIs, or access rules changed (and the `site/src/content/examples/*.mdx` pages that describe them).
- [ ] New/changed **CLI flags & env vars** documented in `site/src/content/docs/configuration.md`.
- [ ] **Screenshots/assets** under `site/src/assets/` re-captured if the admin UI changed.

> Historic design archives under `docs/superpowers/` are point-in-time records and are **not** updated.

## Verification

- [ ] `zig build` and `zig build test` pass.
- [ ] `tests/admin/` (the Playwright `browser` suite) passes for any behavior/UI change.
- [ ] `cd site && npm run build` passes (if any docs/site content changed).
