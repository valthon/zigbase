//! Named profiles and explicit external-image policy; no embedded codec.
const std = @import("std");
const backend = @import("thumbnail_imagemagick.zig");
pub const Profile = struct {
    name: []const u8,
    width: u32,
    height: u32,
    format: backend.Format = .png,
    fit: @FieldType(backend.Profile, "fit") = .contain,
    quality: u8 = 85,
    pub fn image(self: Profile) backend.Profile {
        return .{ .width = self.width, .height = self.height, .format = self.format, .fit = self.fit, .quality = self.quality };
    }
};
pub const Config = struct {
    profiles: []const Profile = &.{},
    imagemagick: backend.Config = .{ .executable = "" },
    max_concurrent: u32 = 1,
    max_waiting: u32 = 32,
    wait_timeout_ms: u32 = 5000,
};
pub fn lower(comptime cfg: anytype) Config {
    if (@typeInfo(@TypeOf(cfg)) != .@"struct") @compileError(".files.thumbnails must be a struct");
    var out = Config{};
    for (std.meta.fields(@TypeOf(cfg))) |f| {
        if (!@hasField(Config, f.name)) @compileError("Unknown .files.thumbnails key: " ++ f.name);
        if (std.mem.eql(u8, f.name, "imagemagick")) {
            const image = cfg.imagemagick;
            if (@typeInfo(@TypeOf(image)) != .@"struct") @compileError(".files.thumbnails.imagemagick must be a struct");
            for (std.meta.fields(@TypeOf(image))) |field| {
                if (!@hasField(backend.Config, field.name)) @compileError("Unknown thumbnail ImageMagick key: " ++ field.name);
                @field(out.imagemagick, field.name) = @field(image, field.name);
            }
        } else if (!std.mem.eql(u8, f.name, "profiles")) @field(out, f.name) = @field(cfg, f.name);
    }
    if (!@hasField(@TypeOf(cfg), "profiles")) @compileError(".files.thumbnails requires named .profiles");
    if (@typeInfo(@TypeOf(cfg.profiles)) != .@"struct") @compileError(".files.thumbnails.profiles must be a named struct");
    const fields = std.meta.fields(@TypeOf(cfg.profiles));
    if (fields.len == 0 or fields.len > 32) @compileError(".files.thumbnails requires 1..32 named profiles");
    const profiles = blk: {
        var values: [fields.len]Profile = undefined;
        for (fields, 0..) |f, i| {
            if (!validName(f.name)) @compileError("Thumbnail profile names must start with a lowercase letter and contain only lowercase letters, digits and hyphens (1..64 bytes)");
            const p = @field(cfg.profiles, f.name);
            if (@typeInfo(@TypeOf(p)) != .@"struct") @compileError("Thumbnail profile must contain .width and .height");
            if (!@hasField(@TypeOf(p), "width") or !@hasField(@TypeOf(p), "height")) @compileError("Thumbnail profile requires .width and .height");
            var profile = Profile{ .name = f.name, .width = p.width, .height = p.height };
            for (std.meta.fields(@TypeOf(p))) |pf| {
                if (!@hasField(backend.Profile, pf.name)) @compileError("Unknown thumbnail profile key: " ++ pf.name);
                @field(profile, pf.name) = @field(p, pf.name);
            }
            if (!backend.validProfile(out.imagemagick, profile.image())) @compileError("Invalid thumbnail profile: positive dimensions within max_dimension/max_pixels and quality in 1..100 required");
            values[i] = profile;
        }
        break :blk values;
    };
    out.profiles = &profiles;
    if (!backend.validateConfig(out.imagemagick)) @compileError("Invalid thumbnail ImageMagick configuration: explicit absolute executable and positive resource limits required");
    if (out.max_concurrent == 0 or (out.max_waiting > 0 and out.wait_timeout_ms == 0)) @compileError("Invalid thumbnail admission: max_concurrent and enabled wait timeout must be positive");
    return out;
}
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    return true;
}
test "thumbnail profiles support capable limits and explicit external policy" {
    const cfg = comptime lower(.{ .imagemagick = .{ .executable = "/usr/bin/convert", .command_style = .convert }, .profiles = .{ .avatar = .{ .width = 64, .height = 32 }, .@"large-card" = .{ .width = 2048, .height = 1024, .format = .webp, .fit = .cover, .quality = 90 } }, .max_concurrent = 8 });
    try std.testing.expectEqual(@as(usize, 2), cfg.profiles.len);
    try std.testing.expectEqual(backend.Format.webp, cfg.profiles[1].format);
    try std.testing.expectEqual(@as(u32, 8), cfg.max_concurrent);
    for ([_][]const u8{ "", "1x", "A", "a_b", "a/b", "a.b" }) |name| try std.testing.expect(!validName(name));
}
