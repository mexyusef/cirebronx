const std = @import("std");

const RefreshMs = 15 * std.time.ms_per_s;

const KeyRecord = struct {
    key: ?[]const u8 = null,
    is_valid: ?bool = null,
    disabled: ?bool = null,
};

const PoolState = struct {
    keys: std.ArrayList([]u8) = .empty,
    loaded_at_ms: i64 = 0,
    next_index: usize = 0,
};

var state = PoolState{};

pub fn deinitGlobal(allocator: std.mem.Allocator) void {
    for (state.keys.items) |key| allocator.free(key);
    state.keys.deinit(allocator);
    state = .{};
}

pub fn hasPoolFile(allocator: std.mem.Allocator) bool {
    const keys = loadKeys(allocator) catch return false;
    defer freeKeys(allocator, keys);
    return keys.len > 0;
}

pub fn firstKey(allocator: std.mem.Allocator) !?[]u8 {
    const keys = try loadKeys(allocator);
    defer freeKeys(allocator, keys);
    if (keys.len == 0) return null;
    return try allocator.dupe(u8, keys[0]);
}

pub fn nextKey(allocator: std.mem.Allocator) !?[]u8 {
    const now_ms = std.time.milliTimestamp();
    const should_reload = state.loaded_at_ms == 0 or now_ms - state.loaded_at_ms >= RefreshMs;
    if (should_reload) {
        reloadState(allocator) catch return null;
    }
    if (state.keys.items.len == 0) return null;

    const key = state.keys.items[state.next_index % state.keys.items.len];
    state.next_index = (state.next_index + 1) % state.keys.items.len;
    return try allocator.dupe(u8, key);
}

pub fn defaultBaseUrl(allocator: std.mem.Allocator) !?[]u8 {
    if (!hasPoolFile(allocator)) return null;
    return try allocator.dupe(u8, "https://openrouter.ai/api/v1/chat/completions");
}

pub fn keyCount(allocator: std.mem.Allocator) usize {
    const keys = loadKeys(allocator) catch return 0;
    defer freeKeys(allocator, keys);
    return keys.len;
}

fn reloadState(allocator: std.mem.Allocator) !void {
    for (state.keys.items) |key| allocator.free(key);
    state.keys.clearRetainingCapacity();

    const keys = try loadKeys(allocator);
    defer freeKeys(allocator, keys);
    for (keys) |key| {
        try state.keys.append(allocator, try allocator.dupe(u8, key));
    }

    state.loaded_at_ms = std.time.milliTimestamp();
    if (state.next_index >= state.keys.items.len) state.next_index = 0;
}

fn loadKeys(allocator: std.mem.Allocator) ![][]u8 {
    const path = try poolPath(allocator);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        return allocator.alloc([]u8, 0);
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return allocator.alloc([]u8, 0);
    };
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice([]KeyRecord, allocator, contents, .{
        .ignore_unknown_fields = true,
    }) catch {
        return allocator.alloc([]u8, 0);
    };
    defer parsed.deinit();

    var keys = std.ArrayList([]u8).empty;
    errdefer freeKeys(allocator, keys.items);

    for (parsed.value) |record| {
        if (record.is_valid) |valid| {
            if (!valid) continue;
        }
        if (record.disabled) |disabled| {
            if (disabled) continue;
        }
        const raw = record.key orelse continue;
        const trimmed = std.mem.trim(u8, raw, " \r\n\t");
        if (trimmed.len == 0) continue;
        try keys.append(allocator, try allocator.dupe(u8, trimmed));
    }
    return try keys.toOwnedSlice(allocator);
}

fn freeKeys(allocator: std.mem.Allocator, keys: []const []u8) void {
    for (keys) |key| allocator.free(key);
    allocator.free(keys);
}

fn poolPath(allocator: std.mem.Allocator) ![]u8 {
    const explicit = std.process.getEnvVarOwned(allocator, "OPENROUTER_KEY_POOL_FILE") catch null;
    if (explicit) |path| {
        if (path.len > 0) return path;
        allocator.free(path);
    }

    const userprofile = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch null;
    if (userprofile) |home| {
        defer allocator.free(home);
        if (home.len > 0) return std.fmt.allocPrint(allocator, "{s}\\OPENROUTER_API_KEYS.json", .{home});
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    if (home) |base| {
        defer allocator.free(base);
        if (base.len > 0) return std.fmt.allocPrint(allocator, "{s}/OPENROUTER_API_KEYS.json", .{base});
    }

    return allocator.dupe(u8, "C:\\Users\\usef\\OPENROUTER_API_KEYS.json");
}
