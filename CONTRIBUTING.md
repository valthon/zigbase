# Contributing to ZigBase

Thanks for your interest in ZigBase. It is an early-stage project with a small team, and
well-scoped contributions — a bug report with a real repro, a docs fix, a focused PR — are
genuinely useful.

By participating you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

**Two things never belong in a public issue**, and they go to different places:

- **Security vulnerabilities** → GitHub's private advisory form, per [SECURITY.md](SECURITY.md).
- **Conduct concerns** → the enforcement contact in the
  [Code of Conduct](CODE_OF_CONDUCT.md#enforcement). The security advisory form is for
  security reports only.

## Table of contents

- [Ways to contribute](#ways-to-contribute)
- [AI-assisted contributions](#ai-assisted-contributions)
- [Development setup](#development-setup)
- [Building and running](#building-and-running)
- [Tests — there are two suites](#tests--there-are-two-suites)
- [The quality bar](#the-quality-bar)
- [Changelog fragments](#changelog-fragments)
- [Keeping docs and examples in sync](#keeping-docs-and-examples-in-sync)
- [Opening a pull request](#opening-a-pull-request)
- [Where things live](#where-things-live)
- [License](#license)

## Ways to contribute

- **Report a bug.** Use the [bug report form](https://github.com/valthon/zigbase/issues/new?template=bug_report.yml).
  A minimal reproduction — a `curl` sequence, a small `App(.{...})` config, or a failing test — is
  worth more than a paragraph of description.
- **Improve the docs.** The [docs issue form](https://github.com/valthon/zigbase/issues/new?template=documentation.yml)
  covers anything wrong, missing, or confusing. Docs PRs are welcome directly; see
  [Keeping docs and examples in sync](#keeping-docs-and-examples-in-sync) for which file to edit.
- **Propose a feature.** Use the [feature request form](https://github.com/valthon/zigbase/issues/new?template=feature_request.yml).
  For anything non-trivial, please open an issue and get agreement on the approach **before**
  writing the code — ZigBase is opinionated about its API surface, and an unsolicited large PR is
  likely to need substantial rework.
- **Pick up known work.** [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) is an honest list of current
  gaps and accepted trade-offs; several entries are tractable contributions.

ZigBase is **pre-1.0** and deliberately prefers the better API over backward compatibility. A
breaking change is acceptable when it makes the design better — it just needs a `### Breaking`
entry in your [changelog fragment](#changelog-fragments).

## AI-assisted contributions

**AI-assisted contributions are welcome here.** ZigBase itself is largely AI-developed, and
pretending otherwise would be dishonest.

This is a deliberate departure from the upstream Zig project, whose
[Code of Conduct](https://ziglang.org/code-of-conduct/) carries a strict no-LLM policy. That policy
is motivated by reviewer-time economics and mentorship on a project with a tiny core team and
hundreds of open PRs — reasons that are specific to Zig's situation, not a claim that AI-written
code is inherently defective. ZigBase reaches a different conclusion for its own repository. If you
contribute to the Zig language itself, follow *their* policy there.

What actually matters here:

- **Code is judged on its properties, never on its authorship.** The bar is
  [`NO_SLOP.md`](NO_SLOP.md) — a rubric distilled from Andrew Kelley's positions and the official
  Zig docs (explicit allocators, guaranteed `defer`/`errdefer`, errors-as-values, no hidden control
  flow, correctness over passing tests, disciplined comptime). It applies identically to
  hand-written and generated code.
- **You are responsible for what you submit.** Understand every line of your PR well enough to
  defend it in review and fix it when it breaks. "The model wrote it" is not an answer to a review
  comment.
- **A green test suite is not evidence of correctness.** `NO_SLOP.md` is explicit about this, and
  it is the single most common failure mode in generated Zig: a test that passes while asserting
  nothing, or an error path between an allocation and its ownership handoff that no test exercises.
  Trace your error and OOM paths by hand.

Bulk, unreviewed, or drive-by generated PRs will be closed. That is a statement about review cost
and correctness, not about tooling.

## Development setup

Every tool is pinned in [`mise.toml`](mise.toml) — Zig 0.16.0, Python 3.13, Node 24, Dart 3.12,
JDK 17, Gradle 9.6. **The exact Zig version matters**; another 0.16.x is not guaranteed to work
(and an unsupported version fails at compile time with a clear required-vs-actual message).

```sh
mise install                          # installs everything pinned in mise.toml
eval "$(mise activate bash)"          # ...then plain `zig`, `python`, `npm` are correct
```

If you would rather not activate mise, prefix each command instead:
`mise exec zig@0.16.0 -- zig build`. The commands below use the activated form.

**Platform:** Linux and macOS only. There is no Windows build — the embedded HTTP server depends on
facil.io/zap. On a Windows host, develop in WSL2 or use the Docker image.

## Building and running

```sh
zig build                             # -> zig-out/bin/zigbase
zig build run -- serve --insecure-cookies --data-dir ./zb_data
```

**`--insecure-cookies` is required for local plain-HTTP development** — auth cookies are `Secure`
by default, so without it the admin UI cannot store your session and login silently fails. The
default bind is `127.0.0.1:8090` (loopback only).

Create a superuser to sign in at <http://127.0.0.1:8090/_/>:

```sh
./zig-out/bin/zigbase superuser create --email you@example.com --password '<strong password>' --data-dir ./zb_data
```

Useful optional build flags (all default off unless noted): `-Dpostgres` (PostgreSQL backend),
`-Ds3` (S3-compatible storage), `-Dvector` (vector search), `-Dfts5=false` (lean build without
SQLite FTS5), `-Ddev-mode` (dev-only test seams; on in `Debug`, off in release). Run
`zig build --help` for the full list.

## Tests — there are two suites

Both run in CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)), and **passing one does not
imply passing the other.**

### 1. Zig unit tests

```sh
zig build test --summary all
```

> **Caveat:** `zig build test` prints a spurious `failed command: …` line even when everything
> passes. The authoritative signal is the `Build Summary: N/N tests passed` line — hence
> `--summary all`. There is no per-test filter wired into `build.zig`.

CI also runs the suite with `-Ddev-mode=false` (the production gate), so a test that depends on a
dev-only seam must be gated accordingly.

**Adding a new `src/*.zig` file?** Its `test {}` blocks will not run until the file is added to the
`test { _ = @import("…"); }` block in [`src/root.zig`](src/root.zig), which is both the public API
surface and the unit-test root. This is easy to forget and silently skips your tests.

### 2. Python / Playwright browser suite

**Before running this, rebuild.** The suite shells out to whatever binary is already sitting in
`zig-out/bin/` — if the tree has moved since your last `zig build` (a rebase, a stash, a branch
switch, or just time passing while you edited), that binary can be stale without anything telling
you so; the symptom is a coherent subset of tests failing (e.g. one file's worth) while everything
else passes, which reads like a real regression until you check the artifact. The suite also needs
two fixture binaries that a plain `zig build` does not produce:

```sh
zig build                                 # refresh zig-out/bin/zigbase
zig build features-fixture full-fixture   # fixtures test_features.py / test_logs.py need
```

See ["Traps: a spawned-server suite tests whatever is on disk"](docs/testing.md#traps-a-spawned-server-suite-tests-whatever-is-on-disk)
for the failure shapes this avoids.

```sh
python -m pytest tests/admin -q -n auto              # whole suite, parallel
python -m pytest tests/admin/test_schema.py::test_edit_rules_lock_toggle -q   # one test
python -m pytest tests/smtp -q                        # live SMTP-TLS test (keep serial)
```

First run needs the test dependencies and a headless browser:

```sh
python -m pip install pytest pytest-xdist playwright aiosmtpd
python -m playwright install --with-deps --only-shell chromium
```

[`tests/admin/conftest.py`](tests/admin/conftest.py) is the harness: it builds the binary, launches
a real server with `--insecure-cookies`, and drives the admin SPA with headless Chromium. It is
parallel-safe (each server binds its own free port and tempdir), so `-n auto` is fine;
`tests/smtp` must stay serial because it binds a fixed TLS port.

### 2b. Agent-evaluation harness

The real-agent Genesis run is opt-in, but its contracts, fake agents, negative grader fixtures, and
skill drift guard are ordinary blocking tests:

```sh
python -m pytest tests/agent_evals tests/admin/test_skill_sync.py -q
ZIGBASE_DOCKER_EVAL_TEST=1 python -m pytest tests/agent_evals/test_genesis_docker.py -q
```

The second command needs a local Docker daemon and exercises the pinned image, health/meta probes,
production doctor, and teardown. See [docs/agent-evals.md](docs/agent-evals.md) before running a real
agent; do not commit its raw stdout/stderr transcripts.

**Run the relevant `tests/admin/` test for anything touching the admin UI, secure defaults,
realtime, or access rules.** A green `zig build test` has repeatedly hidden real regressions that
the `browser` CI job then caught — end-to-end behavior is only exercised here.

### Other CI gates you can run locally

```sh
zig fmt --check src build.zig     # formatting gate
```

**Before running `check-gating.sh`, build its four reference binaries.** A plain `zig build`
only produces one of them; the other three are separate steps the script does not build for you —
run without them, it fails fast with an actionable `exit 2` naming the missing binary rather than
silently passing:

```sh
zig build                                             # zig-out/bin/zigbase
zig build full-fixture minimal-server                 # the other two gating-invariant fixtures
zig build -Ddev-tools=false -p zig-out-devtools-off    # dev-tools-off reference build
```

```sh
./scripts/check-gating.sh         # optional subsystems must be comptime-gated (absent-symbols check)
./scripts/check-allocator-contracts.sh   # allocator ownership-contract ratchet
zig build audit                   # pinned dependency versions vs. docs/security-advisories.md
zig build fuzz --fuzz=100000      # bounded coverage-guided parser fuzzing
```

The parser fuzz targets cover filter/query grammars, PostgreSQL connection strings, and
WebAuthn CBOR/authenticator data. Use `zig build fuzz --fuzz` to run continuously;
`zig build fuzz` executes only the checked-in seed corpora and exits.

CI additionally builds all three examples and several fixture binaries, and runs PostgreSQL,
PostgreSQL-over-TLS, S3/MinIO, and the four client-SDK jobs. If your change touches a client SDK's
generated output, the `gen-*-client-check` steps will fail until you regenerate the snapshot.

## The quality bar

Read [`NO_SLOP.md`](NO_SLOP.md) before writing Zig here. The rules that catch the most real defects:

- **Explicit allocators.** Any function that allocates takes an `Allocator` parameter. No hidden
  allocation, no reaching for a global allocator.
- **Guaranteed deallocation.** Pair every acquisition with `defer`/`errdefer` *immediately* after
  it. Missing `errdefer` on a partial-construction path is the classic leak.
- **Ownership contracts.** Be explicit about what a function returns and who frees it. A function
  that allocates scratch and never frees it is correct under a caller's arena and a leak under any
  other allocator.
- **Trace every error and OOM path** between an allocation and its ownership handoff, before you
  commit. This is the single class of defect reviewers here keep finding.
- **Errors as values, no hidden control flow, correctness over passing tests.**

`NO_SLOP.md` also lists what *not* to flag — style and naming are deliberately un-enforced beyond
`zig fmt`.

A few conventions that bite if you are adding API surface:

- Every list endpoint returns `{items}`; side-effect success is `204`; pagination uses the records
  cursor vocabulary (`cursor`/`limit`, `nextCursor`/`hasNext`); URL segments are dash-case.
- Config planes follow the assignment rule in [`docs/framework.md`](docs/framework.md) §3 —
  comptime for structure, env for deploy-varying values, build flags for binary cost.
- Optional subsystems must be comptime-gated (no unconditional function-pointer registration);
  `scripts/check-gating.sh` enforces this in CI.
- New CLI flags and env vars must be documented, or `tests/admin/test_docs_parity.py` fails on the
  config-key-table drift.

Hook record mutations must allocate with `ev.arena.a`, never `ev.app.allocator` — `ev.arena` owns
`ev.record`.

## Changelog fragments

**Never edit `CHANGELOG.md` directly.** Add a fragment file instead:

```
changelog.d/<slug>.md
```

`<slug>` is a short kebab-case descriptor unique enough not to collide with other open PRs. The
body is one or more `### <Section>` headings with bullet lines; a single fragment may populate
several sections:

```markdown
### Features
- Added `Data.createAuthRecord` for passwordless provisioning.

### Fixes
- `data.create` no longer leaks the scratch arena on an OOM path.
```

Recognized sections, in emit order: **Breaking, Features, Fixes, Changed, Performance, Deprecated,
Removed, Security, Internal**. Any other `### <name>` fails the build.

The changelog is consumer-facing. The first eight sections are for user-visible changes;
**Internal** is for contributor-facing changes with no consumer impact (build, CI, tests, refactors,
tooling). The test: *would a user notice → a consumer section; only contributors notice → Internal;
nobody needs it recorded → no fragment.* See [`changelog.d/README.md`](changelog.d/README.md).

This exists so parallel PRs never conflict on `CHANGELOG.md`. Fragments are aggregated into a
release block and deleted at release time.

## Keeping docs and examples in sync

Stale published docs ship wrong — sometimes insecure — guidance to users, so this is a required
part of every PR, not an afterthought.

- **Canonical docs live in `docs/*.md`** (plus root `CHANGELOG.md` and `KNOWN_LIMITATIONS.md`).
- **The published site under `site/src/content/docs/` is generated** from those by
  `site/scripts/gen-docs-mirror.mjs`, which runs automatically on `npm run dev` / `npm run build`.
  **Never hand-edit a mirror** — they are gitignored build artifacts. Edit the canonical file and
  the mirror follows.
- **The exceptions** are the site-authored pages with no `docs/` canonical: `configuration.md`,
  `overview.md`, and the `.mdx` pages (`tutorial.mdx`, `quick-start.mdx`). Edit those in `site/`
  directly. New CLI flags and env vars go in `site/src/content/docs/configuration.md`.
- **`docs/superpowers/` is a historical design archive.** Do not rewrite it.
- **The three examples are a deliberate complexity ladder** — `examples/blog` (bare packaging
  proof), `examples/golfsim` (a realistic app), `examples/plugins` (the advanced comptime surface).
  Update their code *and* READMEs when behavior, defaults, fields, APIs, or access rules change,
  and keep blog the simplest and plugins the most advanced. Each is a standalone consumer package
  with its own vendored `zig-pkg/zap` — do not edit vendored dependencies.

If any docs or site content changed:

```sh
cd site && npm run build
```

## Opening a pull request

1. **Branch off `main`.** Direct pushes to `main` are rejected; everything goes through a PR.
2. **Tell a clean story with your commits.** Focused commits with real messages beat one dump
   commit or a pile of `fix review` fixups. Tests and docs belong with the change they cover.
3. **Fill in the [PR template](.github/pull_request_template.md).** The docs-and-examples sync
   checklist is required — check each item that applies, or mark it `N/A`.
4. **Make CI green.** `zig build`, `zig build test`, `zig fmt --check`, and the `browser` job for
   any behavior or UI change.
5. **Respond to review threads.** Reply to each one, and resolve it only after the fix is actually
   pushed. Pushing a fix without replying leaves reviewers guessing.

Merges use **merge commits** (no squash, no rebase-merge). Maintainers merge once CI is green and
review threads are resolved.

## Where things live

| Path | What it is |
|------|-----------|
| `src/root.zig` | Public API surface **and** the unit-test root |
| `src/framework.zig` | `App(comptime cfg)` — the comptime application builder |
| `src/server.zig`, `src/router.zig`, `src/api/` | Request lifecycle: listener → router → handlers |
| `src/db.zig` | Reader pool + single mutex-guarded writer, WAL mode |
| `src/query/` | Query-string lexer → parser → compiler (parameter-bound SQL) |
| `src/schema.zig`, `src/provision.zig`, `src/ddl.zig`, `src/migrations.zig` | Schema and provisioning |
| `src/rules.zig` | Access rules — safe by default; blank means locked, `"@public"` is the only allow-all |
| `src/events.zig`, `src/realtime/` | Hooks and realtime delivery |
| `src/admin/app.js` | The admin SPA (Preact via htm, `@embedFile`-d — no build step; edit and rebuild) |
| `src/files/`, `src/mail/` | Pluggable `Storage` and `Mailer` vtables |
| `examples/` | The three-rung consumer complexity ladder |
| `clients/` | Official TypeScript, Dart, Python, and Kotlin SDKs |
| `tests/admin/` | Playwright browser suite (drives `data-test=` hooks in the SPA) |
| `docs/` | Canonical documentation |

[`CLAUDE.md`](CLAUDE.md) has a longer architectural tour of the parts that span multiple files.

## License

ZigBase is [Apache-2.0](LICENSE). By contributing, you agree that your contributions are licensed
under the same terms. There is no separate CLA.
