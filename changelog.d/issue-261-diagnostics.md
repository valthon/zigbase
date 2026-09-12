### Changed

- Correct the `zigbase.testing` troubleshooting guidance for Zig 0.16's misleading
  `failed command: ... --listen=-` output. The known case is a successful test process whose
  exit-time stderr newline is rendered with a stale command label, not a test-runner race or
  cross-runner CPU crash. Preserve the supported `zigbase.addTest` build wiring.

### Internal

- Keep a dependency-free Zig+C reproduction and locally tested candidate compiler
  patch, including a passing test whose exit-time destructor terminates by signal.
