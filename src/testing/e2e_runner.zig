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
const process_io = @import("process_io");
const temp_dir = @import("temp_dir.zig");
const TempDir = temp_dir.Dir;

const scenario_timeout_ms: u32 = 30_000;
const shutdown_timeout_ms: u32 = 3_000;
const helper_timeout_ms: u32 = 5_000;

const ProviderPortJob = struct {
    io: Io,
    file: Io.File,
    done: std.atomic.Value(bool) = .init(false),
    port: ?u16 = null,

    fn run(job: *ProviderPortJob) void {
        defer job.done.store(true, .release);
        var buffer: [64]u8 = undefined;
        var reader = job.file.reader(job.io, &buffer);
        const line = reader.interface.takeDelimiterExclusive('\n') catch return;
        if (!std.mem.startsWith(u8, line, "PORT ")) return;
        job.port = std.fmt.parseInt(u16, std.mem.trim(u8, line[5..], " \r\n"), 10) catch null;
    }
};

const ProviderWaitJob = struct {
    io: Io,
    child: *std.process.Child,
    done: std.atomic.Value(bool) = .init(false),
    term: ?std.process.Child.Term = null,

    fn run(job: *ProviderWaitJob) void {
        job.term = job.child.wait(job.io) catch null;
        job.done.store(true, .release);
    }
};

fn waitForFlag(io: Io, flag: *const std.atomic.Value(bool), timeout_ms: u32) bool {
    const deadline = Io.Timestamp.now(io, .awake).nanoseconds +
        @as(i96, timeout_ms) * std.time.ns_per_ms;
    while (!flag.load(.acquire)) {
        if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline) return false;
        io.sleep(.fromMilliseconds(10), .awake) catch return false;
    }
    return true;
}

fn reapChild(io: Io, child: *std.process.Child) void {
    if (child.id == null) return;
    _ = child.wait(io) catch {
        child.kill(io);
        return;
    };
}

fn readProviderPort(io: Io, child: *std.process.Child) !u16 {
    const group_id = child.id orelse return error.ProviderExitedBeforePort;
    var job = ProviderPortJob{ .io = io, .file = child.stdout.? };
    const thread = std.Thread.spawn(.{}, ProviderPortJob.run, .{&job}) catch {
        process_io.terminateProcessTree(child, io, 50);
        return error.ProviderPortReaderFailed;
    };
    if (!waitForFlag(io, &job.done, helper_timeout_ms)) {
        process_io.terminateProcessGroup(io, group_id, 50);
        thread.join();
        reapChild(io, child);
        return error.ProviderStartTimedOut;
    }
    thread.join();
    return job.port orelse {
        process_io.terminateProcessTree(child, io, 50);
        return error.NoPortLine;
    };
}

fn waitProvider(io: Io, child: *std.process.Child) !std.process.Child.Term {
    const group_id = child.id orelse return error.ProviderAlreadyReaped;
    var job = ProviderWaitJob{ .io = io, .child = child };
    const thread = std.Thread.spawn(.{}, ProviderWaitJob.run, .{&job}) catch {
        process_io.terminateProcessTree(child, io, 50);
        return error.ProviderWaitThreadFailed;
    };
    const completed = waitForFlag(io, &job.done, helper_timeout_ms);
    if (!completed) process_io.terminateProcessGroup(io, group_id, 50);
    thread.join();
    if (!completed) return error.ProviderCompletionTimedOut;
    return job.term orelse {
        if (child.id != null) process_io.terminateProcessTree(child, io, 50);
        return error.ProviderWaitFailed;
    };
}

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
        // Never inherit the runner's stderr: an accidentally surviving
        // provider must not retain a caller's `tee`/pipeline write end.
        .stderr = .ignore,
        .pgid = 0,
    });
    // Ensure cleanup even on failure paths.
    var prov_done = false;
    defer if (!prov_done) {
        process_io.terminateProcessTree(&prov, io, 50);
        prov_done = true;
    };

    const port = readProviderPort(io, &prov) catch |err| {
        prov_done = prov.id == null;
        return err;
    };

    const base_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/v1", .{port});

    // 2. Environment for marlin: isolated state, socket, fake endpoint.
    var env = std.process.Environ.Map.init(arena);
    try env.put("HOME", state_dir); // nothing should use it, but be safe
    try env.put("TMPDIR", state_dir);
    try env.put("XDG_STATE_HOME", state_dir);
    const sock_path = try std.fmt.allocPrint(arena, "{s}/daemon.sock", .{state_dir});
    try env.put("MARLIN_SOCKET", sock_path);
    try env.put("MARLIN_BASE_URL_OPENROUTER", base_url);
    // Test daemons remain in the runner's process group. That makes Ctrl+C or
    // an outer tool cancellation clean up the entire scenario tree.
    try env.put("MARLIN_DAEMON_PGID", "inherit");
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
    // A successful client command may leave its intentionally daemonized
    // child alive in the command's owned process group. Remember every group
    // so cleanup can sweep it after the graceful shutdown attempt.
    var process_groups: std.ArrayList(std.posix.pid_t) = .empty;
    defer process_groups.deinit(gpa);
    var graceful_shutdown_done = false;
    // Always stop the provider first, then the per-scenario daemon. The order
    // matters: a failed shutdown must never postpone provider pipe cleanup.
    // The group sweep stays as a safety net for error paths — the happy path
    // asserts graceful exit BEFORE any signal can mask a wedged daemon.
    defer {
        if (!prov_done) {
            process_io.terminateProcessTree(&prov, io, 50);
            prov_done = true;
        }
        if (!graceful_shutdown_done) {
            const res = process_io.run(gpa, io, .{
                .argv = &.{ marlin_bin, "shutdown" },
                .environ_map = &env,
                .cwd = .{ .path = state_dir },
                .stdout_limit = 64 * 1024,
                .stderr_limit = 64 * 1024,
                .timeout_ms = shutdown_timeout_ms,
            }) catch null;
            if (res) |r| {
                r.deinit(gpa);
            }
        }
        for (process_groups.items) |group_id| {
            process_io.terminateProcessGroup(io, group_id, 50);
        }
    }

    // 3. Run marlin (1 or 2 invocations).
    var runs: u8 = 0;
    while (runs < sf.check.runs) : (runs += 1) {
        const argv_cfg = if (runs == 0) sf.check.argv else sf.check.argv2;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, marlin_bin);
        for (argv_cfg) |a| try argv.append(arena, a);

        const res = process_io.run(gpa, io, .{
            .argv = argv.items,
            .environ_map = &env,
            .cwd = .{ .path = state_dir },
            .stdout_limit = 4 * 1024 * 1024,
            .stderr_limit = 4 * 1024 * 1024,
            .timeout_ms = scenario_timeout_ms,
        }) catch |err| {
            if (err == error.Timeout) {
                print(io, "\n  scenario command exceeded {d}ms and its process tree was terminated\n", .{scenario_timeout_ms});
                return error.ScenarioTimedOut;
            }
            return err;
        };
        defer res.deinit(gpa);
        if (res.process_group_id) |group_id| try process_groups.append(gpa, group_id);

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
    const prov_term = waitProvider(io, &prov) catch |err| {
        prov_done = true;
        return err;
    };
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
        const res = try process_io.run(gpa, io, .{
            .argv = &.{ "sqlite3", db_path, "SELECT kind FROM blocks ORDER BY seq;" },
            .stdout_limit = 1024 * 1024,
            .stderr_limit = 64 * 1024,
            .timeout_ms = helper_timeout_ms,
        });
        defer res.deinit(gpa);

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
        const res = try process_io.run(gpa, io, .{
            .argv = &.{ "sqlite3", db_path, query },
            .stdout_limit = 1024 * 1024,
            .stderr_limit = 64 * 1024,
            .timeout_ms = helper_timeout_ms,
        });
        defer res.deinit(gpa);

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

    // 6. Graceful shutdown must actually END the daemon process. `shutdown`
    // acks right before daemon exit, so the ack alone proves nothing — a
    // teardown deadlock after the ack leaves a zombie holding the store (the
    // !rb zombie-daemon bug). The signal sweep in the defer would silently
    // unwedge and mask it; assert real exit first.
    {
        const res = process_io.run(gpa, io, .{
            .argv = &.{ marlin_bin, "shutdown" },
            .environ_map = &env,
            .cwd = .{ .path = state_dir },
            .stdout_limit = 64 * 1024,
            .stderr_limit = 64 * 1024,
            .timeout_ms = shutdown_timeout_ms,
        }) catch null;
        if (res) |r| r.deinit(gpa);
        graceful_shutdown_done = true;
        for (process_groups.items) |group_id| {
            if (!waitGroupGone(io, group_id, shutdown_timeout_ms)) {
                print(io, "\n  daemon (group {d}) survived graceful shutdown\n", .{group_id});
                return error.DaemonSurvivedShutdown;
            }
        }
    }

    print(io, "ok\n", .{});
}

/// True once no process in the group remains (probe: CONT to -pgid until
/// ProcessNotFound). Scenario daemons opt into group inheritance, so a
/// wedged daemon keeps the group alive and is observable here.
fn waitGroupGone(io: Io, group_id: std.posix.pid_t, timeout_ms: u32) bool {
    const deadline = Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, timeout_ms) * std.time.ns_per_ms;
    while (true) {
        std.posix.kill(-group_id, .CONT) catch |err| switch (err) {
            error.ProcessNotFound => return true,
            else => return true, // no probe possible → do not block the suite
        };
        if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline) return false;
        io.sleep(.fromMilliseconds(25), .awake) catch return false;
    }
}

fn checkSessionHandleFlow(
    gpa: std.mem.Allocator,
    io: Io,
    marlin_bin: []const u8,
    env: *const std.process.Environ.Map,
    state_dir: []const u8,
) !void {
    const listed = try process_io.run(gpa, io, .{
        .argv = &.{ marlin_bin, "ls" },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = 256 * 1024,
        .stderr_limit = 256 * 1024,
        .timeout_ms = helper_timeout_ms,
    });
    defer listed.deinit(gpa);
    if (listed.term != .exited or listed.term.exited != 0) return error.SessionHandleListFailed;

    const line_end = std.mem.indexOfScalar(u8, listed.stdout, '\n') orelse listed.stdout.len;
    var words = std.mem.tokenizeAny(u8, listed.stdout[0..line_end], " \t\r");
    const handle = words.next() orelse return error.SessionHandleMissing;
    if (handle.len < 8 or handle.len > 64) return error.SessionHandleBadLength;
    for (handle) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.SessionHandleBadSyntax;
    const prefix = handle[0..4];

    const archived = try process_io.run(gpa, io, .{
        .argv = &.{ marlin_bin, "archive", prefix },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = 256 * 1024,
        .stderr_limit = 256 * 1024,
        .timeout_ms = helper_timeout_ms,
    });
    defer archived.deinit(gpa);
    if (archived.term != .exited or archived.term.exited != 0 or
        std.mem.indexOf(u8, archived.stdout, handle) == null)
    {
        return error.SessionHandleArchiveFailed;
    }

    const hidden = try process_io.run(gpa, io, .{
        .argv = &.{ marlin_bin, "ls" },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = 256 * 1024,
        .stderr_limit = 256 * 1024,
        .timeout_ms = helper_timeout_ms,
    });
    defer hidden.deinit(gpa);
    if (hidden.term != .exited or hidden.term.exited != 0 or
        !std.mem.eql(u8, hidden.stdout, "no sessions\n"))
    {
        return error.SessionHandleArchiveVisibilityFailed;
    }

    const inclusive = try process_io.run(gpa, io, .{
        .argv = &.{ marlin_bin, "ls", "--all" },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = 256 * 1024,
        .stderr_limit = 256 * 1024,
        .timeout_ms = helper_timeout_ms,
    });
    defer inclusive.deinit(gpa);
    if (inclusive.term != .exited or inclusive.term.exited != 0 or
        std.mem.indexOf(u8, inclusive.stdout, handle) == null or
        std.mem.indexOf(u8, inclusive.stdout, "archived") == null)
    {
        return error.SessionHandleInclusiveListFailed;
    }

    const restored = try process_io.run(gpa, io, .{
        .argv = &.{ marlin_bin, "unarchive", prefix },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = 256 * 1024,
        .stderr_limit = 256 * 1024,
        .timeout_ms = helper_timeout_ms,
    });
    defer restored.deinit(gpa);
    if (restored.term != .exited or restored.term.exited != 0 or
        std.mem.indexOf(u8, restored.stdout, handle) == null)
    {
        return error.SessionHandleRestoreFailed;
    }
}

fn writeExecutable(gpa: std.mem.Allocator, io: Io, path: []const u8, contents: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
    const chmod = try process_io.run(gpa, io, .{
        .argv = &.{ "/bin/chmod", "700", path },
        .stdout_limit = 4096,
        .stderr_limit = 4096,
        .timeout_ms = helper_timeout_ms,
    });
    defer chmod.deinit(gpa);
    if (chmod.term != .exited or chmod.term.exited != 0) return error.ExecutableFixtureSetupFailed;
}

fn print(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}
