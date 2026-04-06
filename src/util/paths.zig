const std = @import("std");

const config_mod = @import("../storage/config.zig");

pub fn resolveAppPaths(allocator: std.mem.Allocator) !config_mod.AppPaths {
    const home_dir = try resolveHomeDir(allocator);
    const app_dir = try std.fmt.allocPrint(allocator, "{s}{c}.cirebronx", .{
        home_dir,
        std.fs.path.sep,
    });
    const config_path = try std.fmt.allocPrint(allocator, "{s}{c}config.json", .{
        app_dir,
        std.fs.path.sep,
    });
    const sessions_dir = try std.fmt.allocPrint(allocator, "{s}{c}sessions", .{
        app_dir,
        std.fs.path.sep,
    });
    const histories_dir = try std.fmt.allocPrint(allocator, "{s}{c}histories", .{
        app_dir,
        std.fs.path.sep,
    });

    return .{
        .home_dir = home_dir,
        .app_dir = app_dir,
        .config_path = config_path,
        .sessions_dir = sessions_dir,
        .histories_dir = histories_dir,
    };
}

fn resolveHomeDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        return home;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |profile| {
        return profile;
    } else |_| {}

    return error.HomeDirectoryNotFound;
}
