# Plan — Theme B3: KV/Settings Store (#87) + Feature Flags (#88)

Design: `docs/superpowers/specs/2026-06-27-theme-b3-kv-flags-design.md`.

Strict TDD: write a failing test, see it fail, implement, see it pass, commit.
Verify gate: `mise exec zig@0.16.0 -- zig build test --summary all` →
`Build Summary: N/N tests passed`.

## Task 1 — `_kv` system table (migration `0009_kv`)
- [ ] Test (migrations.zig): after `run`, `pragma_table_info('_kv')` has 4 columns
      (`key`,`value`,`created`,`updated`); `_migrations` count == `all.len`.
- [ ] Implement `init_0009_kv` + add `.{ .name = "0009_kv", .up = init_0009_kv }`
      to `all`.
- [ ] Build test → pass. Commit.

## Task 2 — Data KV core (`kvGet`/`kvSet`/`kvDelete`)
- [ ] Test (data.zig): set→get round-trip; missing key → null; set twice updates
      value AND preserves `created`; delete removes + returns existence.
- [ ] Implement the three methods on `Data` (prepare/bind/step/finalize idioms;
      `kvGet` dupes onto `self.alloc`; `kvSet` ON CONFLICT preserves created;
      `kvDelete` uses `changesCount`).
- [ ] Build test → pass. Commit.

## Task 3 — ctx.kv + ctx.flag/setFlag
- [ ] Test (ctx.zig, CtxTestEnv): ctx.kv set/get round-trip; flag set→true,
      unset→false; setFlag toggles; works inside ctx.tx (bound_conn).
- [ ] Implement `KeyValue` namespace + `kv()`, `flag()`, `setFlag()` on `Ctx`
      (reads via connForRead; writes via bound_conn-else-writer, like Records.create).
- [ ] Build test → pass. Commit.

## Task 4 — Docs + example + changelog
- [ ] `docs/framework.md`: KV/settings + feature-flags section.
- [ ] Mirror into `site/src/content/docs/framework.md`.
- [ ] Build site (`cd site && npm run build`).
- [ ] Demonstrate in an example (examples/plugins or golfsim) keeping it building.
- [ ] `changelog.d/theme-b3-kv-flags.md` (`### Features`).
- [ ] Commit.

## Task 5 — (Cheap-if-feasible) superuser HTTP settings API
- [ ] Evaluate router.zig/api wiring cost. If clean+small: add
      `GET /api/settings`, `GET/PUT/DELETE /api/settings/:key` (superuser-only) +
      browser test. Else: defer, document custom-route pattern only, note in report.

## Finish
- [ ] Full `zig build test --summary all` green.
- [ ] Browser suite if HTTP path touched (else attempt/report).
- [ ] Push `feat/theme-b3-kv-flags`, open PR (#87, #88). Do NOT merge.
