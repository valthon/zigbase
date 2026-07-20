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

    /// Constructible ONLY from a real arena, at the boundary that owns and deinits it.
    /// Taking the concrete `*ArenaAllocator` (not an `Allocator`) means a GPA can't flow
    /// in ACCIDENTALLY through the signature. Zig has no private fields, so a deliberate
    /// `RequestArena{ .a = some_gpa }` struct literal still compiles — that bypass is not
    /// prevented, only made greppable and high-friction instead of the default path.
    pub fn from(arena: *std.heap.ArenaAllocator) RequestArena {
        return .{ .a = arena.allocator() };
    }
};

test "RequestArena is constructible only from a real arena and exposes .a" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ra = RequestArena.from(&arena);
    const buf = try ra.a.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), buf.len);

    // Contract-1 helpers take a plain Allocator; `.a` is the deliberate bridge.
    try std.testing.expect(@TypeOf(ra.a) == std.mem.Allocator);
}
