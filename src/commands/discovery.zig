const std = @import("std");

pub const CommandInfo = struct {
    name: []u8,
    path: []u8,
    summary: []u8,
    source: []u8,

    pub fn deinit(self: *CommandInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.summary);
        allocator.free(self.source);
    }
};

pub const LoadedCommand = struct {
    info: CommandInfo,
    body: []u8,

    pub fn deinit(self: *LoadedCommand, allocator: std.mem.Allocator) void {
        self.info.deinit(allocator);
        allocator.free(self.body);
    }
};

const Root = struct {
    path: []u8,
    label: []const u8,
};

pub fn discover(allocator: std.mem.Allocator) ![]CommandInfo {
    var list: std.ArrayList(CommandInfo) = .empty;
    defer list.deinit(allocator);

    const roots = try discoverRoots(allocator);
    defer freeRoots(allocator, roots);

    for (roots) |root| {
        var dir = std.fs.openDirAbsolute(root.path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!isCommandFile(entry.path)) continue;

            const full_path = try std.fs.path.join(allocator, &.{ root.path, entry.path });
            errdefer allocator.free(full_path);
            if (containsCommand(list.items, full_path)) {
                allocator.free(full_path);
                continue;
            }

            const content = readFileAlloc(allocator, full_path, 64 * 1024) catch {
                allocator.free(full_path);
                continue;
            };
            defer allocator.free(content);
            const parsed = parseCommandFile(content);

            try list.append(allocator, .{
                .name = try buildCommandName(allocator, entry.path),
                .path = full_path,
                .summary = try allocator.dupe(u8, parsed.summary),
                .source = try allocator.dupe(u8, root.label),
            });
        }
    }

    return try list.toOwnedSlice(allocator);
}

pub fn loadByName(allocator: std.mem.Allocator, requested: []const u8) !?LoadedCommand {
    const normalized = std.mem.trimLeft(u8, requested, "/");
    const found = try discover(allocator);
    defer {
        for (found) |*command| command.deinit(allocator);
        allocator.free(found);
    }

    for (found) |command| {
        if (!std.mem.eql(u8, command.name, normalized)) continue;
        const content = try readFileAlloc(allocator, command.path, 256 * 1024);
        errdefer allocator.free(content);
        const parsed = parseCommandFile(content);
        const loaded = LoadedCommand{
            .info = .{
                .name = try allocator.dupe(u8, command.name),
                .path = try allocator.dupe(u8, command.path),
                .summary = try allocator.dupe(u8, command.summary),
                .source = try allocator.dupe(u8, command.source),
            },
            .body = try allocator.dupe(u8, parsed.body),
        };
        allocator.free(content);
        return loaded;
    }

    return null;
}

pub fn renderPrompt(allocator: std.mem.Allocator, body: []const u8, arguments: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < body.len) {
        if (std.mem.startsWith(u8, body[cursor..], "$ARGUMENTS")) {
            try out.appendSlice(allocator, arguments);
            cursor += "$ARGUMENTS".len;
            continue;
        }
        if (std.mem.startsWith(u8, body[cursor..], "{{ARGUMENTS}}")) {
            try out.appendSlice(allocator, arguments);
            cursor += "{{ARGUMENTS}}".len;
            continue;
        }
        try out.append(allocator, body[cursor]);
        cursor += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn discoverRoots(allocator: std.mem.Allocator) ![]Root {
    var roots: std.ArrayList(Root) = .empty;
    defer roots.deinit(allocator);

    if (try homeCandidate(allocator)) |home| {
        defer allocator.free(home);
        try appendRoot(allocator, &roots, try std.fs.path.join(allocator, &.{ home, ".codex", "commands" }), "~/.codex");
        try appendRoot(allocator, &roots, try std.fs.path.join(allocator, &.{ home, ".claude", "commands" }), "~/.claude");
    }

    if (try cwdCandidate(allocator)) |cwd| {
        defer allocator.free(cwd);
        try appendRoot(allocator, &roots, try std.fs.path.join(allocator, &.{ cwd, ".codex", "commands" }), "./.codex");
        try appendRoot(allocator, &roots, try std.fs.path.join(allocator, &.{ cwd, ".claude", "commands" }), "./.claude");
    }

    return try roots.toOwnedSlice(allocator);
}

fn appendRoot(
    allocator: std.mem.Allocator,
    roots: *std.ArrayList(Root),
    root_path: []u8,
    label: []const u8,
) !void {
    errdefer allocator.free(root_path);
    for (roots.items) |existing| {
        if (std.mem.eql(u8, existing.path, root_path)) {
            allocator.free(root_path);
            return;
        }
    }
    try roots.append(allocator, .{
        .path = root_path,
        .label = label,
    });
}

fn freeRoots(allocator: std.mem.Allocator, roots: []Root) void {
    for (roots) |root| allocator.free(root.path);
    allocator.free(roots);
}

fn homeCandidate(allocator: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |profile| {
        return profile;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        return home;
    } else |_| {}
    return null;
}

fn cwdCandidate(allocator: std.mem.Allocator) !?[]u8 {
    return std.fs.cwd().realpathAlloc(allocator, ".") catch null;
}

fn containsCommand(found: []const CommandInfo, path: []const u8) bool {
    for (found) |command| {
        if (std.mem.eql(u8, command.path, path)) return true;
    }
    return false;
}

fn isCommandFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".txt") or std.mem.eql(u8, ext, ".prompt");
}

fn buildCommandName(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const ext = std.fs.path.extension(path);
    const stem = path[0 .. path.len - ext.len];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (stem) |char| {
        try out.append(allocator, if (char == '\\') '/' else char);
    }
    return try out.toOwnedSlice(allocator);
}

const ParsedCommandFile = struct {
    summary: []const u8,
    body: []const u8,
};

fn parseCommandFile(content: []const u8) ParsedCommandFile {
    const split = splitFrontmatter(content);
    const description = extractFrontmatterValue(split.frontmatter, "description");
    const summary = if (description.len > 0) description else extractSummary(split.body);
    return .{
        .summary = summary,
        .body = std.mem.trim(u8, split.body, "\r\n"),
    };
}

const FrontmatterSplit = struct {
    frontmatter: []const u8,
    body: []const u8,
};

fn splitFrontmatter(content: []const u8) FrontmatterSplit {
    const prefix_len = if (std.mem.startsWith(u8, content, "---\r\n"))
        "---\r\n".len
    else if (std.mem.startsWith(u8, content, "---\n"))
        "---\n".len
    else
        0;
    if (prefix_len == 0) {
        return .{ .frontmatter = "", .body = content };
    }
    const rest = content[prefix_len..];
    const end_marker = if (std.mem.indexOf(u8, rest, "\r\n---\r\n") != null)
        "\r\n---\r\n"
    else if (std.mem.indexOf(u8, rest, "\n---\n") != null)
        "\n---\n"
    else
        return .{ .frontmatter = "", .body = content };
    const end = std.mem.indexOf(u8, rest, end_marker).?;
    return .{
        .frontmatter = rest[0..end],
        .body = rest[end + end_marker.len ..],
    };
}

fn extractFrontmatterValue(frontmatter: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        if (trimmed.len <= key.len or trimmed[key.len] != ':') continue;
        return std.mem.trim(u8, trimmed[key.len + 1 ..], " \r\t\"'");
    }
    return "";
}

fn extractSummary(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t#-");
        if (trimmed.len == 0) continue;
        return trimmed;
    }
    return "";
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, limit);
}

test "buildCommandName keeps nested command paths" {
    const name = try buildCommandName(std.testing.allocator, "blog\\idea.md");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("blog/idea", name);
}

test "extractSummary skips markdown markers" {
    const summary = extractSummary(
        \\# Bootstrap
        \\
        \\Create a starter project plan.
    );
    try std.testing.expectEqualStrings("Bootstrap", summary);
}

test "parseCommandFile prefers frontmatter description and strips header" {
    const parsed = parseCommandFile(
        \\---
        \\description: Bootstrap project
        \\argument-hint: <idea>
        \\---
        \\
        \\# Bootstrap
        \\Use $ARGUMENTS here.
    );
    try std.testing.expectEqualStrings("Bootstrap project", parsed.summary);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "Use $ARGUMENTS here.") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "description:") == null);
}

test "parseCommandFile supports CRLF frontmatter" {
    const parsed = parseCommandFile(
        "---\r\n" ++
        "description: Django backend API helper\r\n" ++
        "allowed-tools: SlashCommand, Bash\r\n" ++
        "---\r\n" ++
        "\r\n" ++
        "# Build API\r\n" ++
        "Do the work.\r\n"
    );
    try std.testing.expectEqualStrings("Django backend API helper", parsed.summary);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "Do the work.") != null);
}

test "renderPrompt replaces argument placeholders" {
    const rendered = try renderPrompt(std.testing.allocator, "hello $ARGUMENTS and {{ARGUMENTS}}", "world");
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("hello world and world", rendered);
}
