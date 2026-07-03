### Internal

- Parallelized the Playwright/browser test suite (`tests/admin/`) with pytest-xdist (`-n auto`) in CI and reworked the harness fixtures to reuse a per-worker Chromium browser and a template superuser data dir, cutting the suite's serial wall time (~4:53) to ~18s on a 32-core box. No consumer-visible change.
