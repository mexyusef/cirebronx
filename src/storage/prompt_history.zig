const std = @import("std");

const atomic_write = @import("atomic_write.zig");
const config_mod = @import("config.zig");

const DiskHistory = struct {
    cwd: []const u8 = "",
    items: []const []const u8 = &.{},
};

pub fn load(allocator: std.mem.Allocator, paths: config_mod.AppPaths, cwd: []const u8) ![][]u8 {
    const history_path = try historyPathForWorkspace(allocator, paths, cwd);
    defer allocator.free(history_path);

    const file = std.fs.openFileAbsolute(history_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(DiskHistory, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const items = try allocator.alloc([]u8, parsed.value.items.len);
    for (parsed.value.items, 0..) |item, index| {
        items[index] = try allocator.dupe(u8, item);
    }
    return items;
}

pub fn save(allocator: std.mem.Allocator, paths: config_mod.AppPaths, cwd: []const u8, items: []const []const u8) !void {
    std.fs.makeDirAbsolute(paths.histories_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const history_path = try historyPathForWorkspace(allocator, paths, cwd);
    defer allocator.free(history_path);

    const disk = DiskHistory{
        .cwd = cwd,
        .items = items,
    };

    const json = try std.json.Stringify.valueAlloc(allocator, disk, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(json);

    try atomic_write.writeFileAbsolute(history_path, json);
}

fn historyPathForWorkspace(allocator: std.mem.Allocator, paths: config_mod.AppPaths, cwd: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, cwd);
    return try std.fmt.allocPrint(allocator, "{s}{c}{x}.json", .{
        paths.histories_dir,
        std.fs.path.sep,
        hash,
    });
}

test "history path is stable per workspace" {
    const paths = config_mod.AppPaths{
        .home_dir = @constCast("C:\\Users\\x"),
        .app_dir = @constCast("C:\\Users\\x\\.cirebronx"),
        .config_path = @constCast("C:\\Users\\x\\.cirebronx\\config.json"),
        .sessions_dir = @constCast("C:\\Users\\x\\.cirebronx\\sessions"),
        .histories_dir = @constCast("C:\\Users\\x\\.cirebronx\\histories"),
    };

    const a = try historyPathForWorkspace(std.testing.allocator, paths, "C:\\repo-a");
    defer std.testing.allocator.free(a);
    const b = try historyPathForWorkspace(std.testing.allocator, paths, "C:\\repo-a");
    defer std.testing.allocator.free(b);
    const c = try historyPathForWorkspace(std.testing.allocator, paths, "C:\\repo-b");
    defer std.testing.allocator.free(c);

    try std.testing.expect(std.mem.eql(u8, a, b));
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "save and load prompt history round trips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const app_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}{c}.cirebronx", .{ root, std.fs.path.sep });
    defer std.testing.allocator.free(app_dir);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}{c}config.json", .{ app_dir, std.fs.path.sep });
    defer std.testing.allocator.free(config_path);
    const sessions_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}{c}sessions", .{ app_dir, std.fs.path.sep });
    defer std.testing.allocator.free(sessions_dir);
    const histories_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}{c}histories", .{ app_dir, std.fs.path.sep });
    defer std.testing.allocator.free(histories_dir);

    try std.fs.makeDirAbsolute(app_dir);

    const paths = config_mod.AppPaths{
        .home_dir = try std.testing.allocator.dupe(u8, root),
        .app_dir = try std.testing.allocator.dupe(u8, app_dir),
        .config_path = try std.testing.allocator.dupe(u8, config_path),
        .sessions_dir = try std.testing.allocator.dupe(u8, sessions_dir),
        .histories_dir = try std.testing.allocator.dupe(u8, histories_dir),
    };
    defer paths.deinit(std.testing.allocator);

    const items = [_][]const u8{ "first prompt", "second prompt" };
    try save(std.testing.allocator, paths, "C:\\repo-a", &items);

    const loaded = try load(std.testing.allocator, paths, "C:\\repo-a");
    defer {
        for (loaded) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("first prompt", loaded[0]);
    try std.testing.expectEqualStrings("second prompt", loaded[1]);
}
