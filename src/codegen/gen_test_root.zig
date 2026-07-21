//! Test root for the `gen-test` build step (Task 8).
//! Imports both "zigbase" (for gen_client.generate) and "app" (for the dating
//! schema) so that the golden-snapshot test can call generate() with the real
//! App.collections and compare against the committed snapshot.
//!
//! This file is the module root for the gen-test step — it does NOT belong to
//! zigbase_mod (which roots at src/root.zig). No files claimed by zigbase_mod
//! are imported relative-style here.
const std = @import("std");
const zigbase = @import("zigbase");
const app = @import("app");

const gen_client = zigbase.codegen.gen_client;

test "golden: in-process generate matches the committed dating snapshot" {
    // Skipped unless the committed snapshot exists (it is created in Task 8).
    // Zig 0.16 test IO: std.Io.Dir.cwd().readFileAlloc uses the std.testing.io handle.
    // gen_client.generate is contract-1 (self-freeing, returns one owned slice), so this
    // runs under the leak-detecting allocator: both the snapshot read and the generated
    // text are the only owned results, freed below.
    const a = std.testing.allocator;
    const committed = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "clients/typescript/test/codegen/dating/zbase.gen.ts",
        a,
        .limited(64 * 1024 * 1024),
    ) catch return; // absent during earlier tasks -> skip
    defer a.free(committed);
    const text = try gen_client.generate(a, app.App.collections, app.App.routes, app.App.custom_auth, app.App.flags, app.App.experiments, true, "profiles", "ZbClient", "/api");
    defer a.free(text);
    try std.testing.expectEqualStrings(committed, text);
}
