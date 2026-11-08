//! Wakes a thread when files or directories it watches change: kqueue on
//! macOS, inotify on Linux. Anywhere else, or when a watch cannot be set up,
//! wait() just times out and the caller reads anyway, as if polling.
const std = @import("std");
const builtin = @import("builtin");

const use_kqueue = builtin.os.tag == .macos;
const use_inotify = builtin.os.tag == .linux;
const linux = std.os.linux;

/// What watch() returns for unwatch(): a descriptor (kqueue) or a watch
/// descriptor (inotify).
pub const Handle = i32;

pub const Notifier = struct {
    /// The kqueue, or the inotify instance; -1 when there is neither.
    fd: i32 = -1,
    /// inotify: a pipe polled beside fd, so wake() can interrupt wait().
    wake_pipe: [2]i32 = .{ -1, -1 },

    /// ident of the kqueue user event that wake() triggers.
    const wake_ident = 1;

    pub fn init() Notifier {
        var self: Notifier = .{};
        if (use_kqueue) {
            const kq = std.c.kqueue();
            if (kq < 0) return self;
            const change = [1]std.c.Kevent{.{
                .ident = wake_ident,
                .filter = std.c.EVFILT.USER,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            var none: [1]std.c.Kevent = undefined;
            if (std.c.kevent(kq, &change, 1, &none, 0, null) < 0) {
                _ = std.c.close(kq);
                return self;
            }
            self.fd = kq;
        } else if (use_inotify) {
            const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return self;
            var pipe: [2]i32 = undefined;
            if (linux.errno(linux.pipe2(&pipe, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) {
                _ = linux.close(@intCast(rc));
                return self;
            }
            self.fd = @intCast(rc);
            self.wake_pipe = pipe;
        }
        return self;
    }

    pub fn deinit(self: *Notifier) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        for (self.wake_pipe) |fd| if (fd >= 0) {
            _ = std.c.close(fd);
        };
        self.* = .{};
    }

    pub fn available(self: *const Notifier) bool {
        return self.fd >= 0;
    }

    /// Watch a file (written, appended, replaced) or a directory (an entry
    /// added; on Linux also a file in it written). Null if it cannot be watched.
    pub fn watch(self: *Notifier, path: [:0]const u8) ?Handle {
        if (self.fd < 0) return null;
        if (use_kqueue) {
            const fd = std.c.open(path, .{ .EVTONLY = true, .CLOEXEC = true });
            if (fd < 0) return null;
            const change = [1]std.c.Kevent{.{
                .ident = @intCast(fd),
                .filter = std.c.EVFILT.VNODE,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = std.c.NOTE.WRITE | std.c.NOTE.EXTEND | std.c.NOTE.DELETE | std.c.NOTE.RENAME,
                .data = 0,
                .udata = 0,
            }};
            var none: [1]std.c.Kevent = undefined;
            if (std.c.kevent(self.fd, &change, 1, &none, 0, null) < 0) {
                _ = std.c.close(fd);
                return null;
            }
            return fd;
        }
        if (use_inotify) {
            const mask = linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.CREATE | linux.IN.MOVED_TO |
                linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;
            const rc = linux.inotify_add_watch(self.fd, path, mask);
            if (linux.errno(rc) != .SUCCESS) return null;
            return @intCast(rc);
        }
        return null;
    }

    pub fn unwatch(self: *Notifier, handle: Handle) void {
        if (self.fd < 0) return;
        if (use_kqueue) _ = std.c.close(handle); // closing the descriptor drops its event
        if (use_inotify) _ = linux.inotify_rm_watch(self.fd, handle);
    }

    /// Interrupt a wait() in another thread.
    pub fn wake(self: *Notifier) void {
        if (self.fd < 0) return;
        if (use_kqueue) {
            const change = [1]std.c.Kevent{.{
                .ident = wake_ident,
                .filter = std.c.EVFILT.USER,
                .flags = 0,
                .fflags = std.c.NOTE.TRIGGER,
                .data = 0,
                .udata = 0,
            }};
            var none: [1]std.c.Kevent = undefined;
            _ = std.c.kevent(self.fd, &change, 1, &none, 0, null);
        }
        if (use_inotify) _ = linux.write(self.wake_pipe[1], "x", 1);
    }

    /// Block until something watched changes, wake() is called, or
    /// timeout_ms passes. Returns at once when there is no notifier.
    pub fn wait(self: *Notifier, timeout_ms: u32) void {
        if (self.fd < 0) return;
        if (use_kqueue) {
            var events: [16]std.c.Kevent = undefined;
            const ts: std.c.timespec = .{
                .sec = @intCast(timeout_ms / 1000),
                .nsec = @intCast(@as(u64, timeout_ms % 1000) * std.time.ns_per_ms),
            };
            _ = std.c.kevent(self.fd, &events, 0, &events, events.len, &ts);
        }
        if (use_inotify) {
            var fds = [2]linux.pollfd{
                .{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_pipe[0], .events = linux.POLL.IN, .revents = 0 },
            };
            _ = linux.poll(&fds, fds.len, @intCast(timeout_ms));
            // What changed does not matter: the caller reads every watched
            // file. Drain both so the next wait blocks again.
            var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
            for ([_]i32{ self.fd, self.wake_pipe[0] }) |fd| {
                while (true) {
                    const rc = linux.read(fd, &buf, buf.len);
                    if (linux.errno(rc) != .SUCCESS or rc == 0) break;
                }
            }
        }
    }
};
