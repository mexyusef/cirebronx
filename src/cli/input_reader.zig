const std = @import("std");
const ziggy = @import("ziggy");

const windows = std.os.windows;

const WAIT_OBJECT_0: windows.DWORD = 0;
const WAIT_TIMEOUT: windows.DWORD = 258;

pub const InputQueue = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    mutex: std.Thread.Mutex = .{},
    events: std.ArrayList(ziggy.Event) = .empty,

    pub fn deinit(self: *InputQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.events.items) |*event| deinitEvent(self.allocator, event);
        self.events.deinit(self.allocator);
    }

    pub fn poll(self: *InputQueue) ![]ziggy.Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.toOwnedSlice(self.allocator);
    }

    fn push(self: *InputQueue, event: ziggy.Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events.append(self.allocator, event) catch {
            var owned = event;
            deinitEvent(self.allocator, &owned);
        };
    }
};

pub fn spawn(queue: *InputQueue, stdin: *std.Io.Reader) !void {
    _ = stdin;
    const Task = struct {
        queue: *InputQueue,
        stdin_file: std.fs.File,
        allocator: std.mem.Allocator = std.heap.page_allocator,
        pending: std.ArrayList(u8) = .empty,

        fn run(task: *@This()) void {
            defer task.pending.deinit(task.allocator);
            defer std.heap.page_allocator.destroy(task);
            var buffer: [1024]u8 = undefined;
            while (true) {
                if (@import("builtin").os.tag == .windows) {
                    const wait_result = windows.kernel32.WaitForSingleObject(task.stdin_file.handle, 50);
                    if (wait_result == WAIT_TIMEOUT) {
                        task.flushStandaloneEscape();
                        continue;
                    }
                    if (wait_result != WAIT_OBJECT_0) break;
                }

                const read_len = task.stdin_file.read(&buffer) catch break;
                if (read_len == 0) {
                    task.flushStandaloneEscape();
                    break;
                }
                task.pending.appendSlice(task.allocator, buffer[0..read_len]) catch break;
                task.drainPending() catch break;
            }
        }

        fn flushStandaloneEscape(task: *@This()) void {
            if (task.pending.items.len == 1 and task.pending.items[0] == 0x1b) {
                _ = task.pending.pop();
                task.queue.push(.{ .key = .escape });
            }
        }

        fn drainPending(task: *@This()) !void {
            while (try task.extractNextEvent()) |parsed| {
                task.queue.push(parsed.event);
                if (parsed.consumed >= task.pending.items.len) {
                    task.pending.clearRetainingCapacity();
                } else {
                    std.mem.copyForwards(u8, task.pending.items[0 .. task.pending.items.len - parsed.consumed], task.pending.items[parsed.consumed..]);
                    task.pending.items.len -= parsed.consumed;
                }
            }
        }

        const ParsedEvent = struct {
            event: ziggy.Event,
            consumed: usize,
        };

        fn extractNextEvent(task: *@This()) !?ParsedEvent {
            const bytes = task.pending.items;
            if (bytes.len == 0) return null;

            if (std.mem.startsWith(u8, bytes, "\x1b[200~")) {
                if (try ziggy.parseBracketedPaste(task.allocator, bytes)) |parsed| {
                    return .{ .event = parsed.event, .consumed = parsed.consumed };
                }
                return null;
            }

            if (bytes[0] == 0x1b and isIncompleteEscapeSequence(bytes)) return null;

            if (ziggy.parseOne(bytes)) |parsed| {
                return .{ .event = parsed.event, .consumed = parsed.consumed };
            }

            return .{ .event = .{ .key = .{ .char = bytes[0] } }, .consumed = 1 };
        }
    };

    const reader_task = try std.heap.page_allocator.create(Task);
    reader_task.* = .{
        .queue = queue,
        .stdin_file = std.fs.File.stdin(),
    };
    const thread = try std.Thread.spawn(.{}, struct {
        fn entry(thread_task: *Task) void {
            thread_task.run();
        }
    }.entry, .{reader_task});
    thread.detach();
}

fn isIncompleteEscapeSequence(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes[0] != 0x1b) return false;
    if (bytes.len == 1) return true;
    if (bytes[1] == 'O') return bytes.len < 3;
    if (bytes[1] != '[') return false;
    if (bytes.len == 2) return true;

    if (bytes[2] == '<') {
        return std.mem.indexOfAny(u8, bytes[3..], "Mm") == null;
    }

    if (std.mem.startsWith(u8, bytes, "\x1b[200~")) {
        return std.mem.indexOf(u8, bytes[6..], "\x1b[201~") == null;
    }

    var index: usize = 2;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte == '~' or (byte >= '@' and byte <= 'Z') or (byte >= 'a' and byte <= 'z')) return false;
    }
    return true;
}

pub fn deinitEvent(allocator: std.mem.Allocator, event: *ziggy.Event) void {
    switch (event.*) {
        .paste => |text| allocator.free(text),
        else => {},
    }
}
