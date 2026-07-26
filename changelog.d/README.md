# Changelog fragments

Every recorded change adds a small **fragment** file in this directory instead of editing
`CHANGELOG.md`. At release time `scripts/assemble-changelog.sh` collects the fragments into
a new version section in `CHANGELOG.md` and deletes them. (The published mirror
`site/src/content/docs/changelog.md` is a generated artifact — see [At release](#at-release).)

This exists so parallel PRs never touch the same lines of `CHANGELOG.md` and never
conflict on it. Two PRs each adding their own fragment file merge cleanly; two PRs each
appending to the shared `## [Unreleased]` block do not.

## Adding a fragment

Create one file per PR/change:

```
changelog.d/<slug>.md
```

`<slug>` is a short kebab-case descriptor, unique enough not to collide with other open
PRs (e.g. `index-collation`, `command-mailer`, the branch/feature name). There is **no**
type suffix in the filename.

## Fragment content

The body is one or more `### <Section>` headings, each followed by Markdown bullet lines.
A single fragment **may populate multiple sections** — put each bullet under the section it
belongs to. The assembler aggregates the bullets per section across all fragments.

```markdown
### Breaking
- `data.create` on an auth collection now provisions credentials.

### Features
- Added `Data.createAuthRecord` for passwordless provisioning.
```

### Recognized sections

Use these exact display headings. The assembler emits them in this order and omits any
that are empty; any other `### <name>` fails the build.

| # | section           | use for                                                     |
| - | ----------------- | ----------------------------------------------------------- |
| 1 | `### Breaking`    | breaking changes (call out the migration in the bullet)     |
| 2 | `### Features`    | new features                                                |
| 3 | `### Fixes`       | bug fixes                                                   |
| 4 | `### Changed`     | changes to existing behavior that aren't breaking           |
| 5 | `### Performance` | performance improvements                                    |
| 6 | `### Deprecated`  | soon-to-be-removed features                                 |
| 7 | `### Removed`     | removed features                                            |
| 8 | `### Security`    | vulnerability fixes / security-relevant behavior changes    |
| 9 | `### Internal`    | **internal-only** — contributor-facing changes with no consumer impact (build/CI, test infra, refactors, dev tooling, the release/changelog process itself) |

Sections 1–8 are **consumer-facing**; `Internal` (rendered last, de-emphasized) is for
contributor-facing changes worth recording but invisible to users.

## What belongs in the changelog, and where?

The changelog is **consumer-facing** — it records what a ZigBase *user* experiences. So:

- The consumer sections (**Breaking, Features, Fixes, Changed, Performance, Deprecated,
  Removed, Security**) are for **user-visible** changes only — anything that changes the
  API, the CLI, behavior, performance, security posture, or what's supported.
- **Internal** is for contributor-facing changes worth recording but with **no consumer
  impact**: build/CI, test infrastructure, refactors, dev tooling, and the
  release/changelog process itself.

Decision rule:

> **Would a ZigBase user notice?** → a consumer section.
> **Only contributors notice?** → `Internal`.
> **Nobody needs it recorded?** → no fragment at all (git history is enough).

## At release

The release PR runs `scripts/assemble-changelog.sh [<version> [<date>]]` (version defaults to
`build.zig.zon`'s), which:

1. reads every `changelog.d/*.md` fragment and splits each on its `### <Section>` headings,
2. aggregates the bullets per section across all fragments, in the canonical order above,
   under a new `## [<version>] - <date>` block,
3. inserts that block into `CHANGELOG.md`, and
4. `git rm`s the consumed fragment files.

It does **not** write `site/src/content/docs/changelog.md` — that mirror is a generated build
artifact, regenerated from `CHANGELOG.md` by `site/scripts/gen-docs-mirror.mjs` on
`npm run dev`/`build`. Never hand-edit it.

The assembled block matters beyond the repo: the `v*` release workflow extracts it with
`scripts/extract-release-notes.sh` and uses it as the GitHub release body, so it is what
consumers read on the release page. Review it for internal consistency before merging.

Do not run the assembler in a feature PR — only add your fragment.
