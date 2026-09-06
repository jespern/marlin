//! Bitmap text from the original's three font textures (16, 12 and 8 px),
//! plus the screen anchors the HUD lays itself out with. Glyph metrics
//! describe where each character sits in the font texture.

const std = @import("std");
const math = @import("math.zig");
const render = @import("render.zig");
const scene = @import("scene.zig");
const assets_mod = @import("assets.zig");
const Vec2i = math.Vec2i;
const Rgba = math.Rgba;

pub const Size = enum(u8) { px16, px12, px8 };

pub const color_accent = Rgba.init(123, 98, 12, 255);
pub const color_default = Rgba.init(128, 128, 128, 255);

pub const Anchor = struct {
    pub const left: u8 = 1 << 0;
    pub const center: u8 = 1 << 1;
    pub const right: u8 = 1 << 2;
    pub const top: u8 = 1 << 3;
    pub const middle: u8 = 1 << 4;
    pub const bottom: u8 = 1 << 5;
};

const Glyph = struct { x: u16, y: u16, width: u16 };

/// Character cells: A-Z, 0-9, then ":" and "." (written as 'e' and 'f').
const CharSet = struct {
    height: u16,
    glyphs: [40]Glyph,
};

fn g(x: u16, y: u16, w: u16) Glyph {
    return .{ .x = x, .y = y, .width = w };
}

const char_sets = [3]CharSet{
    .{ .height = 16, .glyphs = .{
        g(0, 0, 25),    g(25, 0, 24),   g(49, 0, 17),   g(66, 0, 24),   g(90, 0, 24),   g(114, 0, 17),  g(131, 0, 25),  g(156, 0, 18),
        g(174, 0, 7),   g(181, 0, 17),  g(0, 16, 17),   g(17, 16, 17),  g(34, 16, 28),  g(62, 16, 17),  g(79, 16, 24),  g(103, 16, 24),
        g(127, 16, 26), g(153, 16, 24), g(177, 16, 18), g(195, 16, 17), g(0, 32, 17),   g(17, 32, 17),  g(34, 32, 29),  g(63, 32, 24),
        g(87, 32, 17),  g(104, 32, 18), g(122, 32, 24), g(146, 32, 10), g(156, 32, 18), g(174, 32, 17), g(191, 32, 18), g(0, 48, 18),
        g(18, 48, 18),  g(36, 48, 18),  g(54, 48, 22),  g(76, 48, 25),  g(101, 48, 7),  g(108, 48, 7),  g(198, 0, 0),   g(198, 0, 0),
    } },
    .{ .height = 12, .glyphs = .{
        g(0, 0, 19),    g(19, 0, 19),   g(38, 0, 14),   g(52, 0, 19),   g(71, 0, 19),   g(90, 0, 13),   g(103, 0, 19),  g(122, 0, 14),
        g(136, 0, 6),   g(142, 0, 13),  g(155, 0, 14),  g(169, 0, 14),  g(0, 12, 22),   g(22, 12, 14),  g(36, 12, 19),  g(55, 12, 18),
        g(73, 12, 20),  g(93, 12, 19),  g(112, 12, 15), g(127, 12, 14), g(141, 12, 13), g(154, 12, 13), g(167, 12, 22), g(0, 24, 19),
        g(19, 24, 13),  g(32, 24, 14),  g(46, 24, 19),  g(65, 24, 8),   g(73, 24, 15),  g(88, 24, 13),  g(101, 24, 14), g(115, 24, 15),
        g(130, 24, 14), g(144, 24, 15), g(159, 24, 18), g(177, 24, 19), g(196, 24, 5),  g(201, 24, 5),  g(183, 0, 0),   g(183, 0, 0),
    } },
    .{ .height = 8, .glyphs = .{
        g(0, 0, 13),   g(13, 0, 13),  g(26, 0, 10),  g(36, 0, 13),  g(49, 0, 13),  g(62, 0, 9),   g(71, 0, 13),  g(84, 0, 10),
        g(94, 0, 4),   g(98, 0, 9),   g(107, 0, 10), g(117, 0, 10), g(127, 0, 16), g(143, 0, 10), g(153, 0, 13), g(166, 0, 13),
        g(179, 0, 14), g(0, 8, 13),   g(13, 8, 10),  g(23, 8, 9),   g(32, 8, 9),   g(41, 8, 9),   g(50, 8, 16),  g(66, 8, 14),
        g(80, 8, 9),   g(89, 8, 10),  g(99, 8, 13),  g(112, 8, 6),  g(118, 8, 11), g(129, 8, 10), g(139, 8, 10), g(149, 8, 11),
        g(160, 8, 10), g(170, 8, 10), g(180, 8, 12), g(192, 8, 14), g(206, 8, 4),  g(210, 8, 4),  g(193, 0, 0),  g(193, 0, 0),
    } },
};

pub const Icon = enum(u8) { hand, confirm, cancel, end, del, star };

pub const Ui = struct {
    font_textures: [3]u16,
    icon_textures: [6]u16,
    /// Integer UI scale; 1 at the PSX-native 240p.
    scale: i32 = 1,
    screen: Vec2i,

    pub fn load(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, r: *render.Renderer) !Ui {
        const list = try scene.loadCompressedTextures(gpa, assets, r, "wipeout/textures", "drfonts.cmp");
        if (list.len < 10) return error.MissingFonts;
        return .{
            .font_textures = .{ list.start, list.start + 1, list.start + 2 },
            .icon_textures = .{ list.start + 3, list.start + 5, list.start + 6, list.start + 7, list.start + 8, list.start + 9 },
            .screen = Vec2i.init(@intCast(r.width), @intCast(r.height)),
        };
    }

    pub fn scaled(self: *const Ui, v: Vec2i) Vec2i {
        return Vec2i.init(v.x * self.scale, v.y * self.scale);
    }

    /// Position relative to a screen edge or centre, offset in UI units.
    pub fn pos(self: *const Ui, anchor: u8, offset: Vec2i) Vec2i {
        var p = Vec2i.init(0, 0);
        if (anchor & Anchor.left != 0) {
            p.x = offset.x * self.scale;
        } else if (anchor & Anchor.center != 0) {
            p.x = @divTrunc(self.screen.x, 2) + offset.x * self.scale;
        } else if (anchor & Anchor.right != 0) {
            p.x = self.screen.x + offset.x * self.scale;
        }
        if (anchor & Anchor.top != 0) {
            p.y = offset.y * self.scale;
        } else if (anchor & Anchor.middle != 0) {
            p.y = @divTrunc(self.screen.y, 2) + offset.y * self.scale;
        } else if (anchor & Anchor.bottom != 0) {
            p.y = self.screen.y + offset.y * self.scale;
        }
        return p;
    }

    fn glyphIndex(c: u8) ?usize {
        if (c >= 'A' and c <= 'Z') return c - 'A';
        if (c >= '0' and c <= '9') return c - '0' + 26;
        if (c == ':') return 36;
        if (c == '.') return 37;
        return null;
    }

    pub fn charWidth(c: u8, size: Size) i32 {
        if (c == ' ') return 8;
        const index = glyphIndex(c) orelse return 0;
        return char_sets[@intFromEnum(size)].glyphs[index].width;
    }

    pub fn textWidth(text: []const u8, size: Size) i32 {
        var width: i32 = 0;
        for (text) |c| width += charWidth(c, size);
        return width;
    }

    pub fn drawText(self: *const Ui, r: *render.Renderer, text: []const u8, at: Vec2i, size: Size, color: Rgba) void {
        const set = &char_sets[@intFromEnum(size)];
        const texture = self.font_textures[@intFromEnum(size)];
        var p = at;
        for (text) |c| {
            if (c == ' ') {
                p.x += 8 * self.scale;
                continue;
            }
            const index = glyphIndex(c) orelse continue;
            const glyph = set.glyphs[index];
            const cell = Vec2i.init(glyph.width, set.height);
            r.push2dTile(p, Vec2i.init(glyph.x, glyph.y), cell, self.scaled(cell), color, texture);
            p.x += @as(i32, glyph.width) * self.scale;
        }
    }

    pub fn drawTextCentered(self: *const Ui, r: *render.Renderer, text: []const u8, at: Vec2i, size: Size, color: Rgba) void {
        var p = at;
        p.x -= @divTrunc(textWidth(text, size) * self.scale, 2);
        self.drawText(r, text, p, size, color);
    }

    pub fn drawNumber(self: *const Ui, r: *render.Renderer, num: i64, at: Vec2i, size: Size, color: Rgba) void {
        var buf: [20]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{@max(num, 0)}) catch return;
        self.drawText(r, text, at, size, color);
    }

    /// mm:ss.t as the original formats lap times, digits assembled by hand
    /// so the zero padding never depends on a format spec.
    pub fn drawTime(self: *const Ui, r: *render.Renderer, seconds: f32, at: Vec2i, size: Size, color: Rgba) void {
        const msec: i64 = @intFromFloat(@max(seconds, 0) * 1000.0);
        const tenths: u8 = @intCast(@mod(@divTrunc(msec, 100), 10));
        const secs: u8 = @intCast(@mod(@divTrunc(msec, 1000), 60));
        const mins: u8 = @intCast(@mod(@divTrunc(msec, 60 * 1000), 100));
        const text = [7]u8{
            '0' + mins / 10, '0' + mins % 10, ':',
            '0' + secs / 10, '0' + secs % 10, '.',
            '0' + tenths,
        };
        self.drawText(r, &text, at, size, color);
    }

    pub fn drawImage(self: *const Ui, r: *render.Renderer, at: Vec2i, texture: u16) void {
        r.push2d(at, self.scaled(r.textureSize(texture)), Rgba.white, texture);
    }

    pub fn drawIcon(self: *const Ui, r: *render.Renderer, icon: Icon, at: Vec2i, color: Rgba) void {
        const texture = self.icon_textures[@intFromEnum(icon)];
        r.push2d(at, self.scaled(r.textureSize(texture)), color, texture);
    }
};

test "text width counts glyphs and spaces" {
    try std.testing.expectEqual(@as(i32, 25 + 8 + 24), Ui.textWidth("A B", .px16));
    try std.testing.expectEqual(@as(i32, 7), Ui.charWidth(':', .px16));
}
