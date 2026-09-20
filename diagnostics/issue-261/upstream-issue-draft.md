# Misleading `failed command` for a successful server-mode test that writes stderr at exit

This is retained local investigation material, not a claim that an upstream issue
has been filed. The runnable package and current verification driver are linked
from [README.md](README.md); the snippet below is the smallest original case.

## Zig version

0.16.0

## Summary

`zig build test` prints `failed command: .../test ... --listen=-` when a successful server-mode
test writes a single newline to stderr during process destruction. The test result is `pass`, the
child exits 0, the build exits 0, and the final summary says every test passed.

The message looks like a test crash and has led downstream users to diagnose a nonexistent
test-runner race.

## Minimal reproduction

`build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    mod.addCSourceFile(.{ .file = b.path("newline_destructor.c") });
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
```

`test.zig`:

```zig
const std = @import("std");

test "pass" {
    try std.testing.expect(true);
}
```

`newline_destructor.c`:

```c
#include <stdio.h>

__attribute__((destructor)) static void newline_at_exit(void) {
    fputc('\n', stderr);
}
```

Run `zig build test --summary all`.

## Actual output

```text
test
+- run test w

failed command: .../test ... --listen=-

Build Summary: 3/3 steps succeeded; 1/1 tests passed
test success
+- run test 1 pass (1 total)
```

The shell exit status is 0.

## Instrumented result

Instrumentation in `std.Build.Step.Run.evalZigTest` records:

```text
received test_results index=0 status=pass
requestNextTest: all tests done; sending exit
waitZigTest=no_poll active_test_index=null stdout_buffered=0 stderr_buffered=1
child.wait term=exited with code 0
```

`strace -ff -e trace=process` likewise shows exactly one test process and `wait4` reporting
`WIFEXITED` with status 0.

The behavior comes from two pieces of state retained after successful completion:

1. whitespace-only stderr is copied into `run.step.result_stderr`, causing the build runner to
   render a warning block;
2. `run.step.result_failed_command` still contains the command prepared before spawning, so the
   warning renderer labels the successful command as failed.

## Expected behavior

Whitespace-only stderr after a clean test exit should not produce a warning. If meaningful stderr
is retained and displayed for a successful test, it should not be followed by `failed command`.

The accompanying candidate patch trims whitespace-only stderr and clears
`result_failed_command` only when tests are done, the child exited 0, and test
results are successful. Its three-line context shows that guard before the
existing unexpected-exit failure branch. It preserves meaningful stderr, genuine
test failures, and a passing test followed by SIGSEGV from a C destructor.

## Historical downstream measurements (2026-08-02)

The former ZigBase consumer reproduction ran on WSL2, Linux 6.18, an Intel
i9-13900K, and Zig 0.16.0. These are point-in-time observations, not a current
performance contract or a requirement to repeat load generation.

| Build | Runs | Printed `failed command` | Nonzero build exits |
| --- | ---: | ---: | ---: |
| native, idle | 50 | 50 | 0 |
| `-Dcpu=baseline`, idle | 50 | 50 | 0 |
| native, 30 CPU load workers | 30 | 30 | 0 |
| `-Dcpu=baseline`, 30 CPU load workers | 30 | 30 | 0 |

Native and baseline artifacts differed. Disassembly found YMM instructions in
native `compiler_rt.memcpy.memcpyFast` but not baseline, establishing that the
CPU control took effect without changing the symptom. A no-app-boot control
referencing one facil.io symbol also reproduced it. Suppressing facil.io's
exit-time newline removed the warning. Those historical consumer/load artifacts
remain in PR #355's original Git history; the maintained package has no ZigBase
dependency.
