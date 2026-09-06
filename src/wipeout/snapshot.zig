//! Bytewise race snapshots. Everything the simulation needs to continue is
//! plain data referencing assets by index, so a snapshot is the state
//! structs themselves behind a small header. A mismatch in magic, version
//! or size is treated as "no snapshot" rather than an error.

const std = @import("std");
const ship_mod = @import("ship.zig");
const camera_mod = @import("camera.zig");
const input_mod = @import("input.zig");
const rng_mod = @import("rng.zig");
const Io = std.Io;

pub const magic: u32 = 0x5750_4f53; // "WPOS"
pub const version: u32 = 1;

pub const Snapshot = extern struct {
    magic: u32 = magic,
    version: u32 = version,
    size: u32 = @sizeOf(Snapshot),
    track: u8,
    pilot: u8,
    rapier: u8,
    crt: u8,
    steps: u64,
    ship: ship_mod.Ship,
    camera: camera_mod.Camera,
    rng: rng_mod.Rng,
    _reserved: [4]u32 = .{ 0, 0, 0, 0 },

    pub fn valid(self: *const Snapshot) bool {
        return self.magic == magic and self.version == version and self.size == @sizeOf(Snapshot);
    }
};

/// `$XDG_STATE_HOME/marlin/wipeout-race.bin`, else under ~/.local/state.
/// Caller frees.
pub fn defaultPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("XDG_STATE_HOME")) |state| {
        if (state.len > 0) return std.fs.path.join(gpa, &.{ state, "marlin", "wipeout-race.bin" });
    }
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "marlin", "wipeout-race.bin" });
}

pub fn write(io: Io, path: []const u8, snap: *const Snapshot) !void {
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.asBytes(snap) });
}

/// Null when the file is missing or does not match this build's layout.
pub fn read(io: Io, gpa: std.mem.Allocator, path: []const u8) ?Snapshot {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(@sizeOf(Snapshot) + 16)) catch return null;
    defer gpa.free(bytes);
    if (bytes.len != @sizeOf(Snapshot)) return null;
    var snap: Snapshot = undefined;
    @memcpy(std.mem.asBytes(&snap), bytes);
    if (!snap.valid()) return null;
    return snap;
}

pub fn remove(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "snapshot round-trips through bytes and rejects other layouts" {
    var snap = Snapshot{
        .track = 3,
        .pilot = 6,
        .rapier = 1,
        .crt = 1,
        .steps = 1234,
        .ship = std.mem.zeroes(ship_mod.Ship),
        .camera = .{},
        .rng = rng_mod.Rng.seed(7),
    };
    snap.ship.position.x = 42.5;
    const bytes = std.mem.asBytes(&snap);
    var back: Snapshot = undefined;
    @memcpy(std.mem.asBytes(&back), bytes);
    try std.testing.expect(back.valid());
    try std.testing.expectEqual(@as(f32, 42.5), back.ship.position.x);
    try std.testing.expectEqual(@as(u64, 1234), back.steps);
    back.version += 1;
    try std.testing.expect(!back.valid());
}
