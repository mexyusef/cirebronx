const std = @import("std");

pub const SkillInfo = struct {
    name: []u8,
    path: []u8,
    summary: []u8,

    pub fn deinit(self: *SkillInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.summary);
    }
};

pub fn discover(allocator: std.mem.Allocator) ![]SkillInfo {
    const root = try resolveSkillsRoot(allocator);
    defer allocator.free(root);

    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var list: std.ArrayList(SkillInfo) = .empty;
    defer list.deinit(allocator);

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "SKILL.md")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ root, entry.path });
        errdefer allocator.free(full_path);
        const content = readFileAlloc(allocator, full_path, 64 * 1024) catch {
            allocator.free(full_path);
            continue;
        };
        defer allocator.free(content);

        const skill_name = std.fs.path.basename(std.fs.path.dirname(entry.path) orelse entry.path);
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, skill_name),
            .path = full_path,
            .summary = try allocator.dupe(u8, extractSummary(content)),
        });
    }

    return try list.toOwnedSlice(allocator);
}

fn resolveSkillsRoot(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "CODEX_HOME")) |codex_home| {
        defer allocator.free(codex_home);
        return try std.fs.path.join(allocator, &.{ codex_home, "skills" });
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |profile| {
        defer allocator.free(profile);
        return try std.fs.path.join(allocator, &.{ profile, ".codex", "skills" });
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return try std.fs.path.join(allocator, &.{ home, ".codex", "skills" });
    } else |_| {}

    return error.HomeDirectoryNotFound;
}

fn extractSummary(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t#-");
        if (trimmed.len == 0) continue;
        return trimmed;
    }
    return "";
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, limit);
}
