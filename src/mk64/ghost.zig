//! Local, versioned time-trial poses. No ROM data is stored. Ghosts are visual
//! only; they never participate in collision or steering. 60-Hz samples align
//! with the race clock, including across pauses. Format v1 is physics-specific.
const std = @import("std");
const game = @import("game.zig");
const Vec3 = @import("course.zig").Vec3;
const Io = std.Io;
pub const max_ticks = 36000;
pub const Pose = struct { body: Vec3, yaw: f32, wheel: u32 };
pub fn pose(g: game.Game) Pose {
    return .{ .body = g.pos.add(.{ .x = 0, .y = 6 + g.controller.drift.height, .z = 0 }), .yaw = g.yaw + @as(f32, @floatFromInt(g.controller.drift_slip)) * (2 * std.math.pi / 65536.0), .wheel = g.presentation.wheel >> 8 };
}
pub const Run = struct {
    ticks: u32,
    splits: [3]u32,
    frames: []Pose,
    pub fn deinit(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.frames);
    }
};
const magic = "MK64LR01";
const header = 24;
pub fn encode(gpa: std.mem.Allocator, run: Run) ![]u8 {
    try validate(run);
    const bytes = try gpa.alloc(u8, header + run.frames.len * 20 + 32);
    @memcpy(bytes[0..8], magic);
    put(bytes, 8, run.ticks);
    for (run.splits, 0..) |v, i| put(bytes, 12 + i * 4, v);
    for (run.frames, 0..) |p, i| {
        const n = header + i * 20;
        for ([_]f32{ p.body.x, p.body.y, p.body.z, p.yaw }, 0..) |v, j| put(bytes, n + j * 4, @bitCast(v));
        put(bytes, n + 16, p.wheel);
    }
    std.crypto.hash.sha2.Sha256.hash(bytes[0 .. bytes.len - 32], bytes[bytes.len - 32 ..][0..32], .{});
    return bytes;
}
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Run {
    if (bytes.len < header + 32 or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidGhost;
    const ticks = get(bytes, 8);
    if (ticks == 0 or ticks > max_ticks or bytes.len != header + (@as(usize, ticks) + 1) * 20 + 32) return error.InvalidGhost;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0 .. bytes.len - 32], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[bytes.len - 32 ..])) return error.InvalidGhost;
    var run = Run{ .ticks = ticks, .splits = undefined, .frames = try gpa.alloc(Pose, @as(usize, ticks) + 1) };
    errdefer run.deinit(gpa);
    for (&run.splits, 0..) |*v, i| v.* = get(bytes, 12 + i * 4);
    for (run.frames, 0..) |*p, i| {
        const n = header + i * 20;
        p.* = .{ .body = .{ .x = @bitCast(get(bytes, n)), .y = @bitCast(get(bytes, n + 4)), .z = @bitCast(get(bytes, n + 8)) }, .yaw = @bitCast(get(bytes, n + 12)), .wheel = get(bytes, n + 16) };
    }
    try validate(run);
    return run;
}
fn validate(run: Run) !void {
    if (run.ticks == 0 or run.ticks > max_ticks or run.frames.len != @as(usize, run.ticks) + 1) return error.InvalidGhost;
    var sum: u64 = 0;
    for (run.splits) |v| {
        if (v == 0) return error.InvalidGhost;
        sum += v;
    }
    if (sum != run.ticks) return error.InvalidGhost;
    for (run.frames) |p| {
        for ([_]f32{ p.body.x, p.body.y, p.body.z, p.yaw }) |v| if (!std.math.isFinite(v) or @abs(v) > 100000) return error.InvalidGhost;
        if (p.wheel > 3) return error.InvalidGhost;
    }
}
fn put(b: []u8, n: usize, v: u32) void {
    std.mem.writeInt(u32, b[n..][0..4], v, .little);
}
fn get(b: []const u8, n: usize) u32 {
    return std.mem.readInt(u32, b[n..][0..4], .little);
}
pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !?Run {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(header + (max_ticks + 1) * 20 + 32)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer gpa.free(bytes);
    return try decode(gpa, bytes);
}
pub fn save(gpa: std.mem.Allocator, io: Io, path: []const u8, run: Run) !void {
    const bytes = try encode(gpa, run);
    defer gpa.free(bytes);
    if (std.fs.path.dirname(path)) |dir| {
        if (Io.Dir.cwd().openDir(io, dir, .{})) |opened| {
            opened.close(io);
        } else |err| {
            if (err != error.FileNotFound) return err;
            try Io.Dir.cwd().createDirPath(io, dir);
        }
    }
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const temp = try std.fmt.allocPrint(gpa, "{s}.{x}.tmp", .{ path, std.mem.readInt(u64, &nonce, .little) });
    defer gpa.free(temp);
    errdefer Io.Dir.cwd().deleteFile(io, temp) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = bytes });
    try Io.Dir.cwd().rename(temp, Io.Dir.cwd(), path, io);
}
test "ghost round trip rejects corruption and inconsistent split totals" {
    const gpa = std.testing.allocator;
    const p = Pose{ .body = .{ .x = 1, .y = 2, .z = 3 }, .yaw = 0.5, .wheel = 2 };
    var frames = [_]Pose{ p, p, p, p };
    const run = Run{ .ticks = 3, .splits = .{ 1, 1, 1 }, .frames = &frames };
    const bytes = try encode(gpa, run);
    defer gpa.free(bytes);
    const decoded = try decode(gpa, bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(run.ticks, decoded.ticks);
    try std.testing.expectEqualDeep(p, decoded.frames[1]);
    bytes[25] ^= 1;
    try std.testing.expectError(error.InvalidGhost, decode(gpa, bytes));
    var invalid = run;
    invalid.splits[2] = 0;
    try std.testing.expectError(error.InvalidGhost, encode(gpa, invalid));
}
