const std = @import("std");

const App = @import("../core/app.zig").App;
const message = @import("../core/message.zig");
const permissions = @import("../core/permissions.zig");
const provider = @import("../provider/adapter.zig");
const provider_types = @import("../provider/types.zig");
const session_store = @import("../storage/session.zig");
const tools = @import("../tools/registry.zig");

pub const Options = struct {
    io: permissions.PromptIo,
    save_session: bool = true,
    max_steps: usize = 8,
};

pub const Hooks = struct {
    context: ?*anyopaque = null,
    on_status: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    on_text_chunk: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    on_tool_calls: ?*const fn (?*anyopaque, []const message.ToolCall) anyerror!void = null,
    on_tool_result: ?*const fn (?*anyopaque, []const u8, []const u8, []const u8) anyerror!void = null,

    pub fn status(self: Hooks, text: []const u8) !void {
        if (self.on_status) |handler| try handler(self.context, text);
    }

    pub fn textChunk(self: Hooks, text: []const u8) !void {
        if (self.on_text_chunk) |handler| try handler(self.context, text);
    }

    pub fn toolCalls(self: Hooks, calls: []const message.ToolCall) !void {
        if (self.on_tool_calls) |handler| try handler(self.context, calls);
    }

    pub fn toolResult(self: Hooks, tool_call_id: []const u8, tool_name: []const u8, result: []const u8) !void {
        if (self.on_tool_result) |handler| try handler(self.context, tool_call_id, tool_name, result);
    }
};

pub const Result = struct {
    final_text: ?[]u8 = null,
    tool_rounds: usize = 0,
    steps: usize = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.final_text) |text| allocator.free(text);
    }
};

pub const Error = error{
    TurnStepLimitExceeded,
} || tools.ToolExecutionError || anyerror;

pub fn runPrompt(app: *App, prompt: []const u8, hooks: Hooks, options: Options) Error!Result {
    try app.appendMessage(.{
        .role = .user,
        .content = prompt,
    });

    const ctx = tools.ExecutionContext{
        .app = app,
        .io = options.io,
    };
    const visible_tools = tools.toolsForExposure(app);
    const observer = provider_types.TurnObserver{
        .context = @constCast(&hooks),
        .on_status = onStatus,
        .on_text_chunk = onTextChunk,
        .on_tool_calls = onToolCalls,
    };

    var result = Result{};
    errdefer result.deinit(app.allocator);

    var step: usize = 0;
    while (step < options.max_steps) : (step += 1) {
        var turn = try provider.sendTurnObserved(app, visible_tools, observer);
        defer turn.deinit(app.allocator);

        switch (turn) {
            .assistant_text => |text| {
                try app.appendAssistantText(text);
                result.final_text = try app.allocator.dupe(u8, text);
                result.steps = step + 1;
                if (options.save_session) try saveSession(app);
                return result;
            },
            .tool_calls => |calls| {
                result.tool_rounds += 1;
                try hooks.toolCalls(calls);
                try app.appendAssistantToolCalls(calls);
                for (calls) |call| {
                    const tool_result = tools.executeTool(app.allocator, ctx, call) catch |err| blk: {
                        break :blk try std.fmt.allocPrint(app.allocator, "tool error: {s}", .{ @errorName(err) });
                    };
                    defer app.allocator.free(tool_result);
                    try hooks.toolResult(call.id, call.name, tool_result);
                    try app.appendToolResult(call.id, call.name, tool_result);
                }
            },
        }
    }

    result.steps = options.max_steps;
    if (options.save_session) try saveSession(app);
    return Error.TurnStepLimitExceeded;
}

fn saveSession(app: *App) !void {
    try session_store.saveSession(
        app.allocator,
        app.config.paths,
        app.session_id,
        app.cwd,
        app.config.model,
        app.session.items,
    );
}

fn onStatus(raw: ?*anyopaque, text: []const u8) !void {
    const hooks: *const Hooks = @ptrCast(@alignCast(raw.?));
    try hooks.status(text);
}

fn onTextChunk(raw: ?*anyopaque, text: []const u8) !void {
    const hooks: *const Hooks = @ptrCast(@alignCast(raw.?));
    try hooks.textChunk(text);
}

fn onToolCalls(raw: ?*anyopaque, calls: []const message.ToolCall) !void {
    const hooks: *const Hooks = @ptrCast(@alignCast(raw.?));
    try hooks.toolCalls(calls);
}
