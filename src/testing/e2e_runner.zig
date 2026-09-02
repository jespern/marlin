//! e2e runner: drives the REAL marlin binary against the fake provider.
//!
//! Invoked by `zig build e2e` with paths to both binaries. For each scenario
//! in src/testing/scenarios/:
//!   1. spawn marlin-fakeprov <scenario.json>, read "PORT <n>"
//!   2. spawn marlin with an isolated $XDG_STATE_HOME (temp dir) and
//!      internal local/OpenRouter endpoint overrides aimed at that port
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
//!     "stdout_equals": "hello from fake\n",       // optional exact golden
//!     "db_kinds": ["user_msg","assistant_msg"],   // expected block kinds, in order
//!     "runs": 1,                                  // repeat marlin N times (for --continue tests)
//!     "session_handle_flow": true                 // exercise ls/prefix/archive/unarchive
//!   }
//! For runs > 1, "argv2" gives the second invocation's args.

const std = @import("std");
const Io = std.Io;
const process_io = @import("process_io");
const proto = @import("proto");
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
    stdout_equals: ?[]const u8 = null,
    stderr_equals: ?[]const u8 = null,
    db_kinds: []const []const u8 = &.{},
    /// Exact `turns|rounds|tools|outcome` telemetry aggregate.
    db_telemetry: ?[]const u8 = null,
    /// Expected durable session hierarchy rows:
    /// kind|has_parent|has_parent_block|max_rounds|archived.
    db_session_meta: []const []const u8 = &.{},
    db_media_refs: u32 = 0,
    db_tool_media_refs: u32 = 0,
    image_fixture: bool = false,
    runs: u8 = 1,
    /// Optional per-scenario M5 config and executable hook fixture.
    config_toml: ?[]const u8 = null,
    hook_script: ?[]const u8 = null,
    mcp_script: ?[]const u8 = null,
    hook_output_contains: ?[]const u8 = null,
    session_handle_flow: bool = false,
    /// Direct socket regression: approval publication, reconnect replay,
    /// steering while parked, and reboot refusal are one state-machine flow.
    approval_reconnect_flow: bool = false,
    /// Fetch a stored full tool-output blob over the daemon protocol and
    /// require at least this many decoded bytes (exercises large replies).
    blob_roundtrip_min_bytes: u64 = 0,
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
    // Strict: an unknown key under "check" (a typo'd `stdout_contain`) must
    // fail the scenario, not silently assert nothing. `steps` stays opaque.
    const sf = try std.json.parseFromSliceLeaky(ScenarioFile, arena, scenario_bytes, .{});

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
    if (sf.check.image_fixture) {
        const image_path = try std.fs.path.join(arena, &.{ state_dir, "tiny.gif" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "GIF89aMARLIN" });
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

    // Use a hostname deliberately: every scenario exercises the bounded DNS
    // helper and resolved-address handoff before the real provider request.
    const base_url = try std.fmt.allocPrint(arena, "http://localhost:{d}/v1", .{port});

    // 2. Environment for marlin: isolated state, socket, fake endpoint.
    var env = std.process.Environ.Map.init(arena);
    try env.put("HOME", state_dir); // nothing should use it, but be safe
    try env.put("TMPDIR", state_dir);
    try env.put("XDG_STATE_HOME", state_dir);
    const sock_path = try std.fmt.allocPrint(arena, "{s}/daemon.sock", .{state_dir});
    try env.put("MARLIN_SOCKET", sock_path);
    // Dynamic endpoint overrides are private harness plumbing. Scenarios use
    // local/testing without requiring users to configure its loopback URL;
    // the OpenRouter override remains for provider-specific scenarios.
    try env.put("MARLIN_BASE_URL_LOCAL", base_url);
    try env.put("MARLIN_BASE_URL_OPENROUTER", base_url);
    try env.put("MARLIN_BASE_URL_ACME", base_url);
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
    try env.put("OTEL_EXPORTER_OTLP_ENDPOINT", "");
    try env.put("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "");
    try env.put("OTEL_EXPORTER_OTLP_HEADERS", "");
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

    // 3. Run ordinary CLI scenarios, or the direct multi-connection protocol
    // regression that cannot be expressed as a one-shot headless command.
    if (sf.check.approval_reconnect_flow) {
        const started = try process_io.run(gpa, io, .{
            .argv = &.{ marlin_bin, "ls" },
            .environ_map = &env,
            .cwd = .{ .path = state_dir },
            .stdout_limit = 256 * 1024,
            .stderr_limit = 256 * 1024,
            .timeout_ms = helper_timeout_ms,
        });
        defer started.deinit(gpa);
        if (started.process_group_id) |group_id| try process_groups.append(gpa, group_id);
        if (started.term != .exited or started.term.exited != 0) return error.DaemonStartFailed;
        try checkApprovalReconnectFlow(gpa, io, &env, state_dir);
    } else {
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
                if (sf.check.stdout_equals) |want| {
                    if (!std.mem.eql(u8, want, res.stdout)) {
                        print(io, "\n  stdout differs from exact golden\n  want: {f}\n  got:  {f}\n", .{
                            std.json.fmt(want, .{}), std.json.fmt(res.stdout, .{}),
                        });
                        return error.StdoutMismatch;
                    }
                }
                if (sf.check.stderr_equals) |want| {
                    if (!std.mem.eql(u8, want, res.stderr)) {
                        print(io, "\n  stderr differs from exact golden\n  want: {f}\n  got:  {f}\n", .{
                            std.json.fmt(want, .{}), std.json.fmt(res.stderr, .{}),
                        });
                        return error.StderrMismatch;
                    }
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
    if (sf.check.blob_roundtrip_min_bytes > 0) {
        try checkBlobRoundtrip(
            gpa,
            io,
            &env,
            state_dir,
            sf.check.blob_roundtrip_min_bytes,
        );
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

    if (sf.check.db_telemetry) |want| {
        const db_path = try std.fmt.allocPrint(arena, "{s}/marlin/marlin.db", .{state_dir});
        const query =
            "SELECT (SELECT count(*) FROM telemetry_turns) || '|' || " ++
            "(SELECT count(*) FROM telemetry_rounds) || '|' || " ++
            "(SELECT count(*) FROM telemetry_tools) || '|' || " ++
            "COALESCE((SELECT outcome FROM telemetry_turns ORDER BY started_at_ms DESC LIMIT 1),'');";
        const res = try process_io.run(gpa, io, .{
            .argv = &.{ "sqlite3", db_path, query },
            .stdout_limit = 64 * 1024,
            .stderr_limit = 64 * 1024,
            .timeout_ms = helper_timeout_ms,
        });
        defer res.deinit(gpa);
        const got = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (!std.mem.eql(u8, want, got)) {
            print(io, "\n  db telemetry mismatch: want {s}, got {s}\n", .{ want, got });
            return error.DbTelemetryMismatch;
        }
        const diagnostic = try process_io.run(gpa, io, .{
            .argv = &.{ marlin_bin, "diagnostics", "--json" },
            .environ_map = &env,
            .cwd = .{ .path = state_dir },
            .stdout_limit = 256 * 1024,
            .stderr_limit = 64 * 1024,
            .timeout_ms = helper_timeout_ms,
        });
        defer diagnostic.deinit(gpa);
        if (diagnostic.term != .exited or diagnostic.term.exited != 0)
            return error.DiagnosticsCommandFailed;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, diagnostic.stdout, .{}) catch {
            print(io, "\n  diagnostics returned invalid JSON\n  stdout: {f}\n  stderr: {f}\n", .{
                std.json.fmt(diagnostic.stdout, .{}), std.json.fmt(diagnostic.stderr, .{}),
            });
            return error.DiagnosticsJsonInvalid;
        };
        defer parsed.deinit();
        const object = if (parsed.value == .object) parsed.value.object else return error.DiagnosticsJsonInvalid;
        const provider_requests = object.get("provider_requests") orelse return error.DiagnosticsJsonInvalid;
        const tool_calls = object.get("tool_calls") orelse return error.DiagnosticsJsonInvalid;
        var expected_fields = std.mem.splitScalar(u8, want, '|');
        _ = expected_fields.next(); // telemetry_turns
        const expected_provider_requests = std.fmt.parseInt(i64, expected_fields.next() orelse return error.DiagnosticsJsonInvalid, 10) catch
            return error.DiagnosticsJsonInvalid;
        const expected_tool_calls = std.fmt.parseInt(i64, expected_fields.next() orelse return error.DiagnosticsJsonInvalid, 10) catch
            return error.DiagnosticsJsonInvalid;
        if (provider_requests != .integer or provider_requests.integer != expected_provider_requests or
            tool_calls != .integer or tool_calls.integer != expected_tool_calls)
            return error.DiagnosticsJsonInvalid;
    }

    if (sf.check.db_session_meta.len > 0) {
        const db_path = try std.fmt.allocPrint(arena, "{s}/marlin/marlin.db", .{state_dir});
        const query =
            "SELECT kind || '|' || (parent_sid IS NOT NULL) || '|' || " ++
            "(parent_block_id IS NOT NULL) || '|' || COALESCE(max_rounds,0) || '|' || " ++
            "(archived_at IS NOT NULL) FROM sessions " ++
            "ORDER BY CASE WHEN parent_sid IS NULL THEN 0 ELSE 1 END, created_at;";
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
    if (sf.check.db_media_refs > 0) {
        const db_path = try std.fmt.allocPrint(arena, "{s}/marlin/marlin.db", .{state_dir});
        const res = try process_io.run(gpa, io, .{
            .argv = &.{ "sqlite3", db_path, "SELECT count(*) FROM blob_refs r JOIN blocks b ON b.id=r.block_id WHERE b.kind='user_msg';" },
            .stdout_limit = 64 * 1024,
            .stderr_limit = 64 * 1024,
            .timeout_ms = helper_timeout_ms,
        });
        defer res.deinit(gpa);
        const got = std.fmt.parseInt(u32, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch
            return error.MediaRefQueryFailed;
        if (got != sf.check.db_media_refs) return error.MediaRefCountMismatch;
    }
    if (sf.check.db_tool_media_refs > 0) {
        const db_path = try std.fmt.allocPrint(arena, "{s}/marlin/marlin.db", .{state_dir});
        const res = try process_io.run(gpa, io, .{
            .argv = &.{ "sqlite3", db_path, "SELECT count(*) FROM blob_refs r JOIN blocks b ON b.id=r.block_id WHERE b.kind='tool_result';" },
            .stdout_limit = 64 * 1024,
            .stderr_limit = 64 * 1024,
            .timeout_ms = helper_timeout_ms,
        });
        defer res.deinit(gpa);
        const count = std.fmt.parseUnsigned(u32, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch 0;
        if (count != sf.check.db_tool_media_refs) return error.DbToolMediaRefsMismatch;
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

const ProtocolConn = struct {
    gpa: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    rbuf: []u8,
    wbuf: []u8,

    fn connect(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) !*ProtocolConn {
        const sock_path = env.get("MARLIN_SOCKET") orelse return error.ProtocolSocketMissing;
        const address = try Io.net.UnixAddress.init(sock_path);
        var attempt: u8 = 0;
        const stream = while (attempt < 100) : (attempt += 1) {
            if (address.connect(io)) |candidate| break candidate else |_| {}
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        } else return error.ProtocolConnectTimedOut;
        errdefer stream.close(io);

        const self = try gpa.create(ProtocolConn);
        errdefer gpa.destroy(self);
        const rbuf = try gpa.alloc(u8, 1024 * 1024);
        errdefer gpa.free(rbuf);
        const wbuf = try gpa.alloc(u8, 256 * 1024);
        errdefer gpa.free(wbuf);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .reader = Io.net.Stream.Reader.init(stream, io, rbuf),
            .writer = Io.net.Stream.Writer.init(stream, io, wbuf),
            .rbuf = rbuf,
            .wbuf = wbuf,
        };
        return self;
    }

    fn deinit(self: *ProtocolConn) void {
        self.stream.close(self.io);
        self.gpa.free(self.rbuf);
        self.gpa.free(self.wbuf);
        self.gpa.destroy(self);
    }

    fn send(self: *ProtocolConn, value: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.gpa, value, .{});
        defer self.gpa.free(json);
        try self.writer.interface.writeAll(json);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();
    }

    fn recv(self: *ProtocolConn, arena: std.mem.Allocator) !std.json.Value {
        const line = try proto.readLineAlloc(self.gpa, &self.reader.interface);
        defer self.gpa.free(line);
        return std.json.parseFromSliceLeaky(std.json.Value, arena, std.mem.trim(u8, line, " \r\n"), .{
            .allocate = .alloc_always,
        });
    }
};

const RecvJob = struct {
    conn: *ProtocolConn,
    arena: std.mem.Allocator,
    done: std.atomic.Value(bool) = .init(false),
    msg: ?std.json.Value = null,
    err: ?anyerror = null,

    fn run(job: *RecvJob) void {
        job.msg = job.conn.recv(job.arena) catch |err| {
            job.err = err;
            job.done.store(true, .release);
            return;
        };
        job.done.store(true, .release);
    }
};

fn recvBounded(conn: *ProtocolConn, arena: std.mem.Allocator) !std.json.Value {
    var job = RecvJob{ .conn = conn, .arena = arena };
    const thread = try std.Thread.spawn(.{}, RecvJob.run, .{&job});
    if (!waitForFlag(conn.io, &job.done, helper_timeout_ms)) {
        conn.stream.shutdown(conn.io, .both) catch {};
        thread.join();
        return error.ProtocolReceiveTimedOut;
    }
    thread.join();
    if (job.err) |err| return err;
    return job.msg orelse error.ProtocolReceiveFailed;
}

fn recvTagBounded(
    conn: *ProtocolConn,
    arena: std.mem.Allocator,
    tag: []const u8,
) !std.json.ObjectMap {
    while (true) {
        const msg = try recvBounded(conn, arena);
        if (tagObject(msg, tag)) |object| return object;
        if (tagObject(msg, "err")) |daemon_err| {
            reportDaemonError(conn.io, daemon_err);
            return error.UnexpectedDaemonError;
        }
    }
}

fn connectProtocol(
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
) !*ProtocolConn {
    const conn = try ProtocolConn.connect(gpa, io, env);
    errdefer conn.deinit();
    try conn.send(.{ .hello = .{ .proto_version = proto.proto_version, .client_kind = "e2e-protocol" } });
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    _ = try recvTagBounded(conn, arena_state.allocator(), "hello_ok");
    return conn;
}

fn waitApproval(
    conn: *ProtocolConn,
    arena: std.mem.Allocator,
    sid: u64,
    id_out: []u8,
) ![]const u8 {
    while (true) {
        const msg = try recvBounded(conn, arena);
        if (tagObject(msg, "err")) |daemon_err| {
            reportDaemonError(conn.io, daemon_err);
            return error.UnexpectedDaemonError;
        }
        const request = tagObject(msg, "approval_request") orelse continue;
        if (uintField(request, "sid") != sid) continue;
        const approval_id = stringField(request, "approval_id") orelse return error.ApprovalIdMissing;
        if (approval_id.len > id_out.len) return error.ApprovalIdTooLong;
        @memcpy(id_out[0..approval_id.len], approval_id);
        return id_out[0..approval_id.len];
    }
}

fn expectDaemonError(
    conn: *ProtocolConn,
    arena: std.mem.Allocator,
    code: []const u8,
) !void {
    while (true) {
        const msg = try recvBounded(conn, arena);
        const daemon_err = tagObject(msg, "err") orelse continue;
        if (!std.mem.eql(u8, stringField(daemon_err, "code") orelse "", code)) return error.WrongDaemonError;
        return;
    }
}

fn tagObject(msg: std.json.Value, tag: []const u8) ?std.json.ObjectMap {
    if (msg != .object) return null;
    const payload = msg.object.get(tag) orelse return null;
    return if (payload == .object) payload.object else null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn uintField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn reportDaemonError(io: Io, daemon_err: std.json.ObjectMap) void {
    print(io, "\n  unexpected daemon error {s}: {s}\n", .{
        stringField(daemon_err, "code") orelse "unknown",
        stringField(daemon_err, "msg") orelse "no message",
    });
}

fn checkApprovalReconnectFlow(
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    state_dir: []const u8,
) !void {
    var approval_buf: [32]u8 = undefined;
    const approval_id = first: {
        const conn = try connectProtocol(gpa, io, env);
        defer conn.deinit();
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        try conn.send(.{ .session_create = .{
            .cwd = state_dir,
            .model = "local/testing",
            .approvals = "default",
        } });
        const created = try recvTagBounded(conn, arena, "session_created");
        const sid = uintField(created, "sid") orelse return error.SessionIdMissing;
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
        try conn.send(.{ .input = .{ .sid = sid, .text = "approval reconnect task" } });
        const id = try waitApproval(conn, arena, sid, &approval_buf);
        break :first .{ sid, id.len };
    };
    const sid = approval_id[0];
    const id = approval_buf[0..approval_id[1]];

    // A session watcher must recover actionable background approval state.
    {
        const conn = try connectProtocol(gpa, io, env);
        defer conn.deinit();
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var watcher_id_buf: [32]u8 = undefined;
        try conn.send(.{ .session_watch = struct {}{} });
        const watcher_id = try waitApproval(conn, arena_state.allocator(), sid, &watcher_id_buf);
        if (!std.mem.eql(u8, watcher_id, id)) return error.ApprovalReplayMismatch;
    }

    // A focused reattach gets the same request, and input remains a steer for
    // the parked turn. Plain reboot refuses; the approval can still resolve.
    const conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sub_id_buf: [32]u8 = undefined;
    try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 1 } });
    const sub_id = try waitApproval(conn, arena, sid, &sub_id_buf);
    if (!std.mem.eql(u8, sub_id, id)) return error.ApprovalReplayMismatch;

    const large_steer = try gpa.alloc(u8, 300 * 1024);
    defer gpa.free(large_steer);
    const steer_prefix = "queued while awaiting approval";
    @memcpy(large_steer[0..steer_prefix.len], steer_prefix);
    @memset(large_steer[steer_prefix.len..], 'x');
    try conn.send(.{ .input = .{
        .sid = sid,
        .text = large_steer,
        .request_id = 102,
    } });
    const steer_ok = try recvTagBounded(conn, arena, "ok");
    if (uintField(steer_ok, "request_id") != 102) return error.InputAckMismatch;
    try conn.send(.{ .reboot = .{ .force = false } });
    try expectDaemonError(conn, arena, "approval_pending");
    try conn.send(.{ .approve = .{ .sid = sid, .approval_id = id, .decision = "granted" } });
    _ = try recvTagBounded(conn, arena, "ok");

    while (true) {
        const msg = try recvBounded(conn, arena);
        if (tagObject(msg, "err")) |daemon_err| {
            reportDaemonError(conn.io, daemon_err);
            return error.UnexpectedDaemonError;
        }
        const status = tagObject(msg, "status") orelse continue;
        if (uintField(status, "sid") != sid) continue;
        const state = stringField(status, "state") orelse continue;
        if (std.mem.eql(u8, state, "err")) return error.ApprovalFlowTurnFailed;
        if (std.mem.eql(u8, state, "idle")) break;
    }

    try conn.send(.{ .interrupt = .{ .sid = sid, .report = true } });
    const idle_interrupt = try recvTagBounded(conn, arena, "interrupt_result");
    const active = idle_interrupt.get("active") orelse return error.InterruptResultMissing;
    if (active != .bool or active.bool) return error.InterruptResultMismatch;

    // A bounded attach emits exactly its newest window followed by an
    // explicit marker. This is the TUI cold-attach contract and must stay
    // distinct from legacy from_seq replays, whose clients know no marker.
    {
        const tail_conn = try connectProtocol(gpa, io, env);
        defer tail_conn.deinit();
        var tail_arena_state = std.heap.ArenaAllocator.init(gpa);
        defer tail_arena_state.deinit();
        const tail_arena = tail_arena_state.allocator();
        try tail_conn.send(.{ .sub = .{ .sid = sid, .from_seq = 1, .tail_limit = 1 } });
        const newest = try recvTagBounded(tail_conn, tail_arena, "blk");
        if (uintField(newest, "sid") != sid) return error.TailReplaySessionMismatch;
        const newest_block = objectField(newest, "b") orelse return error.TailReplayMarkerMissing;
        const newest_block_seq = uintField(newest_block, "seq") orelse return error.TailReplayMarkerMissing;
        const marker = try recvTagBounded(tail_conn, tail_arena, "replay_done");
        if (uintField(marker, "sid") != sid) return error.TailReplaySessionMismatch;
        const oldest_seq = uintField(marker, "oldest_seq") orelse return error.TailReplayMarkerMissing;
        const newest_seq = uintField(marker, "newest_seq") orelse return error.TailReplayMarkerMissing;
        if (oldest_seq == 0 or oldest_seq != newest_seq) return error.TailReplayMarkerMismatch;
        if (newest_block_seq != newest_seq) return error.TailReplayMarkerMismatch;
        const has_older = marker.get("has_older") orelse return error.TailReplayMarkerMissing;
        if (has_older != .bool or !has_older.bool) return error.TailReplayMarkerMismatch;

        // Reaching the loaded top requests another bounded page before the
        // current oldest seq; it must never fall back to a full replay.
        try tail_conn.send(.{ .sub = .{
            .sid = sid,
            .tail_limit = 1,
            .before_seq = oldest_seq,
        } });
        const older = try recvTagBounded(tail_conn, tail_arena, "blk");
        const older_block = objectField(older, "b") orelse return error.TailReplayMarkerMissing;
        const older_seq = uintField(older_block, "seq") orelse return error.TailReplayMarkerMissing;
        if (older_seq >= oldest_seq) return error.TailReplayMarkerMismatch;
        const older_marker = try recvTagBounded(tail_conn, tail_arena, "replay_done");
        if (uintField(older_marker, "oldest_seq") != older_seq or
            uintField(older_marker, "newest_seq") != older_seq)
            return error.TailReplayMarkerMismatch;
    }

    // Forward catch-up is page-bounded too. A partial page must not become a
    // live subscription (no status yet); the final page transitions to live
    // and emits status only after the durable frontier marker.
    {
        const forward_conn = try connectProtocol(gpa, io, env);
        defer forward_conn.deinit();
        var forward_arena_state = std.heap.ArenaAllocator.init(gpa);
        defer forward_arena_state.deinit();
        const forward_arena = forward_arena_state.allocator();
        try forward_conn.send(.{ .sub = .{
            .sid = sid,
            .from_seq = 1,
            .replay_limit = 1,
        } });
        const first = try recvTagBounded(forward_conn, forward_arena, "blk");
        const first_block = objectField(first, "b") orelse return error.ForwardReplayMarkerMissing;
        const first_seq = uintField(first_block, "seq") orelse return error.ForwardReplayMarkerMissing;
        const first_marker = try recvTagBounded(forward_conn, forward_arena, "replay_done");
        const forward = first_marker.get("forward") orelse return error.ForwardReplayMarkerMissing;
        if (forward != .bool or !forward.bool) return error.ForwardReplayMarkerMismatch;
        const has_newer = first_marker.get("has_newer") orelse return error.ForwardReplayMarkerMissing;
        if (has_newer != .bool or !has_newer.bool) return error.ForwardReplayMarkerMismatch;
        if (uintField(first_marker, "newest_seq") != first_seq)
            return error.ForwardReplayMarkerMismatch;

        try forward_conn.send(.{ .sub = .{
            .sid = sid,
            .from_seq = first_seq + 1,
            .replay_limit = 512,
        } });
        const final_marker = try recvTagBounded(forward_conn, forward_arena, "replay_done");
        const final_has_newer = final_marker.get("has_newer") orelse return error.ForwardReplayMarkerMissing;
        if (final_has_newer != .bool or final_has_newer.bool) return error.ForwardReplayMarkerMismatch;
        const live_status = try recvTagBounded(forward_conn, forward_arena, "status");
        if (uintField(live_status, "sid") != sid) return error.ForwardReplaySessionMismatch;
    }

    // Opted-in catalog watchers receive one-row mutations rather than a
    // complete session_list_result rebuild for every metadata change.
    {
        const watch_conn = try connectProtocol(gpa, io, env);
        defer watch_conn.deinit();
        var watch_arena_state = std.heap.ArenaAllocator.init(gpa);
        defer watch_arena_state.deinit();
        const watch_arena = watch_arena_state.allocator();
        try watch_conn.send(.{ .session_watch = .{ .incremental = true } });
        _ = try recvTagBounded(watch_conn, watch_arena, "session_list_result");
        try watch_conn.send(.{ .session_set_effort = .{ .sid = sid, .effort = "high" } });
        _ = try recvTagBounded(watch_conn, watch_arena, "ok");
        const upsert = try recvTagBounded(watch_conn, watch_arena, "session_upsert");
        const changed = objectField(upsert, "session") orelse return error.SessionUpsertMissing;
        if (uintField(changed, "sid") != sid) return error.SessionUpsertMismatch;
        const effort = stringField(changed, "effort") orelse return error.SessionUpsertMismatch;
        if (!std.mem.eql(u8, effort, "high")) return error.SessionUpsertMismatch;

        try watch_conn.send(.{ .session_archive = .{ .sid = sid, .archived = true } });
        _ = try recvTagBounded(watch_conn, watch_arena, "ok");
        const removed = try recvTagBounded(watch_conn, watch_arena, "session_remove");
        if (uintField(removed, "sid") != sid) return error.SessionRemoveMismatch;

        try watch_conn.send(.{ .session_archive = .{ .sid = sid, .archived = false } });
        _ = try recvTagBounded(watch_conn, watch_arena, "ok");
        const restored = try recvTagBounded(watch_conn, watch_arena, "session_upsert");
        const restored_session = objectField(restored, "session") orelse return error.SessionUpsertMissing;
        if (uintField(restored_session, "sid") != sid) return error.SessionUpsertMismatch;
    }

    // Rejected input returns the same identity, so an optimistic client can
    // remove precisely that echo and restore its pre-submit state.
    try conn.send(.{ .session_archive = .{ .sid = sid, .archived = true } });
    _ = try recvTagBounded(conn, arena, "ok");
    try conn.send(.{ .input = .{
        .sid = sid,
        .text = "must be rejected",
        .request_id = 103,
    } });
    while (true) {
        const msg = try recvBounded(conn, arena);
        const daemon_err = tagObject(msg, "err") orelse continue;
        if (!std.mem.eql(u8, stringField(daemon_err, "code") orelse "", "archived"))
            return error.WrongDaemonError;
        if (uintField(daemon_err, "request_id") != 103) return error.InputAckMismatch;
        break;
    }
}

fn checkBlobRoundtrip(
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    state_dir: []const u8,
    min_bytes: u64,
) !void {
    const db_path = try std.fmt.allocPrint(gpa, "{s}/marlin/marlin.db", .{state_dir});
    defer gpa.free(db_path);
    const query =
        "SELECT json_extract(body_json,'$.tool_result.full_body_ref') " ++
        "FROM blocks WHERE kind='tool_result' AND " ++
        "json_extract(body_json,'$.tool_result.full_body_ref') IS NOT NULL LIMIT 1;";
    const lookup = try process_io.run(gpa, io, .{
        .argv = &.{ "sqlite3", db_path, query },
        .stdout_limit = 4096,
        .stderr_limit = 4096,
        .timeout_ms = helper_timeout_ms,
    });
    defer lookup.deinit(gpa);
    if (lookup.term != .exited or lookup.term.exited != 0) return error.BlobRefLookupFailed;
    const hash = std.mem.trim(u8, lookup.stdout, " \t\r\n");
    if (hash.len == 0) return error.BlobRefMissing;

    const conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try conn.send(.{ .blob_get = .{ .hash = hash } });
    const result = try recvTagBounded(conn, arena_state.allocator(), "blob_result");
    const bytes = stringField(result, "bytes") orelse return error.BlobBytesMissing;
    if (bytes.len < min_bytes) return error.BlobRoundtripTooSmall;
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
