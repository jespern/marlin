const proto = @import("../core/proto.zig");
const limits = @import("../core/recap.zig");

pub const State = struct {
    last_change_ms: i64 = 0,
    last_activity_ms: i64 = 0,
    attempted_seq: u64 = 0,
    pending_seq: u64 = 0,
    retry_at_ms: i64 = 0,
    shown_seq: u64 = 0,

    pub fn changed(self: *State, timestamp: i64) void {
        self.last_change_ms = @max(self.last_change_ms, timestamp);
        self.pending_seq = 0;
    }

    pub fn due(self: *const State, state: proto.SessionState, seq: u64, now: i64) bool {
        return (state == .idle or state == .done or state == .err) and seq > 0 and
            seq != self.attempted_seq and self.pending_seq == 0 and self.last_change_ms > 0 and
            now >= self.retry_at_ms and now - @max(self.last_change_ms, self.last_activity_ms) >= limits.idle_ms;
    }

    pub fn accept(self: *State, current_seq: u64, response_seq: u64, retry: bool, now: i64) bool {
        if (self.pending_seq != response_seq) return false;
        self.pending_seq = 0;
        if (current_seq != response_seq or self.shown_seq == response_seq) return false;
        if (retry) {
            self.attempted_seq = 0;
            self.retry_at_ms = now + 15_000;
            return false;
        }
        return true;
    }
};
