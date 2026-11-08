//! Screenshots painted from Marlin's own frame, the way Ghostty paints a
//! terminal: cell backgrounds, then underlines, text, strikethroughs, the
//! cursor, and Kitty images, into RGBA pixels, encoded as PNG.
//!
//! Box drawing, blocks, underlines, and cursors are Ghostty's own sprite
//! code (ghostty_font), so they match Ghostty pixel for pixel. Text comes
//! from a `Text` backend that shapes and rasterizes it the way Ghostty
//! does on that platform (raster_coretext.zig on macOS); the blending here
//! is Ghostty's default: coverage over the cell background in sRGB.
const std = @import("std");
const ghostty_font = @import("ghostty_font");

pub const Metrics = ghostty_font.Metrics;
pub const Rgb = [3]u8;

pub const Underline = enum { none, single, double, curly, dotted, dashed };

pub const Cell = struct {
    /// The grapheme; empty for a blank cell or the tail of a wide one.
    text: []const u8 = "",
    /// Columns the grapheme covers: 1, 2 for wide, 0 for a wide tail.
    width: u2 = 1,
    fg: Rgb,
    bg: Rgb,
    /// Text opacity: faint text is drawn at Ghostty's faint-opacity.
    alpha: u8 = 255,
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    underline: Underline = .none,
    underline_color: ?Rgb = null,
};

pub const CursorStyle = enum { block, hollow, bar, underline };

pub const Cursor = struct {
    col: u16,
    row: u16,
    style: CursorStyle,
    /// Ghostty's cursor-color; the cell's text color when unset.
    color: ?Rgb = null,
    /// Ghostty's cursor-text: text under a block cursor; else its bg.
    text: ?Rgb = null,
};

/// A Kitty image placement, already cropped to what is visible.
pub const Image = struct {
    /// Straight-alpha RGBA, `width` x `height`.
    pixels: []const u8,
    width: u32,
    height: u32,
    /// The part of `pixels` shown.
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_width: u32,
    src_height: u32,
    /// Where it lands, in pixels from the grid's top left, and its size.
    x: i32,
    y: i32,
    dst_width: u32,
    dst_height: u32,
};

pub const Frame = struct {
    cols: u16,
    rows: u16,
    /// `rows` x `cols`, row by row.
    cells: []const Cell,
    /// The terminal background, around and under default cells.
    background: Rgb,
    cursor: ?Cursor = null,
    images: []const Image = &.{},

    pub fn row(self: Frame, y: usize) []const Cell {
        return self.cells[y * self.cols ..][0..self.cols];
    }
};

/// One rasterized glyph, positioned relative to the top left of the cell
/// whose text color it takes.
pub const Glyph = struct {
    col: u16,
    /// Coverage (`color` false) or premultiplied BGRA (`color` true).
    data: []const u8,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    color: bool,
};

/// Shapes and rasterizes the text of one row. Cells with sprites (see
/// `isSprite`) are drawn here, not by the backend.
pub const Text = struct {
    ctx: *anyopaque,
    /// Glyphs for `row`, allocated in `arena`. `cursor_col` breaks runs
    /// around the cursor as Ghostty does.
    shapeRow: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, row: []const Cell, cursor_col: ?u16) anyerror![]const Glyph,
};

pub const Picture = struct {
    width: u32,
    height: u32,
    /// Opaque RGBA.
    pixels: []u8,

    pub fn deinit(self: Picture, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }

    pub fn pixel(self: Picture, x: u32, y: u32) Rgb {
        const at = (y * self.width + x) * 4;
        return self.pixels[at..][0..3].*;
    }
};

/// The first codepoint of a grapheme that Ghostty draws as a sprite (a
/// box-drawing or block character), or null.
pub fn spriteCodepoint(text: []const u8) ?u21 {
    const view = std.unicode.Utf8View.init(text) catch return null;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return null;
    if (it.nextCodepoint() != null) return null;
    return if (ghostty_font.hasSprite(cp)) cp else null;
}

pub const Options = struct {
    /// Background margin around the grid, in pixels.
    padding: u32 = 0,
};

/// Paint `frame` with cells `metrics.cell_width` x `metrics.cell_height`
/// pixels. Without `text`, only backgrounds, sprites, lines, the cursor,
/// and images are drawn.
pub fn paint(gpa: std.mem.Allocator, frame: Frame, metrics: Metrics, text: ?Text, options: Options) !Picture {
    const cw = metrics.cell_width;
    const ch = metrics.cell_height;
    const pad = options.padding;
    var canvas: Canvas = .{
        .width = @as(u32, frame.cols) * cw + 2 * pad,
        .height = @as(u32, frame.rows) * ch + 2 * pad,
        .pixels = undefined,
        .origin_x = @intCast(pad),
        .origin_y = @intCast(pad),
    };
    canvas.pixels = try gpa.alloc(u8, @as(usize, canvas.width) * canvas.height * 4);
    errdefer gpa.free(canvas.pixels);
    canvas.fill(0, 0, canvas.width, canvas.height, frame.background);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (0..frame.rows) |y| {
        const row_cells = frame.row(y);
        const top: i32 = @intCast(y * ch);
        const cursor_col: ?u16 = if (frame.cursor) |c| if (c.row == y) c.col else null else null;

        // Backgrounds, each cell its own.
        for (row_cells, 0..) |cell, x| {
            if (std.mem.eql(u8, &cell.bg, &frame.background)) continue;
            canvas.fillCell(@intCast(x * cw), top, cw, ch, cell.bg);
        }
        // A block cursor is a background the text is drawn over.
        if (cursor_col) |col| if (frame.cursor.?.style == .block and col < frame.cols) {
            const cell = row_cells[col];
            try canvas.sprite(gpa, @backingInt(ghostty_font.Sprite.cursor_rect), @max(cell.width, 1), metrics, @intCast(col * cw), top, frame.cursor.?.color orelse cell.fg, 255);
        };

        // Underlines go under the text.
        for (row_cells, 0..) |cell, x| {
            const sprite: ghostty_font.Sprite = switch (cell.underline) {
                .none => continue,
                .single => .underline,
                .double => .underline_double,
                .curly => .underline_curly,
                .dotted => .underline_dotted,
                .dashed => .underline_dashed,
            };
            try canvas.sprite(gpa, @backingInt(sprite), @max(cell.width, 1), metrics, @intCast(x * cw), top, cell.underline_color orelse cell.fg, cell.alpha);
        }

        // Text: sprites here, everything else through the backend.
        for (row_cells, 0..) |cell, x| {
            const cp = spriteCodepoint(cell.text) orelse continue;
            try canvas.sprite(gpa, cp, @max(cell.width, 1), metrics, @intCast(x * cw), top, textColor(frame, cell, @intCast(x), @intCast(y)), cell.alpha);
        }
        if (text) |backend| {
            _ = arena_state.reset(.retain_capacity);
            const glyphs = try backend.shapeRow(backend.ctx, arena, row_cells, cursor_col);
            for (glyphs) |glyph| {
                const cell = row_cells[glyph.col];
                const left: i32 = @as(i32, glyph.col) * @as(i32, @intCast(cw));
                if (glyph.color) {
                    canvas.blendPremultiplied(left + glyph.x, top + glyph.y, glyph.width, glyph.height, glyph.data, cell.alpha);
                } else {
                    canvas.blendMask(left + glyph.x, top + glyph.y, glyph.width, glyph.height, glyph.data, textColor(frame, cell, glyph.col, @intCast(y)), cell.alpha);
                }
            }
        }

        for (row_cells, 0..) |cell, x| {
            if (!cell.strikethrough) continue;
            try canvas.sprite(gpa, @backingInt(ghostty_font.Sprite.strikethrough), @max(cell.width, 1), metrics, @intCast(x * cw), top, cell.fg, cell.alpha);
        }

        if (cursor_col) |col| if (col < frame.cols) {
            const cursor = frame.cursor.?;
            const cell = row_cells[col];
            const sprite: ?ghostty_font.Sprite = switch (cursor.style) {
                .block => null,
                .hollow => .cursor_hollow_rect,
                .bar => .cursor_bar,
                .underline => .cursor_underline,
            };
            if (sprite) |s| try canvas.sprite(gpa, @backingInt(s), @max(cell.width, 1), metrics, @intCast(col * cw), top, cursor.color orelse cell.fg, 255);
        };
    }

    for (frame.images) |image| canvas.image(image);
    return .{ .width = canvas.width, .height = canvas.height, .pixels = canvas.pixels };
}

/// Text color at a cell: under a block cursor, Ghostty's cursor-text.
fn textColor(frame: Frame, cell: Cell, col: u16, row: u16) Rgb {
    if (frame.cursor) |cursor| if (cursor.style == .block and cursor.row == row and cursor.col == col) {
        return cursor.text orelse cell.bg;
    };
    return cell.fg;
}

const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    /// Where the grid starts.
    origin_x: i32,
    origin_y: i32,

    fn fill(self: *Canvas, x: u32, y: u32, w: u32, h: u32, color: Rgb) void {
        for (y..@min(y + h, self.height)) |py| {
            for (x..@min(x + w, self.width)) |px| {
                const at = (py * self.width + px) * 4;
                self.pixels[at..][0..4].* = .{ color[0], color[1], color[2], 255 };
            }
        }
    }

    fn fillCell(self: *Canvas, x: i32, y: i32, w: u32, h: u32, color: Rgb) void {
        self.fill(@intCast(self.origin_x + x), @intCast(self.origin_y + y), w, h, color);
    }

    /// Ghostty's text blending: `color` at coverage x `alpha` over what is
    /// there, in sRGB.
    fn blendMask(self: *Canvas, x: i32, y: i32, w: u32, h: u32, mask: []const u8, color: Rgb, alpha: u8) void {
        for (0..h) |my| {
            const py = self.origin_y + y + @as(i32, @intCast(my));
            if (py < 0 or py >= self.height) continue;
            for (0..w) |mx| {
                const px = self.origin_x + x + @as(i32, @intCast(mx));
                if (px < 0 or px >= self.width) continue;
                const coverage = mask[my * w + mx];
                if (coverage == 0) continue;
                const a: u32 = (@as(u32, coverage) * alpha + 127) / 255;
                const at = (@as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px))) * 4;
                for (0..3) |c| self.pixels[at + c] = lerp(self.pixels[at + c], color[c], a);
            }
        }
    }

    /// A color glyph (premultiplied BGRA) over what is there.
    fn blendPremultiplied(self: *Canvas, x: i32, y: i32, w: u32, h: u32, bgra: []const u8, alpha: u8) void {
        for (0..h) |my| {
            const py = self.origin_y + y + @as(i32, @intCast(my));
            if (py < 0 or py >= self.height) continue;
            for (0..w) |mx| {
                const px = self.origin_x + x + @as(i32, @intCast(mx));
                if (px < 0 or px >= self.width) continue;
                const src = bgra[(my * w + mx) * 4 ..][0..4];
                const a: u32 = (@as(u32, src[3]) * alpha + 127) / 255;
                if (a == 0) continue;
                const at = (@as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px))) * 4;
                const rgb = [3]u8{ src[2], src[1], src[0] };
                for (0..3) |c| {
                    const s: u32 = (@as(u32, rgb[c]) * alpha + 127) / 255;
                    const d: u32 = self.pixels[at + c];
                    self.pixels[at + c] = @intCast(@min(255, s + (d * (255 - a) + 127) / 255));
                }
            }
        }
    }

    fn sprite(self: *Canvas, gpa: std.mem.Allocator, cp: u32, cols: u32, metrics: Metrics, x: i32, y: i32, color: Rgb, alpha: u8) !void {
        const mask = try ghostty_font.drawSprite(gpa, cp, cols, metrics);
        defer mask.deinit(gpa);
        self.blendMask(x + mask.x, y + mask.y, mask.width, mask.height, mask.data, color, alpha);
    }

    /// Scale the visible part of `image` into its box, bilinearly.
    fn image(self: *Canvas, img: Image) void {
        if (img.src_width == 0 or img.src_height == 0 or img.dst_width == 0 or img.dst_height == 0) return;
        const sx: f64 = @as(f64, @floatFromInt(img.src_width)) / @as(f64, @floatFromInt(img.dst_width));
        const sy: f64 = @as(f64, @floatFromInt(img.src_height)) / @as(f64, @floatFromInt(img.dst_height));
        for (0..img.dst_height) |dy| {
            const py = self.origin_y + img.y + @as(i32, @intCast(dy));
            if (py < 0 or py >= self.height) continue;
            const fy = @max(0, (@as(f64, @floatFromInt(dy)) + 0.5) * sy - 0.5);
            for (0..img.dst_width) |dx| {
                const px = self.origin_x + img.x + @as(i32, @intCast(dx));
                if (px < 0 or px >= self.width) continue;
                const fx = @max(0, (@as(f64, @floatFromInt(dx)) + 0.5) * sx - 0.5);
                const rgba = sample(img, fx, fy);
                const a: u32 = rgba[3];
                if (a == 0) continue;
                const at = (@as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px))) * 4;
                for (0..3) |c| self.pixels[at + c] = lerp(self.pixels[at + c], rgba[c], a);
            }
        }
    }
};

fn sample(img: Image, fx: f64, fy: f64) [4]u8 {
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, img.src_width - 1);
    const y1 = @min(y0 + 1, img.src_height - 1);
    const tx = fx - @floor(fx);
    const ty = fy - @floor(fy);
    var out: [4]u8 = undefined;
    for (0..4) |c| {
        const p00: f64 = @floatFromInt(texel(img, @min(x0, img.src_width - 1), @min(y0, img.src_height - 1))[c]);
        const p10: f64 = @floatFromInt(texel(img, x1, @min(y0, img.src_height - 1))[c]);
        const p01: f64 = @floatFromInt(texel(img, @min(x0, img.src_width - 1), y1)[c]);
        const p11: f64 = @floatFromInt(texel(img, x1, y1)[c]);
        const top = p00 + (p10 - p00) * tx;
        const bottom = p01 + (p11 - p01) * tx;
        out[c] = @intFromFloat(@round(top + (bottom - top) * ty));
    }
    return out;
}

fn texel(img: Image, x: u32, y: u32) [4]u8 {
    const at = ((img.src_y + y) * img.width + img.src_x + x) * 4;
    return img.pixels[at..][0..4].*;
}

/// `under` toward `over` by `a`/255, rounded.
fn lerp(under: u8, over: u8, a: u32) u8 {
    const u: u32 = under;
    const o: u32 = over;
    return @intCast((u * (255 - a) + o * a + 127) / 255);
}

/// The picture as an RGB PNG. `scale` is the display's backing scale
/// (2 on Retina), recorded so the image pastes at its on-screen size.
pub fn encodePng(gpa: std.mem.Allocator, picture: Picture, scale: f64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], picture.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], picture.height, .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 }; // 8-bit RGB, deflate, no filter set, no interlace
    try chunk(w, "IHDR", &ihdr);

    // Pixels per metre at 72 dpi times the backing scale.
    const ppm: u32 = @intFromFloat(@round(72.0 * scale / 0.0254));
    var phys: [9]u8 = undefined;
    std.mem.writeInt(u32, phys[0..4], ppm, .big);
    std.mem.writeInt(u32, phys[4..8], ppm, .big);
    phys[8] = 1; // metres
    try chunk(w, "pHYs", &phys);

    // Each row: filter type 0, then RGB.
    const row_len = 1 + @as(usize, picture.width) * 3;
    const raw = try gpa.alloc(u8, row_len * picture.height);
    defer gpa.free(raw);
    for (0..picture.height) |y| {
        const dst = raw[y * row_len ..][0..row_len];
        dst[0] = 0;
        for (0..picture.width) |x| {
            const src = picture.pixels[(y * picture.width + x) * 4 ..][0..3];
            dst[1 + x * 3 ..][0..3].* = src.*;
        }
    }
    // The compressor needs room in its output from the start.
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer compressed.deinit();
    {
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var deflate: std.compress.flate.Compress = try .init(&compressed.writer, &window, .zlib, .default);
        try deflate.writer.writeAll(raw);
        try deflate.finish();
    }
    try chunk(w, "IDAT", compressed.written());
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}
