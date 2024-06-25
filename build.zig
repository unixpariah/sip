const std = @import("std");
const Scanner = @import("zig-wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = .{ .target = target, .optimize = optimize };

    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    scanner.addCustomProtocol("protocols/wlr-layer-shell-unstable-v1.xml");
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/xdg-output/xdg-output-unstable-v1.xml");
    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 5);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zxdg_output_manager_v1", 3);

    const xkbcommon = b.dependency("zig-xkbcommon", .{}).module("xkbcommon");

    const ziglua = b.dependency("ziglua", opts).module("ziglua");

    const exe = b.addExecutable(.{
        .name = "seto",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();

    const helpers = b.addModule("helpers", .{ .root_source_file = b.path("src/helpers.zig") });

    exe.root_module.addImport("helpers", helpers);
    exe.root_module.addImport("wayland", wayland);
    exe.root_module.addImport("xkbcommon", xkbcommon);
    exe.root_module.addImport("ziglua", ziglua);
    exe.linkSystemLibrary("wayland-protocols");
    exe.linkSystemLibrary("wayland-egl");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("egl");
    exe.linkSystemLibrary("gl");
    exe.linkSystemLibrary("freetype2");

    // TODO: remove when https://github.com/ziglang/zig/issues/131 is implemented
    scanner.addCSource(exe);

    b.installArtifact(exe);

    const root_files = [_][]const u8{
        "src/helpers.zig",
        "src/Tree.zig",
        "src/main.zig",
        "tests/integration.zig",
        "src/config/Grid.zig",
    };

    const unit_tests_step = b.step("test", "Run all tests");
    for (root_files) |file| {
        const test_file = b.addTest(.{ .root_source_file = b.path(file) });
        test_file.root_module.addImport("helpers", helpers);
        unit_tests_step.dependOn(&b.addRunArtifact(test_file).step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run client");
    run_step.dependOn(&run_cmd.step);
}
