//! Unit tests for cli.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in cli.zig.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const attach = @import("client/attach.zig");
const cc_approve = @import("client/cc_approve.zig");
const daemon = @import("daemon/daemon.zig");
const headless = @import("client/headless.zig");
const pipe = @import("client/pipe.zig");
const remote_rebuild = @import("client/remote_rebuild.zig");
const top = @import("client/top.zig");
const landlock = @import("daemon/landlock.zig");
const permissions = @import("daemon/permissions.zig");
const sandbox = @import("daemon/sandbox.zig");
const tui = @import("client/tui.zig");
const web = @import("client/web.zig");

const cli = @import("cli.zig");
const Command = cli.Command;
const runShellRequest = cli.runShellRequest;

test {
    std.testing.refAllDecls(cli);
}

test "shell request runs through configured shell in requested cwd" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-cli-shell");
    defer temp.deinit();
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, temp.path, gpa);
    defer gpa.free(cwd);

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("SHELL", "/bin/sh");
    const command = "printf '%s' \"$PWD\" > cwd.txt";
    const request = tui.ShellRequest{
        .command = try gpa.dupe(u8, command),
        .cwd = try gpa.dupe(u8, cwd),
    };
    defer request.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), try runShellRequest(io, &environ, request, false));
    const cwd_txt = try std.fs.path.join(gpa, &.{ cwd, "cwd.txt" });
    defer gpa.free(cwd_txt);
    const actual = try Io.Dir.cwd().readFileAlloc(io, cwd_txt, gpa, .limited(4096));
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(cwd, actual);
}

test "shell request returns command exit status" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-cli-shell");
    defer temp.deinit();
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, temp.path, gpa);
    defer gpa.free(cwd);

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("SHELL", "/bin/sh");
    const request = tui.ShellRequest{
        .command = try gpa.dupe(u8, "exit 7"),
        .cwd = try gpa.dupe(u8, cwd),
    };
    defer request.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 7), try runShellRequest(io, &environ, request, false));
}

test "command parse" {
    try std.testing.expectEqual(Command.run, Command.parse("run").?);
    try std.testing.expectEqual(Command.top, Command.parse("top").?);
    try std.testing.expectEqual(Command.archive, Command.parse("archive").?);
    try std.testing.expectEqual(Command.unarchive, Command.parse("unarchive").?);
    try std.testing.expectEqual(Command.shutdown, Command.parse("shutdown").?);
    try std.testing.expectEqual(Command.gc, Command.parse("gc").?);
    try std.testing.expectEqual(Command.diagnostics, Command.parse("diagnostics").?);
    try std.testing.expectEqual(Command.resolve_host, Command.parse("resolve_host").?);
    try std.testing.expectEqual(@as(?Command, null), Command.parse("bogus"));
}
