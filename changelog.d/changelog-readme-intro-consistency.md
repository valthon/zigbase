### Internal

- Finished the `changelog.d/README.md` correction started in the previous docs pass: its intro paragraph still said `assemble-changelog.sh` writes the published mirror `site/src/content/docs/changelog.md`, contradicting the "At release" section a few lines below, which correctly states the script does not touch it. The intro now points at that section instead.
- `CLAUDE.md` no longer describes the assembled block as being inserted "below `## [Unreleased]`". There is deliberately no `## [Unreleased]` section in `CHANGELOG.md`, and the assembler anchors on the most recent released-version heading rather than requiring one — the old wording invited a contributor to re-add a section the project removed on purpose.
