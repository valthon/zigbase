# Test-runner feedback regression

Run with the pinned compiler and Python:

```sh
mise exec zig@0.16.0 python@3.13 -- python tests/test_runner/verify.py
```

The driver copies the dependency-free fixture and current `src/simple_runner.zig`
into a temporary directory, then runs seven cases with each runner. It uses a
private cache, no package dependencies, two compiler workers, and a 120-second
limit per build. Deliberate signals cannot create core dumps. Linux and macOS
are supported; no installed compiler or source file is modified.

| Case | Exit | Required evidence |
| --- | --- | --- |
| Destructor newline | 0 | Stock runner prints stale `failed command`; simple runner does not |
| Meaningful destructor stderr | 0 | Message survives; same label distinction |
| Assertion failure | 1 | Assertion diagnostic and failed command |
| Test passes, destructor raises SIGSEGV | 1 | Signal diagnostic and failed command |
| Allocation leak | 1 | Leak diagnostic and failed command |
| Logged error | 1 | Error message and failed command |
| Skipped test | 0 | Skip count; same label distinction |

The newline is sufficient to reproduce the Zig 0.16.0 diagnostic. It does not
prove a race or explain any nonzero build exit. The regression never suppresses
output or turns failed executions into success. Any unexpected case aborts with
the captured stdout/stderr. CI runs it in the contracts job.

The minimal Zig+C reproduction was recovered from
[PR #355, commit 64c16806](https://github.com/valthon/zigbase/pull/355), following the
corrected diagnosis in [#261](https://github.com/valthon/zigbase/issues/261).
This extends that fixture to test the supported ZigBase runner and its failure
contracts. PR #355's private compiler patch and historical stress measurements
remain separate investigation work; this regression does not apply that patch
or claim the upstream compiler bug is fixed.
