//! Comptime string repetition for tests: Zig 0.17 removed the `**` operator.

pub fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return comptime blk: {
        @setEvalBranchQuota(4 * n + 1000);
        var buf: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        const final = buf;
        break :blk &final;
    };
}
