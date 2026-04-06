const std = @import("std");

pub fn writeFileAbsolute(path: []const u8, content: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;

    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp-{d}", .{
        path,
        std.time.timestamp(),
    });
    defer std.heap.page_allocator.free(tmp_path);

    var tmp_file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
    defer tmp_file.close();

    var buf: [4096]u8 = undefined;
    var writer = tmp_file.writer(&buf);
    try writer.interface.writeAll(content);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try std.fs.renameAbsolute(tmp_path, path);
    _ = dir_path;
}
