# CI Build-Once Lean Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build each ZigBase binary once in a dedicated CI job, share via artifacts, and run the browser/SDK test jobs against the prebuilt standalone binaries with no Zig/Node toolchain — backed by a shared, persisted zig global cache so the vendored SQLite compiles once.

**Architecture:** Refactor the pytest and TS-SDK test harnesses to consume a prebuilt binary when `ZIGBASE_TEST_*_BINARY` env vars are set, falling back to `zig build` locally. Split CI into `build` (artifacts + warm `ZIG_GLOBAL_CACHE_DIR`), `unit` (`zig build test`), `browser` (needs build), and `ts-sdk` (needs build).

**Tech Stack:** GitHub Actions, `jdx/mise-action@v4`, `actions/cache@v4`, `actions/upload-artifact@v4` / `download-artifact@v4`, Python/pytest/Playwright, Zig 0.16.0, Node 24, vitest.

## Global Constraints

- Zig is pinned to **0.16.0**; always invoke via `mise exec zig@0.16.0 -- zig …`.
- Node is **24** via mise (`mise exec node@24 -- npm …`); do NOT reintroduce `actions/setup-node`.
- Python is **3.13** via mise.
- One env var per binary, shared across Python and TS harnesses: `ZIGBASE_TEST_BINARY` (main `zigbase`), `ZIGBASE_TEST_BLOG_BINARY` (blog), `ZIGBASE_TEST_PLUGINS_BINARY` (plugins).
- Local `pytest`/`npm test` with NO env vars set MUST behave exactly as today (build via zig/npm).
- Vendored SQLite amalgamation lives at `vendor/sqlite/sqlite3.c` (compiled in `build.zig`).
- The `plugins` binary embeds `examples/plugins/frontend/dist` at build time; downstream jobs need only the binary.
- Keep artifacts as **debug** builds (plain `zig build`) — identical to current behavior.

---

### Task 1: Python binary resolver module

**Files:**
- Create: `tests/_bin.py`
- Create: `tests/conftest.py`
- Test: `tests/test_bin_resolver.py`

**Interfaces:**
- Produces:
  - `tests/_bin.py`:
    - `REPO: pathlib.Path` — repo root.
    - `ZIG: list[str]` — `["mise", "exec", "zig@0.16.0", "--", "zig"]`.
    - `resolve_binary(env_var: str, package_dir: pathlib.Path, bin_name: str) -> str` — returns `$env_var` if it points at an existing file; else runs `zig build` in `package_dir` and returns `package_dir/zig-out/bin/bin_name`.
    - `resolve_plugins_binary() -> str | None` — returns `$ZIGBASE_TEST_PLUGINS_BINARY` if it exists; else (npm available) builds `examples/plugins/frontend` then the plugins binary and returns its path; returns `None` if npm is unavailable (caller skips).
  - `tests/conftest.py` puts `tests/` on `sys.path` so `import _bin` resolves from `tests/admin/` and `tests/smtp/`.

- [ ] **Step 1: Create the sys.path bootstrap conftest**

Create `tests/conftest.py`:

```python
# Ensures `import _bin` resolves from tests/admin/ and tests/smtp/ when pytest
# collects those subdirectories. Loaded before any test module under tests/.
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
```

- [ ] **Step 2: Write the failing resolver test**

Create `tests/test_bin_resolver.py`:

```python
import pathlib
import subprocess

import pytest

import _bin


def test_resolve_binary_uses_existing_env_override(tmp_path, monkeypatch):
    fake = tmp_path / "prebuilt-bin"
    fake.write_text("#!/bin/sh\n")
    monkeypatch.setenv("ZIGBASE_TEST_FAKE", str(fake))
    # package_dir is bogus on purpose: a valid override must short-circuit
    # before any build is attempted.
    got = _bin.resolve_binary("ZIGBASE_TEST_FAKE", pathlib.Path("/nonexistent/pkg"), "whatever")
    assert got == str(fake)


def test_resolve_binary_falls_back_to_build_when_override_missing(monkeypatch):
    monkeypatch.setenv("ZIGBASE_TEST_FAKE", "/does/not/exist")
    # Falls through to `zig build` in a dir with no build.zig -> non-zero exit.
    with pytest.raises(subprocess.CalledProcessError):
        _bin.resolve_binary("ZIGBASE_TEST_FAKE", pathlib.Path("/tmp"), "whatever")


def test_resolve_binary_falls_back_when_env_unset(monkeypatch):
    monkeypatch.delenv("ZIGBASE_TEST_FAKE", raising=False)
    with pytest.raises(subprocess.CalledProcessError):
        _bin.resolve_binary("ZIGBASE_TEST_FAKE", pathlib.Path("/tmp"), "whatever")
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mise exec python@3.13 -- python -m pytest tests/test_bin_resolver.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named '_bin'`.

- [ ] **Step 4: Implement `tests/_bin.py`**

Create `tests/_bin.py`:

```python
"""Resolve a ZigBase server/example binary for the test suites.

In CI, prebuilt binaries are passed via ZIGBASE_TEST_*_BINARY env vars so the
tests do not rebuild. Locally (env unset), fall back to `zig build` / `npm`
exactly as before.
"""
import os
import pathlib
import shutil
import subprocess

REPO = pathlib.Path(__file__).resolve().parents[1]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]


def _zig_build(package_dir: pathlib.Path, bin_name: str) -> str:
    subprocess.run(ZIG + ["build"], cwd=package_dir, check=True)
    path = package_dir / "zig-out" / "bin" / bin_name
    assert path.exists(), f"{bin_name} binary missing after build at {path}"
    return str(path)


def resolve_binary(env_var: str, package_dir: pathlib.Path, bin_name: str) -> str:
    """Return the prebuilt binary named by $env_var if it exists, else build it."""
    override = os.environ.get(env_var)
    if override and pathlib.Path(override).exists():
        return override
    return _zig_build(package_dir, bin_name)


def resolve_plugins_binary():
    """The plugins binary embeds frontend/dist at build time.

    Returns the $ZIGBASE_TEST_PLUGINS_BINARY override if it exists; otherwise
    builds the frontend (needs npm) and the binary, returning its path. Returns
    None when npm is unavailable so the caller can pytest.skip().
    """
    override = os.environ.get("ZIGBASE_TEST_PLUGINS_BINARY")
    if override and pathlib.Path(override).exists():
        return override
    if shutil.which("npm") is None:
        return None
    plugins = REPO / "examples" / "plugins"
    fe = plugins / "frontend"
    if not (fe / "dist" / "index.html").exists():
        subprocess.run(["npm", "install", "--no-audit", "--no-fund"], cwd=fe, check=True)
        subprocess.run(["npm", "run", "build"], cwd=fe, check=True)
    return _zig_build(plugins, "plugins")
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mise exec python@3.13 -- python -m pytest tests/test_bin_resolver.py -q`
Expected: PASS (3 passed).

- [ ] **Step 6: Commit**

```bash
git add tests/_bin.py tests/conftest.py tests/test_bin_resolver.py
git commit -m "test: add prebuilt-binary resolver for the test harness"
```

---

### Task 2: Wire the Python fixtures to the resolver

**Files:**
- Modify: `tests/admin/conftest.py` (the `binary` fixture, ~lines 4-13)
- Modify: `tests/admin/test_static_files.py` (3 main-binary build sites + the plugins test)
- Modify: `tests/admin/test_custom_route.py` (~line 11)
- Modify: `tests/admin/test_scheduler.py` (~line 10)
- Modify: `tests/smtp/test_smtp_tls.py` (the `binary` fixture, ~lines 48-53)

**Interfaces:**
- Consumes: `_bin.resolve_binary`, `_bin.resolve_plugins_binary` (Task 1).

- [ ] **Step 1: Update `tests/admin/conftest.py` `binary` fixture**

Replace the `binary` fixture body. Find:

```python
@pytest.fixture(scope="session")
def binary():
    subprocess.run(ZIG + ["build"], cwd=REPO, check=True)
    return str(REPO / "zig-out" / "bin" / "zigbase")
```

Replace with:

```python
@pytest.fixture(scope="session")
def binary():
    return resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
```

Add the import near the top of `tests/admin/conftest.py` (after the existing `import` line):

```python
from _bin import resolve_binary
```

(Leave the existing `REPO` and `ZIG` module constants in place — other helpers may use them.)

- [ ] **Step 2: Update `tests/admin/test_custom_route.py`**

Add after the existing imports:

```python
from _bin import resolve_binary
```

Find:

```python
    subprocess.run(["mise", "exec", "zig@0.16.0", "--", "zig", "build"], cwd=BLOG, check=True)
    blog = BLOG / "zig-out" / "bin" / "blog"
    assert blog.exists()
```

Replace with:

```python
    blog = resolve_binary("ZIGBASE_TEST_BLOG_BINARY", BLOG, "blog")
```

(`blog` is now a `str`; it is already used as `str(blog)` downstream, which is a no-op on a str — leave call sites unchanged.)

- [ ] **Step 3: Update `tests/admin/test_scheduler.py`**

Add after the existing imports:

```python
from _bin import resolve_binary
```

Find:

```python
    subprocess.run(["mise", "exec", "zig@0.16.0", "--", "zig", "build"], cwd=BLOG, check=True)
    blog = BLOG / "zig-out" / "bin" / "blog"
    assert blog.exists()
```

Replace with:

```python
    blog = resolve_binary("ZIGBASE_TEST_BLOG_BINARY", BLOG, "blog")
```

- [ ] **Step 4: Update `tests/admin/test_static_files.py` — main-binary sites**

Add after the existing imports:

```python
from _bin import resolve_binary, resolve_plugins_binary
```

There are two occurrences of this pair (in `test_serve_static_runtime_mode` and `test_serve_static_missing_dir_is_fatal`):

```python
    subprocess.run(ZIG + ["build"], cwd=REPO, check=True)
    binary = REPO / "zig-out" / "bin" / "zigbase"
```

Replace BOTH with:

```python
    binary = resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
```

(`binary` becomes a `str`; downstream uses `str(binary)` / `[str(binary), ...]`, which are no-ops on a str.)

- [ ] **Step 5: Update `tests/admin/test_static_files.py` — plugins test**

Find the head of `test_embedded_static_in_plugins_example`:

```python
def test_embedded_static_in_plugins_example():
    if shutil.which("npm") is None:
        pytest.skip("npm not available; cannot build the plugins frontend")
    plugins = REPO / "examples" / "plugins"
    fe = plugins / "frontend"
    if not (fe / "dist" / "index.html").exists():
        subprocess.run(["npm", "install", "--no-audit", "--no-fund"], cwd=fe, check=True)
        subprocess.run(["npm", "run", "build"], cwd=fe, check=True)
    subprocess.run(ZIG + ["build"], cwd=plugins, check=True)
    binary = plugins / "zig-out" / "bin" / "plugins"
```

Replace with:

```python
def test_embedded_static_in_plugins_example():
    binary = resolve_plugins_binary()
    if binary is None:
        pytest.skip("npm not available and no prebuilt plugins binary; cannot build the plugins frontend")
```

The `shutil.which` call moved into `_bin.resolve_plugins_binary`, so `shutil` is now unused in `test_static_files.py`. If a linter flags it, drop `shutil` from the top-of-file import; otherwise leaving it is harmless.

- [ ] **Step 6: Update `tests/smtp/test_smtp_tls.py` `binary` fixture**

Add after the existing imports:

```python
from _bin import resolve_binary
```

Find:

```python
@pytest.fixture(scope="session")
def binary():
    subprocess.run(ZIG + ["build"], cwd=REPO, check=True)
    path = REPO / "zig-out" / "bin" / "zigbase"
    assert path.exists(), "zigbase binary missing after build"
    return str(path)
```

Replace with:

```python
@pytest.fixture(scope="session")
def binary():
    return resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")
```

- [ ] **Step 7: Verify the override path (no rebuild) locally**

Build the main + blog binaries once, then run a fast subset with the env vars pointed at them and confirm the tests pass without rebuilding:

```bash
mise exec zig@0.16.0 -- zig build
cd examples/blog && mise exec zig@0.16.0 -- zig build && cd ../..
ZIGBASE_TEST_BINARY="$PWD/zig-out/bin/zigbase" \
ZIGBASE_TEST_BLOG_BINARY="$PWD/examples/blog/zig-out/bin/blog" \
  mise exec python@3.13 -- python -m pytest tests/admin/test_custom_route.py tests/admin/test_scheduler.py -q
```

Expected: PASS. (To confirm no rebuild happens, the run should not print zig build output.)

- [ ] **Step 8: Verify the local fallback path still works**

Run one admin test with NO env vars set; it must build via zig exactly as before:

```bash
env -u ZIGBASE_TEST_BINARY -u ZIGBASE_TEST_BLOG_BINARY -u ZIGBASE_TEST_PLUGINS_BINARY \
  mise exec python@3.13 -- python -m pytest tests/admin/test_custom_route.py -q
```

Expected: PASS (builds blog via zig, then runs).

- [ ] **Step 9: Commit**

```bash
git add tests/admin/conftest.py tests/admin/test_static_files.py tests/admin/test_custom_route.py tests/admin/test_scheduler.py tests/smtp/test_smtp_tls.py
git commit -m "test: consume prebuilt binaries via ZIGBASE_TEST_*_BINARY env vars"
```

---

### Task 3: Wire the TS-SDK integration harness to the same env var

**Files:**
- Modify: `clients/typescript/test/integration/harness.ts:11,19-29`

**Interfaces:**
- Consumes: `ZIGBASE_TEST_BINARY` env var (same name as the Python suite).

- [ ] **Step 1: Honor the prebuilt binary path**

In `clients/typescript/test/integration/harness.ts`, find:

```typescript
const BIN = join(REPO_ROOT, "zig-out", "bin", "zigbase");
```

Replace with:

```typescript
// CI supplies a prebuilt binary via ZIGBASE_TEST_BINARY; otherwise use the
// zig-out path produced by ensureBuilt()'s `zig build`.
const BIN = process.env.ZIGBASE_TEST_BINARY ?? join(REPO_ROOT, "zig-out", "bin", "zigbase");
```

- [ ] **Step 2: Skip the build when a prebuilt binary is provided**

Find:

```typescript
let built = false;
function ensureBuilt(): void {
  if (built) return;
  // The binary MUST be built with zig 0.16.0; plain `zig` on PATH may be older.
  const r = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], {
    cwd: REPO_ROOT,
    stdio: "inherit",
  });
  if (r.status !== 0) throw new Error("zig build failed");
  built = true;
}
```

Replace with:

```typescript
let built = false;
function ensureBuilt(): void {
  if (built) return;
  // A prebuilt binary supplied via ZIGBASE_TEST_BINARY (e.g. a CI artifact)
  // skips the build entirely — no Zig toolchain needed in that job.
  if (process.env.ZIGBASE_TEST_BINARY) {
    built = true;
    return;
  }
  // The binary MUST be built with zig 0.16.0; plain `zig` on PATH may be older.
  const r = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], {
    cwd: REPO_ROOT,
    stdio: "inherit",
  });
  if (r.status !== 0) throw new Error("zig build failed");
  built = true;
}
```

- [ ] **Step 3: Verify the prebuilt path runs the SDK integration tests**

```bash
mise exec zig@0.16.0 -- zig build
cd clients/typescript && mise exec node@24 -- npm ci
ZIGBASE_TEST_BINARY="$PWD/../../zig-out/bin/zigbase" mise exec node@24 -- npm run test:integration
```

Expected: integration tests PASS, launching the prebuilt binary (no `zig build` output during the run).

- [ ] **Step 4: Commit**

```bash
git add clients/typescript/test/integration/harness.ts
git commit -m "test(sdk): honor ZIGBASE_TEST_BINARY to skip the zig build in CI"
```

---

### Task 4: Restructure the CI workflow (build-once + warm zig-cache)

**Files:**
- Modify: `.github/workflows/ci.yml` (replace entire file)

**Interfaces:**
- Consumes: the env-var contract from Tasks 1-3.

- [ ] **Step 1: Replace `.github/workflows/ci.yml`**

Write the full file:

```yaml
name: CI
on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    env:
      ZIG_GLOBAL_CACHE_DIR: ${{ github.workspace }}/.zig-global
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v4
      # Shared, persisted zig global cache: the vendored SQLite amalgamation
      # compiles once and is reused across main/blog/plugins and across runs.
      - name: Cache zig global cache
        uses: actions/cache@v4
        with:
          path: ${{ github.workspace }}/.zig-global
          key: zig-global-${{ runner.os }}-zig0.16.0-${{ hashFiles('vendor/sqlite/sqlite3.c', 'build.zig', 'build.zig.zon') }}
          restore-keys: zig-global-${{ runner.os }}-zig0.16.0-
      - name: Cache npm downloads
        uses: actions/cache@v4
        with:
          path: ~/.npm
          key: npm-${{ runner.os }}-${{ hashFiles('**/package-lock.json') }}
          restore-keys: npm-${{ runner.os }}-
      - name: Build plugins example frontend (embedded into the plugins binary)
        run: cd examples/plugins/frontend && mise exec node@24 -- npm ci --no-audit --no-fund && mise exec node@24 -- npm run build
      - name: Build main zigbase binary
        run: mise exec zig@0.16.0 -- zig build
      - name: Build blog example consumer (dependency-graph proof)
        run: cd examples/blog && mise exec zig@0.16.0 -- zig build
      - name: Build golfsim example consumer (realistic app)
        run: cd examples/golfsim && mise exec zig@0.16.0 -- zig build
      - name: Build plugins example consumer (advanced framework surface)
        run: cd examples/plugins && mise exec zig@0.16.0 -- zig build
      - name: Upload prebuilt binaries
        uses: actions/upload-artifact@v4
        with:
          name: zigbase-binaries
          path: |
            zig-out/bin/zigbase
            examples/blog/zig-out/bin/blog
            examples/plugins/zig-out/bin/plugins
          if-no-files-found: error
          retention-days: 1

  unit:
    runs-on: ubuntu-latest
    env:
      ZIG_GLOBAL_CACHE_DIR: ${{ github.workspace }}/.zig-global
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v4
      - name: Cache zig global cache
        uses: actions/cache@v4
        with:
          path: ${{ github.workspace }}/.zig-global
          key: zig-global-${{ runner.os }}-zig0.16.0-${{ hashFiles('vendor/sqlite/sqlite3.c', 'build.zig', 'build.zig.zon') }}
          restore-keys: zig-global-${{ runner.os }}-zig0.16.0-
      - name: Unit tests
        run: mise exec zig@0.16.0 -- zig build test --summary all

  browser:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v4
      - name: Download prebuilt binaries
        uses: actions/download-artifact@v4
        with:
          name: zigbase-binaries
          path: artifacts
      - name: Export prebuilt binary paths
        run: |
          chmod +x artifacts/zig-out/bin/zigbase \
                   artifacts/examples/blog/zig-out/bin/blog \
                   artifacts/examples/plugins/zig-out/bin/plugins
          echo "ZIGBASE_TEST_BINARY=$GITHUB_WORKSPACE/artifacts/zig-out/bin/zigbase" >> "$GITHUB_ENV"
          echo "ZIGBASE_TEST_BLOG_BINARY=$GITHUB_WORKSPACE/artifacts/examples/blog/zig-out/bin/blog" >> "$GITHUB_ENV"
          echo "ZIGBASE_TEST_PLUGINS_BINARY=$GITHUB_WORKSPACE/artifacts/examples/plugins/zig-out/bin/plugins" >> "$GITHUB_ENV"
      - name: Install Python test deps + resolve Playwright version
        id: pw
        run: |
          mise exec python@3.13 -- python -m pip install --quiet pytest playwright aiosmtpd
          echo "version=$(mise exec python@3.13 -- python -c 'import importlib.metadata as m; print(m.version("playwright"))')" >> "$GITHUB_OUTPUT"
      - name: Cache Playwright browser (chromium headless shell)
        id: pw-cache
        uses: actions/cache@v4
        with:
          path: ~/.cache/ms-playwright
          key: ${{ runner.os }}-playwright-${{ steps.pw.outputs.version }}-chromium-shell
      - name: Install Chromium headless shell + OS deps (cache miss)
        if: steps.pw-cache.outputs.cache-hit != 'true'
        run: mise exec python@3.13 -- python -m playwright install --with-deps --only-shell chromium
      - name: Install Playwright OS deps (cache hit)
        if: steps.pw-cache.outputs.cache-hit == 'true'
        run: mise exec python@3.13 -- python -m playwright install-deps chromium
      - name: Headless browser tests
        run: mise exec python@3.13 -- python -m pytest tests/admin -q
      - name: Live SMTP-over-TLS (STARTTLS) delivery test
        run: mise exec python@3.13 -- python -m pytest tests/smtp -q

  ts-sdk:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v4
      - name: Download prebuilt binaries
        uses: actions/download-artifact@v4
        with:
          name: zigbase-binaries
          path: artifacts
      - name: Export prebuilt binary path
        run: |
          chmod +x artifacts/zig-out/bin/zigbase
          echo "ZIGBASE_TEST_BINARY=$GITHUB_WORKSPACE/artifacts/zig-out/bin/zigbase" >> "$GITHUB_ENV"
      - name: Cache npm downloads
        uses: actions/cache@v4
        with:
          path: ~/.npm
          key: npm-${{ runner.os }}-${{ hashFiles('**/package-lock.json') }}
          restore-keys: npm-${{ runner.os }}-
      - name: Install SDK deps
        working-directory: clients/typescript
        run: mise exec node@24 -- npm ci || mise exec node@24 -- npm install
      - name: Typecheck
        working-directory: clients/typescript
        run: mise exec node@24 -- npm run typecheck
      - name: Unit tests
        working-directory: clients/typescript
        run: mise exec node@24 -- npm test
      - name: Integration tests
        working-directory: clients/typescript
        run: mise exec node@24 -- npm run test:integration
```

- [ ] **Step 2: Validate YAML locally**

Run:

```bash
mise exec python@3.13 -- python -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print('jobs:', list(d['jobs'].keys()))"
```

Expected: `jobs: ['build', 'unit', 'browser', 'ts-sdk']`.

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build binaries once and share via artifacts; warm shared zig cache"
git push -u origin ci-build-once-lean-split
```

- [ ] **Step 4: Verify CI is green and confirm the wins**

After the run completes:

```bash
gh pr checks <PR#>
```

Expected: `build`, `unit`, `browser`, `ts-sdk` all pass. Then confirm via step timings that (a) the `browser`/`ts-sdk` jobs no longer run `zig build` inside tests, and (b) the `build` job's blog/plugins steps are fast (shared global cache):

```bash
gh api repos/valthon/zigbase/actions/jobs/<build-job-id> --jq '.steps[] | "\(.name): \((((.completed_at|fromdateiso8601) - (.started_at|fromdateiso8601)))|floor)s"'
```

Expected: blog/plugins build steps single-digit seconds (vs ~14-15s cold-each); browser/ts-sdk total wall-clock noticeably lower than the previous run.

---

## Notes for the executor

- **Do not** reintroduce `actions/setup-node` — Node comes from mise (`node@24`).
- The `build` and `unit` jobs intentionally share the same `actions/cache` key; whichever finishes first warms the cache, and a concurrent "cache already exists" warning is harmless.
- `upload-artifact@v4` preserves the directory structure from the least-common-ancestor (the workspace root), so the download lands at `artifacts/zig-out/bin/zigbase`, `artifacts/examples/blog/...`, `artifacts/examples/plugins/...` — the paths the Export steps reference. `chmod +x` after download guards against the exec bit being dropped in transit.
- If the `browser` job's plugins test errors with a missing dist at runtime, that's a regression — the plugins binary must embed `frontend/dist` at build time in the `build` job (it does, because the frontend build step precedes the plugins zig build).
```
