const std = @import("std");

const App = @import("../core/app.zig").App;
const message_mod = @import("../core/message.zig");
const permissions = @import("../core/permissions.zig");
const provider = @import("../provider/adapter.zig");
const openrouter_pool = @import("../provider/openrouter_pool.zig");
const provider_types = @import("../provider/types.zig");
const tools = @import("../tools/registry.zig");

pub const ToolResult = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    content: []u8,

    fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        allocator.free(self.content);
    }
};

pub const TurnEvent = union(enum) {
    status: []u8,
    text_chunk: []u8,
    tool_calls: []message_mod.ToolCall,
    tool_result: ToolResult,
    assistant_text: []u8,
    turn_error: []u8,
    done: void,

    pub fn deinit(self: *TurnEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .status, .text_chunk, .assistant_text, .turn_error => |text| allocator.free(text),
            .tool_calls => |calls| {
                for (calls) |*call| call.deinit(allocator);
                allocator.free(calls);
            },
            .tool_result => |*result| result.deinit(allocator),
            .done => {},
        }
    }
};

pub const TurnQueue = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    mutex: std.Thread.Mutex = .{},
    events: std.ArrayList(TurnEvent) = .empty,

    pub fn deinit(self: *TurnQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    pub fn poll(self: *TurnQueue) ![]TurnEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.toOwnedSlice(self.allocator);
    }

    fn push(self: *TurnQueue, event: TurnEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events.append(self.allocator, event) catch {
            var owned = event;
            owned.deinit(self.allocator);
        };
    }
};

const Snapshot = struct {
    session_id: []u8,
    cwd: []u8,
    provider: []u8,
    model: []u8,
    base_url: []u8,
    api_key: []u8,
    theme: []u8,
    permissions: permissions.PermissionSet,
    plan_mode: bool,
    messages: []message_mod.Message,

    fn clone(allocator: std.mem.Allocator, app: *const App) !Snapshot {
        var messages = try allocator.alloc(message_mod.Message, app.session.items.len);
        errdefer {
            for (messages) |*msg| msg.deinit(allocator);
            allocator.free(messages);
        }

        for (app.session.items, 0..) |msg, index| {
            var owned_calls: []message_mod.ToolCall = &.{};
            if (msg.tool_calls.len > 0) {
                owned_calls = try allocator.alloc(message_mod.ToolCall, msg.tool_calls.len);
                for (msg.tool_calls, 0..) |call, call_index| {
                    owned_calls[call_index] = .{
                        .id = try allocator.dupe(u8, call.id),
                        .name = try allocator.dupe(u8, call.name),
                        .arguments = try allocator.dupe(u8, call.arguments),
                    };
                }
            }

            messages[index] = .{
                .role = msg.role,
                .content = try allocator.dupe(u8, msg.content),
                .tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null,
                .tool_name = if (msg.tool_name) |name| try allocator.dupe(u8, name) else null,
                .tool_calls = owned_calls,
            };
        }

        return .{
            .session_id = try allocator.dupe(u8, app.session_id),
            .cwd = try allocator.dupe(u8, app.cwd),
            .provider = try allocator.dupe(u8, app.config.provider),
            .model = try allocator.dupe(u8, app.config.model),
            .base_url = try allocator.dupe(u8, app.config.base_url),
            .api_key = try allocator.dupe(u8, app.config.api_key),
            .theme = try allocator.dupe(u8, app.config.theme),
            .permissions = app.permissions,
            .plan_mode = app.plan_mode,
            .messages = messages,
        };
    }

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.cwd);
        allocator.free(self.provider);
        allocator.free(self.model);
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        allocator.free(self.theme);
        for (self.messages) |*msg| msg.deinit(allocator);
        allocator.free(self.messages);
    }
};

pub fn spawn(queue: *TurnQueue, app: *const App) !void {
    const snapshot = try Snapshot.clone(std.heap.page_allocator, app);
    errdefer {
        var owned = snapshot;
        owned.deinit(std.heap.page_allocator);
    }

    const Task = struct {
        queue: *TurnQueue,
        snapshot: Snapshot,

        fn run(task: *@This()) void {
            defer {
                var owned = task.snapshot;
                owned.deinit(std.heap.page_allocator);
                std.heap.page_allocator.destroy(task);
            }

            var gpa: std.heap.DebugAllocator(.{}) = .init;
            const allocator = gpa.allocator();
            defer {
                openrouter_pool.deinitGlobal(allocator);
                _ = gpa.deinit();
            }

            var worker_app = App.init(allocator) catch |err| {
                pushError(task.queue, tryFmt(std.heap.page_allocator, "worker init error: {s}", .{@errorName(err)}));
                task.queue.push(.done);
                return;
            };
            defer worker_app.deinit();

            hydrateWorkerApp(allocator, &worker_app, &task.snapshot) catch |err| {
                pushError(task.queue, tryFmt(std.heap.page_allocator, "worker hydrate error: {s}", .{@errorName(err)}));
                task.queue.push(.done);
                return;
            };

            runWorkerTurn(task.queue, &worker_app) catch |err| {
                pushError(task.queue, tryFmt(std.heap.page_allocator, "worker error: {s}", .{@errorName(err)}));
            };
            task.queue.push(.done);
        }
    };

    const worker_task = try std.heap.page_allocator.create(Task);
    worker_task.* = .{
        .queue = queue,
        .snapshot = snapshot,
    };
    const thread = try std.Thread.spawn(.{}, struct {
        fn entry(thread_task: *Task) void {
            thread_task.run();
        }
    }.entry, .{worker_task});
    thread.detach();
}

fn hydrateWorkerApp(allocator: std.mem.Allocator, worker_app: *App, snapshot: *const Snapshot) !void {
    try worker_app.replaceSession(snapshot.session_id, snapshot.model, snapshot.messages);
    allocator.free(worker_app.cwd);
    worker_app.cwd = try allocator.dupe(u8, snapshot.cwd);
    allocator.free(worker_app.config.provider);
    worker_app.config.provider = try allocator.dupe(u8, snapshot.provider);
    allocator.free(worker_app.config.base_url);
    worker_app.config.base_url = try allocator.dupe(u8, snapshot.base_url);
    allocator.free(worker_app.config.api_key);
    worker_app.config.api_key = try allocator.dupe(u8, snapshot.api_key);
    allocator.free(worker_app.config.theme);
    worker_app.config.theme = try allocator.dupe(u8, snapshot.theme);
    worker_app.permissions = snapshot.permissions;
    worker_app.plan_mode = snapshot.plan_mode;
}

fn runWorkerTurn(queue: *TurnQueue, app: *App) !void {
    var io_capture: std.Io.Writer.Allocating = .init(app.allocator);
    defer io_capture.deinit();

    const ctx = tools.ExecutionContext{
        .app = app,
        .io = .{
            .stdout = &io_capture.writer,
            .stdin = null,
            .interactive = false,
            .approval = null,
        },
    };
    const visible_tools = tools.toolsForExposure(app);
    var observer_context = ObserverContext{ .queue = queue };
    const observer = provider.TurnObserver{
        .context = &observer_context,
        .on_status = onStatus,
        .on_text_chunk = onTextChunk,
        .on_tool_calls = onToolCalls,
    };

    var seen_tool_calls = std.ArrayList(u64).empty;
    defer seen_tool_calls.deinit(app.allocator);
    var web_search_runs: usize = 0;

    var step: usize = 0;
    while (step < 8) : (step += 1) {
        pushStatus(queue, if (step == 0) "requesting model" else "continuing tool loop");
        var turn = provider.sendTurnObserved(app, visible_tools, observer) catch |err| {
            pushError(queue, tryFmt(std.heap.page_allocator, "error: {s}", .{@errorName(err)}));
            return;
        };
        defer turn.deinit(app.allocator);

        switch (turn) {
            .assistant_text => |text| {
                try app.appendAssistantText(text);
                pushAssistantText(queue, text);
                pushStatus(queue, "assistant replied");
                return;
            },
            .tool_calls => |calls| {
                try app.appendAssistantToolCalls(calls);
                pushToolCalls(queue, calls);
                for (calls) |call| {
                    pushStatus(queue, tryFmt(std.heap.page_allocator, "tool running: {s}", .{call.name}));
                    const result = executeToolWithLoopGuard(
                        app.allocator,
                        ctx,
                        call,
                        &seen_tool_calls,
                        &web_search_runs,
                    ) catch |err| try std.fmt.allocPrint(app.allocator, "tool error: {s}", .{@errorName(err)});
                    defer app.allocator.free(result);
                    try app.appendToolResult(call.id, call.name, result);
                    pushToolResult(queue, call.id, call.name, result);
                }
            },
        }
    }

    pushError(queue, "error: MaxStepsReached");
}

fn executeToolWithLoopGuard(
    allocator: std.mem.Allocator,
    ctx: tools.ExecutionContext,
    call: message_mod.ToolCall,
    seen_tool_calls: *std.ArrayList(u64),
    web_search_runs: *usize,
) ![]u8 {
    const fingerprint = toolCallFingerprint(call);
    for (seen_tool_calls.items) |existing| {
        if (existing == fingerprint) {
            return try std.fmt.allocPrint(allocator,
                "duplicate tool call suppressed: {s}\nuse the existing result for this same call and provide an answer or a different next action.",
                .{call.name},
            );
        }
    }
    try seen_tool_calls.append(allocator, fingerprint);
    if (std.mem.eql(u8, call.name, "web_search")) {
        web_search_runs.* += 1;
        if (web_search_runs.* > 3) {
            return try allocator.dupe(u8,
                "web_search retry limit reached for this turn.\nuse the previous search results already returned and answer the user instead of repeating similar searches."
            );
        }
    }
    return try tools.executeTool(allocator, ctx, call);
}

fn toolCallFingerprint(call: message_mod.ToolCall) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(call.name);
    hasher.update(&[_]u8{0});
    hasher.update(call.arguments);
    return hasher.final();
}

const ObserverContext = struct {
    queue: *TurnQueue,
};

fn onStatus(raw: ?*anyopaque, text: []const u8) anyerror!void {
    const context: *ObserverContext = @ptrCast(@alignCast(raw.?));
    pushStatus(context.queue, text);
}

fn onTextChunk(raw: ?*anyopaque, text: []const u8) anyerror!void {
    const context: *ObserverContext = @ptrCast(@alignCast(raw.?));
    pushTextChunk(context.queue, text);
}

fn onToolCalls(raw: ?*anyopaque, calls: []const message_mod.ToolCall) anyerror!void {
    _ = raw;
    _ = calls;
}

fn pushStatus(queue: *TurnQueue, text: []const u8) void {
    queue.push(.{ .status = std.heap.page_allocator.dupe(u8, text) catch return });
}

fn pushTextChunk(queue: *TurnQueue, text: []const u8) void {
    queue.push(.{ .text_chunk = std.heap.page_allocator.dupe(u8, text) catch return });
}

fn pushAssistantText(queue: *TurnQueue, text: []const u8) void {
    queue.push(.{ .assistant_text = std.heap.page_allocator.dupe(u8, text) catch return });
}

fn pushError(queue: *TurnQueue, text: []const u8) void {
    queue.push(.{ .turn_error = std.heap.page_allocator.dupe(u8, text) catch return });
}

fn pushToolCalls(queue: *TurnQueue, calls: []const message_mod.ToolCall) void {
    const allocator = std.heap.page_allocator;
    var owned = allocator.alloc(message_mod.ToolCall, calls.len) catch return;
    errdefer {
        for (owned) |*call| call.deinit(allocator);
        allocator.free(owned);
    }
    for (calls, 0..) |call, index| {
        owned[index] = .{
            .id = allocator.dupe(u8, call.id) catch return,
            .name = allocator.dupe(u8, call.name) catch return,
            .arguments = allocator.dupe(u8, call.arguments) catch return,
        };
    }
    queue.push(.{ .tool_calls = owned });
}

fn pushToolResult(queue: *TurnQueue, tool_call_id: []const u8, tool_name: []const u8, content: []const u8) void {
    const allocator = std.heap.page_allocator;
    queue.push(.{
        .tool_result = .{
            .tool_call_id = allocator.dupe(u8, tool_call_id) catch return,
            .tool_name = allocator.dupe(u8, tool_name) catch return,
            .content = allocator.dupe(u8, content) catch return,
        },
    });
}

fn tryFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch allocator.dupe(u8, "error") catch unreachable;
}
