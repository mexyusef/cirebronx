const std = @import("std");
const storage = @import("../storage/mcp.zig");

pub const ToolInfo = struct {
    name: []u8,
    description: []u8,

    pub fn deinit(self: *ToolInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

pub fn listTools(
    allocator: std.mem.Allocator,
    server: storage.McpServer,
    cwd: []const u8,
) ![]ToolInfo {
    var session = try Session.init(allocator, server.command, cwd);
    defer session.deinit();

    _ = try session.request("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"cirebronx\",\"version\":\"0.1.0\"}}}");
    try session.notify("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}");
    const raw = try session.request("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}");
    defer allocator.free(raw);

    const Envelope = struct {
        result: struct {
            tools: []struct {
                name: []const u8,
                description: ?[]const u8 = null,
            },
        },
    };
    const parsed = try std.json.parseFromSlice(Envelope, allocator, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var tools = try allocator.alloc(ToolInfo, parsed.value.result.tools.len);
    for (parsed.value.result.tools, 0..) |tool, index| {
        tools[index] = .{
            .name = try allocator.dupe(u8, tool.name),
            .description = try allocator.dupe(u8, tool.description orelse ""),
        };
    }
    return tools;
}

pub fn callTool(
    allocator: std.mem.Allocator,
    server: storage.McpServer,
    cwd: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    var session = try Session.init(allocator, server.command, cwd);
    defer session.deinit();

    _ = try session.request("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"cirebronx\",\"version\":\"0.1.0\"}}}");
    try session.notify("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}");

    const request_body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{{\"name\":{f},\"arguments\":{s}}}}}",
        .{ std.json.fmt(tool_name, .{}), arguments_json },
    );
    defer allocator.free(request_body);

    const raw = try session.request(request_body);
    defer allocator.free(raw);

    const Envelope = struct {
        result: struct {
            content: []struct {
                @"type": ?[]const u8 = null,
                text: ?[]const u8 = null,
            } = &.{},
            isError: ?bool = null,
        },
    };
    const parsed = try std.json.parseFromSlice(Envelope, allocator, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (parsed.value.result.content) |item| {
        if (item.text) |text| {
            try out.writer.writeAll(text);
            try out.writer.writeByte('\n');
        }
    }
    return out.toOwnedSlice();
}

const Session = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdout_buf: [4096]u8,

    fn init(allocator: std.mem.Allocator, command: []const u8, cwd: []const u8) !Session {
        const argv = if (@import("builtin").os.tag == .windows)
            &.{ "powershell", "-NoProfile", "-Command", command }
        else
            &.{ "sh", "-lc", command };

        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = cwd;
        try child.spawn();

        return .{
            .allocator = allocator,
            .stdout_buf = undefined,
            .child = child,
        };
    }

    fn deinit(self: *Session) void {
        _ = self.child.kill() catch {};
    }

    fn notify(self: *Session, json_payload: []const u8) !void {
        try self.send(json_payload);
    }

    fn request(self: *Session, json_payload: []const u8) ![]u8 {
        try self.send(json_payload);
        return try self.readMessage();
    }

    fn send(self: *Session, json_payload: []const u8) !void {
        var writer_buf: [1024]u8 = undefined;
        var writer = self.child.stdin.?.writer(&writer_buf);
        try writer.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ json_payload.len, json_payload });
        try writer.interface.flush();
    }

    fn readMessage(self: *Session) ![]u8 {
        var stdout_reader = self.child.stdout.?.reader(&self.stdout_buf);

        var content_length: usize = 0;
        while (true) {
            const maybe_line = try stdout_reader.interface.takeDelimiter('\n');
            if (maybe_line == null) return error.EndOfStream;
            const line = std.mem.trim(u8, maybe_line.?, "\r");
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "Content-Length:")) {
                const value = std.mem.trim(u8, line["Content-Length:".len..], " ");
                content_length = try std.fmt.parseInt(usize, value, 10);
            }
        }

        if (content_length == 0) return error.InvalidData;
        const payload = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(payload);
        try stdout_reader.interface.readSliceAll(payload);
        return payload;
    }
};
