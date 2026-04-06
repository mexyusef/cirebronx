const std = @import("std");

pub const PluginManifest = struct {
    name: []u8,
    version: []u8,
    description: []u8,
    path: []u8,

    pub fn deinit(self: *PluginManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.path);
    }
};

const DiskPluginManifest = struct {
    name: []const u8 = "",
    version: []const u8 = "0.0.0",
    description: []const u8 = "",
};

pub fn scan(allocator: std.mem.Allocator, cwd: []const u8) ![]PluginManifest {
    const plugins_dir = try std.fs.path.join(allocator, &.{ cwd, "plugins" });
    defer allocator.free(plugins_dir);

    var dir = std.fs.openDirAbsolute(plugins_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var list: std.ArrayList(PluginManifest) = .empty;
    defer list.deinit(allocator);

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "plugin.json")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ plugins_dir, entry.path });
        errdefer allocator.free(full_path);

        var file = std.fs.openFileAbsolute(full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        defer file.close();
        const raw = try file.readToEndAlloc(allocator, 128 * 1024);
        defer allocator.free(raw);

        const parsed = try std.json.parseFromSlice(DiskPluginManifest, allocator, raw, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, parsed.value.name),
            .version = try allocator.dupe(u8, parsed.value.version),
            .description = try allocator.dupe(u8, parsed.value.description),
            .path = full_path,
        });
    }

    return try list.toOwnedSlice(allocator);
}
