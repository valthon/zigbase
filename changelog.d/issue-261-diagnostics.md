### Documentation

- Correct the `zigbase.testing` troubleshooting guidance for Zig 0.16's misleading
  `failed command: ... --listen=-` output. The known case is a successful test process whose
  exit-time stderr newline is rendered with a stale command label, not a test-runner race or
  cross-runner CPU crash. Add a standalone upstream reproduction and diagnostic tooling.
