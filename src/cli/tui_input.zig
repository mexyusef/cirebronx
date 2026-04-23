const std = @import("std");
const ziggy = @import("ziggy");

const App = @import("../core/app.zig").App;
const windows = std.os.windows;

const WAIT_OBJECT_0: windows.DWORD = 0;
const WAIT_TIMEOUT: windows.DWORD = 258;
const ESC_SEQUENCE_WAIT_MS: windows.DWORD = 100;

pub fn handleInputControlKey(program: anytype, app: *App, key: ziggy.Key) !void {
    switch (key) {
        .ctrl_a => program.model.moveHome(),
        .ctrl_e => program.model.moveEnd(),
        .ctrl_j => {
            try program.model.insertNewline(app.allocator);
            try program.model.logAction(app.allocator, "inserted newline");
        },
        .ctrl_k => {
            try program.model.deleteToEnd(app.allocator);
            try program.model.logAction(app.allocator, "deleted to end");
        },
        .ctrl_r => {
            if (try program.model.searchHistoryBackward(app.allocator)) {
                try program.model.logAction(app.allocator, "history search match");
            } else {
                try program.model.logAction(app.allocator, "history search no match");
            }
        },
        .ctrl_u => {
            try program.model.deleteToStart(app.allocator);
            try program.model.logAction(app.allocator, "deleted to start");
        },
        .ctrl_w => {
            try program.model.deletePreviousWord(app.allocator);
            try program.model.logAction(app.allocator, "deleted previous word");
        },
        else => return,
    }
    try program.redraw();
}

pub fn handlePaneChar(
    program: anytype,
    app: *App,
    stdin: *std.Io.Reader,
    byte: u8,
    comptime submitCurrentInputFn: anytype,
    comptime conversationItemCountFn: anytype,
    comptime activityItemCountFn: anytype,
    comptime repoItemCountFn: anytype,
    comptime paneFocusStringFn: anytype,
) !bool {
    switch (byte) {
        '/' => {
            program.model.focus = .input;
            try program.model.replaceInput(app.allocator, "/", 1);
            try program.model.logAction(app.allocator, "quick command input");
            try program.redraw();
        },
        ':' => {
            program.model.focus = .input;
            try program.model.replaceInput(app.allocator, "/", 1);
            try program.model.logAction(app.allocator, "command palette input");
            try program.redraw();
        },
        'i' => {
            program.model.focus = .input;
            try program.model.logAction(app.allocator, "focus -> input");
            try program.redraw();
        },
        'c' => {
            program.model.focus = .input;
            try program.model.clearInput(app.allocator);
            try program.model.logAction(app.allocator, "cleared input");
            try program.redraw();
        },
        '?' => {
            try program.model.openHelpModal(app.allocator);
            try program.model.logAction(app.allocator, "opened help modal");
            try program.redraw();
        },
        's' => {
            try program.model.openSessionModal(app.allocator);
            try program.model.logAction(app.allocator, "opened session modal");
            try program.redraw();
        },
        'p' => {
            try program.model.openConfigModal(app.allocator);
            try program.model.logAction(app.allocator, "opened config modal");
            try program.redraw();
        },
        'g' => {
            switch (program.model.focus) {
                .conversation => program.model.conversation_selected = 0,
                .activity => program.model.activity_selected = 0,
                .repo => program.model.repo_state.tree_state.selection.cursor = 0,
                .input => {},
            }
            program.model.syncScrollBounds(program.tty.size);
            try program.model.logAction(app.allocator, "jump to top");
            try program.redraw();
        },
        'G' => {
            switch (program.model.focus) {
                .conversation => {
                    const total = try conversationItemCountFn(&program.model, app.allocator);
                    if (total > 0) program.model.conversation_selected = total - 1;
                },
                .activity => {
                    const total = activityItemCountFn(&program.model);
                    if (total > 0) program.model.activity_selected = total - 1;
                },
                .repo => {
                    const total = try repoItemCountFn(&program.model, app.allocator);
                    if (total > 0) program.model.repo_state.tree_state.selection.cursor = total - 1;
                },
                .input => {},
            }
            program.model.syncScrollBounds(program.tty.size);
            try program.model.logAction(app.allocator, "jump to bottom");
            try program.redraw();
        },
        'r' => {
            try program.model.reuseSelectedIntoInput(app.allocator);
            try program.model.logAction(app.allocator, "reuse selected item");
            try program.redraw();
        },
        'j' => {
            const conversation_total = try conversationItemCountFn(&program.model, app.allocator);
            const activity_total = activityItemCountFn(&program.model);
            program.model.moveSelectionDown(program.tty.size, conversation_total, activity_total);
            try program.redraw();
        },
        'k' => {
            program.model.moveSelectionUp(program.tty.size);
            try program.redraw();
        },
        'e' => {
            const reusable = try program.model.reusableSelection(app.allocator);
            if (reusable) |text| {
                defer app.allocator.free(text);
                try program.model.replaceInput(app.allocator, text, text.len);
                program.model.focus = .input;
                try program.model.logAction(app.allocator, "execute selected item");
                try program.redraw();
                if (try submitCurrentInputFn(program, app, stdin)) return true;
            } else {
                try program.model.logAction(app.allocator, "selected item is not directly executable");
                try program.redraw();
            }
        },
        'x' => {
            try program.model.setSidebarOutput(app.allocator, "Activity cleared.");
            try program.model.logAction(app.allocator, "cleared activity output");
            try program.redraw();
        },
        'T' => {
            if (try program.model.jumpToLatestTool(app.allocator, program.tty.size)) {
                try program.model.logAction(app.allocator, "jumped to latest tool sequence");
            } else {
                try program.model.logAction(app.allocator, "no tool sequence found");
            }
            try program.redraw();
        },
        'E' => {
            if (try program.model.jumpToLatestError(app.allocator, program.tty.size)) {
                try program.model.logAction(app.allocator, "jumped to latest error");
            } else {
                try program.model.logAction(app.allocator, "no error entry found");
            }
            try program.redraw();
        },
        else => {},
    }
    _ = paneFocusStringFn;
    return false;
}

pub fn readEventAlloc(allocator: std.mem.Allocator, stdin: anytype, stdin_file: ?std.fs.File) !?ziggy.Event {
    const first = stdin.takeByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };

    if (first != 0x1b) return ziggy.parseOne(&[_]u8{first}).?.event;
    if (@import("builtin").os.tag == .windows) {
        if (stdin_file) |file| {
            const wait_result = windows.kernel32.WaitForSingleObject(file.handle, ESC_SEQUENCE_WAIT_MS);
            if (wait_result == WAIT_TIMEOUT) return .{ .key = .escape };
            if (wait_result != WAIT_OBJECT_0) return .{ .key = .escape };
        }
    }
    const second = stdin.takeByte() catch return .{ .key = .escape };
    if (second != '[') return ziggy.parseOne(&[_]u8{ first, second }).?.event;
    const third = stdin.takeByte() catch return .{ .key = .escape };
    if (third == '<') {
        var seq = std.ArrayList(u8).empty;
        defer seq.deinit(allocator);
        try seq.appendSlice(allocator, &[_]u8{ first, second, third });
        while (true) {
            const byte = stdin.takeByte() catch return .{ .key = .escape };
            try seq.append(allocator, byte);
            if (byte == 'M' or byte == 'm') break;
        }
        return ziggy.parseOne(seq.items).?.event;
    }
    if (third == '2') {
        const fourth = stdin.takeByte() catch return .{ .key = .escape };
        const fifth = stdin.takeByte() catch return .{ .key = .escape };
        if (fourth == '0' and fifth == '0') {
            const tilde = stdin.takeByte() catch return .{ .key = .escape };
            if (tilde != '~') return .{ .key = .escape };
            var pasted = std.ArrayList(u8).empty;
            errdefer pasted.deinit(allocator);
            while (true) {
                const byte = stdin.takeByte() catch break;
                if (byte == 0x1b) {
                    const next1 = stdin.takeByte() catch {
                        try pasted.append(allocator, byte);
                        break;
                    };
                    const next2 = stdin.takeByte() catch {
                        try pasted.append(allocator, byte);
                        try pasted.append(allocator, next1);
                        break;
                    };
                    const next3 = stdin.takeByte() catch {
                        try pasted.append(allocator, byte);
                        try pasted.append(allocator, next1);
                        try pasted.append(allocator, next2);
                        break;
                    };
                    const next4 = stdin.takeByte() catch {
                        try pasted.append(allocator, byte);
                        try pasted.append(allocator, next1);
                        try pasted.append(allocator, next2);
                        try pasted.append(allocator, next3);
                        break;
                    };
                    if (next1 == '[' and next2 == '2' and next3 == '0' and next4 == '1') {
                        const tilde_end = stdin.takeByte() catch break;
                        if (tilde_end == '~') break;
                        try pasted.appendSlice(allocator, &[_]u8{ byte, next1, next2, next3, next4, tilde_end });
                        continue;
                    }
                    try pasted.appendSlice(allocator, &[_]u8{ byte, next1, next2, next3, next4 });
                    continue;
                }
                try pasted.append(allocator, byte);
            }
            const owned = try pasted.toOwnedSlice(allocator);
            const encoded = try std.fmt.allocPrint(allocator, "\x1b[200~{s}\x1b[201~", .{owned});
            defer allocator.free(encoded);
            allocator.free(owned);
            return (try ziggy.parseBracketedPaste(allocator, encoded)).?.event;
        }
        return try readCsiSequence(allocator, stdin, first, second, third);
    }
    return try readCsiSequence(allocator, stdin, first, second, third);
}

fn readCsiSequence(allocator: std.mem.Allocator, stdin: anytype, first: u8, second: u8, third: u8) !ziggy.Event {
    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(allocator);
    try seq.appendSlice(allocator, &[_]u8{ first, second, third });

    if (isCsiFinalByte(third)) {
        return ziggy.parseOne(seq.items).?.event;
    }

    while (true) {
        const byte = stdin.takeByte() catch return .{ .key = .escape };
        try seq.append(allocator, byte);
        if (isCsiFinalByte(byte)) break;
    }
    return ziggy.parseOne(seq.items).?.event;
}

fn isCsiFinalByte(byte: u8) bool {
    return byte == '~' or (byte >= '@' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}
