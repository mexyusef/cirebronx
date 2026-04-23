const std = @import("std");

const atomic_write = @import("atomic_write.zig");
const path_util = @import("../util/paths.zig");
const openrouter_pool = @import("../provider/openrouter_pool.zig");

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
    theme: []u8,
    paths: AppPaths,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.model);
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        allocator.free(self.theme);
        self.paths.deinit(allocator);
    }
};

const DiskConfig = struct {
    provider: []const u8 = "openai",
    model: []const u8 = "gpt-4o-mini",
    base_url: []const u8 = "https://api.openai.com/v1/chat/completions",
    api_key: []const u8 = "",
    theme: []const u8 = "bubble",
};

pub const ProviderPreset = enum {
    openai,
    openrouter,
    gemini,
    anthropic,
    groq,
    cerebras,
    huggingface,
};

pub fn defaultConfig(paths: AppPaths) Config {
    return .{
        .provider = @constCast("openai"),
        .model = @constCast("gpt-4o-mini"),
        .base_url = @constCast("https://api.openai.com/v1/chat/completions"),
        .api_key = @constCast(""),
        .theme = @constCast("bubble"),
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
            try applyEnvironmentOverrides(allocator, &cfg);
            try normalizeProviderConfig(allocator, &cfg);
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
    const preset = parseProviderPreset(cfg.provider) orelse .openai;
    switch (preset) {
        .openai => try normalizeOpenAiFamily(allocator, cfg, .{
            .provider = "openai",
            .base_url = "https://api.openai.com/v1/chat/completions",
            .default_model = "gpt-4o-mini",
            .primary_key_env = "OPENAI_API_KEY",
            .secondary_key_env = null,
            .allow_openrouter_pool = true,
        }),
        .openrouter => try normalizeOpenAiFamily(allocator, cfg, .{
            .provider = "openrouter",
            .base_url = "https://openrouter.ai/api/v1/chat/completions",
            .default_model = "openrouter/free",
            .primary_key_env = "OPENROUTER_API_KEY",
            .secondary_key_env = "OPENAI_API_KEY",
            .allow_openrouter_pool = true,
        }),
        .gemini => {
            try normalizeOpenAiFamily(allocator, cfg, .{
                .provider = "gemini",
                .base_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                .default_model = "gemini-2.5-flash",
                .primary_key_env = "GEMINI_API_KEY",
                .secondary_key_env = null,
                .allow_openrouter_pool = false,
            });
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
        .groq => try normalizeOpenAiFamily(allocator, cfg, .{
            .provider = "groq",
            .base_url = "https://api.groq.com/openai/v1/chat/completions",
            .default_model = "llama-3.3-70b-versatile",
            .primary_key_env = "GROQ_API_KEY",
            .secondary_key_env = null,
            .allow_openrouter_pool = false,
        }),
        .cerebras => try normalizeOpenAiFamily(allocator, cfg, .{
            .provider = "cerebras",
            .base_url = "https://api.cerebras.ai/v1/chat/completions",
            .default_model = "gpt-oss-120b",
            .primary_key_env = "CEREBRAS_API_KEY",
            .secondary_key_env = null,
            .allow_openrouter_pool = false,
        }),
        .huggingface => try normalizeOpenAiFamily(allocator, cfg, .{
            .provider = "huggingface",
            .base_url = "https://router.huggingface.co/v1/chat/completions",
            .default_model = "openai/gpt-oss-120b:cerebras",
            .primary_key_env = "HF_TOKEN",
            .secondary_key_env = "HUGGINGFACE_API_KEY",
            .allow_openrouter_pool = false,
        }),
    }
}

pub fn setProviderPreset(allocator: std.mem.Allocator, cfg: *Config, preset: ProviderPreset) !void {
    allocator.free(cfg.provider);
    cfg.provider = try allocator.dupe(u8, providerPresetString(preset));
    allocator.free(cfg.model);
    cfg.model = try allocator.dupe(u8, "");
    allocator.free(cfg.base_url);
    cfg.base_url = try allocator.dupe(u8, "");
    allocator.free(cfg.api_key);
    cfg.api_key = try allocator.dupe(u8, "");
    try normalizeProviderConfig(allocator, cfg);
}

pub fn parseProviderPreset(name: []const u8) ?ProviderPreset {
    if (std.mem.eql(u8, name, "openai-compatible")) return .openai;
    if (std.mem.eql(u8, name, "openai")) return .openai;
    if (std.mem.eql(u8, name, "openrouter")) return .openrouter;
    if (std.mem.eql(u8, name, "gemini")) return .gemini;
    if (std.mem.eql(u8, name, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, name, "groq")) return .groq;
    if (std.mem.eql(u8, name, "cerebras")) return .cerebras;
    if (std.mem.eql(u8, name, "huggingface")) return .huggingface;
    return null;
}

pub fn providerPresetString(preset: ProviderPreset) []const u8 {
    return switch (preset) {
        .openai => "openai",
        .openrouter => "openrouter",
        .gemini => "gemini",
        .anthropic => "anthropic",
        .groq => "groq",
        .cerebras => "cerebras",
        .huggingface => "huggingface",
    };
}

fn applyEnvironmentOverrides(allocator: std.mem.Allocator, cfg: *Config) !void {
    const env_provider = std.process.getEnvVarOwned(allocator, "CIREBRONX_PROVIDER") catch null;
    if (env_provider) |provider| {
        allocator.free(cfg.provider);
        cfg.provider = provider;
    }

    if (cfg.api_key.len == 0) try adoptEnvKey(allocator, cfg, "OPENAI_API_KEY");
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
    const env_theme = std.process.getEnvVarOwned(allocator, "CIREBRONX_THEME") catch null;
    if (env_theme) |theme_name| {
        allocator.free(cfg.theme);
        cfg.theme = theme_name;
    }

    if (cfg.api_key.len == 0) if (try openrouter_pool.firstKey(allocator)) |key| {
        allocator.free(cfg.api_key);
        cfg.api_key = key;
    };
    if (env_base == null and std.mem.eql(u8, cfg.base_url, "https://api.openai.com/v1/chat/completions")) {
        if (try openrouter_pool.defaultBaseUrl(allocator)) |base_url| {
            allocator.free(cfg.base_url);
            cfg.base_url = base_url;
        }
    }
}

const OpenAiFamilyConfig = struct {
    provider: []const u8,
    base_url: []const u8,
    default_model: []const u8,
    primary_key_env: []const u8,
    secondary_key_env: ?[]const u8,
    allow_openrouter_pool: bool,
};

fn normalizeOpenAiFamily(allocator: std.mem.Allocator, cfg: *Config, family: OpenAiFamilyConfig) !void {
    allocator.free(cfg.provider);
    cfg.provider = try allocator.dupe(u8, family.provider);

    allocator.free(cfg.base_url);
    cfg.base_url = try allocator.dupe(u8, family.base_url);

    if (cfg.model.len == 0 or
        std.mem.eql(u8, cfg.model, "gpt-4o-mini") or
        std.mem.eql(u8, cfg.model, "openai/gpt-4o-mini") or
        std.mem.eql(u8, cfg.model, "openrouter/free"))
    {
        allocator.free(cfg.model);
        cfg.model = try allocator.dupe(u8, family.default_model);
    }

    if (cfg.api_key.len == 0) {
        try adoptEnvKey(allocator, cfg, family.primary_key_env);
    }
    if (cfg.api_key.len == 0) {
        if (family.secondary_key_env) |env_name| {
            try adoptEnvKey(allocator, cfg, env_name);
        }
    }
    if (cfg.api_key.len == 0 and family.allow_openrouter_pool) {
        if (try openrouter_pool.firstKey(allocator)) |key| {
            allocator.free(cfg.api_key);
            cfg.api_key = key;
        }
    }
    if (family.allow_openrouter_pool and std.mem.eql(u8, family.provider, "openai")) {
        if (try openrouter_pool.defaultBaseUrl(allocator)) |base_url| {
            allocator.free(cfg.base_url);
            cfg.base_url = base_url;
        }
    }
}

fn adoptEnvKey(allocator: std.mem.Allocator, cfg: *Config, env_name: []const u8) !void {
    const env_key = std.process.getEnvVarOwned(allocator, env_name) catch null;
    if (env_key) |key| {
        allocator.free(cfg.api_key);
        cfg.api_key = key;
    }
}

pub fn save(allocator: std.mem.Allocator, config: *const Config) !void {
    const disk = DiskConfig{
        .provider = config.provider,
        .model = config.model,
        .base_url = config.base_url,
        .api_key = config.api_key,
        .theme = config.theme,
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
        .theme = try allocator.dupe(u8, disk.theme),
        .paths = paths,
    };
}
