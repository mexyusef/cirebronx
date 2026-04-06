const std = @import("std");

const App = @import("../core/app.zig").App;
const message_mod = @import("../core/message.zig");
const tool_base = @import("../tools/base.zig");
const provider_types = @import("types.zig");

pub const TurnResult = provider_types.TurnResult;
pub const TurnObserver = provider_types.TurnObserver;

const client_headers = [_]std.http.Header{
    .{ .name = "anthropic-version", .value = "2023-06-01" },
    .{ .name = "x-client-name", .value = "cirebronx" },
};

const ResponseEnvelope = struct {
    content: []ContentBlock,
    stop_reason: ?[]const u8 = null,
};

const ContentBlock = struct {
    @"type": []const u8,
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

const StreamEnvelope = struct {
    @"type": []const u8,
    index: ?usize = null,
    delta: ?StreamDelta = null,
    content_block: ?StreamContentBlock = null,
    @"error": ?StreamErrorInfo = null,
};

const StreamDelta = struct {
    @"type": []const u8,
    text: ?[]const u8 = null,
    partial_json: ?[]const u8 = null,
};

const StreamContentBlock = struct {
    @"type": []const u8,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

const StreamErrorInfo = struct {
    @"type": []const u8,
    message: []const u8,
};

const ToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    input_json: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolAccumulator, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.input_json.deinit(allocator);
    }
};

pub fn sendTurn(app: *App, tools: []const tool_base.ToolSpec) !TurnResult {
    return sendTurnObserved(app, tools, .{});
}

pub fn sendTurnObserved(app: *App, tools: []const tool_base.ToolSpec, observer: TurnObserver) !TurnResult {
    if (app.config.api_key.len == 0) return error.MissingApiKey;
    try observer.status("provider request");

    var client: std.http.Client = .{ .allocator = app.allocator };
    defer client.deinit();

    const body = try buildRequestBody(app.allocator, app, tools, true);
    defer app.allocator.free(body);

    const uri = try std.Uri.parse(app.config.base_url);

    var request = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &.{
            client_headers[0],
            client_headers[1],
            .{ .name = "x-api-key", .value = app.config.api_key },
        },
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try request.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try request.connection.?.flush();

    var response = try request.receiveHead(&.{});
    if (response.head.status != .ok) {
        try observer.status("provider error");
        return error.ProviderRequestFailed;
    }
    try observer.status("provider stream open");
    return try parseStreamingResponse(app.allocator, &response, observer);
}

fn buildRequestBody(
    allocator: std.mem.Allocator,
    app: *App,
    tools: []const tool_base.ToolSpec,
    stream: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeByte('{');
    try out.writer.writeAll("\"model\":");
    try std.json.Stringify.value(app.config.model, .{}, &out.writer);
    try out.writer.writeAll(",\"max_tokens\":4096");

    if (app.plan_mode) {
        try out.writer.writeAll(",\"system\":");
        try std.json.Stringify.value(
            "You are Cirebronx, a coding agent. Prefer tool use for inspection and edits. Keep plans explicit before complex changes.",
            .{},
            &out.writer,
        );
    }

    try out.writer.writeAll(",\"messages\":[");
    try writeMessages(&out.writer, app.session.items);
    try out.writer.writeByte(']');

    if (tools.len > 0) {
        try out.writer.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeByte('{');
            try out.writer.writeAll("\"name\":");
            try std.json.Stringify.value(tool.name, .{}, &out.writer);
            try out.writer.writeAll(",\"description\":");
            try std.json.Stringify.value(tool.description, .{}, &out.writer);
            try out.writer.writeAll(",\"input_schema\":");
            try out.writer.writeAll(tool.schema_json);
            try out.writer.writeByte('}');
        }
        try out.writer.writeByte(']');
    }

    try out.writer.writeAll(",\"stream\":");
    try out.writer.writeAll(if (stream) "true" else "false");
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn parseStreamingResponse(
    allocator: std.mem.Allocator,
    response: *std.http.Client.Response,
    observer: TurnObserver,
) !TurnResult {
    var transfer_buffer: [256]u8 = undefined;
    var reader = response.reader(&transfer_buffer);
    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(allocator);
    var tool_calls: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tool_calls.items) |*call| call.deinit(allocator);
        tool_calls.deinit(allocator);
    }

    var current_event: ?[]const u8 = null;
    while (try reader.takeDelimiter('\n')) |line_with_newline| {
        const line = std.mem.trimRight(u8, line_with_newline, "\r\n");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "event: ")) {
            current_event = line["event: ".len..];
            continue;
        }
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const payload = line["data: ".len..];
        if (current_event) |event_name| {
            try consumeStreamEvent(allocator, event_name, payload, &text_out, &tool_calls, observer);
        }
    }

    if (tool_calls.items.len > 0) {
        const owned = try finalizeToolCalls(allocator, tool_calls.items);
        try observer.status("provider tool calls");
        try observer.toolCalls(owned);
        return .{ .tool_calls = owned };
    }

    try observer.status("provider response");
    return .{ .assistant_text = try text_out.toOwnedSlice(allocator) };
}

fn consumeStreamEvent(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    payload: []const u8,
    text_out: *std.ArrayList(u8),
    tool_calls: *std.ArrayList(ToolAccumulator),
    observer: TurnObserver,
) !void {
    if (std.mem.eql(u8, event_name, "ping") or std.mem.eql(u8, event_name, "message_start") or std.mem.eql(u8, event_name, "message_delta") or std.mem.eql(u8, event_name, "message_stop") or std.mem.eql(u8, event_name, "content_block_stop")) {
        return;
    }

    const parsed = try std.json.parseFromSlice(StreamEnvelope, allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (std.mem.eql(u8, event_name, "error")) {
        return error.ProviderRequestFailed;
    }

    if (std.mem.eql(u8, event_name, "content_block_start")) {
        if (parsed.value.index) |index| {
            if (parsed.value.content_block) |block| {
                if (std.mem.eql(u8, block.@"type", "tool_use")) {
                    try ensureToolAccumulator(tool_calls, allocator, index);
                    var target = &tool_calls.items[index];
                    if (block.id) |id| try target.id.appendSlice(allocator, id);
                    if (block.name) |name| try target.name.appendSlice(allocator, name);
                } else if (std.mem.eql(u8, block.@"type", "text")) {
                    if (block.text) |text| {
                        try text_out.appendSlice(allocator, text);
                        if (text.len > 0) try emitObservedText(observer, text);
                    }
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_name, "content_block_delta")) {
        if (parsed.value.delta) |delta| {
            if (std.mem.eql(u8, delta.@"type", "text_delta")) {
                if (delta.text) |text| {
                    try text_out.appendSlice(allocator, text);
                    if (text.len > 0) try emitObservedText(observer, text);
                }
            } else if (std.mem.eql(u8, delta.@"type", "input_json_delta")) {
                if (parsed.value.index) |index| {
                    try ensureToolAccumulator(tool_calls, allocator, index);
                    if (delta.partial_json) |json_part| {
                        try tool_calls.items[index].input_json.appendSlice(allocator, json_part);
                    }
                }
            }
        }
    }
}

fn emitObservedText(observer: TurnObserver, text: []const u8) !void {
    if (text.len == 0) return;
    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == ' ' or byte == '\n' or byte == '\t') {
            if (index > start) try observer.textChunk(text[start..index]);
            try observer.textChunk(text[index .. index + 1]);
            start = index + 1;
        }
    }
    if (start < text.len) try observer.textChunk(text[start..]);
}

fn ensureToolAccumulator(
    tool_calls: *std.ArrayList(ToolAccumulator),
    allocator: std.mem.Allocator,
    index: usize,
) !void {
    while (tool_calls.items.len <= index) {
        try tool_calls.append(allocator, .{});
    }
}

fn finalizeToolCalls(allocator: std.mem.Allocator, accumulators: []const ToolAccumulator) ![]message_mod.ToolCall {
    var count: usize = 0;
    for (accumulators) |call| {
        if (call.name.items.len > 0) count += 1;
    }
    var owned = try allocator.alloc(message_mod.ToolCall, count);
    var write_index: usize = 0;
    for (accumulators, 0..) |call, index| {
        if (call.name.items.len == 0) continue;
        owned[write_index] = .{
            .id = if (call.id.items.len == 0)
                try std.fmt.allocPrint(allocator, "call_{d}", .{index})
            else
                try allocator.dupe(u8, call.id.items),
            .name = try allocator.dupe(u8, call.name.items),
            .arguments = if (call.input_json.items.len == 0)
                try allocator.dupe(u8, "{}")
            else
                try allocator.dupe(u8, call.input_json.items),
        };
        write_index += 1;
    }
    return owned;
}

test "consumeStreamEvent accumulates anthropic text deltas" {
    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(std.testing.allocator);
    var tool_calls: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tool_calls.items) |*call| call.deinit(std.testing.allocator);
        tool_calls.deinit(std.testing.allocator);
    }

    try consumeStreamEvent(
        std.testing.allocator,
        "content_block_start",
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"hel\"}}",
        &text_out,
        &tool_calls,
        .{},
    );
    try consumeStreamEvent(
        std.testing.allocator,
        "content_block_delta",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}",
        &text_out,
        &tool_calls,
        .{},
    );

    try std.testing.expectEqualStrings("hello", text_out.items);
}

test "consumeStreamEvent accumulates anthropic tool deltas" {
    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(std.testing.allocator);
    var tool_calls: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tool_calls.items) |*call| call.deinit(std.testing.allocator);
        tool_calls.deinit(std.testing.allocator);
    }

    try consumeStreamEvent(
        std.testing.allocator,
        "content_block_start",
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read_file\"}}",
        &text_out,
        &tool_calls,
        .{},
    );
    try consumeStreamEvent(
        std.testing.allocator,
        "content_block_delta",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"src/main.zig\\\"}\"}}",
        &text_out,
        &tool_calls,
        .{},
    );

    const finalized = try finalizeToolCalls(std.testing.allocator, tool_calls.items);
    defer {
        for (finalized) |*call| call.deinit(std.testing.allocator);
        std.testing.allocator.free(finalized);
    }

    try std.testing.expectEqual(@as(usize, 1), finalized.len);
    try std.testing.expectEqualStrings("toolu_1", finalized[0].id);
    try std.testing.expectEqualStrings("read_file", finalized[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", finalized[0].arguments);
}

fn writeMessages(writer: *std.Io.Writer, messages: []const message_mod.Message) !void {
    var first = true;
    var index: usize = 0;
    while (index < messages.len) {
        const msg = messages[index];
        switch (msg.role) {
            .tool => {
                var last = index;
                while (last < messages.len and messages[last].role == .tool) : (last += 1) {}
                if (!first) try writer.writeByte(',');
                first = false;
                try writeToolResultMessage(writer, messages[index..last]);
                index = last;
            },
            else => {
                if (!first) try writer.writeByte(',');
                first = false;
                try writeStandardMessage(writer, msg);
                index += 1;
            },
        }
    }
}

fn writeStandardMessage(writer: *std.Io.Writer, msg: message_mod.Message) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"role\":");
    const role = switch (msg.role) {
        .assistant => "assistant",
        .user => "user",
        .system => "user",
        .tool => unreachable,
    };
    try std.json.Stringify.value(role, .{}, writer);
    try writer.writeAll(",\"content\":[");

    var first = true;
    if (msg.content.len > 0 or msg.tool_calls.len == 0) {
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(msg.content, .{}, writer);
        try writer.writeByte('}');
        first = false;
    }

    for (msg.tool_calls) |call| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
        try std.json.Stringify.value(call.id, .{}, writer);
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(call.name, .{}, writer);
        try writer.writeAll(",\"input\":");
        try writer.writeAll(call.arguments);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
}

fn writeToolResultMessage(writer: *std.Io.Writer, results: []const message_mod.Message) !void {
    try writer.writeAll("{\"role\":\"user\",\"content\":[");
    for (results, 0..) |msg, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
        try std.json.Stringify.value(msg.tool_call_id.?, .{}, writer);
        try writer.writeAll(",\"content\":");
        try std.json.Stringify.value(msg.content, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn parseResponse(allocator: std.mem.Allocator, raw_response: []const u8) !TurnResult {
    const trimmed = std.mem.trim(u8, raw_response, " \r\n\t");
    const parsed = try std.json.parseFromSlice(ResponseEnvelope, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var tool_count: usize = 0;
    var text_out: std.Io.Writer.Allocating = .init(allocator);
    defer text_out.deinit();

    for (parsed.value.content) |block| {
        if (std.mem.eql(u8, block.@"type", "tool_use")) {
            tool_count += 1;
        } else if (std.mem.eql(u8, block.@"type", "text")) {
            if (block.text) |text| try text_out.writer.writeAll(text);
        }
    }

    if (tool_count > 0) {
        var owned = try allocator.alloc(message_mod.ToolCall, tool_count);
        var idx: usize = 0;
        for (parsed.value.content) |block| {
            if (!std.mem.eql(u8, block.@"type", "tool_use")) continue;
            var input_out: std.Io.Writer.Allocating = .init(allocator);
            defer input_out.deinit();
            try std.json.Stringify.value(block.input.?, .{}, &input_out.writer);
            owned[idx] = .{
                .id = try allocator.dupe(u8, block.id.?),
                .name = try allocator.dupe(u8, block.name.?),
                .arguments = try input_out.toOwnedSlice(),
            };
            idx += 1;
        }
        return .{ .tool_calls = owned };
    }

    return .{ .assistant_text = try text_out.toOwnedSlice() };
}
