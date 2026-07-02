### Features

- SPA fallback routing (#183): a presence-only `.spa` marker file makes its static
  directory an SPA root — GET/HEAD misses at or below it serve that directory's
  `index.html` (200), so client-routed apps survive deep links and hard refreshes.
  Works for both `--serve-static`/`.dir` trees and embedded manifests; real files,
  `/api`, admin, and custom routes always win. In **dir** mode the marker is
  resolved **live** against the filesystem on every miss — adding, removing, or
  editing a `.spa`/`index.html` takes effect on the next request, no restart needed;
  startup only fails fast (with a clear, path-naming error) when a `.spa`-marked
  directory has no `index.html`, and an unreadable subdirectory is skipped with a
  warning rather than aborting boot. **Embedded** manifests keep a startup-derived,
  comptime-static marker set (there's no live filesystem to go stale).
- Comptime `static_routes` for custom builds (#183): declare `match → serve`
  rewrites on `App(.{ .static_routes = &.{...} })` with minimal segment matching
  (`:name` one segment, `*` one-or-more rest, `**` zero-or-more rest; first match
  wins). Patterns and embedded serve targets are validated at compile time; dir
  targets at startup. A new `enable_spa_marker` key gates the marker (default: on
  without routes, off with routes).

### Changed

- A static file literally named `.spa` is no longer servable (it now denotes an SPA
  root and falls through to the fallback/404); the check is ASCII case-insensitive
  on the request path, so it holds on case-insensitive filesystems too. Other
  dotfiles are unaffected (#183).

### Fixes

- The `/api` namespace is now refused a second time on the sanitized/normalized
  path inside the static fallback, so a raw double-slash (`//api/x`) can't bypass
  the raw-path `/api` gate and reach a fallback document (#183).
