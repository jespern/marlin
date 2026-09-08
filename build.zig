const std = @import("std");

/// marlin build graph.
///
/// Artifacts:
///   marlin           the agent harness (daemon | attach | run | ls | ...);
///                    the ONLY artifact the default install produces
///   marlin-fakeprov  scripted OpenAI-compat server for e2e tests
///   e2e-runner       orchestrates fakeprov + marlin per scenario
///   *-probe          offline renderers for the games/effects (dev tools)
///
/// Steps:
///   zig build            install marlin (and nothing else)
///   zig build tools      also install the probes and marlin-fakeprov
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
    "-DSQLITE_ENABLE_FTS5",
};

/// The daemon's scoped idle-sleep assertion (src/daemon/power.zig) calls
/// IOKit/CoreFoundation directly; other platforms compile it as a no-op and
/// link nothing extra.
fn configurePower(module: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .macos) return;
    if (b.sysroot) |sysroot| {
        const frameworks = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" });
        module.addSystemFrameworkPath(.{ .cwd_relative = frameworks });
    }
    module.linkFramework("IOKit", .{});
    module.linkFramework("CoreFoundation", .{});
}

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

    const asset_store = b.createModule(.{ .root_source_file = b.path("src/asset_store.zig"), .target = target });
    const asset_store_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/asset_store.zig"), .target = target, .optimize = .Debug }) });
    const asset_store_run = b.addRunArtifact(asset_store_tests);
    b.step("asset-store-test", "Test shared asset verification and caching").dependOn(&asset_store_run.step);
    // ---- source formatting ----
    const format = b.addFmt(.{ .paths = &.{ "src", "build.zig" } });
    const format_step = b.step("fmt", "Format Zig source");
    format_step.dependOn(&format.step);

    const format_check = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });
    const format_check_step = b.step("fmt-check", "Check Zig source formatting");
    format_check_step.dependOn(&format_check.step);

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
    exe.root_module.addImport("asset_store", asset_store);
    configureSqlite(exe.root_module, b, embedded_sqlite);
    configurePower(exe.root_module, b, target);
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    const run_step = b.step("run", "Build and run marlin");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ---- Pure-Zig Mario Kart 64 port ----
    const mk64_module = b.createModule(.{
        .root_source_file = b.path("src/mk64/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mk64_module.addImport("asset_store", asset_store);
    const asset_import = b.addExecutable(.{
        .name = "mk64-import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/mk64_import.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mk64", .module = mk64_module }},
        }),
    });
    const asset_run = b.addRunArtifact(asset_import);
    if (b.args) |args| asset_run.addArgs(args);
    asset_run.has_side_effects = true;
    b.step("mk64-import", "Regenerate the versioned MK64 asset bundle from the USA ROM").dependOn(&asset_run.step);
    const mk64_probe = b.addExecutable(.{
        .name = "mk64-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/mk64_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mk64", .module = mk64_module }},
        }),
    });
    const mk64_run = b.addRunArtifact(mk64_probe);
    if (b.args) |args| mk64_run.addArgs(args);
    mk64_run.has_side_effects = true;
    b.step("mk64-probe", "Render Luigi Raceway from a US ROM to PPM").dependOn(&mk64_run.step);
    const mk64_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/mk64/root.zig"),
        .target = target,
        .optimize = .Debug,
    }) });
    mk64_tests.root_module.addImport("asset_store", asset_store);
    b.step("mk64-test", "Test the pure-Zig MK64 port").dependOn(&b.addRunArtifact(mk64_tests).step);

    // ---- wipEout port probe ----
    const wipeout_module = b.createModule(.{
        .root_source_file = b.path("src/wipeout/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    wipeout_module.addImport("asset_store", asset_store);
    const wipeout_probe = b.addExecutable(.{
        .name = "wipeout-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/wipeout_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wipeout", .module = wipeout_module },
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            },
        }),
    });
    const wipeout_probe_cmd = b.addRunArtifact(wipeout_probe);
    if (b.args) |args| wipeout_probe_cmd.addArgs(args);
    wipeout_probe_cmd.has_side_effects = true;
    const wipeout_probe_step = b.step("wipeout-probe", "Run the wipEout track renderer probe");
    wipeout_probe_step.dependOn(&wipeout_probe_cmd.step);

    const wipeout_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wipeout/root.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    wipeout_tests.root_module.addImport("asset_store", asset_store);
    const wipeout_test_step = b.step("wipeout-test", "Run wipEout port unit tests");
    wipeout_test_step.dependOn(&b.addRunArtifact(wipeout_tests).step);

    // ---- orb probe: offline frames of the orb screensaver ----
    const orb_module = b.createModule(.{
        .root_source_file = b.path("src/client/orb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vaxis", .module = vaxis.module("vaxis") }},
    });
    const orb_probe = b.addExecutable(.{
        .name = "orb-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/orb_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "orb", .module = orb_module }},
        }),
    });
    const orb_probe_cmd = b.addRunArtifact(orb_probe);
    if (b.args) |args| orb_probe_cmd.addArgs(args);
    orb_probe_cmd.has_side_effects = true;
    b.step("orb-probe", "Render orb screensaver frames to PPM").dependOn(&orb_probe_cmd.step);

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
    test_module.addImport("asset_store", asset_store);
    configureSqlite(test_module, b, embedded_sqlite);
    configurePower(test_module, b, target);
    test_module.addOptions("build_options", build_options);
    const exe_tests = b.addTest(.{ .root_module = test_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit + fixture tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&asset_store_run.step);

    // ---- fake provider ----
    const fakeprov = b.addExecutable(.{
        .name = "marlin-fakeprov",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/fake_provider_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const fake_model_cmd = b.addRunArtifact(fakeprov);
    fake_model_cmd.addArgs(&.{ "--port", "5757", "--repeat-last" });
    if (b.args) |args|
        fake_model_cmd.addArgs(args)
    else
        fake_model_cmd.addFileArg(b.path("src/testing/fixtures/local_testing.json"));
    fake_model_cmd.has_side_effects = true;
    const fake_model_step = b.step("fake-model", "Run the scripted local/testing model on 127.0.0.1:5757");

    // ---- dev tools ----
    // `zig build` installs marlin and nothing else: a release must never
    // depend on a dev tool compiling for every target (the x86-64 release
    // once failed on a 128-bit atomic in wipeout-probe). The probes and the
    // fake provider are still one step away when wanted.
    const tools_step = b.step("tools", "Install dev tools into zig-out/bin: wipeout-probe, mk64-probe, orb-probe, marlin-fakeprov");
    tools_step.dependOn(&b.addInstallArtifact(wipeout_probe, .{}).step);
    tools_step.dependOn(&b.addInstallArtifact(mk64_probe, .{}).step);
    tools_step.dependOn(&b.addInstallArtifact(orb_probe, .{}).step);
    tools_step.dependOn(&b.addInstallArtifact(fakeprov, .{}).step);
    fake_model_step.dependOn(&fake_model_cmd.step);

    const mobile_tests = b.addSystemCommand(&.{ "node", "--test" });
    mobile_tests.addFileArg(b.path("src/mobile/push_test.cjs"));
    b.step("mobile-test", "Test optional phone push helper (Node.js 22+)").dependOn(&mobile_tests.step);

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
