const std = @import("std");
const ziggy = @import("ziggy");

const App = @import("../core/app.zig").App;
const permissions = @import("../core/permissions.zig");
const session_store = @import("../storage/session.zig");

pub fn buildHelpBody(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        \\Navigation
        \\  Tab        cycle focus forward
        \\  Shift+Tab  cycle focus backward
        \\  j / k      move selection
        \\  g / G      jump top / bottom
        \\  Home/End   move cursor or jump pane bounds
        \\  PgUp/PgDn  move by half a pane
        \\  T / E      jump to latest tool / error entry
        \\  Alt+B/F    move by word
        \\  Enter      inspect selected item
        \\  Esc        close modal
        \\
        \\Actions
        \\  r          reuse selected item into input
        \\  e          execute selected reusable item
        \\  c          clear input
        \\  x          clear activity output
        \\  / or :     start slash command input
        \\
        \\Inspection
        \\  ?          open this help
        \\  s          open session modal
        \\  p          open config / permissions modal
        \\  y/a/n/d    answer approval modal
        \\
        \\Input
        \\  Left/Right move cursor
        \\  Ctrl+A/E   move to start / end
        \\  Ctrl+J     insert newline
        \\  Ctrl+R     search prompt history backward
        \\  Ctrl+W     delete previous word
        \\  Ctrl+U/K   delete to start / end
        \\  Paste      bracketed paste inserts raw text
        \\  Backspace  delete backward
        \\  Ctrl+D     quit
        \\
    , .{});
}

pub fn buildSessionBody(allocator: std.mem.Allocator, app: *const App, turn_running: bool, status_text: []const u8) ![]u8 {
    const messages_text = try std.fmt.allocPrint(allocator, "{d}", .{app.session.items.len});
    defer allocator.free(messages_text);
    const base = try ziggy.FormatText.buildFieldsBody(allocator, &.{
        .{ .key = "session_id", .value = app.session_id },
        .{ .key = "messages", .value = messages_text },
        .{ .key = "cwd", .value = app.cwd },
        .{ .key = "provider", .value = app.config.provider },
        .{ .key = "model", .value = app.config.model },
        .{ .key = "plan_mode", .value = if (app.plan_mode) "on" else "off" },
        .{ .key = "turn_running", .value = if (turn_running) "yes" else "no" },
        .{ .key = "status", .value = status_text },
    });
    defer allocator.free(base);

    const sessions = try session_store.listSessions(allocator, app.config.paths);
    defer {
        for (sessions) |*session| session.deinit(allocator);
        allocator.free(sessions);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(base);
    try out.writer.writeAll("\n\nrecent sessions\n");
    if (sessions.len == 0) {
        try out.writer.writeAll("  <none>\n");
    } else {
        for (sessions[0..@min(sessions.len, 5)]) |session| {
            try out.writer.print("  {s}  model={s}  messages={d}\n", .{
                session.id,
                session.model,
                session.message_count,
            });
        }
    }
    return try out.toOwnedSlice();
}

pub fn buildConfigBody(allocator: std.mem.Allocator, app: *const App) ![]u8 {
    const permissions_body = try std.fmt.allocPrint(allocator, "read={s}\nwrite={s}\nshell={s}", .{
        permissions.modeString(app.permissions.read),
        permissions.modeString(app.permissions.write),
        permissions.modeString(app.permissions.shell),
    });
    defer allocator.free(permissions_body);
    return try ziggy.FormatText.buildSectionsBody(allocator, &.{
        .{ .title = "provider", .body = app.config.provider },
        .{ .title = "model", .body = app.config.model },
        .{ .title = "base_url", .body = app.config.base_url },
        .{ .title = "permissions", .body = permissions_body },
        .{ .title = "commands", .body = "/sessions\n/provider <preset>\n/model <name>\n/permissions [class mode]\n/doctor\n/diff\n/review\n/compact" },
    });
}

pub fn latestActivitySummary(status_text: []const u8, actions: []const []u8) []const u8 {
    if (actions.len > 0) return actions[actions.len - 1];
    return status_text;
}

pub fn activityActionLabel(allocator: std.mem.Allocator, action: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, action, "run: ")) {
        return try std.fmt.allocPrint(allocator, "Run: {s}", .{ziggy.FormatText.previewText(action["run: ".len..], 56)});
    }
    if (std.mem.startsWith(u8, action, "done: ")) {
        return try std.fmt.allocPrint(allocator, "Done: {s}", .{ziggy.FormatText.previewText(action["done: ".len..], 56)});
    }
    if (std.mem.indexOf(u8, action, "tool") != null) {
        return try std.fmt.allocPrint(allocator, "Tool: {s}", .{ziggy.FormatText.previewText(action, 56)});
    }
    return try std.fmt.allocPrint(allocator, "Action: {s}", .{ziggy.FormatText.previewText(action, 56)});
}

pub fn activityOutputLabel(allocator: std.mem.Allocator, line: []const u8, line_index: usize) ![]u8 {
    if (std.mem.startsWith(u8, line, "[tool] ")) {
        return try std.fmt.allocPrint(allocator, "Tool {d}: {s}", .{ line_index, ziggy.FormatText.previewText(line["[tool] ".len..], 56) });
    }
    if (std.mem.startsWith(u8, line, "error: ")) {
        return try std.fmt.allocPrint(allocator, "Error {d}: {s}", .{ line_index, ziggy.FormatText.previewText(line["error: ".len..], 56) });
    }
    return try std.fmt.allocPrint(allocator, "Output {d}: {s}", .{ line_index, ziggy.FormatText.previewText(line, 56) });
}
