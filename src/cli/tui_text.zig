const std = @import("std");
const ziggy = @import("ziggy");

const App = @import("../core/app.zig").App;
const mcp_store = @import("../storage/mcp.zig");
const permissions = @import("../core/permissions.zig");
const session_store = @import("../storage/session.zig");

const embedded_help = @embedFile("help.md");

pub fn buildHelpBody(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8, embedded_help);
}

pub fn buildStartupSidebar(allocator: std.mem.Allocator, profile: ziggy.RenderProfile) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        \\Type prompts here. Enter submits. Enter on panes inspects. Ctrl+D quits.
        \\Ctrl+B toggles the right sidebar.
        \\Ctrl+Y copies the selected pane or modal content.
        \\Ctrl+X quits the app.
        \\Use v / m / t for provider, model, and theme pickers.
        \\Skill and command roots are read from ~/.codex and ~/.claude.
        \\Use /tools, /skills, /commands, or /mcp status to inspect the local agent surface.
        \\
        \\terminal
        \\  render_mode: {s}
        \\  icon_mode:   {s}
        \\  unicode:     {s}
        \\  icons:       {s}
        \\
        \\override
        \\  ZIGGY_RENDER_MODE=unicode_force
        \\  ZIGGY_ICON_MODE=unicode
    , .{
        @tagName(profile.render_mode),
        @tagName(profile.icon_mode),
        if (profile.unicodeEnabled()) "enabled" else "fallback",
        if (profile.iconEnabled()) "enabled" else "fallback",
    });
}

pub fn buildSessionBody(allocator: std.mem.Allocator, app: *const App, turn_running: bool, status_text: []const u8) ![]u8 {
    const messages_text = try std.fmt.allocPrint(allocator, "{d}", .{app.session.items.len});
    defer allocator.free(messages_text);
    const servers = try mcp_store.load(allocator, app.config.paths);
    defer mcp_store.deinitServers(allocator, servers);
    const mcp_count = try std.fmt.allocPrint(allocator, "{d}", .{servers.len});
    defer allocator.free(mcp_count);
    const base = try ziggy.FormatText.buildFieldsBody(allocator, &.{
        .{ .key = "session_id", .value = app.session_id },
        .{ .key = "messages", .value = messages_text },
        .{ .key = "cwd", .value = app.cwd },
        .{ .key = "provider", .value = app.config.provider },
        .{ .key = "model", .value = app.config.model },
        .{ .key = "mcp_servers", .value = mcp_count },
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
    try out.writer.writeAll("\n\nmcp servers\n");
    if (servers.len == 0) {
        try out.writer.writeAll("  <none>\n");
    } else {
        for (servers) |server| {
            try out.writer.print("  {s}  {s}\n", .{ server.name, server.command });
        }
    }
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
        .{ .title = "theme", .body = app.config.theme },
        .{ .title = "model", .body = app.config.model },
        .{ .title = "base_url", .body = app.config.base_url },
        .{ .title = "permissions", .body = permissions_body },
        .{ .title = "commands", .body = "/sessions\n/provider <preset>\n/theme <preset>\n/model <name>\n/tools\n/permissions [class mode]\n/doctor\n/diff\n/review\n/compact\n/commands\n/skills\n/themes\n/mcp status\n/mcp show <name>" },
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
