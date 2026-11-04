//! Kitty graphics from shell sessions (`kitten icat`, ...) shown on the host
//! terminal. The shell's emulator keeps the images and their placements;
//! after each frame this sends every image once, places the visible ones
//! over their transcript rows (cropped when partly scrolled off), and
//! removes placements that left the view. vaxis's own graphics stay off
//! (see pixel_effects.zig), so this speaks the protocol directly, with ids
//! from a range of its own and an explicit placement id per placement so
//! re-placing every frame replaces rather than piles up.
const std = @import("std");
const vt = @import("ghostty-vt");

const chunk_bytes: usize = 4096;
const first_id: u32 = 0x4d530000;

/// Where one image placement goes on the host terminal this frame.
pub const Want = struct {
    image: *const vt.kitty.graphics.Image,
    /// Identity of the image data, so a retransmitted image is resent.
    key: ImageKey,
    placement: u32,
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,
    x_offset: u32 = 0,
    y_offset: u32 = 0,
    source: Rect,
};

pub const Rect = struct { x: u32, y: u32, width: u32, height: u32 };
pub const ImageKey = struct { owner: usize, image_id: u32, data: usize, len: usize };
const Shown = struct { id: u32, placement: u32 };

pub const Display = struct {
    sent: std.AutoHashMapUnmanaged(ImageKey, u32) = .empty,
    shown: std.AutoHashMapUnmanaged(Shown, void) = .empty,
    next_id: u32 = first_id,

    pub fn deinit(self: *Display, gpa: std.mem.Allocator) void {
        self.sent.deinit(gpa);
        self.shown.deinit(gpa);
    }

    /// Make the host terminal show exactly `wants`.
    pub fn update(self: *Display, gpa: std.mem.Allocator, w: *std.Io.Writer, wants: []const Want) !void {
        var next: std.AutoHashMapUnmanaged(Shown, void) = .empty;
        errdefer next.deinit(gpa);
        for (wants) |want| {
            const id = self.sent.get(want.key) orelse id: {
                const id = self.next_id;
                self.next_id +%= 1;
                if (self.next_id < first_id) self.next_id = first_id;
                try transmit(gpa, w, id, want.image);
                try self.sent.put(gpa, want.key, id);
                break :id id;
            };
            try place(w, id, want);
            try next.put(gpa, .{ .id = id, .placement = want.placement }, {});
        }
        var it = self.shown.keyIterator();
        while (it.next()) |old| if (!next.contains(old.*))
            try w.print("\x1b_Ga=d,d=i,i={d},p={d},q=2;\x1b\\", .{ old.id, old.placement });
        self.shown.deinit(gpa);
        self.shown = next;
    }

    /// Free images whose data is no longer wanted by any shell.
    pub fn forget(self: *Display, w: *std.Io.Writer, keep: *const fn (ctx: ?*anyopaque, key: ImageKey) bool, ctx: ?*anyopaque) !void {
        var it = self.sent.iterator();
        while (it.next()) |entry| {
            if (keep(ctx, entry.key_ptr.*)) continue;
            try w.print("\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{entry.value_ptr.*});
            self.sent.removeByPtr(entry.key_ptr);
            it = self.sent.iterator();
        }
    }
};

/// Send pixels once (a=t). Gray formats widen to RGB(A).
fn transmit(gpa: std.mem.Allocator, w: *std.Io.Writer, id: u32, image: *const vt.kitty.graphics.Image) !void {
    const data = image.data.bytes() orelse return;
    var owned: ?[]u8 = null;
    defer if (owned) |bytes| gpa.free(bytes);
    const pixels: []const u8, const format: u8 = switch (image.format) {
        .rgb => .{ data, 24 },
        .rgba => .{ data, 32 },
        .gray => blk: {
            const rgb = try gpa.alloc(u8, data.len * 3);
            for (data, 0..) |g, i| @memset(rgb[i * 3 ..][0..3], g);
            owned = rgb;
            break :blk .{ rgb, 24 };
        },
        .gray_alpha => blk: {
            const rgba = try gpa.alloc(u8, data.len * 2);
            for (0..data.len / 2) |i| {
                @memset(rgba[i * 4 ..][0..3], data[i * 2]);
                rgba[i * 4 + 3] = data[i * 2 + 1];
            }
            owned = rgba;
            break :blk .{ rgba, 32 };
        },
        .png => return, // decoded on load; never stored as PNG
    };
    const encoder = std.base64.standard.Encoder;
    const encoded = try gpa.alloc(u8, encoder.calcSize(pixels.len));
    defer gpa.free(encoded);
    _ = encoder.encode(encoded, pixels);
    var offset: usize = 0;
    var first = true;
    while (offset < encoded.len or first) {
        const end = @min(offset + chunk_bytes, encoded.len);
        const more: u1 = if (end < encoded.len) 1 else 0;
        if (first)
            try w.print("\x1b_Ga=t,f={d},s={d},v={d},i={d},q=2,m={d};{s}\x1b\\", .{ format, image.width, image.height, id, more, encoded[offset..end] })
        else
            try w.print("\x1b_Gm={d};{s}\x1b\\", .{ more, encoded[offset..end] });
        first = false;
        offset = end;
    }
}

/// Put (or move) one placement (a=p); the cursor stays put (C=1).
fn place(w: *std.Io.Writer, id: u32, want: Want) !void {
    try w.print("\x1b7\x1b[{d};{d}H", .{ @as(u32, want.row) + 1, @as(u32, want.col) + 1 });
    try w.print("\x1b_Ga=p,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d},X={d},Y={d},C=1,q=2;\x1b\\", .{
        id,                want.placement,
        want.cols,         want.rows,
        want.source.x,     want.source.y,
        want.source.width, want.source.height,
        want.x_offset,     want.y_offset,
    });
    try w.writeAll("\x1b8");
}
