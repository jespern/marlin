//! Screenshots as PNG on the macOS clipboard (Alt+S, /screenshot [slim],
//! !ss). Terminals can only put text on the clipboard, so Marlin paints the
//! image itself from the frame it just rendered, the way Ghostty paints it:
//! Ghostty's font setup and sprite font, CoreText shaping, the terminal's
//! own colors, and the shell's Kitty images (raster.zig,
//! raster_coretext.zig). Painting runs on a thread from a copy of the
//! frame; the PNG goes to the pasteboard, or to MARLIN_SCREENSHOT_FILE.
//! Ghostty's default font is downloaded on first use and cached.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");
const ghostty_font = @import("ghostty_font");
const asset_store = @import("asset_store");
const render = @import("render.zig");
const raster = @import("raster.zig");
const shell_tab = @import("shell_tab.zig");
const tui = @import("tui.zig");
const App = tui.App;
const coretext = if (builtin.os.tag == .macos) @import("raster_coretext.zig") else struct {};

pub const Mode = enum {
    /// Everything on screen: tab bar, transcript or shell, status line.
    full,
    /// Only the transcript (or shell) area.
    slim,
};

/// What a screenshot thread reports back.
pub const Outcome = union(enum) {
    /// On the clipboard; `exact` when the font grid matched the
    /// terminal's cells, so text sits where the terminal drew it.
    copied: struct { exact: bool },
    failed: []const u8,
};

pub const Colors = struct {
    fg: [3]u8,
    bg: [3]u8,
    palette: [256][3]u8,
};

/// Ghostty's config keys that change how the frame is painted.
pub const GhosttyConfig = struct {
    font: if (builtin.os.tag == .macos) coretext.Config else void = if (builtin.os.tag == .macos) .{} else {},
    faint_opacity: f64 = 0.5,
    cursor_color: ?[3]u8 = null,
    cursor_text: ?[3]u8 = null,
    cursor_style: raster.CursorStyle = .block,
};

/// Ghostty's built-in default font: JetBrains Mono 2.304, the files
/// Ghostty pins (same digests), from JetBrains' release tag.
pub const default_font = [2]asset_store.Spec{
    .{
        .filename = "JetBrainsMono-wght.ttf",
        .sha256 = "662a196d58f1183bf2d77428b6d5283fe3f45161ab021bea4036bc98e5cac016",
        .url = "https://raw.githubusercontent.com/JetBrains/JetBrainsMono/v2.304/fonts/variable/JetBrainsMono%5Bwght%5D.ttf",
        .max_bytes = 1024 * 1024,
        .validate = validateFont,
    },
    .{
        .filename = "JetBrainsMono-Italic-wght.ttf",
        .sha256 = "f115aaa12113718c02ce72864fe6823b87241bc23d3e44cf1220155f861063f2",
        .url = "https://raw.githubusercontent.com/JetBrains/JetBrainsMono/v2.304/fonts/variable/JetBrainsMono-Italic%5Bwght%5D.ttf",
        .max_bytes = 1024 * 1024,
        .validate = validateFont,
    },
};

fn validateFont(_: std.mem.Allocator, bytes: []const u8) anyerror!void {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "\x00\x01\x00\x00")) return error.NotTrueType;
}

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

/// After a frame is rendered: copy the requested part of it and paint it
/// on a thread.
pub fn takePending(app: *App, screen: *const vaxis.Screen) void {
    if (builtin.os.tag != .macos) return;
    const mode = app.screenshot_request orelse return;
    app.screenshot_request = null;
    const loop = app.loop orelse return;
    const top: usize = switch (mode) {
        .full => 0,
        .slim => app.tabBarRows(),
    };
    const end: usize = switch (mode) {
        .full => screen.height,
        .slim => @min(top + app.view.last_view_h, screen.height),
    };
    if (end <= top) return app.setNotice("nothing to capture", .{});

    const job = app.gpa.create(Job) catch return app.setNotice("screenshot failed: out of memory", .{});
    job.* = .{
        .arena = .init(app.gpa),
        .gpa = app.gpa,
        .io = app.io,
        .loop = loop,
        .environ = app.environ,
        .frame = undefined,
        .config = undefined,
        .cell_width = if (app.cell_px_w > 0) app.cell_px_w else 16,
        .cell_height = if (app.cell_px_h > 0) app.cell_px_h else 34,
        .tmp = undefined,
        .file = null,
    };
    const prepared = job.prepare(app, screen, top, end);
    prepared catch {
        job.deinit();
        return app.setNotice("screenshot failed: out of memory", .{});
    };
    app.screenshot_thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        job.deinit();
        return app.setNotice("screenshot failed: could not start", .{});
    };
    app.setNotice("taking a screenshot…", .{});
}

pub fn done(app: *App, outcome: Outcome) void {
    if (app.screenshot_thread) |thread| thread.join();
    app.screenshot_thread = null;
    switch (outcome) {
        .copied => |copied| if (copied.exact)
            app.setNotice("screenshot copied to the clipboard", .{})
        else
            app.setNotice("screenshot copied (approximate: Ghostty's font or cell grid could not be matched)", .{}),
        .failed => |reason| app.setNotice("screenshot failed: {s}", .{reason}),
    }
}

const Job = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: Io,
    loop: *vaxis.Loop(tui.Event),
    environ: ?*const std.process.Environ.Map,
    frame: raster.Frame,
    config: GhosttyConfig,
    cell_width: u32,
    cell_height: u32,
    tmp: []const u8,
    file: ?[]const u8,

    fn deinit(job: *Job) void {
        job.arena.deinit();
        job.gpa.destroy(job);
    }

    /// Everything the thread needs, copied out of the app and the screen.
    fn prepare(job: *Job, app: *App, screen: *const vaxis.Screen, top: usize, end: usize) !void {
        const arena = job.arena.allocator();
        const home = if (app.environ) |env| env.get("HOME") else null;
        job.config = loadGhosttyConfig(arena, app.io, home);
        const theme = &app.terminal_theme;
        job.frame = try frameFrom(arena, screen, top, end, colorsFrom(theme.foreground, theme.background, theme.palette), job.config);
        job.frame.images = try imagesFrom(arena, app, top, end, job.cell_width, job.cell_height);
        const env = app.environ;
        job.tmp = try arena.dupe(u8, if (env) |e| e.get("TMPDIR") orelse "/tmp" else "/tmp");
        if (env) |e| if (e.get("MARLIN_SCREENSHOT_FILE")) |path| {
            job.file = try arena.dupe(u8, path);
        };
    }

    fn run(job: *Job) void {
        defer job.deinit();
        const outcome: Outcome = if (job.paint()) |exact| .{ .copied = .{ .exact = exact } } else |err| .{ .failed = @errorName(err) };
        job.loop.postEvent(.{ .screenshot = outcome }) catch {};
    }

    fn paint(job: *Job) !bool {
        if (builtin.os.tag != .macos) return error.Unsupported;
        ghostty_font.setIo(job.io);
        var font_config = job.config.font;
        const fetched = fetchDefaultFont(job.gpa, job.io, job.environ);
        defer if (fetched) |f| {
            job.gpa.free(f.regular);
            job.gpa.free(f.italic);
        };
        font_config.default_font = fetched;
        var fonts = try coretext.Fonts.init(job.gpa, font_config, job.cell_width, job.cell_height);
        defer fonts.deinit();
        const picture = try raster.paint(job.gpa, job.frame, fonts.metrics, fonts.text(), .{ .padding = 2 * fonts.metrics.cell_width });
        defer picture.deinit(job.gpa);
        const png = try raster.encodePng(job.gpa, picture, fonts.scale);
        defer job.gpa.free(png);
        if (job.file) |path| {
            try Io.Dir.cwd().writeFile(job.io, .{ .sub_path = path, .data = png });
        } else {
            try copyToClipboard(job.gpa, job.io, png, job.tmp);
        }
        return fonts.exact_grid and fetched != null;
    }
};

/// Ghostty's default font from the cache, downloading it the first time;
/// null when it cannot be had (offline, say).
fn fetchDefaultFont(gpa: std.mem.Allocator, io: Io, environ: ?*const std.process.Environ.Map) ?coretext.DefaultFont {
    if (builtin.os.tag != .macos) return null;
    const env = environ orelse return null;
    var bytes: [2]?[]u8 = .{ null, null };
    for (default_font, &bytes) |spec, *out| {
        var progress: asset_store.Progress = .{};
        const path = asset_store.cachePath(gpa, env, spec) catch break;
        defer gpa.free(path);
        out.* = asset_store.acquireAt(gpa, io, spec, path, &progress) catch |err| {
            std.log.scoped(.screenshot).warn("could not fetch {s}: {t}", .{ spec.filename, err });
            break;
        };
    }
    if (bytes[0] != null and bytes[1] != null) return .{ .regular = bytes[0].?, .italic = bytes[1].? };
    for (bytes) |b| if (b) |owned| gpa.free(owned);
    return null;
}

/// Rows `top..end` of `screen` as cells to paint, in the terminal's
/// colors, styled the way Ghostty styles them.
pub fn frameFrom(arena: std.mem.Allocator, screen: *const vaxis.Screen, top: usize, end: usize, colors: Colors, config: GhosttyConfig) !raster.Frame {
    const cols: u16 = screen.width;
    const rows: u16 = @intCast(end - top);
    const cells = try arena.alloc(raster.Cell, @as(usize, cols) * rows);
    const faint: u8 = @intFromFloat(@round(std.math.clamp(config.faint_opacity, 0, 1) * 255));
    for (0..rows) |r| {
        var col: usize = 0;
        while (col < cols) {
            const out = &cells[r * cols + col];
            const cell = screen.readCell(@intCast(col), @intCast(top + r)) orelse {
                out.* = .{ .fg = colors.fg, .bg = colors.bg };
                col += 1;
                continue;
            };
            const style = cell.style;
            var fg = resolve(style.fg, colors, colors.fg);
            var bg = resolve(style.bg, colors, colors.bg);
            if (style.reverse) std.mem.swap([3]u8, &fg, &bg);
            const grapheme = cell.char.grapheme;
            const measured: usize = if (cell.char.width > 0) cell.char.width else render.displayWidth(grapheme);
            const width: usize = std.math.clamp(measured, 1, 2);
            out.* = .{
                .text = if (style.invisible or std.mem.eql(u8, grapheme, " ")) "" else try arena.dupe(u8, grapheme),
                .width = @intCast(width),
                .fg = fg,
                .bg = bg,
                .alpha = if (style.dim) faint else 255,
                .bold = style.bold,
                .italic = style.italic,
                .strikethrough = style.strikethrough,
                .underline = switch (style.ul_style) {
                    .off => .none,
                    .single => .single,
                    .double => .double,
                    .curly => .curly,
                    .dotted => .dotted,
                    .dashed => .dashed,
                },
                .underline_color = switch (style.ul) {
                    .default => null,
                    else => resolve(style.ul, colors, fg),
                },
            };
            // The tail of a wide grapheme: nothing of its own.
            for (1..width) |k| if (col + k < cols) {
                cells[r * cols + col + k] = .{ .width = 0, .fg = fg, .bg = bg };
            };
            col += width;
        }
    }
    const cursor: ?raster.Cursor = if (screen.cursor_vis and screen.cursor.row >= top and screen.cursor.row < end and screen.cursor.col < cols) .{
        .col = @intCast(screen.cursor.col),
        .row = @intCast(screen.cursor.row - top),
        .style = switch (screen.cursor_shape) {
            .default => config.cursor_style,
            .block, .block_blink => .block,
            .underline, .underline_blink => .underline,
            .beam, .beam_blink => .bar,
        },
        .color = config.cursor_color,
        .text = config.cursor_text,
    } else null;
    return .{ .cols = cols, .rows = rows, .cells = cells, .background = colors.bg, .cursor = cursor };
}

/// The shell's Kitty images as the host terminal shows them: each crop
/// scaled into its cell box, copied out as RGBA.
fn imagesFrom(arena: std.mem.Allocator, app: *App, top: usize, end: usize, cell_width: u32, cell_height: u32) ![]const raster.Image {
    const covered = app.picker != null or app.top_view != null or app.shortcut_help;
    if (covered) return &.{};
    const wants = try shell_tab.imageWants(app, arena);
    var images: std.ArrayList(raster.Image) = .empty;
    for (wants) |want| {
        if (want.row < top or want.row >= end) continue;
        const rgba = try rgbaFrom(arena, want.image) orelse continue;
        try images.append(arena, .{
            .pixels = rgba,
            .width = want.image.width,
            .height = want.image.height,
            .src_x = want.source.x,
            .src_y = want.source.y,
            .src_width = @min(want.source.width, want.image.width -| want.source.x),
            .src_height = @min(want.source.height, want.image.height -| want.source.y),
            .x = @intCast(@as(u32, want.col) * cell_width + want.x_offset),
            .y = @intCast(@as(u32, want.row - @as(u16, @intCast(top))) * cell_height + want.y_offset),
            .dst_width = @as(u32, want.cols) * cell_width,
            .dst_height = @as(u32, want.rows) * cell_height,
        });
    }
    return images.items;
}

fn rgbaFrom(arena: std.mem.Allocator, image: *const vt.kitty.graphics.Image) !?[]const u8 {
    const data = image.data.bytes() orelse return null;
    const n = @as(usize, image.width) * image.height;
    const out = try arena.alloc(u8, n * 4);
    switch (image.format) {
        .rgba => {
            if (data.len < n * 4) return null;
            @memcpy(out, data[0 .. n * 4]);
        },
        .rgb => {
            if (data.len < n * 3) return null;
            for (0..n) |i| out[i * 4 ..][0..4].* = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        },
        .gray => {
            if (data.len < n) return null;
            for (0..n) |i| out[i * 4 ..][0..4].* = .{ data[i], data[i], data[i], 255 };
        },
        .gray_alpha => {
            if (data.len < n * 2) return null;
            for (0..n) |i| out[i * 4 ..][0..4].* = .{ data[i * 2], data[i * 2], data[i * 2], data[i * 2 + 1] };
        },
        .png => return null,
    }
    return out;
}

fn resolve(color: vaxis.Color, colors: Colors, default: [3]u8) [3]u8 {
    return switch (color) {
        .default => default,
        .index => |index| colors.palette[index],
        .rgb => |rgb| rgb,
    };
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

/// Ghostty's config, from where Ghostty reads it.
pub fn loadGhosttyConfig(arena: std.mem.Allocator, io: Io, home: ?[]const u8) GhosttyConfig {
    const dir = home orelse return .{};
    var text: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ ".config/ghostty/config", "Library/Application Support/com.mitchellh.ghostty/config" }) |rel| {
        const path = std.fs.path.join(arena, &.{ dir, rel }) catch continue;
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch continue;
        text.appendSlice(arena, bytes) catch {};
        text.append(arena, '\n') catch {};
    }
    return parseGhosttyConfig(arena, text.items);
}

/// The keys of Ghostty's config that screenshots honor. Repeatable keys
/// accumulate; an empty value resets them, as in Ghostty.
pub fn parseGhosttyConfig(arena: std.mem.Allocator, config_text: []const u8) GhosttyConfig {
    var config: GhosttyConfig = .{};
    const Lists = struct {
        family: std.ArrayList([]const u8) = .empty,
        bold: std.ArrayList([]const u8) = .empty,
        italic: std.ArrayList([]const u8) = .empty,
        bold_italic: std.ArrayList([]const u8) = .empty,
        features: std.ArrayList([]const u8) = .empty,
    };
    var lists: Lists = .{};
    var lines = std.mem.splitScalar(u8, config_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, std.mem.trim(u8, line[eq + 1 ..], " \t"), "\"");
        const list: ?*std.ArrayList([]const u8) = if (std.mem.eql(u8, key, "font-family"))
            &lists.family
        else if (std.mem.eql(u8, key, "font-family-bold"))
            &lists.bold
        else if (std.mem.eql(u8, key, "font-family-italic"))
            &lists.italic
        else if (std.mem.eql(u8, key, "font-family-bold-italic"))
            &lists.bold_italic
        else if (std.mem.eql(u8, key, "font-feature"))
            &lists.features
        else
            null;
        if (list) |l| {
            if (value.len == 0) l.clearRetainingCapacity() else l.append(arena, value) catch {};
            continue;
        }
        if (std.mem.eql(u8, key, "faint-opacity")) {
            config.faint_opacity = std.fmt.parseFloat(f64, value) catch config.faint_opacity;
        } else if (std.mem.eql(u8, key, "cursor-color")) {
            config.cursor_color = parseColor(value);
        } else if (std.mem.eql(u8, key, "cursor-text")) {
            config.cursor_text = parseColor(value);
        } else if (std.mem.eql(u8, key, "cursor-style")) {
            if (std.mem.eql(u8, value, "bar")) config.cursor_style = .bar;
            if (std.mem.eql(u8, value, "underline")) config.cursor_style = .underline;
            if (std.mem.eql(u8, value, "block")) config.cursor_style = .block;
            if (std.mem.eql(u8, value, "block_hollow")) config.cursor_style = .hollow;
        } else if (builtin.os.tag == .macos) {
            if (std.mem.eql(u8, key, "font-size")) {
                config.font.size = std.fmt.parseFloat(f64, value) catch config.font.size;
            } else if (std.mem.eql(u8, key, "font-thicken")) {
                config.font.font_thicken = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "font-thicken-strength")) {
                config.font.font_thicken_strength = std.fmt.parseInt(u8, value, 10) catch config.font.font_thicken_strength;
            }
        }
    }
    if (builtin.os.tag == .macos) {
        config.font.family = lists.family.items;
        config.font.family_bold = lists.bold.items;
        config.font.family_italic = lists.italic.items;
        config.font.family_bold_italic = lists.bold_italic.items;
        config.font.features = lists.features.items;
    }
    return config;
}

fn parseColor(value: []const u8) ?[3]u8 {
    const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
    if (hex.len != 6) return null;
    var out: [3]u8 = undefined;
    for (&out, 0..) |*c, i| c.* = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return null;
    return out;
}

/// Put `png` on the pasteboard through a JXA script; blocking, so callers
/// use a thread.
pub fn copyToClipboard(gpa: std.mem.Allocator, io: Io, png: []const u8, tmp_dir: []const u8) !void {
    var name_buf: [64]u8 = undefined;
    var random: [8]u8 = undefined;
    io.random(&random);
    const name = try std.fmt.bufPrint(&name_buf, "marlin-shot-{x}.png", .{std.mem.readInt(u64, &random, .little)});
    const path = try std.fs.path.join(gpa, &.{ tmp_dir, name });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", clipboard_script, path },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.scoped(.screenshot).warn("osascript failed: {s}", .{result.stderr});
            return error.ClipboardFailed;
        },
        else => return error.ClipboardFailed,
    }
}

const clipboard_script =
    \\ObjC.import('AppKit');
    \\function run(argv) {
    \\  var png = $.NSData.dataWithContentsOfFile(argv[0]);
    \\  if (png.isNil()) throw new Error('no image');
    \\  var pb = $.NSPasteboard.generalPasteboard;
    \\  pb.clearContents;
    \\  pb.setDataForType(png, 'public.png');
    \\}
;
