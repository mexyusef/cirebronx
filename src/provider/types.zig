const std = @import("std");
const message_mod = @import("../core/message.zig");

pub const TurnObserver = struct {
    context: ?*anyopaque = null,
    on_status: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    on_text_chunk: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    on_tool_calls: ?*const fn (?*anyopaque, []const message_mod.ToolCall) anyerror!void = null,

    pub fn status(self: TurnObserver, text: []const u8) !void {
        if (self.on_status) |handler| try handler(self.context, text);
    }

    pub fn textChunk(self: TurnObserver, text: []const u8) !void {
        if (self.on_text_chunk) |handler| try handler(self.context, text);
    }

    pub fn toolCalls(self: TurnObserver, calls: []const message_mod.ToolCall) !void {
        if (self.on_tool_calls) |handler| try handler(self.context, calls);
    }
};

pub const TurnResult = union(enum) {
    assistant_text: []u8,
    tool_calls: []message_mod.ToolCall,

    pub fn deinit(self: *TurnResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .assistant_text => |text| allocator.free(text),
            .tool_calls => |calls| {
                for (calls) |*call| call.deinit(allocator);
                allocator.free(calls);
            },
        }
    }
};
