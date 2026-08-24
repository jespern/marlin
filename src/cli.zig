//! Subcommand parsing and dispatch. No business logic lives here.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const daemon = @import("daemon/daemon.zig");
const headless = @import("client/headless.zig");
const tui = @import("client/tui.zig");
const web = @import("client/web.zig");

pub const Command = enum {
    attach,
    daemon,
    run,
    ls,
    archive,
    unarchive,
    kill,
    compact,
    reboot,
    shutdown,
    web,
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
        .version => try stdoutPrint(io, "marlin {s}\n", .{build_options.version}),
        .help => try stdoutPrint(io, help_text, .{}),
        .daemon => try daemon.Daemon.serve(gpa, io, environ, null),
        .run => return headless.run(gpa, io, environ, self_exe, rest),
        .ls => return headless.ls(gpa, io, environ, self_exe, rest),
        .archive => return headless.setArchived(gpa, io, environ, self_exe, rest, true),
        .unarchive => return headless.setArchived(gpa, io, environ, self_exe, rest, false),
        .kill => return headless.kill(gpa, io, environ, self_exe, rest),
        .compact => return headless.compact(gpa, io, environ, self_exe, rest),
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
    \\  marlin attach <handle> attach TUI to a session (unique prefix, min 4)
    \\  marlin run [--continue] [--model <m>] [--quiet] [--ask] "task"
    \\  marlin daemon          run the daemon in the foreground
    \\  marlin ls [--all]      list sessions
    \\  marlin archive <handle> hide a session tree without deleting it
    \\  marlin unarchive <handle> restore an archived session tree
    \\  marlin kill <handle>   interrupt a session's running turn
    \\  marlin compact [handle] manually compact a session's context
    \\  marlin reboot [--build] re-exec daemon+client onto a fresh binary
    \\  marlin shutdown        stop the daemon
    \\  marlin web [--port N]  local web UI (127.0.0.1:8377, unauthenticated POC)
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
    try std.testing.expectEqual(@as(?Command, null), Command.parse("bogus"));
}
