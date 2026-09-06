//! Time-trial HUD using ROM lap/time labels and the original CI4 debug font.
//! Layout/countdown panels are native HUD adapters, not the complete N64 UI.
const std = @import("std");
const render = @import("render.zig");
const rom = @import("rom.zig");
const Trial = @import("trial.zig").Trial;
const Game = @import("game.zig").Game;
const glyphs = @import("font_map.zig").ascii;
pub const Hud = struct {
    font: [4096][4]u8,
    icons: [4][1280][4]u8,
    box: [2048][4]u8,
    labels: [4][512][4]u8,
    pub fn load(gpa: std.mem.Allocator, bytes: []const u8) !Hud {
        const common = try rom.mio0(gpa, bytes[0x132b50..]);
        defer gpa.free(common);
        if (common.len < 0x23ad8) return error.InvalidHud;
        var h: Hud = undefined;
        for (0..4096) |i| {
            const b = common[0x6ef8 + i / 2];
            const idx = if (i % 2 == 0) b >> 4 else b & 15;
            h.font[i] = render.rgba16(try rom.u16be(common, 0x6ed8 + @as(usize, idx) * 2));
        }
        for ([_]usize{ 0xb158, 0xb558, 0xb958, 0xc158 }, 0..) |offset, label_index| for (0..512) |i| {
            h.labels[label_index][i] = render.rgba16(try rom.u16be(common, offset + i * 2));
        };
        for ([_]usize{ 0x20dd8, 0x203d8, 0x22bd8, 0x235d8 }, [_]usize{ 0x1e4d8, 0x1e0d8, 0x1f0d8, 0x1f4d8 }, 0..) |offset, palette, kind| {
            for (0..1280) |i| h.icons[kind][i] = render.rgba16(try rom.u16be(common, palette + @as(usize, common[offset + i]) * 2));
        }
        for (0..2048) |i| h.box[i] = render.rgba16(try rom.u16be(common, 0x1ee8 + i * 2));
        return h;
    }
    pub fn draw(self: *const Hud, r: *render.Renderer, g: Game, t: Trial, best: ?u32) void {
        panel(r, 6, 6, 158, 54);
        panel(r, 268, 6, 46, 24);
        self.text(r, 174, 14, g.controller.engine.label(), 1);
        self.label(r, 3, 10, 10);
        var buffer: [80]u8 = undefined;
        const timer = timeText(&buffer, t.elapsed);
        self.text(r, 48, 14, timer, 1);
        self.label(r, @min(t.laps, 2), 276, 10);
        self.text(r, 10, 34, "BEST", 1);
        self.text(r, 50, 34, if (best) |ticks| timeText(&buffer, ticks) else "--:--.--", 1);
        self.text(r, 10, 46, "LAP", 1);
        self.text(r, 50, 46, timeText(&buffer, t.elapsed - t.lap_start), 1);
        panel(r, 238, 214, 76, 16);
        self.text(r, 242, 218, std.fmt.bufPrint(&buffer, "{d: >3} KM/H", .{@as(u32, @intFromFloat(@max(0, (if (t.phase == .finished) @as(f32, 0) else g.speed) * 12)))}) catch "", 1);
        if (t.phase == .practice or t.assisted) {
            panel(r, 6, 214, 144, 16);
            self.text(r, 10, 218, if (t.phase == .practice) "PRACTICE" else "ASSISTED - NO BEST", 1);
        }
        self.text(r, 10, 230, "H KEYS C CLASS M MODE O AUTO G GHOST", 1);
        if (g.paused) {
            panel(r, 116, 96, 88, 26);
            self.text(r, 136, 105, "PAUSED", 1);
            return;
        }
        if (t.phase == .countdown) {
            panel(r, 108, 84, 104, 72);
            self.text(r, 120, 94, "GET READY", 1);
            const digit = std.fmt.bufPrint(&buffer, "{d}", .{(t.countdown + 59) / 60}) catch "";
            self.text(r, 148, 118, digit, 3);
        } else if (t.phase == .racing and t.elapsed < 60) {
            self.text(r, 136, 86, "GO", 3);
        } else if (t.phase == .finished) {
            panel(r, 40, 46, 240, 160);
            self.text(r, 112, 56, "FINISH", 2);
            for (t.splits, 0..) |split, i| {
                const y = 90 + @as(i32, @intCast(i)) * 18;
                self.text(r, 56, y, std.fmt.bufPrint(&buffer, "LAP {d}", .{i + 1}) catch "", 1);
                self.text(r, 176, y, timeText(&buffer, split), 1);
            }
            self.text(r, 56, 146, "TOTAL", 1);
            self.text(r, 176, 146, timeText(&buffer, t.elapsed), 1);
            self.text(r, 56, 168, if (t.save_failed) "BEST COULD NOT SAVE" else if (t.saved) "NEW BEST + GHOST SAVED" else if (t.assisted) "ASSISTED - NOT SAVED" else if (!t.valid) "INVALID RUN" else "RACE COMPLETE", 1);
            self.text(r, 72, 190, "R RETRY / ESC EXIT", 1);
        } else if (t.laps > 0 and t.elapsed - t.lap_start < 180) {
            panel(r, 6, 72, 152, 16);
            self.text(r, 10, 76, "SPLIT", 1);
            self.text(r, 58, 76, timeText(&buffer, t.splits[t.laps - 1]), 1);
        }
        if (t.phase == .racing or t.phase == .practice) {
            const message: []const u8 = if (g.controller.drift.turbo_ticks > 0) "MINI-TURBO!" else if (g.controller.drift.charge >= 2) "DRIFT READY" else if (g.controller.drift.charge == 1) "DRIFT 1/2" else "";
            if (message.len > 0) {
                panel(r, 96, 198, 128, 16);
                self.text(r, 160 - @as(i32, @intCast(message.len)) * 4, 202, message, 1);
            }
        }
    }
    pub fn drawBoxes(self: *const Hud, r: *render.Renderer, camera: render.Camera, items: @import("items.zig").Items, ticks: u32) void {
        for (@import("items.zig").positions, items.cooldown, 0..) |p, cooldown, index| {
            if (cooldown != 0) continue;
            const world = p.add(.{ .x = 0, .y = 12 + 2 * @sin(@as(f32, @floatFromInt(ticks)) * 0.05 + @as(f32, @floatFromInt(index))), .z = 0 });
            const screen = camera.project(world) orelse continue;
            if (screen.x < -64 or screen.x > 384 or screen.y < -64 or screen.y > 304) continue;
            const size: usize = @intFromFloat(std.math.clamp(230 * 16 / screen.z, 2, 64));
            const left = @as(i32, @intFromFloat(screen.x)) - @as(i32, @intCast(size / 2));
            const top = @as(i32, @intFromFloat(screen.y)) - @as(i32, @intCast(size / 2));
            for (0..size) |y| for (0..size) |x| {
                const px = left + @as(i32, @intCast(x));
                const py = top + @as(i32, @intCast(y));
                if (px < 0 or py < 0 or px >= 320 or py >= 240) continue;
                const i = @as(usize, @intCast(py)) * 320 + @as(usize, @intCast(px));
                if (1 / screen.z < r.depth[i]) continue;
                const color = self.box[(y * 64 / size) * 32 + x * 32 / size];
                const tint: [3]u8 = if ((index + ticks / 20) % 2 == 0) .{ 60, 220, 255 } else .{ 230, 100, 255 };
                if (color[3] > 0) {
                    pixel(r, px, py, color[0..3].*);
                } else if (x == 0 or y == 0 or x + 1 == size or y + 1 == size) {
                    pixel(r, px, py, tint);
                } else {
                    for (0..3) |c| r.rgb[i * 3 + c] = @intCast((@as(u16, r.rgb[i * 3 + c]) * 3 + tint[c]) / 4);
                }
                r.depth[i] = 1 / screen.z;
            };
        }
    }
    pub fn drawProjectiles(self: *const Hud, r: *render.Renderer, camera: render.Camera, world: @import("projectiles.zig").World) void {
        for (world.actors) |actor| {
            if (!actor.active) continue;
            const screen = camera.project(actor.pos) orelse continue;
            if (screen.x < -64 or screen.x > 384 or screen.y < -64 or screen.y > 304) continue;
            const size: usize = @intFromFloat(std.math.clamp(230 * 9 / screen.z, 2, 48));
            const left = @as(i32, @intFromFloat(screen.x)) - @as(i32, @intCast(size / 2));
            const top = @as(i32, @intFromFloat(screen.y)) - @as(i32, @intCast(size / 2));
            for (0..size) |y| for (0..size) |x| {
                const px = left + @as(i32, @intCast(x));
                const py = top + @as(i32, @intCast(y));
                if (px < 0 or py < 0 or px >= 320 or py >= 240) continue;
                const i = @as(usize, @intCast(py)) * 320 + @as(usize, @intCast(px));
                if (1 / screen.z < r.depth[i]) continue;
                // Crop the HUD frame: temporary world billboard until actor meshes are ported.
                const color = self.icons[if (actor.kind == .banana) @as(usize, 1) else if (actor.kind == .shell) 2 else 3][(4 + y * 24 / size) * 40 + 8 + x * 24 / size];
                if (color[3] == 0 or (@as(u16, color[0]) + color[1] + color[2] < 70)) continue;
                pixel(r, px, py, color[0..3].*);
                r.depth[i] = 1 / screen.z;
            };
        }
    }
    pub fn drawDefense(self: *const Hud, r: *render.Renderer, camera: render.Camera, items: @import("items.zig").Items) void {
        var display = @import("projectiles.zig").World{};
        for (items.world.shields, 0..) |position, id| {
            if (position) |p| display.actors[id] = .{ .active = true, .pos = p, .kind = switch (items.kind[id]) {
                .banana => .banana,
                .shell => .shell,
                .red_shell => .red_shell,
                .mushroom => continue,
            } };
        }
        self.drawProjectiles(r, camera, display);
    }
    pub fn drawRace(self: *const Hud, r: *render.Renderer, g: Game, t: Trial, race: *const @import("race.zig").Race, track: *const @import("course.zig").Course) void {
        // Cover the time-trial BEST field with race position.
        for (32..44) |y| for (8..160) |x| pixel(r, @intCast(x), @intCast(y), .{ 12, 20, 32 });
        var buffer: [64]u8 = undefined;
        self.text(r, 10, 34, std.fmt.bufPrint(&buffer, "POSITION {d}/8", .{race.place(g, track)}) catch "", 1);
        for (214..230) |y| for (6..154) |x| pixel(r, @intCast(x), @intCast(y), .{ 12, 20, 32 });
        self.text(r, 10, 218, "RACE / M TIME TRIAL", 1);
        if (t.phase != .finished) {
            panel(r, 266, 36, 48, 48);
            if (race.items.held[0]) {
                for (0..32) |y| for (0..40) |x| {
                    const kind: usize = if (race.items.roulette[0] > 0) (race.items.roulette[0] / 5) % 4 else @intFromEnum(race.items.kind[0]);
                    const p = self.icons[kind][y * 40 + x];
                    if (p[3] > 0) pixel(r, 270 + @as(i32, @intCast(x)), 38 + @as(i32, @intCast(y)), p[0..3].*);
                };
                self.text(r, 270, 74, if (race.items.roulette[0] > 0) "ROLL" else if (race.items.trailing[0]) "GUARD" else "E USE", 1);
            } else self.text(r, 274, 54, "ITEM", 1);
            if (race.items.block_flash[0] > 0) {
                panel(r, 88, 144, 144, 16);
                self.text(r, 96, 148, "SHELL BLOCKED!", 1);
            } else if (race.items.incoming(0, g)) {
                panel(r, 72, 144, 176, 16);
                self.text(r, 80, 148, "RED SHELL INCOMING!", 1);
            }
            if (g.controller.spin_ticks > 0) {
                panel(r, 104, 162, 112, 16);
                self.text(r, 112, 166, "SPIN OUT!", 1);
            }
            if (g.controller.mushroom_ticks > 0 or g.controller.mushroom_force > 1) {
                panel(r, 88, 180, 144, 16);
                self.text(r, 92, 184, "MUSHROOM BOOST!", 1);
            }
        }
        if (t.phase != .finished or g.paused) return;
        for (46..210) |y| for (40..280) |x| pixel(r, @intCast(x), @intCast(y), .{ 12, 20, 32 });
        self.text(r, 80, 52, std.fmt.bufPrint(&buffer, "FINISH - {d}/8", .{race.place(g, track)}) catch "", 1);
        for (race.order(g, track), 0..) |id, i| {
            const y: i32 = 72 + @as(i32, @intCast(i)) * 14;
            self.text(r, 56, y, std.fmt.bufPrint(&buffer, "{d} {s}{s}", .{ i + 1, @import("characters.zig").names[id], if (id == 0) " YOU" else "" }) catch "", 1);
            const ticks = if (id == 0) t.elapsed else race.trials[id - 1].elapsed;
            self.text(r, 192, y, if (race.finish_place[id] != 0) timeText(&buffer, ticks) else "RACING", 1);
        }
        self.text(r, 72, 192, "R RETRY / M MODE", 1);
    }
    fn label(self: *const Hud, r: *render.Renderer, index: usize, left: i32, top: i32) void {
        for (0..16) |y| for (0..32) |x| {
            const p = self.labels[index][y * 32 + x];
            if (p[3] > 0) pixel(r, left + @as(i32, @intCast(x)), top + @as(i32, @intCast(y)), p[0..3].*);
        };
    }
    fn text(self: *const Hud, r: *render.Renderer, left: i32, top: i32, s: []const u8, scale: i32) void {
        for (s, 0..) |ch, i| {
            const glyph = glyphs[ch];
            if (glyph == 255) continue;
            for (0..8) |y| for (0..8) |x| {
                const p = self.font[(@as(usize, glyph / 16) * 8 + y) * 128 + @as(usize, glyph % 16) * 8 + x];
                if (p[3] == 0) continue;
                for (0..@intCast(scale)) |dy| for (0..@intCast(scale)) |dx| pixel(r, left + @as(i32, @intCast(i * 8 + x)) * scale + @as(i32, @intCast(dx)), top + @as(i32, @intCast(y)) * scale + @as(i32, @intCast(dy)), p[0..3].*);
            };
        }
    }
};
fn pixel(r: *render.Renderer, x: i32, y: i32, c: [3]u8) void {
    if (x < 0 or x >= 320 or y < 0 or y >= 240) return;
    const i = (@as(usize, @intCast(y)) * 320 + @as(usize, @intCast(x))) * 3;
    r.rgb[i..][0..3].* = c;
}
fn panel(r: *render.Renderer, x: i32, y: i32, w: usize, h: usize) void {
    for (0..h) |dy| for (0..w) |dx| {
        const px = x + @as(i32, @intCast(dx));
        const py = y + @as(i32, @intCast(dy));
        if (px < 0 or px >= 320 or py < 0 or py >= 240) continue;
        const i = (@as(usize, @intCast(py)) * 320 + @as(usize, @intCast(px))) * 3;
        for (0..3) |c| r.rgb[i + c] /= 3;
    };
}
pub fn timeText(buffer: []u8, ticks: u32) []const u8 {
    const centiseconds = @as(u64, ticks) * 100 / 60;
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}.{d:0>2}", .{ centiseconds / 6000, centiseconds / 100 % 60, centiseconds % 100 }) catch "--:--.--";
}
test "clock converts simulation ticks without rounding into next lap" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("00:00.98", timeText(&b, 59));
    try std.testing.expectEqualStrings("01:00.00", timeText(&b, 3600));
}
