const std = @import("std");

const App = @import("../core/app.zig").App;
const command_discovery = @import("discovery.zig");
const permissions = @import("../core/permissions.zig");
const config_store = @import("../storage/config.zig");
const mcp_store = @import("../storage/mcp.zig");
const session_store = @import("../storage/session.zig");
const skills = @import("../skills/discovery.zig");
const mcp_client = @import("../mcp/client.zig");
const mcp_helpers = @import("../mcp/helpers.zig");
const plugins = @import("../plugins/registry.zig");
const openrouter_pool = @import("../provider/openrouter_pool.zig");
const tools = @import("../tools/registry.zig");
const message_mod = @import("../core/message.zig");

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
            \\  /status
            \\  /providers
            \\  /tools
            \\  /tools show <name>
            \\  /tools run <name> <json>
            \\  /themes
            \\  /commands
            \\  /commands show <name> [arguments]
            \\  /exit
            \\  /clear
            \\  /session
            \\  /config
            \\  /sessions [count]
            \\  /provider [openai|openrouter|anthropic|gemini|groq|cerebras|huggingface]
            \\  /theme [bubble|midnight|forest|ember]
            \\  /model [name]
            \\  /skills
            \\  /skills show <name> [arguments]
            \\  /mcp list|status|show|add|remove|tools|call
            \\  /plugins
            \\  /doctor
            \\  /diff
            \\  /review
            \\  /subagent [list|steer|kill]
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

    if (std.mem.eql(u8, name, "status")) {
        const sessions = try session_store.listSessions(app.allocator, app.config.paths);
        defer {
            for (sessions) |*session| session.deinit(app.allocator);
            app.allocator.free(sessions);
        }
        const servers = try mcp_helpers.loadServers(app.allocator, app.config.paths);
        defer mcp_helpers.deinitServers(app.allocator, servers);
        const found_plugins = try plugins.scan(app.allocator, app.cwd);
        defer {
            for (found_plugins) |*plugin| plugin.deinit(app.allocator);
            app.allocator.free(found_plugins);
        }
        const found_commands = try command_discovery.discover(app.allocator);
        defer {
            for (found_commands) |*command| command.deinit(app.allocator);
            app.allocator.free(found_commands);
        }
        const found_skills = try skills.discover(app.allocator);
        defer {
            for (found_skills) |*skill| skill.deinit(app.allocator);
            app.allocator.free(found_skills);
        }
        try io.stdout.print(
            "status: {s}\nprovider: {s}\nmodel: {s}\ntheme: {s}\nbase_url: {s}\nmessages: {d}\nplan: {s}\nlast_provider_error: {s}\nsessions: {d}\nskills: {d}\ncommands: {d}\nplugins: {d}\nmcp_servers: {d}\nsubagents: {d}\nopenrouter_pool_keys: {d}\n",
            .{
                if (app.session.items.len == 0) "idle" else "active",
                app.config.provider,
                app.config.model,
                app.config.theme,
                app.config.base_url,
                app.session.items.len,
                if (app.plan_mode) "on" else "off",
                if (app.last_provider_error) |err| err else "<none>",
                sessions.len,
                found_skills.len,
                found_commands.len,
                found_plugins.len,
                servers.len,
                app.subagents.items.len,
                openrouter_pool.keyCount(app.allocator),
            },
        );
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "commands")) {
        const sub = parts.next();
        if (sub == null or std.mem.eql(u8, sub.?, "list")) {
            const found = try command_discovery.discover(app.allocator);
            defer {
                for (found) |*command| command.deinit(app.allocator);
                app.allocator.free(found);
            }

            if (found.len == 0) {
                try io.stdout.writeAll("no external commands found\n");
                try io.stdout.flush();
                return true;
            }

            for (found) |command| {
                try io.stdout.print("{s} [{s}]: {s}\n{s}\n\n", .{
                    command.name,
                    command.source,
                    command.path,
                    command.summary,
                });
            }
            try io.stdout.flush();
            return true;
        }

        if (std.mem.eql(u8, sub.?, "show")) {
            const requested = parts.next() orelse {
                try io.stdout.writeAll("usage: /commands show <name> [arguments]\n");
                try io.stdout.flush();
                return true;
            };
            var loaded = (try command_discovery.loadByName(app.allocator, requested)) orelse {
                try io.stdout.writeAll("external command not found\n");
                try io.stdout.flush();
                return true;
            };
            defer loaded.deinit(app.allocator);

            const rendered = try command_discovery.renderPrompt(app.allocator, loaded.body, std.mem.trim(u8, parts.rest(), " \r\t"));
            defer app.allocator.free(rendered);
            try io.stdout.print("[{s}] {s}\n{s}\n\n", .{
                loaded.info.source,
                loaded.info.name,
                rendered,
            });
            try io.stdout.flush();
            return true;
        }

        var loaded = (try command_discovery.loadByName(app.allocator, sub.?)) orelse {
            try io.stdout.writeAll("external command not found\n");
            try io.stdout.flush();
            return true;
        };
        defer loaded.deinit(app.allocator);

        const rendered = try command_discovery.renderPrompt(app.allocator, loaded.body, std.mem.trim(u8, parts.rest(), " \r\t"));
        errdefer app.allocator.free(rendered);
        try app.setPendingInjectedPrompt(rendered);
        app.allocator.free(rendered);
        try io.stdout.print("running external command {s} [{s}]\n", .{
            loaded.info.name,
            loaded.info.source,
        });
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "providers")) {
        const gemini_key = std.process.getEnvVarOwned(app.allocator, "GEMINI_API_KEY") catch null;
        defer if (gemini_key) |value| app.allocator.free(value);
        const anthropic_key = std.process.getEnvVarOwned(app.allocator, "ANTHROPIC_API_KEY") catch null;
        defer if (anthropic_key) |value| app.allocator.free(value);
        const openai_key = std.process.getEnvVarOwned(app.allocator, "OPENAI_API_KEY") catch null;
        defer if (openai_key) |value| app.allocator.free(value);
        const openrouter_key = std.process.getEnvVarOwned(app.allocator, "OPENROUTER_API_KEY") catch null;
        defer if (openrouter_key) |value| app.allocator.free(value);
        const groq_key = std.process.getEnvVarOwned(app.allocator, "GROQ_API_KEY") catch null;
        defer if (groq_key) |value| app.allocator.free(value);
        const cerebras_key = std.process.getEnvVarOwned(app.allocator, "CEREBRAS_API_KEY") catch null;
        defer if (cerebras_key) |value| app.allocator.free(value);
        const hf_key = std.process.getEnvVarOwned(app.allocator, "HF_TOKEN") catch null;
        defer if (hf_key) |value| app.allocator.free(value);
        const huggingface_key = std.process.getEnvVarOwned(app.allocator, "HUGGINGFACE_API_KEY") catch null;
        defer if (huggingface_key) |value| app.allocator.free(value);
        const anthropic_present = anthropic_key != null;
        try io.stdout.print(
            "current: {s}\n\npresets:\n  openai       key_present={s}  base=https://api.openai.com/v1/chat/completions\n  openrouter   key_present={s}  pool_keys={d}  base=https://openrouter.ai/api/v1/chat/completions\n  anthropic    key_present={s}  base=https://api.anthropic.com/v1/messages\n  gemini       key_present={s}  base=https://generativelanguage.googleapis.com/v1beta/openai/chat/completions\n  groq         key_present={s}  base=https://api.groq.com/openai/v1/chat/completions\n  cerebras     key_present={s}  base=https://api.cerebras.ai/v1/chat/completions\n  huggingface  key_present={s}  base=https://router.huggingface.co/v1/chat/completions\n",
            .{
                app.config.provider,
                if (openai_key != null) "yes" else "no",
                if (openrouter_key != null or openrouter_pool.keyCount(app.allocator) > 0) "yes" else "no",
                openrouter_pool.keyCount(app.allocator),
                if (anthropic_present) "yes" else "no",
                if (gemini_key != null) "yes" else "no",
                if (groq_key != null) "yes" else "no",
                if (cerebras_key != null) "yes" else "no",
                if (hf_key != null or huggingface_key != null) "yes" else "no",
            },
        );
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "tools")) {
        const sub = parts.next();
        if (sub != null and std.mem.eql(u8, sub.?, "show")) {
            const tool_name = parts.next() orelse {
                try io.stdout.writeAll("usage: /tools show <name>\n");
                try io.stdout.flush();
                return true;
            };
            const tool = tools.findTool(tool_name) orelse {
                try io.stdout.writeAll("tool not found\n");
                try io.stdout.flush();
                return true;
            };
            try io.stdout.print("{s} [{s}]\n{s}\nschema:\n{s}\n", .{
                tool.name,
                @tagName(tool.permission),
                tool.description,
                tool.schema_json,
            });
            try io.stdout.flush();
            return true;
        }

        if (sub != null and std.mem.eql(u8, sub.?, "run")) {
            const tool_name = parts.next() orelse {
                try io.stdout.writeAll("usage: /tools run <name> <json>\n");
                try io.stdout.flush();
                return true;
            };
            const raw_json = std.mem.trim(u8, parts.rest(), " \r\t");
            if (raw_json.len == 0) {
                try io.stdout.writeAll("usage: /tools run <name> <json>\n");
                try io.stdout.flush();
                return true;
            }

            const tool = tools.findTool(tool_name) orelse {
                try io.stdout.writeAll("tool not found\n");
                try io.stdout.flush();
                return true;
            };

            var call = message_mod.ToolCall{
                .id = try app.allocator.dupe(u8, "manual"),
                .name = try app.allocator.dupe(u8, tool_name),
                .arguments = try app.allocator.dupe(u8, raw_json),
            };
            defer call.deinit(app.allocator);

            const previous_mode = app.permissions.forClass(tool.permission);
            if (previous_mode != .deny) app.permissions.setForClass(tool.permission, .allow);
            defer app.permissions.setForClass(tool.permission, previous_mode);

            const result = tools.executeTool(app.allocator, .{
                .app = app,
                .io = .{
                    .stdout = io.stdout,
                    .stdin = io.stdin,
                    .interactive = io.interactive,
                },
            }, call) catch |err| {
                try io.stdout.print("tool error: {s}\n", .{@errorName(err)});
                try io.stdout.flush();
                return true;
            };
            defer app.allocator.free(result);

            try io.stdout.writeAll(result);
            if (result.len == 0 or result[result.len - 1] != '\n') try io.stdout.writeByte('\n');
            try io.stdout.flush();
            return true;
        }

        const exposed = @import("../tools/registry.zig").toolsForExposure(app);
        try io.stdout.print("available tools: {d}\n\n", .{exposed.len});
        for (exposed) |tool| {
            try io.stdout.print("{s} [{s}]\n{s}\n\n", .{
                tool.name,
                @tagName(tool.permission),
                tool.description,
            });
        }
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "themes")) {
        try io.stdout.print(
            "current: {s}\n\npresets:\n  bubble\n  midnight\n  forest\n  ember\n",
            .{app.config.theme},
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
        const servers = try mcp_helpers.loadServers(app.allocator, app.config.paths);
        defer mcp_helpers.deinitServers(app.allocator, servers);

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

        if (std.mem.eql(u8, sub, "status")) {
            if (servers.len == 0) {
                try io.stdout.writeAll("no mcp servers configured\n");
                try io.stdout.flush();
                return true;
            }
            const lines = try mcp_helpers.collectStatus(app.allocator, servers, app.cwd);
            defer mcp_helpers.deinitStatusLines(app.allocator, lines);
            for (lines) |status_line| {
                if (status_line.error_text) |err| {
                    try io.stdout.print("{s}: error={s}\n  command: {s}\n", .{
                        status_line.name,
                        err,
                        status_line.command,
                    });
                } else {
                    try io.stdout.print("{s}: ok tools={d}\n  command: {s}\n", .{
                        status_line.name,
                        status_line.tool_count.?,
                        status_line.command,
                    });
                }
            }
            try io.stdout.flush();
            return true;
        }

        if (std.mem.eql(u8, sub, "show")) {
            const server_name = parts.next() orelse {
                try io.stdout.writeAll("usage: /mcp show <name>\n");
                try io.stdout.flush();
                return true;
            };
            const server = mcp_helpers.findServer(servers, server_name) orelse {
                try io.stdout.writeAll("mcp server not found\n");
                try io.stdout.flush();
                return true;
            };
            try io.stdout.print("name: {s}\ncommand: {s}\n", .{ server.name, server.command });
            const tool_list = mcp_client.listTools(app.allocator, server.*, app.cwd) catch |err| {
                try io.stdout.print("status: error {s}\n", .{@errorName(err)});
                try io.stdout.flush();
                return true;
            };
            defer {
                for (tool_list) |*tool| tool.deinit(app.allocator);
                app.allocator.free(tool_list);
            }
            try io.stdout.print("status: ok\ntools: {d}\n", .{tool_list.len});
            for (tool_list) |tool| {
                try io.stdout.print("  - {s}", .{tool.name});
                if (tool.description.len > 0) {
                    try io.stdout.print(": {s}", .{tool.description});
                }
                try io.stdout.writeByte('\n');
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
            const server = mcp_helpers.findServer(servers, server_name) orelse {
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
            const server = mcp_helpers.findServer(servers, server_name) orelse {
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

        try io.stdout.writeAll("usage: /mcp list|status|show|add|remove|tools|call\n");
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
        try io.stdout.print(
            "current session: {s}\nmessages: {d}\nuse /sessions to list saved sessions and /resume [id|latest] to load one\n",
            .{ app.session_id, app.session.items.len },
        );
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
            "provider: {s}\nmodel: {s}\ntheme: {s}\nbase_url: {s}\npermissions: read={s} write={s} shell={s}\nplan: {s}\n",
            .{
                app.config.provider,
                app.config.model,
                app.config.theme,
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
        const servers = try mcp_helpers.loadServers(app.allocator, app.config.paths);
        defer mcp_helpers.deinitServers(app.allocator, servers);
        const found_plugins = try plugins.scan(app.allocator, app.cwd);
        defer {
            for (found_plugins) |*plugin| plugin.deinit(app.allocator);
            app.allocator.free(found_plugins);
        }

        const key_env = switch (config_store.parseProviderPreset(app.config.provider) orelse .openai) {
            .openai => "OPENAI_API_KEY / OPENROUTER_API_KEYS.json",
            .openrouter => "OPENROUTER_API_KEY / OPENROUTER_API_KEYS.json",
            .gemini => "GEMINI_API_KEY",
            .anthropic => "ANTHROPIC_API_KEY",
            .groq => "GROQ_API_KEY",
            .cerebras => "CEREBRAS_API_KEY",
            .huggingface => "HF_TOKEN / HUGGINGFACE_API_KEY",
        };
        const key_present = app.config.api_key.len > 0;
        var git_result = runCommand(app.allocator, app.cwd, &.{ "git", "rev-parse", "--is-inside-work-tree" }) catch null;
        defer if (git_result) |*res| res.deinit(app.allocator);

        try io.stdout.print(
            "cwd: {s}\nprovider: {s}\nmodel: {s}\ntheme: {s}\nbase_url: {s}\napi_key_env: {s}\napi_key_present: {s}\nplan: {s}\nsessions: {d}\nmcp_servers: {d}\nplugins: {d}\ngit_repo: {s}\n",
            .{
                app.cwd,
                app.config.provider,
                app.config.model,
                app.config.theme,
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

    if (std.mem.eql(u8, name, "subagent")) {
        const sub = parts.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            if (app.subagents.items.len == 0) {
                try io.stdout.writeAll("no subagents\n");
            } else {
                for (app.subagents.items) |agent| {
                    try io.stdout.print("{s}  target={s}  status={s}\n  {s}\n", .{
                        agent.id,
                        agent.target,
                        agent.status,
                        agent.prompt,
                    });
                }
            }
            try io.stdout.flush();
            return true;
        }
        if (std.mem.eql(u8, sub, "steer")) {
            const target = parts.next() orelse {
                try io.stdout.writeAll("usage: /subagent steer <target> <message>\n");
                try io.stdout.flush();
                return true;
            };
            const prompt = parts.rest();
            if (prompt.len == 0) {
                try io.stdout.writeAll("usage: /subagent steer <target> <message>\n");
                try io.stdout.flush();
                return true;
            }
            const id = try app.createSubagent(target, prompt);
            try io.stdout.print("created {s} for {s}\n", .{ id, target });
            try io.stdout.flush();
            return true;
        }
        if (std.mem.eql(u8, sub, "kill")) {
            const id = parts.next() orelse {
                try io.stdout.writeAll("usage: /subagent kill <id>\n");
                try io.stdout.flush();
                return true;
            };
            if (app.removeSubagent(id)) {
                try io.stdout.print("removed {s}\n", .{id});
            } else {
                try io.stdout.writeAll("subagent not found\n");
            }
            try io.stdout.flush();
            return true;
        }
        try io.stdout.writeAll("usage: /subagent [list|steer|kill]\n");
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
            try io.stdout.writeAll("invalid provider, expected openai, openrouter, anthropic, gemini, groq, cerebras, or huggingface\n");
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

    if (std.mem.eql(u8, name, "theme")) {
        const theme_name = parts.next();
        if (theme_name == null) {
            try io.stdout.print("theme: {s}\n", .{app.config.theme});
            try io.stdout.flush();
            return true;
        }
        if (!std.mem.eql(u8, theme_name.?, "bubble") and
            !std.mem.eql(u8, theme_name.?, "midnight") and
            !std.mem.eql(u8, theme_name.?, "forest") and
            !std.mem.eql(u8, theme_name.?, "ember"))
        {
            try io.stdout.writeAll("invalid theme, expected bubble, midnight, forest, or ember\n");
            try io.stdout.flush();
            return true;
        }
        app.allocator.free(app.config.theme);
        app.config.theme = try app.allocator.dupe(u8, theme_name.?);
        try config_store.save(app.allocator, &app.config);
        try io.stdout.print("theme set to {s}\n", .{app.config.theme});
        try io.stdout.flush();
        return true;
    }

    if (std.mem.eql(u8, name, "skills")) {
        const sub = parts.next();
        if (sub != null and std.mem.eql(u8, sub.?, "show")) {
            const requested = parts.next() orelse {
                try io.stdout.writeAll("usage: /skills show <name> [arguments]\n");
                try io.stdout.flush();
                return true;
            };
            var loaded = (try skills.loadByName(app.allocator, requested)) orelse {
                try io.stdout.writeAll("skill not found\n");
                try io.stdout.flush();
                return true;
            };
            defer loaded.deinit(app.allocator);

            const rendered = try skills.renderPrompt(app.allocator, loaded.body, parts.rest());
            defer app.allocator.free(rendered);
            try io.stdout.print("[{s}] {s}\n{s}\n\n", .{
                loaded.info.source,
                loaded.info.name,
                rendered,
            });
            try io.stdout.flush();
            return true;
        }

        if (sub != null and !std.mem.eql(u8, sub.?, "list")) {
            var loaded = (try skills.loadByName(app.allocator, sub.?)) orelse {
                try io.stdout.writeAll("skill not found\n");
                try io.stdout.flush();
                return true;
            };
            defer loaded.deinit(app.allocator);

            const rendered = try skills.renderPrompt(app.allocator, loaded.body, parts.rest());
            errdefer app.allocator.free(rendered);
            try app.setPendingInjectedPrompt(rendered);
            app.allocator.free(rendered);
            try io.stdout.print("running skill {s} [{s}]\n", .{
                loaded.info.name,
                loaded.info.source,
            });
            try io.stdout.flush();
            return true;
        }

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
            try io.stdout.print("{s} [{s}]: {s}\n{s}\n\n", .{ skill.name, skill.source, skill.path, skill.summary });
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

    if (try command_discovery.loadByName(app.allocator, name)) |loaded_command_value| {
        var loaded_command = loaded_command_value;
        defer loaded_command.deinit(app.allocator);
        const rendered = try command_discovery.renderPrompt(app.allocator, loaded_command.body, std.mem.trim(u8, parts.rest(), " \r\t"));
        errdefer app.allocator.free(rendered);
        try app.setPendingInjectedPrompt(rendered);
        app.allocator.free(rendered);
        try io.stdout.print("running external command {s} [{s}]\n", .{
            loaded_command.info.name,
            loaded_command.info.source,
        });
        try io.stdout.flush();
        return true;
    }

    if (try skills.loadByName(app.allocator, name)) |loaded_skill_value| {
        var loaded_skill = loaded_skill_value;
        defer loaded_skill.deinit(app.allocator);
        const rendered = try skills.renderPrompt(app.allocator, loaded_skill.body, parts.rest());
        errdefer app.allocator.free(rendered);
        try app.setPendingInjectedPrompt(rendered);
        app.allocator.free(rendered);
        try io.stdout.print("running skill {s} [{s}]\n", .{
            loaded_skill.info.name,
            loaded_skill.info.source,
        });
        try io.stdout.flush();
        return true;
    }

    try io.stdout.writeAll("unknown command\n");
    try io.stdout.flush();
    return true;
}

pub fn tryBareSkillInvocation(app: *App, line: []const u8, io: CommandIo) !bool {
    const trimmed = std.mem.trim(u8, line, " \r\t");
    if (trimmed.len == 0 or trimmed[0] == '/') return false;

    var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const requested = parts.next() orelse return false;
    var loaded = (try skills.loadByName(app.allocator, requested)) orelse return false;
    defer loaded.deinit(app.allocator);

    const rendered = try skills.renderPrompt(app.allocator, loaded.body, parts.rest());
    errdefer app.allocator.free(rendered);
    try app.setPendingInjectedPrompt(rendered);
    app.allocator.free(rendered);
    try io.stdout.print("running skill {s} [{s}]\n", .{
        loaded.info.name,
        loaded.info.source,
    });
    try io.stdout.flush();
    return true;
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
