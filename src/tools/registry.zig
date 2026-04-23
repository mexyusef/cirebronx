const std = @import("std");

const App = @import("../core/app.zig").App;
const message = @import("../core/message.zig");
const permissions = @import("../core/permissions.zig");
const base = @import("base.zig");
const skills = @import("../skills/discovery.zig");

const MAX_READ_SIZE: usize = 1024 * 1024;
const MAX_WRITE_SIZE: usize = 1024 * 1024;

pub const ExecutionContext = struct {
    app: *App,
    io: permissions.PromptIo,
};

pub const ToolExecutionError = error{
    UnknownTool,
    PermissionDenied,
    InvalidArguments,
    PathOutsideWorkspace,
    BinaryFile,
    FileTooLarge,
    UnsupportedUrl,
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
            .kind = .rg_search,
            .name = "rg",
            .description = "Search workspace files with ripgrep. Prefer this for fast repo-wide code search, especially on Windows.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Ripgrep pattern to search for.\"},\"path\":{\"type\":\"string\",\"description\":\"Directory or file path.\"},\"glob\":{\"type\":\"string\",\"description\":\"Optional glob filter like *.zig.\"},\"case_sensitive\":{\"type\":\"boolean\",\"description\":\"Whether the search should be case-sensitive.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum number of matching lines to return.\"}},\"required\":[\"pattern\"]}",
            .permission = .read,
        },
        .{
            .kind = .glob_search,
            .name = "glob_search",
            .description = "Find files matching a glob pattern inside the workspace.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Glob pattern like **/*.zig or src/**/test_*.py.\"},\"path\":{\"type\":\"string\",\"description\":\"Base directory to search from.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum number of matches.\"}},\"required\":[\"pattern\"]}",
            .permission = .read,
        },
        .{
            .kind = .web_fetch,
            .name = "web_fetch",
            .description = "Fetch a web page or text resource and return a readable text summary.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"HTTP or HTTPS URL to fetch.\"}},\"required\":[\"url\"]}",
            .permission = .read,
        },
        .{
            .kind = .web_search,
            .name = "web_search",
            .description = "Search the web and return concise top results.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum number of results to return.\"}},\"required\":[\"query\"]}",
            .permission = .read,
        },
        .{
            .kind = .list_skills,
            .name = "list_skills",
            .description = "List discovered skills from .codex/.claude roots.",
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
            .kind = .shell_command,
            .name = "bash",
            .description = "Execute a shell command inside the workspace. Uses PowerShell on Windows and sh on POSIX.",
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
            .kind = .apply_patch,
            .name = "apply_patch",
            .description = "Apply multiple exact text replacements to a file in one tool call.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path.\"},\"edits\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"old_text\":{\"type\":\"string\"},\"new_text\":{\"type\":\"string\"}},\"required\":[\"old_text\",\"new_text\"]}}},\"required\":[\"path\",\"edits\"]}",
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
        .rg_search => try executeRgSearch(allocator, ctx.app, call.arguments),
        .glob_search => try executeGlobSearch(allocator, ctx.app, call.arguments),
        .web_fetch => try executeWebFetch(allocator, call.arguments),
        .web_search => try executeWebSearch(allocator, call.arguments),
        .list_skills => try executeListSkills(allocator),
        .git_status => try executeGitStatus(allocator, ctx.app),
        .git_worktree_list => try executeGitWorktreeList(allocator, ctx.app),
        .git_worktree_add => try executeGitWorktreeAdd(allocator, ctx.app, call.arguments),
        .shell_command => try executeShellCommand(allocator, ctx.app, call.arguments),
        .write_file => try executeWriteFile(allocator, ctx.app, call.arguments),
        .edit_file => try executeEditFile(allocator, ctx.app, call.arguments),
        .apply_patch => try executeApplyPatch(allocator, ctx.app, call.arguments),
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

    const real = std.fs.realpathAlloc(allocator, resolved) catch null;
    if (real) |resolved_real| {
        defer allocator.free(resolved_real);
        if (!std.mem.startsWith(u8, resolved_real, app.cwd)) {
            allocator.free(resolved);
            return ToolExecutionError.PathOutsideWorkspace;
        }
    }
    return resolved;
}

fn executeReadFile(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct { path: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{});
    defer parsed.deinit();
    const path = try resolveWorkspacePath(allocator, app, parsed.value.path);
    defer allocator.free(path);
    return try readFileAbsoluteAlloc(allocator, path, MAX_READ_SIZE);
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

fn executeRgSearch(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct {
        pattern: []const u8,
        path: []const u8 = ".",
        glob: ?[]const u8 = null,
        case_sensitive: bool = false,
        limit: usize = 100,
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const path = try resolveWorkspacePath(allocator, app, parsed.value.path);
    defer allocator.free(path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{
        "rg",
        "--line-number",
        "--color",
        "never",
        "--hidden",
        "--max-count",
    });
    const limit_text = try std.fmt.allocPrint(allocator, "{d}", .{@min(parsed.value.limit, 500)});
    defer allocator.free(limit_text);
    try argv.append(allocator, limit_text);
    if (!parsed.value.case_sensitive) try argv.append(allocator, "--smart-case");
    if (parsed.value.glob) |glob| {
        try argv.appendSlice(allocator, &.{ "--glob", glob });
    }
    try argv.appendSlice(allocator, &.{ parsed.value.pattern, path });
    const argv_items = try argv.toOwnedSlice(allocator);
    defer allocator.free(argv_items);

    return try runCommand(allocator, app.cwd, argv_items);
}

fn executeGlobSearch(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Args = struct {
        pattern: []const u8,
        path: []const u8 = ".",
        limit: usize = 200,
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const path = try resolveWorkspacePath(allocator, app, parsed.value.path);
    defer allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    const limit = @min(parsed.value.limit, 500);
    var count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!globMatch(parsed.value.pattern, entry.path)) continue;
        try out.writer.print("{s}\n", .{entry.path});
        count += 1;
        if (count >= limit) break;
    }

    return out.toOwnedSlice();
}

fn executeWebFetch(allocator: std.mem.Allocator, raw_args: []const u8) ![]u8 {
    const Args = struct { url: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{});
    defer parsed.deinit();

    try ensureHttpUrl(parsed.value.url);
    const body = try httpGetAlloc(allocator, parsed.value.url, 256 * 1024);
    defer allocator.free(body);

    const rendered = if (looksLikeHtml(body))
        try stripHtmlToText(allocator, body)
    else
        try allocator.dupe(u8, std.mem.trim(u8, body, " \r\n\t"));
    defer allocator.free(rendered);

    return try std.fmt.allocPrint(allocator, "url: {s}\n\n{s}", .{
        parsed.value.url,
        previewText(rendered, 4000),
    });
}

fn executeWebSearch(allocator: std.mem.Allocator, raw_args: []const u8) ![]u8 {
    const Args = struct {
        query: []const u8,
        limit: usize = 5,
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const encoded = try urlEncodeComponent(allocator, parsed.value.query);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(
        allocator,
        "https://www.bing.com/search?format=rss&q={s}",
        .{encoded},
    );
    defer allocator.free(url);

    const body = try httpGetAlloc(allocator, url, 512 * 1024);
    defer allocator.free(body);
    return try summarizeBingRssResults(allocator, body, parsed.value.query, @min(parsed.value.limit, 8));
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

    if (parsed.value.content.len > MAX_WRITE_SIZE) return ToolExecutionError.FileTooLarge;

    if (std.fs.path.dirname(path)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    try writeFileAbsolute(path, parsed.value.content);

    return try std.fmt.allocPrint(allocator, "file written: {s} ({d} bytes)", .{
        parsed.value.path,
        parsed.value.content.len,
    });
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

    const content = try readFileAbsoluteAlloc(allocator, path, MAX_READ_SIZE);
    defer allocator.free(content);

    const match_index = std.mem.indexOf(u8, content, parsed.value.old_text) orelse return ToolExecutionError.InvalidArguments;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(content[0..match_index]);
    try out.writer.writeAll(parsed.value.new_text);
    try out.writer.writeAll(content[match_index + parsed.value.old_text.len ..]);
    const new_content = try out.toOwnedSlice();
    defer allocator.free(new_content);

    if (new_content.len > MAX_WRITE_SIZE) return ToolExecutionError.FileTooLarge;

    try writeFileAbsolute(path, new_content);

    return try std.fmt.allocPrint(allocator, "file edited: {s} (replaced {d} bytes with {d} bytes)", .{
        parsed.value.path,
        parsed.value.old_text.len,
        parsed.value.new_text.len,
    });
}

fn executeApplyPatch(allocator: std.mem.Allocator, app: *App, raw_args: []const u8) ![]u8 {
    const Edit = struct {
        old_text: []const u8,
        new_text: []const u8,
    };
    const Args = struct {
        path: []const u8,
        edits: []const Edit,
    };
    const parsed = try std.json.parseFromSlice(Args, allocator, raw_args, .{});
    defer parsed.deinit();

    const path = try resolveWorkspacePath(allocator, app, parsed.value.path);
    defer allocator.free(path);

    const content = try readFileAbsoluteAlloc(allocator, path, MAX_READ_SIZE);
    defer allocator.free(content);

    var owned = try allocator.dupe(u8, content);
    defer allocator.free(owned);
    var replacements: usize = 0;

    for (parsed.value.edits) |edit| {
        const match_index = std.mem.indexOf(u8, owned, edit.old_text) orelse return ToolExecutionError.InvalidArguments;
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll(owned[0..match_index]);
        try out.writer.writeAll(edit.new_text);
        try out.writer.writeAll(owned[match_index + edit.old_text.len ..]);
        const new_owned = try out.toOwnedSlice();
        allocator.free(owned);
        owned = new_owned;
        replacements += 1;
    }

    if (owned.len > MAX_WRITE_SIZE) return ToolExecutionError.FileTooLarge;
    try writeFileAbsolute(path, owned);
    return try std.fmt.allocPrint(allocator, "patch applied: {s} ({d} edits)", .{
        parsed.value.path,
        replacements,
    });
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
        try out.writer.print("{s} [{s}]: {s}\n{s}\n\n", .{ skill.name, skill.source, skill.path, skill.summary });
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
    const stat = try file.stat();
    if (stat.size > limit) return ToolExecutionError.FileTooLarge;
    const content = try file.readToEndAlloc(allocator, limit);
    errdefer allocator.free(content);
    if (appearsBinary(content)) return ToolExecutionError.BinaryFile;
    return content;
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

fn httpGetAlloc(
    allocator: std.mem.Allocator,
    url: []const u8,
    max_bytes: usize,
) ![]u8 {
    const result = if (@import("builtin").os.tag == .windows) blk: {
        const escaped_url = try std.mem.replaceOwned(u8, allocator, url, "'", "''");
        defer allocator.free(escaped_url);
        const script = try std.fmt.allocPrint(
            allocator,
            "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::UTF8; (Invoke-WebRequest -UseBasicParsing -Uri '{s}' -Headers @{{'User-Agent'='cirebronx/0.1.0'}}).Content",
            .{escaped_url},
        );
        defer allocator.free(script);
        break :blk try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "powershell", "-NoProfile", "-Command", script },
            .max_output_bytes = max_bytes,
        });
    } else try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "-LfsS",
            "--max-time",
            "20",
            "-H",
            "user-agent: cirebronx/0.1.0",
            url,
        },
        .max_output_bytes = max_bytes,
    });
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        defer allocator.free(result.stdout);
        return ToolExecutionError.InvalidArguments;
    }
    return result.stdout;
}

fn ensureHttpUrl(url: []const u8) !void {
    if (std.mem.startsWith(u8, url, "http://")) return;
    if (std.mem.startsWith(u8, url, "https://")) return;
    return ToolExecutionError.UnsupportedUrl;
}

fn looksLikeHtml(body: []const u8) bool {
    const probe = body[0..@min(body.len, 2048)];
    return std.mem.indexOf(u8, probe, "<html") != null or
        std.mem.indexOf(u8, probe, "<body") != null or
        std.mem.indexOf(u8, probe, "<!DOCTYPE") != null;
}

fn stripHtmlToText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var in_tag = false;
    var skip_until: ?[]const u8 = null;
    var pending_space = false;
    var index: usize = 0;
    while (index < html.len) : (index += 1) {
        if (skip_until) |needle| {
            if (std.mem.indexOfPos(u8, html, index, needle)) |pos| {
                index = pos + needle.len - 1;
                skip_until = null;
                pending_space = true;
                continue;
            }
            break;
        }
        const byte = html[index];
        if (byte == '<') {
            if (std.ascii.startsWithIgnoreCase(html[index..], "<style")) {
                skip_until = "</style>";
                continue;
            }
            if (std.ascii.startsWithIgnoreCase(html[index..], "<script")) {
                skip_until = "</script>";
                continue;
            }
            in_tag = true;
            pending_space = true;
            continue;
        }
        if (byte == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;

        if (byte == '&') {
            if (decodeHtmlEntity(html[index..])) |decoded| {
                if (std.ascii.isWhitespace(decoded)) {
                    pending_space = true;
                } else {
                    if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
                    pending_space = false;
                    try out.append(allocator, decoded);
                }
                while (index < html.len and html[index] != ';') : (index += 1) {}
                continue;
            }
        }

        if (std.ascii.isWhitespace(byte)) {
            pending_space = true;
            continue;
        }

        if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
        pending_space = false;
        try out.append(allocator, byte);
    }

    return out.toOwnedSlice(allocator);
}

fn decodeHtmlEntity(slice: []const u8) ?u8 {
    if (std.mem.startsWith(u8, slice, "&amp;")) return '&';
    if (std.mem.startsWith(u8, slice, "&lt;")) return '<';
    if (std.mem.startsWith(u8, slice, "&gt;")) return '>';
    if (std.mem.startsWith(u8, slice, "&quot;")) return '"';
    if (std.mem.startsWith(u8, slice, "&#39;")) return '\'';
    if (std.mem.startsWith(u8, slice, "&nbsp;")) return ' ';
    return null;
}

fn urlEncodeComponent(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var writer = out.writer(allocator);
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try out.append(allocator, byte);
        } else if (byte == ' ') {
            try out.append(allocator, '+');
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice(allocator);
}


fn summarizeBingRssResults(
    allocator: std.mem.Allocator,
    rss_body: []const u8,
    query: []const u8,
    limit: usize,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var writer = out.writer(allocator);

    var count: usize = 0;
    var cursor: usize = 0;
    var items = std.ArrayList(struct {
        title: []const u8,
        link: []const u8,
        description: []const u8,
    }).empty;
    defer items.deinit(allocator);
    while (count < limit) {
        const item_start_rel = std.mem.indexOfPos(u8, rss_body, cursor, "<item>") orelse break;
        const item_end = std.mem.indexOfPos(u8, rss_body, item_start_rel, "</item>") orelse break;
        const item = rss_body[item_start_rel..item_end];
        const title = xmlTagValue(item, "title") orelse "";
        const link = xmlTagValue(item, "link") orelse "";
        const description = xmlTagValue(item, "description") orelse "";
        count += 1;
        try items.append(allocator, .{
            .title = title,
            .link = link,
            .description = description,
        });
        cursor = item_end + "</item>".len;
    }

    try writer.print("search query: {s}\nresults: {d}\n", .{ query, count });
    if (count == 0) {
        try writer.writeAll("No search results found.\n");
        return out.toOwnedSlice(allocator);
    }
    try writer.writeAll("Use these results to answer the user. Do not repeat the same search unless you need a meaningfully different query or source.\n\n");

    for (items.items, 0..) |entry, index| {
        try writer.print("{d}. {s}\n   url: {s}\n", .{ index + 1, entry.title, entry.link });
        if (entry.description.len > 0) try writer.print("   snippet: {s}\n", .{entry.description});
    }
    return out.toOwnedSlice(allocator);
}

fn xmlTagValue(haystack: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const start = std.mem.indexOf(u8, haystack, open) orelse return null;
    const content_start = start + open.len;
    const end = std.mem.indexOfPos(u8, haystack, content_start, close) orelse return null;
    return std.mem.trim(u8, haystack[content_start..end], " \r\n\t");
}

fn previewText(text: []const u8, max_len: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len <= max_len) return trimmed;
    return trimmed[0..max_len];
}

fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globMatchAt(pattern, 0, path, 0);
}

fn globMatchAt(pattern: []const u8, pattern_index: usize, path: []const u8, path_index: usize) bool {
    if (pattern_index >= pattern.len) return path_index >= path.len;

    if (pattern[pattern_index] == '*') {
        if (pattern_index + 1 < pattern.len and pattern[pattern_index + 1] == '*') {
            const next_index = pattern_index + 2;
            if (globMatchAt(pattern, next_index, path, path_index)) return true;
            var cursor = path_index;
            while (cursor < path.len) : (cursor += 1) {
                if (globMatchAt(pattern, next_index, path, cursor + 1)) return true;
            }
            return false;
        }

        var cursor = path_index;
        if (globMatchAt(pattern, pattern_index + 1, path, cursor)) return true;
        while (cursor < path.len and path[cursor] != '/' and path[cursor] != '\\') : (cursor += 1) {
            if (globMatchAt(pattern, pattern_index + 1, path, cursor + 1)) return true;
        }
        return false;
    }

    if (pattern[pattern_index] == '?') {
        if (path_index >= path.len or path[path_index] == '/' or path[path_index] == '\\') return false;
        return globMatchAt(pattern, pattern_index + 1, path, path_index + 1);
    }

    if (path_index >= path.len) return false;
    const pattern_char = normalizeGlobByte(pattern[pattern_index]);
    const path_char = normalizeGlobByte(path[path_index]);
    if (pattern_char != path_char) return false;
    return globMatchAt(pattern, pattern_index + 1, path, path_index + 1);
}

fn normalizeGlobByte(byte: u8) u8 {
    if (byte == '\\') return '/';
    return std.ascii.toLower(byte);
}

fn terminationString(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .Exited => "exited",
        .Signal => "signal",
        .Stopped => "stopped",
        .Unknown => "unknown",
    };
}

fn appearsBinary(content: []const u8) bool {
    const probe_len = @min(content.len, 4096);
    for (content[0..probe_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
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

test "findTool returns web tools" {
    try std.testing.expect(findTool("web_fetch") != null);
    try std.testing.expect(findTool("web_search") != null);
}

test "findTool returns glob and patch tools" {
    try std.testing.expect(findTool("glob_search") != null);
    try std.testing.expect(findTool("apply_patch") != null);
}

test "findTool returns bash alias" {
    try std.testing.expect(findTool("bash") != null);
}

test "findTool returns rg alias" {
    try std.testing.expect(findTool("rg") != null);
}

test "stripHtmlToText removes tags and keeps readable text" {
    const text = try stripHtmlToText(std.testing.allocator, "<html><body><h1>Hello</h1><p>world &amp; more</p></body></html>");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Hello world & more", text);
}

test "summarizeBingRssResults extracts item lines" {
    const rss =
        \\<?xml version="1.0"?><rss><channel>
        \\<item><title>First result</title><link>https://example.com/1</link><description>Hello one</description></item>
        \\<item><title>Second result</title><link>https://example.com/2</link><description>Hello two</description></item>
        \\</channel></rss>
    ;
    const summary = try summarizeBingRssResults(std.testing.allocator, rss, "demo query", 5);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "search query: demo query") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "results: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Use these results to answer the user") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "First result") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Second result") != null);
}

test "globMatch supports recursive patterns" {
    try std.testing.expect(globMatch("src/**/*.zig", "src/provider/openai_client.zig"));
    try std.testing.expect(globMatch("**/*.py", "templates/tools/test.py"));
    try std.testing.expect(!globMatch("src/*.zig", "src/provider/openai_client.zig"));
}
