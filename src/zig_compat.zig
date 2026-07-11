//! Compile-time Zig-version guard.
//!
//! zigbase is pinned to a single Zig minor series (see `mise.toml` /
//! `build.zig.zon` `minimum_zig_version`). Building the library with a different
//! compiler used to fail deep inside the source with confusing errors that gave a
//! downstream consumer no hint that the real problem was their toolchain version.
//!
//! This module's top-level `comptime` block runs on EVERY build (it is referenced
//! from `src/root.zig`, which every consumer — including `examples/blog` — compiles),
//! so an unsupported compiler is rejected up front with an actionable
//! required-vs-actual message instead of an opaque deep-compilation error.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

comptime {
    const need = std.SemanticVersion.parse(build_options.min_zig_version) catch
        @compileError("zigbase: could not parse minimum_zig_version '" ++ build_options.min_zig_version ++ "' from build.zig.zon");
    const have = builtin.zig_version;

    // Pinned to a single minor series: reject a different major OR minor, so
    // 0.16.x passes but 0.15.x / 0.17.x are rejected.
    if (have.major != need.major or have.minor != need.minor) {
        @compileError(std.fmt.comptimePrint(
            "zigbase requires Zig {d}.{d}.x (pinned {s}), but you are building with {s}. " ++
                "Install the pinned toolchain: run `mise install` in the repo, or " ++
                "`mise exec zig@{s} -- zig build`. See mise.toml / build.zig.zon minimum_zig_version.",
            .{ need.major, need.minor, build_options.min_zig_version, builtin.zig_version_string, build_options.min_zig_version },
        ));
    }
}

test "zig version guard compiles under a supported toolchain" {
    // The guard above is compile-time only; if this test binary built at all, the
    // running compiler satisfied the pinned major.minor. Assert it explicitly.
    const need = try std.SemanticVersion.parse(build_options.min_zig_version);
    try std.testing.expectEqual(need.major, builtin.zig_version.major);
    try std.testing.expectEqual(need.minor, builtin.zig_version.minor);
}
