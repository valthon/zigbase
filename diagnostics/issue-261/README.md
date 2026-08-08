# Issue 261 diagnostic reproduction

This directory preserves two reproductions for the misleading Zig 0.16 test-runner output tracked
in issue 261:

- the original `zigbase.testing.start` consumer reproduction (`zig build test`);
- `upstream-minimal/`, an independent one-test Zig+C package whose only unusual behavior is an
  exit-time newline written to stderr.

Both packages pass their test and exit 0, but unmodified Zig 0.16.0 prints:

```text
test
+- run test w

failed command: .../test ... --listen=-

Build Summary: ... steps succeeded; 1/1 tests passed
```

The final build summary and process exit status are authoritative. In this reproduction, `failed
command` does not mean the test child failed.

## Results captured 2026-08-02

The consumer reproduction was run on WSL2, Linux 6.18, an Intel i9-13900K, and Zig 0.16.0.

| Build | Runs | Printed `failed command` | Nonzero build exits |
| --- | ---: | ---: | ---: |
| native, idle | 50 | 50 | 0 |
| `-Dcpu=baseline`, idle | 50 | 50 | 0 |
| native, 30 CPU load workers | 30 | 30 | 0 |
| `-Dcpu=baseline`, 30 CPU load workers | 30 | 30 | 0 |

The native and baseline test binaries had different SHA-256 hashes. Disassembly of
`compiler_rt.memcpy.memcpyFast` found YMM instructions in the native binary and none in the
baseline binary, confirming that the CPU control took effect. It did not alter the symptom.

`strace -ff -e trace=process` captured exactly one test-child `execve` and this wait result:

```text
wait4(<test-pid>, [{WIFEXITED(s) && WEXITSTATUS(s) == 0}], ...) = <test-pid>
```

Applying `zig-runner-instrumentation.patch` to a copy of Zig's `lib/` directory showed this state
sequence:

```text
received test_results index=0 status=pass
requestNextTest: all tests done; sending exit
waitZigTest=no_poll active_test_index=null stdout_buffered=0 stderr_buffered=1
child.wait term=exited with code 0
```

The single buffered byte is facil.io's `fio_lib_destroy` newline. Suppressing only that `fprintf`
made the warning block disappear. The no-harness `zig build control` target reproduces the output
as soon as it references one facil.io symbol, so app/SQLite boot latency is not required.

The independent `upstream-minimal` package proves the behavior without zigbase or facil.io:

```sh
cd upstream-minimal
zig build test --summary all
echo "$?" # 0
```

`upstream-issue-draft.md` contains a ready-to-file upstream report based on that reproducer.

## Candidate Zig fix

`zig-runner-diagnostic-fix.patch` does two things after a clean server-mode test exit:

1. discards stderr consisting only of ASCII whitespace;
2. clears `result_failed_command`, because the command did not fail.

It was verified against three cases:

- newline-only stderr: clean success output, exit 0;
- meaningful `diagnostic\n` stderr: warning and text retained, no false `failed command`, exit 0;
- a genuinely failing test: test diagnostics retained, build exits 1.

To instrument or test the patch without modifying an installed Zig:

```sh
cp -a "$(zig env | sed -n 's/.*\.lib_dir = "\([^"]*\)".*/\1/p')" /tmp/zig-lib-issue261
cd /tmp/zig-lib-issue261
patch -p1 < /path/to/zig-runner-instrumentation.patch
ZIG_LIB_DIR=/tmp/zig-lib-issue261 zig build test --summary all
```

`run-matrix.sh` automates the native/baseline and optional loaded runs while recording every build
log beneath a temporary results directory.
