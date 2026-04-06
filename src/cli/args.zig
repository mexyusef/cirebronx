const std = @import("std");

pub const Command = enum {
    interactive,
    tui,
    chat,
    resume_session,
    help,
    version,
};

pub const ParsedArgs = struct {
    command: Command,
    prompt: ?[]u8,
    session_id: ?[]u8,

    pub fn deinit(self: *const ParsedArgs, allocator: std.mem.Allocator) void {
        if (self.prompt) |prompt| allocator.free(prompt);
        if (self.session_id) |session_id| allocator.free(session_id);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator) !ParsedArgs {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len <= 1) {
        return .{ .command = .tui, .prompt = null, .session_id = null };
    }

    const first = argv[1];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return .{ .command = .help, .prompt = null, .session_id = null };
    }
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
        return .{ .command = .version, .prompt = null, .session_id = null };
    }
    if (std.mem.eql(u8, first, "--tui")) {
        return .{ .command = .tui, .prompt = null, .session_id = null };
    }
    if (std.mem.eql(u8, first, "--resume")) {
        const session_id = if (argv.len >= 3) argv[2] else "latest";
        return .{
            .command = .resume_session,
            .prompt = null,
            .session_id = try allocator.dupe(u8, session_id),
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
        \\  cirebronx --resume     Resume latest session
        \\  cirebronx --resume ID  Resume a specific session
        \\  CIREBRONX_PROVIDER=gemini cirebronx "hello"
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
