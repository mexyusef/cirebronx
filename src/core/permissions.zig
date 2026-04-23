const std = @import("std");

pub const PermissionClass = enum {
    read,
    write,
    shell,
};

pub const PermissionMode = enum {
    allow,
    ask,
    deny,
};

pub const PermissionSet = struct {
    read: PermissionMode = .allow,
    write: PermissionMode = .allow,
    shell: PermissionMode = .allow,

    pub fn forClass(self: *const PermissionSet, class: PermissionClass) PermissionMode {
        return switch (class) {
            .read => self.read,
            .write => self.write,
            .shell => self.shell,
        };
    }

    pub fn setForClass(self: *PermissionSet, class: PermissionClass, mode: PermissionMode) void {
        switch (class) {
            .read => self.read = mode,
            .write => self.write = mode,
            .shell => self.shell = mode,
        }
    }
};

pub fn parsePermissionClass(name: []const u8) ?PermissionClass {
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "write")) return .write;
    if (std.mem.eql(u8, name, "shell")) return .shell;
    return null;
}

pub fn parsePermissionMode(name: []const u8) ?PermissionMode {
    if (std.mem.eql(u8, name, "allow")) return .allow;
    if (std.mem.eql(u8, name, "ask")) return .ask;
    if (std.mem.eql(u8, name, "deny")) return .deny;
    return null;
}

pub fn modeString(mode: PermissionMode) []const u8 {
    return switch (mode) {
        .allow => "allow",
        .ask => "ask",
        .deny => "deny",
    };
}

pub const PromptIo = struct {
    stdout: *std.Io.Writer,
    stdin: ?*std.Io.Reader,
    interactive: bool,
    approval: ?ApprovalHandler = null,
};

pub const ApprovalHandler = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque, *PermissionSet, PermissionClass, []const u8) anyerror!bool,
};

pub fn requestPermission(
    permissions: *PermissionSet,
    class: PermissionClass,
    summary: []const u8,
    io: PromptIo,
) !bool {
    const current = permissions.forClass(class);
    switch (current) {
        .allow => return true,
        .deny => return false,
        .ask => {
            if (io.approval) |approval| {
                return try approval.callback(approval.context, permissions, class, summary);
            }
            if (!io.interactive or io.stdin == null) return false;
            try io.stdout.print(
                "permission required for {s}: {s}\nAllow once? [y]es / [n]o / [a]lways / [d]eny always: ",
                .{ @tagName(class), summary },
            );
            try io.stdout.flush();
            const maybe_line = try io.stdin.?.takeDelimiter('\n');
            if (maybe_line == null) return false;
            const line = std.mem.trim(u8, maybe_line.?, " \r\t");
            if (line.len == 0) return false;

            switch (line[0]) {
                'y', 'Y' => return true,
                'a', 'A' => {
                    permissions.setForClass(class, .allow);
                    return true;
                },
                'd', 'D' => {
                    permissions.setForClass(class, .deny);
                    return false;
                },
                else => return false,
            }
        },
    }
}
