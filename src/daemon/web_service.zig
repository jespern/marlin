//! Daemon-owned companion process and bounded operational log. HTTP failures
//! cannot take down the dispatcher; shutdown kills and reaps the child.
const std = @import("std");
const Io = std.Io;
const proto = @import("../core/proto.zig");
pub const Service = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    exe: []const u8,
    mutex: Io.Mutex = .init,
    pid: ?std.process.Child.Id = null,
    stopping: bool = false,
    thread: ?std.Thread = null,
    state: []const u8 = "stopped",
    logs: [128][384]u8 = undefined,
    lengths: [128]usize = @splat(0),
    count: usize = 0,
    next: usize = 0,
    url: [256]u8 = undefined,
    url_len: usize = 0,
    port: u16,

    /// Idempotent, and restartable after stop(): /web disable then enable
    /// cycles the same Service. Thread handle is dispatcher-owned.
    pub fn start(self: *Service) !void {
        if (self.thread != null) return;
        self.mutex.lockUncancelable(self.io);
        self.stopping = false;
        self.state = "starting";
        self.mutex.unlock(self.io);
        self.thread = try std.Thread.spawn(.{}, work, .{self});
    }
    pub fn stop(self: *Service) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        if (self.pid) |pid| {
            if (@import("builtin").os.tag != .windows) _ = std.c.kill(pid, std.posix.SIG.KILL);
        }
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    pub fn append(self: *Service, text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (std.mem.indexOf(u8, text, "marlin web ui on ") != null) self.state = "running";
        const n = @min(text.len, self.logs[0].len);
        for (text[0..n], 0..) |ch, i| self.logs[self.next][i] = if (ch >= 32 and ch != 127) ch else ' ';
        self.lengths[self.next] = n;
        self.next = (self.next + 1) % self.logs.len;
        self.count = @min(self.count + 1, self.logs.len);
        if (std.mem.indexOf(u8, text, "tailnet: https://")) |marker| {
            const at = marker + 9;
            const end = std.mem.indexOfScalarPos(u8, text, at, ' ') orelse text.len;
            self.url_len = @min(end - at, self.url.len);
            @memcpy(self.url[0..self.url_len], text[at..][0..self.url_len]);
        }
    }
    pub fn snapshot(self: *Service, arena: std.mem.Allocator) !proto.WebStatus {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const lines = try arena.alloc([]const u8, self.count);
        for (lines, 0..) |*line, i| {
            const at = (self.next + self.logs.len - self.count + i) % self.logs.len;
            line.* = try arena.dupe(u8, self.logs[at][0..self.lengths[at]]);
        }
        return .{ .enabled = true, .state = self.state, .url = if (self.url_len > 0)
            try arena.dupe(u8, self.url[0..self.url_len])
        else
            try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{self.port}), .logs = lines };
    }
    fn work(self: *Service) void {
        self.run() catch |err| {
            var buf: [128]u8 = undefined;
            self.append(std.fmt.bufPrint(&buf, "companion failed: {t}", .{err}) catch "companion failed");
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state = if (self.stopping) "stopped" else "failed";
    }
    fn run(self: *Service) !void {
        // stdin is a pipe the daemon holds open for the companion's lifetime
        // but never writes to. Its only purpose is death detection: when the
        // daemon exits — cleanly OR by crash/SIGKILL — the OS closes this
        // write end, the companion reads EOF and exits, so a companion can
        // never outlive its daemon and squat the port (the orphaned-web-ui
        // bug). Clean shutdown still kills it directly via stop().
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ self.exe, "_web" },
            .environ_map = self.environ,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        defer child.kill(self.io);
        self.mutex.lockUncancelable(self.io);
        self.pid = child.id;
        if (self.stopping) {
            self.pid = null;
            self.mutex.unlock(self.io);
            return;
        }
        self.mutex.unlock(self.io);
        // Clear the published pid before reaping it, preventing pid reuse races.
        defer {
            self.mutex.lockUncancelable(self.io);
            self.pid = null;
            self.mutex.unlock(self.io);
        }
        var buf: [32768]u8 = undefined;
        var reader = child.stderr.?.reader(self.io, &buf);
        while (reader.interface.takeDelimiterInclusive('\n')) |line| self.append(std.mem.trimEnd(u8, line, "\r\n")) else |_| {}
    }
};
