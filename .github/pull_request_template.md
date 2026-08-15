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
- [ ] **`site/content/docs/`** — published SuperMD mirrors are **generated** from canonical `docs/*.md` plus `CHANGELOG.md`/`KNOWN_LIMITATIONS.md`; edit the canonical source and regenerate, never hand-edit a mirror. Site-authored onboarding sources live under `site/sources/docs/`.
- [ ] **`examples/{blog,golfsim,plugins}`** — code and READMEs updated if behavior, defaults, fields, APIs, or access rules changed (plus the public-site example pages that describe them).
- [ ] New/changed **CLI flags & env vars** documented in `site/sources/docs/configuration.md`.
- [ ] **Screenshots/assets** under `site/assets/` re-captured if the admin UI changed.

> Historic design archives under `docs/superpowers/` are point-in-time records and are **not** updated.

## Verification

- [ ] `zig build` and `zig build test` pass.
- [ ] `tests/admin/` (the Playwright `browser` suite) passes for any behavior/UI change.
- [ ] `cd site && bash build.sh` and the site validation/browser checks pass (if any docs/site content changed).
