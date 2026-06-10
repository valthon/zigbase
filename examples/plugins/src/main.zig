//! ZigBase "plugins" example — the ADVANCED framework example.
//!
//! Where examples/blog is a bare packaging proof and examples/golfsim builds a
//! realistic app on top of ZigBase, THIS example exercises the comptime-config
//! surface a framework integrator reaches for — using ONLY the public
//! `zigbase.*` exports (no reaching into ZigBase internals):
//!
//!   1. A CUSTOM MAILER PLUGIN (`AuditMailer`) implementing the plugin contract
//!      `create(gpa, io, cfg) !Self` / `interface(*Self) zigbase.Mailer` /
//!      `deinit(*Self) void`, returning a `zigbase.Mailer` vtable that logs the
//!      `zigbase.Email`. Registered via `App(.{ .mailer = AuditMailer })`.
//!   2. COMPTIME SCHEMA via `.collections` — two related collections, one of
//!      which references the other BY NAME through a `.relation` field.
//!   3. An EXPLICIT MIGRATION via `.migrations` — a `zigbase.Migration` whose
//!      `up = fn(alloc, io, w: *zigbase.Db) anyerror!void` runs a `w.exec(...)`.
//!   4. POOL LEVERS via `.pools` — reader/job pool sizes + page-cache budget.
//!   5. FULLY EMBEDDED STATIC FRONTEND via `embedStaticDir` — the Astro build
//!      output in `frontend/dist` is compiled into the binary at build time;
//!      there is no runtime dependency on the frontend directory.
//!
//! The whole point: this package compiles against the PUBLISHED `zigbase`
//! module, proving the documented plugin/schema/migration features are usable
//! by an external consumer.

const std = @import("std");
const zigbase = @import("zigbase");

// ---------------------------------------------------------------------------
// 1. Custom mailer plugin.
//
//    The plugin contract (mirrors the built-in DefaultMailerPlugin):
//      - create(gpa, io, cfg) !Self   — construct from runtime config.
//      - interface(*Self) zigbase.Mailer — hand back the vtable the app calls.
//      - deinit(*Self) void           — release anything `create` allocated.
//
//    `AuditMailer` is a trivial backend: it logs every outbound `zigbase.Email`
//    (to / subject) and counts sends. The point is that it COMPILES against the
//    public `zigbase.Mailer` / `zigbase.Email` vtable types.
// ---------------------------------------------------------------------------
const AuditMailer = struct {
    sent: usize = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !AuditMailer {
        _ = gpa;
        _ = io;
        _ = cfg;
        return .{};
    }

    pub fn interface(self: *AuditMailer) zigbase.Mailer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *AuditMailer) void {
        _ = self;
    }

    const vtable = zigbase.Mailer.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: zigbase.Email) anyerror!void {
        _ = io;
        _ = alloc;
        const self: *AuditMailer = @ptrCast(@alignCast(ptr));
        self.sent += 1;
        std.log.info("[audit-mail #{d}] to={s} subject={s}", .{ self.sent, email.to, email.subject });
    }
};

// ---------------------------------------------------------------------------
// 3. Explicit migration.
//
//    `up` matches `fn(alloc, io, w: *zigbase.Db) anyerror!void`. ZigBase runs it
//    exactly once (recorded by `id` in `_migrations`) before provisioning the
//    comptime collections. Here it creates a side table directly via `w.exec`
//    (a SQLite statement) — a stand-in for a non-additive change that the
//    additive auto-provisioner won't make on its own.
// ---------------------------------------------------------------------------
fn createAuditLog(alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void {
    _ = alloc;
    _ = io;
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS plugin_audit_log (
        \\  id INTEGER PRIMARY KEY,
        \\  note TEXT NOT NULL DEFAULT ''
        \\);
    );
}

// ---------------------------------------------------------------------------
// Wire it all together. One `App(...)` registers the custom mailer plugin, the
// comptime schema, the explicit migration, and the pool levers, then `runCli`
// exposes `serve` / `migrate` / `help`.
// ---------------------------------------------------------------------------
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        // 1. custom mailer plugin (replaces DefaultMailerPlugin)
        .mailer = AuditMailer,

        // 2. comptime schema: two related collections. `posts.author` is a
        //    relation referencing the `authors` collection BY NAME.
        .collections = .{
            .authors = .{
                .type = .base,
                .fields = .{
                    .{ .name = "name", .type = .text, .required = true },
                    .{ .name = "contact_email", .type = .email },
                },
                .rules = .{ .list = "", .view = "" },
            },
            .posts = .{
                .fields = .{
                    .{ .name = "title", .type = .text, .required = true, .max = 200 },
                    .{ .name = "author", .type = .relation, .target = "authors", .cascadeDelete = true },
                    .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
                },
                .rules = .{ .list = "status = \"published\"" },
            },
        },

        // 3. explicit migration (escape hatch for non-additive changes)
        .migrations = &[_]zigbase.Migration{
            .{ .id = "0001_create_audit_log", .up = createAuditLog },
        },

        // 4. footprint tuning levers
        .pools = .{ .readers = 4, .jobs = 1, .cache_kib = 512 },

        // 5. fully embedded static frontend (see build.zig embedStaticDir)
        .static_files = .{ .embedded = &@import("static_assets").files },
    }).runCli(init);
}
