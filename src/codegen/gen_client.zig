//! Pure-Zig TypeScript client generator executable.
//! Reads @import("app").App.collections and emits a zbase.gen.ts.
const std = @import("std");

// Zig 0.16 entry point — filled in Task 5.
pub fn main(init: std.process.Init) !void {
    _ = init;
}
