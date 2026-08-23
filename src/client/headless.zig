//! `marlin run "task"` — headless one-shot session. Doubles as the eval
//! harness (docs/ARCHITECTURE.md §11): create session, run to completion,
//! print result to stdout, exit nonzero on failure.
//!
//! M0 NOTE: in M0 this short-circuits — no daemon exists yet, so it drives
//! daemon/loop.zig in-process. From M1 it becomes a true protocol client and
//! the in-process path is deleted.

const std = @import("std");
const Io = std.Io;

pub fn runStub(io: Io) !void {
    var buf: [256]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    try w.interface.print("marlin run: not implemented yet (M0 in progress) — see docs/MILESTONES.md\n", .{});
    try w.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
}
