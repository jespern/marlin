//! The text half of a screenshot on macOS, done the way Ghostty does it so
//! glyphs land on the same pixels: its font collection (font-family, then
//! its embedded JetBrains Mono as fallback), codepoint-to-font resolution
//! and fallback discovery, CoreText shaping, and glyph rasterization.
//! Ported from Ghostty's font/face/coretext.zig, font/shaper/coretext.zig,
//! font/shaper/run.zig, font/discovery.zig, font/CodepointResolver.zig,
//! and font/Collection.zig; each piece names its source.
const std = @import("std");
const ghostty_font = @import("ghostty_font");
const raster = @import("raster.zig");

const Metrics = ghostty_font.Metrics;
const FaceMetrics = ghostty_font.FaceMetrics;
const opentype = ghostty_font.opentype;

/// Ghostty's config keys that change text rendering.
pub const Config = struct {
    /// font-family (and per-style overrides); empty: the embedded font.
    family: []const []const u8 = &.{},
    family_bold: []const []const u8 = &.{},
    family_italic: []const []const u8 = &.{},
    family_bold_italic: []const []const u8 = &.{},
    /// font-size, in points.
    size: f64 = 13,
    /// font-feature, as written ("-calt", "ss01", "liga=0").
    features: []const []const u8 = &.{},
    font_thicken: bool = false,
    font_thicken_strength: u8 = 255,
    /// Ghostty's built-in JetBrains Mono (variable, upright and italic),
    /// which it uses when font-family is unset and as a fallback after it.
    /// Fetched on demand rather than carried in the binary; without it,
    /// Menlo stands in and the grid is unlikely to match.
    default_font: ?DefaultFont = null,
};

pub const DefaultFont = struct { regular: []const u8, italic: []const u8 };

const Style = enum { regular, bold, italic, bold_italic };

pub const Face = struct {
    font: Ref,
    /// Ghostty's Collection.Entry.fallback: the embedded and discovered
    /// faces, which must match a codepoint's default presentation.
    fallback: bool,
    /// Line width of a synthetic bold stroke.
    synthetic_bold: ?f64 = null,
    /// Bitmap color glyphs (sbix): emoji presentation.
    color: bool,
    metrics: FaceMetrics,
    /// `font` with the feature settings applied, for shaping.
    shaping: Ref,

    fn deinit(self: Face) void {
        release(self.font);
        release(self.shaping);
    }

    fn glyphIndex(self: Face, cp: u21) ?u16 {
        var chars: [2]u16 = undefined;
        const len = utf16(cp, &chars);
        var glyphs = [2]u16{ 0, 0 };
        if (!CTFontGetGlyphsForCharacters(self.font, &chars, &glyphs, @intCast(len))) return null;
        return glyphs[0];
    }
};

pub const Fonts = struct {
    gpa: std.mem.Allocator,
    config: Config,
    /// Faces per style, in Ghostty's collection order.
    faces: [4]std.ArrayList(Face) = @splat(.empty),
    /// Fallbacks found by discovery, keyed by the codepoint they were for.
    discovered: std.AutoHashMapUnmanaged(u21, ?usize) = .empty,
    metrics: Metrics,
    /// The primary face's size in points, and the display scale.
    points: f64,
    scale: f64,
    /// Whether the grid computed from the font matched the terminal's
    /// cells; if not, the cells were forced to the terminal's size.
    exact_grid: bool,
    features: Ref,
    typesetter_options: Ref,

    /// Load the fonts Ghostty would for `config` and choose the display
    /// scale whose grid is the terminal's: `cell_width` x `cell_height`.
    pub fn init(gpa: std.mem.Allocator, config: Config, cell_width: u32, cell_height: u32) !Fonts {
        const features = try featuresDict(gpa, config.features);
        errdefer release(features);
        const zero: i32 = 0;
        const zero_num = CFNumberCreate(null, kCFNumberSInt32Type, &zero) orelse return error.CoreText;
        defer release(zero_num);
        const typesetter_options = try dictionary(&.{kCTTypesetterOptionForcedEmbeddingLevel}, &.{zero_num});
        errdefer release(typesetter_options);

        var self: Fonts = .{
            .gpa = gpa,
            .config = config,
            .metrics = undefined,
            .points = config.size,
            .scale = 2,
            .exact_grid = false,
            .features = features,
            .typesetter_options = typesetter_options,
        };
        errdefer self.deinit();

        // Ghostty sizes fonts in points at the display's scale; the
        // terminal reports only cell pixels, so take the scale that gives
        // exactly those cells, as Ghostty's grid would be.
        var best: ?struct { scale: f64, metrics: Metrics, err: u32 } = null;
        var loaded: f64 = 0;
        for ([_]f64{ 2, 1, 3, 1.5, 2.5 }) |scale| {
            self.clearFaces();
            try self.loadFaces(config.size * scale);
            loaded = scale;
            const m = Metrics.calc(self.faces[0].items[0].metrics);
            const err = absDiff(m.cell_width, cell_width) + absDiff(m.cell_height, cell_height);
            if (best == null or err < best.?.err) best = .{ .scale = scale, .metrics = m, .err = err };
            if (err == 0) break;
        }
        const chosen = best.?;
        if (chosen.scale != loaded) {
            self.clearFaces();
            try self.loadFaces(config.size * chosen.scale);
        }
        self.scale = chosen.scale;
        self.metrics = chosen.metrics;
        self.exact_grid = chosen.err == 0;
        if (!self.exact_grid) {
            // adjust-cell-width/height, or a terminal other than Ghostty:
            // Ghostty's own adjustment keeps the baseline centered.
            var mods: Metrics.ModifierSet = .{};
            defer mods.deinit(gpa);
            try mods.put(gpa, .cell_width, .{ .absolute = @as(i32, @intCast(cell_width)) - @as(i32, @intCast(self.metrics.cell_width)) });
            try mods.put(gpa, .cell_height, .{ .absolute = @as(i32, @intCast(cell_height)) - @as(i32, @intCast(self.metrics.cell_height)) });
            self.metrics.apply(mods);
        }
        return self;
    }

    pub fn deinit(self: *Fonts) void {
        self.clearFaces();
        for (&self.faces) |*list| list.deinit(self.gpa);
        self.discovered.deinit(self.gpa);
        release(self.features);
        release(self.typesetter_options);
    }

    fn clearFaces(self: *Fonts) void {
        for (&self.faces) |*list| {
            for (list.items) |entry| entry.deinit();
            list.clearRetainingCapacity();
        }
        self.discovered.clearRetainingCapacity();
    }

    /// Ghostty's SharedGridSet.collection: configured families per style,
    /// synthetic styles for what they lack, then the embedded fallbacks.
    fn loadFaces(self: *Fonts, px: f64) !void {
        const per_style = [4][]const []const u8{
            self.config.family,
            if (self.config.family_bold.len > 0) self.config.family_bold else self.config.family,
            if (self.config.family_italic.len > 0) self.config.family_italic else self.config.family,
            if (self.config.family_bold_italic.len > 0) self.config.family_bold_italic else self.config.family,
        };
        for (per_style, 0..) |families, i| {
            const style: Style = @fromBackingInt(@intCast(i));
            for (families) |family| {
                const desc = try discoverFirst(.{
                    .family = family,
                    .size = self.config.size,
                    .bold = style == .bold or style == .bold_italic,
                    .italic = style == .italic or style == .bold_italic,
                }) orelse continue;
                defer release(desc);
                const font = CTFontCreateWithFontDescriptor(desc, px, null) orelse continue;
                try self.addFace(style, font, false, null);
            }
        }
        try self.completeStyles();

        const default = self.config.default_font orelse {
            if (self.faces[0].items.len == 0) try self.loadStandIn(px);
            return;
        };
        const embedded = [4]struct { []const u8, ?f64 }{
            .{ default.regular, null },
            .{ default.regular, 700 },
            .{ default.italic, null },
            .{ default.italic, 700 },
        };
        for (embedded, 0..) |entry, i| {
            var font = try fontFromData(entry[0], px);
            if (entry[1]) |weight| {
                const weighted = try withWeight(font, weight);
                release(font);
                font = weighted;
            }
            try self.addFace(@fromBackingInt(@intCast(i)), font, true, null);
        }
    }

    /// No configured family and no default font: Menlo, in every style.
    fn loadStandIn(self: *Fonts, px: f64) !void {
        const desc = try discoverFirst(.{ .family = "Menlo", .size = self.config.size }) orelse return error.NoFont;
        defer release(desc);
        const font = CTFontCreateWithFontDescriptor(desc, px, null) orelse return error.NoFont;
        try self.addFace(.regular, font, false, null);
        try self.completeStyles();
    }

    /// Ghostty's Collection.completeStyles: a style with no face gets the
    /// first regular text face, made bold or italic synthetically.
    fn completeStyles(self: *Fonts) !void {
        if (self.faces[0].items.len == 0) return;
        const regular = self.faces[0].items[0];
        if (self.faces[@backingInt(Style.italic)].items.len == 0) {
            const font = CTFontCreateCopyWithAttributes(regular.font, 0, &italic_skew, null) orelse return error.CoreText;
            try self.addFace(.italic, font, false, null);
        }
        if (self.faces[@backingInt(Style.bold)].items.len == 0) {
            const font = CTFontCreateCopyWithAttributes(regular.font, 0, null, null) orelse return error.CoreText;
            try self.addFace(.bold, font, false, @max(self.config.size / 14.0, 1));
        }
        if (self.faces[@backingInt(Style.bold_italic)].items.len == 0) {
            const italic = self.faces[@backingInt(Style.italic)].items[0];
            const font = CTFontCreateCopyWithAttributes(italic.font, 0, null, null) orelse return error.CoreText;
            try self.addFace(.bold_italic, font, false, @max(self.config.size / 14.0, 1));
        }
    }

    /// Takes ownership of `font`.
    fn addFace(self: *Fonts, style: Style, font: Ref, fallback: bool, synthetic_bold: ?f64) !void {
        errdefer release(font);
        const shaping = try self.withFeatures(font);
        errdefer release(shaping);
        try self.faces[@backingInt(style)].append(self.gpa, .{
            .font = font,
            .fallback = fallback,
            .synthetic_bold = synthetic_bold,
            .color = isColorFont(font),
            .metrics = faceMetrics(font),
            .shaping = shaping,
        });
    }

    /// `font` with the feature settings, as Ghostty's shaper copies it.
    fn withFeatures(self: *Fonts, font: Ref) !Ref {
        const desc = CTFontDescriptorCreateWithAttributes(self.features) orelse return error.CoreText;
        defer release(desc);
        return CTFontCreateCopyWithAttributes(font, 0, null, desc) orelse error.CoreText;
    }

    pub fn text(self: *Fonts) raster.Text {
        return .{ .ctx = self, .shapeRow = shapeRowOpaque };
    }

    fn shapeRowOpaque(ctx: *anyopaque, arena: std.mem.Allocator, row: []const raster.Cell, cursor_col: ?u16) anyerror![]const raster.Glyph {
        const self: *Fonts = @ptrCast(@alignCast(ctx));
        return self.shapeRow(arena, row, cursor_col);
    }

    /// Where a face lives: a style list and index, or a discovered one.
    const FaceRef = struct { style: Style, index: usize };

    fn face(self: *Fonts, ref: FaceRef) *Face {
        return &self.faces[@backingInt(ref.style)].items[ref.index];
    }

    /// Ghostty's CodepointResolver.getIndex (minus overrides and sprites,
    /// which the caller handles).
    fn resolve(self: *Fonts, cp: u21, style: Style, presentation: ?Presentation) !?FaceRef {
        const mode: PresentationMode = if (presentation) |p| .{ .explicit = p } else .{
            .default = if (ghostty_font.isEmojiPresentation(cp)) .emoji else .text,
        };
        for (self.faces[@backingInt(style)].items, 0..) |candidate, i| {
            if (hasCodepoint(candidate, cp, mode)) return .{ .style = style, .index = i };
        }
        if (style != .regular) return self.resolve(cp, .regular, presentation);
        if (try self.discover(cp, mode)) |ref| return ref;
        // Nothing has the wanted presentation: any will do.
        if (mode == .any) return null;
        for (self.faces[0].items, 0..) |candidate, i| {
            if (hasCodepoint(candidate, cp, .any)) return .{ .style = .regular, .index = i };
        }
        return null;
    }

    /// Ghostty's fallback discovery for regular style, the found face added
    /// to the regular list with the ic_width size adjustment.
    fn discover(self: *Fonts, cp: u21, mode: PresentationMode) !?FaceRef {
        if (self.discovered.get(cp)) |known| return if (known) |i| .{ .style = .regular, .index = i } else null;
        const found = try self.discoverFace(cp, mode);
        try self.discovered.put(self.gpa, cp, found);
        return if (found) |i| .{ .style = .regular, .index = i } else null;
    }

    fn discoverFace(self: *Fonts, cp: u21, mode: PresentationMode) !?usize {
        const primary = self.faces[0].items[0];
        const px = CTFontGetSize(primary.font);
        const points = self.config.size;
        var candidates: std.ArrayList(Ref) = .empty;
        defer {
            for (candidates.items) |d| release(d);
            candidates.deinit(self.gpa);
        }
        // Han goes straight to CoreText's own choice.
        if (!(cp >= 0x4E00 and cp <= 0x9FFF)) {
            try discoverAll(self.gpa, .{ .codepoint = cp, .size = points }, &candidates);
        }
        if (candidates.items.len == 0) {
            if (try codepointDescriptor(primary.font, cp)) |desc| try candidates.append(self.gpa, desc);
        }
        for (candidates.items) |desc| {
            const probe = CTFontCreateWithFontDescriptor(desc, 12, null) orelse continue;
            const probe_metrics = faceMetrics(probe);
            release(probe);
            const scaled = px * scaleFactor(primary.metrics, probe_metrics);
            const font = CTFontCreateWithFontDescriptor(desc, scaled, null) orelse continue;
            var candidate: Face = .{
                .font = font,
                .fallback = true,
                .color = isColorFont(font),
                .metrics = faceMetrics(font),
                .shaping = font,
            };
            if (!hasCodepoint(candidate, cp, mode)) {
                release(font);
                continue;
            }
            candidate.shaping = self.withFeatures(font) catch {
                release(font);
                continue;
            };
            try self.faces[0].append(self.gpa, candidate);
            return self.faces[0].items.len - 1;
        }
        return null;
    }

    /// One shaped run: consecutive cells sharing style and face.
    const Run = struct { start: usize, end: usize, face: FaceRef };

    /// Ghostty's RunIterator, then its CoreText Shaper.shape per run, then
    /// Face.renderGlyph per glyph.
    pub fn shapeRow(self: *Fonts, arena: std.mem.Allocator, row: []const raster.Cell, cursor_col: ?u16) ![]const raster.Glyph {
        var glyphs: std.ArrayList(raster.Glyph) = .empty;
        const codepoints = try arena.alloc(u21, row.len);
        for (row, codepoints) |cell, *cp| cp.* = firstCodepoint(cell.text) orelse 0;

        // Shaping stops after the last non-empty cell.
        var max: usize = 0;
        for (row, 0..) |cell, i| if (cell.text.len > 0) {
            max = i + 1;
        };

        var i: usize = 0;
        while (i < max) {
            const run_style = styleOf(row[i]);
            var j = i;
            var run_face: ?FaceRef = null;
            var sprite_run = false;
            while (j < max) : (j += 1) {
                const cell = row[j];
                if (cell.width == 0) continue; // the tail of a wide cell
                if (j > i) {
                    // Ghostty keeps "fl", "fi", and "st" apart.
                    const prev = codepoints[j - 1];
                    const cp = codepoints[j];
                    if ((prev == 'f' and (cp == 'l' or cp == 'i')) or (prev == 's' and cp == 't')) break;
                    if (!sameRunStyle(row[i], cell)) break;
                }
                if (cursor_col) |c| {
                    if (i == c and j == i + 1) break;
                    if (i < c and j == c) break;
                }
                const is_sprite = raster.spriteCodepoint(cell.text) != null;
                if (j == i) sprite_run = is_sprite;
                if (is_sprite != sprite_run) break;
                if (is_sprite) continue;
                const ref = try self.cellFace(cell, run_style);
                if (j == i) {
                    run_face = ref;
                } else if (!std.meta.eql(run_face, ref)) break;
            }
            if (j == i) j = i + 1;
            if (!sprite_run) if (run_face) |ref| {
                try self.shapeRun(arena, row, codepoints, i, j, ref, &glyphs);
            };
            i = j;
        }
        return glyphs.items;
    }

    fn cellFace(self: *Fonts, cell: raster.Cell, style: Style) !?FaceRef {
        if (cell.text.len == 0) return self.resolve(' ', style, null);
        const view = std.unicode.Utf8View.init(cell.text) catch return self.resolve(0xFFFD, style, null);
        var it = view.iterator();
        const first = it.nextCodepoint() orelse return self.resolve(' ', style, null);
        var presentation: ?Presentation = null;
        while (it.nextCodepoint()) |cp| {
            if (cp == 0xFE0E) presentation = .text;
            if (cp == 0xFE0F) presentation = .emoji;
        }
        if (try self.resolve(first, style, presentation)) |ref| return ref;
        if (try self.resolve(0xFFFD, style, presentation)) |ref| return ref;
        return self.resolve(' ', style, presentation);
    }

    /// Ghostty's Shaper.shape: a CTTypesetter line over the run's text,
    /// each glyph assigned to its cluster's cell with the offset from
    /// that cell's start.
    fn shapeRun(self: *Fonts, arena: std.mem.Allocator, row: []const raster.Cell, codepoints: []const u21, start: usize, end: usize, ref: FaceRef, out: *std.ArrayList(raster.Glyph)) !void {
        const f = self.face(ref).*;
        var units: std.ArrayList(u16) = .empty;
        var clusters: std.ArrayList(u32) = .empty;
        for (row[start..end], start..) |cell, col| {
            if (cell.width == 0) continue;
            const grapheme = if (cell.text.len == 0) " " else cell.text;
            const view = std.unicode.Utf8View.init(grapheme) catch continue;
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp == 0xFE0E or cp == 0xFE0F) continue;
                var buf: [2]u16 = undefined;
                const n = utf16(cp, &buf);
                for (buf[0..n]) |unit| {
                    try units.append(arena, unit);
                    try clusters.append(arena, @intCast(col - start));
                }
            }
        }
        if (units.items.len == 0) return;

        const str = CFStringCreateWithCharacters(null, units.items.ptr, @intCast(units.items.len)) orelse return error.CoreText;
        defer release(str);
        const attrs = try dictionary(&.{kCTFontAttributeName}, &.{f.shaping});
        defer release(attrs);
        const attributed = CFAttributedStringCreate(null, str, attrs) orelse return error.CoreText;
        defer release(attributed);
        const typesetter = CTTypesetterCreateWithAttributedStringAndOptions(attributed, self.typesetter_options) orelse return error.CoreText;
        defer release(typesetter);
        const line = CTTypesetterCreateLine(typesetter, .{ .location = 0, .length = 0 }) orelse return error.CoreText;
        defer release(line);

        const Offset = struct { cluster: u32 = 0, x: f64 = 0 };
        var run_offset: Offset = .{};
        var cell_offset: Offset = .{};
        const runs = CTLineGetGlyphRuns(line);
        for (0..@intCast(CFArrayGetCount(runs))) |r| {
            const ctrun = CFArrayGetValueAtIndex(runs, @intCast(r)).?;
            const n: usize = @intCast(CTRunGetGlyphCount(ctrun));
            const ids = try arena.alloc(u16, n);
            const advances = try arena.alloc(CGSize, n);
            const positions = try arena.alloc(CGPoint, n);
            const indices = try arena.alloc(CFIndex, n);
            const all: CFRange = .{ .location = 0, .length = 0 };
            CTRunGetGlyphs(ctrun, all, ids.ptr);
            CTRunGetAdvances(ctrun, all, advances.ptr);
            CTRunGetPositions(ctrun, all, positions.ptr);
            CTRunGetStringIndices(ctrun, all, indices.ptr);
            for (ids, advances, positions, indices) |glyph, advance, position, index| {
                const unit: usize = @intCast(index);
                const cluster = clusters.items[unit];
                if (cell_offset.cluster != cluster) {
                    const after_current_or_next = cluster <= run_offset.cluster;
                    const first_in_cluster = unit == 0 or clusters.items[unit - 1] != cluster;
                    if (first_in_cluster and !after_current_or_next) {
                        cell_offset = .{ .cluster = cluster, .x = run_offset.x };
                    }
                }
                const x_offset: i32 = @intFromFloat(@round(position.x - cell_offset.x));
                const y_offset: i32 = @intFromFloat(@round(position.y));
                run_offset.x += advance.width;
                run_offset.cluster = @max(run_offset.cluster, cluster);

                const col = start + cell_offset.cluster;
                const cp = codepoints[col];
                const constraint: ghostty_font.Constraint = ghostty_font.getConstraint(cp) orelse
                    if (ghostty_font.isSymbol(cp)) .{ .size = .fit } else .none;
                const rendered = try self.renderGlyph(arena, f, glyph, constraint, ghostty_font.constraintWidth(codepoints, @max(row[col].width, 1), col)) orelse continue;
                try out.append(arena, .{
                    .col = @intCast(col),
                    .data = rendered.data,
                    .width = rendered.width,
                    .height = rendered.height,
                    .x = rendered.offset_x + x_offset,
                    // Bearings count up from the cell's bottom.
                    .y = @as(i32, @intCast(self.metrics.cell_height)) - (rendered.offset_y + y_offset),
                    .color = rendered.color,
                });
            }
        }
    }

    const Rendered = struct { data: []u8, width: u32, height: u32, offset_x: i32, offset_y: i32, color: bool };

    /// Ghostty's coretext Face.renderGlyph, into a buffer instead of an atlas.
    fn renderGlyph(self: *Fonts, arena: std.mem.Allocator, f: Face, glyph: u16, constraint: ghostty_font.Constraint, constraint_width: u2) !?Rendered {
        var glyphs = [1]u16{glyph};
        var rect = CTFontGetBoundingRectsForGlyphs(f.font, kCTFontOrientationHorizontal, &glyphs, null, 1);
        const sbix = f.color;
        if (!sbix) if (f.synthetic_bold) |line_width| {
            rect.size.width += line_width;
            rect.size.height += line_width;
            rect.origin.x -= line_width / 2;
            rect.origin.y -= line_width / 2;
        };
        if (rect.size.width < 0.25 or rect.size.height < 0.25) return null;

        const metrics = self.metrics;
        const cell_width: f64 = @floatFromInt(metrics.cell_width);
        const cell_height: f64 = @floatFromInt(metrics.cell_height);
        const cell_baseline: f64 = @floatFromInt(metrics.cell_baseline);
        const size = constraint.constrain(.{
            .width = rect.size.width,
            .height = rect.size.height,
            .x = rect.origin.x,
            .y = rect.origin.y + cell_baseline,
        }, metrics, constraint_width);
        var x = size.x;
        var y = size.y;
        var width = size.width;
        var height = size.height;
        if (constraint.size != .stretch) {
            const dx = (cell_width - metrics.face_width) / 2;
            x += dx;
            if (dx < 0) x -= @trunc(dx);
        }
        if (sbix) {
            width = cell_width - @round(cell_width - width - x) - @round(x);
            height = cell_height - @round(cell_height - height - y) - @round(y);
            x = @round(x);
            y = @round(y);
        }
        const padding: u32 = if (self.config.font_thicken and !sbix) 1 else 0;
        const px_x = @as(i32, @intFromFloat(@floor(x))) - @as(i32, @intCast(padding));
        const px_y = @as(i32, @intFromFloat(@floor(y))) - @as(i32, @intCast(padding));
        const frac_x = x - @floor(x);
        const frac_y = y - @floor(y);
        const px_width = @as(u32, @intFromFloat(@ceil(width + frac_x))) + 2 * padding;
        const px_height = @as(u32, @intFromFloat(@ceil(height + frac_y))) + 2 * padding;
        if (px_width == 0 or px_height == 0) return null;

        const depth: u32 = if (sbix) 4 else 1;
        const buf = try arena.alloc(u8, px_width * px_height * depth);
        @memset(buf, 0);
        const space = CGColorSpaceCreateWithName(if (sbix) kCGColorSpaceDisplayP3 else kCGColorSpaceLinearGray) orelse return error.CoreText;
        defer CGColorSpaceRelease(space);
        const info: u32 = if (sbix) kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst else kCGImageAlphaOnly;
        const ctx = CGBitmapContextCreate(buf.ptr, px_width, px_height, 8, px_width * depth, space, info) orelse return error.CoreText;
        defer CGContextRelease(ctx);
        if (sbix) CGContextSetRGBFillColor(ctx, 0, 0, 0, 0) else CGContextSetGrayFillColor(ctx, 0, 0);
        CGContextFillRect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(px_width), .height = @floatFromInt(px_height) } });
        CGContextSetAllowsFontSmoothing(ctx, true);
        CGContextSetShouldSmoothFonts(ctx, self.config.font_thicken);
        CGContextSetAllowsFontSubpixelPositioning(ctx, true);
        CGContextSetShouldSubpixelPositionFonts(ctx, true);
        CGContextSetAllowsFontSubpixelQuantization(ctx, false);
        CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
        CGContextSetAllowsAntialiasing(ctx, true);
        CGContextSetShouldAntialias(ctx, true);
        if (sbix) {
            CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
            CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 1);
        } else {
            const strength: f64 = @floatFromInt(self.config.font_thicken_strength);
            CGContextSetGrayFillColor(ctx, strength / 255.0, 1);
            CGContextSetGrayStrokeColor(ctx, strength / 255.0, 1);
        }
        if (f.synthetic_bold) |line_width| {
            CGContextSetTextDrawingMode(ctx, kCGTextFillStroke);
            CGContextSetLineWidth(ctx, line_width);
        }
        CGContextTranslateCTM(ctx, frac_x + @as(f64, @floatFromInt(padding)), frac_y + @as(f64, @floatFromInt(padding)));
        CGContextScaleCTM(ctx, width / rect.size.width, height / rect.size.height);
        const at = [1]CGPoint{.{ .x = -rect.origin.x, .y = -rect.origin.y }};
        CTFontDrawGlyphs(f.font, &glyphs, &at, 1, ctx);

        // Bitmap contexts keep the top row first, as the canvas does.
        return .{
            .data = buf,
            .width = px_width,
            .height = px_height,
            .offset_x = px_x,
            .offset_y = px_y + @as(i32, @intCast(px_height)),
            .color = sbix,
        };
    }
};

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

fn styleOf(cell: raster.Cell) Style {
    if (cell.bold) return if (cell.italic) .bold_italic else .bold;
    return if (cell.italic) .italic else .regular;
}

/// Ghostty's comparableStyle: runs split on any style change but the
/// background.
fn sameRunStyle(a: raster.Cell, b: raster.Cell) bool {
    return std.mem.eql(u8, &a.fg, &b.fg) and a.alpha == b.alpha and a.bold == b.bold and
        a.italic == b.italic and a.strikethrough == b.strikethrough and a.underline == b.underline and
        std.meta.eql(a.underline_color, b.underline_color);
}

fn firstCodepoint(text: []const u8) ?u21 {
    const view = std.unicode.Utf8View.init(text) catch return null;
    var it = view.iterator();
    return it.nextCodepoint();
}

fn utf16(cp: u21, out: *[2]u16) usize {
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        out[1] = 0;
        return 1;
    }
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

const Presentation = enum { text, emoji };
const PresentationMode = union(enum) { explicit: Presentation, default: Presentation, any };

/// Ghostty's Collection.Entry.hasCodepoint for CoreText faces: fallback
/// faces must match the default presentation, configured ones need not.
fn hasCodepoint(f: Face, cp: u21, mode: PresentationMode) bool {
    const wanted: ?Presentation = switch (mode) {
        .explicit => |p| p,
        .default => |p| if (f.fallback) p else null,
        .any => null,
    };
    if (f.glyphIndex(cp) == null) return false;
    const actual: Presentation = if (f.color) .emoji else .text;
    return wanted == null or wanted.? == actual;
}

/// Ghostty's Collection.scaleFactor with the ic_width adjustment.
fn scaleFactor(primary: FaceMetrics, face_metrics: FaceMetrics) f64 {
    const primary_scale = 1 / primary.px_per_em;
    const face_scale = 1 / face_metrics.px_per_em;
    const pair: [2]f64 = if (face_metrics.ic_width == face_metrics.icWidth())
        .{ primary.icWidth() * primary_scale, face_metrics.icWidth() * face_scale }
    else if (face_metrics.ex_height == face_metrics.exHeight())
        .{ primary.exHeight() * primary_scale, face_metrics.exHeight() * face_scale }
    else if (face_metrics.cap_height == face_metrics.capHeight())
        .{ primary.capHeight() * primary_scale, face_metrics.capHeight() * face_scale }
    else
        .{ primary.lineHeight() * primary_scale, face_metrics.lineHeight() * face_scale };
    if (pair[0] <= 0 or pair[1] <= 0) return 1;
    return pair[0] / pair[1];
}

fn isColorFont(font: Ref) bool {
    if (CTFontGetSymbolicTraits(font) & kCTFontTraitColorGlyphs == 0) return false;
    const sbix = CTFontCopyTable(font, tag("sbix"), 0) orelse return false;
    release(sbix);
    return true;
}

fn tag(comptime name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .big);
}

fn table(font: Ref, comptime name: *const [4]u8) ?Ref {
    return CTFontCopyTable(font, tag(name), 0);
}

fn tableBytes(data: Ref) []const u8 {
    return CFDataGetBytePtr(data)[0..@intCast(CFDataGetLength(data))];
}

/// Ghostty's coretext Face.getMetrics.
pub fn faceMetrics(font: Ref) FaceMetrics {
    const head: ?opentype.Head = if (table(font, "head") orelse table(font, "bhed")) |d| blk: {
        defer release(d);
        break :blk opentype.Head.init(tableBytes(d)) catch null;
    } else null;
    const post: ?opentype.Post = if (table(font, "post")) |d| blk: {
        defer release(d);
        break :blk opentype.Post.init(tableBytes(d)) catch null;
    } else null;
    const os2: ?opentype.OS2 = if (table(font, "OS/2")) |d| blk: {
        defer release(d);
        break :blk opentype.OS2.init(tableBytes(d)) catch null;
    } else null;
    const hhea: ?opentype.Hhea = if (table(font, "hhea")) |d| blk: {
        defer release(d);
        break :blk opentype.Hhea.init(tableBytes(d)) catch null;
    } else null;

    const units_per_em: f64 = if (head) |h| @floatFromInt(h.unitsPerEm) else @floatFromInt(CTFontGetUnitsPerEm(font));
    const px_per_em = CTFontGetSize(font);
    const px_per_unit = px_per_em / units_per_em;

    const vertical: [3]f64 = vertical: {
        const h = hhea orelse break :vertical .{ CTFontGetAscent(font), -CTFontGetDescent(font), CTFontGetLeading(font) };
        const hhea_ascent: f64 = @floatFromInt(h.ascender);
        const hhea_descent: f64 = @floatFromInt(h.descender);
        const hhea_line_gap: f64 = @floatFromInt(h.lineGap);
        const o = os2 orelse break :vertical .{ hhea_ascent * px_per_unit, hhea_descent * px_per_unit, hhea_line_gap * px_per_unit };
        const os2_ascent: f64 = @floatFromInt(o.sTypoAscender);
        const os2_descent: f64 = @floatFromInt(o.sTypoDescender);
        const os2_line_gap: f64 = @floatFromInt(o.sTypoLineGap);
        if (o.fsSelection.use_typo_metrics) break :vertical .{ os2_ascent * px_per_unit, os2_descent * px_per_unit, os2_line_gap * px_per_unit };
        if (h.ascender != 0 or h.descender != 0) break :vertical .{ hhea_ascent * px_per_unit, hhea_descent * px_per_unit, hhea_line_gap * px_per_unit };
        if (os2_ascent != 0 or os2_descent != 0) break :vertical .{ os2_ascent * px_per_unit, os2_descent * px_per_unit, os2_line_gap * px_per_unit };
        const win_ascent: f64 = @floatFromInt(o.usWinAscent);
        const win_descent: f64 = @floatFromInt(o.usWinDescent);
        break :vertical .{ win_ascent * px_per_unit, -win_descent * px_per_unit, 0.0 };
    };

    var underline_position: ?f64 = null;
    var underline_thickness: ?f64 = null;
    if (post) |p| {
        const broken = p.underlineThickness == 0;
        if (!(broken and p.underlinePosition == 0)) underline_position = @as(f64, @floatFromInt(p.underlinePosition)) * px_per_unit;
        if (!broken) underline_thickness = @as(f64, @floatFromInt(p.underlineThickness)) * px_per_unit;
    }
    var strikethrough_position: ?f64 = null;
    var strikethrough_thickness: ?f64 = null;
    if (os2) |o| {
        const broken = o.yStrikeoutSize == 0;
        if (!(broken and o.yStrikeoutPosition == 0)) strikethrough_position = @as(f64, @floatFromInt(o.yStrikeoutPosition)) * px_per_unit;
        if (!broken) strikethrough_thickness = @as(f64, @floatFromInt(o.yStrikeoutSize)) * px_per_unit;
    }
    const cap_height: f64, const ex_height: f64 = if (os2) |o| .{
        if (o.sCapHeight) |v| @as(f64, @floatFromInt(v)) * px_per_unit else CTFontGetCapHeight(font),
        if (o.sxHeight) |v| @as(f64, @floatFromInt(v)) * px_per_unit else CTFontGetXHeight(font),
    } else .{ CTFontGetCapHeight(font), CTFontGetXHeight(font) };

    // The widest printable ASCII advance, and their joint bounding height.
    var chars: [95]u16 = undefined;
    for (&chars, 0..) |*c, i| c.* = @intCast(32 + i);
    var glyphs: [95]u16 = undefined;
    _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.len);
    var advances: [95]CGSize = undefined;
    _ = CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyphs, &advances, glyphs.len);
    var cell_width: f64 = 0;
    for (advances) |a| cell_width = @max(cell_width, a.width);
    const ascii_rect = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &glyphs, null, glyphs.len);

    const ic_width: ?f64 = ic: {
        var water = [1]u16{0x6C34};
        var water_glyph = [1]u16{0};
        if (!CTFontGetGlyphsForCharacters(font, &water, &water_glyph, 1)) break :ic null;
        const advance = CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &water_glyph, null, 1);
        const bounds = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &water_glyph, null, 1);
        if (bounds.size.width > advance) break :ic null;
        break :ic advance;
    };

    return .{
        .px_per_em = px_per_em,
        .cell_width = cell_width,
        .ascent = vertical[0],
        .descent = vertical[1],
        .line_gap = vertical[2],
        .underline_position = underline_position,
        .underline_thickness = underline_thickness,
        .strikethrough_position = strikethrough_position,
        .strikethrough_thickness = strikethrough_thickness,
        .cap_height = cap_height,
        .ex_height = ex_height,
        .ascii_height = ascii_rect.size.height,
        .ic_width = ic_width,
    };
}

// ---- discovery (Ghostty's font/discovery.zig, CoreText) ----

const Descriptor = struct {
    family: ?[]const u8 = null,
    codepoint: u21 = 0,
    size: f64 = 0,
    bold: bool = false,
    italic: bool = false,
};

fn toCoreText(desc: Descriptor) !Ref {
    var keys: [4]Ref = undefined;
    var values: [4]Ref = undefined;
    var n: usize = 0;
    var owned: [4]?Ref = @splat(null);
    defer for (owned) |o| if (o) |v| release(v);
    if (desc.family) |family| {
        const s = try cfString(family);
        owned[n] = s;
        keys[n] = kCTFontFamilyNameAttribute;
        values[n] = s;
        n += 1;
    }
    if (desc.codepoint > 0) {
        const cs = CFCharacterSetCreateWithCharactersInRange(null, .{ .location = desc.codepoint, .length = 1 }) orelse return error.CoreText;
        owned[n] = cs;
        keys[n] = kCTFontCharacterSetAttribute;
        values[n] = cs;
        n += 1;
    }
    if (desc.size > 0) {
        const size: i32 = @intFromFloat(@round(desc.size));
        const num = CFNumberCreate(null, kCFNumberSInt32Type, &size) orelse return error.CoreText;
        owned[n] = num;
        keys[n] = kCTFontSizeAttribute;
        values[n] = num;
        n += 1;
    }
    var traits: u32 = 0;
    if (desc.bold) traits |= kCTFontTraitBold;
    if (desc.italic) traits |= kCTFontTraitItalic;
    if (traits > 0) {
        const traits_i: i32 = @bitCast(traits);
        const num = CFNumberCreate(null, kCFNumberSInt32Type, &traits_i) orelse return error.CoreText;
        defer release(num);
        const traits_dict = try dictionary(&.{kCTFontSymbolicTrait}, &.{num});
        owned[n] = traits_dict;
        keys[n] = kCTFontTraitsAttribute;
        values[n] = traits_dict;
        n += 1;
    }
    const attrs = try dictionary(keys[0..n], values[0..n]);
    defer release(attrs);
    return CTFontDescriptorCreateWithAttributes(attrs) orelse error.CoreText;
}

/// Every installed font matching `desc`, best first by Ghostty's Score.
fn discoverAll(gpa: std.mem.Allocator, desc: Descriptor, out: *std.ArrayList(Ref)) !void {
    const ct_desc = try toCoreText(desc);
    defer release(ct_desc);
    var descs = [1]?*const anyopaque{ct_desc};
    const arr = CFArrayCreate(null, &descs, 1, &kCFTypeArrayCallBacks) orelse return error.CoreText;
    defer release(arr);
    const collection = CTFontCollectionCreateWithFontDescriptors(arr, null) orelse return error.CoreText;
    defer release(collection);
    const list = CTFontCollectionCreateMatchingFontDescriptors(collection) orelse return;
    defer release(list);
    const count: usize = @intCast(CFArrayGetCount(list));
    const Scored = struct { desc: Ref, score: u64 };
    const scored = try gpa.alloc(Scored, count);
    defer gpa.free(scored);
    for (scored, 0..) |*s, i| {
        const d = CFArrayGetValueAtIndex(list, @intCast(i)).?;
        _ = CFRetain(d);
        s.* = .{ .desc = d, .score = score(desc, d) };
    }
    std.mem.sortUnstable(Scored, scored, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lessThan);
    try out.ensureUnusedCapacity(gpa, count);
    for (scored) |s| out.appendAssumeCapacity(s.desc);
}

fn discoverFirst(desc: Descriptor) !?Ref {
    var list: std.ArrayList(Ref) = .empty;
    const gpa = std.heap.page_allocator;
    defer list.deinit(gpa);
    try discoverAll(gpa, desc, &list);
    if (list.items.len == 0) return null;
    for (list.items[1..]) |d| release(d);
    return list.items[0];
}

/// Ghostty's CoreText.Score, packed the same way so it orders the same.
fn score(desc: Descriptor, ct_desc: Ref) u64 {
    const Score = packed struct(u32) {
        glyph_count: u16 = 0,
        fuzzy_style: u8 = 0,
        bold: bool = false,
        italic: bool = false,
        exact_style: bool = false,
        monospace: bool = false,
        codepoint: bool = false,
        _: u3 = 0,
    };
    var s: Score = .{};
    const font = CTFontCreateWithFontDescriptor(ct_desc, 12, null) orelse return 0;
    defer release(font);
    s.glyph_count = std.math.cast(u16, CTFontGetGlyphCount(font)) orelse std.math.maxInt(u16);
    if (desc.codepoint > 0) {
        var chars: [2]u16 = undefined;
        const len = utf16(desc.codepoint, &chars);
        var glyphs = [2]u16{ 0, 0 };
        s.codepoint = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, @intCast(len));
    }
    const symbolic: u32 = traits: {
        const traits = CTFontDescriptorCopyAttribute(ct_desc, kCTFontTraitsAttribute) orelse break :traits 0;
        defer release(traits);
        const num = CFDictionaryGetValue(traits, kCTFontSymbolicTrait) orelse break :traits 0;
        var value: i32 = 0;
        _ = CFNumberGetValue(num, kCFNumberSInt32Type, &value);
        break :traits @bitCast(value);
    };
    s.monospace = symbolic & kCTFontTraitMonoSpace != 0;
    var is_bold = symbolic & kCTFontTraitBold != 0;
    var is_italic = symbolic & kCTFontTraitItalic != 0;
    if (table(font, "head")) |d| {
        defer release(d);
        if (opentype.Head.init(tableBytes(d))) |head| {
            is_bold = is_bold or (head.macStyle & 1 == 1);
            is_italic = is_italic or (head.macStyle & 2 == 2);
        } else |_| {}
    }
    if (table(font, "OS/2")) |d| {
        defer release(d);
        if (opentype.OS2.init(tableBytes(d))) |os2| {
            is_bold = is_bold or os2.fsSelection.bold;
            is_italic = is_italic or os2.fsSelection.italic;
        } else |_| {}
    }
    variationStyle(font, &is_bold, &is_italic);
    s.bold = desc.bold == is_bold;
    s.italic = desc.italic == is_italic;

    var style_buf: [128]u8 = undefined;
    const style_name: []const u8 = name: {
        const style = CTFontDescriptorCopyAttribute(ct_desc, kCTFontStyleNameAttribute) orelse break :name "";
        defer release(style);
        break :name cfStringBytes(style, &style_buf) orelse "";
    };
    const desired: []const []const u8 = if (desc.bold)
        (if (desc.italic) &.{ "bold italic", "bold", "italic", "oblique" } else &.{ "bold", "upright" })
    else if (desc.italic)
        &.{ "italic", "regular", "oblique" }
    else
        &.{ "regular", "upright" };
    s.exact_style = std.ascii.eqlIgnoreCase(style_name, desired[0]);
    var fuzzy: u8 = @intCast(@min(style_name.len, 255));
    for (desired) |d| {
        if (std.ascii.findIgnoreCase(style_name, d) != null) fuzzy -|= @intCast(d.len);
    }
    s.fuzzy_style = 255 -| fuzzy;
    return @as(u32, @bitCast(s));
}

/// Ghostty's Score reads bold/italic from a variable font's wght, ital,
/// and slnt axes too.
fn variationStyle(font: Ref, is_bold: *bool, is_italic: *bool) void {
    const axes = CTFontCopyAttribute(font, kCTFontVariationAxesAttribute) orelse return;
    defer release(axes);
    const values = CTFontCopyAttribute(font, kCTFontVariationAttribute) orelse return;
    defer release(values);
    var ital_seen = false;
    var buf: [64]u8 = undefined;
    for (0..@intCast(CFArrayGetCount(axes))) |i| {
        const axis = CFArrayGetValueAtIndex(axes, @intCast(i)).?;
        const id = CFDictionaryGetValue(axis, kCTFontVariationAxisIdentifierKey) orelse continue;
        const name_ref = CFDictionaryGetValue(axis, kCTFontVariationAxisNameKey) orelse continue;
        const default = CFDictionaryGetValue(axis, kCTFontVariationAxisDefaultValueKey) orelse continue;
        const name = cfStringBytes(name_ref, &buf) orelse "";
        var value: f64 = 0;
        _ = CFNumberGetValue(default, kCFNumberDoubleType, &value);
        if (CFDictionaryGetValue(values, id)) |v| _ = CFNumberGetValue(v, kCFNumberDoubleType, &value);
        if (std.mem.eql(u8, name, "wght")) {
            is_bold.* = value > 600;
        } else if (std.mem.eql(u8, name, "ital")) {
            is_italic.* = value > 0.5;
            ital_seen = true;
        } else if (!ital_seen and std.mem.eql(u8, name, "slnt")) {
            is_italic.* = value <= -5.0;
        }
    }
}

/// Ghostty's discoverCodepoint: CoreText's own choice for the character,
/// unless that is LastResort.
fn codepointDescriptor(original: Ref, cp: u21) !?Ref {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return null;
    const str = try cfString(buf[0..len]);
    defer release(str);
    var units: [2]u16 = undefined;
    const font = CTFontCreateForString(original, str, .{ .location = 0, .length = @intCast(utf16(cp, &units)) }) orelse return null;
    defer release(font);
    const name = CTFontCopyPostScriptName(font);
    defer release(name);
    var name_buf: [64]u8 = undefined;
    if (cfStringBytes(name, &name_buf)) |n| if (std.mem.eql(u8, n, "LastResort")) return null;
    return CTFontCopyFontDescriptor(font);
}

fn fontFromData(bytes: []const u8, px: f64) !Ref {
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.CoreText;
    defer release(data);
    const desc = CTFontManagerCreateFontDescriptorFromData(data) orelse return error.CoreText;
    defer release(desc);
    return CTFontCreateWithFontDescriptor(desc, px, null) orelse error.CoreText;
}

/// Ghostty's Face.setVariations for the embedded bold: wght = `weight`.
fn withWeight(font: Ref, weight: f64) !Ref {
    const wght: i32 = @bitCast(tag("wght"));
    const id = CFNumberCreate(null, kCFNumberSInt32Type, &wght) orelse return error.CoreText;
    defer release(id);
    const value = CFNumberCreate(null, kCFNumberDoubleType, &weight) orelse return error.CoreText;
    defer release(value);
    const variation = try dictionary(&.{id}, &.{value});
    defer release(variation);
    const attrs = try dictionary(&.{kCTFontVariationAttribute}, &.{variation});
    defer release(attrs);
    const desc = CTFontDescriptorCreateWithAttributes(attrs) orelse return error.CoreText;
    defer release(desc);
    return CTFontCreateCopyWithAttributes(font, 0, null, desc) orelse error.CoreText;
}

/// Ghostty's default features (liga) followed by font-feature, as a font
/// attributes dictionary (Ghostty's makeFeaturesDict).
fn featuresDict(gpa: std.mem.Allocator, configured: []const []const u8) !Ref {
    var list: std.ArrayList(Ref) = .empty;
    defer {
        for (list.items) |d| release(d);
        list.deinit(gpa);
    }
    var specs: std.ArrayList(Feature) = .empty;
    defer specs.deinit(gpa);
    try specs.append(gpa, .{ .tag = "liga".*, .value = 1 });
    for (configured) |text| {
        var it = std.mem.tokenizeAny(u8, text, ", ");
        while (it.next()) |item| if (Feature.parse(item)) |f| try specs.append(gpa, f);
    }
    for (specs.items) |f| {
        const key = try cfString(&f.tag);
        defer release(key);
        const value_i: i32 = @intCast(f.value);
        const value = CFNumberCreate(null, kCFNumberSInt32Type, &value_i) orelse return error.CoreText;
        defer release(value);
        try list.append(gpa, try dictionary(&.{ kCTFontOpenTypeFeatureTag, kCTFontOpenTypeFeatureValue }, &.{ key, value }));
    }
    const arr = CFArrayCreate(null, @ptrCast(list.items.ptr), @intCast(list.items.len), &kCFTypeArrayCallBacks) orelse return error.CoreText;
    defer release(arr);
    return dictionary(&.{kCTFontFeatureSettingsAttribute}, &.{arr});
}

/// A font-feature entry, in Ghostty's syntaxes: "liga", "+liga", "-liga",
/// "liga=0", "liga on".
pub const Feature = struct {
    tag: [4]u8,
    value: u32,

    pub fn parse(text: []const u8) ?Feature {
        var s = std.mem.trim(u8, text, " \t\"");
        var value: u32 = 1;
        if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
            if (s[0] == '-') value = 0;
            s = s[1..];
        }
        if (std.mem.indexOfAny(u8, s, "= ")) |sep| {
            const rest = std.mem.trim(u8, s[sep + 1 ..], " =");
            s = s[0..sep];
            value = if (std.mem.eql(u8, rest, "on")) 1 else if (std.mem.eql(u8, rest, "off")) 0 else std.fmt.parseInt(u32, rest, 10) catch return null;
        }
        if (s.len != 4) return null;
        return .{ .tag = s[0..4].*, .value = value };
    }
};

// ---- CoreFoundation helpers ----

fn release(ref: Ref) void {
    CFRelease(ref);
}

fn cfString(bytes: []const u8) !Ref {
    return CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), kCFStringEncodingUTF8, false) orelse error.CoreText;
}

fn cfStringBytes(str: Ref, buf: []u8) ?[]const u8 {
    if (!CFStringGetCString(str, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8)) return null;
    return std.mem.sliceTo(buf, 0);
}

fn dictionary(keys: []const Ref, values: []const Ref) !Ref {
    return CFDictionaryCreate(null, @ptrCast(keys.ptr), @ptrCast(values.ptr), @intCast(keys.len), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse error.CoreText;
}

const italic_skew: CGAffineTransform = .{ .a = 1, .b = 0, .c = 0.267949, .d = 1, .tx = 0, .ty = 0 };

// ---- CoreFoundation, CoreText, CoreGraphics ----

const Ref = *const anyopaque;
const CFIndex = isize;
const CFRange = extern struct { location: CFIndex, length: CFIndex };
const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const CGAffineTransform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };
const CFDictionaryKeyCallBacks = extern struct { version: CFIndex, retain: ?*const anyopaque, release: ?*const anyopaque, copyDescription: ?*const anyopaque, equal: ?*const anyopaque, hash: ?*const anyopaque };
const CFDictionaryValueCallBacks = extern struct { version: CFIndex, retain: ?*const anyopaque, release: ?*const anyopaque, copyDescription: ?*const anyopaque, equal: ?*const anyopaque };
const CFArrayCallBacks = CFDictionaryValueCallBacks;

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCFNumberSInt32Type: CFIndex = 3;
const kCFNumberDoubleType: CFIndex = 13;
const kCTFontOrientationHorizontal: u32 = 1;
const kCTFontTraitItalic: u32 = 1 << 0;
const kCTFontTraitBold: u32 = 1 << 1;
const kCTFontTraitMonoSpace: u32 = 1 << 10;
const kCTFontTraitColorGlyphs: u32 = 1 << 13;
const kCGImageAlphaOnly: u32 = 7;
const kCGImageAlphaPremultipliedFirst: u32 = 2;
const kCGBitmapByteOrder32Little: u32 = 2 << 12;
const kCGTextFillStroke: i32 = 2;

extern const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
extern const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
extern const kCFTypeArrayCallBacks: CFArrayCallBacks;
extern const kCTFontAttributeName: Ref;
extern const kCTFontFamilyNameAttribute: Ref;
extern const kCTFontStyleNameAttribute: Ref;
extern const kCTFontCharacterSetAttribute: Ref;
extern const kCTFontSizeAttribute: Ref;
extern const kCTFontTraitsAttribute: Ref;
extern const kCTFontSymbolicTrait: Ref;
extern const kCTFontFeatureSettingsAttribute: Ref;
extern const kCTFontOpenTypeFeatureTag: Ref;
extern const kCTFontOpenTypeFeatureValue: Ref;
extern const kCTFontVariationAttribute: Ref;
extern const kCTFontVariationAxesAttribute: Ref;
extern const kCTFontVariationAxisIdentifierKey: Ref;
extern const kCTFontVariationAxisNameKey: Ref;
extern const kCTFontVariationAxisDefaultValueKey: Ref;
extern const kCTTypesetterOptionForcedEmbeddingLevel: Ref;
extern const kCGColorSpaceLinearGray: Ref;
extern const kCGColorSpaceDisplayP3: Ref;

extern "c" fn CFRelease(ref: Ref) void;
extern "c" fn CFRetain(ref: Ref) Ref;
extern "c" fn CFStringCreateWithBytes(alloc: ?Ref, bytes: [*]const u8, len: CFIndex, encoding: u32, external: bool) ?Ref;
extern "c" fn CFStringCreateWithCharacters(alloc: ?Ref, chars: [*]const u16, len: CFIndex) ?Ref;
extern "c" fn CFStringGetCString(str: Ref, buf: [*]u8, size: CFIndex, encoding: u32) bool;
extern "c" fn CFDataCreate(alloc: ?Ref, bytes: [*]const u8, len: CFIndex) ?Ref;
extern "c" fn CFDataGetBytePtr(data: Ref) [*]const u8;
extern "c" fn CFDataGetLength(data: Ref) CFIndex;
extern "c" fn CFNumberCreate(alloc: ?Ref, kind: CFIndex, value: *const anyopaque) ?Ref;
extern "c" fn CFNumberGetValue(num: Ref, kind: CFIndex, out: *anyopaque) bool;
extern "c" fn CFDictionaryCreate(alloc: ?Ref, keys: [*]const ?*const anyopaque, values: [*]const ?*const anyopaque, count: CFIndex, key_callbacks: *const CFDictionaryKeyCallBacks, value_callbacks: *const CFDictionaryValueCallBacks) ?Ref;
extern "c" fn CFDictionaryGetValue(dict: Ref, key: Ref) ?Ref;
extern "c" fn CFArrayCreate(alloc: ?Ref, values: [*]const ?*const anyopaque, count: CFIndex, callbacks: *const CFArrayCallBacks) ?Ref;
extern "c" fn CFArrayGetCount(arr: Ref) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(arr: Ref, index: CFIndex) ?Ref;
extern "c" fn CFAttributedStringCreate(alloc: ?Ref, str: Ref, attrs: Ref) ?Ref;
extern "c" fn CFCharacterSetCreateWithCharactersInRange(alloc: ?Ref, range: CFRange) ?Ref;

extern "c" fn CTFontDescriptorCreateWithAttributes(attrs: Ref) ?Ref;
extern "c" fn CTFontDescriptorCopyAttribute(desc: Ref, attr: Ref) ?Ref;
extern "c" fn CTFontManagerCreateFontDescriptorFromData(data: Ref) ?Ref;
extern "c" fn CTFontCreateWithFontDescriptor(desc: Ref, size: f64, matrix: ?*const CGAffineTransform) ?Ref;
extern "c" fn CTFontCreateCopyWithAttributes(font: Ref, size: f64, matrix: ?*const CGAffineTransform, attrs: ?Ref) ?Ref;
extern "c" fn CTFontCreateForString(font: Ref, str: Ref, range: CFRange) ?Ref;
extern "c" fn CTFontCopyFontDescriptor(font: Ref) Ref;
extern "c" fn CTFontCopyPostScriptName(font: Ref) Ref;
extern "c" fn CTFontCopyAttribute(font: Ref, attr: Ref) ?Ref;
extern "c" fn CTFontCopyTable(font: Ref, table_tag: u32, options: u32) ?Ref;
extern "c" fn CTFontGetSize(font: Ref) f64;
extern "c" fn CTFontGetUnitsPerEm(font: Ref) u32;
extern "c" fn CTFontGetAscent(font: Ref) f64;
extern "c" fn CTFontGetDescent(font: Ref) f64;
extern "c" fn CTFontGetLeading(font: Ref) f64;
extern "c" fn CTFontGetCapHeight(font: Ref) f64;
extern "c" fn CTFontGetXHeight(font: Ref) f64;
extern "c" fn CTFontGetGlyphCount(font: Ref) CFIndex;
extern "c" fn CTFontGetSymbolicTraits(font: Ref) u32;
extern "c" fn CTFontGetGlyphsForCharacters(font: Ref, chars: [*]const u16, glyphs: [*]u16, count: CFIndex) bool;
extern "c" fn CTFontGetAdvancesForGlyphs(font: Ref, orientation: u32, glyphs: [*]const u16, advances: ?[*]CGSize, count: CFIndex) f64;
extern "c" fn CTFontGetBoundingRectsForGlyphs(font: Ref, orientation: u32, glyphs: [*]const u16, rects: ?[*]CGRect, count: CFIndex) CGRect;
extern "c" fn CTFontDrawGlyphs(font: Ref, glyphs: [*]const u16, positions: [*]const CGPoint, count: usize, ctx: Ref) void;
extern "c" fn CTFontCollectionCreateWithFontDescriptors(descs: Ref, options: ?Ref) ?Ref;
extern "c" fn CTFontCollectionCreateMatchingFontDescriptors(collection: Ref) ?Ref;
extern "c" fn CTTypesetterCreateWithAttributedStringAndOptions(str: Ref, options: Ref) ?Ref;
extern "c" fn CTTypesetterCreateLine(typesetter: Ref, range: CFRange) ?Ref;
extern "c" fn CTLineGetGlyphRuns(line: Ref) Ref;
extern "c" fn CTRunGetGlyphCount(run: Ref) CFIndex;
extern "c" fn CTRunGetGlyphs(run: Ref, range: CFRange, out: [*]u16) void;
extern "c" fn CTRunGetAdvances(run: Ref, range: CFRange, out: [*]CGSize) void;
extern "c" fn CTRunGetPositions(run: Ref, range: CFRange, out: [*]CGPoint) void;
extern "c" fn CTRunGetStringIndices(run: Ref, range: CFRange, out: [*]CFIndex) void;

extern "c" fn CGColorSpaceCreateWithName(name: Ref) ?Ref;
extern "c" fn CGColorSpaceRelease(space: Ref) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits: usize, row_bytes: usize, space: Ref, info: u32) ?Ref;
extern "c" fn CGContextRelease(ctx: Ref) void;
extern "c" fn CGContextSetGrayFillColor(ctx: Ref, gray: f64, alpha: f64) void;
extern "c" fn CGContextSetGrayStrokeColor(ctx: Ref, gray: f64, alpha: f64) void;
extern "c" fn CGContextSetRGBFillColor(ctx: Ref, r: f64, g: f64, b: f64, a: f64) void;
extern "c" fn CGContextSetRGBStrokeColor(ctx: Ref, r: f64, g: f64, b: f64, a: f64) void;
extern "c" fn CGContextFillRect(ctx: Ref, rect: CGRect) void;
extern "c" fn CGContextSetAllowsFontSmoothing(ctx: Ref, value: bool) void;
extern "c" fn CGContextSetShouldSmoothFonts(ctx: Ref, value: bool) void;
extern "c" fn CGContextSetAllowsFontSubpixelPositioning(ctx: Ref, value: bool) void;
extern "c" fn CGContextSetShouldSubpixelPositionFonts(ctx: Ref, value: bool) void;
extern "c" fn CGContextSetAllowsFontSubpixelQuantization(ctx: Ref, value: bool) void;
extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(ctx: Ref, value: bool) void;
extern "c" fn CGContextSetAllowsAntialiasing(ctx: Ref, value: bool) void;
extern "c" fn CGContextSetShouldAntialias(ctx: Ref, value: bool) void;
extern "c" fn CGContextSetTextDrawingMode(ctx: Ref, mode: i32) void;
extern "c" fn CGContextSetLineWidth(ctx: Ref, width: f64) void;
extern "c" fn CGContextTranslateCTM(ctx: Ref, tx: f64, ty: f64) void;
extern "c" fn CGContextScaleCTM(ctx: Ref, sx: f64, sy: f64) void;
