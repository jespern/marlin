//! Unit tests for shell_host.zig: the daemon's mirror of a shell.
const std = @import("std");
const vt = @import("ghostty-vt");
const shell_host = @import("shell_host.zig");
const shell_pty = @import("shell_pty.zig");

/// Plays the dispatcher: the reader thread hands output over, and the test
/// thread feeds it to the host.
const Relay = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayList(u8) = .empty,
    seen: std.ArrayList(u8) = .empty,
    exited: bool = false,

    fn sink(self: *Relay) shell_pty.Sink {
        return .{ .ctx = self, .output = onOutput, .exited = onExited };
    }

    fn onOutput(ctx: *anyopaque, _: *shell_pty.Shell, bytes: []const u8) void {
        const self: *Relay = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pending.appendSlice(std.testing.allocator, bytes) catch @panic("OOM");
    }

    fn onExited(ctx: *anyopaque, _: *shell_pty.Shell, _: shell_pty.Status) void {
        const self: *Relay = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.exited = true;
    }

    /// Feed what arrived to the host; true once the shell exited.
    fn pump(self: *Relay, host: *shell_host.Host) !bool {
        self.mutex.lockUncancelable(self.io);
        const bytes = try std.testing.allocator.dupe(u8, self.pending.items);
        self.pending.clearRetainingCapacity();
        const exited = self.exited;
        self.mutex.unlock(self.io);
        defer std.testing.allocator.free(bytes);
        host.feed(bytes);
        if (host.pty) |pty| pty.acknowledge(bytes.len);
        try self.seen.appendSlice(std.testing.allocator, bytes);
        return exited;
    }

    fn deinit(self: *Relay) void {
        self.pending.deinit(std.testing.allocator);
        self.seen.deinit(std.testing.allocator);
    }
};

test "the daemon's mirror answers terminal queries with no viewer attached" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");

    const host = try shell_host.Host.create(gpa, io, 1, 9, "/", 0, .{ .cols = 80, .rows = 24, .cell_width = 9, .cell_height = 18 });
    defer host.destroy();
    var relay: Relay = .{ .io = io };
    defer relay.deinit();
    // Raw mode, ask for the cursor position, read the 6-byte reply.
    try host.start(io, .{
        .path = "/bin/sh",
        .argv = &.{ "sh", "-c", "stty raw -echo; printf '\\033[6n'; r=$(dd bs=1 count=6 2>/dev/null | od -An -c | tr -d ' \\n'); stty sane; printf 'got:%s|' \"$r\"" },
        .cwd = "/",
        .environ = &environ,
        .size = .{ .cols = 80, .rows = 24 },
    }, relay.sink());

    for (0..500) |_| {
        if (try relay.pump(host)) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;
    _ = try relay.pump(host);
    try std.testing.expect(std.mem.indexOf(u8, relay.seen.items, "got:033[1;1R|") != null);
}

test "a host snapshot decodes to the same screen" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const host = try shell_host.Host.create(gpa, io, 1, 9, "/", 0, .{ .cols = 20, .rows = 4 });
    defer host.destroy();
    host.feed("\x1b]2;my title\x07hello\r\nworld\x1b[");
    try std.testing.expect(host.titleChanged());
    try std.testing.expect(!host.titleChanged());
    try std.testing.expectEqualStrings("my title", host.title());

    const bytes = try host.snapshot(gpa);
    defer gpa.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var decoded = try vt.snapshot.decode(gpa, io, &reader, .{ .max_continuation_bytes = 1024 });
    defer decoded.deinit(gpa);
    try std.testing.expectEqualStrings("\x1b[", decoded.continuation.bytes);
    const text = try decoded.terminal.?.plainString(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
}

test "viewers attach once and detach cleanly" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const host = try shell_host.Host.create(gpa, threaded.io(), 1, 9, "/", 0, .{ .cols = 20, .rows = 4 });
    defer host.destroy();
    try host.attach(7);
    host.viewer(7).?.unacked = 99;
    try host.attach(7); // reattaching resets its window
    try std.testing.expectEqual(@as(usize, 1), host.viewers.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.viewer(7).?.unacked);
    host.detach(7);
    try std.testing.expect(host.viewer(7) == null);
}

test "the transcript joins soft wraps, keeps scrollback, and keeps the newest bytes" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const host = try shell_host.Host.create(gpa, threaded.io(), 1, 9, "/", 0, .{ .cols = 10, .rows = 3 });
    defer host.destroy();
    host.feed("first\r\nsecond\r\nthird\r\na-line-longer-than-ten\r\n$ ");
    const text = try host.transcript(gpa, 1 << 20);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("first\nsecond\nthird\na-line-longer-than-ten\n$", text);

    const tail = try host.transcript(gpa, 12);
    defer gpa.free(tail);
    try std.testing.expectEqualStrings("$", tail);
}
