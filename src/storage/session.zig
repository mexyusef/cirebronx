const std = @import("std");

const atomic_write = @import("atomic_write.zig");
const config_mod = @import("config.zig");
const message_mod = @import("../core/message.zig");

const DiskMessage = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_calls: []DiskToolCall = &.{},
};

const DiskToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

const DiskSession = struct {
    id: []const u8,
    cwd: []const u8,
    model: []const u8,
    updated_at: i64,
    messages: []DiskMessage,
};

pub const LoadedSession = struct {
    id: []u8,
    cwd: []u8,
    model: []u8,
    updated_at: i64,
    messages: []message_mod.Message,

    pub fn deinit(self: *LoadedSession, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.cwd);
        allocator.free(self.model);
        for (self.messages) |*msg| msg.deinit(allocator);
        allocator.free(self.messages);
    }
};

pub const SessionSummary = struct {
    id: []u8,
    cwd: []u8,
    model: []u8,
    updated_at: i64,
    message_count: usize,

    pub fn deinit(self: *SessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.cwd);
        allocator.free(self.model);
    }
};

pub fn saveSession(
    allocator: std.mem.Allocator,
    paths: config_mod.AppPaths,
    session_id: []const u8,
    cwd: []const u8,
    model: []const u8,
    messages: []const message_mod.Message,
) !void {
    std.fs.makeDirAbsolute(paths.sessions_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var disk_messages = try allocator.alloc(DiskMessage, messages.len);
    defer allocator.free(disk_messages);

    for (messages, 0..) |msg, idx| {
        var disk_calls: []DiskToolCall = &.{};
        if (msg.tool_calls.len > 0) {
            disk_calls = try allocator.alloc(DiskToolCall, msg.tool_calls.len);
            for (msg.tool_calls, 0..) |call, call_idx| {
                disk_calls[call_idx] = .{
                    .id = call.id,
                    .name = call.name,
                    .arguments = call.arguments,
                };
            }
        }
        disk_messages[idx] = .{
            .role = message_mod.roleString(msg.role),
            .content = msg.content,
            .tool_call_id = msg.tool_call_id,
            .tool_name = msg.tool_name,
            .tool_calls = disk_calls,
        };
    }
    defer {
        for (disk_messages) |msg| {
            if (msg.tool_calls.len > 0) allocator.free(msg.tool_calls);
        }
    }

    const payload = DiskSession{
        .id = session_id,
        .cwd = cwd,
        .model = model,
        .updated_at = std.time.timestamp(),
        .messages = disk_messages,
    };

    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(json);

    const file_path = try std.fmt.allocPrint(allocator, "{s}{c}{s}.json", .{
        paths.sessions_dir,
        std.fs.path.sep,
        session_id,
    });
    defer allocator.free(file_path);

    try atomic_write.writeFileAbsolute(file_path, json);
}

pub fn loadSession(
    allocator: std.mem.Allocator,
    paths: config_mod.AppPaths,
    requested_id: []const u8,
) !LoadedSession {
    const session_id = if (std.mem.eql(u8, requested_id, "latest"))
        try findLatestSessionId(allocator, paths)
    else
        try allocator.dupe(u8, requested_id);
    errdefer allocator.free(session_id);

    const file_path = try std.fmt.allocPrint(allocator, "{s}{c}{s}.json", .{
        paths.sessions_dir,
        std.fs.path.sep,
        session_id,
    });
    defer allocator.free(file_path);

    var file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(raw);

    const parsed = try std.json.parseFromSlice(DiskSession, allocator, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var messages = try allocator.alloc(message_mod.Message, parsed.value.messages.len);
    errdefer {
        for (messages) |*msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    for (parsed.value.messages, 0..) |disk_msg, index| {
        var owned_calls: []message_mod.ToolCall = &.{};
        if (disk_msg.tool_calls.len > 0) {
            owned_calls = try allocator.alloc(message_mod.ToolCall, disk_msg.tool_calls.len);
            for (disk_msg.tool_calls, 0..) |call, call_index| {
                owned_calls[call_index] = .{
                    .id = try allocator.dupe(u8, call.id),
                    .name = try allocator.dupe(u8, call.name),
                    .arguments = try allocator.dupe(u8, call.arguments),
                };
            }
        }

        messages[index] = .{
            .role = parseRole(disk_msg.role) orelse .user,
            .content = try allocator.dupe(u8, disk_msg.content),
            .tool_call_id = if (disk_msg.tool_call_id) |id| try allocator.dupe(u8, id) else null,
            .tool_name = if (disk_msg.tool_name) |name| try allocator.dupe(u8, name) else null,
            .tool_calls = owned_calls,
        };
    }

    return .{
        .id = session_id,
        .cwd = try allocator.dupe(u8, parsed.value.cwd),
        .model = try allocator.dupe(u8, parsed.value.model),
        .updated_at = parsed.value.updated_at,
        .messages = messages,
    };
}

pub fn findLatestSessionId(
    allocator: std.mem.Allocator,
    paths: config_mod.AppPaths,
) ![]u8 {
    var dir = try std.fs.openDirAbsolute(paths.sessions_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var latest_name: ?[]u8 = null;
    var latest_mtime: i128 = std.math.minInt(i128);

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const stat = try dir.statFile(entry.name);
        if (stat.mtime > latest_mtime) {
            if (latest_name) |name| allocator.free(name);
            latest_mtime = stat.mtime;
            latest_name = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".json".len]);
        }
    }

    return latest_name orelse error.SessionNotFound;
}

pub fn listSessions(
    allocator: std.mem.Allocator,
    paths: config_mod.AppPaths,
) ![]SessionSummary {
    var dir = std.fs.openDirAbsolute(paths.sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(SessionSummary, 0),
        else => return err,
    };
    defer dir.close();

    var list = std.ArrayList(SessionSummary).empty;
    defer list.deinit(allocator);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;

        var file = try dir.openFile(entry.name, .{});
        defer file.close();
        const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(raw);

        const parsed = try std.json.parseFromSlice(DiskSession, allocator, raw, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        try list.append(allocator, .{
            .id = try allocator.dupe(u8, parsed.value.id),
            .cwd = try allocator.dupe(u8, parsed.value.cwd),
            .model = try allocator.dupe(u8, parsed.value.model),
            .updated_at = parsed.value.updated_at,
            .message_count = parsed.value.messages.len,
        });
    }

    std.mem.sort(SessionSummary, list.items, {}, struct {
        fn lessThan(_: void, a: SessionSummary, b: SessionSummary) bool {
            return a.updated_at > b.updated_at;
        }
    }.lessThan);

    return try list.toOwnedSlice(allocator);
}

fn parseRole(name: []const u8) ?message_mod.Role {
    if (std.mem.eql(u8, name, "system")) return .system;
    if (std.mem.eql(u8, name, "user")) return .user;
    if (std.mem.eql(u8, name, "assistant")) return .assistant;
    if (std.mem.eql(u8, name, "tool")) return .tool;
    return null;
}
