//! Subcommand parsing and dispatch. No business logic lives here.

const std = @import("std");
const Io = std.Io;

const daemon = @import("daemon/daemon.zig");
const headless = @import("client/headless.zig");

pub const Command = enum {
    attach,
    daemon,
    run,
    ls,
    kill,
    help,
    version,

    pub fn parse(word: []const u8) ?Command {
        inline for (@typeInfo(Command).@"enum".fields) |f| {
            if (std.mem.eql(u8, word, f.name)) return @field(Command, f.name);
        }
        return null;
    }
};

pub fn dispatch(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !void {
    _ = gpa;
    const cmd: Command = if (args.len == 0)
        .attach
    else
        Command.parse(args[0]) orelse .help;

    switch (cmd) {
        .version => try stdoutPrint(io, "marlin 0.0.0\n", .{}),
        .help => try stdoutPrint(io, help_text, .{}),
        .daemon => try daemon.serveStub(io),
        .run => try headless.runStub(io),
        else => try stdoutPrint(io, "marlin: '{s}' not implemented yet (see docs/MILESTONES.md)\n", .{@tagName(cmd)}),
    }
}

const help_text =
    \\marlin — a fast, simple AI agent harness
    \\
    \\usage:
    \\  marlin                 attach to the daemon (TUI)
    \\  marlin run "task"      headless one-shot session
    \\  marlin daemon          run the daemon in the foreground
    \\  marlin ls              list sessions
    \\  marlin attach <id>     attach to a session
    \\  marlin kill <id>       terminate a session
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
    try std.testing.expectEqual(@as(?Command, null), Command.parse("bogus"));
}
