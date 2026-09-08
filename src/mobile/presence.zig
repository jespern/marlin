//! Dispatcher-owned, bounded leases. Quiet reading counts as activity for two
//! minutes in the TUI. Heartbeats expire after 30 seconds if a client freezes.
pub const Kind = enum { terminal, phone };
pub const Lease = struct { id: u64 = 0, kind: Kind = .terminal, sid: u64 = 0, until: i64 = 0 };
pub const Presence = struct {
    leases: [128]Lease = @splat(.{}),
    pub fn update(self: *Presence, kind: Kind, id: u64, sid: u64, active: bool, now: i64) bool {
        if (id == 0) return false;
        var free: ?*Lease = null;
        for (&self.leases) |*lease| {
            if (lease.id == id and lease.kind == kind) {
                lease.* = .{ .id = id, .kind = kind, .sid = sid, .until = if (active) now +| 30_000 else 0 };
                return true;
            }
            if (lease.until <= now) free = lease;
        }
        if (!active) return true;
        const lease = free orelse return false;
        lease.* = .{ .id = id, .kind = kind, .sid = sid, .until = now +| 30_000 };
        return true;
    }
    pub fn suppress(self: *const Presence, sid: u64, now: i64) bool {
        for (self.leases) |lease| {
            if (lease.until > now and (lease.kind == .terminal or lease.sid == sid)) return true;
        }
        return false;
    }
};

const std = @import("std");
/// The dispatcher updates leases; the delivery worker rechecks them just
/// before network delivery so queued work respects newly focused clients.
pub const Shared = struct {
    mutex: std.Io.Mutex = .init,
    value: Presence = .{},
    pub fn update(self: *Shared, io: std.Io, kind: Kind, id: u64, sid: u64, active: bool, now: i64) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.value.update(kind, id, sid, active, now);
    }
    pub fn suppress(self: *Shared, io: std.Io, sid: u64, now: i64) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.value.suppress(sid, now);
    }
};
