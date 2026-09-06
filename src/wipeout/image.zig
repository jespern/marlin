//! PSX texture decoding: TIM images and the LZSS-packed CMP bundles that
//! hold them. Decoded pixels are 8-bit RGBA with alpha 0 for the PSX
//! "transparent black" sentinel.

const std = @import("std");
const bytes = @import("bytes.zig");
const math = @import("math.zig");
const Rgba = math.Rgba;

pub const Error = error{
    UnsupportedTimType,
    CorruptCmp,
    CorruptLzss,
} || bytes.Error || std.mem.Allocator.Error;

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []Rgba,

    pub fn alloc(gpa: std.mem.Allocator, width: u32, height: u32) !Image {
        const pixels = try gpa.alloc(Rgba, @as(usize, width) * height);
        @memset(pixels, Rgba.init(0, 0, 0, 0));
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }

    /// Copy a `sw`x`sh` block from `src` at (`sx`,`sy`) into `dst` at (`dx`,`dy`).
    pub fn blit(dst: *Image, src: *const Image, sx: u32, sy: u32, sw: u32, sh: u32, dx: u32, dy: u32) void {
        var y: u32 = 0;
        while (y < sh) : (y += 1) {
            const src_row = (sy + y) * src.width + sx;
            const dst_row = (dy + y) * dst.width + dx;
            @memcpy(dst.pixels[dst_row .. dst_row + sw], src.pixels[src_row .. src_row + sw]);
        }
    }
};

const tim_type_paletted_4bpp = 0x08;
const tim_type_paletted_8bpp = 0x09;
const tim_type_true_color_16bpp = 0x02;

fn colorFrom16(c: u16, transparent_bit: bool) Rgba {
    const alpha: u8 = if (c == 0)
        0
    else if (transparent_bit and (c & 0x7fff) == 0)
        0
    else
        0xff;
    return Rgba.init(
        @as(u8, @truncate((c >> 0) & 0x1f)) << 3,
        @as(u8, @truncate((c >> 5) & 0x1f)) << 3,
        @as(u8, @truncate((c >> 10) & 0x1f)) << 3,
        alpha,
    );
}

/// Decode a TIM (PSX texture) blob.
pub fn decodeTim(gpa: std.mem.Allocator, data: []const u8, transparent: bool) Error!Image {
    var r = bytes.Reader.init(data);
    _ = try r.u32Le(); // magic
    // Wipeout 64 stores extra flags in the high bits; only the low nibble
    // selects the pixel mode.
    const kind = (try r.u32Le()) & 0xF;

    var palette: [256]Rgba = undefined;
    if (kind == tim_type_paletted_4bpp or kind == tim_type_paletted_8bpp) {
        _ = try r.u32Le(); // clut block byte length
        _ = try r.u16Le(); // palette x
        _ = try r.u16Le(); // palette y
        const palette_colors = try r.u16Le();
        _ = try r.u16Le(); // palette count
        var i: usize = 0;
        while (i < palette_colors) : (i += 1) {
            const c = colorFrom16(try r.u16Le(), transparent);
            if (i < palette.len) palette[i] = c;
        }
    } else if (kind != tim_type_true_color_16bpp) {
        return error.UnsupportedTimType;
    }

    _ = try r.u32Le(); // pixel block byte length
    const pixels_per_entry: u32 = switch (kind) {
        tim_type_paletted_8bpp => 2,
        tim_type_paletted_4bpp => 4,
        else => 1,
    };
    _ = try r.u16Le(); // frame buffer x
    _ = try r.u16Le(); // frame buffer y
    const entries_per_row: u32 = try r.u16Le();
    const rows: u32 = try r.u16Le();

    const width = entries_per_row * pixels_per_entry;
    var image = try Image.alloc(gpa, width, rows);
    errdefer image.deinit(gpa);

    const entries = entries_per_row * rows;
    var out: usize = 0;
    var i: u32 = 0;
    switch (kind) {
        tim_type_true_color_16bpp => while (i < entries) : (i += 1) {
            image.pixels[out] = colorFrom16(try r.u16Le(), transparent);
            out += 1;
        },
        tim_type_paletted_8bpp => while (i < entries) : (i += 1) {
            const v = try r.u16Le();
            image.pixels[out] = palette[v & 0xff];
            image.pixels[out + 1] = palette[(v >> 8) & 0xff];
            out += 2;
        },
        else => while (i < entries) : (i += 1) {
            const v = try r.u16Le();
            image.pixels[out] = palette[v & 0xf];
            image.pixels[out + 1] = palette[(v >> 4) & 0xf];
            image.pixels[out + 2] = palette[(v >> 8) & 0xf];
            image.pixels[out + 3] = palette[(v >> 12) & 0xf];
            out += 4;
        },
    }
    return image;
}

// LZSS parameters used by the CMP bundles: 13-bit window offsets, 4-bit
// match lengths, a one-byte break-even, and offset 0 as the end marker.
const lzss_index_bits = 13;
const lzss_length_bits = 4;
const lzss_window_size = 1 << lzss_index_bits;
const lzss_break_even = (1 + lzss_index_bits + lzss_length_bits) / 9;

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    rack: u8 = 0,
    mask: u8 = 0x80,

    fn bit(self: *BitReader) Error!bool {
        if (self.mask == 0x80) {
            if (self.pos >= self.data.len) return error.CorruptLzss;
            self.rack = self.data[self.pos];
            self.pos += 1;
        }
        const v = (self.rack & self.mask) != 0;
        self.mask >>= 1;
        if (self.mask == 0) self.mask = 0x80;
        return v;
    }

    fn bits(self: *BitReader, count: u5) Error!u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < count) : (i += 1) {
            v = (v << 1) | @as(u32, @intFromBool(try self.bit()));
        }
        return v;
    }
};

/// Expand an LZSS stream into `out`, which must be exactly the expected
/// decompressed length. Returns the number of bytes written.
pub fn lzssDecompress(input: []const u8, out: []u8) Error!usize {
    var window: [lzss_window_size]u8 = undefined;
    @memset(&window, 0);
    var br = BitReader{ .data = input };
    var current: usize = 1;
    var written: usize = 0;

    while (true) {
        if (try br.bit()) {
            const c: u8 = @intCast(try br.bits(8));
            if (written >= out.len) return error.CorruptLzss;
            out[written] = c;
            written += 1;
            window[current] = c;
            current = (current + 1) & (lzss_window_size - 1);
        } else {
            const match_position: usize = try br.bits(lzss_index_bits);
            if (match_position == 0) break;
            const match_length: usize = (try br.bits(lzss_length_bits)) + lzss_break_even;
            var i: usize = 0;
            while (i <= match_length) : (i += 1) {
                const c = window[(match_position + i) & (lzss_window_size - 1)];
                if (written >= out.len) return error.CorruptLzss;
                out[written] = c;
                written += 1;
                window[current] = c;
                current = (current + 1) & (lzss_window_size - 1);
            }
        }
    }
    return written;
}

/// A decompressed CMP bundle: a list of TIM blobs sharing one buffer.
pub const Cmp = struct {
    buffer: []u8,
    entries: [][]const u8,

    pub fn deinit(self: Cmp, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        gpa.free(self.buffer);
    }
};

pub fn decodeCmp(gpa: std.mem.Allocator, data: []const u8) Error!Cmp {
    var r = bytes.Reader.init(data);
    const count_signed = try r.i32Le();
    if (count_signed < 0 or count_signed > 4096) return error.CorruptCmp;
    const count: usize = @intCast(count_signed);

    var total: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const size = try r.i32Le();
        if (size < 0) return error.CorruptCmp;
        total += @intCast(size);
    }

    const buffer = try gpa.alloc(u8, total);
    errdefer gpa.free(buffer);
    const entries = try gpa.alloc([]const u8, count);
    errdefer gpa.free(entries);

    var sizes = bytes.Reader.init(data);
    try sizes.skip(4);
    var offset: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const size: usize = @intCast(try sizes.i32Le());
        entries[i] = buffer[offset .. offset + size];
        offset += size;
    }

    _ = try lzssDecompress(data[r.pos..], buffer);
    return .{ .buffer = buffer, .entries = entries };
}

test "true colour tim decodes with transparent black" {
    // 2x1 16bpp image: pixel 0 = black (transparent), pixel 1 = 0x7fff white.
    const data = [_]u8{
        0x10, 0x00, 0x00, 0x00, // magic
        0x02, 0x00, 0x00, 0x00, // type: 16bpp
        0x10, 0x00, 0x00, 0x00, // block length
        0x00, 0x00, 0x00, 0x00, // fb x, y
        0x02, 0x00, 0x01, 0x00, // entries per row, rows
        0x00, 0x00, 0xff, 0x7f,
    };
    const img = try decodeTim(std.testing.allocator, &data, false);
    defer img.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u8, 0), img.pixels[0].a);
    try std.testing.expectEqual(@as(u8, 0xf8), img.pixels[1].r);
    try std.testing.expectEqual(@as(u8, 0xff), img.pixels[1].a);
}

test "lzss literal run then end marker" {
    // Bits: 1 + 8 literal bits ('A' = 0x41), then 0 + 13 zero bits (end).
    // 1 01000001 0 0000000000000 -> 1010 0000 1000 0000 0000 00(00)
    const data = [_]u8{ 0xa0, 0x80, 0x00, 0x00 };
    var out: [4]u8 = undefined;
    const n = try lzssDecompress(&data, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 'A'), out[0]);
}
