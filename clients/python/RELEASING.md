# Releasing `zigbase` (Python)

The Python SDK is versioned **independently** of the ZigBase server, exactly like the
TypeScript SDK (see [`clients/typescript/RELEASING.md`](../typescript/RELEASING.md)) and
the Dart SDK (see [`clients/dart/RELEASING.md`](../dart/RELEASING.md)).

- The **server** is released with `vX` tags (e.g. `v0.11.0`).
- The **TypeScript SDK** is released with `client-v*` tags (e.g. `client-v0.3.0`).
- The **Dart SDK** is released with `dart-client-v*` tags (e.g. `dart-client-v0.1.0`).
- The **Python SDK** is released with `python-client-v*` tags (e.g. `python-client-v0.1.0`)
  — a distinct prefix from the other two, since all three packages version independently
  and a shared prefix would collide.

## Prerequisites

`zigbase` publishes via PyPI's **Trusted Publishing** (GitHub Actions OIDC, the
PyPI-ecosystem equivalent of npm trusted publishing) — the
[`release-python-sdk.yml`](../../.github/workflows/release-python-sdk.yml) workflow needs
no token (`id-token: write` only). This depends on **one-time setup by the repository
owner** on PyPI (below), which has not happened yet — see
[Status](#status-first-publish-pending) before tagging a release.

### One-time owner setup (do this before the first tag)

PyPI Trusted Publishing binds to the **owner/repo + workflow filename** (and, if a GitHub
Actions `environment` is used, that environment name too) — this is the *same* model as
npm's trusted publishing and *different* from pub.dev's repository+tag-pattern binding.
Renaming `release-python-sdk.yml` breaks the binding on PyPI's side until the "Publishing"
settings page is updated to match; changing the `environment: pypi` value in the workflow
requires the same.

PyPI supports two setup routes, depending on whether the project already exists:

**Route A — package doesn't exist yet (this project's situation): a "pending publisher".**
PyPI lets you register a trusted publisher for a project name **before any version has ever
been uploaded** — the first tag push then creates the project via that trusted publisher,
with no manual upload step at all.

1. Log into PyPI, go to <https://pypi.org/manage/account/publishing/>, and under *Add a
   pending publisher* fill in:
   - **PyPI Project Name**: `zigbase`
   - **Owner**: `valthon`
   - **Repository name**: `zigbase`
   - **Workflow name**: `release-python-sdk.yml`
   - **Environment name**: `pypi`
2. Push a `python-client-v<version>` tag matching `pyproject.toml`'s `version` (see
   [Cutting a release](#cutting-a-release) below). The `verify` job runs the gates and
   builds; the `publish` job's OIDC token is exchanged for a short-lived PyPI API token,
   which claims the project and uploads the built sdist + wheel — no `twine upload`, no
   long-lived credential, ever.

**Route B — fallback: manual first upload.** If the pending-publisher route is unavailable
or the project needs to exist for some other reason first, a maintainer can do a one-time
manual publish, then configure a normal (non-pending) trusted publisher on the existing
project's *Publishing* settings tab with the same five fields as above:
```bash
cd clients/python
mise exec python@3.13 -- python -m pip install --quiet build twine
mise exec python@3.13 -- python -m build
mise exec python@3.13 -- python -m twine upload dist/*     # prompts for a PyPI API token
```
This reserves the `zigbase` name and publishes the version currently in `pyproject.toml`.
Every subsequent `python-client-v*` tag then publishes automatically via Trusted
Publishing, same as Route A from that point on.

**Optional hardening — require the GitHub Actions environment.** Both routes above name a
GitHub Actions `environment: pypi`, which `release-python-sdk.yml`'s `publish` job already
sets — but PyPI enforcing it (rejecting an OIDC token minted outside that environment) only
applies once the publisher is configured with that environment name (both routes above
already do this). Optionally also create the matching environment under this repo's
**Settings → Environments** (naming it `pypi`), optionally with required reviewers, for
GitHub-side visibility/gating in addition to PyPI's own enforcement.

**Optional — tag protection.** Restrict who can push `python-client-v*` tags with a
repository ruleset (**Settings → Rules → Rulesets**, targeting tags) to limit who can
trigger a publish.

## Status: first publish pending

`zigbase` is not yet on PyPI — neither setup route above has been run. **Do not tag a
`python-client-v*` release** until one has; `release-python-sdk.yml` exists and will run on
the tag, but its `publish` job cannot succeed against a project PyPI doesn't have a trusted
publisher registered for (Route A) or hasn't seen at all (before Route B's manual upload).

As of this writing, `zigbase` is unclaimed on PyPI (`https://pypi.org/pypi/zigbase/json`
answers 404), so Route A (pending publisher) is the cleaner path — no manual upload, no
local PyPI API token ever touches a maintainer's machine.

## Cutting a release

1. Bump the version in `clients/python/pyproject.toml`'s `[project] version` (e.g. `0.1.0`
   → `0.1.1`). Follow semver.
2. Move `clients/python/CHANGELOG.md`'s `## [Unreleased]` entries under a new
   `## [0.1.1] - <date>` heading (keep a fresh empty `## [Unreleased]` above it for the
   next round of changes).
3. Commit the bump:
   ```bash
   git commit -am "chore(python-sdk): release python-client-v0.1.1"
   ```
4. Tag with the matching `python-client-v<version>` tag (the version after the prefix MUST
   equal `pyproject.toml`'s `version`, or the workflow's assertion step fails closed):
   ```bash
   git tag python-client-v0.1.1
   ```
5. Push the commit and the tag:
   ```bash
   git push origin main
   git push origin python-client-v0.1.1
   ```
6. The `release-python-sdk.yml` workflow runs on the pushed tag:
   - `verify` installs `.[dev]` + `build` + `twine`, runs the four local gates (format,
     lint, typecheck, unit tests — **not** the live-server integration suite, which needs a
     zigbase binary the release workflow doesn't build), asserts the tag matches
     `pyproject.toml`, builds the sdist + wheel with `python -m build`, and `twine check`s
     them, then uploads the built `dist/` as a workflow artifact.
   - `publish` downloads that exact artifact and hands it to
     `pypa/gh-action-pypi-publish@release/v1`, which authenticates via OIDC (no token) and
     uploads to PyPI. Nothing is rebuilt between `verify` and `publish` — what gets
     published is byte-for-byte what passed `twine check`.

## Notes

- The workflow does **not** build or run the Zig server / integration tests — the merge CI
  already covers those (`zig build test` + the unit suite in `clients/python/tests/`,
  `-m integration` tests opt-in via `ZIGBASE_TEST_BINARY`, see the `python-sdk` job in
  `.github/workflows/ci.yml`). SDK releases stay fast and deterministic, mirroring the
  TypeScript and Dart SDKs' release posture.
- `py.typed` (PEP 561) ships in the wheel automatically — hatchling includes every file
  under the declared package directory (`src/zigbase`) by default; there's no separate
  packaging step to remember when bumping the version.
