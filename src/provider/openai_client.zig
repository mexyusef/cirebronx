const builtin = @import("builtin");
const std = @import("std");

const App = @import("../core/app.zig").App;
const message_mod = @import("../core/message.zig");
const tool_base = @import("../tools/base.zig");
const provider_types = @import("types.zig");
const openrouter_pool = @import("openrouter_pool.zig");
const provider_prompt = @import("prompt.zig");

const client_headers = [_]std.http.Header{
    .{ .name = "x-goog-api-client", .value = "cirebronx/0.1.0" },
    .{ .name = "accept-encoding", .value = "identity" },
};

pub const TurnResult = provider_types.TurnResult;
pub const TurnObserver = provider_types.TurnObserver;

const ResponseEnvelope = struct {
    choices: []Choice,

    const Choice = struct {
        message: ResponseMessage,
    };
};

const ResponseMessage = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]ResponseToolCall = null,
};

const ResponseToolCall = struct {
    id: []const u8,
    function: ResponseFunction,
};

const ResponseFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

const StreamEnvelope = struct {
    choices: []StreamChoice,
};

const StreamChoice = struct {
    delta: StreamDelta = .{},
    finish_reason: ?[]const u8 = null,
};

const StreamDelta = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]StreamToolCall = null,
};

const StreamToolCall = struct {
    index: usize = 0,
    id: ?[]const u8 = null,
    function: ?StreamFunction = null,
};

const StreamFunction = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

const ErrorEnvelope = struct {
    @"error": ErrorDetail,
};

const ErrorDetail = struct {
    code: ?i64 = null,
    message: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

const ToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolAccumulator, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

pub fn sendTurn(app: *App, tools: []const tool_base.ToolSpec) !TurnResult {
    return sendTurnObserved(app, tools, .{});
}

pub fn sendTurnObserved(app: *App, tools: []const tool_base.ToolSpec, observer: TurnObserver) !TurnResult {
    app.clearLastProviderError();
    const openrouter_attempts = if (isOpenRouterBaseUrl(app.config.base_url))
        @max(openrouter_pool.keyCount(app.allocator), 1)
    else
        1;

    if (openrouter_attempts == 0 and app.config.api_key.len == 0) {
        try app.setLastProviderError("Missing API key");
        return error.MissingApiKey;
    }
    try observer.status("provider request");

    const body = try buildRequestBody(app.allocator, app, tools, true);
    defer app.allocator.free(body);

    if (std.mem.eql(u8, app.config.provider, "gemini")) {
        return try sendTurnViaCurl(app, body, observer);
    }

    var client: std.http.Client = .{ .allocator = app.allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(app.config.base_url);
    var attempt: usize = 0;
    while (attempt < openrouter_attempts) : (attempt += 1) {
        const request_api_key = try requestApiKey(app.allocator, app.config.base_url, app.config.api_key);
        defer if (request_api_key.ptr != app.config.api_key.ptr) app.allocator.free(request_api_key);
        if (request_api_key.len == 0) {
            try app.setLastProviderError("Missing API key");
            return error.MissingApiKey;
        }

        const auth_header = try std.fmt.allocPrint(app.allocator, "Bearer {s}", .{request_api_key});
        defer app.allocator.free(auth_header);

        var request = try client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
            .extra_headers = &client_headers,
        });
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try request.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try request.connection.?.flush();

        var response = try request.receiveHead(&.{});
        if (response.head.status != .ok) {
            var transfer_buffer_error: [16 * 1024]u8 = undefined;
            var error_reader = response.reader(&transfer_buffer_error);
            var error_body_writer: std.Io.Writer.Allocating = .init(app.allocator);
            defer error_body_writer.deinit();
            _ = error_reader.streamRemaining(&error_body_writer.writer) catch 0;
            const decoded_error = try decodeHttpBody(app.allocator, error_body_writer.written());
            defer app.allocator.free(decoded_error);
            if (decoded_error.len > 0) {
                if (try extractProviderErrorMessage(app.allocator, decoded_error)) |message| {
                    defer app.allocator.free(message);
                    const full = try std.fmt.allocPrint(app.allocator, "provider error ({s}): {s}", .{
                        @tagName(response.head.status),
                        message,
                    });
                    defer app.allocator.free(full);
                    try app.setLastProviderError(full);
                } else {
                    try app.setLastProviderError(decoded_error);
                }
            }
            if (isOpenRouterBaseUrl(app.config.base_url) and attempt + 1 < openrouter_attempts and isOpenRouterRetryableStatus(response.head.status)) {
                try observer.status("provider retry with next openrouter key");
                continue;
            }
            try observer.status("provider error");
            return error.ProviderRequestFailed;
        }
        try observer.status("provider stream open");
        return parseStreamingResponse(app.allocator, &response, observer) catch |err| switch (err) {
            error.SyntaxError => {
                try app.setLastProviderError("provider returned an unparseable streaming response");
                try observer.status("provider parse error");
                return error.ProviderRequestFailed;
            },
            else => return err,
        };
    }
    try observer.status("provider error");
    return error.ProviderRequestFailed;
}

fn sendTurnViaCurl(app: *App, body: []const u8, observer: TurnObserver) !TurnResult {
    const request_api_key = try requestApiKey(app.allocator, app.config.base_url, app.config.api_key);
    defer if (request_api_key.ptr != app.config.api_key.ptr) app.allocator.free(request_api_key);

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(app.allocator);

    const auth_header = try std.fmt.allocPrint(app.allocator, "Authorization: Bearer {s}", .{request_api_key});
    defer app.allocator.free(auth_header);

    const temp_dir = std.process.getEnvVarOwned(app.allocator, "TEMP") catch try app.allocator.dupe(u8, ".");
    defer app.allocator.free(temp_dir);
    const unique = std.time.nanoTimestamp();
    const stdout_path = try std.fmt.allocPrint(app.allocator, "{s}\\cirebronx-gemini-{d}.stdout", .{ temp_dir, unique });
    defer app.allocator.free(stdout_path);
    const stderr_path = try std.fmt.allocPrint(app.allocator, "{s}\\cirebronx-gemini-{d}.stderr", .{ temp_dir, unique });
    defer app.allocator.free(stderr_path);

    {
        const file = try std.fs.createFileAbsolute(stdout_path, .{ .truncate = true });
        file.close();
    }
    {
        const file = try std.fs.createFileAbsolute(stderr_path, .{ .truncate = true });
        file.close();
    }
    defer std.fs.deleteFileAbsolute(stdout_path) catch {};
    defer std.fs.deleteFileAbsolute(stderr_path) catch {};

    try args.appendSlice(app.allocator, &.{
        "curl",
        "-sS",
        "-N",
        "-X",
        "POST",
        app.config.base_url,
        "-H",
        auth_header,
        "-H",
        "Content-Type: application/json",
        "-H",
        "x-goog-api-client: cirebronx/0.1.0",
        "-H",
        "accept-encoding: identity",
        "--output",
        stdout_path,
        "--stderr",
        stderr_path,
        "--data-binary",
        body,
    });

    var child = std.process.Child.init(args.items, app.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(app.allocator);
    var tool_calls: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tool_calls.items) |*call| call.deinit(app.allocator);
        tool_calls.deinit(app.allocator);
    }
    var raw_out: std.Io.Writer.Allocating = .init(app.allocator);
    defer raw_out.deinit();
    var saw_sse = false;
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(app.allocator);

    var stdout_file = try std.fs.openFileAbsolute(stdout_path, .{ .mode = .read_only });
    defer stdout_file.close();

    var read_offset: u64 = 0;
    var read_buf: [4096]u8 = undefined;
    var finished = false;

    while (true) {
        const end_pos = try stdout_file.getEndPos();
        if (end_pos > read_offset) {
            try stdout_file.seekTo(read_offset);
            var remaining = end_pos - read_offset;
            while (remaining > 0) {
                const want = @min(read_buf.len, @as(usize, @intCast(remaining)));
                const n = try stdout_file.read(read_buf[0..want]);
                if (n == 0) break;
                read_offset += n;
                remaining -= n;
                try raw_out.writer.writeAll(read_buf[0..n]);
                try pending.appendSlice(app.allocator, read_buf[0..n]);

                while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
                    const consume_len = newline_index + 1;
                    const line_with_newline = pending.items[0..consume_len];
                    const line = std.mem.trimRight(u8, line_with_newline, "\r\n");
                    if (line.len != 0 and std.mem.startsWith(u8, line, "data: ")) {
                        saw_sse = true;
                        const payload = line["data: ".len..];
                        if (!std.mem.eql(u8, payload, "[DONE]")) {
                            try consumeStreamEvent(app.allocator, payload, &text_out, &tool_calls, observer);
                        }
                    }
                    if (consume_len < pending.items.len) {
                        std.mem.copyForwards(u8, pending.items[0 .. pending.items.len - consume_len], pending.items[consume_len..]);
                    }
                    pending.items.len -= consume_len;
                }
            }
        }

        if (finished) break;
        if (builtin.os.tag == .windows) {
            const windows = std.os.windows;
            const status = windows.kernel32.WaitForSingleObject(child.id, 50);
            switch (status) {
                windows.WAIT_OBJECT_0 => finished = true,
                windows.WAIT_TIMEOUT => {},
                windows.WAIT_FAILED => return windows.unexpectedError(windows.GetLastError()),
                else => unreachable,
            }
        } else {
            finished = true;
        }
    }

    if (pending.items.len > 0) {
        const line = std.mem.trimRight(u8, pending.items, "\r\n");
        if (line.len != 0 and std.mem.startsWith(u8, line, "data: ")) {
            saw_sse = true;
            const payload = line["data: ".len..];
            if (!std.mem.eql(u8, payload, "[DONE]")) {
                try consumeStreamEvent(app.allocator, payload, &text_out, &tool_calls, observer);
            }
        }
    }

    _ = try child.wait();

    const stderr_file = try std.fs.openFileAbsolute(stderr_path, .{ .mode = .read_only });
    defer stderr_file.close();
    const stderr_owned = try stderr_file.readToEndAlloc(app.allocator, 1024 * 1024);
    defer app.allocator.free(stderr_owned);

    const raw_body = raw_out.written();
    if (!saw_sse) {
        const trimmed_stderr = std.mem.trim(u8, stderr_owned, " \r\n\t");
        const trimmed_stdout = std.mem.trim(u8, raw_body, " \r\n\t");
        if (trimmed_stdout.len > 0) {
            if (try extractProviderErrorMessage(app.allocator, trimmed_stdout)) |message| {
                defer app.allocator.free(message);
                try app.setLastProviderError(message);
                return error.ProviderRequestFailed;
            }
            const fallback = parseResponse(app.allocator, trimmed_stdout) catch {
                try app.setLastProviderError("provider returned an unparseable streaming response");
                return error.ProviderRequestFailed;
            };
            return try emitParsedResponse(observer, fallback, false);
        }
        if (trimmed_stderr.len > 0) {
            try app.setLastProviderError(trimmed_stderr);
            return error.ProviderRequestFailed;
        }
        try app.setLastProviderError("provider returned an empty response");
        return error.ProviderRequestFailed;
    }

    if (tool_calls.items.len > 0) {
        const owned = try finalizeToolCalls(app.allocator, tool_calls.items);
        return try emitParsedResponse(observer, .{ .tool_calls = owned }, true);
    }

    return try emitParsedResponse(observer, .{ .assistant_text = try text_out.toOwnedSlice(app.allocator) }, true);
}

fn requestApiKey(allocator: std.mem.Allocator, base_url: []const u8, fallback: []const u8) ![]const u8 {
    if (isOpenRouterBaseUrl(base_url)) {
        if (try openrouter_pool.nextKey(allocator)) |key| return key;
    }
    return fallback;
}

fn isOpenRouterBaseUrl(base_url: []const u8) bool {
    return std.mem.indexOf(u8, base_url, "openrouter.ai") != null;
}

fn isOpenRouterRetryableStatus(status: std.http.Status) bool {
    return switch (status) {
        .unauthorized,
        .payment_required,
        .forbidden,
        .request_timeout,
        .conflict,
        .too_many_requests,
        .internal_server_error,
        .bad_gateway,
        .service_unavailable,
        .gateway_timeout,
        => true,
        else => false,
    };
}

fn buildRequestBody(
    allocator: std.mem.Allocator,
    app: *App,
    tools: []const tool_base.ToolSpec,
    stream: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const runtime_prompt = try provider_prompt.buildRuntimePrompt(allocator, tools);
    defer allocator.free(runtime_prompt);

    try out.writer.writeByte('{');
    try out.writer.writeAll("\"model\":");
    try std.json.Stringify.value(app.config.model, .{}, &out.writer);
    try out.writer.writeAll(",\"messages\":[");

    var needs_comma = false;
    try writeMessagePrefix(&out.writer, &needs_comma);
    try out.writer.writeAll("{\"role\":\"system\",\"content\":");
    try std.json.Stringify.value(runtime_prompt, .{}, &out.writer);
    try out.writer.writeByte('}');

    for (app.session.items) |msg| {
        try writeMessagePrefix(&out.writer, &needs_comma);
        try writeMessageJson(&out.writer, msg);
    }

    try out.writer.writeByte(']');
    if (tools.len > 0) {
        try out.writer.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, index| {
            if (index > 0) try out.writer.writeByte(',');
            try writeToolJson(&out.writer, tool);
        }
        try out.writer.writeAll("],\"tool_choice\":\"auto\"");
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
    var transfer_buffer: [64 * 1024]u8 = undefined;
    var reader = response.reader(&transfer_buffer);
    var text_out: std.ArrayList(u8) = .empty;
    var saw_sse = false;
    var raw_writer: std.Io.Writer.Allocating = .init(allocator);
    defer text_out.deinit(allocator);
    defer raw_writer.deinit();
    var tool_calls: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tool_calls.items) |*call| call.deinit(allocator);
        tool_calls.deinit(allocator);
    }

    while (try reader.takeDelimiter('\n')) |line_with_newline| {
        try raw_writer.writer.writeAll(line_with_newline);
        try raw_writer.writer.writeByte('\n');

        const line = std.mem.trimRight(u8, line_with_newline, "\r\n");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        saw_sse = true;
        const payload = line["data: ".len..];
        if (std.mem.eql(u8, payload, "[DONE]")) break;
        try consumeStreamEvent(allocator, payload, &text_out, &tool_calls, observer);
    }

    const decoded_body = try decodeHttpBody(allocator, raw_writer.written());
    defer allocator.free(decoded_body);

    if (!saw_sse) {
        const fallback = parseResponse(allocator, decoded_body) catch |err| switch (err) {
            error.SyntaxError => return error.SyntaxError,
            else => return err,
        };
        return try emitParsedResponse(observer, fallback, false);
    }

    if (tool_calls.items.len > 0) {
        const owned = try finalizeToolCalls(allocator, tool_calls.items);
        return try emitParsedResponse(observer, .{ .tool_calls = owned }, true);
    }

    const text = try text_out.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    if (try extractPseudoToolCalls(allocator, text)) |calls| {
        allocator.free(text);
        return try emitParsedResponse(observer, .{ .tool_calls = calls }, true);
    }
    return try emitParsedResponse(observer, .{ .assistant_text = text }, true);
}

fn emitParsedResponse(observer: TurnObserver, result: TurnResult, already_streamed: bool) !TurnResult {
    switch (result) {
        .assistant_text => |text| {
            try observer.status("provider response");
            if (!already_streamed and text.len > 0) try observer.textChunk(text);
        },
        .tool_calls => |calls| {
            try observer.status("provider tool calls");
            if (!already_streamed) try observer.toolCalls(calls);
        },
    }
    return result;
}

fn extractPseudoToolCalls(allocator: std.mem.Allocator, text: []const u8) !?[]message_mod.ToolCall {
    var calls = std.ArrayList(message_mod.ToolCall).empty;
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, "CALL>")) |marker| {
        const json_start = marker + "CALL>".len;
        if (json_start >= text.len or text[json_start] != '{') {
            cursor = json_start;
            continue;
        }
        const json_len = findBalancedJsonObject(text[json_start..]) orelse break;
        const payload = text[json_start .. json_start + json_len];

        const parsed = std.json.parseFromSlice(struct {
            name: []const u8,
            arguments: std.json.Value,
        }, allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cursor = json_start + 1;
            continue;
        };
        defer parsed.deinit();

        var rendered: std.Io.Writer.Allocating = .init(allocator);
        defer rendered.deinit();
        try std.json.Stringify.value(parsed.value.arguments, .{}, &rendered.writer);
        const arguments = try allocator.dupe(u8, rendered.written());
        errdefer allocator.free(arguments);
        const id = try std.fmt.allocPrint(allocator, "call_text_{d}", .{calls.items.len + 1});
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, parsed.value.name);
        errdefer allocator.free(name);

        try calls.append(allocator, .{
            .id = id,
            .name = name,
            .arguments = arguments,
        });
        cursor = json_start + json_len;
    }

    if (calls.items.len == 0) {
        calls.deinit(allocator);
        return null;
    }
    return try calls.toOwnedSlice(allocator);
}

fn findBalancedJsonObject(text: []const u8) ?usize {
    if (text.len == 0 or text[0] != '{') return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text, 0..) |byte, index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == '"') in_string = false;
            continue;
        }

        switch (byte) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            else => {},
        }
    }
    return null;
}

fn consumeStreamEvent(
    allocator: std.mem.Allocator,
    payload: []const u8,
    text_out: *std.ArrayList(u8),
    tool_calls: *std.ArrayList(ToolAccumulator),
    observer: TurnObserver,
) !void {
    const trimmed = std.mem.trim(u8, payload, " \r\n\t");
    if (trimmed.len == 0) return;
    if (trimmed[0] != '{') return;

    if (std.mem.indexOf(u8, trimmed, "\"tool_calls\"") == null) {
        if (try extractJsonStringField(allocator, trimmed, "\"content\":")) |content| {
            defer allocator.free(content);
            try text_out.appendSlice(allocator, content);
            try emitObservedText(observer, content);
            return;
        }
    }

    const parsed = std.json.parseFromSlice(StreamEnvelope, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.SyntaxError => return,
        else => return err,
    };
    defer parsed.deinit();

    for (parsed.value.choices) |choice| {
        if (choice.delta.content) |content| {
            try text_out.appendSlice(allocator, content);
            try emitObservedText(observer, content);
        }
        if (choice.delta.tool_calls) |delta_calls| {
            try observer.status("streaming tool calls");
            for (delta_calls) |delta_call| {
                try ensureToolAccumulator(tool_calls, allocator, delta_call.index);
                var target = &tool_calls.items[delta_call.index];
                if (delta_call.id) |id| try target.id.appendSlice(allocator, id);
                if (delta_call.function) |function| {
                    if (function.name) |name| try target.name.appendSlice(allocator, name);
                    if (function.arguments) |arguments| try target.arguments.appendSlice(allocator, arguments);
                }
            }
        }
    }
}

fn extractJsonStringField(allocator: std.mem.Allocator, body: []const u8, key: []const u8) !?[]u8 {
    const start_key = std.mem.indexOf(u8, body, key) orelse return null;
    const after_key = std.mem.trimLeft(u8, body[start_key + key.len ..], " \t");
    if (after_key.len == 0 or after_key[0] != '"') return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 1;
    while (index < after_key.len) : (index += 1) {
        const byte = after_key[index];
        if (byte == '"') return try out.toOwnedSlice(allocator);
        if (byte == '\\' and index + 1 < after_key.len) {
            index += 1;
            const escaped = after_key[index];
            switch (escaped) {
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                't' => try out.append(allocator, '\t'),
                '\\' => try out.append(allocator, '\\'),
                '"' => try out.append(allocator, '"'),
                '/' => try out.append(allocator, '/'),
                'b' => try out.append(allocator, 8),
                'f' => try out.append(allocator, 12),
                else => try out.append(allocator, escaped),
            }
            continue;
        }
        try out.append(allocator, byte);
    }

    out.deinit(allocator);
    return null;
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
    var owned = try allocator.alloc(message_mod.ToolCall, accumulators.len);
    for (accumulators, 0..) |call, index| {
        owned[index] = .{
            .id = if (call.id.items.len == 0)
                try std.fmt.allocPrint(allocator, "call_{d}", .{index})
            else
                try allocator.dupe(u8, call.id.items),
            .name = try allocator.dupe(u8, call.name.items),
            .arguments = if (call.arguments.items.len == 0)
                try allocator.dupe(u8, "{}")
            else
                try allocator.dupe(u8, call.arguments.items),
        };
    }
    return owned;
}

fn decodeHttpBody(allocator: std.mem.Allocator, raw_body: []const u8) ![]u8 {
    if (raw_body.len >= 2 and raw_body[0] == 0x1f and raw_body[1] == 0x8b) {
        var input: std.Io.Reader = .fixed(raw_body);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
        _ = try decompress.reader.streamRemaining(&output.writer);
        return try allocator.dupe(u8, output.written());
    }
    return try allocator.dupe(u8, raw_body);
}

fn extractProviderErrorMessage(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, body, " \r\n\t");
    if (trimmed.len == 0) return null;

    if (trimmed[0] == '[') {
        const parsed = std.json.parseFromSlice([]ErrorEnvelope, allocator, trimmed, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        if (parsed.value.len == 0) return null;
        return try allocator.dupe(u8, parsed.value[0].@"error".message orelse return null);
    }

    const parsed = std.json.parseFromSlice(ErrorEnvelope, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    return try allocator.dupe(u8, parsed.value.@"error".message orelse return extractProviderErrorMessageText(allocator, trimmed));
}

fn extractProviderErrorMessageText(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    const key = "\"message\":";
    const start_key = std.mem.indexOf(u8, body, key) orelse return null;
    const after_key = std.mem.trimLeft(u8, body[start_key + key.len ..], " \t");
    if (after_key.len == 0 or after_key[0] != '"') return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 1;
    while (index < after_key.len) : (index += 1) {
        const byte = after_key[index];
        if (byte == '"') return try out.toOwnedSlice(allocator);
        if (byte == '\\' and index + 1 < after_key.len) {
            index += 1;
            const escaped = after_key[index];
            switch (escaped) {
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                't' => try out.append(allocator, '\t'),
                '\\' => try out.append(allocator, '\\'),
                '"' => try out.append(allocator, '"'),
                else => try out.append(allocator, escaped),
            }
            continue;
        }
        try out.append(allocator, byte);
    }

    out.deinit(allocator);
    return null;
}

test "consumeStreamEvent accumulates assistant text chunks" {
    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(std.testing.allocator);
    var tool_calls: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tool_calls.items) |*call| call.deinit(std.testing.allocator);
        tool_calls.deinit(std.testing.allocator);
    }

    try consumeStreamEvent(
        std.testing.allocator,
        "{\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}",
        &text_out,
        &tool_calls,
        .{},
    );
    try consumeStreamEvent(
        std.testing.allocator,
        "{\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}",
        &text_out,
        &tool_calls,
        .{},
    );

    try std.testing.expectEqualStrings("hello", text_out.items);
    try std.testing.expectEqual(@as(usize, 0), tool_calls.items.len);
}

test "consumeStreamEvent extracts text from gemini-style chunk without full json parse" {
    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(std.testing.allocator);
    var tool_calls: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tool_calls.items) |*call| call.deinit(std.testing.allocator);
        tool_calls.deinit(std.testing.allocator);
    }

    try consumeStreamEvent(
        std.testing.allocator,
        "{\"choices\":[{\"delta\":{\"content\":\"Hello\\nworld\",\"role\":\"assistant\"},\"index\":0}],\"object\":\"chat.completion.chunk\"}",
        &text_out,
        &tool_calls,
        .{},
    );

    try std.testing.expectEqualStrings("Hello\nworld", text_out.items);
}

test "consumeStreamEvent ignores malformed non-json payloads" {
    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(std.testing.allocator);
    var tool_calls: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tool_calls.items) |*call| call.deinit(std.testing.allocator);
        tool_calls.deinit(std.testing.allocator);
    }

    try consumeStreamEvent(
        std.testing.allocator,
        "not-json",
        &text_out,
        &tool_calls,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 0), text_out.items.len);
    try std.testing.expectEqual(@as(usize, 0), tool_calls.items.len);
}

test "emitObservedText splits coarse chunks into smaller observer writes" {
    const Capture = struct {
        buf: std.ArrayList(u8) = .empty,

        fn onText(raw: ?*anyopaque, chunk: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.buf.appendSlice(std.testing.allocator, chunk);
        }
    };

    var capture = Capture{};
    defer capture.buf.deinit(std.testing.allocator);

    try emitObservedText(.{
        .context = &capture,
        .on_text_chunk = Capture.onText,
    }, "hello world");

    try std.testing.expectEqualStrings("hello world", capture.buf.items);
}

test "consumeStreamEvent accumulates streamed tool calls" {
    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(std.testing.allocator);
    var tool_calls: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tool_calls.items) |*call| call.deinit(std.testing.allocator);
        tool_calls.deinit(std.testing.allocator);
    }

    try consumeStreamEvent(
        std.testing.allocator,
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"\"}}]}}]}",
        &text_out,
        &tool_calls,
        .{},
    );
    try consumeStreamEvent(
        std.testing.allocator,
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"src/main.zig\\\"}\"}}]}}]}",
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
    try std.testing.expectEqualStrings("call_1", finalized[0].id);
    try std.testing.expectEqualStrings("read_file", finalized[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", finalized[0].arguments);
}

test "parseResponse parses non-stream assistant text" {
    const result = try parseResponse(
        std.testing.allocator,
        "{\"choices\":[{\"message\":{\"content\":\"hello from fallback\"}}]}",
    );
    defer switch (result) {
        .assistant_text => |text| std.testing.allocator.free(text),
        .tool_calls => |calls| {
            for (calls) |*call| call.deinit(std.testing.allocator);
            std.testing.allocator.free(calls);
        },
    };

    try std.testing.expect(result == .assistant_text);
    try std.testing.expectEqualStrings("hello from fallback", result.assistant_text);
}

test "parseResponse parses non-stream tool calls" {
    const result = try parseResponse(
        std.testing.allocator,
        "{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]}}]}",
    );
    defer switch (result) {
        .assistant_text => |text| std.testing.allocator.free(text),
        .tool_calls => |calls| {
            for (calls) |*call| call.deinit(std.testing.allocator);
            std.testing.allocator.free(calls);
        },
    };

    try std.testing.expect(result == .tool_calls);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{}", result.tool_calls[0].arguments);
}

test "parseResponse converts textual CALL syntax into tool calls" {
    const result = try parseResponse(
        std.testing.allocator,
        "{\"choices\":[{\"message\":{\"content\":\"CALL>{\\\"name\\\":\\\"write_file\\\",\\\"arguments\\\":{\\\"path\\\":\\\"src/main.java\\\",\\\"content\\\":\\\"class Main {}\\\"}}\"}}]}",
    );
    defer switch (result) {
        .assistant_text => |text| std.testing.allocator.free(text),
        .tool_calls => |calls| {
            for (calls) |*call| call.deinit(std.testing.allocator);
            std.testing.allocator.free(calls);
        },
    };

    try std.testing.expect(result == .tool_calls);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("write_file", result.tool_calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.tool_calls[0].arguments, "\"path\":\"src/main.java\"") != null);
}

test "buildRequestBody omits tool config when no tools are exposed" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();
    std.testing.allocator.free(app.config.model);
    app.config.model = try std.testing.allocator.dupe(u8, "gemini-2.5-flash");
    std.testing.allocator.free(app.config.provider);
    app.config.provider = try std.testing.allocator.dupe(u8, "gemini");

    const body = try buildRequestBody(std.testing.allocator, &app, &.{}, true);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
}

test "buildRequestBody includes tool config when tools are exposed" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();
    std.testing.allocator.free(app.config.model);
    app.config.model = try std.testing.allocator.dupe(u8, "gpt-test");

    const exposed = [_]tool_base.ToolSpec{
        .{
            .kind = .read_file,
            .name = "read_file",
            .description = "Read a file",
            .schema_json = "{\"type\":\"object\"}",
            .permission = .read,
        },
    };

    const body = try buildRequestBody(std.testing.allocator, &app, &exposed, true);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Tool inventory") != null);
}

fn writeMessagePrefix(writer: *std.Io.Writer, needs_comma: *bool) !void {
    if (needs_comma.*) try writer.writeByte(',');
    needs_comma.* = true;
}

fn writeMessageJson(writer: *std.Io.Writer, msg: message_mod.Message) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"role\":");
    try std.json.Stringify.value(message_mod.roleString(msg.role), .{}, writer);
    try writer.writeAll(",\"content\":");
    try std.json.Stringify.value(msg.content, .{}, writer);

    if (msg.tool_call_id) |tool_call_id| {
        try writer.writeAll(",\"tool_call_id\":");
        try std.json.Stringify.value(tool_call_id, .{}, writer);
    }

    if (msg.tool_name) |tool_name| {
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(tool_name, .{}, writer);
    }

    if (msg.tool_calls.len > 0) {
        try writer.writeAll(",\"tool_calls\":[");
        for (msg.tool_calls, 0..) |call, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":");
            try std.json.Stringify.value(call.id, .{}, writer);
            try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
            try std.json.Stringify.value(call.name, .{}, writer);
            try writer.writeAll(",\"arguments\":");
            try std.json.Stringify.value(call.arguments, .{}, writer);
            try writer.writeAll("}}");
        }
        try writer.writeByte(']');
    }

    try writer.writeByte('}');
}

fn writeToolJson(writer: *std.Io.Writer, tool: tool_base.ToolSpec) !void {
    try writer.writeAll("{\"type\":\"function\",\"function\":{");
    try writer.writeAll("\"name\":");
    try std.json.Stringify.value(tool.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(tool.description, .{}, writer);
    try writer.writeAll(",\"parameters\":");
    try writer.writeAll(tool.schema_json);
    try writer.writeAll("}}");
}

fn parseResponse(
    allocator: std.mem.Allocator,
    raw_response: []const u8,
) !TurnResult {
    const trimmed = std.mem.trim(u8, raw_response, " \r\n\t");

    const parsed = try std.json.parseFromSlice(ResponseEnvelope, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) {
        return .{ .assistant_text = try allocator.dupe(u8, "") };
    }

    const msg = parsed.value.choices[0].message;
    if (msg.tool_calls) |tool_calls| {
        var owned = try allocator.alloc(message_mod.ToolCall, tool_calls.len);
        for (tool_calls, 0..) |call, index| {
            owned[index] = .{
                .id = try allocator.dupe(u8, call.id),
                .name = try allocator.dupe(u8, call.function.name),
                .arguments = try allocator.dupe(u8, call.function.arguments),
            };
        }
        return .{ .tool_calls = owned };
    }

    const text = try allocator.dupe(u8, msg.content orelse "");
    errdefer allocator.free(text);
    if (try extractPseudoToolCalls(allocator, text)) |calls| {
        allocator.free(text);
        return .{ .tool_calls = calls };
    }
    return .{ .assistant_text = text };
}
