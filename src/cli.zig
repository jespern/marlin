//! Subcommand parsing and dispatch. No business logic lives here.

const std = @import("std");
const Io = std.Io;

const daemon = @import("daemon/daemon.zig");
const headless = @import("client/headless.zig");
const tui = @import("client/tui.zig");

pub const Command = enum {
    attach,
    daemon,
    run,
    ls,
    kill,
    compact,
    reboot,
    shutdown,
    help,
    version,

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
    const cmd: Command = if (args.len == 0)
        .attach
    else
        Command.parse(args[0]) orelse .help;
    const rest = if (args.len == 0) args else args[1..];

    switch (cmd) {
        .version => try stdoutPrint(io, "marlin 0.0.0\n", .{}),
        .help => try stdoutPrint(io, help_text, .{}),
        .daemon => try daemon.Daemon.serve(gpa, io, environ, null),
        .run => return headless.run(gpa, io, environ, self_exe, rest),
        .ls => return headless.ls(gpa, io, environ, self_exe),
        .kill => return headless.kill(gpa, io, environ, self_exe, rest),
        .compact => return headless.compact(gpa, io, environ, self_exe, rest),
        .reboot => return headless.reboot(gpa, io, environ, self_exe, rest),
        .shutdown => return headless.shutdown(gpa, io, environ),
        .attach => {
            var sid_arg: ?u64 = null;
            if (rest.len > 0) {
                sid_arg = std.fmt.parseInt(u64, rest[0], 10) catch {
                    try stdoutPrint(io, "marlin: bad session id '{s}'\n", .{rest[0]});
                    return 2;
                };
            }
            var plan = tui.RebootPlan{};
            const code = try tui.run(gpa, io, environ, self_exe, sid_arg, &plan);
            if (plan.request != .none) {
                // TUI torn down cleanly; now run the reboot sequence and
                // exec back into `marlin attach <sid>`.
                var sid_buf: [24]u8 = undefined;
                const sid_str = try std.fmt.bufPrintZ(&sid_buf, "{d}", .{plan.sid});
                var argv: std.ArrayList([:0]const u8) = .empty;
                defer argv.deinit(gpa);
                if (plan.request == .build) try argv.append(gpa, "--build");
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

const help_text =
    \\marlin — a fast, simple AI agent harness
    \\
    \\usage:
    \\  marlin                 attach to the daemon (TUI, newest session)
    \\  marlin attach <id>     attach TUI to a specific session
    \\  marlin run [--continue] [--model <m>] [--quiet] [--ask] "task"
    \\  marlin daemon          run the daemon in the foreground
    \\  marlin ls              list sessions
    \\  marlin kill <id>       interrupt a session's running turn
    \\  marlin compact [id]    manually compact a session's context
    \\  marlin reboot [--build] re-exec daemon+client onto a fresh binary
    \\  marlin shutdown        stop the daemon
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
    try std.testing.expectEqual(Command.shutdown, Command.parse("shutdown").?);
    try std.testing.expectEqual(@as(?Command, null), Command.parse("bogus"));
}
