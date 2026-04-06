const std = @import("std");

const atomic_write = @import("atomic_write.zig");
const config_mod = @import("config.zig");

pub const McpServer = struct {
    name: []u8,
    command: []u8,

    pub fn deinit(self: *McpServer, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
    }
};

const DiskMcpServer = struct {
    name: []const u8,
    command: []const u8,
};

const DiskMcpConfig = struct {
    servers: []DiskMcpServer = &.{},
};

pub fn configPath(allocator: std.mem.Allocator, paths: config_mod.AppPaths) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}{c}mcp.json", .{ paths.app_dir, std.fs.path.sep });
}

pub fn load(allocator: std.mem.Allocator, paths: config_mod.AppPaths) ![]McpServer {
    const path = try configPath(allocator, paths);
    defer allocator.free(path);

    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(raw);

    const parsed = try std.json.parseFromSlice(DiskMcpConfig, allocator, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var servers = try allocator.alloc(McpServer, parsed.value.servers.len);
    for (parsed.value.servers, 0..) |server, index| {
        servers[index] = .{
            .name = try allocator.dupe(u8, server.name),
            .command = try allocator.dupe(u8, server.command),
        };
    }
    return servers;
}

pub fn save(
    allocator: std.mem.Allocator,
    paths: config_mod.AppPaths,
    servers: []const McpServer,
) !void {
    std.fs.makeDirAbsolute(paths.app_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var disk = try allocator.alloc(DiskMcpServer, servers.len);
    defer allocator.free(disk);
    for (servers, 0..) |server, index| {
        disk[index] = .{
            .name = server.name,
            .command = server.command,
        };
    }

    const payload = DiskMcpConfig{ .servers = disk };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(json);

    const path = try configPath(allocator, paths);
    defer allocator.free(path);
    try atomic_write.writeFileAbsolute(path, json);
}

pub fn deinitServers(allocator: std.mem.Allocator, servers: []McpServer) void {
    for (servers) |*server| server.deinit(allocator);
    allocator.free(servers);
}
