const std = @import("std");

// ---- Public API (grows over this plan) -------------------------------------
pub const App = @import("app.zig").App; // runtime app context (comptime builder added later)
pub const Config = @import("config.zig").Config;
pub const Server = @import("server.zig").Server;
pub const http = @import("http.zig");

/// Internal modules the shipped binary's main() drives directly until a later
/// task introduces the comptime App(cfg) builder. Not part of the stable API.
pub const @"internal" = struct {
    pub const app = @import("app.zig");
    pub const server = @import("server.zig");
    pub const cli = @import("cli.zig");
    pub const config = @import("config.zig");
    pub const db = @import("db.zig");
    pub const migrations = @import("migrations.zig");
    pub const files_storage = @import("files/storage.zig");
    pub const crypto = @import("crypto.zig");
    pub const id = @import("id.zig");
};

// ---- Test discovery --------------------------------------------------------
// The unit-test runner is rooted at THIS module. Reference every internal file
// so its `test {}` blocks are analyzed and run (matches pre-restructure behavior
// where main.zig's import graph reached them).
test "smoke" {
    try std.testing.expect(true);
}

test {
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("cli.zig");
    _ = @import("db.zig");
    _ = @import("http.zig");
    _ = @import("router.zig");
    _ = @import("request.zig");
    _ = @import("server.zig");
    _ = @import("schema.zig");
    _ = @import("collections.zig");
    _ = @import("records.zig");
    _ = @import("values.zig");
    _ = @import("ddl.zig");
    _ = @import("migrations.zig");
    _ = @import("rules.zig");
    _ = @import("crypto.zig");
    _ = @import("jwt.zig");
    _ = @import("auth.zig");
    _ = @import("id.zig");
    _ = @import("admin.zig");
    _ = @import("api/error.zig");
    _ = @import("api/health.zig");
    _ = @import("api/collections.zig");
    _ = @import("api/records.zig");
    _ = @import("api/auth.zig");
    _ = @import("api/oauth.zig");
    _ = @import("api/files.zig");
    _ = @import("oauth/secrets.zig");
    _ = @import("oauth/providers.zig");
    _ = @import("oauth/client.zig");
    _ = @import("query/params.zig");
    _ = @import("query/lexer.zig");
    _ = @import("query/parser.zig");
    _ = @import("query/joiner.zig");
    _ = @import("query/compiler.zig");
    _ = @import("query/sort.zig");
    _ = @import("query/expand.zig");
    _ = @import("realtime/protocol.zig");
    _ = @import("realtime/connection.zig");
    _ = @import("realtime/hub.zig");
    _ = @import("realtime/ws.zig");
    _ = @import("files/naming.zig");
    _ = @import("files/mime.zig");
    _ = @import("files/storage.zig");
    _ = @import("files/plan.zig");
    _ = @import("files/multipart.zig");
}
