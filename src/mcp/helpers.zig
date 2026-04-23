const std = @import("std");

const client = @import("client.zig");
const store = @import("../storage/mcp.zig");
const config_mod = @import("../storage/config.zig");

pub const StatusLine = struct {
    name: []u8,
    command: []u8,
    tool_count: ?usize,
    error_text: ?[]u8,

    pub fn deinit(self: *StatusLine, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        if (self.error_text) |text| allocator.free(text);
    }
};

pub fn loadServers(allocator: std.mem.Allocator, paths: config_mod.AppPaths) ![]store.McpServer {
    return try store.load(allocator, paths);
}

pub fn deinitServers(allocator: std.mem.Allocator, servers: []store.McpServer) void {
    store.deinitServers(allocator, servers);
}

pub fn findServer(servers: []store.McpServer, name: []const u8) ?*store.McpServer {
    for (servers) |*server| {
        if (std.mem.eql(u8, server.name, name)) return server;
    }
    return null;
}

pub fn collectStatus(allocator: std.mem.Allocator, servers: []const store.McpServer, cwd: []const u8) ![]StatusLine {
    var lines: std.ArrayList(StatusLine) = .empty;
    defer lines.deinit(allocator);

    for (servers) |server| {
        const tool_list = client.listTools(allocator, server, cwd) catch |err| {
            try lines.append(allocator, .{
                .name = try allocator.dupe(u8, server.name),
                .command = try allocator.dupe(u8, server.command),
                .tool_count = null,
                .error_text = try allocator.dupe(u8, @errorName(err)),
            });
            continue;
        };
        defer {
            for (tool_list) |*tool| tool.deinit(allocator);
            allocator.free(tool_list);
        }
        try lines.append(allocator, .{
            .name = try allocator.dupe(u8, server.name),
            .command = try allocator.dupe(u8, server.command),
            .tool_count = tool_list.len,
            .error_text = null,
        });
    }

    return try lines.toOwnedSlice(allocator);
}

pub fn deinitStatusLines(allocator: std.mem.Allocator, lines: []StatusLine) void {
    for (lines) |*line| line.deinit(allocator);
    allocator.free(lines);
}

test "findServer finds matching entry" {
    var servers = [_]store.McpServer{
        .{ .name = try std.testing.allocator.dupe(u8, "alpha"), .command = try std.testing.allocator.dupe(u8, "cmd a") },
        .{ .name = try std.testing.allocator.dupe(u8, "beta"), .command = try std.testing.allocator.dupe(u8, "cmd b") },
    };
    defer for (&servers) |*server| server.deinit(std.testing.allocator);

    try std.testing.expect(findServer(&servers, "beta") != null);
    try std.testing.expect(findServer(&servers, "gamma") == null);
}

test "deinitStatusLines frees owned values" {
    const lines = try std.testing.allocator.alloc(StatusLine, 2);
    lines[0] = .{
        .name = try std.testing.allocator.dupe(u8, "alpha"),
        .command = try std.testing.allocator.dupe(u8, "cmd a"),
        .tool_count = 2,
        .error_text = null,
    };
    lines[1] = .{
        .name = try std.testing.allocator.dupe(u8, "beta"),
        .command = try std.testing.allocator.dupe(u8, "cmd b"),
        .tool_count = null,
        .error_text = try std.testing.allocator.dupe(u8, "BrokenPipe"),
    };

    deinitStatusLines(std.testing.allocator, lines);
}
