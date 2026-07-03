const std = @import("std");
const zigbase = @import("zigbase");

/// The gating-invariant's POSITIVE control (companion to fixtures/minimal). Explored
/// during Task 7: the stock `zigbase` binary (src/main.zig) does NOT configure `.mail`,
/// `.webhooks`, or `.analytics` either — so their symbols (senders/inbound API, the
/// webhook + mail job kinds, the analytics API) never appear there, and a self-check
/// against it would DRIFT-fail on those patterns forever (not a spelling problem — the
/// subsystems are simply absent from every binary the build already produces). This
/// fixture turns exactly those knobs on so scripts/check-gating.sh has a real positive
/// control for them. `.admin` and the five built-in auth methods are already on by
/// default in the stock binary, so this fixture doesn't need to repeat them.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .analytics = .{},
        .mail = .{},
        .webhooks = true,
    }).runCli(init);
}
