### Features
- `zigbase init` scaffolds a starting-point project in one command — `--box` (no Zig toolchain: `docker-compose.yml`, a schema starting point plus an apply script, `AGENTS.md`/`CLAUDE.md`, `.gitignore`, `README.md`) or `--framework` (a Zig package with `build.zig`, `build.zig.zon`, a comptime schema, and in-process tests already wired). Existing files are never overwritten — they are reported as skipped, and there is no `--force`. Reachable with no install at all via `npx zigbase init`.
- `zigbase agents-md` writes a trap-oriented `AGENTS.md` (plus a one-line `CLAUDE.md`) into a project that already exists, inferring box vs framework content from the directory. `--stdout` prints instead of writing, for diffing.
- New build helpers on ZigBase's `build.zig`, usable from a consumer's `build.zig` via `@import("zigbase")`: `addTo(dep, mod)` adds the `zigbase` import **and** sets `link_libc` together, so the two cannot drift apart; `addTest(b, dep, .{ .root_module = … })` creates a test artifact wired with a `.simple`-mode test runner ZigBase now ships, which avoids the upstream Zig 0.16 `--listen=-` build-runner race and fails the build on a leaked allocation.
- New docs: [Testing](https://valthon.github.io/zigbase/docs/testing) — which test surface covers what, the build wiring, and what an in-process test structurally cannot see; and [For coding agents](https://valthon.github.io/zigbase/docs/agents) — a ~2k-token entry point.
- The docs site now publishes `llms.txt` and a machine-readable `docs-index.json`, both generated from the same registry that drives the published pages.

### Changed
- `docs/framework.md` §2 and the README now lead with `zigbase.addTo` instead of a separate `addImport` + "remember `link_libc`" pair, and §15 hands out `zigbase.addTest` in place of the previous advice to copy Zig's own test runner into your project.
- The `recipes.md` testing recipe now teaches `zigbase.testing` (in-process, `StartOptions`-based determinism, `captureMail`). The process-global `zigbase.testcapture` seam is still documented, under a heading that says it is for a spawned server.

### Internal
- `examples/blog` gained a `zig build test` step using `zigbase.testing`, and its `App` is hoisted to a `pub const` so tests can reach it; the step runs in CI. Its vitest e2e stays — it is the only end-to-end coverage of `@zigbase/client` over a real socket.
- `tests/admin/test_docs_parity.py` now fails when a `docs/*.md` is only half-registered on the site (registry, the mirror generator's `PUBLISHED` set, `site/.gitignore`, and the sidebar must agree).
