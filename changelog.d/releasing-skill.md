### Internal

- Moved the `## Releasing` section out of `CLAUDE.md` into a `releasing` skill (`.claude/skills/releasing/SKILL.md`). The release process — tag-driven CI publishing, the version-bump prerequisites, the required changelog consistency review, and the `assemble-changelog.sh` mechanics — is needed only when cutting a release, but as always-loaded memory it cost roughly 890 tokens of context in every session. The prose moves verbatim; `CLAUDE.md` keeps a pointer, and the non-release `gh pr edit` gotcha moves up into "Conventions that bite" where it applies to any PR.
