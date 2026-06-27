### Changed

- `before*` record hooks now run INSIDE the triggering write's transaction on the
  HTTP create/update/delete path. A hook's side-writes (via `ev.data` /
  `ev.caps().records()`) and the primary row write now commit atomically, and a
  before-hook that returns an error — or a denied access-rule guard — rolls the
  whole transaction back, so a rejected write persists nothing (fail closed).
  Previously a before-hook side-write committed independently, before the
  triggering write.
