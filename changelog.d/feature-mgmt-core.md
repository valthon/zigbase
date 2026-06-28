### Breaking

- **Feature flags are now declared-only.** Flags must be declared in the `App(.{ .flags = .{ … } })` literal; only declared flags resolve. The v0.7 runtime-string API `ctx.flag("arbitrary")` (KV-or-false) has been **removed** — use the typed `App.flag(ctx, .name)` for known flags, or `ctx.flagByName("name")` (returns `?bool`, null when undeclared) for dynamic names.
- **`ctx.setFlag` now writes a declared-flag override.** It writes the `flag:<name>` override key for a DECLARED flag and errors `error.UndeclaredFlag` otherwise (the typed, compile-checked form is `App.setFlag(ctx, .name, enabled)`). Previously it set an arbitrary `<name>` KV value.

### Features

- **Comptime feature-flag + experiment registry (#128/#129/#130).** Declare `.flags` (bare-bool default or `.{ .default, .description }`) and `.experiments` (`.{ .variants, .weights, .sticky, .description }`) in the `App(cfg)` literal. Malformed declarations (unknown sub-key, non-bool flag, variants/weights length mismatch, empty/duplicate variants, all-zero weights) are loud `@compileError`s.
- **Typed, compile-checked accessors.** `App.flag(ctx, .name) bool`, `App.setFlag(ctx, .name, enabled) !void`, and `App.experiment(ctx, .name, subject) ![]const u8` — a typo'd flag/experiment name is a compile error (generated `App.Flag` / `App.Experiment` enums).
- **Runtime resolution.** `ctx.flagByName(name) ?bool` (dynamic read), `ctx.flags().resolveAll(subject)` resolves every declared flag + experiment in a single batched `_kv` scan, and deterministic experiment bucketing (`FNV1a-64(name ++ subject)` over cumulative weights) gives a stable variant per `(name, subject)`. Per-flag overrides live in `_kv` under `flag:<name>`; experiment weight overrides under `exp:<name>:weights` (JSON).
