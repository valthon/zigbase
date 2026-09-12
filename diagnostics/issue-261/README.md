# Issue 261: misleading successful-test diagnostics

`upstream-minimal/` is a dependency-free Zig+C reproduction for Zig 0.16.0.
Its default test passes, then a C destructor writes a newline to stderr.
The stock server-mode build runner exits 0 but prints `failed command:` because
it retains both the whitespace and a command label prepared before spawning.
No ZigBase, facil.io, SQLite, application boot or load generation is required.

```sh
cd diagnostics/issue-261/upstream-minimal
mise exec zig@0.16.0 -- zig build test --summary all
```

The final summary and process exit status determine whether the build failed.
Do not dismiss real assertion failures, signals or nonzero exits as this cosmetic
case. ZigBase consumers should keep using `zigbase.addTest`, which wires the
supported simple runner; do not copy a compiler runner into the application.

## Candidate patch regression

From the repository root:

```sh
mise exec zig@0.16.0 python@3.13 -- python diagnostics/issue-261/verify.py
```

The driver requires Linux/macOS, Python, `patch` and exactly Zig 0.16.0. It copies
Zig's library into a private temporary directory, checks both patch files apply,
applies only the candidate diagnostic patch there, and runs four cases against
the stock and copied libraries. The installed compiler is never modified.
Pass `--zig /absolute/path/to/zig` or `--zig-lib-dir /path/to/lib` for a
nonstandard installation. Temporary libraries and caches are removed afterward;
allow disk space for a compiler-library copy and build artifacts. Each child
command has a 120-second timeout, not a hard bound on disk or process memory.

| Case (`-Dcase=`) | Build exit | Candidate behavior |
| --- | --- | --- |
| `newline` (default) | 0 | Suppress whitespace-only stderr and stale command label. |
| `meaningful` | 0 | Preserve stderr text without calling the command failed. |
| `assertion` | 1 | Preserve assertion diagnostics and failed command. |
| `signal` | 1 | Test passes, destructor raises SIGSEGV; preserve process failure and command. |

The candidate's explicit guard requires all tests done, child exit 0 **and**
successful test results before removing anything. In particular, completing the
test protocol alone does not prove that process destruction succeeded.
`zig-runner-instrumentation.patch` is an optional investigation aid, not the fix.
No patch is installed by ZigBase's application build or release.

Historical host measurements belong in [the upstream draft](upstream-issue-draft.md),
not in the reproducer's guarantees. The older ZigBase-specific consumer and load
matrix were removed; PR #355's original Git history retains that evidence.
The draft is local material only; this cleanup does not file an upstream issue.
