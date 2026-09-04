//! Pixel effects: RGB framebuffers shipped through the Kitty graphics
//! protocol. The demoscene scenes were validated standalone in
//! scripts/kitty-pixel-probe.zig (15–60 fps sweeps) and moved here so they
//! are screensavers, not a probe; Pac-Man's board lives in pacman.zig and is
//! rasterized here.
//!
//! Transport: each tick's frame is transmitted as a new image (`a=t`, 4 KiB
//! chunks, `q=2` so the terminal does not answer every frame, `o=z` zlib when
//! that is smaller — the maze compresses ~50×, which is what pays for its
//! resolution) with an id from vaxis' counter, then placed through the cell grid with `Image.draw(.fill)`
//! so vaxis' render() emits the placement in the same synchronized update as
//! the cells. The previous image is freed at the start of the next transmit,
//! so the screen never lacks an image. Placements use the default z-index
//! (above text): terminals disagree on whether negative z sits above or
//! below an explicit cell background, and the effect is opaque anyway.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");
const visual_effect = @import("../core/visual_effect.zig");
const pacman = @import("pacman.zig");
const shadowbox = @import("shadowbox.zig");

pub const Scene = enum { plasma, tunnel, metaballs, horizon };

/// Framebuffer resolution is decoupled from the terminal's pixel size: the
/// terminal scales the image to the window (`.fill`), and encoding cost is
/// what bounds frame rate. 400×N at 30 fps is ~400 KiB/s of base64.
const max_width: u32 = 400;
const min_width: u32 = 160;
/// Assumed cell aspect when the terminal does not report pixel sizes.
const default_cell_w: u32 = 8;
const default_cell_h: u32 = 16;
const fps: u16 = 30;

pub const Engine = struct {
    gpa: std.mem.Allocator,
    kind: visual_effect.Kind,
    cols: u16 = 0,
    rows: u16 = 0,
    cell_px_w: u32 = default_cell_w,
    cell_px_h: u32 = default_cell_h,
    width: u16 = 0,
    height: u16 = 0,
    frame: u64 = 0,
    seed_offset: u64 = 0,
    rgb: []u8 = &.{},
    scratch: []u8 = &.{},
    encoded: []u8 = &.{},
    /// The image transmitted for the CURRENT frame (placed by draw).
    image: ?vaxis.Image = null,
    /// Last frame's image, freed at the start of the next transmit.
    previous_id: ?u32 = null,
    /// The tick `image` was rendered for; renders between ticks reuse it.
    transmitted_frame: ?u64 = null,
    /// Ship every Nth tick; very large boards use 2 so deflate stays cheap.
    transmit_every: u8 = 1,
    seed: u64 = 1,
    /// Where the sun and moon stand; the shadow-box follows it. Set by the
    /// TUI before each transmit.
    sky: shadowbox.Sky = shadowbox.Sky.noon,
    /// Board state for the pacman kind (unused otherwise), its cached
    /// background (per maze generation), zlib output, and the compressor's
    /// window.
    game: pacman.Game,
    background: []u8 = &.{},
    background_generation: u64 = 0,
    zbuf: []u8 = &.{},
    window: []u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, kind: visual_effect.Kind, seed: u64) Engine {
        return .{ .gpa = gpa, .kind = kind, .seed = seed, .seed_offset = effect.hash(seed) % 600, .game = pacman.Game.init(seed) };
    }

    pub fn deinit(self: *Engine) void {
        self.freeBuffers();
        self.* = undefined;
    }

    fn freeBuffers(self: *Engine) void {
        if (self.rgb.len > 0) self.gpa.free(self.rgb);
        if (self.scratch.len > 0) self.gpa.free(self.scratch);
        if (self.encoded.len > 0) self.gpa.free(self.encoded);
        if (self.background.len > 0) self.gpa.free(self.background);
        if (self.zbuf.len > 0) self.gpa.free(self.zbuf);
        if (self.window.len > 0) self.gpa.free(self.window);
        self.rgb = &.{};
        self.scratch = &.{};
        self.encoded = &.{};
        self.background = &.{};
        self.zbuf = &.{};
        self.window = &.{};
    }

    pub fn setSky(self: *Engine, sky: shadowbox.Sky) void {
        self.sky = sky;
    }

    pub fn setCellPixels(self: *Engine, w: u32, h: u32) void {
        if (w > 0 and h > 0) {
            self.cell_px_w = w;
            self.cell_px_h = h;
        }
    }

    pub fn reset(self: *Engine, cols: u16, rows: u16, seed: u64) !void {
        self.frame = 0;
        self.transmitted_frame = null;
        self.seed = seed;
        self.seed_offset = effect.hash(seed) % 600;
        try self.resize(cols, rows);
        if (self.kind == .pacman) self.game.reset(seed);
    }

    pub fn resize(self: *Engine, cols: u16, rows: u16) !void {
        self.cols = cols;
        self.rows = rows;
        if (self.kind == .pacman) {
            // The maze is shaped for the window; a new shape is a new board.
            const layout = pacman.layoutForAspect(@as(u32, @max(cols, 1)) * self.cell_px_w, @as(u32, @max(rows, 1)) * self.cell_px_h);
            if (layout.cols != self.game.cols or layout.rows != self.game.rows) self.game.configure(layout.cols, layout.rows);
        }
        const dims = framebufferSize(cols, rows, self.cell_px_w, self.cell_px_h, self.kind);
        if (dims.width == self.width and dims.height == self.height and self.rgb.len > 0) return;
        self.freeBuffers();
        self.width = dims.width;
        self.height = dims.height;
        const pixels = @as(usize, self.width) * self.height;
        self.rgb = try self.gpa.alloc(u8, pixels * 3);
        errdefer self.gpa.free(self.rgb);
        self.scratch = try self.gpa.alloc(u8, pixels * 3);
        errdefer self.gpa.free(self.scratch);
        self.encoded = try self.gpa.alloc(u8, std.base64.standard.Encoder.calcSize(pixels * 3));
        errdefer self.gpa.free(self.encoded);
        if (self.kind == .pacman) {
            self.background = try self.gpa.alloc(u8, pixels * 3);
            errdefer self.gpa.free(self.background);
            self.background_generation = 0;
        }
        if (compressible(self.kind)) {
            self.zbuf = try self.gpa.alloc(u8, pixels * 3 + 4096);
            errdefer self.gpa.free(self.zbuf);
            self.window = try self.gpa.alloc(u8, 2 * std.compress.flate.max_window_len);
        }
        self.transmit_every = shipEvery(self.kind, pixels);
    }

    /// Flat or smooth art that zlib pays for; the noisy demoscene scenes are
    /// sent raw.
    fn compressible(kind: visual_effect.Kind) bool {
        return kind == .pacman or kind == .shadowbox;
    }

    /// Ticks per shipped frame. The shadow-box ran at 20 fps in the browser
    /// and its zlib frames are the largest, so 15 fps; very large boards
    /// also halve to keep deflate off the critical path.
    fn shipEvery(kind: visual_effect.Kind, pixels: usize) u8 {
        if (kind == .shadowbox) return 2;
        return if (pixels > 700_000) 2 else 1;
    }

    pub fn tick(self: *Engine) void {
        self.frame +%= 1;
        if (self.kind == .pacman) self.game.tick();
    }

    /// Render this tick's frame and ship it. Must run before draw() so the
    /// placement refers to the current image. Renders between ticks (a key,
    /// a daemon event) reuse the image already in the terminal. The caller
    /// handles NoGraphicsCapability by falling back to a cell effect.
    pub fn transmit(self: *Engine, vx: *vaxis.Vaxis, tty: *std.Io.Writer) !void {
        if (!vx.caps.kitty_graphics) return error.NoGraphicsCapability;
        if (self.rgb.len == 0) try self.resize(self.cols, self.rows);
        if (self.image != null and (self.transmitted_frame == self.frame or self.frame % self.transmit_every != 0)) return;
        // The image placed LAST tick is on screen; freeing it now (before the
        // new transmit) never leaves a blank frame, and keeps terminal memory
        // at two images.
        if (self.previous_id) |id| {
            freeImage(tty, id);
            self.previous_id = null;
        }
        const frame = self.frame + self.seed_offset;
        switch (self.kind) {
            .demo => renderDemo(self.rgb, self.scratch, self.width, self.height, frame),
            .tunnel => renderScene(.tunnel, self.rgb, self.width, self.height, frame),
            .metaballs => renderScene(.metaballs, self.rgb, self.width, self.height, frame),
            .horizon => renderScene(.horizon, self.rgb, self.width, self.height, frame),
            .shadowbox => shadowbox.render(self.rgb, self.width, self.height, self.frame, self.seed, self.sky),
            .pacman => {
                if (self.background_generation != self.game.generation) {
                    pacman.renderBackground(&self.game, self.background, self.width, self.height);
                    self.background_generation = self.game.generation;
                }
                pacman.renderPixels(&self.game, self.rgb, self.background, self.width, self.height);
            },
            else => renderScene(.plasma, self.rgb, self.width, self.height, frame),
        }
        var payload: []const u8 = self.rgb;
        var compressed = false;
        if (self.zbuf.len > 0) {
            if (deflate(self.zbuf, self.window, self.rgb)) |z| {
                if (z.len < self.rgb.len) {
                    payload = z;
                    compressed = true;
                }
            }
        }
        const encoded = std.base64.standard.Encoder.encode(self.encoded, payload);
        const id = vx.next_img_id;
        vx.next_img_id += 1;
        try transmitEncoded(tty, encoded, id, self.width, self.height, compressed);
        if (self.image) |old| self.previous_id = old.id;
        self.image = vaxis.Image.init(id, self.width, self.height);
        self.transmitted_frame = self.frame;
    }

    /// Drop the current image from the terminal (effect ended).
    pub fn release(self: *Engine, vx: *vaxis.Vaxis, tty: *std.Io.Writer) void {
        _ = vx;
        if (self.previous_id) |id| {
            freeImage(tty, id);
            self.previous_id = null;
        }
        if (self.image) |img| {
            freeImage(tty, img.id);
            self.image = null;
        }
        self.transmitted_frame = null;
    }

    pub fn hasImage(self: *const Engine) bool {
        return self.image != null or self.previous_id != null;
    }

    /// Place the current frame over the whole window (opaque by nature; the
    /// mode/opacity contract of cell effects does not apply).
    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        _ = mode;
        _ = opacity;
        effect.prepare(win, .full_screen);
        win.hideCursor();
        if (self.image) |img| img.draw(win, .{ .scale = .fill }) catch {};
    }
};

/// Kitty `a=t` transmit of a base64 RGB frame (zlib-compressed when
/// `compressed`) in 4 KiB chunks; `q=2` keeps the terminal from answering.
/// The placement comes from vaxis' render().
fn transmitEncoded(tty: *std.Io.Writer, encoded: []const u8, id: u32, width: u16, height: u16, compressed: bool) !void {
    const chunk: usize = 4096;
    const first_end: usize = @min(chunk, encoded.len);
    const more: u1 = if (first_end < encoded.len) 1 else 0;
    try tty.print(
        "\x1b_Ga=t,f=24,s={d},v={d},i={d},q=2{s},m={d};{s}\x1b\\",
        .{ width, height, id, if (compressed) ",o=z" else "", more, encoded[0..first_end] },
    );
    var offset: usize = first_end;
    while (offset < encoded.len) {
        const end: usize = @min(offset + chunk, encoded.len);
        const m: u1 = if (end < encoded.len) 1 else 0;
        try tty.print("\x1b_Gm={d};{s}\x1b\\", .{ m, encoded[offset..end] });
        offset = end;
    }
    try tty.flush();
}

fn freeImage(tty: *std.Io.Writer, id: u32) void {
    tty.print("\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{id}) catch {};
}

/// zlib-compress `src` into `dst` (fastest level); null when it does not fit.
fn deflate(dst: []u8, window: []u8, src: []const u8) ?[]u8 {
    var out: std.Io.Writer = .fixed(dst);
    var c = std.compress.flate.Compress.init(&out, window, .zlib, .fastest) catch return null;
    c.writer.writeAll(src) catch return null;
    c.finish() catch return null;
    return out.buffered();
}

pub const Dimensions = struct { width: u16, height: u16 };

/// Pick a framebuffer whose aspect matches the window's pixel aspect, with
/// the width clamped into the band that keeps 30 fps encoding cheap. The
/// maze wants vertical resolution (30 board rows), so it sizes from height.
pub fn framebufferSize(cols: u16, rows: u16, cell_px_w: u32, cell_px_h: u32, kind: visual_effect.Kind) Dimensions {
    const c: u32 = @max(cols, 1);
    const r: u32 = @max(rows, 1);
    const win_w = c * cell_px_w;
    const win_h = r * cell_px_h;
    if (kind == .shadowbox) {
        // A 1900×900 canvas stretched to the viewport in the original: render
        // near the window's own pixel size, capped to keep zlib frames cheap.
        var width: u32 = std.math.clamp(win_w, 480, 960);
        var height: u32 = @max(width * win_h / @max(win_w, 1), 32);
        if (height > 540) {
            height = 540;
            width = @max(height * win_w / @max(win_h, 1), 64);
        }
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }
    if (kind == .pacman) {
        // Up to 16 px per maze tile; the maze is centered in a framebuffer of
        // the window's aspect (letterboxed, so `.fill` never stretches it).
        const layout = pacman.layoutForAspect(win_w, win_h);
        const t: u32 = std.math.clamp(@min(1600 / @as(u32, layout.cols), 720 / @as(u32, layout.rows)), 4, 16);
        const height: u32 = @as(u32, layout.rows) * t;
        const by_aspect: u32 = height * win_w / @max(win_h, 1);
        const width: u32 = std.math.clamp(by_aspect, @as(u32, layout.cols) * t, 1600);
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }
    const width: u32 = @min(max_width, @max(min_width, c * 3));
    var height: u32 = width * win_h / @max(win_w, 1);
    height = @max(height, 32);
    return .{ .width = @intCast(width), .height = @intCast(@min(height, 720)) };
}

// ------------------------------------------------------------- scenes --

pub fn renderDemo(rgb: []u8, scratch: []u8, width: u16, height: u16, frame: u64) void {
    const scene_frames = @as(u64, fps) * 6;
    const transition_frames = @as(u64, fps);
    const scene_index: u2 = @intCast((frame / scene_frames) % 4);
    const local_frame = frame % scene_frames;
    const scene: Scene = @enumFromInt(scene_index);
    renderScene(scene, rgb, width, height, frame);

    const transition_start = scene_frames - transition_frames;
    if (local_frame < transition_start) return;
    const next_index: u8 = (@as(u8, scene_index) + 1) % 4;
    const next: Scene = @enumFromInt(next_index);
    renderScene(next, scratch, width, height, frame);
    const linear = @as(f32, @floatFromInt(local_frame - transition_start)) / @as(f32, @floatFromInt(transition_frames));
    const mix = linear * linear * (3.0 - 2.0 * linear);
    blendFrames(rgb, scratch, mix);
}

pub fn renderScene(scene: Scene, rgb: []u8, width: u16, height: u16, frame: u64) void {
    switch (scene) {
        .plasma => renderPlasma(rgb, width, height, frame),
        .tunnel => renderTunnel(rgb, width, height, frame),
        .metaballs => renderMetaballs(rgb, width, height, frame),
        .horizon => renderHorizon(rgb, width, height, frame),
    }
}

fn renderPlasma(rgb: []u8, width: u16, height: u16, frame: u64) void {
    const time = seconds(frame);
    const center_x = @as(f32, @floatFromInt(width)) * 0.5;
    const center_y = @as(f32, @floatFromInt(height)) * 0.5;
    var y: u16 = 0;
    var offset: usize = 0;
    while (y < height) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y));
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f32, @floatFromInt(x));
            const dx = (xf - center_x) / center_x;
            const dy = (yf - center_y) / center_y;
            const radial = @sqrt(dx * dx + dy * dy);
            const value = @sin(xf * 0.035 + time * 2.1) +
                @sin(yf * 0.052 - time * 1.7) +
                @sin((dx + dy) * 7.0 + time) +
                @sin(radial * 12.0 - time * 2.4);
            const phase = (value + 4.0) / 8.0 * std.math.tau;
            rgb[offset] = colorChannel(@sin(phase));
            rgb[offset + 1] = colorChannel(@sin(phase + 2.094));
            rgb[offset + 2] = colorChannel(@sin(phase + 4.188));
            offset += 3;
        }
    }
}

fn renderTunnel(rgb: []u8, width: u16, height: u16, frame: u64) void {
    const time = seconds(frame);
    const center_x = @as(f32, @floatFromInt(width)) * 0.5 + @sin(time * 0.7) * 24.0;
    const center_y = @as(f32, @floatFromInt(height)) * 0.5 + @cos(time * 0.9) * 14.0;
    const scale = @as(f32, @floatFromInt(height));
    var y: u16 = 0;
    var offset: usize = 0;
    while (y < height) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y));
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f32, @floatFromInt(x));
            const dx = (xf - center_x) / scale;
            const dy = (yf - center_y) / scale;
            const distance = @sqrt(dx * dx + dy * dy) + 0.025;
            const angle = std.math.atan2(dy, dx);
            const depth = 0.55 / distance + time * 1.8;
            const spiral = angle * 4.0 + depth * 1.7 + @sin(depth * 0.45);
            const bands = @sin(depth * 7.0) * 0.55 + @sin(spiral * 2.0) * 0.45;
            const glow = @min(1.0, 0.08 / distance);
            const phase = spiral + bands * 1.4;
            rgb[offset] = unitChannel(0.13 + glow * 0.8 + (@sin(phase) * 0.5 + 0.5) * 0.24);
            rgb[offset + 1] = unitChannel(0.02 + glow * 0.22 + (@sin(phase + 2.1) * 0.5 + 0.5) * 0.18);
            rgb[offset + 2] = unitChannel(0.22 + glow * 0.65 + (@sin(phase + 4.2) * 0.5 + 0.5) * 0.42);
            offset += 3;
        }
    }
}

fn renderMetaballs(rgb: []u8, width: u16, height: u16, frame: u64) void {
    const time = seconds(frame);
    const w = @as(f32, @floatFromInt(width));
    const h = @as(f32, @floatFromInt(height));
    const centers = [5][3]f32{
        .{ w * 0.50 + @sin(time * 1.3) * w * 0.23, h * 0.50 + @cos(time * 0.9) * h * 0.27, h * 0.22 },
        .{ w * 0.50 + @cos(time * 0.7 + 1.4) * w * 0.29, h * 0.50 + @sin(time * 1.1) * h * 0.31, h * 0.19 },
        .{ w * 0.50 + @sin(time * 0.8 + 3.1) * w * 0.34, h * 0.50 + @cos(time * 1.4 + 0.8) * h * 0.22, h * 0.17 },
        .{ w * 0.50 + @cos(time * 1.5 + 4.2) * w * 0.20, h * 0.50 + @sin(time * 0.6 + 2.0) * h * 0.36, h * 0.15 },
        .{ w * 0.50 + @sin(time * 1.0 + 5.0) * w * 0.27, h * 0.50 + @sin(time * 1.7 + 4.0) * h * 0.18, h * 0.13 },
    };
    var y: u16 = 0;
    var offset: usize = 0;
    while (y < height) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y));
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f32, @floatFromInt(x));
            var field: f32 = 0;
            for (centers) |ball| {
                const dx = xf - ball[0];
                const dy = yf - ball[1];
                field += ball[2] * ball[2] / (dx * dx + dy * dy + 18.0);
            }
            const edge = smoothstep(0.72, 1.12, field);
            const inner = smoothstep(1.05, 2.8, field);
            const shimmer = @sin(field * 4.5 - time * 2.0) * 0.5 + 0.5;
            rgb[offset] = unitChannel(0.015 + edge * (0.55 + inner * 0.4));
            rgb[offset + 1] = unitChannel(0.025 + edge * (0.08 + shimmer * 0.28));
            rgb[offset + 2] = unitChannel(0.07 + edge * (0.55 + (1.0 - inner) * 0.35));
            offset += 3;
        }
    }
}

fn renderHorizon(rgb: []u8, width: u16, height: u16, frame: u64) void {
    const time = seconds(frame);
    const w = @as(f32, @floatFromInt(width));
    const h = @as(f32, @floatFromInt(height));
    const horizon = h * 0.52;
    const sun_x = w * 0.5 + @sin(time * 0.22) * w * 0.08;
    const sun_y = h * 0.30;
    const sun_radius = h * 0.22;
    var y: u16 = 0;
    var offset: usize = 0;
    while (y < height) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y));
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f32, @floatFromInt(x));
            var red: f32 = 0.015;
            var green: f32 = 0.008;
            var blue: f32 = 0.055 + (1.0 - yf / h) * 0.08;

            const sun_dx = xf - sun_x;
            const sun_dy = yf - sun_y;
            const sun_distance = @sqrt(sun_dx * sun_dx + sun_dy * sun_dy);
            if (sun_distance < sun_radius and yf < horizon) {
                const sun = 1.0 - sun_distance / sun_radius;
                const stripe = @sin((yf - sun_y) * 0.42 + time * 1.4);
                const stripe_mask: f32 = if (stripe > -0.35) 1.0 else 0.18;
                red += (0.75 + sun * 0.25) * stripe_mask;
                green += (0.08 + sun * 0.35) * stripe_mask;
                blue += (0.20 + sun * 0.24) * stripe_mask;
            }

            if (yf >= horizon) {
                const depth = (yf - horizon + 1.0) / (h - horizon);
                const perspective = 1.0 / depth;
                const scroll = time * 1.7;
                const horizontal = @abs(@sin((perspective * 1.15 - scroll) * std.math.pi));
                const spread = (xf - w * 0.5) * depth * 0.11;
                const vertical = @abs(@sin(spread * std.math.pi));
                const grid = @max(smoothstep(0.86, 1.0, horizontal), smoothstep(0.90, 1.0, vertical));
                const fade = depth * depth;
                red += grid * fade * 0.72;
                green += grid * fade * 0.08;
                blue += grid * fade * 0.82;
            } else {
                const ridge = horizon - 8.0 - @sin(xf * 0.035 + time * 0.4) * 7.0 - @sin(xf * 0.081 - time * 0.7) * 3.5;
                if (yf > ridge) {
                    red *= 0.25;
                    green *= 0.2;
                    blue *= 0.32;
                }
            }
            rgb[offset] = unitChannel(red);
            rgb[offset + 1] = unitChannel(green);
            rgb[offset + 2] = unitChannel(blue);
            offset += 3;
        }
    }
}

fn blendFrames(destination: []u8, source: []const u8, mix: f32) void {
    const keep = 1.0 - mix;
    for (destination, source) |*dst, src| {
        dst.* = @intFromFloat(@as(f32, @floatFromInt(dst.*)) * keep + @as(f32, @floatFromInt(src)) * mix);
    }
}

fn seconds(frame: u64) f32 {
    return @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(fps));
}

fn smoothstep(low: f32, high: f32, value: f32) f32 {
    const t = std.math.clamp((value - low) / (high - low), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn colorChannel(value: f32) u8 {
    return unitChannel(value * 0.5 + 0.5);
}

fn unitChannel(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0);
}
