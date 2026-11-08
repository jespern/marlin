//! Marlin's entry to the Ghostty font code laid out beside this file (see
//! ghosttyFont in build.zig): grid metrics, OpenType table readers, and the
//! sprite font. `drawSprite` mirrors Ghostty's sprite Face.renderGlyph,
//! minus the atlas: same canvas size, padding, and draw functions.
const std = @import("std");
const z2d = @import("z2d");
const uucode = @import("uucode");
const global = @import("global.zig");
const font = @import("font/main.zig");

pub const Metrics = font.Metrics;
pub const FaceMetrics = Metrics.FaceMetrics;
pub const Sprite = font.sprite.Sprite;
pub const Glyph = @import("font/Glyph.zig");
pub const Constraint = Glyph.RenderOptions.Constraint;
/// Nerd Font icon constraints, by codepoint.
pub const getConstraint = @import("font/nerd_font_attributes.zig").getConstraint;

pub const opentype = struct {
    pub const Head = @import("font/opentype/head.zig").Head;
    pub const Hhea = @import("font/opentype/hhea.zig").Hhea;
    pub const OS2 = @import("font/opentype/os2.zig").OS2;
    pub const Post = @import("font/opentype/post.zig").Post;
};

const special = @import("font/sprite/draw/special.zig");
const Canvas = font.sprite.Canvas;

/// Ghostty's "symbol-like" codepoints (its renderer/cell.zig isSymbol, from
/// the same uucode property): constrained to fit their cells, and allowed
/// to spread into a following blank cell.
pub fn isSymbol(cp: u21) bool {
    if (cp > uucode.config.max_code_point) return false;
    return uucode.get(.is_symbol, cp);
}

/// The Unicode Emoji_Presentation property, for a codepoint's default
/// presentation (Ghostty's CodepointResolver).
pub fn isEmojiPresentation(cp: u21) bool {
    if (cp > uucode.config.max_code_point) return false;
    return uucode.get(.is_emoji_presentation, cp);
}

/// Box drawing, block elements, legacy computing, and Powerline: symbols
/// that do not stop a following symbol from spreading.
pub fn isGraphicsElement(cp: u21) bool {
    return switch (cp) {
        0x2500...0x257F, // box drawing
        0x2580...0x259F, // block elements
        0x1FB00...0x1FBFF, // symbols for legacy computing
        0x1CC00...0x1CEBF, // ... and its supplement
        0xE0B0...0xE0D7, // powerline
        => true,
        else => false,
    };
}

/// Ghostty's renderer/cell.zig constraintWidth over a row of codepoints
/// (0 for an empty cell): how many cells the glyph at `x` may use.
pub fn constraintWidth(row: []const u21, grid_width: u2, x: usize) u2 {
    if (grid_width > 1) return grid_width;
    const cp = row[x];
    if (!isSymbol(cp)) return grid_width;
    if (x == row.len - 1) return 1;
    if (x > 0 and isSymbol(row[x - 1]) and !isGraphicsElement(row[x - 1])) return 1;
    const next = row[x + 1];
    if (next == 0 or next == 0x0020 or next == 0x2002) return 2;
    return 1;
}

/// The Io the sprite canvas draws paths with.
pub fn setIo(io: std.Io) void {
    global.instance = io;
}

const DrawFnError = std.mem.Allocator.Error ||
    z2d.Path.Error ||
    z2d.painter.FillError ||
    z2d.painter.StrokeError ||
    error{MathError};

const DrawFn = fn (cp: u32, canvas: *Canvas, width: u32, height: u32, metrics: Metrics) DrawFnError!void;

const Range = struct { min: u32, max: u32, draw: DrawFn };

/// Every `draw<CP>` / `draw<MIN>_<MAX>` function, as Ghostty's sprite Face
/// collects them.
const ranges: []const Range = ranges: {
    @setEvalBranchQuota(1_000_000);
    const structs = [_]type{
        @import("font/sprite/draw/block.zig"),
        @import("font/sprite/draw/box.zig"),
        @import("font/sprite/draw/braille.zig"),
        @import("font/sprite/draw/branch.zig"),
        @import("font/sprite/draw/geometric_shapes.zig"),
        @import("font/sprite/draw/powerline.zig"),
        @import("font/sprite/draw/symbols_for_legacy_computing.zig"),
        @import("font/sprite/draw/symbols_for_legacy_computing_supplement.zig"),
    };
    var count = 0;
    for (structs) |s| for (@typeInfo(s).@"struct".decl_names) |decl| {
        if (std.mem.startsWith(u8, decl, "draw")) count += 1;
    };
    var r: [count]Range = undefined;
    var i = 0;
    for (structs) |s| for (@typeInfo(s).@"struct".decl_names) |decl| {
        if (!std.mem.startsWith(u8, decl, "draw")) continue;
        const sep = std.mem.indexOfScalar(u8, decl, '_') orelse decl.len;
        const min = std.fmt.parseInt(u21, decl[4..sep], 16) catch unreachable;
        const max = if (sep == decl.len) min else std.fmt.parseInt(u21, decl[sep + 1 ..], 16) catch unreachable;
        r[i] = .{ .min = min, .max = max, .draw = @field(s, decl) };
        i += 1;
    };
    const final = r;
    break :ranges &final;
};

fn drawFn(cp: u32) ?*const DrawFn {
    if (cp >= Sprite.start) switch (@as(Sprite, @fromBackingInt(cp))) {
        inline else => |sprite| return @field(special, @tagName(sprite)),
    };
    inline for (ranges) |range| if (cp >= range.min and cp <= range.max) return range.draw;
    return null;
}

/// True when Ghostty draws `cp` itself instead of taking it from a font.
pub fn hasSprite(cp: u32) bool {
    return drawFn(cp) != null;
}

/// Coverage of one sprite: `width` x `height` bytes, placed with its top
/// left at (`x`, `y`) relative to the top left of its cell.
pub const Mask = struct {
    data: []u8,
    width: u32,
    height: u32,
    x: i32,
    y: i32,

    pub fn deinit(self: Mask, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
    }
};

/// Draw sprite `cp` (a box/block character, or a `Sprite` such as an
/// underline or cursor) for a glyph `cols` cells wide.
pub fn drawSprite(gpa: std.mem.Allocator, cp: u32, cols: u32, metrics: Metrics) !Mask {
    const draw = drawFn(cp) orelse return error.NoSprite;
    const width = metrics.cell_width * @max(cols, 1);
    const height = switch (cp) {
        @backingInt(Sprite.cursor_rect),
        @backingInt(Sprite.cursor_hollow_rect),
        @backingInt(Sprite.cursor_bar),
        => metrics.cursor_height,
        else => metrics.cell_height,
    };
    const padding_x = width / 4;
    const padding_y = height / 4;
    var canvas = try Canvas.init(gpa, width, height, padding_x, padding_y);
    defer canvas.deinit();
    try draw(cp, &canvas, width, height, metrics);
    canvas.clearClippingRegions();
    const pixels = std.mem.sliceAsBytes(canvas.sfc.image_surface_alpha8.buf);
    return .{
        .data = try gpa.dupe(u8, pixels),
        .width = width + 2 * padding_x,
        .height = height + 2 * padding_y,
        .x = -@as(i32, @intCast(padding_x)),
        .y = -@as(i32, @intCast(padding_y)) +
            @divTrunc(@as(i32, @intCast(metrics.cell_height)) - @as(i32, @intCast(height)), 2),
    };
}
