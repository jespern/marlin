//! Client-local MK64 drive harness. Owns the terminal only while the TUI is detached.
const std = @import("std");
const vaxis = @import("vaxis");
const mk64 = @import("../mk64/root.zig");
const Io = std.Io;
const Event = union(enum) { key_press: vaxis.Key, key_release: vaxis.Key, winsize: vaxis.Winsize, focus_in, focus_out };
const image_ids = [2]u32{ 0x4d4b3630, 0x4d4b3631 };

pub const Options = struct { autopilot: bool = false };
pub fn run(gpa: std.mem.Allocator, io: Io, environ: *std.process.Environ.Map, path: []const u8) !void {
    return runWithOptions(gpa, io, environ, path, .{});
}
pub fn runWithOptions(gpa: std.mem.Allocator, io: Io, environ: *std.process.Environ.Map, path: []const u8, options: Options) !void {
    const bytes = if (path.len > 0)
        try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024))
    else
        mk64.cache.acquire(gpa, io, environ) catch |err| {
            var buffer: [512]u8 = undefined;
            var out = Io.File.stderr().writer(io, &buffer);
            try out.interface.print("Mario Kart asset download/cache failed ({t}). Retry online, or set MARLIN_MK64_ASSETS to a local bundle.\n", .{err});
            try out.interface.flush();
            return err;
        };
    defer gpa.free(bytes);
    const imported = if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], &.{ 0x80, 0x37, 0x12, 0x40 })) try mk64.assets.importRom(gpa, bytes) else null;
    defer if (imported) |b| gpa.free(b);
    var assets = try mk64.assets.load(gpa, imported orelse bytes);
    defer assets.deinit();
    const track = assets.track;
    const sprite = assets.sprites[0];
    const opponents = assets.sprites[1..];
    const hud = assets.hud;
    const state_dir = if (environ.get("MARLIN_MK64_STATE_DIR")) |dir| try gpa.dupe(u8, dir) else if (environ.get("XDG_STATE_HOME")) |dir| try std.fs.path.join(gpa, &.{ dir, "marlin", "mk64" }) else if (environ.get("HOME")) |dir| try std.fs.path.join(gpa, &.{ dir, ".local", "state", "marlin", "mk64" }) else null;
    defer if (state_dir) |dir| gpa.free(dir);
    var engine: @import("../mk64/engine.zig").Class = .cc100;
    var best_path = if (state_dir) |dir| try std.fs.path.join(gpa, &.{ dir, engine.file() }) else null;
    defer if (best_path) |p| gpa.free(p);
    var best: ?mk64.ghost.Run = if (best_path) |p| mk64.ghost.load(gpa, io, p) catch null else null;
    defer if (best) |b| b.deinit(gpa);
    var recording: std.ArrayList(mk64.ghost.Pose) = .empty;
    defer recording.deinit(gpa);
    try recording.ensureTotalCapacity(gpa, mk64.ghost.max_ticks + 1);
    const renderer = try gpa.create(mk64.render.Renderer);
    defer gpa.destroy(renderer);
    const zbuf = try gpa.alloc(u8, renderer.rgb.len + 4096);
    defer gpa.free(zbuf);
    const window = try gpa.alloc(u8, 2 * std.compress.flate.max_window_len);
    defer gpa.free(window);
    const encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(zbuf.len));
    defer gpa.free(encoded);
    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer tty.deinit();
    var vx = try vaxis.init(io, gpa, environ, .{ .kitty_keyboard_flags = .{ .report_events = true } });
    defer vx.deinit(gpa, tty.writer());
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();
    const writer = tty.writer();
    try vx.enterAltScreen(writer);
    try writer.flush();
    try vx.queryTerminal(writer, .fromSeconds(1));
    if (!vx.caps.kitty_graphics) return error.KittyGraphicsRequired;
    if (!vx.caps.kitty_keyboard) return error.KeyReleaseProtocolRequired;
    try writer.writeAll("\x1b[?25l\x1b[?1004h");
    try writer.flush();
    defer {
        for (image_ids) |id| writer.print("\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{id}) catch {};
        writer.writeAll("\x1b[?2026l\x1b[?1004l\x1b[?25h") catch {};
        writer.flush() catch {};
    }
    var size = try tty.getWinsize();
    var game = mk64.trial.Trial.grid(&track);
    var trial = mk64.trial.Trial{};
    var race_enabled = true;
    var race = mk64.race.Race.init(&track, engine, &game);
    var mode_held = false;
    var item_held = false;
    var item_backward = false;
    var overlay = options.autopilot;
    var overlay_held = false;
    var ghost_visible = true;
    var ghost_held = false;
    var keys: Keys = .{};
    var pause_held = false;
    var reset_held = false;
    var auto_held = false;
    var demo_held = false;
    var class_held = false;
    var focus_driver: ?mk64.autopilot.Driver = null;
    var driver = mk64.autopilot.Driver{ .mode = if (options.autopilot) .race else .off };
    var finish_wait: u16 = 0;
    var applied: mk64.game.Input = .{};
    const frame_ns = std.time.ns_per_s / mk64.game.tick_hz;
    var deadline = now(io);
    var last_tick = deadline;
    var accumulator: i128 = 0;
    var frame: usize = 0;
    while (true) {
        while (try loop.tryEvent()) |event| switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return;
                if ((key.matches('e', .{}) or key.matches('e', .{ .shift = true })) and !item_held) {
                    item_held = true;
                    item_backward = key.mods.shift;
                    if (race_enabled and trial.phase == .racing) race.items.beginHold(0, game);
                }
                if (key.matches('m', .{}) and !mode_held) {
                    mode_held = true;
                    race_enabled = !race_enabled;
                    game = mk64.trial.Trial.grid(&track);
                    game.controller.engine = engine;
                    game.controller.top_speed = engine.top();
                    if (race_enabled) race = mk64.race.Race.init(&track, engine, &game);
                    trial = .{};
                    recording.clearRetainingCapacity();
                    driver = .{};
                    focus_driver = null;
                    keys = .{};
                    applied = .{};
                }
                if (key.matches('c', .{}) and !class_held) {
                    class_held = true;
                    engine = engine.next();
                    const next_path = if (state_dir) |dir| try std.fs.path.join(gpa, &.{ dir, engine.file() }) else null;
                    if (best_path) |p| gpa.free(p);
                    best_path = next_path;
                    if (best) |b| b.deinit(gpa);
                    best = if (best_path) |p| mk64.ghost.load(gpa, io, p) catch null else null;
                    game = mk64.trial.Trial.grid(&track);
                    game.controller.engine = engine;
                    game.controller.top_speed = engine.top();
                    if (race_enabled) race = mk64.race.Race.init(&track, engine, &game);
                    trial = .{};
                    recording.clearRetainingCapacity();
                    driver = .{};
                    focus_driver = null;
                    keys = .{};
                    applied = .{};
                }
                if (key.matches('h', .{}) and !overlay_held) {
                    overlay_held = true;
                    overlay = !overlay;
                    try writer.writeAll("\x1b[2J");
                }
                if (key.matches('g', .{}) and !ghost_held) {
                    ghost_held = true;
                    ghost_visible = !ghost_visible;
                }
                if (key.matches('o', .{}) and !auto_held) {
                    auto_held = true;
                    focus_driver = null;
                    driver.mode = if (driver.mode == .off) .race else .off;
                    if (driver.mode != .off) trial.assisted = true;
                    overlay = true;
                    keys = .{};
                    applied = .{};
                }
                if (key.matches('t', .{}) and !demo_held) {
                    demo_held = true;
                    focus_driver = null;
                    race_enabled = false;
                    game = mk64.autopilot.rollingStart(&track, 460);
                    game.controller.engine = engine;
                    game.controller.top_speed = engine.top();
                    driver = .{ .mode = .drift_demo };
                    trial = mk64.trial.Trial.practice();
                    recording.clearRetainingCapacity();
                    overlay = true;
                    keys = .{};
                    applied = .{};
                }
                if (key.matches('r', .{}) and !reset_held) {
                    reset_held = true;
                    focus_driver = null;
                    game = mk64.trial.Trial.grid(&track);
                    game.controller.engine = engine;
                    game.controller.top_speed = engine.top();
                    if (race_enabled) race = mk64.race.Race.init(&track, engine, &game);
                    trial = .{};
                    recording.clearRetainingCapacity();
                    driver = .{};
                    applied = .{};
                    keys = .{};
                }
                if (key.matches('p', .{}) and !pause_held) {
                    pause_held = true;
                    game.paused = !game.paused;
                    race.items.cancelHold(0);
                    item_held = false;
                    if (!game.paused) {
                        if (focus_driver) |saved| driver = saved;
                        focus_driver = null;
                    }
                    keys = .{};
                }
                if (!game.paused) keys.update(key, true);
                // Any driving key takes control immediately, including during a demo.
                if (!game.paused and Keys.isDrivingKey(key)) {
                    driver.mode = .off;
                    applied = .{};
                }
            },
            .key_release => |key| {
                if (key.codepoint == 'e' or key.codepoint == 'E') {
                    if (item_held and race_enabled and trial.phase == .racing) race.items.releaseHold(0, &game, item_backward or key.mods.shift) else race.items.cancelHold(0);
                    item_held = false;
                }
                if (key.codepoint == 'm') mode_held = false;
                if (key.codepoint == 'c') class_held = false;
                if (key.codepoint == 'p') pause_held = false;
                if (key.codepoint == 'r') reset_held = false;
                if (key.codepoint == 'h') overlay_held = false;
                if (key.codepoint == 'g') ghost_held = false;
                if (key.codepoint == 'o') auto_held = false;
                if (key.codepoint == 't') demo_held = false;
                keys.update(key, false);
            },
            .focus_out => {
                race.items.cancelHold(0);
                item_held = false;
                if (focus_driver == null) focus_driver = driver;
                class_held = false;
                mode_held = false;
                keys = .{};
                pause_held = false;
                reset_held = false;
                auto_held = false;
                demo_held = false;
                overlay_held = false;
                ghost_held = false;
                game.paused = true;
            },
            .focus_in => {},
            .winsize => |s| {
                size = s;
                keys = .{};
                try writer.writeAll("\x1b[2J");
            },
        };
        const current = now(io);
        accumulator += @min(current - last_tick, 250 * std.time.ns_per_ms);
        last_tick = current;
        while (accumulator >= frame_ns) : (accumulator -= frame_ns) {
            if (options.autopilot and driver.mode == .race and game.finished and !game.paused) {
                finish_wait += 1;
                if (finish_wait == 180) {
                    game = mk64.trial.Trial.grid(&track);
                    game.controller.engine = engine;
                    game.controller.top_speed = engine.top();
                    if (race_enabled) race = mk64.race.Race.init(&track, engine, &game);
                    trial = .{ .assisted = true };
                    recording.clearRetainingCapacity();
                    race.items.cancelHold(0);
                    item_held = false;
                    keys = .{};
                    finish_wait = 0;
                }
            } else if (!game.finished) finish_wait = 0;
            applied = if (game.paused or game.finished) .{} else if (driver.mode != .off) driver.input(game, &track) else keys.input();
            const before = trial.elapsed;
            if (trial.phase == .racing and before == 0 and recording.items.len == 0) recording.appendAssumeCapacity(mk64.ghost.pose(game));
            const was_finished = game.finished;
            trial.tick(&game, &track, applied, driver.mode != .off);
            if (race_enabled and !was_finished) {
                race.tick(&game, trial, &track);
                if (driver.mode == .race and trial.phase == .racing and !item_held) race.items.autoUse(0, &game);
            }
            if (trial.elapsed > before) {
                if (trial.elapsed <= mk64.ghost.max_ticks) recording.appendAssumeCapacity(mk64.ghost.pose(game)) else trial.valid = false;
            }
        }
        if (game.paused or game.finished) applied = .{};
        if (trial.phase == .finished and !trial.settled) {
            trial.settled = true;
            if (!race_enabled and trial.eligible() and (best == null or trial.elapsed < best.?.ticks)) {
                if (best_path) |p| {
                    const candidate = mk64.ghost.Run{ .ticks = trial.elapsed, .splits = trial.splits, .frames = recording.items };
                    if (mk64.ghost.save(gpa, io, p, candidate)) |_| {
                        const copy = try gpa.dupe(mk64.ghost.Pose, recording.items);
                        if (best) |old| old.deinit(gpa);
                        best = .{ .ticks = trial.elapsed, .splits = trial.splits, .frames = copy };
                        trial.saved = true;
                    } else |_| trial.save_failed = true;
                } else trial.save_failed = true;
            }
        }
        renderer.draw(&track, game.camera());
        if (!race_enabled and ghost_visible and trial.phase != .practice) {
            if (best) |b| if (trial.elapsed < b.frames.len) sprite.drawGhost(renderer, game.camera(), b.frames[trial.elapsed]);
        }
        if (race_enabled) hud.drawDefense(renderer, game.camera(), race.items);
        if (race_enabled) hud.drawProjectiles(renderer, game.camera(), race.items.world);
        if (race_enabled) hud.drawBoxes(renderer, game.camera(), race.items, trial.elapsed);
        if (race_enabled) for (race.opponents, opponents) |cpu, *kart| kart.drawOpponent(renderer, game.camera(), cpu);
        sprite.drawGame(renderer, &game);
        hud.draw(renderer, game, trial, if (!race_enabled and best != null) best.?.ticks else null);
        if (race_enabled) hud.drawRace(renderer, game, trial, &race, &track);
        const display = fit(size, overlay);
        var out: Io.Writer = .fixed(zbuf);
        var compressor = try std.compress.flate.Compress.init(&out, window, .zlib, .fastest);
        try compressor.writer.writeAll(&renderer.rgb);
        try compressor.finish();
        const payload = if (out.buffered().len < renderer.rgb.len) out.buffered() else &renderer.rgb;
        const base64 = std.base64.standard.Encoder.encode(encoded, payload);
        const id = image_ids[frame % 2];
        try writer.writeAll("\x1b[?2026h");
        try transmit(writer, base64, display, id, payload.len < renderer.rgb.len);
        if (frame > 0) try writer.print("\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{image_ids[(frame + 1) % 2]});
        if (overlay) {
            var status_buf: [200]u8 = undefined;
            const status = try std.fmt.bufPrint(&status_buf, "{d:.0} km/h | Lap {d}/3 | {d:.1}s | {s}", .{ game.speed * 12, @min(game.laps + 1, 3), @as(f32, @floatFromInt(game.ticks)) / mk64.game.tick_hz, if (game.finished) "FINISH - R restart" else if (game.paused) "PAUSED - P resume" else if (game.controller.drift.turbo_ticks > 0) "MINI-TURBO!" else if (game.controller.drift.charge >= 2) "DRIFT READY - release Space" else if (game.controller.drift.charge == 1) "DRIFT 1/2 - countersteer again" else if (game.controller.drift.drifting) "DRIFT - countersteer then steer in" else "Space drift | O auto | T demo | P pause | R reset" });
            try writer.print("\x1b[{d};1H\x1b[2K\x1b[0m{s}", .{ @max(size.rows, 1), status[0..@min(status.len, size.cols - @min(size.cols, 1))] });
            if (size.rows >= 2) {
                var keys_buf: [180]u8 = undefined;
                const key_status = try std.fmt.bufPrint(&keys_buf, "{s} | [{s}] [{s}] [{s}] [{s}] [{s}] [{s}] | O auto T demo", .{
                    if (driver.mode == .off) "MANUAL" else if (driver.mode == .race) "AUTO" else "DRIFT DEMO",
                    if (applied.accelerate) "W" else "-",
                    if (applied.left) "A" else "-",
                    if (applied.brake) "S" else "-",
                    if (applied.right) "D" else "-",
                    if (applied.hop) "SPACE" else "-----",
                    if (race_enabled and !game.paused and !game.finished and race.items.trailing[0]) "E HOLD" else if (race_enabled and !game.paused and !game.finished and race.items.use_flash[0] > 0) (if (race.items.backward[0]) "SHIFT+E" else "E") else "-",
                });
                try writer.print("\x1b[{d};1H\x1b[2K{s}", .{ size.rows - 1, key_status[0..@min(key_status.len, size.cols - @min(size.cols, 1))] });
            }
        }
        try writer.writeAll("\x1b[?2026l");
        try writer.flush();
        frame += 1;
        deadline += frame_ns;
        const remaining = deadline - now(io);
        if (remaining > 0) try io.sleep(.fromNanoseconds(@intCast(remaining)), .awake) else deadline = now(io);
    }
}

const Keys = struct {
    fn isDrivingKey(key: vaxis.Key) bool {
        for ([_]u21{ 'w', 'a', 's', 'd', ' ', vaxis.Key.up, vaxis.Key.left, vaxis.Key.down, vaxis.Key.right }) |code| {
            if (key.codepoint == code) return true;
        }
        return false;
    }
    held: [9]bool = .{false} ** 9,
    fn update(self: *Keys, key: vaxis.Key, down: bool) void {
        const codes = [9]u21{ 'w', vaxis.Key.up, 's', vaxis.Key.down, 'a', vaxis.Key.left, 'd', vaxis.Key.right, ' ' };
        for (codes, 0..) |code, i| if (key.matches(code, .{}) or (!down and key.codepoint == code)) {
            self.held[i] = down;
        };
    }
    fn input(self: Keys) mk64.game.Input {
        return .{ .accelerate = self.held[0] or self.held[1], .brake = self.held[2] or self.held[3], .left = self.held[4] or self.held[5], .right = self.held[6] or self.held[7], .hop = self.held[8] };
    }
};

const Display = struct { cols: u16, rows: u16, col: u16, row: u16 };
fn fit(size: vaxis.Winsize, overlay: bool) Display {
    const cols = @max(size.cols, 1);
    const rows = @max(size.rows - @min(size.rows, @as(u16, if (overlay) 2 else 0)), 1);
    const cw: f32 = if (size.x_pixel > 0) @as(f32, @floatFromInt(size.x_pixel)) / @as(f32, @floatFromInt(cols)) else 8;
    const ch: f32 = if (size.y_pixel > 0) @as(f32, @floatFromInt(size.y_pixel)) / @as(f32, @floatFromInt(@max(size.rows, 1))) else 16;
    const w = @min(@as(f32, @floatFromInt(cols)) * cw, @as(f32, @floatFromInt(rows)) * ch * 4 / 3);
    const c: u16 = @max(1, @as(u16, @intFromFloat(w / cw)));
    const r: u16 = @max(1, @as(u16, @intFromFloat(w * 3 / 4 / ch)));
    return .{ .cols = @min(c, cols), .rows = @min(r, rows), .col = (cols - @min(c, cols)) / 2, .row = (rows - @min(r, rows)) / 2 };
}
fn transmit(out: *Io.Writer, bytes: []const u8, display: Display, id: u32, compressed: bool) !void {
    try out.print("\x1b[{d};{d}H", .{ display.row + 1, display.col + 1 });
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 4096, bytes.len);
        if (offset == 0) try out.print("\x1b_Ga=T,f=24,s=320,v=240,i={d},q=2{s},m={d},c={d},r={d},C=1;", .{ id, if (compressed) ",o=z" else "", @intFromBool(end < bytes.len), display.cols, display.rows }) else try out.print("\x1b_Gm={d};", .{@intFromBool(end < bytes.len)});
        try out.writeAll(bytes[offset..end]);
        try out.writeAll("\x1b\\");
        offset = end;
    }
}
fn now(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

test "drive keys preserve overlapping aliases" {
    var keys: Keys = .{};
    keys.update(.{ .codepoint = 'w' }, true);
    keys.update(.{ .codepoint = vaxis.Key.up }, true);
    keys.update(.{ .codepoint = 'w' }, false);
    try std.testing.expect(keys.input().accelerate);
    keys.update(.{ .codepoint = vaxis.Key.up }, false);
    try std.testing.expect(!keys.input().accelerate);
}
