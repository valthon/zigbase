### Internal

- Gave the compiled access-rule `Guard` (`records.zig`) a self-contained ownership contract: a new
  `Guard.own` deep-clones `where_sql` + `joins` + `params` onto one allocator and `Guard.deinit`
  frees it, so a Guard no longer aliases the joiner's scratch, a borrowed ability/tenant param, or a
  `dialect.constFalse()` literal. `rules.compileGuard` and `policy.compilePredicate` now build their
  lexer/AST/joiner and the whole ability+tenant composition on a function-local arena and return an
  `own`-built Guard (contract-2) — self-freeing under any allocator, not just when the caller passes
  a request/rule arena (as every in-tree call site does, so deployed servers were unaffected). This
  un-masks `policy.zig`'s 7 arena-masked tests, which now run under the raw `std.testing.allocator`
  (`policy.zig` removed from `scripts/allocator-allowlist.txt`).
