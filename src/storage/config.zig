const std = @import("std");

const atomic_write = @import("atomic_write.zig");
const path_util = @import("../util/paths.zig");

pub const AppPaths = struct {
    home_dir: []u8,
    app_dir: []u8,
    config_path: []u8,
    sessions_dir: []u8,
    histories_dir: []u8,

    pub fn deinit(self: *const AppPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.home_dir);
        allocator.free(self.app_dir);
        allocator.free(self.config_path);
        allocator.free(self.sessions_dir);
        allocator.free(self.histories_dir);
    }
};

pub const Config = struct {
    provider: []u8,
    model: []u8,
    base_url: []u8,
    api_key: []u8,
    paths: AppPaths,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.model);
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        self.paths.deinit(allocator);
    }
};

const DiskConfig = struct {
    provider: []const u8 = "openai-compatible",
    model: []const u8 = "gpt-4o-mini",
    base_url: []const u8 = "https://api.openai.com/v1/chat/completions",
    api_key: []const u8 = "",
};

pub const ProviderPreset = enum {
    openai_compatible,
    gemini,
    anthropic,
};

pub fn defaultConfig(paths: AppPaths) Config {
    return .{
        .provider = @constCast("openai-compatible"),
        .model = @constCast("gpt-4o-mini"),
        .base_url = @constCast("https://api.openai.com/v1/chat/completions"),
        .api_key = @constCast(""),
        .paths = paths,
    };
}

pub fn ownedDefaultConfig(allocator: std.mem.Allocator, paths: AppPaths) !Config {
    return try ownedFromDiskConfig(allocator, paths, .{});
}

pub fn loadOrCreate(allocator: std.mem.Allocator) !Config {
    const paths = try path_util.resolveAppPaths(allocator);
    std.fs.makeDirAbsolute(paths.app_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(paths.sessions_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(paths.histories_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const cwd = std.fs.cwd();
    const file = cwd.openFile(paths.config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            var cfg = try ownedFromDiskConfig(allocator, paths, .{});
            try save(allocator, &cfg);
            return cfg;
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(DiskConfig, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var cfg = try ownedFromDiskConfig(allocator, paths, parsed.value);
    try applyEnvironmentOverrides(allocator, &cfg);
    try normalizeProviderConfig(allocator, &cfg);
    return cfg;
}

pub fn normalizeProviderConfig(allocator: std.mem.Allocator, cfg: *Config) !void {
    const preset = parseProviderPreset(cfg.provider) orelse .openai_compatible;
    switch (preset) {
        .openai_compatible => {
            if (cfg.base_url.len == 0) {
                allocator.free(cfg.base_url);
                cfg.base_url = try allocator.dupe(u8, "https://api.openai.com/v1/chat/completions");
            }
        },
        .gemini => {
            allocator.free(cfg.provider);
            cfg.provider = try allocator.dupe(u8, "gemini");

            allocator.free(cfg.base_url);
            cfg.base_url = try allocator.dupe(u8, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions");

            if (cfg.model.len == 0 or std.mem.eql(u8, cfg.model, "gpt-4o-mini")) {
                allocator.free(cfg.model);
                cfg.model = try allocator.dupe(u8, "gemini-2.5-flash");
            }

            if (cfg.api_key.len == 0) {
                const gemini_key = std.process.getEnvVarOwned(allocator, "GEMINI_API_KEY") catch null;
                if (gemini_key) |key| {
                    allocator.free(cfg.api_key);
                    cfg.api_key = key;
                }
            }
        },
        .anthropic => {
            allocator.free(cfg.provider);
            cfg.provider = try allocator.dupe(u8, "anthropic");

            allocator.free(cfg.base_url);
            cfg.base_url = try allocator.dupe(u8, "https://api.anthropic.com/v1/messages");

            if (cfg.model.len == 0 or std.mem.eql(u8, cfg.model, "gpt-4o-mini")) {
                allocator.free(cfg.model);
                cfg.model = try allocator.dupe(u8, "claude-sonnet-4-20250514");
            }

            if (cfg.api_key.len == 0) {
                const anthropic_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch null;
                if (anthropic_key) |key| {
                    allocator.free(cfg.api_key);
                    cfg.api_key = key;
                }
            }
        },
    }
}

pub fn setProviderPreset(allocator: std.mem.Allocator, cfg: *Config, preset: ProviderPreset) !void {
    allocator.free(cfg.provider);
    cfg.provider = try allocator.dupe(u8, providerPresetString(preset));
    try normalizeProviderConfig(allocator, cfg);
}

pub fn parseProviderPreset(name: []const u8) ?ProviderPreset {
    if (std.mem.eql(u8, name, "openai-compatible")) return .openai_compatible;
    if (std.mem.eql(u8, name, "openai")) return .openai_compatible;
    if (std.mem.eql(u8, name, "gemini")) return .gemini;
    if (std.mem.eql(u8, name, "anthropic")) return .anthropic;
    return null;
}

pub fn providerPresetString(preset: ProviderPreset) []const u8 {
    return switch (preset) {
        .openai_compatible => "openai-compatible",
        .gemini => "gemini",
        .anthropic => "anthropic",
    };
}

fn applyEnvironmentOverrides(allocator: std.mem.Allocator, cfg: *Config) !void {
    const env_provider = std.process.getEnvVarOwned(allocator, "CIREBRONX_PROVIDER") catch null;
    if (env_provider) |provider| {
        allocator.free(cfg.provider);
        cfg.provider = provider;
    }

    if (cfg.api_key.len == 0) {
        const env_key = std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch null;
        if (env_key) |key| {
            allocator.free(cfg.api_key);
            cfg.api_key = key;
        }
    }
    const env_model = std.process.getEnvVarOwned(allocator, "OPENAI_MODEL") catch null;
    if (env_model) |model| {
        allocator.free(cfg.model);
        cfg.model = model;
    }
    const env_base = std.process.getEnvVarOwned(allocator, "OPENAI_BASE_URL") catch null;
    if (env_base) |base| {
        allocator.free(cfg.base_url);
        cfg.base_url = base;
    }
}

pub fn save(allocator: std.mem.Allocator, config: *const Config) !void {
    const disk = DiskConfig{
        .provider = config.provider,
        .model = config.model,
        .base_url = config.base_url,
        .api_key = config.api_key,
    };

    const json = try std.json.Stringify.valueAlloc(allocator, disk, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(json);

    std.fs.makeDirAbsolute(config.paths.app_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try atomic_write.writeFileAbsolute(config.paths.config_path, json);
}

fn ownedFromDiskConfig(
    allocator: std.mem.Allocator,
    paths: AppPaths,
    disk: DiskConfig,
) !Config {
    return .{
        .provider = try allocator.dupe(u8, disk.provider),
        .model = try allocator.dupe(u8, disk.model),
        .base_url = try allocator.dupe(u8, disk.base_url),
        .api_key = try allocator.dupe(u8, disk.api_key),
        .paths = paths,
    };
}
