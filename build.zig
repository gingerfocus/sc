const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // We will also create a module for our other entry point, 'main.zig'.
    const screen = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    screen.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "screen",
        .root_module = screen,
    });
    b.installArtifact(exe);

    // ------------------------------------------------------------------------

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------------------

    const tests = b.addTest(.{
        .root_module = screen,
        .target = target,
        .optimize = optimize,
    });
    const testRun = b.addRunArtifact(tests);
    const testStep = b.step("test", "Run all tests");
    testStep.dependOn(&testRun.step);

    // ------------------------------------------------------------------------
    const docsInstall = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docsStep = b.step("docs", "Copy documentation artifacts to prefix path");
    docsStep.dependOn(&docsInstall.step);

    const docsOpenStep = b.step("docs-open", "Open the docs in a browser");
    const serverRun = b.addSystemCommand(&.{ "python3", "-m", "http.server", "-d" });
    serverRun.addFileArg(exe.getEmittedDocs());

    const openRun = b.addSystemCommand(&.{ "xdg-open", "http://localhost:8000" });
    serverRun.step.dependOn(&openRun.step);
    docsOpenStep.dependOn(&serverRun.step);
}
