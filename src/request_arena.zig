const std = @import("std");

/// A request-scoped arena. Deliberately NOT `std.mem.Allocator`: an arena-scoped API
/// cannot be handed a GPA by accident, the dependency is visible in every signature,
/// and the compiler checks it.
///
/// A function taking a `RequestArena` is contract 4 in the allocator-ownership design
/// (docs/superpowers/specs/2026-07-19-allocator-ownership-design.md) and REQUIRES a
/// written justification meeting all three of:
///   1. the result is a graph of interlinked allocations, not a single buffer; and
///   2. freeing them individually would be pointer-chasing for no benefit; and
///   3. the lifetime is genuinely request-scoped — it dies at a known boundary.
/// "It is currently written that way" is not a justification.
pub const RequestArena = struct {
    /// The deliberate escape hatch: contract-1 helpers take a plain `Allocator`, and
    /// they are correct under any allocator including this arena. Greppable on purpose —
    /// stashing `.a` beyond the request lifetime is the one misuse the type cannot stop.
    a: std.mem.Allocator,

    /// The production constructor: build from a real arena, at the boundary that owns and
    /// deinits it. Taking the concrete `*ArenaAllocator` (not an `Allocator`) means a GPA
    /// can't flow in ACCIDENTALLY through the signature. Zig has no private fields, so a
    /// deliberate `RequestArena{ .a = some_gpa }` struct literal still compiles — that
    /// bypass is not prevented, only made greppable and high-friction instead of the
    /// default path. The one sanctioned non-arena construction is `forTest` below, which
    /// exists to preserve leak detection in tests and is a review defect anywhere else.
    pub fn from(arena: *std.heap.ArenaAllocator) RequestArena {
        return .{ .a = arena.allocator() };
    }

    /// Install a NON-arena allocator for a test. This exists so a test can keep using
    /// `std.testing.allocator`, whose leak detection is STRICTLY STRONGER than an arena's:
    /// an arena frees everything at deinit, so a handler that leaks looks identical to one
    /// that does not. Wrapping such a test in a real arena to satisfy the type would delete
    /// that detection -- the exact masking the ownership work removed (see NO_SLOP.md 2.2a).
    ///
    /// Correctness note: code under a `RequestArena` must be correct under ANY allocator,
    /// because contract-1 helpers reached via `.a` are. So running a handler on a GPA is a
    /// valid, and harsher, execution -- it additionally requires the handler not to leak.
    ///
    /// Test-only by convention, not by compiler enforcement; `forTest` in production code
    /// is a review defect and greppable as one.
    pub fn forTest(gpa: std.mem.Allocator) RequestArena {
        return .{ .a = gpa };
    }
};

test "RequestArena.from builds from a real arena and exposes .a" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ra = RequestArena.from(&arena);
    const buf = try ra.a.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), buf.len);

    // Contract-1 helpers take a plain Allocator; `.a` is the deliberate bridge.
    try std.testing.expect(@TypeOf(ra.a) == std.mem.Allocator);
}
