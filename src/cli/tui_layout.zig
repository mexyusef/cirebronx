const std = @import("std");
const ziggy = @import("ziggy");
const builtin = @import("builtin");

pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

pub fn maxScrollOffset(total_lines: usize, visible: usize) usize {
    return if (total_lines > visible) total_lines - visible else 0;
}

pub fn topAreaRatio(size: ziggy.Size) u8 {
    _ = size;
    return 84;
}

pub fn bottomInputRatio(size: ziggy.Size) u8 {
    if (size.height <= 16) return 45;
    return 50;
}

pub fn mainTopHeight(size: ziggy.Size) usize {
    return (@as(usize, size.height) * topAreaRatio(size)) / 100;
}

pub fn leftPaneRatio(size: ziggy.Size) u8 {
    if (size.width >= 180) return 88;
    if (size.width >= 140) return 86;
    if (size.width >= 110) return 84;
    return 82;
}

pub fn leftPaneWidth(size: ziggy.Size) usize {
    const total = @as(usize, size.width);
    const left = (total * leftPaneRatio(size)) / 100;
    return left;
}

pub fn conversationBodyWidth(size: ziggy.Size) usize {
    return @as(usize, size.width) -| 4;
}

pub fn conversationBodyVisibleHeight(size: ziggy.Size) usize {
    return mainTopHeight(size) -| 2;
}

pub fn conversationVisibleHeightForSize(size: ziggy.Size) usize {
    return mainTopHeight(size) -| 2;
}

pub fn activityVisibleHeightForSize(size: ziggy.Size) usize {
    return mainTopHeight(size) -| 2;
}

pub fn conversationRect(size: ziggy.Size) ziggy.Rect {
    return .{
        .x = 0,
        .y = 0,
        .width = size.width,
        .height = @intCast(mainTopHeight(size)),
    };
}

pub fn conversationScrollbarRect(size: ziggy.Size) ziggy.Rect {
    const rect = conversationRect(size);
    return .{
        .x = rect.x +| rect.width -| 1,
        .y = rect.y + 1,
        .width = 1,
        .height = rect.height -| 2,
    };
}

pub fn conversationContentRect(size: ziggy.Size) ziggy.Rect {
    const rect = conversationRect(size);
    return .{
        .x = rect.x + 1,
        .y = rect.y + 1,
        .width = rect.width -| 3,
        .height = rect.height -| 2,
    };
}

pub fn activityRect(size: ziggy.Size) ziggy.Rect {
    return .{
        .x = size.width,
        .y = 0,
        .width = 0,
        .height = @intCast(mainTopHeight(size)),
    };
}

pub fn activityScrollbarRect(size: ziggy.Size) ziggy.Rect {
    const rect = activityRect(size);
    return .{
        .x = rect.x +| rect.width -| 1,
        .y = rect.y + 1,
        .width = 1,
        .height = rect.height -| 2,
    };
}

pub fn activityContentRect(size: ziggy.Size) ziggy.Rect {
    const rect = activityRect(size);
    return .{
        .x = rect.x + 1,
        .y = rect.y + 1,
        .width = rect.width -| 3,
        .height = rect.height -| 2,
    };
}

pub fn inputRect(size: ziggy.Size) ziggy.Rect {
    const top = mainTopHeight(size);
    const total_h = @as(usize, size.height);
    const input_y = @min(top + 1, total_h);
    const input_h = total_h -| input_y -| 1;
    return .{
        .x = 0,
        .y = @intCast(input_y),
        .width = size.width,
        .height = @intCast(input_h),
    };
}

pub fn inputContentRect(size: ziggy.Size) ziggy.Rect {
    const rect = inputRect(size);
    return .{
        .x = rect.x + 1,
        .y = rect.y + 1,
        .width = rect.width -| 2,
        .height = rect.height -| 2,
    };
}

pub fn detectTerminalSize() ziggy.Size {
    if (builtin.os.tag == .windows) {
        if (detectWindowsConsoleSize()) |size| return size;
    }
    return .{
        .width = @intCast(@max(parseDimensionEnv("COLUMNS", 100), 60)),
        .height = @intCast(@max(parseDimensionEnv("LINES", 28), 16)),
    };
}

fn detectWindowsConsoleSize() ?ziggy.Size {
    const windows = std.os.windows;
    const stdout_handle = std.fs.File.stdout().handle;

    var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (windows.kernel32.GetConsoleScreenBufferInfo(stdout_handle, &info) == 0) return null;

    const width_i32: i32 = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
    const height_i32: i32 = @as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1;
    if (width_i32 <= 0 or height_i32 <= 0) return null;

    return .{
        .width = @intCast(@max(width_i32, 60)),
        .height = @intCast(@max(height_i32, 16)),
    };
}

fn parseDimensionEnv(name: []const u8, fallback: usize) usize {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return fallback;
    defer std.heap.page_allocator.free(value);
    return std.fmt.parseInt(usize, value, 10) catch fallback;
}

test "pane content rects reserve room for borders and scrollbars" {
    const size: ziggy.Size = .{ .width = 120, .height = 40 };
    const conversation = conversationRect(size);
    const conversation_content = conversationContentRect(size);
    const conversation_scrollbar = conversationScrollbarRect(size);
    const activity = activityRect(size);
    const activity_content = activityContentRect(size);
    const activity_scrollbar = activityScrollbarRect(size);

    try std.testing.expect(conversation_content.width < conversation.width);
    try std.testing.expectEqual(conversation_scrollbar.x, conversation.x + conversation.width - 1);
    try std.testing.expectEqual(@as(u16, 0), activity.width);
    try std.testing.expectEqual(@as(u16, 0), activity_content.width);
    try std.testing.expectEqual(activity_scrollbar.x, activity.x + activity.width -| 1);
}

test "input content rect stays inside input rect" {
    const size: ziggy.Size = .{ .width = 100, .height = 28 };
    const rect = inputRect(size);
    const content = inputContentRect(size);
    try std.testing.expect(content.x >= rect.x);
    try std.testing.expect(content.y >= rect.y);
    try std.testing.expect(content.width <= rect.width);
    try std.testing.expect(content.height <= rect.height);
}
