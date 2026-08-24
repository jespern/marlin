//! e2e runner: drives the REAL marlin binary against the fake provider.
//!
//! Invoked by `zig build e2e` with paths to both binaries. For each scenario
//! in src/testing/scenarios/:
//!   1. spawn marlin-fakeprov <scenario.json>, read "PORT <n>"
//!   2. spawn marlin with an isolated $XDG_STATE_HOME (temp dir) and
//!      MARLIN_BASE_URL_OPENROUTER=http://127.0.0.1:<port>/v1
//!   3. assert marlin's exit code + stdout expectations (from the scenario's
//!      companion "check" object)
//!   4. assert fake provider exited 0 (all request expectations matched)
//!   5. optionally assert on the session DB via sqlite3 CLI queries
//!
//! Scenario files may carry a "check" object (ignored by the fake provider):
//!   "check": {
//!     "argv": ["run", "--quiet", "task text"],   // marlin args
//!     "env": {"EXTRA": "VAR"},                    // extra env for marlin
//!     "exit_code": 0,
//!     "stdout_contains": ["hello"],
//!     "db_kinds": ["user_msg","assistant_msg"],   // expected block kinds, in order
//!     "runs": 1,                                  // repeat marlin N times (for --continue tests)
//!     "session_handle_flow": true                 // exercise ls/prefix/archive/unarchive
//!   }
//! For runs > 1, "argv2" gives the second invocation's args.

const std = @import("std");
const Io = std.Io;
const temp_dir = @import("temp_dir.zig");
const TempDir = temp_dir.Dir;

const Check = struct {
    argv: []const []const u8,
    argv2: []const []const u8 = &.{},
    env: std.json.ArrayHashMap([]const u8) = .{},
    exit_code: u8 = 0,
    stdout_contains: []const []const u8 = &.{},
    stderr_contains: []const []const u8 = &.{},
    db_kinds: []const []const u8 = &.{},
    /// Expected durable session hierarchy rows:
    /// kind|has_parent|has_parent_block|max_rounds.
    db_session_meta: []const []const u8 = &.{},
    runs: u8 = 1,
    /// Optional per-scenario M5 config and executable hook fixture.
    config_toml: ?[]const u8 = null,
    hook_script: ?[]const u8 = null,
    mcp_script: ?[]const u8 = null,
    hook_output_contains: ?[]const u8 = null,
    session_handle_flow: bool = false,
};

const ScenarioFile = struct {
    steps: std.json.Value = .null, // consumed by the fake provider, opaque here
    check: Check,
};

var failures: u32 = 0;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.log.err("usage: e2e_runner <marlin-bin> <fakeprov-bin> <scenarios-dir>", .{});
        return 2;
    }
    // Build-system artifact args may be relative to the runner's original
    // cwd. Resolve them before each scenario moves Marlin into its isolated
    // working directory.
    const marlin_bin = try Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    const fakeprov_bin = try Io.Dir.cwd().realPathFileAlloc(io, args[2], arena);
    const scenarios_dir = args[3];
    const temp_root = temp_dir.rootFromEnvironment(init.environ_map.get("TMPDIR"));

    var dir = Io.Dir.cwd().openDir(io, scenarios_dir, .{ .iterate = true }) catch |e| {
        std.log.err("cannot open scenarios dir '{s}': {t}", .{ scenarios_dir, e });
        return 2;
    };
    defer dir.close(io);

    // Collect scenario file names, sorted for deterministic order.
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    if (names.items.len == 0) {
        std.log.err("no scenarios found in {s}", .{scenarios_dir});
        return 2;
    }

    for (names.items) |name| {
        runScenario(gpa, io, arena, marlin_bin, fakeprov_bin, scenarios_dir, temp_root, name) catch |e| {
            failures += 1;
            print(io, "FAIL {s}: {t}\n", .{ name, e });
        };
    }

    if (failures > 0) {
        print(io, "\ne2e: {d}/{d} scenarios FAILED\n", .{ failures, names.items.len });
        return 1;
    }
    print(io, "\ne2e: all {d} scenarios passed\n", .{names.items.len});
    return 0;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn runScenario(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    marlin_bin: []const u8,
    fakeprov_bin: []const u8,
    scenarios_dir: []const u8,
    temp_root: []const u8,
    name: []const u8,
) !void {
    print(io, "e2e {s} ... ", .{name});

    const scenario_path = try std.fs.path.join(arena, &.{ scenarios_dir, name });
    const scenario_bytes = try Io.Dir.cwd().readFileAlloc(io, scenario_path, arena, .limited(4 * 1024 * 1024));
    const sf = try std.json.parseFromSliceLeaky(ScenarioFile, arena, scenario_bytes, .{
        .ignore_unknown_fields = true,
    });

    // Temp state and working directory for this scenario (unique per run).
    // Keeping both beneath TMPDIR makes the runner safe inside Marlin's own
    // Seatbelt profile and prevents file-tool fixtures leaking into the repo.
    var temp = try TempDir.init(gpa, io, temp_root, "marlin-e2e");
    defer temp.deinit();
    const state_dir = temp.path;

    if (sf.check.config_toml) |contents| {
        const config_dir = try std.fs.path.join(arena, &.{ state_dir, ".config", "marlin" });
        try Io.Dir.cwd().createDirPath(io, config_dir);
        const config_path = try std.fs.path.join(arena, &.{ config_dir, "config.toml" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = contents });
    }
    if (sf.check.hook_script) |contents| {
        const hook_path = try std.fs.path.join(arena, &.{ state_dir, "hook.sh" });
        try writeExecutable(gpa, io, hook_path, contents);
    }
    if (sf.check.mcp_script) |contents| {
        const mcp_path = try std.fs.path.join(arena, &.{ state_dir, "mcp.sh" });
        try writeExecutable(gpa, io, mcp_path, contents);
    }

    // 1. Spawn the fake provider; read PORT line.
    var prov = try std.process.spawn(io, .{
        .argv = &.{ fakeprov_bin, scenario_path },
        .stdout = .pipe,
        .stderr = .inherit,
    });
    // Ensure cleanup even on failure paths.
    var prov_done = false;
    defer if (!prov_done) {
        prov.kill(io);
    };

    var port_buf: [64]u8 = undefined;
    var prov_reader = prov.stdout.?.reader(io, &port_buf);
    const port_line = try prov_reader.interface.takeDelimiterExclusive('\n');
    if (!std.mem.startsWith(u8, port_line, "PORT ")) return error.NoPortLine;
    const port = try std.fmt.parseInt(u16, std.mem.trim(u8, port_line[5..], " \r\n"), 10);

    const base_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/v1", .{port});

    // 2. Environment for marlin: isolated state, socket, fake endpoint.
    var env = std.process.Environ.Map.init(arena);
    try env.put("HOME", state_dir); // nothing should use it, but be safe
    try env.put("TMPDIR", state_dir);
    try env.put("XDG_STATE_HOME", state_dir);
    const sock_path = try std.fmt.allocPrint(arena, "{s}/daemon.sock", .{state_dir});
    try env.put("MARLIN_SOCKET", sock_path);
    try env.put("MARLIN_BASE_URL_OPENROUTER", base_url);
    try env.put("OPENROUTER_API_KEY", "test-key-e2e");
    try env.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    // Fixtures assert the LEGACY approval transcript (an M3.5 exit
    // criterion). Capability permissions are pinned off; a scenario that
    // wants them sets MARLIN_PERMISSIONS=1 in its own "env" map below.
    try env.put("MARLIN_PERMISSIONS", "0");
    // Production's generated starter config subscribes to a remote feed.
    // Fake-provider scenarios stay hermetic unless their own env opts in.
    try env.put("MARLIN_NETWORK_BLOCKLISTS", "");
    var env_it = sf.check.env.map.iterator();
    while (env_it.next()) |kv| {
        try env.put(kv.key_ptr.*, kv.value_ptr.*);
    }
    // Always stop the per-scenario daemon (autostarted by marlin run).
    defer {
        const res = std.process.run(gpa, io, .{
            .argv = &.{ marlin_bin, "shutdown" },
            .environ_map = &env,
            .cwd = .{ .path = state_dir },
            .stdout_limit = .limited(64 * 1024),
        }) catch null;
        if (res) |r| {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
    }

    // 3. Run marlin (1 or 2 invocations).
    var runs: u8 = 0;
    while (runs < sf.check.runs) : (runs += 1) {
        const argv_cfg = if (runs == 0) sf.check.argv else sf.check.argv2;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, marlin_bin);
        for (argv_cfg) |a| try argv.append(arena, a);

        const res = try std.process.run(gpa, io, .{
            .argv = argv.items,
            .environ_map = &env,
            .cwd = .{ .path = state_dir },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        });
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);

        const is_last = runs == sf.check.runs - 1;
        if (is_last) {
            const code: u8 = switch (res.term) {
                .exited => |c| c,
                else => 255,
            };
            if (code != sf.check.exit_code) {
                print(io, "\n  marlin exit {d}, want {d}\n  stdout: {s}\n  stderr: {s}\n", .{
                    code,                                      sf.check.exit_code,
                    res.stdout[0..@min(res.stdout.len, 2000)], res.stderr[0..@min(res.stderr.len, 2000)],
                });
                return error.ExitCodeMismatch;
            }
            for (sf.check.stdout_contains) |needle| {
                if (std.mem.indexOf(u8, res.stdout, needle) == null) {
                    print(io, "\n  stdout missing '{s}'\n  stdout: {s}\n", .{
                        needle, res.stdout[0..@min(res.stdout.len, 2000)],
                    });
                    return error.StdoutMismatch;
                }
            }
            for (sf.check.stderr_contains) |needle| {
                if (std.mem.indexOf(u8, res.stderr, needle) == null) {
                    print(io, "\n  stderr missing '{s}'\n  stderr: {s}\n", .{
                        needle, res.stderr[0..@min(res.stderr.len, 2000)],
                    });
                    return error.StderrMismatch;
                }
            }
        }
    }

    if (sf.check.hook_output_contains) |needle| {
        const hook_output = try std.fs.path.join(arena, &.{ state_dir, "hook-events" });
        var attempts: u8 = 0;
        while (attempts < 50) : (attempts += 1) {
            const contents = Io.Dir.cwd().readFileAlloc(io, hook_output, gpa, .limited(256 * 1024)) catch {
                io.sleep(.fromMilliseconds(20), .awake) catch {};
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, needle) != null) break;
            io.sleep(.fromMilliseconds(20), .awake) catch {};
        } else {
            return error.HookOutputMissing;
        }
    }

    // 4. Fake provider must have consumed all steps and validated them.
    const prov_term = try prov.wait(io);
    prov_done = true;
    switch (prov_term) {
        .exited => |c| if (c != 0) return error.ProviderExpectationsFailed,
        else => return error.ProviderCrashed,
    }

    if (sf.check.session_handle_flow) {
        try checkSessionHandleFlow(gpa, io, marlin_bin, &env, state_dir);
    }

    // 5. DB assertions via the sqlite3 CLI (avoids linking sqlite here).
    if (sf.check.db_kinds.len > 0) {
        const db_path = try std.fmt.allocPrint(arena, "{s}/marlin/marlin.db", .{state_dir});
        const res = try std.process.run(gpa, io, .{
            .argv = &.{ "sqlite3", db_path, "SELECT kind FROM blocks ORDER BY seq;" },
            .stdout_limit = .limited(1024 * 1024),
        });
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);

        var lines: std.ArrayList([]const u8) = .empty;
        var lit = std.mem.splitScalar(u8, std.mem.trim(u8, res.stdout, "\n"), '\n');
        while (lit.next()) |l| {
            if (l.len > 0) try lines.append(arena, l);
        }
        if (lines.items.len != sf.check.db_kinds.len) {
            print(io, "\n  db has {d} blocks, want {d}: {s}\n", .{ lines.items.len, sf.check.db_kinds.len, res.stdout });
            return error.DbKindsMismatch;
        }
        for (sf.check.db_kinds, lines.items) |want, got| {
            if (!std.mem.eql(u8, want, got)) {
                print(io, "\n  db kind mismatch: want {s}, got {s}\n", .{ want, got });
                return error.DbKindsMismatch;
            }
        }
    }

    if (sf.check.db_session_meta.len > 0) {
        const db_path = try std.fmt.allocPrint(arena, "{s}/marlin/marlin.db", .{state_dir});
        const query =
            "SELECT kind || '|' || (parent_sid IS NOT NULL) || '|' || " ++
            "(parent_block_id IS NOT NULL) || '|' || COALESCE(max_rounds,0) " ++
            "FROM sessions ORDER BY CASE WHEN parent_sid IS NULL THEN 0 ELSE 1 END, created_at;";
        const res = try std.process.run(gpa, io, .{
            .argv = &.{ "sqlite3", db_path, query },
            .stdout_limit = .limited(1024 * 1024),
        });
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);

        var lines: std.ArrayList([]const u8) = .empty;
        var lit = std.mem.splitScalar(u8, std.mem.trim(u8, res.stdout, "\n"), '\n');
        while (lit.next()) |line| if (line.len > 0) try lines.append(arena, line);
        if (lines.items.len != sf.check.db_session_meta.len) {
            print(io, "\n  db has {d} session rows, want {d}: {s}\n", .{ lines.items.len, sf.check.db_session_meta.len, res.stdout });
            return error.DbSessionMetaMismatch;
        }
        for (sf.check.db_session_meta, lines.items) |want, got| {
            if (!std.mem.eql(u8, want, got)) {
                print(io, "\n  db session metadata mismatch: want {s}, got {s}\n", .{ want, got });
                return error.DbSessionMetaMismatch;
            }
        }
    }

    print(io, "ok\n", .{});
}

fn checkSessionHandleFlow(
    gpa: std.mem.Allocator,
    io: Io,
    marlin_bin: []const u8,
    env: *const std.process.Environ.Map,
    state_dir: []const u8,
) !void {
    const listed = try std.process.run(gpa, io, .{
        .argv = &.{ marlin_bin, "ls" },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer gpa.free(listed.stdout);
    defer gpa.free(listed.stderr);
    if (listed.term != .exited or listed.term.exited != 0) return error.SessionHandleListFailed;

    const line_end = std.mem.indexOfScalar(u8, listed.stdout, '\n') orelse listed.stdout.len;
    var words = std.mem.tokenizeAny(u8, listed.stdout[0..line_end], " \t\r");
    const handle = words.next() orelse return error.SessionHandleMissing;
    if (handle.len < 8 or handle.len > 64) return error.SessionHandleBadLength;
    for (handle) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.SessionHandleBadSyntax;
    const prefix = handle[0..4];

    const archived = try std.process.run(gpa, io, .{
        .argv = &.{ marlin_bin, "archive", prefix },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer gpa.free(archived.stdout);
    defer gpa.free(archived.stderr);
    if (archived.term != .exited or archived.term.exited != 0 or
        std.mem.indexOf(u8, archived.stdout, handle) == null)
    {
        return error.SessionHandleArchiveFailed;
    }

    const hidden = try std.process.run(gpa, io, .{
        .argv = &.{ marlin_bin, "ls" },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer gpa.free(hidden.stdout);
    defer gpa.free(hidden.stderr);
    if (hidden.term != .exited or hidden.term.exited != 0 or
        !std.mem.eql(u8, hidden.stdout, "no sessions\n"))
    {
        return error.SessionHandleArchiveVisibilityFailed;
    }

    const inclusive = try std.process.run(gpa, io, .{
        .argv = &.{ marlin_bin, "ls", "--all" },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer gpa.free(inclusive.stdout);
    defer gpa.free(inclusive.stderr);
    if (inclusive.term != .exited or inclusive.term.exited != 0 or
        std.mem.indexOf(u8, inclusive.stdout, handle) == null or
        std.mem.indexOf(u8, inclusive.stdout, "archived") == null)
    {
        return error.SessionHandleInclusiveListFailed;
    }

    const restored = try std.process.run(gpa, io, .{
        .argv = &.{ marlin_bin, "unarchive", prefix },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer gpa.free(restored.stdout);
    defer gpa.free(restored.stderr);
    if (restored.term != .exited or restored.term.exited != 0 or
        std.mem.indexOf(u8, restored.stdout, handle) == null)
    {
        return error.SessionHandleRestoreFailed;
    }
}

fn writeExecutable(gpa: std.mem.Allocator, io: Io, path: []const u8, contents: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
    const chmod = try std.process.run(gpa, io, .{
        .argv = &.{ "/bin/chmod", "700", path },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(chmod.stdout);
    defer gpa.free(chmod.stderr);
    if (chmod.term != .exited or chmod.term.exited != 0) return error.ExecutableFixtureSetupFailed;
}

fn print(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}
