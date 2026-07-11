### Features
- Vendored/native component versions (SQLite, sqlite-vec, zap, facil.io, zigbase) are now
  discoverable via `zig build versions`, the enriched `--version` output + a startup log line,
  and a `versions` object on `GET /api/health`.

### Security
- `zig build audit` compares pinned dependency versions against a curated in-repo advisory
  table (`docs/security-advisories.md`); documented update process for vendored C security fixes.
