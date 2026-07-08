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
- [ ] **`site/src/content/docs/`** (the *published* docs mirror `docs/*.md` — still hand-synced except the generated `changelog.md`/`known-limitations.md`, see `site/scripts/gen-docs-mirror.mjs`) updated to match: config/env tables in `configuration.md`, serve commands, access-rule semantics, CLI flags, and feature descriptions.
- [ ] **`examples/{blog,golfsim,plugins}`** — code *and* READMEs — updated if behavior, defaults, fields, APIs, or access rules changed (and the `site/src/content/examples/*.mdx` pages that describe them).
- [ ] New/changed **CLI flags & env vars** documented in `site/src/content/docs/configuration.md`.
- [ ] **Screenshots/assets** under `site/src/assets/` re-captured if the admin UI changed.

> Historic design archives under `docs/superpowers/` are point-in-time records and are **not** updated.

## Verification

- [ ] `zig build` and `zig build test` pass.
- [ ] `tests/admin/` (the Playwright `browser` suite) passes for any behavior/UI change.
- [ ] `cd site && npm run build` passes (if any docs/site content changed).
