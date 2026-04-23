const std = @import("std");

const tool_base = @import("../tools/base.zig");

pub fn buildRuntimePrompt(
    allocator: std.mem.Allocator,
    tools: []const tool_base.ToolSpec,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);

    try writer.writeAll(
        \\You are Cirebronx, a terminal coding agent running on the user's machine inside their workspace.
        \\
        \\You and the user share the same filesystem context. When the user asks you to create, modify, scaffold, fix, refactor, or inspect code or project files, use the available tools to do the work in the workspace instead of only describing what to do.
        \\
        \\Persist until the requested task is actually handled end-to-end within the current turn whenever feasible. Do not stop at advice when you can act with tools. Do not invent results. If a tool fails, report the failure briefly and either recover with another tool or explain the real blocker.
        \\
        \\If the user asks what tools you have, answer from the tool inventory below. If the user asks for explanation only, you can explain without editing files. Otherwise, prefer acting over narrating.
        \\
        \\For code or project creation requests:
        \\- create the necessary files in the workspace
        \\- write concrete code instead of placeholder prose
        \\- only explain after you have acted or if acting is blocked
        \\- keep changes scoped to the user's request
        \\- do not overwrite unrelated top-level docs or config such as README.md, LICENSE, package manifests, or lockfiles unless the user asked for that exact change
        \\
        \\For file changes:
        \\- inspect relevant files before editing when needed
        \\- avoid unrelated cleanup
        \\- do not claim to have written files unless you actually used tools to write them
        \\- for multi-file or repo-wide refactors, discover scope first, then edit only the affected files
        \\
        \\Tool playbook:
        \\- use list_files, glob_search, rg, grep, and read_file to discover and inspect before changing code
        \\- use write_file for new files, edit_file for one exact replacement, and apply_patch for multiple exact replacements in one file
        \\- use shell_command or bash to run builds, tests, package managers, formatters, or other workspace commands
        \\- on Windows, prefer rg for repo-wide text search instead of inventing fragile PowerShell search syntax
        \\- use web_search and web_fetch when the task needs current external documentation or URLs
        \\- if the user asks what tools exist, answer from the tool inventory below and mention the most relevant ones for their task
        \\
        \\Keep responses concise and factual. All normal text is shown to the user.
    );

    if (tools.len == 0) {
        try writer.writeAll("\n\nTool inventory:\n- No tools are exposed for this turn.");
        return out.toOwnedSlice(allocator);
    }

    try writer.writeAll("\n\nTool inventory:");
    for (tools) |tool| {
        try writer.print(
            "\n- {s} [{s}]: {s}",
            .{ tool.name, permissionLabel(tool.permission), tool.description },
        );
        if (try summarizeSchemaArguments(allocator, tool.schema_json)) |summary| {
            defer allocator.free(summary);
            if (summary.len > 0) try writer.print(" Args: {s}.", .{summary});
        }
    }

    return out.toOwnedSlice(allocator);
}

fn summarizeSchemaArguments(allocator: std.mem.Allocator, schema_json: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |value| value,
        else => return null,
    };
    const properties = obj.get("properties") orelse return null;
    const prop_obj = switch (properties) {
        .object => |value| value,
        else => return null,
    };
    if (prop_obj.count() == 0) return null;

    var parts = std.ArrayList(u8).empty;
    errdefer parts.deinit(allocator);
    const writer = parts.writer(allocator);
    var first = true;
    var iter = prop_obj.iterator();
    while (iter.next()) |entry| {
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.writeAll(entry.key_ptr.*);
    }
    return try parts.toOwnedSlice(allocator);
}

fn permissionLabel(permission: anytype) []const u8 {
    return @tagName(permission);
}

test "buildRuntimePrompt includes tool inventory" {
    const tools = [_]tool_base.ToolSpec{
        .{
            .kind = .write_file,
            .name = "write_file",
            .description = "Write a file to disk.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}",
            .permission = .write,
        },
        .{
            .kind = .shell_command,
            .name = "bash",
            .description = "Run a shell command.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}",
            .permission = .shell,
        },
        .{
            .kind = .rg_search,
            .name = "rg",
            .description = "Search files with ripgrep.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}},\"required\":[\"pattern\"]}",
            .permission = .read,
        },
        .{
            .kind = .apply_patch,
            .name = "apply_patch",
            .description = "Patch a file.",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"edits\":{\"type\":\"array\"}},\"required\":[\"path\",\"edits\"]}",
            .permission = .write,
        },
    };

    const prompt = try buildRuntimePrompt(std.testing.allocator, &tools);
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "write_file [write]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "bash [shell]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "rg [read]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "apply_patch [write]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Args: path, content.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "create the necessary files in the workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "do not overwrite unrelated top-level docs or config") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "use shell_command or bash to run builds, tests, package managers, formatters, or other workspace commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "on Windows, prefer rg for repo-wide text search instead of inventing fragile PowerShell search syntax") != null);
}
