//! Screenshots as PNG on the macOS clipboard (Alt+S, /screenshot [slim]).
//! Terminals can only put text on the clipboard, so Marlin draws the image
//! itself from the frame it just rendered: the screen's cells become styled
//! runs in the terminal's own colors, and a JXA script draws them with
//! AppKit, which brings font fallback and emoji, and puts the PNG on the
//! pasteboard. Kitty images are not in the frame and do not appear.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");
const render = @import("render.zig");
const tui = @import("tui.zig");
const App = tui.App;

pub const Mode = enum {
    /// Everything on screen: tab bar, transcript or shell, status line.
    full,
    /// Only the transcript (or shell) area.
    slim,
};

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

pub fn isKey(key: vaxis.Key) bool {
    return key.matches('s', .{ .alt = true });
}

/// Ask for a screenshot of the next frame, so it shows the screen as it is
/// without the keypress's own effects (the typed command, a notice).
pub fn request(app: *App, mode: Mode) void {
    if (builtin.os.tag != .macos) return app.setNotice("screenshots need macOS", .{});
    if (app.screenshot_thread != null) return app.setNotice("a screenshot is already being taken", .{});
    app.screenshot_request = mode;
    app.refresh_requested = true;
}

/// After a frame is rendered: start the requested screenshot of it.
pub fn takePending(app: *App, screen: *const vaxis.Screen) void {
    const mode = app.screenshot_request orelse return;
    app.screenshot_request = null;
    const loop = app.loop orelse return;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const top: usize = switch (mode) {
        .full => 0,
        .slim => app.tabBarRows(),
    };
    const end: usize = switch (mode) {
        .full => screen.height,
        .slim => @min(top + app.view.last_view_h, screen.height),
    };
    if (end <= top) return app.setNotice("nothing to capture", .{});
    const theme = &app.terminal_theme;
    const home = if (app.environ) |env| env.get("HOME") else null;
    const json = describe(arena, screen, top, end, colorsFrom(theme.foreground, theme.background, theme.palette), .{
        .cols = screen.width,
        .cell_width = if (app.cell_px_w > 0) app.cell_px_w else 16,
        .cell_height = if (app.cell_px_h > 0) app.cell_px_h else 34,
    }, fontFamily(arena, app.io, home)) catch return app.setNotice("screenshot failed: out of memory", .{});
    const tmp = if (app.environ) |env| env.get("TMPDIR") orelse "/tmp" else "/tmp";
    const job = app.gpa.create(Job) catch return;
    job.* = .{ .gpa = app.gpa, .io = app.io, .loop = loop, .environ = app.environ, .json = undefined, .tmp = undefined };
    job.json = app.gpa.dupe(u8, json) catch {
        app.gpa.destroy(job);
        return;
    };
    job.tmp = app.gpa.dupe(u8, tmp) catch {
        app.gpa.free(job.json);
        app.gpa.destroy(job);
        return;
    };
    app.screenshot_thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        job.deinit();
        return app.setNotice("screenshot failed: could not start", .{});
    };
    app.setNotice("taking a screenshot…", .{});
}

pub fn done(app: *App, failure: ?[]const u8) void {
    if (app.screenshot_thread) |thread| thread.join();
    app.screenshot_thread = null;
    if (failure) |reason| app.setNotice("screenshot failed: {s}", .{reason}) else app.setNotice("screenshot copied to the clipboard", .{});
}

const Job = struct {
    gpa: std.mem.Allocator,
    io: Io,
    loop: *vaxis.Loop(tui.Event),
    environ: ?*const std.process.Environ.Map,
    json: []u8,
    tmp: []u8,

    fn deinit(job: *Job) void {
        job.gpa.free(job.json);
        job.gpa.free(job.tmp);
        job.gpa.destroy(job);
    }

    fn run(job: *Job) void {
        defer job.deinit();
        copyToClipboard(job.gpa, job.io, job.json, job.tmp, job.environ) catch |err| {
            job.loop.postEvent(.{ .screenshot = @errorName(err) }) catch {};
            return;
        };
        job.loop.postEvent(.{ .screenshot = null }) catch {};
    }
};

/// Rows `top..end` of `screen` as JSON for `script`: the grid, colors and
/// font, then one entry per styled run: [row, col, width, text, fg,
/// bg|null, flags].
pub fn describe(arena: std.mem.Allocator, screen: *const vaxis.Screen, top: usize, end: usize, colors: Colors, geometry: Geometry, font: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"cols\":{d},\"rows\":{d},\"cw\":{d},\"ch\":{d},\"font\":", .{ geometry.cols, end - top, geometry.cell_width, geometry.cell_height });
    try writeString(w, font);
    try w.print(",\"bg\":[{d},{d},{d}],\"runs\":[", .{ colors.bg[0], colors.bg[1], colors.bg[2] });
    var first = true;
    for (top..end) |y| {
        const row = y - top;
        var run: ?Run = null;
        var col: usize = 0;
        while (col < screen.width) {
            const cell = screen.readCell(@intCast(col), @intCast(y)) orelse break;
            const grapheme = cell.char.grapheme;
            const measured: usize = if (cell.char.width > 0) cell.char.width else render.displayWidth(grapheme);
            const width: usize = @max(measured, 1);
            defer col += width;
            const style = cell.style;
            var fg = resolve(style.fg, colors, colors.fg);
            var bg = resolve(style.bg, colors, colors.bg);
            if (style.reverse) std.mem.swap([3]u8, &fg, &bg);
            if (style.dim) fg = mix(fg, bg);
            if (style.invisible) fg = bg;
            var flags: u8 = 0;
            if (style.bold) flags |= bold;
            if (style.italic) flags |= italic;
            if (style.ul_style != .off) flags |= underline;
            if (style.strikethrough) flags |= strikethrough;
            const fill: ?[3]u8 = if (std.mem.eql(u8, &bg, &colors.bg)) null else bg;

            const text = if (grapheme.len == 0) " " else grapheme;
            const ascii = width == 1 and text.len == 1 and text[0] >= 0x20 and text[0] < 0x7f;
            if (run) |*r| {
                const same = r.joinable and ascii and r.col + r.width == col and r.flags == flags and
                    std.mem.eql(u8, &r.fg, &fg) and std.meta.eql(r.bg, fill);
                if (same) {
                    try r.text.append(arena, text[0]);
                    r.width += 1;
                    continue;
                }
                try flush(w, row, r, &first);
                run = null;
            }
            if (std.mem.eql(u8, text, " ") and fill == null and flags & (underline | strikethrough) == 0) continue;
            var next: Run = .{ .col = col, .width = width, .fg = fg, .bg = fill, .flags = flags, .joinable = ascii };
            try next.text.appendSlice(arena, text);
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

fn resolve(color: vaxis.Color, colors: Colors, default: [3]u8) [3]u8 {
    return switch (color) {
        .default => default,
        .index => |index| colors.palette[index],
        .rgb => |rgb| rgb,
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
/// clipboard, at the screen's backing scale so it pastes at its real size;
/// or writes it to argv[1] when given (MARLIN_SCREENSHOT_FILE, for tests).
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
    \\  if (argv[1]) { png.writeToFileAtomically(argv[1], true); return W + 'x' + H; }
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
        .argv = &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", script, path, if (environ) |env| env.get("MARLIN_SCREENSHOT_FILE") orelse "" else "" },
        .environ_map = environ,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.scoped(.screenshot).warn("osascript failed: {s}", .{result.stderr});
            return error.ScreenshotFailed;
        },
        else => return error.ScreenshotFailed,
    }
}
