//! `marlin discover [--wait S]`: list the marlins advertising on this
//! network (Bonjour `_marlin._tcp`) with a ready-to-paste `--remote` target.
const std = @import("std");
const Io = std.Io;
const discovery = @import("../core/discovery.zig");

const usage = "usage: marlin discover [--wait <seconds>]\n";

pub fn run(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, args: []const [:0]const u8) !u8 {
    _ = environ;
    var wait_ms: u32 = 2000;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--wait") and i + 1 < args.len) {
            i += 1;
            const seconds = std.fmt.parseFloat(f64, args[i]) catch {
                try eprint(io, usage, .{});
                return 2;
            };
            if (!(seconds > 0) or seconds > 60) {
                try eprint(io, "marlin discover: --wait takes 0 < seconds <= 60\n", .{});
                return 2;
            }
            wait_ms = @intFromFloat(seconds * 1000);
        } else {
            try eprint(io, usage, .{});
            return 2;
        }
    }
    if (!discovery.supported) {
        try eprint(io, "marlin discover: needs Bonjour (macOS); Avahi on Linux is a follow-up\n", .{});
        return 1;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const peers = discovery.browse(arena_state.allocator(), io, wait_ms) catch |err| {
        try eprint(io, "marlin discover: browse failed: {t}\n", .{err});
        return 1;
    };
    if (peers.len == 0) {
        try eprint(io, "no marlins on this network after {d} ms (a daemon advertises unless `[discovery] enabled = false` or MARLIN_DISCOVERY=0)\n", .{wait_ms});
        return 1;
    }
    var buf: [8192]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    try discovery.renderTable(&w.interface, peers);
    try w.interface.flush();
    return 0;
}

fn eprint(io: Io, comptime fmt: []const u8, fmt_args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io, &buf);
    try w.interface.print(fmt, fmt_args);
    try w.interface.flush();
}
