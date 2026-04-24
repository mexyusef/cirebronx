const std = @import("std");

const cli = @import("cli/args.zig");
const app_server = @import("app_server/server.zig");
const repl = @import("cli/repl.zig");
const tui = @import("cli/tui.zig");
const app_mod = @import("core/app.zig");
const commands = @import("commands/registry.zig");
const permissions_mod = @import("core/permissions.zig");
const provider_adapter = @import("provider/adapter.zig");
const anthropic_provider = @import("provider/anthropic_client.zig");
const openrouter_pool = @import("provider/openrouter_pool.zig");
const provider_types = @import("provider/types.zig");
const mcp_client = @import("mcp/client.zig");
const config_mod = @import("storage/config.zig");
const mcp_storage = @import("storage/mcp.zig");
const session_mod = @import("storage/session.zig");
const atomic_write = @import("storage/atomic_write.zig");
const plugins_mod = @import("plugins/registry.zig");
const skills_mod = @import("skills/discovery.zig");
const tools_mod = @import("tools/registry.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer openrouter_pool.deinitGlobal(allocator);

    const parsed = try cli.parseArgs(allocator);
    defer parsed.deinit(allocator);

    if (parsed.command == .help) {
        try cli.printHelp();
        return;
    }

    if (parsed.command == .version) {
        try cli.printVersion();
        return;
    }

    var app = try app_mod.App.init(allocator);
    defer app.deinit();

    const loaded_config = try config_mod.loadOrCreate(allocator);
    app.config.deinit(allocator);
    app.config = loaded_config;

    runParsedCommand(&app, allocator, parsed.command, parsed.prompt, parsed.session_id, parsed.port) catch |err| {
        switch (err) {
            error.ProviderRequestFailed, error.MissingApiKey => std.process.exit(1),
            else => return err,
        }
    };
}

fn runParsedCommand(
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    command: cli.Command,
    prompt: ?[]const u8,
    session_id: ?[]const u8,
    port: ?u16,
) !void {
    if (command == .chat) {
        try repl.runSingleShot(app, prompt.?);
    } else if (command == .tui) {
        try tui.runInteractive(app);
    } else if (command == .app_server) {
        try app_server.run(app, port orelse app_server.default_port);
    } else if (command == .resume_session) {
        var loaded = try session_mod.loadSession(allocator, app.config.paths, session_id.?);
        defer loaded.deinit(allocator);
        try app.replaceSession(loaded.id, loaded.model, loaded.messages);
        try tui.runInteractive(app);
    } else if (command == .interactive) {
        try repl.runInteractive(app);
    } else {
        unreachable;
    }
}

test "main imports compile" {
    _ = cli;
    _ = app_server;
    _ = repl;
    _ = tui;
    _ = app_mod;
    _ = commands;
    _ = permissions_mod;
    _ = provider_adapter;
    _ = anthropic_provider;
    _ = provider_types;
    _ = mcp_client;
    _ = config_mod;
    _ = mcp_storage;
    _ = session_mod;
    _ = atomic_write;
    _ = plugins_mod;
    _ = skills_mod;
    _ = tools_mod;
}
