//! Internal remote source rebuild command. The local coordinator invokes it
//! through SSH, waits for a readiness marker, then reboots the daemon through
//! the existing protocol before releasing this process to start the new daemon.

const std = @import("std");
const Io = std.Io;
const attach = @import("attach.zig");
const self_build = @import("self_build.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) !u8 {
    if (args.len != 0) {
        try eprint(io, "usage: marlin _rebuild\n", .{});
        return 2;
    }
    const candidate = self_build.build(gpa, io, "remote Marlin") catch |err| {
        switch (err) {
            error.NotSourceBuild => try eprint(
                io,
                "marlin: !rb requires the remote executable to be <checkout>/zig-out/bin/marlin\n" ++
                    "marlin: package installations should be updated with their installer or package manager\n",
                .{},
            ),
            else => try eprint(io, "marlin: remote build failed: {t}\n", .{err}),
        }
        return 1;
    };
    defer gpa.free(candidate);

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.writeAll(attach.rebuild_ready_marker ++ "\n");
    try stdout_writer.interface.flush();

    var stdin_buf: [64]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const command = stdin_reader.interface.takeDelimiterExclusive('\n') catch return 1;
    if (!std.mem.eql(u8, command, "continue")) return 1;

    var child = std.process.spawn(io, .{
        .argv = &.{ candidate, "daemon" },
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |err| {
        try eprint(io, "marlin: remote daemon start failed: {t}\n", .{err});
        return 1;
    };
    _ = &child;

    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        if (try attach.tryConnect(gpa, io, environ)) |conn| {
            conn.deinit();
            break;
        }
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    } else {
        try eprint(io, "marlin: rebuilt remote daemon did not become ready\n", .{});
        return 1;
    }
    try stdout_writer.interface.writeAll(attach.rebuild_started_marker ++ "\n");
    try stdout_writer.interface.flush();
    return 0;
}

fn eprint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stderr(), io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
}
