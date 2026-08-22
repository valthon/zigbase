### Internal

- Fixed two bugs that broke `pytest tests/admin` on a fresh local checkout. The
  binary resolver in `tests/_bin.py` always ran the default `zig build` step, so
  fixture servers that only a *named* step installs (`features-fixture`,
  `full-fixture`, `minimal-server`, …) were never produced — 16 errors across
  `test_features.py` and `test_logs.py`. It now builds the step named after the
  binary when the package declares one, and names that step when the binary is
  still missing afterwards. The plugins-frontend build also ran `npm` in
  `examples/plugins/frontend/` (which has no `package.json`) with a `build`
  script that does not exist; it now runs `npm run build:frontend` from
  `examples/plugins/`. Both were invisible in CI, which passes prebuilt binaries
  via the `ZIGBASE_TEST_*_BINARY` overrides.
- Moved the binary-resolver tests to `tests/tools/`, which CI collects. At the
  `tests/` root they were never run by any job — CI names the suite
  subdirectories it collects and never globs `tests/*.py`.
