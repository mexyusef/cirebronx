const std = @import("std");

const App = @import("../core/app.zig").App;
const message = @import("../core/message.zig");
const permissions = @import("../core/permissions.zig");
const base = @import("base.zig");
const skills = @import("../skills/discovery.zig");

pub const ExecutionContext = struct {
    app: *App,
    io: permissions.PromptIo,
};

pub const ToolExecutionError = error{
    UnknownTool,
    PermissionDenied,
    InvalidArguments,
    PathOutsideWorkspace,
};

pub fn getAllTools() []const base.ToolSpec {
    return &.{
        .{
            .kind = .read_file,
            .name = "read_file",
            .description = "Read the contents of a file in the workspace.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path relative to the workspace or absolute.\"}},\"required\":[\"path\"]}",
            .permission = .read,
        },
        .{
            .kind = .list_files,
            .name = "list_files",
            .description = "List files in a directory.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory path.\"},\"recursive\":{\"type\":\"boolean\",\"description\":\"Whether to recurse into subdirectories.\"}},\"required\":[]}",
            .permission = .read,
        },
        .{
            .kind = .grep,
            .name = "grep",
            .description = "Search for a text pattern inside workspace files.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Text pattern to search for.\"},\"path\":{\"type\":\"string\",\"description\":\"Directory or file path.\"}},\"required\":[\"pattern\"]}",
            .permission = .read,
        },
        .{
            .kind = .list_skills,
            .name = "list_skills",
            .description = "List locally installed Codex skills.",
            .schema_json = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
            .permission = .read,
        },
        .{
            .kind = .git_status,
            .name = "git_status",
            .description = "Show git status for the current workspace.",
            .schema_json = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
            .permission = .read,
        },
        .{
            .kind = .git_worktree_list,
            .name = "git_worktree_list",
            .description = "List git worktrees for the current repository.",
            .schema_json = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
            .permission = .read,
        },
        .{
            .kind = .git_worktree_add,
            .name = "git_worktree_add",
            .description = "Create a new git worktree.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"branch\":{\"type\":\"string\"},\"create_branch\":{\"type\":\"boolean\"}},\"required\":[\"path\"]}",
            .permission = .write,
        },
        .{
            .kind = .shell_command,
            .name = "shell_command",
            .description = "Execute a shell command inside the workspace.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Shell command to execute.\"}},\"required\":[\"command\"]}",
            .permission = .shell,
        },
        .{
            .kind = .write_file,
            .name = "write_file",
            .description = "Write a file to disk, replacing its contents.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path.\"},\"content\":{\"type\":\"string\",\"description\":\"New file contents.\"}},\"required\":[\"path\",\"content\"]}",
            .permission = .write,
        },
        .{
            .kind = .edit_file,
            .name = "edit_file",
            .description = "Replace an exact text span inside a file.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path.\"},\"old_text\":{\"type\":\"string\",\"description\":\"Existing text to replace.\"},\"new_text\":{\"type\":\"string\",\"description\":\"Replacement text.\"}},\"required\":[\"path\",\"old_text\",\"new_text\"]}",
            .permission = .write,
        },
        .{
            .kind = .create_task_note,
            .name = "create_task_note",
            .description = "Create a task markdown note in the workspace tasks directory.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"name\"]}",
            .permission = .write,
        },
    };
}

pub fn toolsForExposure(app: *App) []const base.ToolSpec {
    const all = getAllTools();
    var count: usize = 0;
    for (all) |tool| {
        if (app.permissions.forClass(tool.permission) != .deny) count += 1;
    }

    const arena = app.arena.allocator();
    const visible = arena.alloc(base.ToolSpec, count) catch return &.{};
    var idx: usize = 0;
    for (all) |tool| {
        if (app.permissions.forClass(tool.permission) == .deny) continue;
        visible[idx] = tool;
        idx += 1;
    }
    return visible;
}

pub fn findTool(name: []const u8) ?base.ToolSpec {
    for (getAllTools()) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

pub fn executeTool(
    allocator: std.mem.Allocator,
    ctx: ExecutionContext,
    call: message.ToolCall,
) ![]u8 {
    const tool = findTool(call.name) orelse return ToolExecutionError.UnknownTool;
    const allowed = try permissions.requestPermission(
        &ctx.app.permissions,
        tool.permission,
        call.name,
        ctx.io,
    );
    if (!allowed) return ToolExecutionError.PermissionDenied;

    return switch (tool.kind) {
        .read_file => try executeReadFile(allocator, ctx.app, call.arguments),
        .list_files => try executeListFiles(allocator, ctx.app, call.arguments),
        .grep => try executeGrep(allocator, ctx.app, call.arguments),
        .list_skills => try executeListSkills(allocator),
        .git_status => try executeGitStatus(allocator, ctx.app),
        .git_worktree_list => try executeGitWorktreeList(allocator, ctx.app),
        .git_worktree_add => try executeGitWorktreeAdd(allocator, ctx.app, call.arguments),
        .shell_command => try executeShellCommand(allocator, ctx.app, call.arguments),
        .write_file => try executeWriteFile(allocator, ctx.app, call.arguments),
        .edit_file => try executeEditFile(allocator, ctx.app, call.arguments),
        .create_task_note => try executeCreateTaskNote(allocator, ctx.app, call.arguments),
    };
}

fn resolveWorkspacePath(allocator: std.mem.Allocator, app: *App, path: []const u8) ![]u8 {
    const candidate = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ app.cwd, path });
    errdefer allocator.free(candidate);

    const resolved = try std.fs.path.resolve(allocator, &.{candidate});
    allocator.free(candidate);

    if (!std.mem.startsWith(u8, resolved, app.cwd)) {
        allocator.free(resolved);
        return ToolExecutionError.PathOutsideWorkspace;
    }
    return resolved;
}

fn executeReadFile(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct { path: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{});
    defer parsed.deinit();
    const path = try resolveWorkspacePath(allocator, app, parsed.value.path);
    defer allocator.free(path);
    return try readFileAbsoluteAlloc(allocator, path, 256 * 1024);
}

fn executeListFiles(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct {
        path: []const u8 = ".",
        recursive: bool = true,
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const path = try resolveWorkspacePath(allocator, app, parsed.value.path);
    defer allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    if (parsed.value.recursive) {
        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        var count: usize = 0;
        while (try walker.next()) |entry| {
            try out.writer.print("{s} [{s}]\n", .{ entry.path, @tagName(entry.kind) });
            count += 1;
            if (count >= 200) break;
        }
    } else {
        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            try out.writer.print("{s} [{s}]\n", .{ entry.name, @tagName(entry.kind) });
        }
    }

    return out.toOwnedSlice();
}

fn executeGrep(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct {
        pattern: []const u8,
        path: []const u8 = ".",
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{});
    defer parsed.deinit();

    const path = try resolveWorkspacePath(allocator, app, parsed.value.path);
    defer allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var matches: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const file_path = try std.fs.path.join(allocator, &.{ path, entry.path });
        defer allocator.free(file_path);

        const content = readFileAbsoluteAlloc(allocator, file_path, 128 * 1024) catch continue;
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (std.mem.indexOf(u8, line, parsed.value.pattern) != null) {
                try out.writer.print("{s}:{d}: {s}\n", .{ entry.path, line_no, line });
                matches += 1;
                if (matches >= 100) break;
            }
        }
        if (matches >= 100) break;
    }

    return out.toOwnedSlice();
}

fn executeShellCommand(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct { command: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{});
    defer parsed.deinit();

    const argv = if (@import("builtin").os.tag == .windows)
        &.{ "powershell", "-NoProfile", "-Command", parsed.value.command }
    else
        &.{ "sh", "-lc", parsed.value.command };

    return try runCommand(allocator, app.cwd, argv);
}

fn executeWriteFile(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{});
    defer parsed.deinit();

    const path = try resolveWorkspacePath(allocator, app, parsed.value.path);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    try writeFileAbsolute(path, parsed.value.content);

    return try allocator.dupe(u8, "file written");
}

fn executeEditFile(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct {
        path: []const u8,
        old_text: []const u8,
        new_text: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{});
    defer parsed.deinit();

    const path = try resolveWorkspacePath(allocator, app, parsed.value.path);
    defer allocator.free(path);

    const content = try readFileAbsoluteAlloc(allocator, path, 256 * 1024);
    defer allocator.free(content);

    const match_index = std.mem.indexOf(u8, content, parsed.value.old_text) orelse return ToolExecutionError.InvalidArguments;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(content[0..match_index]);
    try out.writer.writeAll(parsed.value.new_text);
    try out.writer.writeAll(content[match_index + parsed.value.old_text.len ..]);
    const new_content = try out.toOwnedSlice();
    defer allocator.free(new_content);

    try writeFileAbsolute(path, new_content);

    return try allocator.dupe(u8, "file edited");
}

fn executeListSkills(allocator: std.mem.Allocator) ![]u8 {
    const found = try skills.discover(allocator);
    defer {
        for (found) |*skill| skill.deinit(allocator);
        allocator.free(found);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (found) |skill| {
        try out.writer.print("{s}: {s}\n{s}\n\n", .{ skill.name, skill.path, skill.summary });
    }
    return out.toOwnedSlice();
}

fn executeGitStatus(allocator: std.mem.Allocator, app: *App) ![]u8 {
    return try runCommand(allocator, app.cwd, &.{ "git", "status", "--short", "--branch" });
}

fn executeGitWorktreeList(allocator: std.mem.Allocator, app: *App) ![]u8 {
    return try runCommand(allocator, app.cwd, &.{ "git", "worktree", "list", "--porcelain" });
}

fn executeGitWorktreeAdd(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct {
        path: []const u8,
        branch: ?[]const u8 = null,
        create_branch: bool = false,
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const full_path = if (std.fs.path.isAbsolute(parsed.value.path))
        try allocator.dupe(u8, parsed.value.path)
    else
        try std.fs.path.join(allocator, &.{ app.cwd, parsed.value.path });
    defer allocator.free(full_path);

    if (parsed.value.branch) |branch| {
        if (parsed.value.create_branch) {
            return try runCommand(allocator, app.cwd, &.{ "git", "worktree", "add", "-b", branch, full_path });
        }
        return try runCommand(allocator, app.cwd, &.{ "git", "worktree", "add", full_path, branch });
    }
    return try runCommand(allocator, app.cwd, &.{ "git", "worktree", "add", full_path });
}

fn executeCreateTaskNote(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct {
        name: []const u8,
        content: []const u8 = "",
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const slug = try slugify(allocator, parsed.value.name);
    defer allocator.free(slug);
    const tasks_dir = try std.fs.path.join(allocator, &.{ app.cwd, "tasks" });
    defer allocator.free(tasks_dir);
    std.fs.makeDirAbsolute(tasks_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{slug});
    defer allocator.free(file_name);
    const file_path = try std.fs.path.join(allocator, &.{ tasks_dir, file_name });
    defer allocator.free(file_path);

    const content = try std.fmt.allocPrint(
        allocator,
        "# {s}\n\n{s}\n",
        .{ parsed.value.name, parsed.value.content },
    );
    defer allocator.free(content);

    try writeFileAbsolute(file_path, content);
    return try std.fmt.allocPrint(allocator, "task note created: {s}", .{file_path});
}

fn readFileAbsoluteAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: usize,
) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, limit);
}

fn writeFileAbsolute(path: []const u8, content: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

fn runCommand(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 128 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("exit: {s}\n", .{terminationString(result.term)});
    if (result.stdout.len > 0) {
        try out.writer.writeAll("stdout:\n");
        try out.writer.writeAll(result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') try out.writer.writeByte('\n');
    }
    if (result.stderr.len > 0) {
        try out.writer.writeAll("stderr:\n");
        try out.writer.writeAll(result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn terminationString(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .Exited => "exited",
        .Signal => "signal",
        .Stopped => "stopped",
        .Unknown => "unknown",
    };
}

fn slugify(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var last_dash = false;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(allocator, std.ascii.toLower(c));
            last_dash = false;
        } else if (!last_dash) {
            try out.append(allocator, '-');
            last_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "task");
    return try out.toOwnedSlice(allocator);
}
