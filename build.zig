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
///   zig build fake-model run local/testing's deterministic fake server
///   zig build smoke      live tests against real OpenRouter (needs key)
const sqlite_flags = &.{
    "-std=c99",
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_DQS=0",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_USE_URI",
};

fn configureSqlite(module: *std.Build.Module, b: *std.Build, embedded: bool) void {
    module.link_libc = true;
    if (embedded) {
        module.addIncludePath(b.path("vendor/sqlite"));
        module.addCSourceFile(.{
            .file = b.path("vendor/sqlite/sqlite3.c"),
            .flags = sqlite_flags,
        });
    } else {
        module.linkSystemLibrary("sqlite3", .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // The installed binary is the daily driver: default it to ReleaseFast so
    // a plain `zig build` can never silently replace it with a Debug build
    // (5-10x slower TUI/JSON/sqlite). Deliberately NOT standardOptimizeOption
    // with preferred_optimize_mode: that replaces -Doptimize with -Drelease
    // and still defaults to Debug, which broke `marlin reboot --build`'s
    // explicit -Doptimize=ReleaseFast. Unit tests keep their own Debug
    // module below for safety checks and fast compile iteration.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;
    const version = b.option([]const u8, "version", "Marlin version embedded in the binary") orelse "0.0.0-dev";
    const embedded_sqlite = b.option(
        bool,
        "embedded-sqlite",
        "Compile vendored SQLite into Marlin (official releases enable this)",
    ) orelse false;

    // ---- marlin ----
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const regex = b.dependency("regex", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "marlin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
                .{ .name = "regex", .module = regex.module("regex") },
            },
        }),
    });
    configureSqlite(exe.root_module, b, embedded_sqlite);
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    const run_step = b.step("run", "Build and run marlin");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ---- unit tests ----
    // Dedicated Debug module: safety checks stay on and test compiles stay
    // fast regardless of the install optimize mode.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            .{ .name = "regex", .module = regex.module("regex") },
        },
    });
    configureSqlite(test_module, b, embedded_sqlite);
    test_module.addOptions("build_options", build_options);
    const exe_tests = b.addTest(.{ .root_module = test_module });
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
    // Installed too: handy for driving the TUI manually against a script.
    b.installArtifact(fakeprov);

    const fake_model_cmd = b.addRunArtifact(fakeprov);
    fake_model_cmd.addArgs(&.{ "--port", "5757", "--repeat-last" });
    if (b.args) |args|
        fake_model_cmd.addArgs(args)
    else
        fake_model_cmd.addFileArg(b.path("src/testing/fixtures/local_testing.json"));
    fake_model_cmd.has_side_effects = true;
    const fake_model_step = b.step("fake-model", "Run the scripted local/testing model on 127.0.0.1:5757");
    fake_model_step.dependOn(&fake_model_cmd.step);

    // ---- e2e ----
    const process_io_module = b.createModule(.{
        .root_source_file = b.path("src/daemon/process_io.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const proto_module = b.createModule(.{
        .root_source_file = b.path("src/core/proto.zig"),
        .target = target,
        .optimize = optimize,
    });
    const e2e_runner = b.addExecutable(.{
        .name = "e2e-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/e2e_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "process_io", .module = process_io_module },
                .{ .name = "proto", .module = proto_module },
            },
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

    // ---- reboot convergence (reboot vs kill-9 must restore identical state) ----
    const conv_cmd = b.addSystemCommand(&.{"src/testing/reboot_convergence.sh"});
    conv_cmd.addArtifactArg(exe);
    conv_cmd.addArtifactArg(fakeprov);
    conv_cmd.addFileArg(b.path("src/testing/scenarios/09_reboot_resume.json"));
    conv_cmd.has_side_effects = true;
    const conv_step = b.step("converge", "Verify reboot vs kill-9 restore identical state");
    conv_step.dependOn(&conv_cmd.step);

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
