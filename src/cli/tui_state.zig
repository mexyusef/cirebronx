const std = @import("std");

pub const PromptHistory = struct {
    items: std.ArrayList([]u8) = .empty,
    browse_index: ?usize = null,
    draft: ?[]u8 = null,

    pub fn deinit(self: *PromptHistory, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| allocator.free(item);
        self.items.deinit(allocator);
        if (self.draft) |draft| allocator.free(draft);
    }

    pub fn push(self: *PromptHistory, allocator: std.mem.Allocator, value: []const u8) !void {
        if (value.len == 0) return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], value)) {
            self.resetBrowse(allocator);
            return;
        }
        try self.items.append(allocator, try allocator.dupe(u8, value));
        while (self.items.items.len > 200) {
            const removed = self.items.orderedRemove(0);
            allocator.free(removed);
        }
        self.resetBrowse(allocator);
    }

    pub fn replaceAll(self: *PromptHistory, allocator: std.mem.Allocator, values: []const []u8) !void {
        self.deinit(allocator);
        self.* = .{};
        for (values) |value| {
            try self.items.append(allocator, try allocator.dupe(u8, value));
        }
    }

    pub fn resetBrowse(self: *PromptHistory, allocator: std.mem.Allocator) void {
        self.browse_index = null;
        if (self.draft) |draft| allocator.free(draft);
        self.draft = null;
    }
};

pub const ModalState = struct {
    pub const Kind = enum {
        generic,
        help,
    };

    title: ?[]u8 = null,
    body: ?[]u8 = null,
    kind: Kind = .generic,
    scroll: usize = 0,

    pub fn deinit(self: *ModalState, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.body) |body| allocator.free(body);
    }

    pub fn isOpen(self: *const ModalState) bool {
        return self.title != null and self.body != null;
    }

    pub fn close(self: *ModalState, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.title = null;
        self.body = null;
        self.kind = .generic;
        self.scroll = 0;
    }

    pub fn open(self: *ModalState, allocator: std.mem.Allocator, title: []const u8, body: []const u8) !void {
        self.close(allocator);
        self.title = try allocator.dupe(u8, title);
        self.body = try allocator.dupe(u8, body);
        self.kind = .generic;
        self.scroll = 0;
    }

    pub fn openWithKind(self: *ModalState, allocator: std.mem.Allocator, title: []const u8, body: []const u8, kind: Kind) !void {
        try self.open(allocator, title, body);
        self.kind = kind;
    }
};

pub const Item = struct {
    label: []u8,
    body: []u8,
    reuse: ?[]u8 = null,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.body);
        if (self.reuse) |reuse| allocator.free(reuse);
    }
};

pub const ActionLog = struct {
    items: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *ActionLog, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| allocator.free(item);
        self.items.deinit(allocator);
    }

    pub fn append(self: *ActionLog, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.items.append(allocator, try allocator.dupe(u8, text));
        if (self.items.items.len > 8) {
            const removed = self.items.orderedRemove(0);
            allocator.free(removed);
        }
    }
};
