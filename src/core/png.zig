//! PNG decoding for libghostty-vt (Kitty graphics in shell sessions). The
//! library leaves PNG decoding to its embedder: as a dependency module it is
//! built as the "lib" artifact, which installs no decoder, and `kitten icat`
//! sends PNG. The daemon's and the client's terminal mirrors decode with
//! wuffs, the decoder Ghostty itself uses and libghostty-vt already links
//! for its pixel operations.
const std = @import("std");
const vt = @import("ghostty-vt");
const wuffs = @import("wuffs");

pub fn install() void {
    vt.sys.decode_png = &decode;
}

fn decode(alloc: std.mem.Allocator, data: []const u8) vt.sys.DecodeError!vt.sys.Image {
    const image = wuffs.png.decode(alloc, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    return .{ .width = image.width, .height = image.height, .data = image.data };
}
