const std = @import("std");
const ziggy = @import("ziggy");

const App = @import("../core/app.zig").App;
const commands = @import("../commands/registry.zig");
const permissions = @import("../core/permissions.zig");
const prompt_history_store = @import("../storage/prompt_history.zig");
const runtime_turn = @import("../runtime/turn.zig");
const tui_state = @import("tui_state.zig");
const tui_layout = @import("tui_layout.zig");

const color_reset = "\x1b[0m";
const color_banner = "\x1b[1;36m";
const color_hint = "\x1b[2;37m";
const color_prompt_provider = "\x1b[1;34m";
const color_prompt_model = "\x1b[1;32m";
const color_assistant = "\x1b[0;37m";
const color_tool = "\x1b[1;33m";
const color_error = "\x1b[1;31m";

pub fn runInteractive(app: *App) !void {
    _ = std.fs.File.stdout().getOrEnableAnsiEscapeSupport();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    try stdout.print("{s}cirebronx interactive mode{s}\n", .{ color_banner, color_reset });
    try stdout.print("{s}Type /help for commands or enter a prompt.{s}\n\n", .{ color_hint, color_reset });
    try stdout.flush();

    while (true) {
        try stdout.print("{s}[{s}{s}:{s}{s}]>{s} ", .{
            color_hint,
            color_prompt_provider,
            app.config.provider,
            color_prompt_model,
            app.config.model,
            color_reset,
        });
        try stdout.flush();

        const maybe_line = try stdin.takeDelimiter('\n');
        if (maybe_line == null) {
            try stdout.writeByte('\n');
            try stdout.flush();
            break;
        }

        const line = std.mem.trim(u8, maybe_line.?, " \r\t");
        if (line.len == 0) continue;

        const handled = commands.handle(app, line, .{
            .stdout = stdout,
            .stdin = stdin,
            .interactive = true,
        }) catch |err| switch (err) {
            commands.CommandError.ExitRequested => break,
            else => return err,
        };
        if (handled) {
            if (app.takePendingInjectedPrompt()) |rendered| {
                defer app.allocator.free(rendered);
                runPromptLine(app, rendered, stdout, stdin, true) catch |err| {
                    try printRuntimeError(app, stdout, err);
                };
            }
            continue;
        }

        if (try commands.tryBareSkillInvocation(app, line, .{
            .stdout = stdout,
            .stdin = stdin,
            .interactive = true,
        })) {
            if (app.takePendingInjectedPrompt()) |rendered| {
                defer app.allocator.free(rendered);
                runPromptLine(app, rendered, stdout, stdin, true) catch |err| {
                    try printRuntimeError(app, stdout, err);
                };
            }
            continue;
        }

        runPromptLine(app, line, stdout, stdin, true) catch |err| {
            try printRuntimeError(app, stdout, err);
        };
    }
}

pub fn runSingleShot(app: *App, prompt: []const u8) !void {
    _ = std.fs.File.stdout().getOrEnableAnsiEscapeSupport();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    if (prompt.len > 0 and prompt[0] == '/') {
        const handled = commands.handle(app, prompt, .{
            .stdout = stdout,
            .stdin = null,
            .interactive = false,
        }) catch |err| switch (err) {
            commands.CommandError.ExitRequested => return,
            else => return err,
        };
        if (handled) {
            if (app.takePendingInjectedPrompt()) |rendered| {
                defer app.allocator.free(rendered);
                runPromptLine(app, rendered, stdout, null, false) catch |err| {
                    try printRuntimeError(app, stdout, err);
                    return err;
                };
                return;
            }
            return;
        }
    }
    if (try commands.tryBareSkillInvocation(app, prompt, .{
        .stdout = stdout,
        .stdin = null,
        .interactive = false,
    })) {
        if (app.takePendingInjectedPrompt()) |rendered| {
            defer app.allocator.free(rendered);
            runPromptLine(app, rendered, stdout, null, false) catch |err| {
                try printRuntimeError(app, stdout, err);
                return err;
            };
        }
        return;
    }
    runPromptLine(app, prompt, stdout, null, false) catch |err| {
        try printRuntimeError(app, stdout, err);
        return err;
    };
}

pub fn runPromptLine(
    app: *App,
    prompt: []const u8,
    stdout: *std.Io.Writer,
    stdin: ?*std.Io.Reader,
    interactive: bool,
) !void {
    try persistPromptHistory(app, prompt);
    var observer = WriterObserver.init(
        app.allocator,
        .{
            .stdout = stdout,
            .interactive = interactive,
            .width = tui_layout.detectTerminalSize().width,
        },
    );
    defer observer.deinit();

    var turn_result = try runtime_turn.runPrompt(app, prompt, .{
        .context = &observer,
        .on_text_chunk = onTextChunk,
        .on_status = onStatus,
        .on_tool_calls = onToolCalls,
    }, .{
        .io = .{
            .stdout = stdout,
            .stdin = stdin,
            .interactive = interactive,
        },
    });
    defer turn_result.deinit(app.allocator);

    if (turn_result.final_text) |text| {
        if (!observer.wrote_text) {
            try renderMarkdownBlock(stdout, app.allocator, text, observer.width);
        } else {
            try observer.finishStream();
        }
        if (observer.line_open) try stdout.writeByte('\n');
        try stdout.flush();
        observer.reset();
    }
}

fn persistPromptHistory(app: *App, prompt: []const u8) !void {
    var history = tui_state.PromptHistory{};
    defer history.deinit(app.allocator);

    const persisted = try prompt_history_store.load(app.allocator, app.config.paths, app.cwd);
    defer {
        for (persisted) |item| app.allocator.free(item);
        app.allocator.free(persisted);
    }

    try history.replaceAll(app.allocator, persisted);
    try history.push(app.allocator, prompt);
    try prompt_history_store.save(app.allocator, app.config.paths, app.cwd, history.items.items);
}

const WriterObserver = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    interactive: bool,
    width: u16,
    wrote_text: bool = false,
    pending: std.ArrayList(u8) = .empty,
    in_code_block: bool = false,
    line_open: bool = false,

    fn init(allocator: std.mem.Allocator, args: struct {
        stdout: *std.Io.Writer,
        interactive: bool,
        width: u16,
    }) WriterObserver {
        return .{
            .allocator = allocator,
            .stdout = args.stdout,
            .interactive = args.interactive,
            .width = args.width,
        };
    }

    fn deinit(self: *WriterObserver) void {
        self.pending.deinit(self.allocator);
    }

    fn reset(self: *WriterObserver) void {
        self.wrote_text = false;
        self.pending.clearRetainingCapacity();
        self.in_code_block = false;
        self.line_open = false;
    }

    fn appendChunk(self: *WriterObserver, text: []const u8) !void {
        self.wrote_text = true;
        try self.pending.appendSlice(self.allocator, text);
        try self.flushCompleteLines();
        if (self.interactive and self.pending.items.len > 0 and !self.in_code_block and !containsStreamingMarkdownSyntax(self.pending.items)) {
            const partial = try self.allocator.dupe(u8, self.pending.items);
            defer self.allocator.free(partial);
            try renderMarkdownStreamPartial(self.stdout, partial);
            self.pending.clearRetainingCapacity();
            self.line_open = true;
        } else {
            self.line_open = self.pending.items.len > 0;
        }
        try self.stdout.flush();
    }

    fn finishStream(self: *WriterObserver) !void {
        if (self.pending.items.len > 0) {
            const leftover = try self.allocator.dupe(u8, self.pending.items);
            defer self.allocator.free(leftover);
            if (self.interactive and !self.in_code_block) {
                try renderMarkdownStreamPartial(self.stdout, leftover);
            } else {
                try renderMarkdownStreamLine(self.stdout, leftover, &self.in_code_block);
            }
            self.pending.clearRetainingCapacity();
        }
        self.line_open = true;
        try self.stdout.flush();
    }

    fn flushCompleteLines(self: *WriterObserver) !void {
        while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |newline_index| {
            const line = std.mem.trimRight(u8, self.pending.items[0..newline_index], "\r");
            const owned = try self.allocator.dupe(u8, line);
            defer self.allocator.free(owned);
            try renderMarkdownStreamLine(self.stdout, owned, &self.in_code_block);
            if (newline_index + 1 < self.pending.items.len) {
                std.mem.copyForwards(u8, self.pending.items[0 .. self.pending.items.len - newline_index - 1], self.pending.items[newline_index + 1 ..]);
            }
            self.pending.items.len -= newline_index + 1;
            self.line_open = false;
        }
    }
};

fn onTextChunk(raw: ?*anyopaque, text: []const u8) !void {
    const observer: *WriterObserver = @ptrCast(@alignCast(raw.?));
    try observer.appendChunk(text);
}

fn onStatus(raw: ?*anyopaque, text: []const u8) !void {
    _ = text;
    const observer: *WriterObserver = @ptrCast(@alignCast(raw.?));
    if (observer.interactive) try observer.stdout.flush();
}

fn onToolCalls(raw: ?*anyopaque, calls: []const @import("../core/message.zig").ToolCall) !void {
    const observer: *WriterObserver = @ptrCast(@alignCast(raw.?));
    observer.reset();
    for (calls) |call| {
        try observer.stdout.print("{s}[tool]{s} {s}\n", .{ color_tool, color_reset, call.name });
    }
    try observer.stdout.flush();
}

fn printRuntimeError(app: *App, stdout: *std.Io.Writer, err: anyerror) !void {
    if (app.last_provider_error) |text| {
        try stdout.print("{s}{s}{s}\n", .{ color_error, text, color_reset });
    } else {
        try stdout.print("{s}error: {s}{s}\n", .{ color_error, @errorName(err), color_reset });
    }
    try stdout.flush();
}

fn renderMarkdownBlock(stdout: *std.Io.Writer, allocator: std.mem.Allocator, text: []const u8, width_u16: u16) !void {
    const width: usize = @max(@as(usize, width_u16) -| 2, 20);
    const theme = ziggy.FormatRichMarkdown.Theme{
        .base = .{ .fg = .{ .ansi = 7 } },
        .heading = .{ .fg = .{ .ansi = 14 }, .bold = true },
        .bullet = .{ .fg = .{ .ansi = 11 }, .bold = true },
        .quote = .{ .fg = .{ .ansi = 6 }, .dim = true },
        .code = .{ .fg = .{ .ansi = 10 }, .bg = .{ .ansi = 8 } },
        .strong = .{ .bold = true },
        .emphasis = .{ .underline = true },
        .link = .{ .fg = .{ .ansi = 12 }, .underline = true },
        .muted = .{ .fg = .{ .ansi = 8 }, .dim = true },
        .accent = .{ .fg = .{ .ansi = 12 }, .bold = true },
        .code_lineno = .{ .fg = .{ .ansi = 8 }, .dim = true },
    };
    const lines = try ziggy.FormatRichMarkdown.renderLines(allocator, text, width, theme);
    defer ziggy.RichText.freeLines(allocator, lines);

    for (lines) |line| {
        try writeRichLine(stdout, line);
        try stdout.writeByte('\n');
    }
}

fn renderMarkdownStreamLine(stdout: *std.Io.Writer, line: []const u8, in_code_block: *bool) !void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "```")) {
        if (!in_code_block.*) {
            in_code_block.* = true;
            const lang = std.mem.trim(u8, trimmed[3..], " \t");
            try writeStyled(stdout, .{ .fg = .{ .ansi = 12 }, .bold = true }, if (lang.len == 0) "[code]" else "[code:");
            if (lang.len > 0) {
                try writeStyled(stdout, .{ .fg = .{ .ansi = 12 }, .bold = true }, lang);
                try writeStyled(stdout, .{ .fg = .{ .ansi = 12 }, .bold = true }, "]");
            }
            try stdout.writeByte('\n');
        } else {
            in_code_block.* = false;
            try stdout.writeByte('\n');
        }
        return;
    }

    if (in_code_block.*) {
        try writeStyled(stdout, .{ .fg = .{ .ansi = 10 }, .bg = .{ .ansi = 8 } }, line);
        try stdout.writeByte('\n');
        return;
    }

    if (trimmed.len == 0) {
        try stdout.writeByte('\n');
        return;
    }

    if (isHorizontalRule(trimmed)) {
        try writeStyled(stdout, .{ .fg = .{ .ansi = 8 }, .dim = true }, "----------------------------------------");
        try stdout.writeByte('\n');
        return;
    }

    if (headingLevel(trimmed)) |level| {
        const content = std.mem.trimLeft(u8, trimmed[level + 1 ..], " \t");
        try writeStyled(stdout, .{ .fg = .{ .ansi = 14 }, .bold = true }, content);
        try stdout.writeByte('\n');
        return;
    }

    if (bulletPrefix(trimmed)) |prefix_len| {
        try writeStyled(stdout, .{ .fg = .{ .ansi = 11 }, .bold = true }, trimmed[0..prefix_len]);
        try writeInlineStyled(stdout, trimmed[prefix_len..]);
        try stdout.writeByte('\n');
        return;
    }

    if (std.mem.startsWith(u8, trimmed, ">")) {
        try writeStyled(stdout, .{ .fg = .{ .ansi = 6 }, .dim = true }, "> ");
        try writeStyled(stdout, .{ .fg = .{ .ansi = 6 }, .dim = true }, std.mem.trimLeft(u8, trimmed[1..], " \t"));
        try stdout.writeByte('\n');
        return;
    }

    try writeInlineStyled(stdout, line);
    try stdout.writeByte('\n');
}

fn renderMarkdownStreamPartial(stdout: *std.Io.Writer, text: []const u8) !void {
    try writeInlineStyled(stdout, text);
}

fn containsStreamingMarkdownSyntax(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.indexOfAny(u8, text, "*`[_")) |_| return true;
    if (std.mem.indexOf(u8, text, "http://") != null or std.mem.indexOf(u8, text, "https://") != null) return true;

    const trimmed_left = std.mem.trimLeft(u8, text, " \t");
    if (trimmed_left.len == 0) return false;
    if (trimmed_left[0] == '#' or trimmed_left[0] == '>') return true;
    if (trimmed_left.len >= 2 and (trimmed_left[0] == '-' or trimmed_left[0] == '*' or trimmed_left[0] == '+') and trimmed_left[1] == ' ') return true;

    var idx: usize = 0;
    while (idx < trimmed_left.len and std.ascii.isDigit(trimmed_left[idx])) : (idx += 1) {}
    return idx > 0 and idx + 1 < trimmed_left.len and trimmed_left[idx] == '.' and trimmed_left[idx + 1] == ' ';
}

test "containsStreamingMarkdownSyntax keeps markdown partials buffered" {
    try std.testing.expect(containsStreamingMarkdownSyntax("**bold"));
    try std.testing.expect(containsStreamingMarkdownSyntax("`code"));
    try std.testing.expect(containsStreamingMarkdownSyntax("# heading"));
    try std.testing.expect(containsStreamingMarkdownSyntax("- list"));
    try std.testing.expect(containsStreamingMarkdownSyntax("1. item"));
    try std.testing.expect(!containsStreamingMarkdownSyntax("plain streaming text"));
}

fn writeRichLine(stdout: *std.Io.Writer, line: ziggy.RichText.Line) !void {
    for (line.spans) |span| {
        try writeStyled(stdout, span.style, span.text);
    }
    try writeStyle(stdout, .{});
}

fn writeInlineStyled(stdout: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, text, i + 2, "**");
            if (end) |j| {
                try writeStyled(stdout, .{ .bold = true }, text[i + 2 .. j]);
                i = j + 2;
                continue;
            }
        }
        if (text[i] == '`') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '`');
            if (end) |j| {
                try writeStyled(stdout, .{ .fg = .{ .ansi = 10 }, .bg = .{ .ansi = 8 } }, text[i + 1 .. j]);
                i = j + 1;
                continue;
            }
        }
        if (text[i] == '_' ) {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '_');
            if (end) |j| {
                try writeStyled(stdout, .{ .underline = true }, text[i + 1 .. j]);
                i = j + 1;
                continue;
            }
        }
        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close| {
                if (close + 1 < text.len and text[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |end| {
                        try writeStyled(stdout, .{ .fg = .{ .ansi = 12 }, .underline = true }, text[i + 1 .. close]);
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        if (std.mem.startsWith(u8, text[i..], "http://") or std.mem.startsWith(u8, text[i..], "https://")) {
            var end = i;
            while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
            try writeStyled(stdout, .{ .fg = .{ .ansi = 12 }, .underline = true }, text[i..end]);
            i = end;
            continue;
        }

        var next = i + 1;
        while (next < text.len and text[next] != '*' and text[next] != '`' and text[next] != '_' and text[next] != '[' and !std.mem.startsWith(u8, text[next..], "http://") and !std.mem.startsWith(u8, text[next..], "https://")) : (next += 1) {}
        try writeStyled(stdout, .{ .fg = .{ .ansi = 7 } }, text[i..next]);
        i = next;
    }
    try writeStyle(stdout, .{});
}

fn writeStyled(stdout: *std.Io.Writer, style: ziggy.Style, text: []const u8) !void {
    try writeStyle(stdout, style);
    try stdout.writeAll(text);
    try writeStyle(stdout, .{});
}

fn writeStyle(stdout: *std.Io.Writer, style: ziggy.Style) !void {
    try stdout.writeAll("\x1b[0");
    if (style.bold) try stdout.writeAll(";1");
    if (style.dim) try stdout.writeAll(";2");
    if (style.underline) try stdout.writeAll(";4");
    try writeColor(stdout, style.fg, true);
    try writeColor(stdout, style.bg, false);
    try stdout.writeByte('m');
}

fn writeColor(stdout: *std.Io.Writer, color: ziggy.Color, fg: bool) !void {
    const base_true: u8 = if (fg) 38 else 48;
    switch (color) {
        .default => {},
        .ansi => |idx| {
            if (idx < 8) {
                try stdout.print(";{d}", .{(if (fg) @as(u8, 30) else @as(u8, 40)) + idx});
            } else if (idx < 16) {
                try stdout.print(";{d}", .{(if (fg) @as(u8, 90) else @as(u8, 100)) + (idx - 8)});
            } else {
                try stdout.print(";{d};5;{d}", .{ base_true, idx });
            }
        },
        .rgb => |rgb| try stdout.print(";{d};2;{d};{d};{d}", .{ base_true, rgb.r, rgb.g, rgb.b }),
    }
}

fn headingLevel(line: []const u8) ?usize {
    var idx: usize = 0;
    while (idx < line.len and idx < 4 and line[idx] == '#') : (idx += 1) {}
    if (idx == 0 or idx >= line.len or line[idx] != ' ') return null;
    return idx;
}

fn bulletPrefix(line: []const u8) ?usize {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') return 2;
    var idx: usize = 0;
    while (idx < line.len and std.ascii.isDigit(line[idx])) : (idx += 1) {}
    if (idx > 0 and idx + 1 < line.len and line[idx] == '.' and line[idx + 1] == ' ') return idx + 2;
    return null;
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const first = line[0];
    if (first != '-' and first != '*' and first != '_') return false;
    for (line) |byte| {
        if (byte != first) return false;
    }
    return true;
}
