//! PNG decoding for libghostty-vt (Kitty graphics in shell sessions). The
//! library leaves PNG decoding to its embedder: as a dependency module it is
//! built as the "lib" artifact, which ships no decoder, and `kitten icat`
//! sends PNG. vaxis already carries zigimg, so the daemon's and the
//! client's terminal mirrors decode with it.
const std = @import("std");
const vt = @import("ghostty-vt");
const zigimg = @import("vaxis").zigimg;

pub fn install() void {
    vt.sys.decode_png = &decode;
}

fn decode(alloc: std.mem.Allocator, data: []const u8) vt.sys.DecodeError!vt.sys.Image {
    var image = zigimg.Image.fromMemory(alloc, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    defer image.deinit(alloc);
    image.convert(alloc, .rgba32) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    return .{
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .data = try alloc.dupe(u8, image.rawBytes()),
    };
}
