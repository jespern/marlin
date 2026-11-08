//! Stand-in for Ghostty's src/quirks.zig: the sprite font and the OpenType
//! readers need only its assert.
const std = @import("std");
const builtin = @import("builtin");

pub const inlineAssert = switch (builtin.mode) {
    .debug => std.debug.assert,
    .small, .safe, .fast => (struct {
        inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }).assert,
};
