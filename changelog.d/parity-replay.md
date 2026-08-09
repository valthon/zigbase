### Features
- Added `tools/replay/zb_replay.py`, a dependency-free parity-replay harness: record a backend's HTTP behaviour, replay it against its replacement, and diff. Matching is a recursive subset with volatile keys (ids, timestamps, tokens) stripped at record time; an expectation of `null` still requires the key to exist, so a migration that silently drops a field is caught rather than passing. Findings are NDJSON, the summary is one JSON object on stdout, and a parity failure exits 2 (a fully-dead replay target exits 1 instead — nothing was actually exercised). See [docs/migration-tools.md](docs/migration-tools.md).

### Internal
- New end-to-end suites `tests/admin/test_schema_cli.py`, `tests/admin/test_import_manifest.py`, `tests/admin/test_legacy_auth.py` and `tests/tools/test_replay.py`; `tests/tools` runs in the `browser` CI job.
