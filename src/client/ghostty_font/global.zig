//! Stand-in for Ghostty's src/global.zig: the sprite canvas asks it for the
//! process's Io when it draws paths. Marlin sets it before drawing.
const std = @import("std");
const builtin = @import("builtin");

pub var instance: ?std.Io = null;

pub fn io() std.Io {
    if (instance) |value| return value;
    if (builtin.is_test) return std.testing.io;
    unreachable; // root.setIo first
}
