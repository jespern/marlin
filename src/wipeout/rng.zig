//! Deterministic random source owned by the game state so a snapshot
//! resumes with the same sequence. xorshift32; only quality-insensitive
//! gameplay jitter depends on it.

pub const Rng = struct {
    state: u32 = 0x9e37_79b9,

    pub fn seed(s: u32) Rng {
        return .{ .state = if (s == 0) 0x9e37_79b9 else s };
    }

    pub fn next(self: *Rng) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    pub fn float(self: *Rng, min: f32, max: f32) f32 {
        const unit = @as(f32, @floatFromInt(self.next() >> 8)) / @as(f32, 1 << 24);
        return min + unit * (max - min);
    }

    pub fn int(self: *Rng, min: i32, max: i32) i32 {
        const span: u32 = @intCast(@max(max - min, 1));
        return min + @as(i32, @intCast(self.next() % span));
    }
};
