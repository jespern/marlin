//! Optional delivery worker. Policy lives in the daemon; network and Web Push
//! crypto run in a bounded `marlin _push` subprocess off dispatcher — same
//! isolation the old Node.js helper had, no runtime dependency.
const std = @import("std");
const Io = std.Io;
const queue = @import("../core/queue.zig");
const presence_mod = @import("presence.zig");
const Job = struct { sid: u64, payload: []u8, queued_ms: i64 };

pub fn run(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, self_exe: []const u8, action: []const u8, input: []const u8) ![]u8 {
    if (self_exe.len == 0) return error.PushHelperFailed;
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ self_exe, "_push", action, input },
        .environ_map = environ,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(15), .clock = .awake } },
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
    });
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        gpa.free(result.stdout);
        return error.PushHelperFailed;
    }
    return result.stdout;
}

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    /// Absolute marlin binary path for self-exec (`marlin _push`).
    self_exe: []const u8,
    jobs: queue.Mpsc(Job),
    presence: ?*presence_mod.Shared = null,
    stopping: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    pub fn init(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, self_exe: []const u8) Worker {
        return .{ .gpa = gpa, .io = io, .environ = environ, .self_exe = self_exe, .jobs = .init(gpa) };
    }
    pub fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, work, .{self});
    }
    pub fn deinit(self: *Worker) void {
        self.stopping.store(true, .release);
        self.jobs.close(self.io);
        if (self.thread) |thread| thread.join();
        self.jobs.deinit();
    }
    pub fn notify(self: *Worker, sid: u64, needs_input: bool, failed: bool) void {
        if (self.thread == null or self.pending.load(.acquire) >= 32) return;
        var sid_buf: [20]u8 = undefined;
        const sid_text = std.fmt.bufPrint(&sid_buf, "{d}", .{sid}) catch unreachable;
        const payload = std.json.Stringify.valueAlloc(self.gpa, .{
            .title = if (needs_input) "Marlin needs you" else if (failed) "Marlin task failed" else "Marlin task completed",
            .body = if (needs_input) "Open Marlin to review the approval." else "Open Marlin to see the result.",
            .sid = sid_text,
        }, .{}) catch return;
        _ = self.pending.fetchAdd(1, .acq_rel);
        self.jobs.push(self.io, .{ .sid = sid, .payload = payload, .queued_ms = nowMs(self.io) }) catch {
            _ = self.pending.fetchSub(1, .acq_rel);
            self.gpa.free(payload);
        };
    }
    fn work(self: *Worker) void {
        while (self.jobs.pop(self.io)) |job| {
            defer self.gpa.free(job.payload);
            defer _ = self.pending.fetchSub(1, .acq_rel);
            const now = nowMs(self.io);
            if (self.stopping.load(.acquire) or now - job.queued_ms > 30_000) continue;
            if (self.presence) |presence| if (presence.suppress(self.io, job.sid, now)) continue;
            const result = run(self.gpa, self.io, self.environ, self.self_exe, "deliver", job.payload) catch |err| {
                std.log.warn("phone notification delivery failed: {t}", .{err});
                continue;
            };
            self.gpa.free(result);
        }
    }
};

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}
