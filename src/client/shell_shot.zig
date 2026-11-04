//! Screenshots of a shell session as PNG on the macOS clipboard. Terminals
//! can only put text on the clipboard, so Marlin draws the image itself:
//! the shell's rows become styled runs (cells resolved to the terminal's own
//! colors), and a JXA script draws them with AppKit, which brings font
//! fallback and emoji, and puts the PNG on the pasteboard.
const std = @import("std");
const Io = std.Io;
const vt = @import("ghostty-vt");

pub const Colors = struct {
    fg: [3]u8,
    bg: [3]u8,
    palette: [256][3]u8,
};

pub const Geometry = struct {
    cols: usize,
    /// Cell size in device pixels.
    cell_width: u32,
    cell_height: u32,
};

const bold: u8 = 1;
const italic: u8 = 2;
const underline: u8 = 4;
const strikethrough: u8 = 8;

const Run = struct {
    col: usize,
    width: usize,
    text: std.ArrayList(u8) = .empty,
    fg: [3]u8,
    bg: ?[3]u8,
    flags: u8,
    /// Plain ASCII cells, which may join a following run of the same style.
    joinable: bool,
};

/// The image as JSON for `script`: its grid, colors and font, then one
/// entry per styled run: [row, col, width, text, fg, bg|null, flags].
pub fn describe(arena: std.mem.Allocator, rows: []const vt.Pin, colors: Colors, geometry: Geometry, font: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"cols\":{d},\"rows\":{d},\"cw\":{d},\"ch\":{d},\"font\":", .{ geometry.cols, rows.len, geometry.cell_width, geometry.cell_height });
    try writeString(w, font);
    try w.print(",\"bg\":[{d},{d},{d}],\"runs\":[", .{ colors.bg[0], colors.bg[1], colors.bg[2] });
    var first = true;
    for (rows, 0..) |pin, row| {
        var run: ?Run = null;
        var col: usize = 0;
        var buf: [4]u8 = undefined;
        for (pin.cells(.all)) |*cell| {
            if (cell.wide == .spacer_tail) continue;
            defer col += 1;
            const width: usize = if (cell.wide == .wide) 2 else 1;
            const style: vt.Style = if (cell.style_id != 0) pin.style(cell) else .{};
            var fg = resolve(style.fg_color, colors, colors.fg);
            // Blank cells can carry a background of their own (erased lines).
            var bg = switch (cell.content_tag) {
                .bg_color_palette => colors.palette[cell.content.color_palette.data],
                .bg_color_rgb => [3]u8{ cell.content.color_rgb.r, cell.content.color_rgb.g, cell.content.color_rgb.b },
                else => resolve(style.bg_color, colors, colors.bg),
            };
            if (style.flags.inverse) std.mem.swap([3]u8, &fg, &bg);
            if (style.flags.faint) fg = mix(fg, bg);
            if (style.flags.invisible) fg = bg;
            var flags: u8 = 0;
            if (style.flags.bold) flags |= bold;
            if (style.flags.italic) flags |= italic;
            if (style.flags.underline != .none) flags |= underline;
            if (style.flags.strikethrough) flags |= strikethrough;
            const fill: ?[3]u8 = if (std.mem.eql(u8, &bg, &colors.bg)) null else bg;

            const has_text = cell.hasText() and cell.wide != .spacer_head;
            const cp: u21 = if (has_text) cell.codepoint() else ' ';
            const ascii = width == 1 and cp < 0x7f and !(has_text and cell.hasGrapheme());
            if (run) |*r| {
                const same = r.joinable and ascii and r.col + r.width == col and r.flags == flags and
                    std.mem.eql(u8, &r.fg, &fg) and std.meta.eql(r.bg, fill);
                if (same) {
                    try r.text.append(arena, @intCast(cp));
                    r.width += 1;
                    continue;
                }
                try flush(w, row, r, &first);
                run = null;
            }
            if (cp == ' ' and fill == null and flags & (underline | strikethrough) == 0) continue;
            var next: Run = .{ .col = col, .width = width, .fg = fg, .bg = fill, .flags = flags, .joinable = ascii };
            try next.text.appendSlice(arena, buf[0 .. std.unicode.utf8Encode(cp, &buf) catch 0]);
            if (has_text and cell.hasGrapheme()) if (pin.grapheme(cell)) |extra| for (extra) |more| {
                try next.text.appendSlice(arena, buf[0 .. std.unicode.utf8Encode(more, &buf) catch continue]);
            };
            run = next;
        }
        if (run) |*r| try flush(w, row, r, &first);
    }
    try w.writeAll("]}");
    return out.written();
}

fn flush(w: *std.Io.Writer, row: usize, run: *const Run, first: *bool) !void {
    var text: []const u8 = run.text.items;
    var width = run.width;
    // Trailing blanks draw nothing unless they are filled or lined.
    if (run.joinable and run.bg == null and run.flags & (underline | strikethrough) == 0) {
        const trimmed = std.mem.trimEnd(u8, text, " ");
        width -= text.len - trimmed.len;
        text = trimmed;
    }
    if (text.len == 0) return;
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.print("[{d},{d},{d},", .{ row, run.col, width });
    try writeString(w, text);
    try w.print(",[{d},{d},{d}],", .{ run.fg[0], run.fg[1], run.fg[2] });
    if (run.bg) |bg| try w.print("[{d},{d},{d}]", .{ bg[0], bg[1], bg[2] }) else try w.writeAll("null");
    try w.print(",{d}]", .{run.flags});
}

fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn resolve(color: vt.Style.Color, colors: Colors, default: [3]u8) [3]u8 {
    return switch (color.value()) {
        .none => default,
        .palette => |index| colors.palette[index],
        .rgb => |rgb| .{ rgb.r, rgb.g, rgb.b },
    };
}

/// Halfway from `fg` to `bg`: faint text.
fn mix(fg: [3]u8, bg: [3]u8) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, fg, bg) |*c, f, b| c.* = @intCast((@as(u16, f) + b) / 2);
    return out;
}

/// The xterm palette with the terminal's reported colors over it.
pub fn colorsFrom(fg: ?[3]u8, bg: ?[3]u8, reported: [16]?[3]u8) Colors {
    var colors: Colors = .{ .fg = fg orelse .{ 0xff, 0xff, 0xff }, .bg = bg orelse .{ 0x28, 0x2c, 0x34 }, .palette = undefined };
    for (&colors.palette, vt.color.default) |*entry, rgb| entry.* = .{ rgb.r, rgb.g, rgb.b };
    for (reported, 0..) |maybe, i| if (maybe) |rgb| {
        colors.palette[i] = rgb;
    };
    return colors;
}

/// The terminal's font when it is Ghostty and names one; else Menlo.
pub fn fontFamily(arena: std.mem.Allocator, io: Io, home: ?[]const u8) []const u8 {
    const dir = home orelse return "Menlo";
    for ([_][]const u8{ ".config/ghostty/config", "Library/Application Support/com.mitchellh.ghostty/config" }) |rel| {
        const path = std.fs.path.join(arena, &.{ dir, rel }) catch continue;
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch continue;
        if (configFont(text)) |font| return font;
    }
    return "Menlo";
}

pub fn configFont(config: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "font-family")) continue;
        const value = std.mem.trim(u8, std.mem.trim(u8, line[eq + 1 ..], " \t"), "\"");
        if (value.len > 0) return value;
    }
    return null;
}

/// Draws `describe`'s JSON (path in argv[0]) and puts the PNG on the
/// clipboard, at the screen's backing scale so it pastes at its real size.
pub const script =
    \\ObjC.import('AppKit');
    \\function run(argv) {
    \\  var d = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
    \\  var pad = d.cw * 2, W = d.cols * d.cw + 2 * pad, H = d.rows * d.ch + 2 * pad;
    \\  var rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(null, W, H, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
    \\  $.NSGraphicsContext.saveGraphicsState;
    \\  $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
    \\  function color(c) { return $.NSColor.colorWithSRGBRedGreenBlueAlpha(c[0] / 255, c[1] / 255, c[2] / 255, 1); }
    \\  function attrs(font, fg, flags) {
    \\    var keys = [$.NSFontAttributeName, $.NSForegroundColorAttributeName], vals = [font, color(fg)];
    \\    if (flags & 4) { keys.push($.NSUnderlineStyleAttributeName); vals.push($(1)); }
    \\    if (flags & 8) { keys.push($.NSStrikethroughStyleAttributeName); vals.push($(1)); }
    \\    return $.NSDictionary.dictionaryWithObjectsForKeys($(vals), $(keys));
    \\  }
    \\  color(d.bg).setFill; $.NSRectFill($.NSMakeRect(0, 0, W, H));
    \\  var probe = $.NSFont.fontWithNameSize(d.font, 100);
    \\  if (probe.isNil()) probe = $.NSFont.monospacedSystemFontOfSizeWeight(100, 0);
    \\  var em = $('M').sizeWithAttributes(attrs(probe, d.bg, 0)).width;
    \\  var size = 100 * d.cw / em, fm = $.NSFontManager.sharedFontManager, fonts = {};
    \\  function font(flags) {
    \\    var k = flags & 3; if (fonts[k]) return fonts[k];
    \\    var f = $.NSFont.fontWithNameSize(probe.fontName, size);
    \\    if (k & 1) f = fm.convertFontToHaveTrait(f, 2);
    \\    if (k & 2) f = fm.convertFontToHaveTrait(f, 1);
    \\    return fonts[k] = f;
    \\  }
    \\  var regular = font(0), lh = regular.ascender - regular.descender + regular.leading;
    \\  d.runs.forEach(function (r) {
    \\    var x = pad + r[1] * d.cw, y = H - pad - (r[0] + 1) * d.ch;
    \\    if (r[5]) { color(r[5]).setFill; $.NSRectFill($.NSMakeRect(x, y, r[2] * d.cw, d.ch)); }
    \\    if (r[3].trim().length) $(r[3]).drawAtPointWithAttributes($.NSMakePoint(x, y + (d.ch - lh) / 2), attrs(font(r[6]), r[4], r[6]));
    \\    else if (r[6] & 12) $(r[3]).drawAtPointWithAttributes($.NSMakePoint(x, y + (d.ch - lh) / 2), attrs(font(r[6]), r[4], r[6]));
    \\  });
    \\  $.NSGraphicsContext.restoreGraphicsState;
    \\  var scale = $.NSScreen.mainScreen.isNil() ? 1 : $.NSScreen.mainScreen.backingScaleFactor;
    \\  rep.size = $.NSMakeSize(W / scale, H / scale);
    \\  var png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
    \\  var pb = $.NSPasteboard.generalPasteboard;
    \\  pb.clearContents;
    \\  pb.setDataForType(png, 'public.png');
    \\  return W + 'x' + H;
    \\}
;

/// Runs `script` on `json`; blocking, so callers use a thread.
pub fn copyToClipboard(gpa: std.mem.Allocator, io: Io, json: []const u8, tmp_dir: []const u8, environ: ?*const std.process.Environ.Map) !void {
    var name_buf: [64]u8 = undefined;
    var random: [8]u8 = undefined;
    io.random(&random);
    const name = try std.fmt.bufPrint(&name_buf, "marlin-shot-{x}.json", .{std.mem.readInt(u64, &random, .little)});
    const path = try std.fs.path.join(gpa, &.{ tmp_dir, name });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", script, path },
        .environ_map = environ,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.scoped(.shell_shot).warn("osascript failed: {s}", .{result.stderr});
            return error.ScreenshotFailed;
        },
        else => return error.ScreenshotFailed,
    }
}
