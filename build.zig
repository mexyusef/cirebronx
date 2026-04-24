const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ziggy_mod = b.createModule(.{
        .root_source_file = b.path("../ziggy/src/ziggy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fmus_mod = b.createModule(.{
        .root_source_file = b.path("../fmus-zig/src/fmus.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("ziggy", ziggy_mod);
    root_module.addImport("fmus", fmus_mod);

    const exe = b.addExecutable(.{
        .name = "cirebronx",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run cirebronx");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("ziggy", ziggy_mod);
    test_module.addImport("fmus", fmus_mod);

    const exe_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
