const std = @import("std");

pub const Command = enum {
    interactive,
    tui,
    chat,
    app_server,
    resume_session,
    help,
    version,
};

pub const ParsedArgs = struct {
    command: Command,
    prompt: ?[]u8,
    session_id: ?[]u8,
    port: ?u16,

    pub fn deinit(self: *const ParsedArgs, allocator: std.mem.Allocator) void {
        if (self.prompt) |prompt| allocator.free(prompt);
        if (self.session_id) |session_id| allocator.free(session_id);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator) !ParsedArgs {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    return parseArgsSlice(allocator, argv);
}

fn parseArgsSlice(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    if (argv.len <= 1) {
        return .{ .command = .tui, .prompt = null, .session_id = null, .port = null };
    }

    const first = argv[1];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return .{ .command = .help, .prompt = null, .session_id = null, .port = null };
    }
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
        return .{ .command = .version, .prompt = null, .session_id = null, .port = null };
    }
    if (std.mem.eql(u8, first, "--tui")) {
        return .{ .command = .tui, .prompt = null, .session_id = null, .port = null };
    }
    if (std.mem.eql(u8, first, "--app-server")) {
        var port: u16 = 9240;
        if (argv.len >= 3) {
            if (std.mem.eql(u8, argv[2], "--port")) {
                if (argv.len < 4) return error.InvalidPort;
                port = try std.fmt.parseInt(u16, argv[3], 10);
            } else {
                port = try std.fmt.parseInt(u16, argv[2], 10);
            }
        }
        return .{ .command = .app_server, .prompt = null, .session_id = null, .port = port };
    }
    if (std.mem.eql(u8, first, "--resume")) {
        const session_id = if (argv.len >= 3) argv[2] else "latest";
        return .{
            .command = .resume_session,
            .prompt = null,
            .session_id = try allocator.dupe(u8, session_id),
            .port = null,
        };
    }

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    for (argv[1..], 0..) |arg, index| {
        if (index > 0) try list.append(allocator, ' ');
        try list.appendSlice(allocator, arg);
    }

    return .{
        .command = .chat,
        .prompt = try list.toOwnedSlice(allocator),
        .session_id = null,
        .port = null,
    };
}

pub fn printHelp() !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\cirebronx
        \\
        \\Usage:
        \\  cirebronx              Start pane-based TUI mode
        \\  cirebronx --tui        Start pane-based TUI mode
        \\  cirebronx "prompt"     Run a single prompt
        \\  cirebronx --app-server [PORT]
        \\                        Start WebSocket JSON-RPC app-server
        \\  cirebronx --resume     Resume latest session
        \\  cirebronx --resume ID  Resume a specific session
        \\  CIREBRONX_PROVIDER=groq cirebronx "hello"
        \\  cirebronx --help       Show help
        \\  cirebronx --version    Show version
        \\
    );
    try stdout.flush();
}

pub fn printVersion() !void {
    var buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("cirebronx {s}\n", .{"0.1.0"});
    try stdout.flush();
}

test "parseArgsSlice parses app server default port" {
    const allocator = std.testing.allocator;
    var parsed = try parseArgsSlice(allocator, &.{ "cirebronx", "--app-server" });
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(Command.app_server, parsed.command);
    try std.testing.expectEqual(@as(?u16, 9240), parsed.port);
}

test "parseArgsSlice parses explicit app server port forms" {
    const allocator = std.testing.allocator;

    var parsed_short = try parseArgsSlice(allocator, &.{ "cirebronx", "--app-server", "9242" });
    defer parsed_short.deinit(allocator);
    try std.testing.expectEqual(Command.app_server, parsed_short.command);
    try std.testing.expectEqual(@as(?u16, 9242), parsed_short.port);

    var parsed_long = try parseArgsSlice(allocator, &.{ "cirebronx", "--app-server", "--port", "9243" });
    defer parsed_long.deinit(allocator);
    try std.testing.expectEqual(Command.app_server, parsed_long.command);
    try std.testing.expectEqual(@as(?u16, 9243), parsed_long.port);
}
