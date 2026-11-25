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
    /// Wall-clock budget for the final marlin invocation, including daemon
    /// autostart. 0 = no budget. The cheapest startup regression gate we have.
    max_wall_ms: u64 = 0,
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
    recap_contains: ?[]const u8 = null,
    git_status_flow: bool = false,
    skill_invocation_flow: bool = false,
    plugin_flow: bool = false,
    runtime_flow: bool = false,
    cwd_completion_flow: bool = false,
    /// Direct socket regression: approval publication, reconnect replay,
    /// steering while parked, and reboot refusal are one state-machine flow.
    approval_reconnect_flow: bool = false,
    session_restore_flow: bool = false,
    project_permissions_flow: bool = false,
    codex_question_flow: bool = false,
    /// `marlin --remote <host> reboot --then …` through a fake ssh to this
    /// scenario's daemon: the follow-up must reach the remote daemon too.
    remote_reboot_flow: bool = false,
    /// Graceful handover beyond sessions: "shells" (a running shell moves,
    /// a client that never returns holds the old daemon until
    /// [reboot] handover_wait) or "abort" (the successor fails to start).
    handover_flow: []const u8 = "",
    /// Ctrl+C under an output flood: how long until the shell answers
    /// again, and how much output still arrives after the interrupt.
    shell_interrupt_flow: bool = false,
    pause_flow: []const u8 = "",
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
    // Build-system args may be relative to the runner's original cwd (since
    // Zig 0.17, directory args are too). Resolve them before each scenario
    // moves Marlin and the fake provider into an isolated working directory.
    const marlin_bin = try Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    const fakeprov_bin = try Io.Dir.cwd().realPathFileAlloc(io, args[2], arena);
    const scenarios_dir = try Io.Dir.cwd().realPathFileAlloc(io, args[3], arena);
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
        if (init.environ_map.get("MARLIN_E2E_FILTER")) |filter| if (std.mem.indexOf(u8, entry.name, filter) == null) continue;
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

    if (sf.check.skill_invocation_flow) {
        const skill_dir = try std.fs.path.join(arena, &.{ state_dir, ".marlin", "skills", "review" });
        try Io.Dir.cwd().createDirPath(io, skill_dir);
        const skill_path = try std.fs.path.join(arena, &.{ skill_dir, "SKILL.md" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = skill_path, .data = "---\nname: review\ndescription: >-\n  Review a target\n  with project conventions.\nmetadata:\n  name: nested-name-is-not-a-skill\n---\nSKILL_BODY_MARKER: inspect $ARGUMENTS[0] with $1.\nRead references/guide.md for details.\n" });
        const reference_dir = try std.fs.path.join(arena, &.{ skill_dir, "references" });
        try Io.Dir.cwd().createDirPath(io, reference_dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ reference_dir, "guide.md" }), .data = "BUNDLED_REFERENCE_MARKER: keep checks focused." });
        const user_skill_dir = try std.fs.path.join(arena, &.{ state_dir, ".config", "marlin", "skills", "review" });
        try Io.Dir.cwd().createDirPath(io, user_skill_dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ user_skill_dir, "SKILL.md" }), .data = "---\nname: review\ndescription: SHADOWED_USER_DESCRIPTION\n---\nSHADOWED_USER_BODY\n" });
        const shared_dir = try std.fs.path.join(arena, &.{ state_dir, ".agents", "skills", "shared" });
        try Io.Dir.cwd().createDirPath(io, shared_dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ shared_dir, "SKILL.md" }), .data = "---\nname: shared\ndescription: SHARED_SKILL_DESCRIPTION\n---\nUNLOADED_SHARED_BODY\n" });
        const agent_path = try std.fs.path.join(arena, &.{ state_dir, "AGENT.md" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = agent_path, .data = "AGENT_STARTUP_MARKER: follow project conventions." });
    }

    // 1. Spawn the fake provider; read PORT line.
    var prov = try std.process.spawn(io, .{
        .argv = &.{ fakeprov_bin, scenario_path },
        .cwd = .{ .path = state_dir },
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
    // Test daemons stay off the LAN: no Bonjour advertisement.
    try env.put("MARLIN_DISCOVERY", "0");
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
    const guest_handover = std.mem.startsWith(u8, sf.check.handover_flow, "guest_");
    if (std.mem.startsWith(u8, sf.check.pause_flow, "guest_") or guest_handover) {
        const flow = if (guest_handover) sf.check.handover_flow else sf.check.pause_flow;
        const guest = Guest.of(flow);
        const auth = std.mem.indexOf(u8, flow, "_auth_") != null;
        const fixture_name = try std.fmt.allocPrint(arena, "{s}{s}.sh", .{ @tagName(guest), if (guest_handover) "_handover" else if (auth) "_auth" else "" });
        const fixture = try std.fs.path.join(arena, &.{ scenarios_dir, "..", "fixtures", "pause", fixture_name });
        const script = try Io.Dir.cwd().readFileAlloc(io, fixture, arena, .limited(64 * 1024));
        const path = try std.fs.path.joinZ(arena, &.{ state_dir, "guest-peer" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = script });
        if (std.c.chmod(path, 0o755) != 0) return error.GuestFixtureChmodFailed;
        try env.put(guest.binEnv(), path);
        try env.put("MARLIN_AUTH_TEST_CASE", sf.check.pause_flow);
    }
    if (sf.check.codex_question_flow) {
        const fixture = try std.fs.path.join(arena, &.{ scenarios_dir, "..", "fixtures", "codex_question.py" });
        const script = try Io.Dir.cwd().readFileAlloc(io, fixture, arena, .limited(64 * 1024));
        const path = try std.fs.path.joinZ(arena, &.{ state_dir, "guest-peer" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = script });
        if (std.c.chmod(path, 0o755) != 0) return error.GuestFixtureChmodFailed;
        try env.put("MARLIN_CODEX_BIN", path);
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
    if (sf.check.approval_reconnect_flow or sf.check.pause_flow.len > 0 or sf.check.session_restore_flow or sf.check.project_permissions_flow or sf.check.codex_question_flow or sf.check.remote_reboot_flow or sf.check.handover_flow.len > 0 or sf.check.shell_interrupt_flow) {
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
        if (sf.check.shell_interrupt_flow)
            try checkShellInterruptFlow(gpa, io, &env, state_dir)
        else if (sf.check.handover_flow.len > 0)
            try checkHandoverFlow(gpa, io, &env, state_dir, sf.check.handover_flow)
        else if (sf.check.remote_reboot_flow)
            try checkRemoteRebootFlow(gpa, io, &env, state_dir, marlin_bin, &process_groups)
        else if (sf.check.codex_question_flow)
            try checkCodexQuestionFlow(gpa, io, &env, state_dir)
        else if (sf.check.project_permissions_flow)
            try checkProjectPermissionsFlow(gpa, io, &env, state_dir, marlin_bin, &process_groups)
        else if (sf.check.session_restore_flow)
            try checkSessionRestoreFlow(gpa, io, &env, state_dir, marlin_bin, &process_groups)
        else if (sf.check.pause_flow.len > 0)
            try checkPauseFlow(gpa, io, &env, state_dir, marlin_bin, &process_groups, sf.check.pause_flow)
        else
            try checkApprovalReconnectFlow(gpa, io, &env, state_dir);
    } else {
        var runs: u8 = 0;
        while (runs < sf.check.runs) : (runs += 1) {
            const argv_cfg = if (runs == 0) sf.check.argv else sf.check.argv2;
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(arena, marlin_bin);
            for (argv_cfg) |a| try argv.append(arena, a);

            const run_began_ns = Io.Timestamp.now(io, .awake).nanoseconds;
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
                const wall_ms: u64 = @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds - run_began_ns, std.time.ns_per_ms));
                if (sf.check.max_wall_ms > 0 and wall_ms > sf.check.max_wall_ms) {
                    print(io, "\n  marlin took {d}ms, budget {d}ms\n", .{ wall_ms, sf.check.max_wall_ms });
                    return error.ScenarioTooSlow;
                }
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

    if (sf.check.recap_contains) |expected| try checkRecap(gpa, io, &env, expected);
    if (sf.check.git_status_flow) try checkGitStatus(gpa, io, &env, state_dir);
    if (sf.check.skill_invocation_flow) try checkSkillInvocation(gpa, io, &env, state_dir);
    if (sf.check.runtime_flow) try checkRuntime(gpa, io, &env);
    if (sf.check.cwd_completion_flow) try checkCwdCompletion(gpa, io, &env, state_dir);
    if (sf.check.plugin_flow) try checkPlugins(gpa, io, &env, state_dir, marlin_bin);

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
/// Whether process `pid` exits within `timeout_ms`.
fn waitPidGone(io: Io, pid: std.posix.pid_t, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 10) {
        if (std.c.kill(pid, @fromBackingInt(@intCast(0))) != 0) return true;
        io.sleep(.fromMilliseconds(10), .awake) catch return false;
    }
    return std.c.kill(pid, @fromBackingInt(@intCast(0))) != 0;
}

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

fn pauseCreate(conn: *ProtocolConn, arena: std.mem.Allocator, cwd: []const u8, approvals: []const u8) !u64 {
    try conn.send(.{ .session_create = .{ .cwd = cwd, .model = "local/testing", .approvals = approvals } });
    const created = try recvTagBounded(conn, arena, "session_created");
    const sid = uintField(created, "sid") orelse return error.SessionIdMissing;
    try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
    _ = try recvTagBounded(conn, arena, "status");
    return sid;
}

fn pauseWaitState(conn: *ProtocolConn, arena: std.mem.Allocator, sid: u64, pause: []const u8, state: []const u8) !void {
    while (true) {
        const msg = try recvBounded(conn, arena);
        if (tagObject(msg, "err")) |err| {
            reportDaemonError(conn.io, err);
            return error.PauseFlowDaemonError;
        }
        const status = tagObject(msg, "status") orelse continue;
        if (uintField(status, "sid") != sid) continue;
        if (std.mem.eql(u8, stringField(status, "state") orelse "", "err")) {
            print(conn.io, "turn error: {s}\n", .{stringField(status, "err_text") orelse "unknown"});
            return error.PauseFlowTurnFailed;
        }
        if (std.mem.eql(u8, stringField(status, "pause") orelse "none", pause) and
            std.mem.eql(u8, stringField(status, "state") orelse "", state)) return;
    }
}

fn pauseWaitCall(conn: *ProtocolConn, arena: std.mem.Allocator, sid: u64) !void {
    while (true) {
        const msg = try recvBounded(conn, arena);
        if (tagObject(msg, "status")) |status| {
            if (uintField(status, "sid") == sid and std.mem.eql(u8, stringField(status, "state") orelse "", "err")) {
                print(conn.io, "guest/turn error: {s}\n", .{stringField(status, "err_text") orelse "unknown"});
                return error.PauseFlowTurnFailed;
            }
        }
        const blk = tagObject(msg, "blk") orelse continue;
        if (uintField(blk, "sid") != sid) continue;
        const b = blk.get("b") orelse continue;
        const body = b.object.get("body") orelse continue;
        if (body.object.contains("tool_call")) return;
    }
}

fn pauseAssertListed(conn: *ProtocolConn, arena: std.mem.Allocator, sid: u64, expected: []const u8) !void {
    try conn.send(.{ .session_list = .{ .include_archived = false } });
    const list = try recvTagBounded(conn, arena, "session_list_result");
    for (list.get("sessions").?.array.items) |session| {
        if (uintField(session.object, "sid") != sid) continue;
        if (!std.mem.eql(u8, stringField(session.object, "pause") orelse "none", expected)) return error.PauseListingMismatch;
        return;
    }
    return error.PausedSessionMissing;
}

fn pauseStartDaemon(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, exe: []const u8, groups: *std.ArrayList(std.posix.pid_t)) !void {
    const result = try process_io.run(gpa, io, .{
        .argv = &.{ exe, "ls" },
        .environ_map = env,
        .cwd = .{ .path = cwd },
        .stdout_limit = 256 * 1024,
        .stderr_limit = 256 * 1024,
        .timeout_ms = helper_timeout_ms,
    });
    defer result.deinit(gpa);
    if (result.process_group_id) |group| try groups.append(gpa, group);
    if (result.term != .exited or result.term.exited != 0) return error.PauseDaemonRestartFailed;
}

fn assertFullAccess(conn: *ProtocolConn, arena: std.mem.Allocator, sid: u64, expected: bool) !void {
    try conn.send(.{ .session_list = .{ .include_archived = false } });
    const result = try recvTagBounded(conn, arena, "session_list_result");
    for (result.get("sessions").?.array.items) |item| {
        if (uintField(item.object, "sid") != sid) continue;
        const full = item.object.get("full_access") orelse return error.FullAccessMissing;
        if (full != .bool or full.bool != expected) return error.FullAccessMismatch;
        return;
    }
    return error.SessionIdMissing;
}

fn checkProjectPermissionsFlow(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, exe: []const u8, groups: *std.ArrayList(std.posix.pid_t)) !void {
    var memory = std.heap.ArenaAllocator.init(gpa);
    defer memory.deinit();
    const arena = memory.allocator();
    const checkout = try std.fs.path.join(arena, &.{ cwd, "project" });
    const other = try std.fs.path.join(arena, &.{ cwd, "project-other" });
    const cache = try std.fs.path.join(arena, &.{ cwd, "build cache" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ checkout, ".git" }));
    try Io.Dir.cwd().createDirPath(io, other);
    try Io.Dir.cwd().createDirPath(io, cache);
    var conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    const first = try pauseCreate(conn, arena, checkout, "default");
    try conn.send(.{ .project_permissions = .{ .sid = first, .action = .allow, .path = cache } });
    const saved = try recvTagBounded(conn, arena, "project_permissions_result");
    const canonical_cache = try Io.Dir.realPathFileAbsoluteAlloc(io, cache, arena);
    const roots = saved.get("write_roots").?.array.items;
    if (roots.len != 1 or !std.mem.eql(u8, roots[0].string, canonical_cache)) return error.ProjectGrantNotSaved;
    try assertFullAccess(conn, arena, first, false);
    // A separate session immediately sees the saved project permission;
    // a similarly named sibling never inherits it.
    const second = try pauseCreate(conn, arena, checkout, "default");
    try conn.send(.{ .project_permissions = .{ .sid = second } });
    const inherited = try recvTagBounded(conn, arena, "project_permissions_result");
    if (inherited.get("write_roots").?.array.items.len != 1) return error.ProjectGrantNotInherited;
    const sibling = try pauseCreate(conn, arena, other, "default");
    try conn.send(.{ .project_permissions = .{ .sid = sibling } });
    const isolated = try recvTagBounded(conn, arena, "project_permissions_result");
    if (isolated.get("write_roots").?.array.items.len != 0) return error.ProjectGrantEscaped;
    const secret = try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.NoHome, ".ssh" });
    try conn.send(.{ .project_permissions = .{ .sid = first, .action = .allow, .path = secret } });
    const denied = try recvTagBounded(conn, arena, "err");
    if (!std.mem.eql(u8, stringField(denied, "code") orelse "", "permission_path_refused")) return error.ProtectedProjectGrantAllowed;
    for (0..2) |restart| {
        try conn.send(.{ .reboot = .{ .suspend_sessions = true } });
        _ = try recvTagBounded(conn, arena, "ok");
        while (true) {
            _ = recvBounded(conn, arena) catch |err| {
                if (err != error.EndOfStream and err != error.ReadFailed) return err;
                break;
            };
        }
        try pauseStartDaemon(gpa, io, env, cwd, exe, groups);
        const replacement = try connectProtocol(gpa, io, env);
        conn.deinit();
        conn = replacement;
        try conn.send(.{ .project_permissions = .{ .sid = second } });
        const restored = try recvTagBounded(conn, arena, "project_permissions_result");
        if (restored.get("write_roots").?.array.items.len != (if (restart == 0) @as(usize, 1) else 0)) return error.ProjectGrantRestoreMismatch;
        try assertFullAccess(conn, arena, second, false);
        if (restart == 0) {
            try conn.send(.{ .project_permissions = .{ .sid = first, .action = .revoke, .path = cache } });
            const revoked = try recvTagBounded(conn, arena, "project_permissions_result");
            if (revoked.get("write_roots").?.array.items.len != 0) return error.ProjectGrantNotRevoked;
        }
    }
}

fn checkSessionRestoreFlow(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, exe: []const u8, groups: *std.ArrayList(std.posix.pid_t)) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    const full = try pauseCreate(conn, arena, cwd, "auto");
    const changed = try pauseCreate(conn, arena, cwd, "default");
    try assertFullAccess(conn, arena, changed, false);
    try conn.send(.{ .session_set_approvals = .{ .sid = changed, .approvals = "auto" } });
    _ = try recvTagBounded(conn, arena, "ok");
    try conn.send(.{ .unsub = .{ .sid = full } });
    try conn.send(.{ .unsub = .{ .sid = changed } });
    try assertFullAccess(conn, arena, full, true);
    try assertFullAccess(conn, arena, changed, true);
    // A client left this half-written prompt in `changed`'s composer.
    try conn.send(.{ .session_draft = .{ .sid = changed, .text = "unsent across reboots" } });
    for (0..2) |restart| {
        try conn.send(.{ .reboot = .{ .suspend_sessions = true } });
        _ = try recvTagBounded(conn, arena, "ok");
        while (true) {
            _ = recvBounded(conn, arena) catch |err| {
                if (err != error.EndOfStream and err != error.ReadFailed) return err;
                break;
            };
        }
        try pauseStartDaemon(gpa, io, env, cwd, exe, groups);
        const replacement = try connectProtocol(gpa, io, env);
        conn.deinit();
        conn = replacement;
        // Assert the unloaded catalog, before any tab rehydrates a session.
        try assertFullAccess(conn, arena, full, true);
        try assertFullAccess(conn, arena, changed, restart == 0);
        if (restart == 0) {
            try conn.send(.{ .session_set_approvals = .{ .sid = changed, .approvals = "default" } });
            _ = try recvTagBounded(conn, arena, "ok");
            try assertFullAccess(conn, arena, changed, false);
            try conn.send(.{ .sub = .{ .sid = full, .from_seq = 0 } });
            _ = try recvTagBounded(conn, arena, "status");
            try conn.send(.{ .input = .{ .sid = full, .text = "remember this prompt after reconnect" } });
            // A lost grant would park the write tool and time out here.
            try pauseWaitState(conn, arena, full, "none", "idle");
        }
        // The draft came through the restart for whoever opens the session.
        try conn.send(.{ .sub = .{ .sid = changed, .tail_limit = 1 } });
        _ = try recvTagBounded(conn, arena, "status");
        const draft = try recvTagBounded(conn, arena, "draft");
        if (uintField(draft, "sid") != changed or !std.mem.eql(u8, stringField(draft, "text") orelse "", "unsent across reboots")) return error.DraftLostInRestart;
        try conn.send(.{ .unsub = .{ .sid = changed } });
        _ = try recvTagBounded(conn, arena, "ok");
    }
    try conn.send(.{ .sub = .{ .sid = full, .tail_limit = 1, .prompt_history_limit = 200 } });
    const history = try recvTagBounded(conn, arena, "input_history_result");
    if (uintField(history, "sid") != full) return error.HistorySessionMismatch;
    const entries = history.get("entries").?.array.items;
    if (entries.len != 1 or !std.mem.eql(u8, stringField(entries[0].object, "text") orelse "", "remember this prompt after reconnect")) return error.PromptHistoryMissing;
    // The status gauge came back from the store across both restarts, and a
    // subscriber gets it at once instead of after the next turn.
    const meta = try recvTagBounded(conn, arena, "session_meta");
    if (uintField(meta, "sid") != full or (uintField(meta, "context_used") orelse 0) == 0 or
        (uintField(meta, "context_limit") orelse 0) == 0) return error.ContextGaugeLost;
    try conn.send(.{ .sub = .{ .sid = changed, .prompt_history_limit = 200 } });
    const empty = try recvTagBounded(conn, arena, "input_history_result");
    if (uintField(empty, "sid") != changed or empty.get("entries").?.array.items.len != 0) return error.HistoryLeakedAcrossSessions;
}

/// Regression: after a remote reboot the client re-execs its follow-up
/// (`attach @sid` in the TUI), and that exec dropped MARLIN_REMOTE, which
/// `--remote` keeps only in the in-process environment map. The follow-up
/// then ran against this machine, so the TUI said "invalid session handle".
/// Here the scenario daemon plays the remote host: a fake `ssh` on PATH runs
/// the remote command with the scenario's state (and, like ssh, without the
/// local environment's MARLIN_REMOTE), and finds marlin where the
/// installers put it (~/.local/bin). The local side gets its own empty state.
fn checkRemoteRebootFlow(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, exe: []const u8, groups: *std.ArrayList(std.posix.pid_t)) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var conn = try ProtocolConn.connect(gpa, io, env);
    try conn.send(.{ .hello = .{ .proto_version = proto.proto_version, .client_kind = "e2e-protocol" } });
    const hello = try recvTagBounded(conn, arena, "hello_ok");
    const old_pid = uintField(hello, "daemon_pid") orelse 0;
    _ = try pauseCreate(conn, arena, cwd, "default");
    conn.deinit();

    const remote_home = env.get("HOME").?;
    const installed_dir = try std.fs.path.join(arena, &.{ remote_home, ".local", "bin" });
    try Io.Dir.cwd().createDirPath(io, installed_dir);
    try writeExecutable(gpa, io, try std.fs.path.join(arena, &.{ installed_dir, "marlin" }), try std.fmt.allocPrint(arena, "#!/bin/sh\nexec '{s}' \"$@\"\n", .{exe}));
    const fake_bin = try std.fs.path.join(arena, &.{ cwd, "fake-bin" });
    try Io.Dir.cwd().createDirPath(io, fake_bin);
    try writeExecutable(gpa, io, try std.fs.path.join(arena, &.{ fake_bin, "ssh" }), try std.fmt.allocPrint(arena,
        \\#!/bin/sh
        \\for command; do :; done
        \\unset MARLIN_REMOTE
        \\HOME='{s}' XDG_STATE_HOME='{s}' MARLIN_SOCKET='{s}' exec /bin/sh -c "$command"
        \\
    , .{ remote_home, env.get("XDG_STATE_HOME").?, env.get("MARLIN_SOCKET").? }));

    var local = try env.clone(arena);
    const local_home = try std.fs.path.join(arena, &.{ cwd, "local-home" });
    try Io.Dir.cwd().createDirPath(io, local_home);
    try local.put("HOME", local_home);
    try local.put("XDG_STATE_HOME", local_home);
    try local.put("MARLIN_SOCKET", try std.fs.path.join(arena, &.{ local_home, "daemon.sock" }));
    try local.put("PATH", try std.fmt.allocPrint(arena, "{s}:/usr/bin:/bin:/usr/sbin:/sbin", .{fake_bin}));

    const result = try process_io.run(gpa, io, .{
        .argv = &.{ exe, "--remote", "fakehost", "reboot", "--then", "diagnostics", "--daemon", "--json" },
        .environ_map = &local,
        .cwd = .{ .path = cwd },
        .stdout_limit = 256 * 1024,
        .stderr_limit = 256 * 1024,
        .timeout_ms = scenario_timeout_ms,
    });
    defer result.deinit(gpa);
    if (result.process_group_id) |group| try groups.append(gpa, group);
    if (result.term != .exited or result.term.exited != 0) {
        print(io, "\n  remote reboot follow-up failed\n  stdout: {s}\n  stderr: {s}\n", .{ result.stdout, result.stderr });
        return error.RemoteRebootFollowUpFailed;
    }
    const identity = try std.json.parseFromSliceLeaky(std.json.Value, arena, result.stdout, .{});
    const remote = identity.object.get("remote") orelse .null;
    if (remote != .string or !std.mem.eql(u8, remote.string, "fakehost")) return error.FollowUpLostRemote;
    const new_pid = uintField(identity.object, "daemon_pid") orelse 0;
    if (new_pid == 0 or new_pid == old_pid) return error.RemoteDaemonNotRestarted;
}

/// Type into a shell and wait until its output shows `expect`.
fn shellRoundTrip(conn: *ProtocolConn, arena: std.mem.Allocator, shell_id: u64, text: []const u8, expect: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const typed = try arena.alloc(u8, encoder.calcSize(text.len));
    try conn.send(.{ .shell_input = .{ .shell_id = shell_id, .data_base64 = encoder.encode(typed, text) } });
    var seen: std.ArrayList(u8) = .empty;
    while (std.mem.indexOf(u8, seen.items, expect) == null) {
        const output = try recvTagBounded(conn, arena, "shell_output");
        const encoded = stringField(output, "data_base64") orelse continue;
        const decoder = std.base64.standard.Decoder;
        const bytes = try arena.alloc(u8, try decoder.calcSizeForSlice(encoded));
        try decoder.decode(bytes, encoded);
        try seen.appendSlice(arena, bytes);
        try conn.send(.{ .shell_ack = .{ .shell_id = shell_id, .bytes = bytes.len } });
    }
}

/// Flood a shell, press Ctrl+C, and type a command: the command must
/// answer promptly, and little of the flood may follow the interrupt.
fn checkShellInterruptFlow(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    try conn.send(.{ .session_create = .{ .cwd = cwd, .model = "local/testing" } });
    const sid = uintField(try recvTagBounded(conn, arena, "session_created"), "sid") orelse return error.SessionIdMissing;
    try conn.send(.{ .shell_open = .{ .sid = sid, .cols = 200, .rows = 50 } });
    const shell_id = uintField(try recvTagBounded(conn, arena, "shell_opened"), "shell_id") orelse return error.ShellIdMissing;
    try shellRoundTrip(conn, arena, shell_id, "echo ready-$((40+2))\r", "ready-42");

    const encoder = std.base64.standard.Encoder;
    const decoder = std.base64.standard.Decoder;
    var typed: [256]u8 = undefined;
    try conn.send(.{ .shell_input = .{ .shell_id = shell_id, .data_base64 = encoder.encode(&typed, "yes '05:25:38.337916  read              F=9    B=0xfa                                                  0.000001   sudo.72343672'\r") } });

    // A client slower than the program, as a TUI on a loaded machine is
    // (about 3 MB/s): it falls behind and is resynced with snapshots.
    const consumer_us_per_kib: u64 = 300;
    var interrupted_at: ?Io.Timestamp = null;
    var live_after: usize = 0;
    var snapshots_after: usize = 0;
    var tail: [32]u8 = @splat(0);
    while (true) {
        var line_arena = std.heap.ArenaAllocator.init(gpa);
        defer line_arena.deinit();
        const msg = try conn.recv(line_arena.allocator());
        const object = tagObject(msg, "shell_output") orelse tagObject(msg, "shell_snapshot") orelse continue;
        const is_snapshot = tagObject(msg, "shell_snapshot") != null;
        const encoded = stringField(object, "data_base64") orelse continue;
        const bytes = try line_arena.allocator().alloc(u8, try decoder.calcSizeForSlice(encoded));
        try decoder.decode(bytes, encoded);
        try io.sleep(.fromMicroseconds(@intCast(consumer_us_per_kib * bytes.len / 1024)), .awake);
        if (!is_snapshot) try conn.send(.{ .shell_ack = .{ .shell_id = shell_id, .bytes = bytes.len } });
        if (interrupted_at == null) {
            // Right after a catch-up snapshot the window refills at once:
            // Ctrl+C then goes out with the most output possible in flight.
            if (!is_snapshot) continue;
            try io.sleep(.fromMilliseconds(100), .awake);
            interrupted_at = Io.Timestamp.now(io, .awake);
            try conn.send(.{ .shell_input = .{ .shell_id = shell_id, .data_base64 = encoder.encode(&typed, "\x03") } });
            try conn.send(.{ .shell_input = .{ .shell_id = shell_id, .data_base64 = encoder.encode(&typed, "echo after-$((6*7))\r") } });
            continue;
        }
        if (is_snapshot) snapshots_after += 1 else live_after += bytes.len;
        const joined = try std.mem.concat(line_arena.allocator(), u8, &.{ &tail, bytes });
        if (std.mem.indexOf(u8, joined, "after-42") != null) break;
        @memcpy(&tail, joined[joined.len - tail.len ..]);
    }
    const elapsed_ms = interrupted_at.?.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    // What was in flight when Ctrl+C went out: at most the viewer window of
    // live output, and one snapshot to catch up (4 MiB and several, before).
    if (live_after > 2 * 256 * 1024 or snapshots_after > 1) {
        print(io, "\n  ctrl+c answered after {d} ms, behind {d} KiB of output and {d} snapshots\n", .{ elapsed_ms, live_after / 1024, snapshots_after });
        return error.ShellInterruptBehindBacklog;
    }
}

fn checkHandoverFlow(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, flow: []const u8) !void {
    if (std.mem.startsWith(u8, flow, "guest_")) return checkGuestHandover(gpa, io, env, cwd, Guest.of(flow));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const abort = std.mem.eql(u8, flow, "abort");

    var watcher = try ProtocolConn.connect(gpa, io, env);
    var watcher_open = true;
    defer if (watcher_open) watcher.deinit();
    try watcher.send(.{ .hello = .{ .proto_version = proto.proto_version, .client_kind = "e2e-protocol" } });
    const hello = try recvTagBounded(watcher, arena, "hello_ok");
    if (hello.get("handover") == null) return error.HandoverNotAdvertised;
    const old_pid: std.posix.pid_t = @intCast(uintField(hello, "daemon_pid") orelse return error.DaemonPidMissing);
    try watcher.send(.{ .handover_watch = struct {}{} });
    try watcher.send(.{ .session_create = .{ .cwd = cwd, .model = "local/testing" } });
    const sid = uintField(try recvTagBounded(watcher, arena, "session_created"), "sid") orelse return error.SessionIdMissing;
    try watcher.send(.{ .shell_open = .{ .sid = sid, .cols = 80, .rows = 24 } });
    const shell_id = uintField(try recvTagBounded(watcher, arena, "shell_opened"), "shell_id") orelse return error.ShellIdMissing;
    try shellRoundTrip(watcher, arena, shell_id, "echo before-$((40+2))\r", "before-42");

    // A second watcher that never comes back.
    const absent = try connectProtocol(gpa, io, env);
    defer absent.deinit();
    try absent.send(.{ .handover_watch = struct {}{} });

    const requester = try connectProtocol(gpa, io, env);
    defer requester.deinit();
    try requester.send(.{ .reboot = .{ .handover = true } });
    _ = try recvTagBounded(requester, arena, "ok");

    if (abort) {
        // The successor fails while starting: the watcher hears why and
        // stays connected to a daemon that carries on.
        const notice = try recvTagBounded(watcher, arena, "daemon_notice");
        while (true) {
            const err_notice = if (notice.get("err")) |e| e == .bool and e.bool else false;
            if (err_notice) break;
            const next = try recvTagBounded(watcher, arena, "daemon_notice");
            if (next.get("err")) |e| if (e == .bool and e.bool) break;
        }
        const refused = try recvBounded(requester, arena);
        if (tagObject(refused, "err") == null) return error.HandoverAbortNotReported;
        try shellRoundTrip(watcher, arena, shell_id, "echo still-$((1+1))\r", "still-2");
        try watcher.send(.{ .session_create = .{ .cwd = cwd, .model = "local/testing" } });
        _ = try recvTagBounded(watcher, arena, "session_created");
        const again = try connectProtocol(gpa, io, env);
        defer again.deinit();
        try again.send(.{ .hello = .{ .proto_version = proto.proto_version } });
        if (uintField(try recvTagBounded(again, arena, "hello_ok"), "daemon_pid") != @as(u64, @intCast(old_pid))) return error.HandoverAbortReplacedDaemon;
        return;
    }

    var token: ?[]const u8 = null;
    while (true) {
        const msg = recvBounded(watcher, arena) catch |err| {
            if (err != error.EndOfStream and err != error.ReadFailed) return err;
            break;
        };
        if (tagObject(msg, "daemon_handover")) |moved| token = stringField(moved, "token");
    }
    watcher.deinit();
    watcher_open = false;
    const presented = token orelse return error.HandoverTokenMissing;

    var moved = try connectProtocol(gpa, io, env);
    defer moved.deinit();
    try moved.send(.{ .hello = .{ .proto_version = proto.proto_version } });
    const new_pid = uintField(try recvTagBounded(moved, arena, "hello_ok"), "daemon_pid") orelse 0;
    if (new_pid == 0 or new_pid == @as(u64, @intCast(old_pid))) return error.HandoverNoSuccessor;
    try moved.send(.{ .handover_watch = struct {}{} });
    try moved.send(.{ .shell_attach = .{ .shell_id = shell_id, .cols = 80, .rows = 24 } });
    const snapshot = try recvTagBounded(moved, arena, "shell_snapshot");
    const encoded = stringField(snapshot, "data_base64") orelse return error.ShellSnapshotMissing;
    const decoder = std.base64.standard.Decoder;
    const screen = try arena.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(screen, encoded);
    if (std.mem.indexOf(u8, screen, "before-42") == null) return error.HandoverShellScreenLost;
    try moved.send(.{ .handover_arrived = .{ .token = presented } });

    // The other watcher is still owed its wait ([reboot] handover_wait).
    try io.sleep(.fromMilliseconds(500), .awake);
    if (std.c.kill(old_pid, @fromBackingInt(@intCast(0))) != 0) return error.HandoverDidNotWaitForEveryClient;
    if (!waitPidGone(io, old_pid, helper_timeout_ms)) return error.HandoverPredecessorStayed;

    // The same shell, now the successor's: it runs, and its end is noticed
    // (with an unknown status: it is not the successor's child).
    try shellRoundTrip(moved, arena, shell_id, "echo after-$((1+1))\r", "after-2");
    const encoder = std.base64.standard.Encoder;
    var exit_buf: [16]u8 = undefined;
    try moved.send(.{ .shell_input = .{ .shell_id = shell_id, .data_base64 = encoder.encode(&exit_buf, "exit\r") } });
    const exited = try recvTagBounded(moved, arena, "shell_exited");
    if (exited.get("code")) |code| if (code != .null) return error.HandoverShellStatusInvented;
}

/// The guest agent a `guest_*` flow drives, through its fake binary.
const Guest = enum {
    claude,
    codex,
    agy,

    fn of(flow: []const u8) Guest {
        inline for (.{ Guest.claude, Guest.agy }) |guest| {
            if (std.mem.startsWith(u8, flow, "guest_" ++ @tagName(guest))) return guest;
        }
        return .codex;
    }

    fn model(guest: Guest) []const u8 {
        return switch (guest) {
            .claude => "claudecode/default",
            .codex => "codex/default",
            .agy => "agy/default",
        };
    }

    fn binEnv(guest: Guest) []const u8 {
        return switch (guest) {
            .claude => "MARLIN_CLAUDE_CODE_BIN",
            .codex => "MARLIN_CODEX_BIN",
            .agy => "MARLIN_AGY_BIN",
        };
    }

    /// What a login-required error tells the user to run.
    fn loginCommand(guest: Guest) []const u8 {
        return switch (guest) {
            .claude => "claude auth login",
            .codex => "codex login",
            .agy => "`agy`",
        };
    }
};

/// A guest turn running across a graceful handover: its guest is not
/// stopped or resumed but followed by the successor, which finishes the
/// same turn with every block exactly once.
fn checkGuestHandover(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, guest: Guest) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var watcher = try ProtocolConn.connect(gpa, io, env);
    var watcher_open = true;
    defer if (watcher_open) watcher.deinit();
    try watcher.send(.{ .hello = .{ .proto_version = proto.proto_version, .client_kind = "e2e-protocol" } });
    const hello = try recvTagBounded(watcher, arena, "hello_ok");
    const old_pid: std.posix.pid_t = @intCast(uintField(hello, "daemon_pid") orelse return error.DaemonPidMissing);
    try watcher.send(.{ .handover_watch = struct {}{} });
    try watcher.send(.{ .session_create = .{ .cwd = cwd, .model = guest.model(), .approvals = "auto" } });
    const sid = uintField(try recvTagBounded(watcher, arena, "session_created"), "sid") orelse return error.SessionIdMissing;
    try watcher.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
    try watcher.send(.{ .input = .{ .sid = sid, .text = "guest handover task" } });
    try pauseWaitCall(watcher, arena, sid);
    const pid_path = try std.fs.path.join(arena, &.{ cwd, "guest-pid" });
    const guest_pid = try std.fmt.parseInt(std.posix.pid_t, try Io.Dir.cwd().readFileAlloc(io, pid_path, arena, .limited(128)), 10);
    // A kept guest is in a session of its own, beyond the runner's group
    // cleanup: whatever happens here, it does not outlive the scenario.
    defer _ = std.c.kill(-guest_pid, .KILL);

    const requester = try connectProtocol(gpa, io, env);
    defer requester.deinit();
    try requester.send(.{ .reboot = .{ .handover = true } });
    _ = try recvTagBounded(requester, arena, "ok");
    var token: ?[]const u8 = null;
    while (true) {
        const msg = recvBounded(watcher, arena) catch |err| {
            if (err != error.EndOfStream and err != error.ReadFailed) return err;
            break;
        };
        if (tagObject(msg, "daemon_handover")) |moved| token = stringField(moved, "token");
    }
    watcher.deinit();
    watcher_open = false;

    var moved = try connectProtocol(gpa, io, env);
    defer moved.deinit();
    try moved.send(.{ .hello = .{ .proto_version = proto.proto_version } });
    const new_pid = uintField(try recvTagBounded(moved, arena, "hello_ok"), "daemon_pid") orelse 0;
    if (new_pid == 0 or new_pid == @as(u64, @intCast(old_pid))) return error.HandoverNoSuccessor;
    try moved.send(.{ .handover_watch = struct {}{} });
    try moved.send(.{ .handover_arrived = .{ .token = token orelse return error.HandoverTokenMissing } });
    if (!waitPidGone(io, old_pid, helper_timeout_ms)) return error.HandoverPredecessorStayed;
    // The guest outlived its daemon: the same process, still parked.
    if (std.c.kill(guest_pid, @fromBackingInt(@intCast(0))) != 0) return error.GuestDiedInHandover;

    // Everything the session holds, from its first block: what the old
    // daemon persisted and what the new one adds, each exactly once.
    try moved.send(.{ .sub = .{ .sid = sid, .from_seq = 1 } });
    const release = try std.fs.path.joinZ(arena, &.{ cwd, "release" });
    const fifo = std.c.open(release, .{ .ACCMODE = .WRONLY });
    if (fifo < 0) return error.GuestReleaseFailed;
    _ = std.c.write(fifo, "go\n", 3);
    _ = std.c.close(fifo);

    var user_msgs: usize = 0;
    var calls: usize = 0;
    var results: usize = 0;
    var answers: usize = 0;
    var commentary: usize = 0;
    var notes: std.ArrayList(u8) = .empty;
    // A block stored while this subscription read its history also arrives
    // live; clients drop it by seq (tui.zig, webui.html), and so does this.
    // A block stored twice has two seqs and still counts twice.
    var last_seq: u64 = 0;
    var repeats: usize = 0;
    while (true) {
        const msg = try recvBounded(moved, arena);
        if (tagObject(msg, "status")) |status| {
            if (uintField(status, "sid") != sid) continue;
            const state = stringField(status, "state") orelse "";
            if (std.mem.eql(u8, state, "err")) {
                print(io, "turn error: {s}\n", .{stringField(status, "err_text") orelse "unknown"});
                return error.GuestHandoverTurnFailed;
            }
            if (std.mem.eql(u8, state, "idle") and answers > 0) break;
            continue;
        }
        const blk = tagObject(msg, "blk") orelse continue;
        if (uintField(blk, "sid") != sid) continue;
        const b = objectField(blk, "b") orelse continue;
        const seq = uintField(b, "seq") orelse 0;
        if (seq <= last_seq) {
            repeats += 1;
            continue;
        }
        last_seq = seq;
        const body = objectField(b, "body") orelse continue;
        if (objectField(body, "user_msg") != null) user_msgs += 1;
        if (objectField(body, "tool_call") != null) calls += 1;
        if (objectField(body, "tool_result") != null) results += 1;
        if (objectField(body, "assistant_msg")) |a| {
            if (!std.mem.eql(u8, stringField(a, "text") orelse "", "guest finished across the handover")) return error.GuestHandoverWrongAnswer;
            answers += 1;
        }
        if (objectField(body, "reasoning")) |r| {
            if (std.mem.indexOf(u8, stringField(r, "text") orelse "", "Commentary before the restart") != null) commentary += 1;
        }
        if (objectField(body, "system_note")) |n| try notes.print(arena, "{s}\n", .{stringField(n, "text") orelse ""});
    }
    // Claude's commentary arrives before its tool call; this Codex and agy
    // have none.
    if (user_msgs != 1 or calls != 1 or results != 1 or answers != 1 or commentary != @intFromBool(guest == .claude)) {
        print(io, "blocks: user {d} call {d} result {d} answer {d} commentary {d} ({d} repeated seqs dropped); notes:\n{s}", .{ user_msgs, calls, results, answers, commentary, repeats, notes.items });
        return error.GuestHandoverBlocksWrong;
    }
    if (notes.items.len > 0) {
        print(io, "unexpected notes:\n{s}", .{notes.items});
        return error.GuestHandoverUnexpectedNote;
    }
    if (!waitPidGone(io, guest_pid, helper_timeout_ms)) return error.GuestOutlivedItsTurn;
    // The finished turn's journal is gone.
    const root = try std.fs.path.join(arena, &.{ cwd, "marlin", "g" });
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        print(io, "left behind: {s}\n", .{entry.name});
        return error.GuestJournalLeftBehind;
    }
}

fn checkCodexQuestionFlow(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    for ([_][]const u8{ "default", "auto" }) |mode| {
        try conn.send(.{ .session_create = .{ .cwd = cwd, .model = "codex/default", .approvals = mode } });
        const sid = uintField(try recvTagBounded(conn, arena, "session_created"), "sid").?;
        try conn.send(.{ .sub = .{ .sid = sid } });
        for ([_][]const u8{ "Per session", "Keep 175 prompts — please" }, 0..) |answer, round| {
            try conn.send(.{ .input = .{ .sid = sid, .text = "ask about history" } });
            var question = try recvTagBounded(conn, arena, "question_request");
            if (uintField(question, "sid") != sid or !std.mem.eql(u8, stringField(question, "question") orelse "", "Where should history live?")) return error.WrongGuestQuestion;
            const options = question.get("options").?.array.items;
            if (options.len != 2 or !std.mem.eql(u8, options[0].string, "Per session")) return error.WrongGuestOptions;
            if (round == 1) {
                const replacement = try connectProtocol(gpa, io, env);
                conn.deinit();
                conn = replacement;
                try conn.send(.{ .sub = .{ .sid = sid } });
                question = try recvTagBounded(conn, arena, "question_request");
            }
            try conn.send(.{ .question_answer = .{ .sid = sid, .question_id = stringField(question, "question_id").?, .answer = answer } });
            try pauseWaitState(conn, arena, sid, "none", "idle");
            const path = try std.fmt.allocPrint(arena, "{s}/answer-{d}", .{ cwd, sid });
            const actual = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024));
            if (!std.mem.eql(u8, answer, actual)) return error.GuestAnswerMismatch;
        }
    }
}

fn checkPauseFlow(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, exe: []const u8, groups: *std.ArrayList(std.posix.pid_t), flow: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    if (std.mem.startsWith(u8, flow, "guest_")) {
        const guest = Guest.of(flow);
        try conn.send(.{ .session_create = .{ .cwd = cwd, .model = guest.model(), .approvals = "auto" } });
        const created = try recvTagBounded(conn, arena, "session_created");
        const sid = uintField(created, "sid").?;
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
        try conn.send(.{ .input = .{ .sid = sid, .text = "guest pause task" } });
        if (std.mem.indexOf(u8, flow, "_auth_") != null) {
            while (true) {
                const status = try recvTagBounded(conn, arena, "status");
                if (uintField(status, "sid") != sid) continue;
                if (!std.mem.eql(u8, stringField(status, "state") orelse "", "err")) continue;
                const message = stringField(status, "err_text") orelse return error.AuthErrorMissing;
                const command = guest.loginCommand();
                if (std.mem.indexOf(u8, message, command) == null or std.mem.indexOf(u8, message, "daemon host") == null) return error.AuthLoginInstructionMissing;
                break;
            }
            const path = try std.fs.path.join(arena, &.{ cwd, "auth-attempts" });
            const attempts = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024));
            if (!std.mem.eql(u8, attempts, "attempt\n")) return error.AuthFailureWasRetried;
            return;
        }
        try pauseWaitCall(conn, arena, sid);
        const pid_path = try std.fs.path.join(arena, &.{ cwd, "guest-pid" });
        const pid_text = try Io.Dir.cwd().readFileAlloc(io, pid_path, arena, .limited(128));
        const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
        try conn.send(.{ .session_pause = .{ .all = true } });
        _ = try recvTagBounded(conn, arena, "ok");
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
        try pauseWaitState(conn, arena, sid, "paused", "idle");
        if (std.c.kill(pid, @fromBackingInt(@intCast(0))) == 0) return error.PausedGuestStillRunning;
        try conn.send(.{ .reboot = .{ .suspend_sessions = true } });
        _ = try recvTagBounded(conn, arena, "ok");
        while (true) {
            _ = recvBounded(conn, arena) catch |err| {
                if (err != error.EndOfStream and err != error.ReadFailed) return err;
                break;
            };
        }
        try pauseStartDaemon(gpa, io, env, cwd, exe, groups);
        const replacement = try connectProtocol(gpa, io, env);
        conn.deinit();
        conn = replacement;
        try pauseAssertListed(conn, arena, sid, "paused");
        try conn.send(.{ .session_resume = .{ .all = true } });
        _ = try recvTagBounded(conn, arena, "ok");
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
        try pauseWaitState(conn, arena, sid, "none", "idle");
        try pauseAssertListed(conn, arena, sid, "none");
        return;
    }
    if (std.mem.eql(u8, flow, "parallel")) {
        var sessions: [4]u64 = undefined;
        for (&sessions) |*sid| sid.* = try pauseCreate(conn, arena, cwd, "auto");
        for (0..3) |cycle| {
            for (sessions) |sid| {
                try conn.send(.{ .input = .{ .sid = sid, .text = "parallel pause task" } });
                try pauseWaitCall(conn, arena, sid);
            }
            // Outlast the old one-second fixture race while all four tools
            // remain parked behind a gate owned by this protocol client.
            if (cycle == 0) try io.sleep(.fromMilliseconds(1_200), .awake);
            try conn.send(.{ .session_pause = .{ .all = true } });
            _ = try recvTagBounded(conn, arena, "ok");
            try conn.send(.{ .session_resume = .{ .sid = sessions[0] } });
            try expectDaemonError(conn, arena, "busy");
            const release = try std.fmt.allocPrint(arena, "{s}/pause-release-{d}", .{ cwd, cycle });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = release, .data = "" });
            for (sessions) |sid| {
                try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
                try pauseWaitState(conn, arena, sid, "paused", "idle");
                try pauseAssertListed(conn, arena, sid, "paused");
            }
            try conn.send(.{ .session_resume = .{ .all = true } });
            _ = try recvTagBounded(conn, arena, "ok");
            for (sessions) |sid| {
                try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
                try pauseWaitState(conn, arena, sid, "none", "idle");
            }
        }
        return;
    }
    if (std.mem.eql(u8, flow, "child")) {
        try conn.send(.{ .session_watch = .{ .incremental = true } });
        const sid = try pauseCreate(conn, arena, cwd, "auto");
        try conn.send(.{ .input = .{ .sid = sid, .text = "parent pause task" } });
        const child_sid = while (true) {
            const update = try recvTagBounded(conn, arena, "session_upsert");
            const child = update.get("session").?.object;
            if (uintField(child, "parent_sid") == sid) break uintField(child, "sid").?;
        };
        const ready = try std.fs.path.join(arena, &.{ cwd, "child-provider.ready" });
        const deadline = Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, helper_timeout_ms) * std.time.ns_per_ms;
        while (true) {
            if (Io.Dir.cwd().access(io, ready, .{})) |_| break else |err| {
                if (err != error.FileNotFound) return err;
            }
            if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline) return error.ChildProviderNotReady;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        try conn.send(.{ .session_pause = .{ .sid = sid } });
        _ = try recvTagBounded(conn, arena, "ok");
        const release = try std.fs.path.join(arena, &.{ cwd, "child-provider.release" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = release, .data = "" });
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
        try pauseWaitState(conn, arena, sid, "paused", "idle");
        try pauseAssertListed(conn, arena, child_sid, "paused");
        try conn.send(.{ .session_resume = .{ .sid = sid } });
        _ = try recvTagBounded(conn, arena, "ok");
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
        try pauseWaitState(conn, arena, sid, "none", "idle");
        return;
    }
    const approval_flow = std.mem.eql(u8, flow, "approval");
    const question_flow = std.mem.eql(u8, flow, "question");
    const reboot_flow = std.mem.eql(u8, flow, "reboot");
    // A graceful handover: the old daemon starts its successor and waits for
    // this client to arrive there before exiting.
    const handover_flow = std.mem.eql(u8, flow, "handover");
    const crash_flow = std.mem.eql(u8, flow, "crash");
    const disconnect_flow = std.mem.eql(u8, flow, "disconnect");
    const force_flow = std.mem.eql(u8, flow, "force");
    const finish_flow = std.mem.eql(u8, flow, "finish");
    const sid = try pauseCreate(conn, arena, cwd, if (approval_flow) "default" else "auto");
    try conn.send(.{ .input = .{ .sid = sid, .text = "pause stress task" } });
    if (approval_flow) {
        var id_buf: [32]u8 = undefined;
        _ = try waitApproval(conn, arena, sid, &id_buf);
    } else if (question_flow) {
        _ = try recvTagBounded(conn, arena, "question_request");
    } else if (finish_flow) {
        _ = try recvTagBounded(conn, arena, "delta");
    } else try pauseWaitCall(conn, arena, sid);

    if (!finish_flow) {
        try conn.send(.{ .input = .{ .sid = sid, .text = "queued before suspension", .request_id = 77, .attachments = &.{.{ .name = "pause.png", .mime = "image/png", .data_base64 = "iVBORw0KGgpwYXlsb2Fk" }} } });
        _ = try recvTagBounded(conn, arena, "ok");
    }
    try conn.send(.{ .session_pause = .{ .sid = sid, .force = force_flow } });
    _ = try recvTagBounded(conn, arena, "ok");
    if (finish_flow) {
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
        try pauseWaitState(conn, arena, sid, "none", "idle");
        try pauseAssertListed(conn, arena, sid, "none");
        return;
    }
    // Duplicate requests are harmless, and input cannot accidentally unpause.
    try conn.send(.{ .session_pause = .{ .sid = sid } });
    try conn.send(.{ .input = .{ .sid = sid, .text = "must remain a draft", .request_id = 78 } });
    try expectDaemonError(conn, arena, "paused");
    // A fresh subscription verifies the persisted state even when an earlier
    // terminal status was consumed while waiting for an acknowledgement.
    try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
    try pauseWaitState(conn, arena, sid, "paused", "idle");
    try pauseAssertListed(conn, arena, sid, "paused");

    if (reboot_flow or crash_flow or disconnect_flow or handover_flow) {
        if (handover_flow) try conn.send(.{ .handover_watch = struct {}{} });
        const second = try pauseCreate(conn, arena, cwd, "auto");
        try conn.send(.{ .input = .{ .sid = second, .text = "second restart task" } });
        try pauseWaitCall(conn, arena, second);
        try conn.send(.{ .input = .{ .sid = second, .text = "reboot queued screenshot", .request_id = 79, .attachments = &.{.{ .name = "reboot.png", .mime = "image/png", .data_base64 = "iVBORw0KGgpwYXlsb2Fk" }} } });
        _ = try recvTagBounded(conn, arena, "ok");
        const requester = try connectProtocol(gpa, io, env);
        var requester_open = true;
        defer if (requester_open) requester.deinit();
        try requester.send(.{ .hello = .{ .proto_version = proto.proto_version } });
        const hello = try recvTagBounded(requester, arena, "hello_ok");
        const pid = uintField(hello, "daemon_pid") orelse return error.DaemonPidMissing;
        try requester.send(.{ .reboot = .{ .suspend_sessions = true, .handover = handover_flow } });
        try pauseWaitState(conn, arena, second, "pausing", "running");
        // The second session's tool waits for this file, so its pause (and
        // with it the reboot) cannot complete before this flow has acted:
        // a fixed sleep raced a slow CI runner.
        const second_release = try std.fs.path.join(arena, &.{ cwd, "second-release" });
        if (crash_flow) {
            if (std.c.kill(@intCast(pid), std.posix.SIG.KILL) != 0) return error.DaemonKillFailed;
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = second_release, .data = "" });
        } else if (disconnect_flow) {
            requester.deinit();
            requester_open = false;
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = second_release, .data = "" });
            try pauseWaitState(conn, arena, second, "paused", "idle");
            try pauseAssertListed(conn, arena, second, "paused");
            // Shutdown without reboot intent: both sessions must remain paused.
            try conn.send(.{ .shutdown = struct {}{} });
        } else {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = second_release, .data = "" });
            _ = try recvTagBounded(requester, arena, "ok");
        }
        // EOF confirms the old daemon has released this connection; before
        // it, a handover sends the token to present to the successor.
        var token: ?[]const u8 = null;
        while (true) {
            const msg = recvBounded(conn, arena) catch |err| {
                if (err != error.EndOfStream and err != error.ReadFailed) return err;
                break;
            };
            if (tagObject(msg, "daemon_handover")) |moved| token = stringField(moved, "token");
        }
        if (handover_flow) {
            const presented = token orelse return error.HandoverTokenMissing;
            // The old daemon waits for this client, and the successor
            // already accepts on the same socket.
            if (std.c.kill(@intCast(pid), @fromBackingInt(@intCast(0))) != 0) return error.HandoverPredecessorGone;
            const replacement = try connectProtocol(gpa, io, env);
            conn.deinit();
            conn = replacement;
            try conn.send(.{ .handover_watch = struct {}{} });
            try conn.send(.{ .handover_arrived = .{ .token = presented } });
            if (!waitPidGone(io, @intCast(pid), helper_timeout_ms)) return error.HandoverPredecessorStayed;
        } else {
            try pauseStartDaemon(gpa, io, env, cwd, exe, groups);
            const replacement = try connectProtocol(gpa, io, env);
            conn.deinit();
            conn = replacement;
        }
        try pauseAssertListed(conn, arena, sid, "paused");
        if (disconnect_flow) {
            try pauseAssertListed(conn, arena, second, "paused");
            try conn.send(.{ .session_resume = .{ .sid = second } });
            _ = try recvTagBounded(conn, arena, "ok");
        }
        try conn.send(.{ .sub = .{ .sid = second, .from_seq = 0 } });
        try pauseWaitState(conn, arena, second, "none", "idle");
    } else {
        // Manual pause survives dropping every subscriber and rehydrating.
        const replacement = try connectProtocol(gpa, io, env);
        conn.deinit();
        conn = replacement;
        try pauseAssertListed(conn, arena, sid, "paused");
    }
    try conn.send(.{ .session_resume = .{ .all = true } });
    _ = try recvTagBounded(conn, arena, "ok");
    try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
    if (approval_flow) {
        var id_buf: [32]u8 = undefined;
        const id = try waitApproval(conn, arena, sid, &id_buf);
        try conn.send(.{ .approve = .{ .sid = sid, .approval_id = id, .decision = .granted } });
    } else if (question_flow) {
        const question = try recvTagBounded(conn, arena, "question_request");
        try conn.send(.{ .question_answer = .{ .sid = sid, .question_id = stringField(question, "question_id").?, .answer = "Proceed" } });
    }
    try pauseWaitState(conn, arena, sid, "none", "idle");
    try pauseAssertListed(conn, arena, sid, "none");
    // Resuming an already completed session must not issue another model call.
    try conn.send(.{ .session_resume = .{ .sid = sid } });
    _ = try recvTagBounded(conn, arena, "ok");
}

fn checkSkillInvocation(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8) !void {
    const conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try conn.send(.{ .session_list = .{ .include_archived = false } });
    const listing = try recvTagBounded(conn, arena, "session_list_result");
    const sessions = listing.get("sessions") orelse return error.SessionIdMissing;
    if (sessions != .array or sessions.array.items.len != 1) return error.SessionIdMissing;
    const sid = uintField(sessions.array.items[0].object, "sid") orelse return error.SessionIdMissing;
    try conn.send(.{ .input = .{
        .sid = sid,
        .text = "/missing",
        .skill = .{ .name = "missing" },
        .request_id = 201,
    } });
    const rejected = try recvTagBounded(conn, arena, "err");
    if (uintField(rejected, "request_id") != 201 or
        !std.mem.eql(u8, stringField(rejected, "code") orelse "", "skill")) return error.SkillRejectionMismatch;

    try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
    _ = try recvTagBounded(conn, arena, "status");
    const invocation = "/review 'parser module' tests";
    try conn.send(.{ .input = .{
        .sid = sid,
        .text = invocation,
        .skill = .{ .name = "review", .arguments = "'parser module' tests" },
        .request_id = 202,
    } });
    var saw_skill = false;
    var saw_ack = false;
    var completed = false;
    while (!completed or !saw_ack) {
        const msg = try recvBounded(conn, arena);
        if (tagObject(msg, "err")) |daemon_err| {
            reportDaemonError(io, daemon_err);
            return error.UnexpectedDaemonError;
        }
        if (tagObject(msg, "ok")) |ok| {
            if (uintField(ok, "request_id") == 202) saw_ack = true;
        }
        if (tagObject(msg, "blk")) |outer| {
            const b = objectField(outer, "b") orelse return error.BlockMissing;
            const body = objectField(b, "body") orelse return error.BlockMissing;
            if (objectField(body, "user_msg")) |user| {
                if (std.mem.eql(u8, stringField(user, "display_text") orelse "", invocation)) {
                    const text = stringField(user, "text") orelse return error.SkillBodyMissing;
                    if (std.mem.indexOf(u8, text, "SKILL_BODY_MARKER: inspect parser module with tests.") == null or
                        std.mem.indexOf(u8, text, "Base directory for relative skill resources:") == null) return error.SkillBodyMissing;
                    saw_skill = true;
                }
            }
        }
        if (tagObject(msg, "status")) |status| {
            const state = stringField(status, "state") orelse "";
            if (std.mem.eql(u8, state, "err")) return error.SkillTurnFailed;
            if (std.mem.eql(u8, state, "idle")) completed = true;
        }
    }
    if (!saw_skill) return error.SkillBodyMissing;
    // Instructions are re-read for the next turn; the earlier rendered
    // skill remains in context even when this input is ordinary prose.
    const agent_path = try std.fs.path.join(arena, &.{ cwd, "AGENT.md" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = agent_path, .data = "AGENT_EDIT_MARKER: updated project conventions." });
    try conn.send(.{ .input = .{ .sid = sid, .text = "follow up with the loaded skill", .request_id = 203 } });
    _ = try recvTagBounded(conn, arena, "ok");
    while (true) {
        const status = try recvTagBounded(conn, arena, "status");
        const state = stringField(status, "state") orelse "";
        if (std.mem.eql(u8, state, "err")) return error.SkillTurnFailed;
        if (std.mem.eql(u8, state, "idle")) break;
    }
}

fn checkPlugins(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, marlin_bin: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const repo = try std.fs.path.join(arena, &.{ cwd, "marketplace" });
    const files = .{
        .{ ".claude-plugin/marketplace.json", "{\"name\":\"fixture-market\",\"plugins\":[{\"name\":\"demo\",\"source\":\"./plugins/demo\"},{\"name\":\"unsupported\",\"source\":\"./plugins/unsupported\"}]}" },
        .{ "plugins/demo/.claude-plugin/plugin.json", "{\"name\":\"demo\",\"version\":\"1.0.0\"}" },
        .{ "plugins/demo/skills/review/SKILL.md", "---\nname: review\ndescription: Review a target with the plugin\n---\nPLUGIN_COMMAND_BODY: $ARGUMENTS.\n" },
        .{ "plugins/unsupported/.claude-plugin/plugin.json", "{\"name\":\"unsupported\",\"hooks\":{}}" },
    };
    inline for (files) |file| {
        const path = try std.fs.path.join(arena, &.{ repo, file[0] });
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file[1] });
    }
    const git_commands = [_][]const []const u8{
        &.{ "git", "init" },                                                                                                                                                           &.{ "git", "add", "." },
        &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", "fixture" },
    };
    for (git_commands) |argv| {
        const result = try process_io.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = repo }, .environ_map = env, .timeout_ms = helper_timeout_ms });
        defer result.deinit(gpa);
        if (result.term != .exited or result.term.exited != 0) return error.GitFixtureFailed;
    }
    const commands = [_]struct { args: []const []const u8, ok: bool = true, contains: []const u8 }{
        .{ .args = &.{ "marketplace", "add", "./marketplace" }, .contains = "Added marketplace fixture-market" },
        .{ .args = &.{ "install", "unsupported@fixture-market" }, .ok = false, .contains = "Only skills and MCP servers" },
        .{ .args = &.{ "install", "demo@fixture-market" }, .contains = "Installed demo@fixture-market" },
        .{ .args = &.{"list"}, .contains = "demo@fixture-market" },
    };
    for (commands) |command| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ marlin_bin, "plugin" });
        try argv.appendSlice(arena, command.args);
        const result = try process_io.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .path = cwd }, .environ_map = env, .timeout_ms = helper_timeout_ms });
        defer result.deinit(gpa);
        if (result.term != .exited or (result.term.exited == 0) != command.ok or
            std.mem.indexOf(u8, if (command.ok) result.stdout else result.stderr, command.contains) == null)
        {
            print(io, "plugin CLI failed: {s} {s}\n", .{ result.stdout, result.stderr });
            return error.PluginCommandFailed;
        }
    }
    const conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    try conn.send(.{ .session_list = .{ .include_archived = false } });
    const listing = try recvTagBounded(conn, arena, "session_list_result");
    const sessions = listing.get("sessions") orelse return error.SessionIdMissing;
    if (sessions != .array or sessions.array.items.len != 1) return error.SessionIdMissing;
    const sid = uintField(sessions.array.items[0].object, "sid") orelse return error.SessionIdMissing;
    try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
    // Without the opt-in, no skill catalog: the gauge, then status.
    var legacy_status = try recvBounded(conn, arena);
    if (tagObject(legacy_status, "session_meta") != null) legacy_status = try recvBounded(conn, arena);
    if (tagObject(legacy_status, "status") == null) return error.UnexpectedSkillCatalog;
    try conn.send(.{ .sub = .{ .sid = sid, .skill_catalog = true } });
    const catalog = try recvTagBounded(conn, arena, "session_skills");
    try expectSkillCatalog(catalog, sid, &.{"demo:review"});
    _ = try recvTagBounded(conn, arena, "status");
    try conn.send(.{ .input = .{ .sid = sid, .text = "/demo:review the parser", .skill = .{ .name = "demo:review", .arguments = "the parser" }, .request_id = 301 } });
    var saw_input = false;
    while (true) {
        const msg = try recvBounded(conn, arena);
        if (tagObject(msg, "err")) |_| return error.PluginInvocationFailed;
        if (tagObject(msg, "blk")) |outer| {
            const body = objectField(objectField(outer, "b") orelse continue, "body") orelse continue;
            if (objectField(body, "user_msg")) |user| {
                if (std.mem.eql(u8, stringField(user, "display_text") orelse "", "/demo:review the parser") and
                    std.mem.indexOf(u8, stringField(user, "text") orelse "", "PLUGIN_COMMAND_BODY: the parser.") != null) saw_input = true;
            }
        }
        if (tagObject(msg, "status")) |status| {
            const state = stringField(status, "state") orelse "";
            if (std.mem.eql(u8, state, "err")) return error.PluginInvocationFailed;
            if (std.mem.eql(u8, state, "idle")) break;
        }
    }
    if (!saw_input) return error.PluginInvocationFailed;
    try conn.send(.{ .plugin = .{ .sid = sid, .command = .{ .action = .uninstall, .argument = "demo@fixture-market" } } });
    const removed = try recvTagBounded(conn, arena, "plugin_result");
    if (removed.get("ok") == null or removed.get("ok").? != .bool or !removed.get("ok").?.bool) return error.PluginCommandFailed;
    const empty_catalog = try recvTagBounded(conn, arena, "session_skills");
    try expectSkillCatalog(empty_catalog, sid, &.{});
    try conn.send(.{ .input = .{ .sid = sid, .text = "/demo:review", .skill = .{ .name = "demo:review" }, .request_id = 302 } });
    const rejected = try recvTagBounded(conn, arena, "err");
    if (uintField(rejected, "request_id") != 302) return error.PluginInvocationFailed;
    const reinstalled = try process_io.run(gpa, io, .{
        .argv = &.{ marlin_bin, "plugin", "install", "demo@fixture-market" },
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .timeout_ms = helper_timeout_ms,
    });
    defer reinstalled.deinit(gpa);
    if (reinstalled.term != .exited or reinstalled.term.exited != 0) return error.PluginCommandFailed;
    try expectSkillCatalog(try recvTagBounded(conn, arena, "session_skills"), sid, &.{"demo:review"});
    const project = try std.fs.path.join(arena, &.{ cwd, "completion-project" });
    const skill_dir = try std.fs.path.join(arena, &.{ project, ".agents", "skills", "local-review" });
    try Io.Dir.cwd().createDirPath(io, skill_dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ skill_dir, "SKILL.md" }),
        .data = "---\nname: local-review\ndescription: Project review\n---\nReview locally.\n",
    });
    try conn.send(.{ .session_set_cwd = .{ .sid = sid, .cwd = project } });
    const project_catalog = try recvTagBounded(conn, arena, "session_skills");
    try expectSkillCatalog(project_catalog, sid, &.{ "demo:review", "local-review" });
    const canonical_project = try Io.Dir.cwd().realPathFileAlloc(io, project, arena);
    if (!std.mem.eql(u8, stringField(project_catalog, "cwd") orelse "", canonical_project)) return error.SkillCatalogWrongCwd;
}

fn expectSkillCatalog(catalog: std.json.ObjectMap, sid: u64, expected: []const []const u8) !void {
    if (uintField(catalog, "sid") != sid) return error.SkillCatalogWrongSession;
    const skills = catalog.get("skills") orelse return error.SkillCatalogMissing;
    if (skills != .array or skills.array.items.len != expected.len) return error.SkillCatalogMismatch;
    for (expected) |name| {
        var found = false;
        for (skills.array.items) |entry| {
            if (entry != .object) return error.SkillCatalogMismatch;
            if (std.mem.eql(u8, stringField(entry.object, "name") orelse "", name)) {
                found = true;
                const description: []const u8 = stringField(entry.object, "description") orelse "";
                if (description.len == 0) return error.SkillCatalogMissingDescription;
                if (entry.object.get("content") != null or entry.object.get("path") != null) return error.SkillCatalogLeakedContent;
            }
        }
        if (!found) return error.SkillCatalogMismatch;
    }
}

fn checkGitStatus(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8) !void {
    const conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try conn.send(.{ .session_list = .{ .include_archived = false } });
    const listing = try recvTagBounded(conn, arena, "session_list_result");
    const sessions = listing.get("sessions") orelse return error.SessionIdMissing;
    if (sessions != .array or sessions.array.items.len != 1) return error.SessionIdMissing;
    const sid = uintField(sessions.array.items[0].object, "sid") orelse return error.SessionIdMissing;
    try conn.send(.{ .session_git_status = .{ .sid = sid } });
    const absent = try recvTagBounded(conn, arena, "session_git_status");
    const absent_branch: []const u8 = stringField(absent, "branch") orelse return error.GitBranchMissing;
    if (absent_branch.len != 0) return error.UnexpectedGitBranch;
    const commands = [_][]const []const u8{
        &.{ "git", "init", "--initial-branch=status-test" },
        &.{ "git", "-c", "user.name=Status Test", "-c", "user.email=status@example.test", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "base" },
        &.{ "git", "update-ref", "refs/remotes/origin/status-test", "HEAD" },
    };
    for (commands) |argv| {
        const result = try process_io.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = env, .timeout_ms = helper_timeout_ms });
        defer result.deinit(gpa);
        if (result.term != .exited or result.term.exited != 0) return error.GitFixtureFailed;
    }
    // Negative cache expires too: initializing a repo in the same cwd appears.
    try io.sleep(.fromMilliseconds(5_100), .awake);
    for (0..3) |attempt| {
        // Exercise both the TTL cache and the metadata cache after TTL expiry.
        if (attempt == 2) try io.sleep(.fromMilliseconds(5_100), .awake);
        try conn.send(.{ .session_git_status = .{ .sid = sid } });
        const result = try recvTagBounded(conn, arena, "session_git_status");
        if (!std.mem.eql(u8, stringField(result, "branch") orelse "", "status-test")) return error.GitBranchMissing;
        if (uintField(result, "sid") != sid) return error.SessionIdMissing;
        const counts = result.get("counts") orelse return error.GitCountsMissing;
        if (counts != .object or uintField(counts.object, "ahead") != 0 or uintField(counts.object, "behind") != 0) return error.GitCountsMissing;
    }
}

fn checkRuntime(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    var ids: [2]u64 = undefined;
    for (&ids, [_][]const u8{ "claudecode/default", "codex/default" }) |*sid, model| {
        try conn.send(.{ .session_create = .{ .cwd = "/tmp", .model = model } });
        sid.* = uintField(try recvTagBounded(conn, a, "session_created"), "sid") orelse return error.SessionIdMissing;
    }
    for ([_]struct { value: ?[]const u8, expected: u64, uses_default: bool }{
        .{ .value = null, .expected = 14_400_000, .uses_default = true },
        .{ .value = "12h", .expected = 43_200_000, .uses_default = false },
        .{ .value = "off", .expected = 0, .uses_default = false },
        .{ .value = null, .expected = 0, .uses_default = false },
        .{ .value = "default", .expected = 14_400_000, .uses_default = true },
    }) |case| {
        try conn.send(.{ .session_runtime = .{ .sid = ids[0], .value = case.value } });
        const result = try recvTagBounded(conn, a, "session_runtime_result");
        if (uintField(result, "sid") != ids[0] or uintField(result, "max_runtime_ms") != case.expected) return error.RuntimeMismatch;
        const uses_default = result.get("uses_default") orelse return error.RuntimeMismatch;
        if (uses_default != .bool or uses_default.bool != case.uses_default) return error.RuntimeMismatch;
        // Releasing the session forces the next command to restore it from SQLite.
        try conn.send(.{ .unsub = .{ .sid = ids[0] } });
        _ = try recvTagBounded(conn, a, "ok");
    }
    try conn.send(.{ .session_runtime = .{ .sid = ids[0], .value = "nonsense" } });
    _ = try recvTagBounded(conn, a, "err");
    try conn.send(.{ .session_runtime = .{ .sid = ids[1] } });
    const untouched = try recvTagBounded(conn, a, "session_runtime_result");
    if (uintField(untouched, "max_runtime_ms") != 14_400_000) return error.RuntimeLeakedAcrossSessions;
}

fn checkRecap(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, expected: []const u8) !void {
    const conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try conn.send(.{ .session_list = .{ .include_archived = false } });
    const listing = try recvTagBounded(conn, arena, "session_list_result");
    const sessions = listing.get("sessions") orelse return error.SessionIdMissing;
    if (sessions != .array or sessions.array.items.len != 1) return error.SessionIdMissing;
    const sid = uintField(sessions.array.items[0].object, "sid") orelse return error.SessionIdMissing;
    try conn.send(.{ .sub = .{ .sid = sid, .tail_limit = 1 } });
    const replay = try recvTagBounded(conn, arena, "replay_done");
    const seq = uintField(replay, "newest_seq") orelse return error.TailReplayMarkerMissing;
    try conn.send(.{ .session_recap = .{ .sid = sid, .seq = seq - 1 } });
    const stale = try recvTagBounded(conn, arena, "session_recap");
    const stale_text: []const u8 = stringField(stale, "text") orelse "";
    if (stale_text.len != 0) return error.StaleRecapAccepted;
    // Only the first request may contact the provider. The second reads the
    // cache even though the scripted provider has already consumed its steps.
    for (0..2) |_| {
        try conn.send(.{ .session_recap = .{ .sid = sid, .seq = seq } });
        const result = try recvTagBounded(conn, arena, "session_recap");
        const text = stringField(result, "text") orelse return error.RecapMissing;
        if (std.mem.indexOf(u8, text, expected) == null) return error.RecapMissing;
        const generated = result.get("generated") orelse return error.RecapMissing;
        if (generated != .bool or !generated.bool) return error.RecapNotGenerated;
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

    const inspected = try process_io.run(gpa, io, .{
        .argv = &.{ marlin_bin, "inspect", prefix, "--json" },
        .environ_map = env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = 1024 * 1024,
        .stderr_limit = 256 * 1024,
        .timeout_ms = helper_timeout_ms,
    });
    defer inspected.deinit(gpa);
    if (inspected.term != .exited or inspected.term.exited != 0) return error.SessionInspectFailed;
    var inspect_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer inspect_arena_state.deinit();
    const inspect_value = std.json.parseFromSliceLeaky(
        std.json.Value,
        inspect_arena_state.allocator(),
        inspected.stdout,
        .{},
    ) catch return error.SessionInspectJsonInvalid;
    if (inspect_value != .object) return error.SessionInspectJsonInvalid;
    const inspect_object = inspect_value.object;
    const inspect_handle = inspect_object.get("handle") orelse return error.SessionInspectJsonInvalid;
    const inspect_session = inspect_object.get("session") orelse return error.SessionInspectJsonInvalid;
    const inspect_blocks = inspect_object.get("blocks") orelse return error.SessionInspectJsonInvalid;
    const inspect_diagnostics = inspect_object.get("diagnostics") orelse return error.SessionInspectJsonInvalid;
    if (inspect_handle != .string or !std.mem.eql(u8, inspect_handle.string, handle) or
        inspect_session != .object or inspect_blocks != .array or inspect_blocks.array.items.len != 2 or
        inspect_diagnostics != .object)
    {
        return error.SessionInspectJsonInvalid;
    }

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
    var w: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

fn checkCwdCompletion(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, daemon_home: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.fs.path.join(a, &.{ daemon_home, "server-project" });
    const repo = try std.fs.path.join(a, &.{ cwd, "repo-on-host" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ repo, "sub directory" }));
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ daemon_home, "home-only" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ cwd, "repo-file" }), .data = "not a directory" });
    const conn = try connectProtocol(gpa, io, env);
    defer conn.deinit();
    try conn.send(.{ .session_create = .{ .cwd = cwd, .model = "local/testing" } });
    const sid = uintField(try recvTagBounded(conn, a, "session_created"), "sid") orelse return error.SessionIdMissing;
    const absolute = try std.fmt.allocPrint(a, "{s}/repo", .{cwd});
    for ([_]struct { typed: []const u8, expected: ?[]const u8 }{
        .{ .typed = "repo", .expected = "repo-on-host/" },
        .{ .typed = "~/home-", .expected = "~/home-only/" },
        .{ .typed = absolute, .expected = try std.fmt.allocPrint(a, "{s}/", .{repo}) },
        .{ .typed = "missing/path/", .expected = null },
    }, 1..) |case, request_id| {
        try conn.send(.{ .session_complete_cwd = .{ .sid = sid, .typed = case.typed, .request_id = request_id } });
        const result = try recvTagBounded(conn, a, "session_cwd_completions");
        if (uintField(result, "request_id") != request_id or uintField(result, "sid") != sid) return error.CwdCompletionIdentity;
        if (!std.mem.eql(u8, stringField(result, "cwd") orelse "", cwd) or
            !std.mem.eql(u8, stringField(result, "typed") orelse "", case.typed)) return error.CwdCompletionIdentity;
        const matches = result.get("matches") orelse return error.CwdCompletionMissing;
        if (matches != .array) return error.CwdCompletionMissing;
        if (case.expected) |expected| {
            if (matches.array.items.len != 1 or matches.array.items[0] != .string or
                !std.mem.eql(u8, matches.array.items[0].string, expected)) return error.CwdCompletionMismatch;
        } else if (matches.array.items.len != 0) return error.CwdCompletionMismatch;
    }
    try conn.send(.{ .session_set_cwd = .{ .sid = sid, .cwd = "repo-on-host" } });
    _ = try recvTagBounded(conn, a, "ok");
    try conn.send(.{ .session_complete_cwd = .{ .sid = sid, .typed = "sub", .request_id = 5 } });
    const result = try recvTagBounded(conn, a, "session_cwd_completions");
    const canonical = try Io.Dir.cwd().realPathFileAlloc(io, repo, a);
    if (!std.mem.eql(u8, stringField(result, "cwd") orelse "", canonical)) return error.CwdCompletionIdentity;
    const matches = result.get("matches") orelse return error.CwdCompletionMissing;
    if (matches != .array or matches.array.items.len != 1 or matches.array.items[0] != .string or
        !std.mem.eql(u8, matches.array.items[0].string, "sub directory/")) return error.CwdCompletionMismatch;
}
