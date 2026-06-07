const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_module = b.createModule(.{
        .root_source_file = b.path("lib/zdu.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zdu", lib_module);
    test_module.addImport("vaxis", vaxis.module("vaxis"));

    const app_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_app_tests = b.addRunArtifact(app_tests);

    const lib_tests = b.addTest(.{
        .root_module = lib_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_app_tests.step);
    test_step.dependOn(&run_lib_tests.step);

    // Integration tests depend on the binary being built first
    const install_step = b.getInstallStep();
    run_app_tests.step.dependOn(install_step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zdu", lib_module);
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));

    const exe = b.addExecutable(.{
        .name = "zdu",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zdu executable");
    run_step.dependOn(&run_cmd.step);

    // Coverage step: run tests under kcov
    const cover_step = b.step("cover", "Generate test coverage report with kcov");
    const run_cover = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-pattern=src/,lib/",
    });
    run_cover.addArg(b.pathJoin(&.{ b.install_path, "cover" }));
    run_cover.addArtifactArg(app_tests);
    cover_step.dependOn(&run_cover.step);
}
