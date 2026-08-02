# Misleading `failed command` for a successful server-mode test that writes stderr at exit

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

The accompanying candidate patch trims whitespace-only stderr after a clean exit and clears
`result_failed_command` before committing successful test results. It preserves meaningful stderr
and genuine test failures.
