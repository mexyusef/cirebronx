const std = @import("std");

pub fn makeSessionId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&bytes, .lower)});
}
