//! Offline orb frames: `zig build orb-probe -- <out-dir> [width height] [frames...]`
//! renders the orb effect over a synthetic dimmed-transcript backdrop and
//! writes one binary PPM per requested frame, so the look can be judged and
//! diffed without a Kitty terminal. Defaults: 720×405, frames 0 60 120 180.

const std = @import("std");
const orb = @import("orb");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: orb-probe <out-dir> [width height] [frame ...]\n", .{});
        return error.Usage;
    }
    const out_dir = args[1];
    var width: u16 = 720;
    var height: u16 = 405;
    var frames_start: usize = 2;
    if (args.len >= 4) {
        if (std.fmt.parseInt(u16, args[2], 10)) |w| {
            width = w;
            height = try std.fmt.parseInt(u16, args[3], 10);
            frames_start = 4;
        } else |_| {}
    }
    const default_frames = [_]u64{ 0, 60, 120, 180 };
    var frames: std.ArrayList(u64) = .empty;
    defer frames.deinit(gpa);
    if (frames_start < args.len) {
        for (args[frames_start..]) |a| try frames.append(gpa, try std.fmt.parseInt(u64, a, 10));
    } else try frames.appendSlice(gpa, &default_frames);

    const len = @as(usize, width) * height * 3;
    const background = try gpa.alloc(u8, len);
    defer gpa.free(background);
    const rgb = try gpa.alloc(u8, len);
    defer gpa.free(rgb);
    syntheticBackdrop(background, width, height);

    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, out_dir, .{});
    defer dir.close(io);
    for (frames.items) |frame| {
        orb.render(rgb, background, width, height, frame, 9);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "orb-{d:0>5}.ppm", .{frame});
        var file = try dir.createFile(io, name, .{});
        defer file.close(io);
        var buf: [1 << 16]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.print("P6\n{d} {d}\n255\n", .{ width, height });
        try w.interface.writeAll(rgb);
        try w.interface.flush();
    }
}

/// A stand-in for the blurred transcript capture: dark blue-grey with faint
/// horizontal text-like bands, so the orb is judged over what it really sits on.
fn syntheticBackdrop(background: []u8, width: u16, height: u16) void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const band: u8 = if ((y / 14) % 2 == 0 and x > width / 20 and x < width * 3 / 4 and (x / 9) % 5 != 0) 14 else 0;
            const i = (y * width + x) * 3;
            background[i] = 6 + band;
            background[i + 1] = 8 + band;
            background[i + 2] = 14 + band;
        }
    }
}
