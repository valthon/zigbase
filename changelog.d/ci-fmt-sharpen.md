### Internal

- CI now enforces formatting: a `zig fmt --check src build.zig` gate in the `unit` job fails the build on any unformatted file, paired with a one-shot tree-wide `zig fmt` sweep so the tree starts clean.
- Scoped the `zig-local-*` build/test caches by branch (`github.ref_name` folded into both the `key:` and `restore-keys:` prefixes of every job) so one branch can no longer restore and reference another branch's cached objects — the cross-branch cache poisoning that surfaced a phantom symbol error in unrelated CI. The content-hash-keyed `zig-global-*` caches stay shared.
