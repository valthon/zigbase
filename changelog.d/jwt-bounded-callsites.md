### Internal

- Convert the two JWT verification call sites whose claims are consumed internally
  (`auth.authenticate`, `api/auth.carrySessionCreated`) from the arena-scoped
  `peekClaims` to the caller-buffer `peekClaimsInto`, removing an allocation from the
  per-request auth path. The remaining four sites return borrowed claims and stay on the
  arena (safely bounded by `jwt.max_token_len`). `carrySessionCreated` drops its now-unused
  allocator parameter. In `authenticate` the peek is scoped to a block so the stack-borrowed
  claims cannot escape into the returned `Authed` — a compiler-enforced guard rather than a
  prose one.
