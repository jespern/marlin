const std = @import("std");

/// marlin build graph.
///
/// One executable (`marlin`) with subcommands (daemon | attach | run | ls | ...).
/// System C libs (sqlite3, libcurl) are linked here when the modules that use
/// them land (M0); external Zig deps (libvaxis for the TUI in M2, zig-toml)
/// are added to build.zig.zon via `zig fetch --save` when needed.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "marlin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // System C dependencies (present on macOS and virtually all Linux distros).
    exe.root_module.linkSystemLibrary("curl", .{});
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_step = b.step("run", "Build and run marlin");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_exe_tests.step);
}
