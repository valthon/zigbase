# ZigBase — Release & Versioning Overhaul

**Status:** Approved design (2026-06-19)

**Context:** Cutting a release today is error-prone and high-churn. The version
number is hand-written in ~10 places (`build.zig.zon`, five `@zigbase/server*`
`package.json`s, the site, the README, KNOWN_LIMITATIONS, CHANGELOG); the
marketing site has already drifted (shows `v0.1.0` in spots while the project is
at `0.4.x`); the server binary is built **twice** in **two variants** (manual
`scripts/release.sh` uses `ReleaseSafe`, CI `release-server.yml`/`publish.mjs`
use `ReleaseFast`) and shipped on two disconnected tracks (manual `gh release`
tarballs vs. CI npm publish); and the per-target npm packages are committed
boilerplate, so adding a platform means editing five-plus files. This overhaul
makes a release a **one-line version bump + a tag**, builds each binary **once**,
ships it to **both** channels, and **derives** every other version reference
automatically.

---

## 1. Goals

- A release is **one canonical version edit + a git tag**. No other *version
  plumbing* changes. (Authoring a `CHANGELOG.md` entry is per-release *content*,
  not plumbing — it is the one expected hand-written file per release, and may
  ride in the same commit as the version bump.)
- **Two independent version lines**, each single-sourced:
  - **Server / project** → `build.zig.zon` `.version`.
  - **Client SDK** (`@zigbase/client`; and each future `clients/<lang>` client)
    → that client's own `package.json` `version`.
- Every other surface — npm package manifests, GitHub release, marketing site,
  docs, README — **derives** its version automatically, committing nothing.
- Each server binary is **built once** (one variant) and published to **both**
  the GitHub release and npm from the same bytes.
- One consistent build variant everywhere: **`ReleaseSafe`, stripped,
  `-Dcpu=baseline`**.
- Adding a new target is a **one-line** addition to a single canonical target
  list — no new committed files or directories.
- Aggressively DRY: a generated artifact is never also committed.

## 2. Non-goals

- No change to the SDK's or server's runtime behavior or public API.
- Not changing the npm package **names** (`@zigbase/client`, `@zigbase/server*`,
  `@zigbase/typegen`).
- Not introducing new clients (Python, etc.) now — only making the design
  accommodate them.
- Windows remains deferred (facil.io is POSIX-only), unchanged here.

## 3. Version model & canonical sources

Exactly two places in git ever name a version:

| Line | Canonical source | Bump to release |
|---|---|---|
| Server / project | `build.zig.zon` `.version` | edit 1 line |
| `@zigbase/client` | `clients/typescript/package.json` `version` | edit 1 line |
| `@zigbase/typegen` | `clients/typescript/npm/typegen/package.json` `version` | edit 1 line |

`@zigbase/typegen` keeps its own independent version (it is a tool, not a
client) and is treated like a client for sourcing purposes: its committed
`package.json` is its source of truth.

A **CI guard** asserts the pushed tag matches the relevant canonical version
(e.g. `v0.4.1` ⇒ `build.zig.zon` is `0.4.1`; `client-v0.2.0` ⇒ client
`package.json` is `0.2.0`), failing the release fast on drift.

## 4. Derivation map — nothing else commits a version

| Surface | Derives version from | How |
|---|---|---|
| npm `@zigbase/server*` (4 platform + meta) | `build.zig.zon` | **generated** at publish (see §6) |
| GitHub release tarballs + `SHA256SUMS` | tag / `build.zig.zon` | built by the release workflow |
| npm `@zigbase/client` | its own `package.json` | published as-is |
| npm `@zigbase/typegen` | its own `package.json` | published as-is |
| Site `.astro` (badges, download table, quickstart) | `build.zig.zon` + client `package.json` | a build-time `version.ts` reads them |
| Site docs (markdown content collection) | same | a **remark plugin** substitutes `{{server_version}}` / `{{client_version}}` tokens at build |
| Root `README.md` (GitHub-rendered) | latest GitHub release | **dynamic shields.io badge**; prose de-pinned |
| `docs/*.md` mirror (GitHub-rendered) | — | **de-pinned**: "the latest release" + links; no hard numbers |
| `CHANGELOG.md` / site `changelog.md` | — | per-version headings are legitimate **content**, not a "current version" display; written per release |

**Principle:** a version number appears only where it can be *derived*. The
changelog is the sole place a literal version is authored, because a changelog
entry *is* per-release content.

## 5. One binary, one variant

- **Retire the `main.zig` / `main_dist.zig` split.** The official `zigbase`
  binary becomes typegen-enabled: `src/main.zig` uses
  `App(.{ .enable_typegen = true })`. Delete `src/main_dist.zig` and the
  `dist-server` build step; the default `zig build` install artifact (`zigbase`)
  is the shipped binary for **both** channels.
  - `enable_typegen` remains a framework option (embedders can opt out); only
    the shipped official binary forces it on. Validated cost: **+118 KiB
    (+1.7%)** on a stripped `ReleaseSafe` `linux-x64` build — negligible.
  - `typegen` only adds a dormant CLI subcommand; no serve-time/HTTP surface
    change.
- **One variant everywhere: `ReleaseSafe` + stripped + `-Dcpu=baseline`.**
  `scripts/release.sh` (already ReleaseSafe), the npm build, and CI all converge.
  Stripping is already in `build.zig` (`-Dstrip`, default on outside Debug).
  Advanced users who want `ReleaseFast`/`ReleaseSmall` build their own.
- Net: one artifact per target, identical bytes in the tarball and the npm
  platform package.
- **Optional (nice-to-have, not required):** a `zigbase version` subcommand /
  `--version` that reads `build.zig.zon` so the running binary self-reports.
  Listed for the plan to include only if cheap.

## 6. Single target list + generated npm packages (DRY)

### 6.1 One canonical target list
Create `clients/typescript/npm/targets.json` (or `.mjs`) — the **single source
of truth** for supported platforms. Each entry carries everything any consumer
needs:

```jsonc
[
  { "key": "linux-x64",    "zig": "x86_64-linux-musl",  "os": "linux",  "cpu": "x64" },
  { "key": "linux-arm64",  "zig": "aarch64-linux-musl", "os": "linux",  "cpu": "arm64" },
  { "key": "darwin-x64",   "zig": "x86_64-macos",       "os": "darwin", "cpu": "x64" },
  { "key": "darwin-arm64", "zig": "aarch64-macos",      "os": "darwin", "cpu": "arm64" }
]
```

This replaces the target list currently duplicated in **five** places:
`publish.mjs`, the `release-server.yml` matrix, `scripts/release.sh`, the
launcher `SUPPORTED` map, and the tarball-naming loop. Adding a 5th target =
one entry here, nothing else.

### 6.2 Generated packages
A generator (`scripts/gen-server-packages.mjs`, or a function inside
`publish.mjs`) emits, into a gitignored staging area at publish time, from
`targets.json` + `build.zig.zon`:

- **Four platform packages** — each `package.json` (name `@zigbase/server-<key>`,
  `version`, `os`, `cpu`, `bin`/files) **and** its one-line `README.md`, both
  produced from a single inline template parameterized by `key`.
- **The meta package** `@zigbase/server` — `package.json` (`version`,
  `optionalDependencies` built from `targets.json`) and `README.md` (the
  platform table generated from `targets.json`).
- A `targets.json` copied into the meta package so the **launcher reads it at
  runtime** instead of hard-coding `SUPPORTED` (launcher *logic* stays committed
  in `index.js` / `bin/zigbase.js`; the *data* is the single source).

### 6.3 What stops being committed
Delete the committed boilerplate (now generated, gitignored like the binaries):
- All four `server-<key>/` directories entirely (`package.json`, `README.md`,
  `.gitkeep`).
- The meta `server/package.json` and `server/README.md`.

**Remains committed (code/content, not derivable):** `server/index.js`,
`server/bin/zigbase.js`, `typegen/bin/typegen.js`, `typegen/package.json` +
`typegen/README.md`, `clients/typescript/package.json` + its README, the
generator, `targets.json`, `RELEASING.md`, launcher tests.

## 7. Build-once pipeline + tag scheme

One workflow, triggered by a `v*` tag, performs the entire project release:

1. **Guard** — assert `tag == build.zig.zon .version`; fail fast otherwise.
2. **Build once** — 4-target matrix (`zig build` ⇒ `zigbase`, `ReleaseSafe`,
   stripped, `-Dcpu=baseline`), matrix sourced from `targets.json`; upload
   artifacts.
3. **GitHub release** — `tar` each binary as `zigbase-<ver>-<target>.tar.gz`,
   write `SHA256SUMS`, `gh release create v<ver>` with those assets.
4. **npm** — generate the manifests (§6.2), inject the **same** built binaries,
   publish `@zigbase/server*` via **OIDC** (`--provenance`, no token).

Both 3 and 4 consume the identical artifacts from step 2.

**Consolidated tags:**

| Tag | Publishes | Builds binaries? |
|---|---|---|
| `v<X.Y.Z>` | GitHub release **+** `@zigbase/server*` | yes (×4, once) |
| `client-v<X.Y.Z>` | `@zigbase/client` (activate dormant `release-sdk.yml`) | no |
| `typegen-v<X.Y.Z>` | `@zigbase/typegen` (pure JS) | no |

- The old `server-v*` tag is **removed** (folded into `v*`).
- `scripts/release.sh` is refactored so its build/package logic is the **shared**
  routine the workflow and the manual fallback both call (DRY); it no longer
  runs a parallel `gh release create`. The manual path stays available for
  bootstrap/emergency, running identical steps.
- `publish.mjs` switches to `ReleaseSafe`, builds `zigbase` (not `zigbase-dist`),
  and uses `targets.json` + the generator.

## 8. Site / docs automatic version

- **`site/src/config/version.ts`** (replacing the static `site.ts` constant)
  reads `../../build.zig.zon` (regex-extract `.version`) and
  `../../clients/typescript/package.json` at build time, exporting
  `SERVER_VERSION`, `CLIENT_VERSION`, their `v…` tags, and derived
  release-asset URLs (built from `targets.json`).
- **`.astro` pages/components** (Nav/landing badge, `download.astro`,
  `QuickStart.astro`, footer) import from `version.ts`. The download table rows
  are generated from `targets.json` so the asset list also tracks the target
  set.
- **A remark plugin** registered in `astro.config` substitutes
  `{{server_version}}` / `{{client_version}}` (and a `{{version_tag}}` form) in
  markdown docs at build, so `typescript-sdk.md`, `known-limitations.md`,
  `overview.md`, etc. carry no literal numbers.
- **Root `README.md`** uses a dynamic shields.io release badge
  (`img.shields.io/github/v/release/valthon/zigbase`) and de-pinned prose.
- **`docs/*.md` mirror** is de-pinned (links to the releases page instead of a
  number), preserving the strict site↔docs mirror rule with no per-release edits
  on either side.
- **`clients/typescript/README.md`** (GitHub-rendered) is de-pinned the same way
  — no literal `@zigbase/client@0.1.0`; link to npm / "latest" instead.

## 9. Migration / cleanup (folded into this work)

- **Close PR #40** (the manual five-`package.json` 0.4.1 bump) — obsolete; the
  real 0.4.1 ships through the new pipeline.
- The pre-existing site `v0.1.0` drift is fixed for free once the site derives
  from `build.zig.zon` (= `0.4.x`).
- After the overhaul lands, cut **`v0.4.1`** through the new pipeline to ship the
  stripped binaries on both channels (the original task that started this).
- Update `clients/typescript/npm/RELEASING.md` to document the new
  one-line-bump-plus-tag flow and the generator/targets model.

## 10. Testing / verification

- **Generator unit test:** from a fixed `targets.json` + a stub version,
  asserts the emitted platform/meta `package.json`s (names, `os`/`cpu`,
  `optionalDependencies`, version) and READMEs match expectations; adding a
  target entry produces a complete new package with no other change.
- **Launcher test** (`test-launcher.mjs`) updated to read the generated
  `targets.json`; still resolves the right platform package per host.
- **Single-binary build:** `zig build` produces a stripped `ReleaseSafe`
  `zigbase` that runs `serve` and `typegen` (the latter emits its usual usage
  error), proving unification.
- **Version-guard:** a tag/version mismatch fails the workflow guard
  (test the guard logic, e.g. a small script with unit coverage).
- **Site build:** `npm run build` derives the correct `SERVER_VERSION` /
  `CLIENT_VERSION` from the manifests; no literal stale versions remain
  (grep gate for `v0.1.0` / hard-coded numbers on the version-display surfaces).
- **Dry-run publish:** `publish.mjs --dry-run` generates manifests + packs all
  packages in dependency order and exits 0.
- **Mirror + stale gates:** the existing `docs/` ↔ `site/` mirror parity holds;
  the stale-phrase grep stays clean.
- **CI stays green** across `build` / `ts-sdk` / `browser` / `pages`.

## 11. Decomposition (for the plan)

Cohesive but large; the plan will sequence roughly:
(a) single binary + one variant (`main.zig`, delete `main_dist.zig` + `dist-server`);
(b) `targets.json` + the package/README generator (+ unit test), delete committed platform dirs, rewire `publish.mjs` + launcher to the generated data;
(c) unified `v*` build-once → both-channels workflow + version guard; refactor `scripts/release.sh` to shared logic; remove `server-v*`; activate `client-v*`;
(d) site `version.ts` + remark token plugin + `targets.json`-driven download table; README dynamic badge; de-pin `docs/*.md` mirror; fix drift;
(e) `RELEASING.md` rewrite, close PR #40, then cut `v0.4.1` through the new pipeline.
