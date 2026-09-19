### Changed

- Correct test-runner guidance: Zig 0.16.0 can label successful exit-time stderr as a failed command; check exit status and the build summary, and use `zigbase.addTest` for consumer apps.

### Internal

- Exercise default and shipped simple test runners in CI against successful stderr, skips, assertions, leaks, logged errors, and post-test signals without patching the compiler.
