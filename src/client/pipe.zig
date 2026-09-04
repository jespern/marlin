//! `marlin _pipe`: stdio ↔ daemon.sock bridge, the far end of Mode B remote
//! attach (docs/ARCHITECTURE.md). A local client's `ssh <host> marlin _pipe`
//! gets a clean NDJSON channel to this box's per-user daemon; the CLIENT
//! performs the hello handshake through the bridge, so the daemon sees an
//! ordinary peer and version skew is rejected end-to-end.
//!
//! Readiness first, then dumbness: a full probe connect (autostart plus its
//! retry patience) runs and is released, and the bridge itself is a plain
//! line copier on a fresh raw connection. Lines are forwarded whole with a
//! flush each, so latency is one NDJSON record, never a partial buffer.

const std = @import("std");
const Io = std.Io;
const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
) !u8 {
    const probe = attach.connect(gpa, io, environ, self_exe) catch |err| {
        std.log.err("_pipe: cannot reach daemon: {t}", .{err});
        return 1;
    };
    probe.deinit();
    const conn = (attach.tryConnect(gpa, io, environ) catch null) orelse {
        std.log.err("_pipe: daemon vanished after readiness probe", .{});
        return 1;
    };
    defer conn.deinit();

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &out_buf);
    var in_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &in_buf);

    // daemon → stdout runs in a helper; stdin → daemon in this thread.
    // stdin EOF (client left, ssh tore down) ends the bridge: shutting the
    // daemon socket down releases the helper's blocked read. If instead the
    // DAEMON dies first, the helper's exit closes nothing here — but the
    // remote client sees the stream end, deinits, ssh closes, and our stdin
    // EOFs, so both directions still unwind without a process kill.
    var downstream = Downstream{ .gpa = gpa, .conn = conn, .writer = &stdout_writer.interface };
    const thread = std.Thread.spawn(.{}, Downstream.run, .{&downstream}) catch {
        std.log.err("_pipe: cannot start bridge thread", .{});
        return 1;
    };
    pump(gpa, &stdin_reader.interface, conn.writer);
    conn.shutdown();
    thread.join();
    return 0;
}

const Downstream = struct {
    gpa: std.mem.Allocator,
    conn: *attach.Conn,
    writer: *std.Io.Writer,

    fn run(self: *Downstream) void {
        pump(self.gpa, self.conn.reader, self.writer);
    }
};

/// Copy NDJSON records until either side fails. readLineAlloc strips the
/// delimiter, so each record is re-terminated on the way out.
fn pump(gpa: std.mem.Allocator, from: *std.Io.Reader, to: *std.Io.Writer) void {
    while (true) {
        const line = proto.readLineAlloc(gpa, from) catch break;
        defer gpa.free(line);
        to.writeAll(line) catch break;
        to.writeByte('\n') catch break;
        to.flush() catch break;
    }
}
