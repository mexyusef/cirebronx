const std = @import("std");
const ziggy = @import("ziggy");

const App = @import("../core/app.zig").App;
const message_mod = @import("../core/message.zig");
const tui_state = @import("tui_state.zig");
const tui_text = @import("tui_text.zig");

pub const Item = tui_state.Item;

pub const ConversationDocument = struct {
    lines: []const ziggy.RichText.Line,
    selected_line: usize,
    entry_starts: []const usize,

    pub fn deinit(self: *ConversationDocument, allocator: std.mem.Allocator) void {
        ziggy.RichText.freeLines(allocator, self.lines);
        allocator.free(self.entry_starts);
    }
};

pub fn buildConversationItems(
    allocator: std.mem.Allocator,
    app: *const App,
    turn_running: bool,
    pending_prompt: ?[]const u8,
    current_tool: ?[]const u8,
    last_error: ?[]const u8,
    live_assistant: ?[]const u8,
    status_text: []const u8,
    actions: []const []u8,
) ![]Item {
    if (app.session.items.len == 0) {
        const items = try allocator.alloc(Item, 1);
        items[0] = .{
            .label = try allocator.dupe(u8, if (turn_running) "Pending turn..." else "No conversation yet."),
            .body = try allocator.dupe(u8, if (turn_running) "The current request is still running." else "Submit a prompt below."),
            .reuse = try allocator.dupe(u8, ""),
        };
        return items;
    }

    var list = std.ArrayList(Item).empty;
    defer list.deinit(allocator);

    var index: usize = 0;
    while (index < app.session.items.len) {
        const msg = app.session.items[index];
        if (msg.role == .assistant and msg.tool_calls.len > 0) {
            const end_index = consumeToolGroup(app.session.items, index);
            try list.append(allocator, try formatToolGroupItem(allocator, app.session.items[index..end_index], index));
            index = end_index;
            continue;
        }

        try list.append(allocator, .{
            .label = try std.fmt.allocPrint(allocator, "{d}. [{s}] {s}", .{
                index + 1,
                message_mod.roleString(msg.role),
                ziggy.FormatText.previewText(msg.content, 56),
            }),
            .body = try formatMessageBody(allocator, msg, index),
            .reuse = if (msg.role == .user) try allocator.dupe(u8, msg.content) else null,
        });
        index += 1;
    }

    if (turn_running and pending_prompt != null) {
        try list.append(allocator, .{
            .label = try std.fmt.allocPrint(allocator, "{d}. [pending] {s}", .{
                app.session.items.len + 1,
                ziggy.FormatText.previewText(pending_prompt.?, 56),
            }),
            .body = try std.fmt.allocPrint(allocator, "Current prompt:\n{s}\n\nprovider:\n{s}:{s}\n\nstatus:\n{s}\n\ncurrent tool:\n{s}\n\nlast error:\n{s}\n\nrecent activity:\n{s}\n", .{
                pending_prompt.?,
                app.config.provider,
                app.config.model,
                status_text,
                current_tool orelse "<none>",
                last_error orelse "<none>",
                tui_text.latestActivitySummary(status_text, actions),
            }),
        });
    }

    if (turn_running and live_assistant != null and live_assistant.?.len > 0) {
        try list.append(allocator, .{
            .label = try std.fmt.allocPrint(allocator, "{d}. [assistant/live] {s}", .{
                app.session.items.len + 1,
                ziggy.FormatText.previewText(live_assistant.?, 56),
            }),
            .body = try std.fmt.allocPrint(allocator, "Streaming assistant preview:\n{s}", .{
                live_assistant.?,
            }),
        });
    }

    return try list.toOwnedSlice(allocator);
}

pub fn buildConversationDocument(
    allocator: std.mem.Allocator,
    app: *const App,
    selected_index: usize,
    turn_running: bool,
    pending_prompt: ?[]const u8,
    current_tool: ?[]const u8,
    last_error: ?[]const u8,
    live_assistant: ?[]const u8,
    status_text: []const u8,
    actions: []const []u8,
    width: usize,
) !ConversationDocument {
    const items = try buildConversationItems(
        allocator,
        app,
        turn_running,
        pending_prompt,
        current_tool,
        last_error,
        live_assistant,
        status_text,
        actions,
    );
    defer freeItems(allocator, items);

    const entries = try allocator.alloc(ziggy.Transcript.Entry, items.len);
    defer {
        for (entries) |entry| {
            if (entry.meta) |text| allocator.free(text);
        }
        allocator.free(entries);
    }

    const body_theme = ziggy.FormatRichMarkdown.Theme{
        .base = .{ .fg = .{ .ansi = 7 } },
        .heading = .{ .fg = .{ .ansi = 14 }, .bold = true },
        .bullet = .{ .fg = .{ .ansi = 11 }, .bold = true },
        .quote = .{ .fg = .{ .ansi = 6 }, .dim = true },
        .code = .{ .fg = .{ .ansi = 10 }, .bg = .{ .ansi = 8 } },
        .muted = .{ .fg = .{ .ansi = 8 }, .dim = true },
        .accent = .{ .fg = .{ .ansi = 12 }, .bold = true },
    };

    for (items, 0..) |item, index| {
        const badge = transcriptBadge(item.label);
        const meta = try transcriptMeta(allocator, item.label, index + 1);
        entries[index] = .{
            .title = transcriptTitle(item.label),
            .body = item.body,
            .selected = index == selected_index,
            .badge = badge,
            .meta = meta,
            .title_style = .{ .fg = .{ .ansi = 7 }, .bold = true },
            .selected_title_style = .{ .fg = .{ .ansi = 15 }, .bg = .{ .ansi = 4 }, .bold = true },
            .badge_style = transcriptBadgeStyle(badge),
            .meta_style = .{ .fg = .{ .ansi = 8 }, .dim = true },
            .separator_style = .{ .fg = .{ .ansi = 8 }, .dim = true },
            .body_theme = body_theme,
        };
    }

    const rendered = try ziggy.Transcript.renderLines(allocator, entries, width);

    return .{
        .lines = rendered.lines,
        .selected_line = rendered.selected_line,
        .entry_starts = rendered.entry_starts,
    };
}

pub fn buildActivityItems(
    allocator: std.mem.Allocator,
    app: *const App,
    sidebar_output: []const u8,
    turn_running: bool,
    pending_prompt: ?[]const u8,
    current_tool: ?[]const u8,
    last_error: ?[]const u8,
    live_assistant: ?[]const u8,
    status_text: []const u8,
    actions: []const []u8,
    history_items: []const []u8,
) ![]Item {
    var list = std.ArrayList(Item).empty;
    defer list.deinit(allocator);

    const shortcuts = [_]struct { label: []const u8, body: []const u8 }{
        .{ .label = "Shortcut: /help", .body = "Show all local commands and usage." },
        .{ .label = "Shortcut: /config", .body = "Show provider, model, base_url, permissions, and plan state." },
        .{ .label = "Shortcut: /sessions", .body = "List recent saved sessions." },
        .{ .label = "Shortcut: /resume", .body = "Resume a stored session." },
    };
    for (shortcuts) |entry| {
        try list.append(allocator, .{
            .label = try allocator.dupe(u8, entry.label),
            .body = try allocator.dupe(u8, entry.body),
            .reuse = try shortcutReuseText(allocator, entry.label),
        });
    }

    if (turn_running and pending_prompt != null) {
        try list.append(allocator, .{
            .label = try std.fmt.allocPrint(allocator, "Live: {s}", .{ziggy.FormatText.previewText(pending_prompt.?, 56)}),
            .body = try std.fmt.allocPrint(allocator, "Provider: {s}:{s}\nStatus: {s}\nPrompt:\n{s}", .{
                app.config.provider,
                app.config.model,
                status_text,
                pending_prompt.?,
            }),
            .reuse = try allocator.dupe(u8, pending_prompt.?),
        });
    }

    if (current_tool) |tool_name| {
        try list.append(allocator, .{
            .label = try std.fmt.allocPrint(allocator, "Live Tool: {s}", .{ziggy.FormatText.previewText(tool_name, 56)}),
            .body = try std.fmt.allocPrint(allocator, "Currently executing tool:\n{s}\n\nstatus:\n{s}", .{
                tool_name,
                status_text,
            }),
        });
    }

    if (last_error) |err_text| {
        try list.append(allocator, .{
            .label = try std.fmt.allocPrint(allocator, "Live Error: {s}", .{ziggy.FormatText.previewText(err_text, 56)}),
            .body = try allocator.dupe(u8, err_text),
        });
    }

    if (live_assistant) |text| {
        if (text.len > 0) {
            try list.append(allocator, .{
                .label = try std.fmt.allocPrint(allocator, "Live Output: {s}", .{ziggy.FormatText.previewText(text, 56)}),
                .body = try allocator.dupe(u8, text),
                .reuse = try allocator.dupe(u8, text),
            });
        }
    }

    for (actions) |action| {
        try list.append(allocator, .{
            .label = try tui_text.activityActionLabel(allocator, action),
            .body = try allocator.dupe(u8, action),
            .reuse = try actionReuseText(allocator, action),
        });
    }

    const recent_count = @min(history_items.len, 4);
    if (recent_count > 0) {
        var idx = history_items.len - recent_count;
        while (idx < history_items.len) : (idx += 1) {
            const prompt = history_items[idx];
            try list.append(allocator, .{
                .label = try std.fmt.allocPrint(allocator, "Recent: {s}", .{ziggy.FormatText.previewText(prompt, 56)}),
                .body = try allocator.dupe(u8, prompt),
                .reuse = try allocator.dupe(u8, prompt),
            });
        }
    }

    const lines_to_keep = try collectRecentOutputLines(allocator, sidebar_output, 20);
    defer {
        for (lines_to_keep) |line| allocator.free(line);
        allocator.free(lines_to_keep);
    }
    for (lines_to_keep, 0..) |line, line_index| {
        try list.append(allocator, .{
            .label = try tui_text.activityOutputLabel(allocator, line, line_index + 1),
            .body = try allocator.dupe(u8, line),
            .reuse = try outputReuseText(allocator, line),
        });
    }
    if (list.items.len == shortcuts.len) {
        try list.append(allocator, .{
            .label = try allocator.dupe(u8, "Hint: /"),
            .body = try allocator.dupe(u8, "Type / in the prompt to open commands."),
            .reuse = try allocator.dupe(u8, "/"),
        });
    }

    return try list.toOwnedSlice(allocator);
}

pub fn extractLabels(allocator: std.mem.Allocator, items: []const Item) ![]const []const u8 {
    const labels = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| labels[index] = try allocator.dupe(u8, item.label);
    return labels;
}

pub fn freeItems(allocator: std.mem.Allocator, items: []Item) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn transcriptBadge(label: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, label, "[user]") != null) return "USER";
    if (std.mem.indexOf(u8, label, "[assistant/tools]") != null) return "TOOLS";
    if (std.mem.indexOf(u8, label, "[assistant/live]") != null) return "LIVE";
    if (std.mem.indexOf(u8, label, "[assistant]") != null) return "ASSIST";
    if (std.mem.indexOf(u8, label, "[pending]") != null) return "PENDING";
    if (std.mem.indexOf(u8, label, "[tool]") != null) return "TOOL";
    return null;
}

fn transcriptBadgeStyle(badge: ?[]const u8) ziggy.Style {
    if (badge) |text| {
        if (std.mem.eql(u8, text, "USER")) return .{ .fg = .{ .ansi = 14 }, .bold = true };
        if (std.mem.eql(u8, text, "ASSIST")) return .{ .fg = .{ .ansi = 10 }, .bold = true };
        if (std.mem.eql(u8, text, "TOOLS")) return .{ .fg = .{ .ansi = 11 }, .bold = true };
        if (std.mem.eql(u8, text, "LIVE")) return .{ .fg = .{ .ansi = 12 }, .bold = true };
        if (std.mem.eql(u8, text, "PENDING")) return .{ .fg = .{ .ansi = 9 }, .bold = true };
        if (std.mem.eql(u8, text, "TOOL")) return .{ .fg = .{ .ansi = 11 }, .bold = true };
    }
    return .{ .fg = .{ .ansi = 8 }, .bold = true };
}

fn transcriptTitle(label: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, label, ']')) |index| {
        const start = @min(index + 2, label.len);
        return std.mem.trimLeft(u8, label[start..], " ");
    }
    if (std.mem.indexOf(u8, label, ". ")) |index| {
        return label[index + 2 ..];
    }
    return label;
}

fn transcriptMeta(allocator: std.mem.Allocator, label: []const u8, fallback_index: usize) !?[]u8 {
    _ = allocator;
    _ = label;
    _ = fallback_index;
    return null;
}

fn consumeToolGroup(messages: []const message_mod.Message, start: usize) usize {
    var index = start + 1;
    while (index < messages.len and messages[index].role == .tool) : (index += 1) {}
    if (index < messages.len and messages[index].role == .assistant and messages[index].tool_calls.len == 0) {
        index += 1;
    }
    return index;
}

fn formatToolGroupItem(allocator: std.mem.Allocator, messages: []const message_mod.Message, start_index: usize) !Item {
    const first = messages[0];
    const has_followup = messages[messages.len - 1].role == .assistant and messages[messages.len - 1].tool_calls.len == 0;
    const tool_result_count = if (has_followup) messages.len - 2 else messages.len - 1;

    var label_preview: []const u8 = first.content;
    if (label_preview.len == 0 and first.tool_calls.len > 0) {
        label_preview = first.tool_calls[0].name;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    const tool_names = blk: {
        var joined: std.Io.Writer.Allocating = .init(allocator);
        errdefer joined.deinit();
        for (first.tool_calls, 0..) |call, index| {
            if (index > 0) try joined.writer.writeAll(", ");
            try joined.writer.writeAll(call.name);
        }
        const slice = try allocator.dupe(u8, joined.written());
        joined.deinit();
        break :blk slice;
    };
    defer allocator.free(tool_names);

    try out.writer.print("## Tool execution\n\nstart message: {d}\nrole: assistant\ntool calls: {d}\nresults: {d}\nstatus: {s}\ntools: {s}\n", .{
        start_index + 1,
        first.tool_calls.len,
        tool_result_count,
        if (has_followup) "completed" else "awaiting follow-up",
        if (tool_names.len > 0) tool_names else "<none>",
    });

    if (first.content.len > 0) {
        try out.writer.print("\n### Assistant content\n\n{s}\n", .{first.content});
    }

    if (first.tool_calls.len > 0) {
        try out.writer.writeAll("\n### Requested tool calls\n\n");
        for (first.tool_calls, 0..) |call, call_index| {
            try out.writer.print("{d}. `{s}` (`{s}`)\n\n**arguments**\n\n```json\n{s}\n```\n\n", .{
                call_index + 1,
                call.name,
                call.id,
                call.arguments,
            });
        }
    }

    if (tool_result_count > 0) {
        try out.writer.writeAll("### Tool results\n\n");
        const result_slice = if (has_followup) messages[1 .. messages.len - 1] else messages[1..];
        for (result_slice, 0..) |msg, result_index| {
            try out.writer.print("{d}. `{s}` (`{s}`)\n\n**result**\n\n```\n{s}\n```\n\n", .{
                result_index + 1,
                msg.tool_name orelse "<unknown>",
                msg.tool_call_id orelse "<none>",
                if (msg.content.len > 0) msg.content else "<empty>",
            });
        }
    }

    if (has_followup) {
        const final_msg = messages[messages.len - 1];
        try out.writer.print("### Assistant follow-up\n\n{s}\n", .{
            if (final_msg.content.len > 0) final_msg.content else "<empty>",
        });
    }

    const body = try allocator.dupe(u8, out.written());
    out.deinit();

    return .{
        .label = try std.fmt.allocPrint(allocator, "{d}-{d}. [assistant/tools] {s}", .{
            start_index + 1,
            start_index + messages.len,
            if (has_followup and messages[messages.len - 1].content.len > 0)
                ziggy.FormatText.previewText(messages[messages.len - 1].content, 56)
            else
                ziggy.FormatText.previewText(label_preview, 56),
        }),
        .body = body,
        .reuse = if (has_followup and messages[messages.len - 1].content.len > 0)
            try allocator.dupe(u8, messages[messages.len - 1].content)
        else
            null,
    };
}

fn formatMessageBody(allocator: std.mem.Allocator, msg: message_mod.Message, index: usize) ![]u8 {
    _ = index;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    if (msg.tool_name) |tool_name| try out.writer.print("Tool: `{s}`\n", .{tool_name});
    if (msg.tool_call_id) |tool_call_id| try out.writer.print("Call: `{s}`\n", .{tool_call_id});
    if (msg.tool_calls.len > 0) {
        try out.writer.writeAll("\nRequested tools:\n\n");
        for (msg.tool_calls, 0..) |call, call_index| {
            try out.writer.print("{d}. `{s}` (`{s}`)\n\n```json\n{s}\n```\n\n", .{
                call_index + 1,
                call.name,
                call.id,
                call.arguments,
            });
        }
    }
    if (msg.tool_calls.len > 0 or msg.tool_name != null or msg.tool_call_id != null) {
        try out.writer.writeAll("\n");
    }
    if (msg.content.len > 0) {
        try out.writer.writeAll(msg.content);
    } else {
        try out.writer.writeAll("<empty>");
    }

    const body = try allocator.dupe(u8, out.written());
    out.deinit();
    return body;
}

fn collectRecentOutputLines(allocator: std.mem.Allocator, sidebar_output: []const u8, limit: usize) ![][]u8 {
    var raw = std.ArrayList([]const u8).empty;
    defer raw.deinit(allocator);

    var parts = std.mem.splitScalar(u8, sidebar_output, '\n');
    while (parts.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "<empty>")) continue;
        try raw.append(allocator, trimmed);
    }

    const start = raw.items.len -| limit;
    var out = try allocator.alloc([]u8, raw.items.len - start);
    for (raw.items[start..], 0..) |line, index| {
        out[index] = try allocator.dupe(u8, line);
    }
    return out;
}

fn shortcutReuseText(allocator: std.mem.Allocator, label: []const u8) !?[]u8 {
    const prefix = "Shortcut: ";
    if (!std.mem.startsWith(u8, label, prefix)) return null;
    return try allocator.dupe(u8, label[prefix.len..]);
}

pub fn actionReuseText(allocator: std.mem.Allocator, action: []const u8) !?[]u8 {
    const prefix = "run: ";
    if (!std.mem.startsWith(u8, action, prefix)) return null;
    return try allocator.dupe(u8, action[prefix.len..]);
}

pub fn outputReuseText(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \r\t");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '/') return try allocator.dupe(u8, trimmed);
    if (std.mem.startsWith(u8, trimmed, "[tool] ")) return null;
    return null;
}
