//! Auth-round-2 e2e fixture (spec §F1–F3 browser coverage): a consumer app with
//! `.session_store = .table` and a REGISTERED `beforeAuthSuccess` hook, so the Playwright
//! suite can exercise (a) the hook firing/aborting on the LEGACY login routes — including
//! the _superusers admin-SPA login — and (b) the per-device session REST surface.
//! Kept deliberately tiny: this is a test fixture, not an example (the examples ladder
//! stays blog < golfsim < plugins).
const std = @import("std");
const zigbase = @import("zigbase");

/// e2e marker hook: veto any identity whose email starts with "blocked" (fail closed,
/// clean rollback — the audit side-write below must NOT persist for a vetoed login);
/// record every allowed login as a side row that commits WITH the session. Fires for
/// `_superusers` too (0.10.0 Breaking behavior the suite pins).
fn gateLogin(ctx: *zigbase.Ctx, ev: *zigbase.events.AuthSuccessEvent) anyerror!void {
    // Side-write FIRST so the veto path also proves rollback.
    var row: std.json.ObjectMap = .empty;
    try row.put(ctx.arena, "who", .{ .string = ev.record_id });
    try row.put(ctx.arena, "col", .{ .string = ev.collection });
    try row.put(ctx.arena, "method", .{ .string = @tagName(ev.method) });
    _ = try ctx.records().create("loginAudit", .{ .object = row });
    if (ev.record == .object) if (ev.record.object.get("email")) |em| if (em == .string) {
        if (std.mem.startsWith(u8, em.string, "blocked")) return ctx.fail(403, "login blocked by hook");
    };
}

pub const App = zigbase.App(.{
    .session_store = .table,
    .beforeAuthSuccess = gateLogin,
    .collections = .{
        .users = .{
            .type = .auth,
            .fields = .{
                .{ .name = "nick", .type = .text },
            },
            // Public signup; owner-only everything else (password change e2e rides update).
            .rules = .{ .list = "@request.auth.id = id", .view = "@request.auth.id = id", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
        },
        .loginAudit = .{
            .fields = .{
                .{ .name = "who", .type = .text },
                .{ .name = "col", .type = .text },
                .{ .name = "method", .type = .text },
            },
            // Publicly listable so tests can assert on it; writes stay locked — the hook's
            // ctx.records() writes bypass rules (Data facade), clients cannot forge rows.
            .rules = .{ .list = "@public", .view = "@public" },
        },
    },
});

pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
