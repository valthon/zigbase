//! The single dev-tools build gate. True by default — every official artifact we
//! publish (GitHub release tarballs, the Docker image, the `@zigbase/server` npm
//! packages) builds at this default, so those binaries always carry the three verbs
//! below. Comptime-FALSE only when a consumer explicitly opts out with
//! `-Ddev-tools=false` while compiling their OWN binary for their OWN deployment.
//!
//! It gates the three pure development-time CLI verbs: `init` and `agents-md`
//! (project scaffolding, `src/scaffold*.zig`) and `typegen` (schema-to-client
//! codegen, `src/codegen/**` — ~24 files, the largest dev-only surface in the
//! binary). None of the three has operational or runtime value on a *deployed*
//! server — they are schema/toolchain-in, source-out generators a developer runs
//! locally, never something a running instance needs to serve traffic. typegen's
//! no-Zig-toolchain equivalent ships separately as `@zigbase/typegen` on npm, so
//! omitting it here doesn't strand anyone.
//!
//! When false, every gated call site (`src/cli.zig`'s `ParseError.DevToolsDisabled`,
//! `src/framework.zig`'s dispatch arms and help text) folds to comptime-dead code,
//! so a stripped binary contains none of `scaffold.zig`/`scaffold/**`/`codegen/**`.
//! Invoking a stripped verb still exits non-zero with an actionable message instead
//! of a bare `UnknownCommand` — the caller is usually an agent that read a doc
//! written for the default (dev-tools-on) binary.
const build_options = @import("build_options");

/// Comptime gate — see the module doc comment. Every dev-tools verb is `if (devtools.enabled) …`.
pub const enabled = build_options.dev_tools;

/// Shared wording for "this verb needs -Ddev-tools=true" — used by both cli.zig's
/// parse-time rejection (the path a real invocation actually takes) and
/// framework.zig's dispatch-time fallback (unreachable in practice since parse
/// rejects first, but keeps those arms from referencing scaffold/codegen in a
/// stripped build). `{s}` is the verb name, e.g. "init".
pub const disabled_note = "this binary was built without -Ddev-tools, so the scaffolding commands (init, agents-md, typegen) are not compiled in. Use an official release binary, or rebuild with -Ddev-tools=true.";
