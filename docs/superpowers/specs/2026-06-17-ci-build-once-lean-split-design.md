# CI Build-Once Lean Split — Design

**Date:** 2026-06-17
**Status:** Approved (design) — pending implementation plan
**Predecessor:** PR #22 (mise v4 caching, Playwright `--only-shell` + browser cache, single-source-of-truth Node)

## Problem

After PR #22, the **Playwright install** is no longer the CI bottleneck (~17s, cached). Per-step timings of the merged run exposed the real cost:

- The `zig` job recompiles the vendored **SQLite amalgamation** cold on every run — the main `Build` step alone is **69s** — because **no `actions/cache` persists `.zig-cache` / the zig global cache**.
- The **same binaries are built twice**: the `zig` job builds `main` + `blog` + `plugins`, and then the `browser` job's pytest fixtures rebuild `main`, `blog`, and `plugins` *again from scratch* (each `zig build` subprocess = another cold SQLite compile). This redundant cold rebuild — not Playwright test execution — dominates the browser job's 219s.

Two root causes: (1) the zig build cache is never persisted, and (2) binaries are rebuilt per-job instead of built once and shared.

### Measured evidence (local, this machine)

| Build | Cache state | Time |
|---|---|---|
| `main` | cold, fresh global cache | 39.5s |
| `blog` | shares global cache with `main` | **7.1s** (vs ~14s cold-each) |
| `plugins` | shares global cache with `main` | **9.2s** (vs ~15s cold-each) |
| `main` rebuild | global + local cache warm | **0.05s** |

A **shared, persisted zig global cache** compiles the vendored SQLite exactly once; `blog`/`plugins` skip it, and on warm runs even `main`'s SQLite restores from cache.

## Goal

Both wall-clock speed **and** architectural cleanliness:
- Build each binary **once**, share via artifacts; downstream test jobs consume the prebuilt **standalone binary** with a minimal toolchain (no Zig, no Node).
- Persist a **shared zig global cache** so the single build is fast and SQLite compiles once.
- CI tests the *actual built artifact* rather than a per-test debug rebuild.

Non-goals: running tests inside the `mcr.microsoft.com/playwright` container (install is now 17s — not worth the ~1.8GB image pull + mise/Zig friction); the sidecar/service-container pattern (rejected — larger image, Python pytest plugin ignores `PW_TEST_CONNECT_WS_ENDPOINT`, GHA `services:` can't override the container command).

## Architecture

Four jobs (the current `zig` job splits into `build` + `unit`):

```
build (Zig + Node, warm global zig-cache)      unit (Zig, warm global zig-cache)
  ├─ restore/save ZIG_GLOBAL_CACHE_DIR cache      └─ zig build test  (runs in parallel,
  ├─ npm build plugins frontend → frontend/dist        shares the cache key)
  ├─ build main, blog, plugins  (share global cache; dist embeds into the plugins binary)
  ├─ build golfsim              (dependency-graph proof; not uploaded)
  └─ upload-artifact: zigbase, blog, plugins binaries
        │
        ├──────────────► browser (Python + Playwright; NO Zig, NO Node)   needs: build
        │                  └─ download-artifact → export ZIGBASE_TEST_*_BINARY → pytest
        └──────────────► ts-sdk (Node; NO Zig)                            needs: build
                           └─ download main binary → export env → SDK tests
```

### Job responsibilities

- **`build`** — the sole producer of binaries. Sets `ZIG_GLOBAL_CACHE_DIR`, restores the zig cache, builds the plugins frontend (Node, with `~/.npm` cache), builds `main`/`blog`/`plugins` (sharing the global cache so SQLite compiles once), builds `golfsim` as a dependency-graph proof (not uploaded), and uploads the three consumed binaries as artifacts. `plugins` embeds `frontend/dist` at build time, so **only the binary** is needed downstream — Node is confined to this job.
- **`unit`** — `zig build test`. Runs in parallel with `build`; shares the warm global-cache key so the test binary's SQLite link is fast. Not a dependency of the test jobs.
- **`browser`** — `needs: build`. Runs on `ubuntu-latest` with only Python + Playwright (no Zig, no Node). Downloads the binary artifacts, sets `ZIGBASE_TEST_*_BINARY` env vars, installs Playwright (`--only-shell`, cached), runs `pytest tests/admin` + `tests/smtp`.
- **`ts-sdk`** — `needs: build`. Downloads the `main` binary artifact, runs the TypeScript SDK unit + integration tests against it (no `zig build`).

## Test-harness refactor (the enabling change)

Add a small resolver shared by the pytest suite:

> Resolve a package's server binary: if `$ZIGBASE_TEST_<PKG>_BINARY` is set **and** the file exists, use it; otherwise `zig build` the package (current behavior) and return the built path.

Env var contract:

| Binary | Env var | Used by |
|---|---|---|
| main `zigbase` | `ZIGBASE_TEST_BINARY` | `conftest.py` `binary` fixture; `test_static_files.py` runtime-mode tests; `tests/smtp/test_smtp_tls.py` `binary` fixture |
| `blog` | `ZIGBASE_TEST_BLOG_BINARY` | `test_custom_route.py`, `test_scheduler.py` |
| `plugins` | `ZIGBASE_TEST_PLUGINS_BINARY` | `test_static_files.py::test_embedded_static_in_plugins_example` |

Properties:
- **Local `pytest` is unchanged** — with no env vars set, every fixture builds via `zig build`/`npm` exactly as today. Zero friction for contributors without artifacts.
- **CI** sets the vars to the downloaded artifact paths, so no rebuild happens in the test jobs.
- The `plugins` embedded-static test, given a prebuilt binary, skips both the `npm` build and the `zig build` (the dist is already embedded), so the `npm`-absent skip-guard becomes moot in CI.

Affected files: `tests/admin/conftest.py`, `tests/admin/test_static_files.py`, `tests/admin/test_custom_route.py`, `tests/admin/test_scheduler.py`, and `tests/smtp/test_smtp_tls.py` (its `binary` fixture also runs `zig build` for the main binary). Because the resolver is shared across both `tests/admin/` and `tests/smtp/`, it lives in a small module importable from both — e.g. `tests/_bin.py` (or a root `tests/conftest.py`) — rather than inside `tests/admin/conftest.py`.

## Warm zig-cache mechanics

- Export `ZIG_GLOBAL_CACHE_DIR=<stable path>` (e.g. `~/.cache/zig-global`) on the `build` and `unit` jobs so all `zig build` invocations share one content-addressed cache.
- `actions/cache@v4`:
  - `path: ~/.cache/zig-global`
  - `key: zig-global-${{ runner.os }}-zig0.16.0-${{ hashFiles('vendor/sqlite/sqlite3.c', 'build.zig', 'build.zig.zon') }}`
  - `restore-keys: zig-global-${{ runner.os }}-zig0.16.0-` (coarser fallback)
- Over-restoring is safe: zig's global cache is content-addressed, so stale entries are ignored and only changed inputs recompile. The coarse `restore-keys` maximizes hit rate while the precise `key` writes a fresh entry when SQLite/build inputs change.
- `build` and `unit` share the same key so whichever finishes first warms it for re-runs.

## Expected outcome

- **No redundant builds**: each binary compiled once in `build`; `browser`/`ts-sdk` consume artifacts.
- **SQLite compiled once per run** (shared global cache), and restored-not-recompiled on warm runs.
- **`browser` critical path** drops from ~270s toward ~150s (loses the ~100s of in-fixture cold rebuilds; gains only artifact download ~5s).
- **`browser`/`ts-sdk` toolchains shrink** to Python+Playwright and Node respectively — no Zig install, matching ZigBase's standalone-binary ethos.

## Risks / open questions (resolve during planning)

1. **Artifact debug vs release** — fixtures currently use `zig build` (debug). Keep the artifacts debug to preserve identical behavior; revisit `-Doptimize` separately.
2. **Cache size** — the zig global cache must stay well under the 10GB repo cache limit; monitor first runs.
3. **`golfsim`** stays a build-only proof in `build` (no test consumer); confirm we still want it on the critical path or move it to a non-blocking proof.
4. **`mise` in test jobs** — `browser`/`ts-sdk` still need `mise` for Python/Node respectively (just not Zig). Confirm `mise.toml` tool resolution doesn't pull Zig implicitly when only Python/Node are exec'd (it shouldn't — `mise exec <tool>` installs on demand).

Resolved during design: vendored SQLite lives at `vendor/sqlite/sqlite3.c` (referenced in `build.zig`); `tests/smtp/test_smtp_tls.py` builds the main binary and is covered by `ZIGBASE_TEST_BINARY`.

## Out of scope

- Playwright container / sidecar (decided against — see Non-goals).
- Release-binary optimization flags, cross-compilation, or changes to `scripts/release.sh`.
- `pages.yml` / `release-sdk.yml` workflows (separate; not part of the test critical path).
