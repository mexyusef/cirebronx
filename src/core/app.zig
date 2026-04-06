const std = @import("std");

const config_mod = @import("../storage/config.zig");
const message_mod = @import("message.zig");
const permissions_mod = @import("permissions.zig");
const path_util = @import("../util/paths.zig");
const random_util = @import("../util/random.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    config: config_mod.Config,
    session: std.ArrayList(message_mod.Message),
    session_id: []u8,
    cwd: []u8,
    permissions: permissions_mod.PermissionSet,
    plan_mode: bool,
    last_provider_error: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) !App {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const paths = try path_util.resolveAppPaths(allocator);
        const session_id = try random_util.makeSessionId(allocator);
        const cwd = try std.process.getCwdAlloc(allocator);

        return .{
            .allocator = allocator,
            .arena = arena,
            .config = try config_mod.ownedDefaultConfig(allocator, paths),
            .session = .empty,
            .session_id = session_id,
            .cwd = cwd,
            .permissions = .{},
            .plan_mode = false,
            .last_provider_error = null,
        };
    }

    pub fn deinit(self: *App) void {
        for (self.session.items) |*msg| msg.deinit(self.allocator);
        self.session.deinit(self.allocator);
        self.allocator.free(self.session_id);
        self.allocator.free(self.cwd);
        if (self.last_provider_error) |text| self.allocator.free(text);
        self.config.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn setLastProviderError(self: *App, text: []const u8) !void {
        self.clearLastProviderError();
        self.last_provider_error = try self.allocator.dupe(u8, text);
    }

    pub fn clearLastProviderError(self: *App) void {
        if (self.last_provider_error) |text| self.allocator.free(text);
        self.last_provider_error = null;
    }

    pub fn appendMessage(self: *App, msg: message_mod.MessageView) !void {
        try self.session.append(self.allocator, .{
            .role = msg.role,
            .content = try self.allocator.dupe(u8, msg.content),
        });
    }

    pub fn appendAssistantText(self: *App, text: []const u8) !void {
        try self.session.append(self.allocator, .{
            .role = .assistant,
            .content = try self.allocator.dupe(u8, text),
        });
    }

    pub fn appendAssistantToolCalls(self: *App, tool_calls: []const message_mod.ToolCall) !void {
        var owned_calls = try self.allocator.alloc(message_mod.ToolCall, tool_calls.len);
        for (tool_calls, 0..) |call, idx| {
            owned_calls[idx] = .{
                .id = try self.allocator.dupe(u8, call.id),
                .name = try self.allocator.dupe(u8, call.name),
                .arguments = try self.allocator.dupe(u8, call.arguments),
            };
        }

        try self.session.append(self.allocator, .{
            .role = .assistant,
            .content = try self.allocator.dupe(u8, ""),
            .tool_calls = owned_calls,
        });
    }

    pub fn appendToolResult(
        self: *App,
        tool_call_id: []const u8,
        tool_name: []const u8,
        content: []const u8,
    ) !void {
        try self.session.append(self.allocator, .{
            .role = .tool,
            .content = try self.allocator.dupe(u8, content),
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
            .tool_name = try self.allocator.dupe(u8, tool_name),
        });
    }

    pub fn clearSession(self: *App) void {
        for (self.session.items) |*msg| msg.deinit(self.allocator);
        self.session.clearRetainingCapacity();
    }

    pub fn replaceSession(
        self: *App,
        session_id: []const u8,
        model: []const u8,
        messages: []const message_mod.Message,
    ) !void {
        self.clearSession();

        self.allocator.free(self.session_id);
        self.session_id = try self.allocator.dupe(u8, session_id);

        self.allocator.free(self.config.model);
        self.config.model = try self.allocator.dupe(u8, model);

        for (messages) |msg| {
            var owned_calls: []message_mod.ToolCall = &.{};
            if (msg.tool_calls.len > 0) {
                owned_calls = try self.allocator.alloc(message_mod.ToolCall, msg.tool_calls.len);
                for (msg.tool_calls, 0..) |call, index| {
                    owned_calls[index] = .{
                        .id = try self.allocator.dupe(u8, call.id),
                        .name = try self.allocator.dupe(u8, call.name),
                        .arguments = try self.allocator.dupe(u8, call.arguments),
                    };
                }
            }

            try self.session.append(self.allocator, .{
                .role = msg.role,
                .content = try self.allocator.dupe(u8, msg.content),
                .tool_call_id = if (msg.tool_call_id) |id| try self.allocator.dupe(u8, id) else null,
                .tool_name = if (msg.tool_name) |name| try self.allocator.dupe(u8, name) else null,
                .tool_calls = owned_calls,
            });
        }
    }

    pub fn compactSession(self: *App, keep_recent: usize) !bool {
        if (self.session.items.len <= keep_recent) return false;

        const dropped_count = self.session.items.len - keep_recent;
        const dropped = self.session.items[0..dropped_count];
        const kept = self.session.items[dropped_count..];

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        try out.writer.print("Compacted earlier conversation.\nDropped messages: {d}\nKept recent messages: {d}\n\nSummary of earlier context:\n", .{
            dropped.len,
            kept.len,
        });

        const preview_start = dropped.len -| 8;
        for (dropped[preview_start..], preview_start..) |msg, index| {
            const preview = if (msg.content.len == 0) "<empty>" else msg.content[0..@min(msg.content.len, 160)];
            try out.writer.print("- {d}. [{s}] {s}\n", .{
                index + 1,
                message_mod.roleString(msg.role),
                preview,
            });
        }

        var next = std.ArrayList(message_mod.Message).empty;
        errdefer {
            for (next.items) |*msg| msg.deinit(self.allocator);
            next.deinit(self.allocator);
        }

        try next.append(self.allocator, .{
            .role = .system,
            .content = try self.allocator.dupe(u8, out.written()),
        });

        for (kept) |msg| {
            var owned_calls: []message_mod.ToolCall = &.{};
            if (msg.tool_calls.len > 0) {
                owned_calls = try self.allocator.alloc(message_mod.ToolCall, msg.tool_calls.len);
                for (msg.tool_calls, 0..) |call, index| {
                    owned_calls[index] = .{
                        .id = try self.allocator.dupe(u8, call.id),
                        .name = try self.allocator.dupe(u8, call.name),
                        .arguments = try self.allocator.dupe(u8, call.arguments),
                    };
                }
            }
            try next.append(self.allocator, .{
                .role = msg.role,
                .content = try self.allocator.dupe(u8, msg.content),
                .tool_call_id = if (msg.tool_call_id) |id| try self.allocator.dupe(u8, id) else null,
                .tool_name = if (msg.tool_name) |name| try self.allocator.dupe(u8, name) else null,
                .tool_calls = owned_calls,
            });
        }

        self.clearSession();
        self.session = next;
        return true;
    }
};
