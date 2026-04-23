const std = @import("std");

const App = @import("../core/app.zig").App;
const openai_client = @import("openai_client.zig");
const anthropic_client = @import("anthropic_client.zig");
const tool_base = @import("../tools/base.zig");

pub const TurnResult = openai_client.TurnResult;
pub const TurnObserver = @import("types.zig").TurnObserver;

pub fn sendTurn(app: *App, tools: []const tool_base.ToolSpec) !TurnResult {
    return sendTurnObserved(app, tools, .{});
}

pub fn sendTurnObserved(app: *App, tools: []const tool_base.ToolSpec, observer: TurnObserver) !TurnResult {
    const exposed_tools = selectToolsForTurn(app, tools);
    if (std.mem.eql(u8, app.config.provider, "anthropic")) {
        return try anthropic_client.sendTurnObserved(app, exposed_tools, observer);
    }
    return try openai_client.sendTurnObserved(app, exposed_tools, observer);
}

fn selectToolsForTurn(app: *App, tools: []const tool_base.ToolSpec) []const tool_base.ToolSpec {
    if (tools.len == 0) return tools;
    if (shouldExposeToolsForTurn(app)) return tools;
    return &.{};
}

fn shouldExposeToolsForTurn(app: *App) bool {
    if (app.session.items.len == 0) return true;
    const last = app.session.items[app.session.items.len - 1];
    if (last.role != .user) return true;

    const text = std.mem.trim(u8, last.content, " \r\n\t");
    if (text.len == 0) return false;

    const lower = lowerSlice(text);
    if (looksLikeKnowledgeOrExamplePrompt(lower) and !hasWorkspaceIntent(lower)) return false;
    return hasWorkspaceIntent(lower);
}

fn hasWorkspaceIntent(lower: []const u8) bool {
    const strong_terms = [_][]const u8{
        "workspace", "codebase", "repository", "repo", "project",
        "this repo", "this repository", "this project", "this codebase",
        "current directory", "current dir", "current folder",
        "list files", "read file", "open file", "search files", "search the repo",
        "grep", "directory", "folder", "path", "terminal", "shell command",
        "git", "worktree", "mcp", "plugin", "skill", "build", "test",
        "fix this", "edit", "patch", "write file", "change file", "inspect", "scan",
        "tool", "tools", "filesystem", "file system", "built-in tools", "built in tools",
        "create file", "update file", "replace text", "edit file", "modify file",
        "create app", "build app", "create project", "build project", "generate project",
        "scaffold", "bootstrap", "implement", "make app", "make project",
        "todo app", "flask app", "python app", "write code", "create code",
        "rename", "rename symbol", "refactor", "across repo", "across project",
        "multiple files", "multi file", "multi-file", "update imports", "fix tests",
        "run tests", "compile", "lint", "build failure", "test failure",
        "bash", "powershell", "command line", "terminal command", "rg", "ripgrep",
        "web", "website", "search web", "web search", "fetch url", "fetch page", "read url",
        "open url", "visit url", "browse", "browser",
    };
    for (strong_terms) |term| {
        if (std.mem.indexOf(u8, lower, term) != null) return true;
    }

    if (std.mem.indexOfAny(u8, lower, "/\\") != null) return true;
    if (std.mem.indexOfAny(u8, lower, "{}[]`$") != null) return true;

    const file_markers = [_][]const u8{
        ".zig", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".go", ".java", ".scala", ".kt",
        ".json", ".md", ".toml", ".yaml", ".yml",
    };
    for (file_markers) |marker| {
        if (std.mem.indexOf(u8, lower, marker) != null) return true;
    }

    return false;
}

fn looksLikeKnowledgeOrExamplePrompt(lower: []const u8) bool {
    const example_terms = [_][]const u8{
        "example", "sample", "snippet", "show me", "teach me", "explain", "what is", "how does",
        "compare", "why is", "syntax", "tutorial", "guide", "best practices",
    };
    for (example_terms) |term| {
        if (std.mem.indexOf(u8, lower, term) != null) return true;
    }
    return false;
}

fn lowerSlice(text: []const u8) []const u8 {
    const Store = struct {
        var buf: [512]u8 = undefined;
    };
    const len = @min(text.len, Store.buf.len);
    for (text[0..len], 0..) |byte, index| Store.buf[index] = std.ascii.toLower(byte);
    return Store.buf[0..len];
}

test "selectToolsForTurn hides tools for non-workspace code example prompt" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendMessage(.{ .role = .user, .content = "show me sample of great scala code" });
    const tool = tool_base.ToolSpec{
        .kind = .list_files,
        .name = "list_files",
        .description = "List files",
        .schema_json = "{}",
        .permission = .read,
    };
    const selected = selectToolsForTurn(&app, &.{tool});
    try std.testing.expectEqual(@as(usize, 0), selected.len);
}

test "selectToolsForTurn keeps tools for workspace file request" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendMessage(.{ .role = .user, .content = "read file src/main.zig and fix the bug" });
    const tool = tool_base.ToolSpec{
        .kind = .read_file,
        .name = "read_file",
        .description = "Read file",
        .schema_json = "{}",
        .permission = .read,
    };
    const selected = selectToolsForTurn(&app, &.{tool});
    try std.testing.expectEqual(@as(usize, 1), selected.len);
}

test "selectToolsForTurn keeps tools for create-project request" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendMessage(.{ .role = .user, .content = "create simple python flask todo app" });
    const tool = tool_base.ToolSpec{
        .kind = .write_file,
        .name = "write_file",
        .description = "Write file",
        .schema_json = "{}",
        .permission = .write,
    };
    const selected = selectToolsForTurn(&app, &.{tool});
    try std.testing.expectEqual(@as(usize, 1), selected.len);
}

test "selectToolsForTurn keeps tools for repo-wide refactor request" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendMessage(.{ .role = .user, .content = "rename Config to AppConfig across repo and update imports" });
    const tool = tool_base.ToolSpec{
        .kind = .apply_patch,
        .name = "apply_patch",
        .description = "Apply patch",
        .schema_json = "{}",
        .permission = .write,
    };
    const selected = selectToolsForTurn(&app, &.{tool});
    try std.testing.expectEqual(@as(usize, 1), selected.len);
}

test "selectToolsForTurn keeps tools on follow-up non-user turns" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendAssistantText("thinking");
    const tool = tool_base.ToolSpec{
        .kind = .read_file,
        .name = "read_file",
        .description = "Read file",
        .schema_json = "{}",
        .permission = .read,
    };
    const selected = selectToolsForTurn(&app, &.{tool});
    try std.testing.expectEqual(@as(usize, 1), selected.len);
}
