const std = @import("std");

const App = @import("../core/app.zig").App;
const permissions = @import("../core/permissions.zig");
const config_store = @import("../storage/config.zig");
const mcp_store = @import("../storage/mcp.zig");
const session_store = @import("../storage/session.zig");
const skills = @import("../skills/discovery.zig");
const mcp_client = @import("../mcp/client.zig");
const plugins = @import("../plugins/registry.zig");

pub const CommandIo = struct {
    stdout: *std.Io.Writer,
    stdin: ?*std.Io.Reader,
    interactive: bool,
};

pub const CommandError = error{
    ExitRequested,
};

const CommandRunnerResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *const CommandRunnerResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn handle(app: *App, line: []const u8, io: CommandIo) !bool {
    if (line.len == 0 or line[0] != '/') return false;

    var parts = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const name = parts.next() orelse return true;

    if (std.mem.eql(u8, name, "help")) {
        try io.stdout.writeAll(
            \\Commands:
            \\  /help
            \\  /exit
            \\  /clear
            \\  /session
            \\  /config
            \\  /sessions [count]
            \\  /provider [openai-compatible|gemini|anthropic]
            \\  /model [name]
            \\  /skills
            \\  /mcp list|add|remove|tools|call
            \\  /plugins
            \\  /doctor
            \\  /diff
            \\  /review
            \\  /compact
            \\  /permissions
            \\  /permissions <read|write|shell> <allow|ask|deny>
            \\  /plan [on|off]
            \\  /resume [id|latest]
            \\
        );
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "plugins")) {
        const found = try plugins.scan(app.allocator, app.cwd);
        defer {
            for (found) |*plugin| plugin.deinit(app.allocator);
            app.allocator.free(found);
        }

        if (found.len == 0) {
            try io.stdout.writeAll("no plugins found\n");
            try io.stdout.flush();
            return true;
        }

        for (found) |plugin| {
            try io.stdout.print("{s} v{s}\n{s}\n{s}\n\n", .{
                plugin.name,
                plugin.version,
                plugin.description,
                plugin.path,
            });
        }
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "mcp")) {
        const sub = parts.next() orelse "list";
        const servers = try mcp_store.load(app.allocator, app.config.paths);
        defer mcp_store.deinitServers(app.allocator, servers);

        if (std.mem.eql(u8, sub, "list")) {
            if (servers.len == 0) {
                try io.stdout.writeAll("no mcp servers configured\n");
            } else {
                for (servers) |server| {
                    try io.stdout.print("{s}: {s}\n", .{ server.name, server.command });
                }
            }
            try io.stdout.flush();
            return true;
        }

        if (std.mem.eql(u8, sub, "add")) {
            const server_name = parts.next() orelse {
                try io.stdout.writeAll("usage: /mcp add <name> <command>\n");
                try io.stdout.flush();
                return true;
            };
            const command = parts.rest();
            if (command.len == 0) {
                try io.stdout.writeAll("usage: /mcp add <name> <command>\n");
                try io.stdout.flush();
                return true;
            }

            var new_servers = try app.allocator.alloc(mcp_store.McpServer, servers.len + 1);
            defer {
                for (new_servers) |*server| server.deinit(app.allocator);
                app.allocator.free(new_servers);
            }
            for (servers, 0..) |server, index| {
                new_servers[index] = .{
                    .name = try app.allocator.dupe(u8, server.name),
                    .command = try app.allocator.dupe(u8, server.command),
                };
            }
            new_servers[servers.len] = .{
                .name = try app.allocator.dupe(u8, server_name),
                .command = try app.allocator.dupe(u8, command),
            };
            try mcp_store.save(app.allocator, app.config.paths, new_servers);
            try io.stdout.writeAll("mcp server added\n");
            try io.stdout.flush();
            return true;
        }

        if (std.mem.eql(u8, sub, "remove")) {
            const server_name = parts.next() orelse {
                try io.stdout.writeAll("usage: /mcp remove <name>\n");
                try io.stdout.flush();
                return true;
            };

            var count: usize = 0;
            for (servers) |server| {
                if (!std.mem.eql(u8, server.name, server_name)) count += 1;
            }
            var next = try app.allocator.alloc(mcp_store.McpServer, count);
            defer {
                for (next) |*server| server.deinit(app.allocator);
                app.allocator.free(next);
            }
            var index: usize = 0;
            for (servers) |server| {
                if (std.mem.eql(u8, server.name, server_name)) continue;
                next[index] = .{
                    .name = try app.allocator.dupe(u8, server.name),
                    .command = try app.allocator.dupe(u8, server.command),
                };
                index += 1;
            }
            try mcp_store.save(app.allocator, app.config.paths, next);
            try io.stdout.writeAll("mcp server removed\n");
            try io.stdout.flush();
            return true;
        }

        if (std.mem.eql(u8, sub, "tools")) {
            const server_name = parts.next() orelse {
                try io.stdout.writeAll("usage: /mcp tools <name>\n");
                try io.stdout.flush();
                return true;
            };
            const server = findServer(servers, server_name) orelse {
                try io.stdout.writeAll("mcp server not found\n");
                try io.stdout.flush();
                return true;
            };
            const tool_list = try mcp_client.listTools(app.allocator, server.*, app.cwd);
            defer {
                for (tool_list) |*tool| tool.deinit(app.allocator);
                app.allocator.free(tool_list);
            }
            for (tool_list) |tool| {
                try io.stdout.print("{s}: {s}\n", .{ tool.name, tool.description });
            }
            try io.stdout.flush();
            return true;
        }

        if (std.mem.eql(u8, sub, "call")) {
            const server_name = parts.next() orelse {
                try io.stdout.writeAll("usage: /mcp call <server> <tool> <arguments-json>\n");
                try io.stdout.flush();
                return true;
            };
            const tool_name = parts.next() orelse {
                try io.stdout.writeAll("usage: /mcp call <server> <tool> <arguments-json>\n");
                try io.stdout.flush();
                return true;
            };
            const arguments_json = parts.rest();
            if (arguments_json.len == 0) {
                try io.stdout.writeAll("usage: /mcp call <server> <tool> <arguments-json>\n");
                try io.stdout.flush();
                return true;
            }
            const server = findServer(servers, server_name) orelse {
                try io.stdout.writeAll("mcp server not found\n");
                try io.stdout.flush();
                return true;
            };
            const result = try mcp_client.callTool(app.allocator, server.*, app.cwd, tool_name, arguments_json);
            defer app.allocator.free(result);
            try io.stdout.writeAll(result);
            if (result.len == 0 or result[result.len - 1] != '\n') try io.stdout.writeByte('\n');
            try io.stdout.flush();
            return true;
        }

        try io.stdout.writeAll("usage: /mcp list|add|remove|tools|call\n");
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "exit") or std.mem.eql(u8, name, "quit")) {
        return CommandError.ExitRequested;
    }

    if (std.mem.eql(u8, name, "clear")) {
        app.clearSession();
        try io.stdout.writeAll("session cleared\n");
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "session")) {
        try io.stdout.print("session: {s}\n", .{app.session_id});
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "sessions")) {
        const count_text = parts.next();
        const limit = if (count_text) |value| std.fmt.parseInt(usize, value, 10) catch 8 else 8;
        const sessions = try session_store.listSessions(app.allocator, app.config.paths);
        defer {
            for (sessions) |*session| session.deinit(app.allocator);
            app.allocator.free(sessions);
        }
        if (sessions.len == 0) {
            try io.stdout.writeAll("no saved sessions\n");
            try io.stdout.flush();
            return true;
        }
        for (sessions[0..@min(sessions.len, limit)]) |session| {
            try io.stdout.print("{s}  model={s}  messages={d}  updated_at={d}\n{s}\n\n", .{
                session.id,
                session.model,
                session.message_count,
                session.updated_at,
                session.cwd,
            });
        }
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "config")) {
        try io.stdout.print(
            "provider: {s}\nmodel: {s}\nbase_url: {s}\npermissions: read={s} write={s} shell={s}\nplan: {s}\n",
            .{
                app.config.provider,
                app.config.model,
                app.config.base_url,
                permissions.modeString(app.permissions.read),
                permissions.modeString(app.permissions.write),
                permissions.modeString(app.permissions.shell),
                if (app.plan_mode) "on" else "off",
            },
        );
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "doctor")) {
        const sessions = try session_store.listSessions(app.allocator, app.config.paths);
        defer {
            for (sessions) |*session| session.deinit(app.allocator);
            app.allocator.free(sessions);
        }
        const servers = try mcp_store.load(app.allocator, app.config.paths);
        defer mcp_store.deinitServers(app.allocator, servers);
        const found_plugins = try plugins.scan(app.allocator, app.cwd);
        defer {
            for (found_plugins) |*plugin| plugin.deinit(app.allocator);
            app.allocator.free(found_plugins);
        }

        const key_env = switch (config_store.parseProviderPreset(app.config.provider) orelse .openai_compatible) {
            .openai_compatible => "OPENAI_API_KEY",
            .gemini => "GEMINI_API_KEY",
            .anthropic => "ANTHROPIC_API_KEY",
        };
        const key_present = app.config.api_key.len > 0;
        var git_result = runCommand(app.allocator, app.cwd, &.{ "git", "rev-parse", "--is-inside-work-tree" }) catch null;
        defer if (git_result) |*res| res.deinit(app.allocator);

        try io.stdout.print(
            "cwd: {s}\nprovider: {s}\nmodel: {s}\nbase_url: {s}\napi_key_env: {s}\napi_key_present: {s}\nplan: {s}\nsessions: {d}\nmcp_servers: {d}\nplugins: {d}\ngit_repo: {s}\n",
            .{
                app.cwd,
                app.config.provider,
                app.config.model,
                app.config.base_url,
                key_env,
                if (key_present) "yes" else "no",
                if (app.plan_mode) "on" else "off",
                sessions.len,
                servers.len,
                found_plugins.len,
                if (git_result != null and git_result.?.exit_code == 0) "yes" else "no",
            },
        );
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "diff")) {
        const status = try runCommand(app.allocator, app.cwd, &.{ "git", "status", "--short" });
        defer status.deinit(app.allocator);
        const diff = try runCommand(app.allocator, app.cwd, &.{ "git", "diff", "--stat" });
        defer diff.deinit(app.allocator);
        if (status.exit_code != 0 and diff.exit_code != 0) {
            try io.stdout.writeAll("not a git repository or git unavailable\n");
            try io.stdout.flush();
            return true;
        }
        if (status.stdout.len > 0) {
            try io.stdout.writeAll("git status --short\n");
            try io.stdout.writeAll(status.stdout);
            if (status.stdout[status.stdout.len - 1] != '\n') try io.stdout.writeByte('\n');
        }
        if (diff.stdout.len > 0) {
            try io.stdout.writeAll("\ngit diff --stat\n");
            try io.stdout.writeAll(diff.stdout);
            if (diff.stdout[diff.stdout.len - 1] != '\n') try io.stdout.writeByte('\n');
        }
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "review")) {
        const files = try runCommand(app.allocator, app.cwd, &.{ "git", "diff", "--name-only" });
        defer files.deinit(app.allocator);
        const check = try runCommand(app.allocator, app.cwd, &.{ "git", "diff", "--check" });
        defer check.deinit(app.allocator);
        if (files.exit_code != 0 and check.exit_code != 0) {
            try io.stdout.writeAll("not a git repository or git unavailable\n");
            try io.stdout.flush();
            return true;
        }
        try io.stdout.writeAll("review target\n");
        if (files.stdout.len == 0) {
            try io.stdout.writeAll("no changed files\n");
        } else {
            try io.stdout.writeAll(files.stdout);
            if (files.stdout[files.stdout.len - 1] != '\n') try io.stdout.writeByte('\n');
        }
        try io.stdout.writeAll("\nreview notes\n");
        if (check.stdout.len == 0) {
            try io.stdout.writeAll("no whitespace/check issues from git diff --check\n");
        } else {
            try io.stdout.writeAll(check.stdout);
            if (check.stdout[check.stdout.len - 1] != '\n') try io.stdout.writeByte('\n');
        }
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "compact")) {
        if (try app.compactSession(12)) {
            try io.stdout.print("session compacted to {d} messages plus summary\n", .{app.session.items.len});
        } else {
            try io.stdout.writeAll("session too small to compact\n");
        }
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "provider")) {
        const provider_name = parts.next();
        if (provider_name == null) {
            try io.stdout.print("provider: {s}\n", .{app.config.provider});
            try io.stdout.flush();
            return true;
        }

        const preset = config_store.parseProviderPreset(provider_name.?) orelse {
            try io.stdout.writeAll("invalid provider, expected openai-compatible, gemini, or anthropic\n");
            try io.stdout.flush();
            return true;
        };

        try config_store.setProviderPreset(app.allocator, &app.config, preset);
        try config_store.save(app.allocator, &app.config);
        try io.stdout.print(
            "provider set to {s}\nmodel: {s}\nbase_url: {s}\n",
            .{ app.config.provider, app.config.model, app.config.base_url },
        );
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "skills")) {
        const found = try skills.discover(app.allocator);
        defer {
            for (found) |*skill| skill.deinit(app.allocator);
            app.allocator.free(found);
        }

        if (found.len == 0) {
            try io.stdout.writeAll("no skills found\n");
            try io.stdout.flush();
            return true;
        }

        for (found) |skill| {
            try io.stdout.print("{s}: {s}\n{s}\n\n", .{ skill.name, skill.path, skill.summary });
        }
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "model")) {
        const model = parts.next();
        if (model == null) {
            try io.stdout.print("model: {s}\n", .{app.config.model});
            try io.stdout.flush();
            return true;
        }

        app.allocator.free(app.config.model);
        app.config.model = try app.allocator.dupe(u8, model.?);
        try config_store.save(app.allocator, &app.config);
        try io.stdout.print("model set to {s}\n", .{app.config.model});
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "permissions")) {
        const class_name = parts.next();
        const mode_name = parts.next();
        if (class_name == null or mode_name == null) {
            try io.stdout.print(
                "permissions: read={s} write={s} shell={s}\n",
                .{
                    permissions.modeString(app.permissions.read),
                    permissions.modeString(app.permissions.write),
                    permissions.modeString(app.permissions.shell),
                },
            );
            try io.stdout.flush();
            return true;
        }

        const class = permissions.parsePermissionClass(class_name.?) orelse {
            try io.stdout.writeAll("invalid permission class\n");
            try io.stdout.flush();
            return true;
        };
        const mode = permissions.parsePermissionMode(mode_name.?) orelse {
            try io.stdout.writeAll("invalid permission mode\n");
            try io.stdout.flush();
            return true;
        };
        app.permissions.setForClass(class, mode);
        try io.stdout.print("{s} set to {s}\n", .{ class_name.?, mode_name.? });
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "plan")) {
        const value = parts.next();
        if (value == null) {
            try io.stdout.print("plan: {s}\n", .{if (app.plan_mode) "on" else "off"});
            try io.stdout.flush();
            return true;
        }

        if (std.mem.eql(u8, value.?, "on")) {
            app.plan_mode = true;
        } else if (std.mem.eql(u8, value.?, "off")) {
            app.plan_mode = false;
        } else {
            try io.stdout.writeAll("usage: /plan [on|off]\n");
            try io.stdout.flush();
            return true;
        }

        try io.stdout.print("plan {s}\n", .{if (app.plan_mode) "enabled" else "disabled"});
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "resume")) {
        const requested = parts.next() orelse "latest";
        var loaded = try session_store.loadSession(app.allocator, app.config.paths, requested);
        defer loaded.deinit(app.allocator);

        try app.replaceSession(loaded.id, loaded.model, loaded.messages);
        try io.stdout.print("resumed session {s}\n", .{app.session_id});
        try io.stdout.flush();
        return true;
    }

    try io.stdout.writeAll("unknown command\n");
    try io.stdout.flush();
    return true;
}

fn findServer(servers: []mcp_store.McpServer, name: []const u8) ?*mcp_store.McpServer {
    for (servers) |*server| {
        if (std.mem.eql(u8, server.name, name)) return server;
    }
    return null;
}

fn runCommand(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !CommandRunnerResult {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const stdout = if (child.stdout) |file|
        try file.readToEndAlloc(allocator, 1024 * 1024)
    else
        try allocator.dupe(u8, "");
    const stderr = if (child.stderr) |file|
        try file.readToEndAlloc(allocator, 1024 * 1024)
    else
        try allocator.dupe(u8, "");

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        else => 1,
    };

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}
