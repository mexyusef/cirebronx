const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments: []u8,

    pub fn deinit(self: *ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

pub const Message = struct {
    role: Role,
    content: []u8,
    tool_call_id: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.tool_name) |name| allocator.free(name);
        if (self.tool_calls.len > 0) {
            for (self.tool_calls) |*call| call.deinit(allocator);
            allocator.free(self.tool_calls);
        }
    }
};

pub const MessageView = struct {
    role: Role,
    content: []const u8,
};

pub fn roleString(role: Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}
