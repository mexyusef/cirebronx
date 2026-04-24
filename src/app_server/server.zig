const std = @import("std");
const fmus = @import("fmus");

const App = @import("../core/app.zig").App;
const message = @import("../core/message.zig");
const permissions = @import("../core/permissions.zig");
const runtime_turn = @import("../runtime/turn.zig");
const tools = @import("../tools/registry.zig");
const session_store = @import("../storage/session.zig");
const mcp_client = @import("../mcp/client.zig");
const mcp_helpers = @import("../mcp/helpers.zig");

pub const default_port: u16 = 9240;

const State = struct {
    app: *App,
};

pub fn run(app: *App, port: u16) !void {
    var router = fmus.jsonrpc.Router.init(app.allocator);
    defer router.deinit();

    var state = State{
        .app = app,
    };
    router.setContext(&state);
    try router.add("status/read", statusRead);
    try router.add("config/read", configRead);
    try router.add("session/list", sessionList);
    try router.add("session/read", sessionRead);
    try router.add("tool/list", toolList);
    try router.add("tool/call", toolCall);
    try router.add("mcp/list", mcpList);
    try router.add("mcp/call", mcpCall);
    try router.add("turn/start", turnStart);
    try router.add("turn/interrupt", turnInterrupt);

    var server = try std.net.Address.listen(try std.net.Address.parseIp("127.0.0.1", port), .{});
    defer server.deinit();

    const transport = fmus.jsonrpc.WsTransportServer.init(app.allocator, &router, .{
        .ws = .{ .protocol = "jsonrpc.2.0" },
    });

    std.debug.print("cirebronx app-server listening on ws://127.0.0.1:{d}\n", .{port});

    while (true) {
        const accepted = try server.accept();
        errdefer accepted.stream.close();
        var handshake_buf: [8192]u8 = undefined;
        var scratch: [8192]u8 = undefined;
        try transport.serveAccepted(accepted.stream, &handshake_buf, &scratch);
    }
}

fn statusRead(allocator: std.mem.Allocator, raw: ?*anyopaque, _: ?std.json.Value) ![]u8 {
    const state = getState(raw);
    return try fmus.json.stringifyAlloc(allocator, .{
        .session_id = state.app.session_id,
        .cwd = state.app.cwd,
        .provider = state.app.config.provider,
        .model = state.app.config.model,
        .base_url = state.app.config.base_url,
        .theme = state.app.config.theme,
        .message_count = state.app.session.items.len,
        .plan_mode = state.app.plan_mode,
        .last_provider_error = state.app.last_provider_error,
        .permissions = .{
            .read = permissions.modeString(state.app.permissions.read),
            .write = permissions.modeString(state.app.permissions.write),
            .shell = permissions.modeString(state.app.permissions.shell),
        },
    });
}

fn configRead(allocator: std.mem.Allocator, raw: ?*anyopaque, _: ?std.json.Value) ![]u8 {
    const state = getState(raw);
    return try fmus.json.stringifyAlloc(allocator, .{
        .provider = state.app.config.provider,
        .model = state.app.config.model,
        .base_url = state.app.config.base_url,
        .theme = state.app.config.theme,
        .paths = .{
            .app_dir = state.app.config.paths.app_dir,
            .config_path = state.app.config.paths.config_path,
            .sessions_dir = state.app.config.paths.sessions_dir,
            .histories_dir = state.app.config.paths.histories_dir,
        },
    });
}

fn sessionList(allocator: std.mem.Allocator, raw: ?*anyopaque, _: ?std.json.Value) ![]u8 {
    const state = getState(raw);
    const sessions = try session_store.listSessions(allocator, state.app.config.paths);
    defer {
        for (sessions) |*session| session.deinit(allocator);
        allocator.free(sessions);
    }
    return try fmus.json.stringifyAlloc(allocator, .{ .sessions = sessions });
}

fn sessionRead(allocator: std.mem.Allocator, raw: ?*anyopaque, params: ?std.json.Value) ![]u8 {
    const state = getState(raw);
    if (paramString(params, "id")) |session_id| {
        var loaded = try session_store.loadSession(allocator, state.app.config.paths, session_id);
        defer loaded.deinit(allocator);
        return try stringifyLoadedSession(allocator, loaded);
    }
    return try stringifyCurrentSession(allocator, state.app);
}

fn toolList(allocator: std.mem.Allocator, raw: ?*anyopaque, _: ?std.json.Value) ![]u8 {
    const state = getState(raw);
    return try fmus.json.stringifyAlloc(allocator, .{
        .tools = tools.toolsForExposure(state.app),
    });
}

fn toolCall(allocator: std.mem.Allocator, raw: ?*anyopaque, params: ?std.json.Value) ![]u8 {
    const state = getState(raw);
    const name = paramString(params, "name") orelse return error.InvalidArguments;
    const arguments_json = if (paramValue(params, "arguments")) |value|
        try fmus.json.stringifyAlloc(allocator, value)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(arguments_json);

    var discard_buf: [256]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&discard_buf);
    var call = message.ToolCall{
        .id = try allocator.dupe(u8, "app-server-call"),
        .name = try allocator.dupe(u8, name),
        .arguments = try allocator.dupe(u8, arguments_json),
    };
    defer call.deinit(allocator);
    const result = try tools.executeTool(allocator, .{
        .app = state.app,
        .io = .{
            .stdout = &discard.writer,
            .stdin = null,
            .interactive = false,
        },
    }, call);
    defer allocator.free(result);

    return try fmus.json.stringifyAlloc(allocator, .{
        .tool = name,
        .result = result,
    });
}

fn mcpList(allocator: std.mem.Allocator, raw: ?*anyopaque, _: ?std.json.Value) ![]u8 {
    const state = getState(raw);
    const servers = try mcp_helpers.loadServers(allocator, state.app.config.paths);
    defer mcp_helpers.deinitServers(allocator, servers);
    const status = try mcp_helpers.collectStatus(allocator, servers, state.app.cwd);
    defer mcp_helpers.deinitStatusLines(allocator, status);
    return try fmus.json.stringifyAlloc(allocator, .{ .servers = status });
}

fn mcpCall(allocator: std.mem.Allocator, raw: ?*anyopaque, params: ?std.json.Value) ![]u8 {
    const state = getState(raw);
    const server_name = paramString(params, "server") orelse return error.InvalidArguments;
    const tool_name = paramString(params, "tool") orelse return error.InvalidArguments;
    const arguments_json = if (paramValue(params, "arguments")) |value|
        try fmus.json.stringifyAlloc(allocator, value)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(arguments_json);

    const servers = try mcp_helpers.loadServers(allocator, state.app.config.paths);
    defer mcp_helpers.deinitServers(allocator, servers);
    const server = mcp_helpers.findServer(servers, server_name) orelse return error.InvalidArguments;
    const result = try mcp_client.callTool(allocator, server.*, state.app.cwd, tool_name, arguments_json);
    defer allocator.free(result);

    return try fmus.json.stringifyAlloc(allocator, .{
        .server = server_name,
        .tool = tool_name,
        .result = result,
    });
}

fn turnStart(allocator: std.mem.Allocator, raw: ?*anyopaque, params: ?std.json.Value) ![]u8 {
    const state = getState(raw);
    const prompt = paramString(params, "prompt") orelse return error.InvalidArguments;

    var collector = EventCollector.init(allocator);
    defer collector.deinit();

    var discard_buf: [256]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&discard_buf);

    var turn_result = try runtime_turn.runPrompt(state.app, prompt, .{
        .context = &collector,
        .on_status = EventCollector.onStatus,
        .on_text_chunk = EventCollector.onTextChunk,
        .on_tool_calls = EventCollector.onToolCalls,
        .on_tool_result = EventCollector.onToolResult,
    }, .{
        .io = .{
            .stdout = &discard.writer,
            .stdin = null,
            .interactive = false,
        },
    });
    defer turn_result.deinit(allocator);

    return try fmus.json.stringifyAlloc(allocator, .{
        .session_id = state.app.session_id,
        .final_text = turn_result.final_text,
        .tool_rounds = turn_result.tool_rounds,
        .steps = turn_result.steps,
        .events = collector.items.items,
    });
}

fn turnInterrupt(allocator: std.mem.Allocator, _: ?*anyopaque, _: ?std.json.Value) ![]u8 {
    return try fmus.json.stringifyAlloc(allocator, .{
        .interrupted = false,
        .reason = "no interruptible app-server turn is running",
    });
}

fn stringifyCurrentSession(allocator: std.mem.Allocator, app: *App) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const messages_json = try buildMessageJsonArray(a, app.session.items);
    return try fmus.json.stringifyAlloc(allocator, .{
        .id = app.session_id,
        .cwd = app.cwd,
        .model = app.config.model,
        .message_count = app.session.items.len,
        .messages = messages_json,
    });
}

fn stringifyLoadedSession(allocator: std.mem.Allocator, loaded: session_store.LoadedSession) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const messages_json = try buildMessageJsonArray(a, loaded.messages);
    return try fmus.json.stringifyAlloc(allocator, .{
        .id = loaded.id,
        .cwd = loaded.cwd,
        .model = loaded.model,
        .updated_at = loaded.updated_at,
        .message_count = loaded.messages.len,
        .messages = messages_json,
    });
}

fn buildMessageJsonArray(allocator: std.mem.Allocator, messages: []const message.Message) ![]const MessageJson {
    const out = try allocator.alloc(MessageJson, messages.len);
    for (messages, 0..) |msg, idx| {
        var calls: []const ToolCallJson = &.{};
        if (msg.tool_calls.len > 0) {
            var owned = try allocator.alloc(ToolCallJson, msg.tool_calls.len);
            for (msg.tool_calls, 0..) |call, call_idx| {
                owned[call_idx] = .{
                    .id = call.id,
                    .name = call.name,
                    .arguments = call.arguments,
                };
            }
            calls = owned;
        }
        out[idx] = .{
            .role = message.roleString(msg.role),
            .content = msg.content,
            .tool_call_id = msg.tool_call_id,
            .tool_name = msg.tool_name,
            .tool_calls = calls,
        };
    }
    return out;
}

const ToolCallJson = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

const MessageJson = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_calls: []const ToolCallJson = &.{},
};

const Event = struct {
    kind: []u8,
    text: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    arguments: ?[]u8 = null,
    result: ?[]u8 = null,

    fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        if (self.text) |text| allocator.free(text);
        if (self.tool_name) |name| allocator.free(name);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.arguments) |args| allocator.free(args);
        if (self.result) |result| allocator.free(result);
    }
};

const EventCollector = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Event),

    fn init(allocator: std.mem.Allocator) EventCollector {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    fn deinit(self: *EventCollector) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    fn onStatus(raw: ?*anyopaque, text: []const u8) !void {
        const self: *EventCollector = @ptrCast(@alignCast(raw.?));
        try self.items.append(self.allocator, .{
            .kind = try self.allocator.dupe(u8, "status"),
            .text = try self.allocator.dupe(u8, text),
        });
    }

    fn onTextChunk(raw: ?*anyopaque, text: []const u8) !void {
        const self: *EventCollector = @ptrCast(@alignCast(raw.?));
        try self.items.append(self.allocator, .{
            .kind = try self.allocator.dupe(u8, "text_chunk"),
            .text = try self.allocator.dupe(u8, text),
        });
    }

    fn onToolCalls(raw: ?*anyopaque, calls: []const message.ToolCall) !void {
        const self: *EventCollector = @ptrCast(@alignCast(raw.?));
        for (calls) |call| {
            try self.items.append(self.allocator, .{
                .kind = try self.allocator.dupe(u8, "tool_call"),
                .tool_name = try self.allocator.dupe(u8, call.name),
                .tool_call_id = try self.allocator.dupe(u8, call.id),
                .arguments = try self.allocator.dupe(u8, call.arguments),
            });
        }
    }

    fn onToolResult(raw: ?*anyopaque, tool_call_id: []const u8, tool_name: []const u8, result: []const u8) !void {
        const self: *EventCollector = @ptrCast(@alignCast(raw.?));
        try self.items.append(self.allocator, .{
            .kind = try self.allocator.dupe(u8, "tool_result"),
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
            .result = try self.allocator.dupe(u8, result),
        });
    }
};

fn getState(raw: ?*anyopaque) *State {
    return @ptrCast(@alignCast(raw.?));
}

fn paramValue(params: ?std.json.Value, name: []const u8) ?std.json.Value {
    const value = params orelse return null;
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn paramString(params: ?std.json.Value, name: []const u8) ?[]const u8 {
    const value = paramValue(params, name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

test "statusRead returns current app state" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();
    var state = State{ .app = &app };

    const json = try statusRead(std.testing.allocator, &state, null);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"permissions\"") != null);
}

test "sessionRead without id returns current session snapshot" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();
    try app.appendMessage(.{ .role = .user, .content = "hello" });

    var state = State{ .app = &app };
    const json = try sessionRead(std.testing.allocator, &state, null);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"message_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hello\"") != null);
}

test "turnInterrupt returns structured compatibility response" {
    const json = try turnInterrupt(std.testing.allocator, null, null);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"interrupted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "no interruptible app-server turn is running") != null);
}
