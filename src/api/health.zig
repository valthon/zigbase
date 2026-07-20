const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const http = @import("../http.zig");
const db = @import("../db.zig");
const build_options = @import("build_options");

/// The active database backend, as a short, non-secret label. Derived from the live pool's
/// backend tag (`db.poolBackend`). Never exposes the connection string, host, credentials, or
/// any other config — only the backend KIND ("sqlite" | "postgres"), so the admin SPA can show
/// a read-only badge. Pure-handler unit tests (no `app`) report the default "sqlite".
fn backendLabel(ctx: *http.RequestCtx) []const u8 {
    const app = ctx.app orelse return "sqlite";
    return switch (db.poolBackend(app.pool)) {
        .sqlite => "sqlite",
        .postgres => "postgres",
    };
}

/// GET /api/health -> 200 {"status":"ok","backend":"...","versions":{...}}
///
/// The `backend` field is a read-only badge for the admin UI. It is deliberately the backend
/// KIND only — no connection string / host / credentials are ever surfaced here.
///
/// The `versions` object (#282) exposes the baked-in component versions so an operator can audit
/// a running binary over HTTP: `sqlite` is the LIVE linked version (`db.libVersion()`); the rest
/// come from build_options (single source of truth, also on `--version` + the boot log). These are
/// non-secret build provenance — no config value, path, or credential is ever added here.
pub fn handle(ctx: *http.RequestCtx) !http.Response {
    const body = try std.json.Stringify.valueAlloc(
        ctx.allocator.a,
        .{
            .status = "ok",
            .backend = backendLabel(ctx),
            .versions = .{
                .zigbase = build_options.version,
                .commit = build_options.commit,
                .sqlite = db.libVersion(),
                .sqliteVec = build_options.sqlite_vec_version,
                .zap = build_options.zap_version,
                .facil = build_options.facil_version,
            },
        },
        .{},
    );
    return .{ .status = 200, .body = body };
}

test "health returns 200 and ok status with backend badge + versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{
        .method = .GET,
        .path = "/api/health",
        .allocator = RequestArena.from(&arena),
    };
    const resp = try handle(&ctx);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    // No live app in this pure-handler test → reports the default backend, never any secret.
    // The versions come from build_options / the linked SQLite; assemble the expected body from
    // the same sources so a version bump doesn't require editing this literal by hand.
    const expected = try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"status\":\"ok\",\"backend\":\"sqlite\",\"versions\":{{" ++
            "\"zigbase\":\"{s}\",\"commit\":\"{s}\",\"sqlite\":\"{s}\"," ++
            "\"sqliteVec\":\"{s}\",\"zap\":\"{s}\",\"facil\":\"{s}\"}}}}",
        .{
            build_options.version,
            build_options.commit,
            db.libVersion(),
            build_options.sqlite_vec_version,
            build_options.zap_version,
            build_options.facil_version,
        },
    );
    try std.testing.expectEqualStrings(expected, resp.body);
}
