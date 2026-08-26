//! Subcommand parsing and dispatch. No business logic lives here.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const attach = @import("client/attach.zig");
const cc_approve = @import("client/cc_approve.zig");
const daemon = @import("daemon/daemon.zig");
const headless = @import("client/headless.zig");
const pipe = @import("client/pipe.zig");
const landlock = @import("daemon/landlock.zig");
const permissions = @import("daemon/permissions.zig");
const sandbox = @import("daemon/sandbox.zig");
const tui = @import("client/tui.zig");
const web = @import("client/web.zig");

pub const Command = enum {
    attach,
    daemon,
    run,
    ls,
    search,
    archive,
    unarchive,
    kill,
    compact,
    mcp,
    gc,
    reboot,
    shutdown,
    web,
    help,
    version,
    resolve_host,
    cc_approve,
    landlock_exec,
    sandbox_probe,
    _pipe,

    pub fn parse(word: []const u8) ?Command {
        inline for (@typeInfo(Command).@"enum".fields) |f| {
            if (std.mem.eql(u8, word, f.name)) return @field(Command, f.name);
        }
        return null;
    }
};

pub fn dispatch(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    // `marlin --remote <host> [command …]` routes the entire invocation at
    // that host's daemon (Mode B). <host> is handed to ssh verbatim — ssh
    // config owns naming, keys, and jump hosts; marlin adds no host registry.
    // The host rides in MARLIN_REMOTE, which attach.connect reads, so
    // TUI/headless/web all work unchanged over ssh.
    var effective = args;
    if (args.len >= 2 and std.mem.eql(u8, args[0], "--remote")) {
        try environ.put(attach.remote_env, args[1]);
        effective = args[2..];
    }
    const cmd: Command = if (effective.len == 0)
        .attach
    else
        Command.parse(effective[0]) orelse .help;
    const rest = if (effective.len == 0) effective else effective[1..];

    switch (cmd) {
        .version => try stdoutPrint(io, "marlin {s}\n", .{build_options.version}),
        .resolve_host => return resolveHost(io, rest),
        // Internal permission bridge for delegated Claude Code sessions
        // (spawned via --mcp-config by the daemon); omitted from help.
        .cc_approve => return cc_approve.run(gpa, io, environ, self_exe, rest),
        // Internal Linux sandbox wrapper (spawned by the daemon's bash
        // adapter): applies a Landlock ruleset to itself, then execs.
        .landlock_exec => return landlock.run(gpa, io, rest),
        // Diagnostic: run the platform sandbox canary and report the verdict.
        .sandbox_probe => return sandboxProbe(gpa, io, environ),
        // Internal stdio↔daemon.sock bridge, the far end of `ssh <host>
        // marlin _pipe` remote attach; omitted from help.
        ._pipe => return pipe.run(gpa, io, environ, self_exe),
        .help => try stdoutPrint(io, help_text, .{}),
        .daemon => try daemon.Daemon.serve(gpa, io, environ, null),
        .run => return headless.run(gpa, io, environ, self_exe, rest),
        .ls => return headless.ls(gpa, io, environ, self_exe, rest),
        .search => return headless.search(gpa, io, environ, self_exe, rest),
        .archive => return headless.setArchived(gpa, io, environ, self_exe, rest, true),
        .unarchive => return headless.setArchived(gpa, io, environ, self_exe, rest, false),
        .kill => return headless.kill(gpa, io, environ, self_exe, rest),
        .compact => return headless.compact(gpa, io, environ, self_exe, rest),
        .mcp => return headless.mcp(gpa, io, environ, self_exe, rest),
        .gc => return headless.gc(gpa, io, environ, self_exe, rest),
        .reboot => return headless.reboot(gpa, io, environ, self_exe, rest),
        .shutdown => return headless.shutdown(gpa, io, environ),
        .web => return web.serve(gpa, io, environ, self_exe, rest),
        .attach => {
            if (rest.len > 1) {
                try stdoutPrint(io, "usage: marlin attach [session-handle]\n", .{});
                return 2;
            }
            const sid_arg: ?[]const u8 = if (rest.len == 1) rest[0] else null;
            var plan = tui.RebootPlan{};
            const code = try tui.run(gpa, io, environ, self_exe, sid_arg, &plan);
            if (plan.request != .none) {
                // TUI torn down cleanly; now run the reboot sequence and
                // exec back into `marlin attach @<sid>`.
                var sid_buf: [25]u8 = undefined;
                // Internal exact-id syntax keeps reboot continuity immune to
                // any public-prefix collision while old decimal input remains
                // accepted for compatibility.
                const sid_str = try std.fmt.bufPrintZ(&sid_buf, "@{d}", .{plan.sid});
                var argv: std.ArrayList([:0]const u8) = .empty;
                defer argv.deinit(gpa);
                if (plan.request.builds()) try argv.append(gpa, "--build");
                if (plan.request.forced()) try argv.append(gpa, "--force");
                try argv.append(gpa, "--then");
                try argv.append(gpa, "attach");
                try argv.append(gpa, sid_str);
                return headless.reboot(gpa, io, environ, self_exe, argv.items);
            }
            return code;
        },
    }
    return 0;
}

/// Internal resolver worker. The daemon invokes this in a killable subprocess
/// because Darwin's getaddrinfo cannot be cancelled safely in a multithreaded
/// process. It intentionally emits one IPv4 address and is omitted from help.
fn resolveHost(io: Io, args: []const [:0]const u8) !u8 {
    if (args.len != 2) return 2;
    const port = std.fmt.parseInt(u16, args[1], 10) catch return 2;
    const host = Io.net.HostName.init(args[0]) catch return 2;
    var storage: [16]Io.net.HostName.LookupResult = undefined;
    var resolved: Io.Queue(Io.net.HostName.LookupResult) = .init(&storage);
    host.lookup(io, &resolved, .{ .port = port, .family = .ip4 }) catch return 1;
    while (resolved.getOneUncancelable(io)) |result| switch (result) {
        .canonical_name => {},
        .address => |address| switch (address) {
            .ip4 => |ip4| {
                try stdoutPrint(io, "{d}.{d}.{d}.{d}\n", .{
                    ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3],
                });
                return 0;
            },
            .ip6 => {},
        },
    } else |_| {}
    return 1;
}

/// Run the platform sandbox canary exactly as daemon startup would and
/// report the verdict. Exit 0 when a backend verified.
fn sandboxProbe(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) !u8 {
    const marlin_exe: ?[:0]u8 = std.process.executablePathAlloc(io, gpa) catch null;
    defer if (marlin_exe) |exe| gpa.free(exe);
    var probe_environ = permissions.toolEnvironment(gpa, environ) catch {
        try stdoutPrint(io, "sandbox: unavailable (environment scrub failed)\n", .{});
        return 1;
    };
    defer probe_environ.deinit();
    const backend = sandbox.verify(gpa, io, &probe_environ, marlin_exe);
    try stdoutPrint(io, "sandbox: {s}\n", .{switch (backend) {
        .seatbelt => @as([]const u8, "verified (seatbelt)"),
        .landlock => "verified (landlock)",
        .unavailable => "unavailable",
    }});
    return if (backend == .unavailable) 1 else 0;
}

const help_text =
    \\marlin — a fast, simple AI agent harness
    \\
    \\usage:
    \\  marlin                 attach to the daemon (TUI, newest session)
    \\  marlin attach <handle> attach TUI to a session (unique prefix, min 4)
    \\  marlin run [--continue] [--model <m>] [--image <path>] [--quiet] [--ask] "task"
    \\  marlin daemon          run the daemon in the foreground
    \\  marlin ls [--all]      list sessions
    \\  marlin search <query>  search durable transcripts across sessions
    \\  marlin archive <handle> hide a session tree without deleting it
    \\  marlin unarchive <handle> restore an archived session tree
    \\  marlin kill <handle>   interrupt a session's running turn
    \\  marlin compact [handle] manually compact a session's context
    \\  marlin mcp list       inspect configured MCP servers
    \\  marlin mcp add <name> -- <command> [args...]
    \\  marlin mcp remove <name> | restart <name> | reload
    \\  marlin gc [--expire-days N] reclaim orphan/old full-output blobs
    \\  marlin reboot [--build] re-exec daemon+client onto a fresh binary
    \\  marlin shutdown        stop the daemon
    \\  marlin web [--port N]  local web UI — opt-in via [web] enabled = true
    \\                         (127.0.0.1:8377; tailnet via tailscale serve)
    \\  marlin --remote <host> [command …]  run any of the above against
    \\                         <host>'s daemon over ssh (host is an ssh
    \\                         destination; ssh config names apply)
    \\  marlin help | version
    \\
;

pub fn stdoutPrint(io: Io, comptime fmt: []const u8, fmt_args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    try w.interface.print(fmt, fmt_args);
    try w.interface.flush();
}

test "command parse" {
    try std.testing.expectEqual(Command.run, Command.parse("run").?);
    try std.testing.expectEqual(Command.archive, Command.parse("archive").?);
    try std.testing.expectEqual(Command.unarchive, Command.parse("unarchive").?);
    try std.testing.expectEqual(Command.shutdown, Command.parse("shutdown").?);
    try std.testing.expectEqual(Command.gc, Command.parse("gc").?);
    try std.testing.expectEqual(Command.resolve_host, Command.parse("resolve_host").?);
    try std.testing.expectEqual(@as(?Command, null), Command.parse("bogus"));
}
