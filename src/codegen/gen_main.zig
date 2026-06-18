//! Thin executable entry-point for the zbase TypeScript client generator.
//!
//! This file is the module root for the generator exe (not gen_client.zig).
//! The split exists because gen_client.zig uses relative imports
//! (@import("../schema.zig") etc.) that claim those source files for the
//! gen_client library module. When used as a module root alongside `zigbase`
//! (which also owns those same files), Zig 0.16 raises "file exists in modules
//! 'root' and 'zigbase'". By making THIS file the module root — importing
//! "zigbase" and "app" as named modules — all shared source files belong to
//! "zigbase" only, and gen_client.zigbase.codegen.gen_client.mainWithCollections
//! is called with the App.collections value from the "app" import.
//!
//! See: Task 7 build wiring (build.zig gen-dating-client step).
const std = @import("std");
const zigbase = @import("zigbase");
const app = @import("app");

pub fn main(init: std.process.Init) !void {
    return zigbase.codegen.gen_client.mainWithCollections(init, app.App.collections, app.App.routes);
}
