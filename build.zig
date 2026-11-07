const std = @import("std");
const Translator = @import("translate_c").Translator;

/// marlin build graph.
///
/// Artifacts:
///   marlin           the agent harness (daemon | attach | run | ls | ...);
///                    the ONLY artifact the default install produces
///   marlin-fakeprov  scripted OpenAI-compat server for e2e tests
///   e2e-runner       orchestrates fakeprov + marlin per scenario
///
/// Steps:
///   zig build            install marlin (and nothing else)
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
fn configurePower(module: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget, macos_sdk: ?[]const u8) void {
    if (target.result.os.tag != .macos) return;
    if (macos_sdk) |sdk| {
        const frameworks = b.pathJoin(&.{ sdk, "System/Library/Frameworks" });
        module.addSystemFrameworkPath(.{ .cwd_relative = frameworks });
    }
    module.linkFramework("IOKit", .{});
    module.linkFramework("CoreFoundation", .{});
}

/// C bindings, translated at build time (`@cImport` is gone in 0.17).
const CBindings = struct {
    sqlite3: *std.Build.Module,
    yaml: *std.Build.Module,

    fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, embedded_sqlite: bool) CBindings {
        const translate_c = b.dependency("translate_c", .{});
        const sqlite3: Translator = .init(translate_c, .{
            .name = "sqlite3_c",
            .c_source_file = b.path("src/daemon/c/sqlite3.h"),
            .target = target,
            .optimize = optimize,
        });
        if (embedded_sqlite) sqlite3.addIncludePath(b.path("vendor/sqlite"));
        const yaml: Translator = .init(translate_c, .{
            .name = "yaml_c",
            .c_source_file = b.path("src/daemon/c/yaml.h"),
            .target = target,
            .optimize = optimize,
        });
        yaml.addIncludePath(b.path("vendor/libyaml"));
        return .{ .sqlite3 = sqlite3.mod, .yaml = yaml.mod };
    }

    fn addTo(self: CBindings, module: *std.Build.Module) void {
        module.addImport("sqlite3_c", self.sqlite3);
        module.addImport("yaml_c", self.yaml);
    }
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
        // macOS ships libsqlite3 in its SDK, so pkg-config adds nothing
        // there, and an old glib pkg-config aborts on `--list-all` when any
        // installed .pc file lacks a field, which fails the whole build.
        const macos = if (module.resolved_target) |target| target.result.os.tag == .macos else false;
        module.linkSystemLibrary("sqlite3", .{ .use_pkg_config = if (macos) .no else .yes });
    }
}

// A real YAML parser for portable Agent Skills frontmatter. Vendored so
// release builds and cross compilation do not depend on a system libyaml.
fn configureYaml(module: *std.Build.Module, b: *std.Build) void {
    module.link_libc = true;
    module.addIncludePath(b.path("vendor/libyaml"));
    module.addCSourceFiles(.{
        .root = b.path("vendor/libyaml"),
        .files = &.{ "api.c", "reader.c", "scanner.c", "parser.c", "loader.c" },
        .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L", "-DYAML_DECLARE_STATIC", "-DYAML_VERSION_STRING=\"0.2.5\"", "-DYAML_VERSION_MAJOR=0", "-DYAML_VERSION_MINOR=2", "-DYAML_VERSION_PATCH=5" },
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // The installed binary is the daily driver: default it to fast so
    // a plain `zig build` can never silently replace it with a Debug build
    // (5-10x slower TUI/JSON/sqlite). Deliberately NOT standardOptimizeOption
    // with preferred_optimize_mode: that replaces -Doptimize with -Drelease
    // and still defaults to Debug, which broke `marlin reboot --build`'s
    // explicit -Doptimize=fast. Unit tests keep their own Debug
    // module below for safety checks and fast compile iteration.
    const optimize = b.option(std.lang.Optimize, "optimize", "Prioritize performance, safety, or binary size") orelse .fast;
    const version = b.option([]const u8, "version", "Marlin version embedded in the binary") orelse "0.0.0-dev";
    // Release binaries carry no debug info: it held build-cache paths whose hashes depend
    // on the build machine's CPU (a dependency builds a code generator for the host), so
    // two builds of the same tag on different x86 runners differed in those paths alone.
    // Stripped, a release rebuilds byte for byte, and is smaller.
    const strip = b.option(bool, "strip", "Omit debug info (default: on unless Debug)") orelse (optimize != .debug);
    const embedded_sqlite = b.option(
        bool,
        "embedded-sqlite",
        "Compile vendored SQLite into Marlin (official releases enable this)",
    ) orelse false;
    // `zig build --sysroot` is gone in 0.17; release builds name the SDK
    // whose frameworks the power assertion links against.
    const macos_sdk = b.option([]const u8, "macos-sdk", "macOS SDK path for framework lookup (release builds)");

    const asset_store = b.createModule(.{ .root_source_file = b.path("src/asset_store.zig"), .target = target });
    const asset_store_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/asset_store.zig"), .target = target, .optimize = .debug }) });
    const asset_store_run = b.addRunArtifact(asset_store_tests);
    b.step("asset-store-test", "Test shared asset verification and caching").dependOn(&asset_store_run.step);
    // ---- source formatting ----
    const format = b.addFmt(.{ .paths = &.{ b.path("src"), b.path("build.zig") } });
    const format_step = b.step("fmt", "Format Zig source");
    format_step.dependOn(&format.step);

    const format_check = b.addFmt(.{
        .paths = &.{ b.path("src"), b.path("build.zig") },
        .check = true,
    });
    const format_check_step = b.step("fmt-check", "Check Zig source formatting");
    format_check_step.dependOn(&format_check.step);

    // ---- marlin ----
    // Terminal emulation for shell sessions (`!!`).
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = optimize });
    // vaxis and libghostty-vt share one uucode package, and a file may belong
    // to only one module, so vaxis uses libghostty's uucode module (whose
    // table config is built for this pairing) instead of making its own.
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize, .external_uucode = true });
    vaxis.module("vaxis").addImport("uucode", ghostty.module("ghostty-vt").import_table.get("uucode").?);
    const regex = b.dependency("regex", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "marlin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
                .{ .name = "regex", .module = regex.module("regex") },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
            },
        }),
    });
    exe.root_module.addImport("asset_store", asset_store);
    const c_bindings: CBindings = .init(b, target, optimize, embedded_sqlite);
    c_bindings.addTo(exe.root_module);
    configureSqlite(exe.root_module, b, embedded_sqlite);
    configureYaml(exe.root_module, b);
    configurePower(exe.root_module, b, target, macos_sdk);
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    const run_step = b.step("run", "Build and run marlin");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
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
    asset_run.addPassthruArgs();
    asset_run.has_side_effects = true;
    b.step("mk64-import", "Regenerate the versioned MK64 asset bundle from the USA ROM").dependOn(&asset_run.step);
    const mk64_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/mk64/root.zig"),
        .target = target,
        .optimize = .debug,
    }) });
    mk64_tests.root_module.addImport("asset_store", asset_store);
    b.step("mk64-test", "Test the pure-Zig MK64 port").dependOn(&b.addRunArtifact(mk64_tests).step);

    // ---- wipEout port tests ----
    const wipeout_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wipeout/root.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    wipeout_tests.root_module.addImport("asset_store", asset_store);
    const wipeout_test_step = b.step("wipeout-test", "Run wipEout port unit tests");
    wipeout_test_step.dependOn(&b.addRunArtifact(wipeout_tests).step);

    // ---- unit tests ----
    // Dedicated Debug module: safety checks stay on and test compiles stay
    // fast regardless of the install optimize mode.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            .{ .name = "regex", .module = regex.module("regex") },
            .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
        },
    });
    test_module.addImport("asset_store", asset_store);
    CBindings.init(b, target, .debug, embedded_sqlite).addTo(test_module);
    configureSqlite(test_module, b, embedded_sqlite);
    configureYaml(test_module, b);
    configurePower(test_module, b, target, macos_sdk);
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
    fake_model_cmd.addArgs(&.{ "--port", "5757", "--repeat-last", "--default-scenario" });
    fake_model_cmd.addFileArg(b.path("src/testing/fixtures/local_testing.json"));
    fake_model_cmd.addPassthruArgs();
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
