//! Pixel effects: RGB framebuffers shipped through the Kitty graphics
//! protocol. The demoscene scenes were validated standalone in
//! scripts/kitty-pixel-probe.zig (15–60 fps sweeps) and moved here so they
//! are screensavers, not a probe; Pac-Man's board lives in pacman.zig and is
//! rasterized here.
//!
//! Transport: the probe's, which has survived every stress run a terminal
//! has been put through. Each shipped frame is one Kitty `a=T`
//! (transmit-and-display) under a fixed per-kind image id and placement id
//! (`p=1`, so the terminal replaces the placement; without one every
//! display mints another, and a 60 fps game piles up thousands the terminal
//! draws each frame), placed at the effect's rectangle with `c=,r=` so the
//! terminal scales it, `q=2` so it does not answer, `o=z` zlib when
//! smaller, 4 KiB chunks. The bytes come from wipeout/kitty_transport.zig,
//! which the probe's `--client-transport` shares. vaxis is kept
//! out of graphics entirely (the TUI clears `caps.kitty_graphics` after
//! the query): its render used to delete every placement and re-place the
//! image on each redraw, so a game tick or a held key re-placed an image
//! that had not been retransmitted, sixty-odd times a second — the one
//! shape of traffic the surviving probe stream never carried, and the
//! leading suspect for Ghostty 1.3.1 dying under marlin and only marlin.
//! A wire budget (`wire_budget_bytes_per_second`, `MARLIN_WIRE_BUDGET`)
//! stretches each effect's ship interval from the size of its last frame.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");
const visual_effect = @import("../core/visual_effect.zig");
const pacman = @import("pacman.zig");
const tetris = @import("tetris.zig");
const daybreak = @import("daybreak.zig");
const orb = @import("orb.zig");
const wipeout_effect = @import("wipeout_effect.zig");
const kitty = @import("../wipeout/kitty_transport.zig");

pub const Scene = enum { plasma, tunnel, metaballs, horizon };

/// Framebuffer resolution is decoupled from the terminal's pixel size: the
/// terminal scales the image to the window (`.fill`). The demoscene scenes
/// stay within the 320×180 envelope the probe validated in real terminals;
/// with zlib and the wire budget that lands near 15 fps.
const max_width: u32 = 320;
const min_width: u32 = 160;
/// Assumed cell aspect when the terminal does not report pixel sizes.
const default_cell_w: u32 = 8;
const default_cell_h: u32 = 16;
const fps: u16 = 30;
/// Threads for the banded zlib encoder on large framebuffers.
const parallel_zlib_bands: usize = 6;

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
    /// Whether the terminal takes Kitty graphics at all (the TUI decides
    /// from its capability query; vaxis' own flag is deliberately off).
    graphics: bool = false,
    /// Bytes the last shipped frame put on the wire; drives the budget.
    last_frame_bytes: usize = 0,
    /// The tick `image` was rendered for; renders between ticks reuse it.
    transmitted_frame: ?u64 = null,
    /// Ship every Nth tick; very large boards use 2 so deflate stays cheap.
    transmit_every: u8 = 1,
    seed: u64 = 1,
    /// Where the sun and moon stand; daybreak follows it. Set by the
    /// TUI before each transmit.
    sky: daybreak.Sky = daybreak.Sky.noon,
    orb_fg: [3]u8 = orb.default_fg,
    orb_bg: [3]u8 = orb.default_bg,
    /// Board state for the pacman kind (unused otherwise), its cached
    /// background (per maze generation), zlib output, and the compressor's
    /// window.
    game: pacman.Game,
    tetris_game: tetris.Game,
    /// The wipEout race for the wipeout kind. Owned by the App (it outlives
    /// engines so a hidden game resumes); null renders black.
    wipeout_game: ?*wipeout_effect.Game = null,
    background: []u8 = &.{},
    background_generation: u64 = 0,
    zbuf: []u8 = &.{},
    window: []u8 = &.{},
    /// Banded multi-threaded zlib for large frames; null uses the
    /// single-stream compressor.
    par_encoder: ?wipeout_effect.parzlib.Encoder = null,

    pub fn init(gpa: std.mem.Allocator, kind: visual_effect.Kind, seed: u64) Engine {
        return .{ .gpa = gpa, .kind = kind, .seed = seed, .seed_offset = effect.hash(seed) % 600, .game = pacman.Game.init(seed), .tetris_game = tetris.Game.init(seed) };
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
        if (self.par_encoder) |*enc| enc.deinit();
        self.par_encoder = null;
        self.rgb = &.{};
        self.scratch = &.{};
        self.encoded = &.{};
        self.background = &.{};
        self.zbuf = &.{};
        self.window = &.{};
    }

    pub fn setGraphics(self: *Engine, available: bool) void {
        self.graphics = available;
    }

    /// The image id this engine transmits under: fixed per kind, replaced in
    /// place every frame.
    pub fn imageId(kind: visual_effect.Kind) u32 {
        return 0x4d61_7200 + @as(u32, @intFromEnum(kind)); // "Mar" + kind
    }

    /// Where the frame lands, in cells: the whole window, or for wipEout the
    /// largest centered 4:3 rectangle so `.fill` scaling never stretches it.
    pub fn placementBox(self: *const Engine) Letterbox {
        if (self.kind == .wipeout) return letterbox(self.cols, self.rows, self.cell_px_w, self.cell_px_h, 4, 3);
        return .{ .x = 0, .y = 0, .cols = self.cols, .rows = self.rows };
    }

    pub fn setSky(self: *Engine, sky: daybreak.Sky) void {
        self.sky = sky;
    }

    pub fn setOrbColors(self: *Engine, foreground: ?[3]u8, background_color: ?[3]u8) void {
        self.orb_fg = foreground orelse orb.default_fg;
        self.orb_bg = background_color orelse orb.default_bg;
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
        if (self.kind == .tetris) self.tetris_game.reset(seed);
    }

    pub fn resize(self: *Engine, cols: u16, rows: u16) !void {
        self.cols = cols;
        self.rows = rows;
        if (self.kind == .pacman) {
            // The maze is shaped for the window; a new shape is a new board.
            const layout = pacman.layoutForAspect(@as(u32, @max(cols, 1)) * self.cell_px_w, @as(u32, @max(rows, 1)) * self.cell_px_h);
            if (layout.cols != self.game.cols or layout.rows != self.game.rows) self.game.configure(layout.cols, layout.rows);
        }
        var dims = framebufferSize(cols, rows, self.cell_px_w, self.cell_px_h, self.kind);
        if (self.kind == .wipeout) {
            if (self.wipeout_game) |g| {
                const out = g.outputSize();
                dims = .{ .width = out.width, .height = out.height };
            }
        }
        if (dims.width == self.width and dims.height == self.height and self.rgb.len > 0) return;
        self.freeBuffers();
        self.width = dims.width;
        self.height = dims.height;
        const pixels = @as(usize, self.width) * self.height;
        self.rgb = try self.gpa.alloc(u8, pixels * 3);
        errdefer self.gpa.free(self.rgb);
        // Two frames' worth: the orb keeps its sharp particle layer and its
        // blurred bloom side by side while compositing.
        self.scratch = try self.gpa.alloc(u8, pixels * 6);
        errdefer self.gpa.free(self.scratch);
        self.encoded = try self.gpa.alloc(u8, std.base64.standard.Encoder.calcSize(pixels * 3));
        errdefer self.gpa.free(self.encoded);
        if (self.kind == .pacman or self.kind == .orb) {
            self.background = try self.gpa.alloc(u8, pixels * 3);
            errdefer self.gpa.free(self.background);
            self.background_generation = 0;
        }
        // zlib for every kind: flat art shrinks ~50×, gradients a few times,
        // and the noisy scenes simply go raw when that is smaller.
        self.zbuf = try self.gpa.alloc(u8, pixels * 3 + 8192);
        errdefer self.gpa.free(self.zbuf);
        self.window = try self.gpa.alloc(u8, 2 * std.compress.flate.max_window_len);
        // Frames past ~200k pixels are worth splitting across threads;
        // smaller ones finish faster on one.
        if (pixels >= 200_000) self.par_encoder = wipeout_effect.parzlib.Encoder.init(self.gpa, parallel_zlib_bands);
        self.transmit_every = shipEvery(self.kind, pixels);
        if (self.kind == .wipeout) {
            if (self.wipeout_game) |g| self.transmit_every = g.outputSize().ship_every;
        }
        self.last_frame_bytes = 0;
    }

    /// Base ticks per shipped frame, before the wire budget. Daybreak moves
    /// slowly and ships at 10 fps; the orb and wipEout ship every 60 Hz tick;
    /// very large boards halve to keep deflate off the critical path.
    fn shipEvery(kind: visual_effect.Kind, pixels: usize) u8 {
        if (kind == .daybreak) return 3;
        if (kind == .orb) return 1;
        if (kind == .wipeout) return 1;
        return if (pixels > 700_000) 2 else 1;
    }

    /// Ticks per shipped frame after the wire budget: the base rate, stretched
    /// so that the last frame's size times the resulting rate stays under
    /// `wire_budget_bytes_per_second`. Nothing shipped yet means the base.
    pub fn effectiveEvery(self: *const Engine) u8 {
        // Applies to every kind, wipEout included (the game keeps simulating
        // at 60 Hz whatever the shipped rate).
        if (self.last_frame_bytes == 0 or wire_budget_bytes_per_second == 0) return self.transmit_every;
        const rate = tickRate(self.kind);
        const needed = (self.last_frame_bytes * rate + wire_budget_bytes_per_second - 1) / wire_budget_bytes_per_second;
        return @intCast(@min(@max(@as(usize, self.transmit_every), needed), rate));
    }

    /// Re-rasterize the live cell grid into the orb's blurred backdrop so it
    /// follows the transcript instead of freezing at screensaver start. Runs
    /// from draw() while the real UI is still in the window — by transmit
    /// time the cells are already blacked out under the image. A blur needs
    /// no 60 fps: every 20th tick (~3/s) keeps the capture+blur cost noise.
    pub fn refreshBackdrop(self: *Engine, win: vaxis.Window) void {
        if (self.kind != .orb or self.background.len == 0) return;
        if (self.background_generation != 0 and self.frame % 20 != 0) return;
        orb.capture(self.background, self.scratch, self.width, self.height, win, self.orb_fg, self.orb_bg);
        self.background_generation = 1;
    }

    pub fn tick(self: *Engine) void {
        self.frame +%= 1;
        if (self.kind == .pacman) self.game.tick();
        if (self.kind == .tetris) self.tetris_game.tick();
        if (self.kind == .wipeout) {
            if (self.wipeout_game) |g| g.tick();
        }
    }

    /// Render this tick's frame and ship it. Must run before draw() so the
    /// placement refers to the current image. Renders between ticks (a key,
    /// a daemon event) reuse the image already in the terminal. The caller
    /// handles NoGraphicsCapability by falling back to a cell effect.
    pub fn transmit(self: *Engine, vx: *vaxis.Vaxis, tty: *std.Io.Writer) !void {
        if (!self.graphics) return error.NoGraphicsCapability;
        if (self.rgb.len == 0) try self.resize(self.cols, self.rows);
        if (self.kind == .wipeout) {
            if (self.wipeout_game) |g| {
                const out = g.outputSize();
                if (out.width != self.width or out.height != self.height) try self.resize(self.cols, self.rows);
            }
        }
        if (self.image != null and (self.transmitted_frame == self.frame or self.frame % self.effectiveEvery() != 0)) return;
        const frame = self.frame + self.seed_offset;
        switch (self.kind) {
            .demo => renderDemo(self.rgb, self.scratch, self.width, self.height, frame),
            .tunnel => renderScene(.tunnel, self.rgb, self.width, self.height, frame),
            .metaballs => renderScene(.metaballs, self.rgb, self.width, self.height, frame),
            .horizon => renderScene(.horizon, self.rgb, self.width, self.height, frame),
            .daybreak => daybreak.render(self.rgb, self.width, self.height, self.frame, self.seed, self.sky),
            .orb => {
                if (self.background_generation == 0) {
                    orb.capture(self.background, self.scratch, self.width, self.height, vx.window(), self.orb_fg, self.orb_bg);
                    self.background_generation = 1;
                }
                orb.render(self.rgb, self.scratch, self.background, self.width, self.height, self.frame, self.seed);
            },
            .tetris => tetris.renderPixels(&self.tetris_game, self.rgb, self.width, self.height),
            .wipeout => if (self.wipeout_game) |g| g.render(self.rgb, self.width, self.height) else @memset(self.rgb, 0),
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
            const z: ?[]u8 = if (self.par_encoder) |*enc| enc.compress(self.zbuf, self.rgb) else deflate(self.zbuf, self.window, self.rgb);
            if (z) |zz| {
                if (zz.len < self.rgb.len) {
                    payload = zz;
                    compressed = true;
                }
            }
        }
        const encoded = std.base64.standard.Encoder.encode(self.encoded, payload);
        const id = imageId(self.kind);
        // One frame is one synchronized update holding one a=T under this
        // kind's image id and placement id 1: the terminal replaces the
        // placement rather than adding one per frame (kitty_transport.zig).
        const box = self.placementBox();
        try kitty.shipFrame(tty, encoded, id, self.width, self.height, compressed, .{
            .col = @intCast(box.x),
            .row = @intCast(box.y),
            .cols = box.cols,
            .rows = box.rows,
        });
        try tty.flush();
        self.image = vaxis.Image.init(id, self.width, self.height);
        self.transmitted_frame = self.frame;
        self.last_frame_bytes = kitty.wireBytes(encoded.len);
    }

    /// Drop the image from the terminal (effect ended).
    pub fn release(self: *Engine, vx: *vaxis.Vaxis, tty: *std.Io.Writer) void {
        _ = vx;
        if (self.image) |img| {
            kitty.freeImage(tty, img.id) catch {};
            self.image = null;
        }
        self.transmitted_frame = null;
    }

    pub fn hasImage(self: *const Engine) bool {
        return self.image != null;
    }

    /// Place the current frame over the whole window (opaque by nature; the
    /// mode/opacity contract of cell effects does not apply).
    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        _ = mode;
        _ = opacity;
        // Black under the image; the placement itself lives in the terminal
        // from `transmit`, so nothing here touches graphics.
        _ = self;
        effect.prepare(win, .full_screen);
        win.hideCursor();
    }
};

/// Kitty `a=T` transmit-and-display of a base64 RGB frame (zlib-compressed
/// when `compressed`) in 4 KiB chunks, scaled into `box` cells at the
/// cursor; `q=2` keeps the terminal from answering, `C=1` leaves the cursor.
/// Deflate effort. Measured on daybreak (gradients) and Pac-Man (flat
/// art): level 4 shrinks frames 7% and 23% over level 1 at the same cost;
/// level 6 buys a little more for a third more CPU per frame.
pub const deflate_options: std.compress.flate.Compress.Options = .level_4;

/// zlib-compress `src` into `dst`; null when it does not fit.
fn deflate(dst: []u8, window: []u8, src: []const u8) ?[]u8 {
    var out: std.Io.Writer = .fixed(dst);
    var c = std.compress.flate.Compress.init(&out, window, .zlib, deflate_options) catch return null;
    c.writer.writeAll(src) catch return null;
    c.finish() catch return null;
    return out.buffered();
}

/// The animation thread's tick rate; ship intervals are counted in ticks.
pub const ticks_per_second: usize = 30;
/// The game tier's tick rate (16 ms) while wipEout is up.
pub const game_ticks_per_second: usize = 60;

/// Ticks per second an engine of this kind is driven at.
pub fn tickRate(kind: visual_effect.Kind) usize {
    return if (kind == .wipeout or kind == .orb) game_ticks_per_second else ticks_per_second;
}
/// What any one effect may put on the wire — a courtesy cap, not a crash
/// guard: Ghostty 1.3.1 took 14 MiB/s of raw frames for 40 s and 2 min of
/// wipEout at 60 fps (~4 MiB/s) without complaint once the placement churn
/// was gone (2026-09-07). 10 MB/s lets every effect ship at its base rate,
/// wipEout's CRT pass included, and still throttles a runaway scene.
pub var wire_budget_bytes_per_second: usize = 10_000_000;

/// `MARLIN_WIRE_BUDGET`: bytes per second, 0 for no budget.
pub fn setWireBudget(bytes_per_second: usize) void {
    wire_budget_bytes_per_second = bytes_per_second;
}

pub const Dimensions = struct { width: u16, height: u16 };

pub const Letterbox = struct { x: i17, y: i17, cols: u16, rows: u16 };

/// Largest `aspect_w:aspect_h` cell rectangle centered in a window, given
/// the cell pixel size.
pub fn letterbox(cols: u16, rows: u16, cell_px_w: u32, cell_px_h: u32, aspect_w: u32, aspect_h: u32) Letterbox {
    if (cols == 0 or rows == 0) return .{ .x = 0, .y = 0, .cols = cols, .rows = rows };
    const cw: u32 = if (cell_px_w > 0) cell_px_w else default_cell_w;
    const ch: u32 = if (cell_px_h > 0) cell_px_h else default_cell_h;
    const full_w: u64 = @as(u64, cols) * cw;
    const full_h: u64 = @as(u64, rows) * ch;
    var out_cols: u32 = cols;
    var out_rows: u32 = rows;
    if (full_w * aspect_h > full_h * aspect_w) {
        out_cols = @intCast(@max((full_h * aspect_w / aspect_h + cw / 2) / cw, 1));
    } else {
        out_rows = @intCast(@max((full_w * aspect_h / aspect_w + ch / 2) / ch, 1));
    }
    out_cols = @min(out_cols, cols);
    out_rows = @min(out_rows, rows);
    return .{
        .x = @intCast((cols - out_cols) / 2),
        .y = @intCast((rows - out_rows) / 2),
        .cols = @intCast(out_cols),
        .rows = @intCast(out_rows),
    };
}

/// Pick a framebuffer whose aspect matches the window's pixel aspect, with
/// the width clamped into the band that keeps 30 fps encoding cheap. The
/// maze wants vertical resolution (30 board rows), so it sizes from height.
pub fn framebufferSize(cols: u16, rows: u16, cell_px_w: u32, cell_px_h: u32, kind: visual_effect.Kind) Dimensions {
    const c: u32 = @max(cols, 1);
    const r: u32 = @max(rows, 1);
    const win_w = c * cell_px_w;
    const win_h = r * cell_px_h;
    if (kind == .daybreak or kind == .orb) {
        // Detailed, slowly shipped scenes render near the window's own pixel
        // size inside the 720×405 envelope Pac-Man has already proven. Both
        // daybreak's stretched 1900×900 canvas and the orb's captured text
        // benefit from more resolution than the small demoscene framebuffers.
        var width: u32 = std.math.clamp(win_w, 480, 720);
        var height: u32 = @max(width * win_h / @max(win_w, 1), 32);
        if (height > 405) {
            height = 405;
            width = @max(height * win_w / @max(win_h, 1), 64);
        }
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }
    if (kind == .pacman) {
        // Up to 16 px per maze tile; the maze and its HUD rows are centered
        // in a framebuffer of the window's aspect (letterboxed, so `.fill`
        // never stretches it).
        const layout = pacman.layoutForAspect(win_w, win_h);
        const total_rows: u32 = @as(u32, layout.rows) + pacman.hud_rows;
        const t: u32 = std.math.clamp(@min(1600 / @as(u32, layout.cols), 720 / total_rows), 4, 16);
        const height: u32 = total_rows * t;
        const by_aspect: u32 = height * win_w / @max(win_h, 1);
        const width: u32 = std.math.clamp(by_aspect, @as(u32, layout.cols) * t, 1600);
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }
    if (kind == .wipeout) {
        // PSX-native 240p (2x with the CRT pass, see Engine.resize); the
        // image is letterboxed to 4:3 at draw time.
        return .{ .width = wipeout_effect.render_width, .height = wipeout_effect.render_height };
    }
    if (kind == .tetris) {
        // The arcade cabinet uses the entire viewport. Render near terminal
        // resolution so its type and beveled blocks stay crisp when scaled.
        var tetris_width: u32 = std.math.clamp(win_w, 480, 960);
        var tetris_height: u32 = @max(tetris_width * win_h / @max(win_w, 1), 270);
        if (tetris_height > 720) {
            tetris_height = 720;
            tetris_width = @max(tetris_height * win_w / @max(win_h, 1), 320);
        }
        return .{ .width = @intCast(tetris_width), .height = @intCast(tetris_height) };
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
