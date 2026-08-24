const std = @import("std");

/// marlin build graph.
///
/// Artifacts:
///   marlin           the agent harness (daemon | attach | run | ls | ...)
///   marlin-fakeprov  scripted OpenAI-compat server for e2e tests
///   e2e-runner       orchestrates fakeprov + marlin per scenario
///
/// Steps:
///   zig build            install marlin
///   zig build test       unit + fixture tests
///   zig build e2e        end-to-end: real binary vs fake provider
///   zig build smoke      live tests against real OpenRouter (needs key)
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- marlin ----
    const exe = b.addExecutable(.{
        .name = "marlin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.linkSystemLibrary("curl", .{});
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_step = b.step("run", "Build and run marlin");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ---- unit tests ----
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit + fixture tests");
    test_step.dependOn(&run_exe_tests.step);

    // ---- fake provider ----
    const fakeprov = b.addExecutable(.{
        .name = "marlin-fakeprov",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/fake_provider_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // ---- e2e ----
    const e2e_runner = b.addExecutable(.{
        .name = "e2e-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/e2e_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const e2e_cmd = b.addRunArtifact(e2e_runner);
    e2e_cmd.addArtifactArg(exe);
    e2e_cmd.addArtifactArg(fakeprov);
    e2e_cmd.addDirectoryArg(b.path("src/testing/scenarios"));
    // e2e spawns subprocesses and binds ports; never cache its result.
    e2e_cmd.has_side_effects = true;
    const e2e_step = b.step("e2e", "Run end-to-end scenarios (real binary, fake provider)");
    e2e_step.dependOn(&e2e_cmd.step);

    // ---- live smoke (real OpenRouter; needs OPENROUTER_API_KEY) ----
    const smoke = b.addExecutable(.{
        .name = "smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const smoke_cmd = b.addRunArtifact(smoke);
    smoke_cmd.addArtifactArg(exe);
    smoke_cmd.has_side_effects = true;
    const smoke_step = b.step("smoke", "Live smoke tests against OpenRouter (costs ~$0.01)");
    smoke_step.dependOn(&smoke_cmd.step);
}
