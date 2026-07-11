//! Offline-import e2e fixture (issue #283). A tiny consumer app whose comptime `.collections`
//! give the `zigbase import` browser test something real to import into through a genuine
//! boot: an auth collection with a password (to prove password hashing) and a base collection
//! with an `.encrypted` field (to prove the at-rest envelope is applied and decrypts on read).
//! Kept minimal — a test fixture, not an example.
const std = @import("std");
const zigbase = @import("zigbase");

pub const App = zigbase.App(.{
    .collections = .{
        // Auth collection: importing a row with a `password` must hash it (never plaintext) and
        // generate a tokenKey / verified=false so the account is immediately usable.
        .members = .{
            .type = .auth,
            .fields = .{
                .{ .name = "name", .type = .text },
            },
            // Public read so the e2e can GET the imported rows back over REST.
            .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
        },
        // Base collection with an encrypted field. `secret` is stored as an AES-GCM envelope at
        // rest; `code` is a plain, unique field usable as an --upsert-key.
        .vault = .{
            .fields = .{
                .{ .name = "code", .type = .text, .required = true, .unique = true },
                .{ .name = "secret", .type = .text, .encrypted = true },
                .{ .name = "note", .type = .text },
            },
            .rules = .{ .list = "@public", .view = "@public" },
        },
    },
});

pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
