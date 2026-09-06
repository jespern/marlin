//! In-race HUD: lap counter and times, wrong-way warning, and the speedo
//! with its coloured bars and facia. Layout offsets are the original's, in
//! UI units relative to screen anchors.

const std = @import("std");
const math = @import("math.zig");
const render = @import("render.zig");
const image = @import("image.zig");
const ui_mod = @import("ui.zig");
const ship_mod = @import("ship.zig");
const defs = @import("defs.zig");
const object = @import("object.zig");
const assets_mod = @import("assets.zig");
const Vec2 = math.Vec2;
const Vec2i = math.Vec2i;
const Vec3 = math.Vec3;
const Rgba = math.Rgba;
const Ui = ui_mod.Ui;
const Anchor = ui_mod.Anchor;

const SpeedoBar = struct { x: i32, y: i32, height: i32, color: Rgba };

const speedo_skew: i32 = 2;
const speedo_bars = [13]SpeedoBar{
    .{ .x = 6, .y = 12, .height = 10, .color = Rgba.init(66, 16, 49, 255) },
    .{ .x = 13, .y = 12, .height = 10, .color = Rgba.init(115, 33, 90, 255) },
    .{ .x = 20, .y = 12, .height = 10, .color = Rgba.init(132, 58, 164, 255) },
    .{ .x = 27, .y = 12, .height = 10, .color = Rgba.init(99, 90, 197, 255) },
    .{ .x = 34, .y = 12, .height = 10, .color = Rgba.init(74, 148, 181, 255) },
    .{ .x = 41, .y = 12, .height = 10, .color = Rgba.init(66, 173, 115, 255) },
    .{ .x = 50, .y = 10, .height = 12, .color = Rgba.init(99, 206, 58, 255) },
    .{ .x = 59, .y = 8, .height = 12, .color = Rgba.init(189, 206, 41, 255) },
    .{ .x = 69, .y = 5, .height = 13, .color = Rgba.init(247, 140, 33, 255) },
    .{ .x = 81, .y = 2, .height = 15, .color = Rgba.init(255, 197, 49, 255) },
    .{ .x = 95, .y = 1, .height = 16, .color = Rgba.init(255, 222, 115, 255) },
    .{ .x = 110, .y = 1, .height = 16, .color = Rgba.init(255, 239, 181, 255) },
    .{ .x = 126, .y = 1, .height = 16, .color = Rgba.init(255, 255, 255, 255) },
};

pub const Hud = struct {
    speedo_facia: u16,

    pub fn load(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, r: *render.Renderer) !Hud {
        const data = try assets.load("wipeout/textures/speedo.tim");
        defer gpa.free(data);
        const img = try image.decodeTim(gpa, data, false);
        defer img.deinit(gpa);
        return .{ .speedo_facia = try r.createTexture(img.width, img.height, img.pixels) };
    }

    /// Draw over a frame whose 3D pass is complete. Switches the renderer
    /// to the 2D view.
    pub const Extras = struct {
        show_position: bool,
        autopilot: bool,
        weapon_icons: ?object.TextureList = null,
        reticle: ?u16 = null,
        /// World position of the weapon target, when there is one.
        target_position: ?Vec3 = null,
    };

    pub fn draw(self: *const Hud, r: *render.Renderer, ui: *const Ui, ship: *const ship_mod.Ship, extras: Extras) void {
        const show_position = extras.show_position;
        const autopilot = extras.autopilot;
        r.setView2d();
        r.setCullBackface(false);

        // Once the race is over the original replaces the HUD with the
        // results page.
        if (ship.finished()) {
            drawResults(r, ui, ship);
            r.setCullBackface(true);
            return;
        }

        // Current lap time and the completed laps above it.
        if (ship.lap >= 0) {
            ui.drawTime(r, ship.lap_time, ui.pos(Anchor.bottom | Anchor.left, Vec2i.init(16, -30)), .px16, ui_mod.color_default);
            var i: i32 = 0;
            while (i < ship.lap and i < defs.num_laps - 1) : (i += 1) {
                ui.drawTime(r, ship.lap_times[@intCast(i)], ui.pos(Anchor.bottom | Anchor.left, Vec2i.init(16, -45 - 10 * i)), .px8, ui_mod.color_accent);
            }
        }

        // Lap counter.
        const display_lap: i64 = @min(@max(0, ship.lap + 1), defs.num_laps);
        ui.drawText(r, "LAP", ui.scaled(Vec2i.init(15, 8)), .px8, ui_mod.color_accent);
        ui.drawNumber(r, display_lap, ui.scaled(Vec2i.init(10, 19)), .px16, ui_mod.color_default);
        const width = Ui.charWidth(@intCast('0' + @as(u8, @intCast(@min(display_lap, 9)))), .px16);
        ui.drawText(r, "OF", ui.scaled(Vec2i.init(10 + width, 27)), .px8, ui_mod.color_accent);
        ui.drawNumber(r, defs.num_laps, ui.scaled(Vec2i.init(32 + width, 19)), .px16, ui_mod.color_default);

        if (show_position) {
            ui.drawText(r, "POSITION", ui.pos(Anchor.top | Anchor.right, Vec2i.init(-90, 8)), .px8, ui_mod.color_accent);
            ui.drawNumber(r, ship.position_rank, ui.pos(Anchor.top | Anchor.right, Vec2i.init(-60, 19)), .px16, ui_mod.color_default);
        }

        // Best lap this session stands in for the saved lap record.
        ui.drawText(r, "LAP RECORD", ui.scaled(Vec2i.init(15, 43)), .px8, ui_mod.color_accent);
        ui.drawTime(r, ship.bestLap(), ui.scaled(Vec2i.init(15, 55)), .px8, ui_mod.color_default);

        if (!ship.flags.direction_forward) {
            ui.drawTextCentered(r, "WRONG WAY", ui.pos(Anchor.middle | Anchor.center, Vec2i.init(-20, 0)), .px16, ui_mod.color_accent);
        }

        self.drawSpeedo(r, ui, ship.speed, ship.thrust_mag);
        if (autopilot) ui.drawText(r, "AUTO", ui.pos(Anchor.top | Anchor.right, Vec2i.init(-48, 38)), .px8, ui_mod.color_accent);

        if (ship.weapon_type != .none) {
            if (extras.weapon_icons) |icons| {
                const index: i16 = @as(i16, @intFromEnum(ship.weapon_type)) - 1;
                if (icons.resolve(index)) |texture| {
                    r.push2d(ui.pos(Anchor.top | Anchor.center, Vec2i.init(-16, 20)), ui.scaled(Vec2i.init(32, 32)), Rgba.white, texture);
                } else |_| {}
            }
        }
        if (extras.target_position) |target| {
            if (extras.reticle) |reticle| drawTargetIcon(r, ui, reticle, target);
        }
        r.setCullBackface(true);
    }

    fn drawTargetIcon(r: *render.Renderer, ui: *const Ui, reticle: u16, position: Vec3) void {
        const size = ui.scaled(r.textureSize(reticle));
        const projected = r.transform(position);
        if (projected.x < -1 or projected.x > 1 or projected.y < -1 or projected.y > 1 or projected.z >= 1) return;
        const sx: f32 = @floatFromInt(ui.screen.x);
        const sy: f32 = @floatFromInt(ui.screen.y);
        const pos = Vec2i.init(
            @as(i32, @intFromFloat(((projected.x + 1.0) / 2.0) * sx)) - @divTrunc(size.x, 2),
            @as(i32, @intFromFloat(((-projected.y + 1.0) / 2.0) * sy)) - @divTrunc(size.y, 2),
        );
        r.push2d(pos, size, Rgba.init(128, 128, 128, 128), reticle);
    }

    /// The end-of-race statistics page, dimmed over the scene, laid out
    /// like the original's (time trial variant: no position or portrait).
    fn drawResults(r: *render.Renderer, ui: *const Ui, ship: *const ship_mod.Ship) void {
        r.push2d(Vec2i.init(0, 0), ui.screen, Rgba.init(0, 0, 0, 128), r.no_texture);
        const anchor = Anchor.middle | Anchor.center;
        ui.drawTextCentered(r, "RACE OVER", ui.pos(anchor, Vec2i.init(0, -100)), .px16, ui_mod.color_accent);

        var pos = Vec2i.init(-140, -100 + 32 + 32);
        ui.drawText(r, "RACE STATISTICS", ui.pos(anchor, pos), .px8, ui_mod.color_accent);
        pos.y += 16;
        var i: usize = 0;
        while (i < defs.num_laps) : (i += 1) {
            ui.drawText(r, "LAP", ui.pos(anchor, Vec2i.init(pos.x + 8, pos.y)), .px8, ui_mod.color_accent);
            ui.drawNumber(r, @intCast(i + 1), ui.pos(anchor, Vec2i.init(pos.x + 50, pos.y)), .px8, ui_mod.color_accent);
            ui.drawTime(r, ship.lap_times[i], ui.pos(anchor, Vec2i.init(pos.x + 72, pos.y)), .px8, ui_mod.color_default);
            pos.y += 12;
        }
        pos.y += 12;
        ui.drawText(r, "RACE TIME", ui.pos(anchor, pos), .px8, ui_mod.color_accent);
        pos.y += 12;
        ui.drawTime(r, ship.raceTime(), ui.pos(anchor, Vec2i.init(pos.x + 8, pos.y)), .px8, ui_mod.color_default);
        pos.y += 12;
        ui.drawText(r, "BEST LAP", ui.pos(anchor, pos), .px8, ui_mod.color_accent);
        pos.y += 12;
        ui.drawTime(r, ship.bestLap(), ui.pos(anchor, Vec2i.init(pos.x + 8, pos.y)), .px8, ui_mod.color_default);

        ui.drawTextCentered(r, "X FOR A NEW RACE", ui.pos(anchor, Vec2i.init(0, 96)), .px8, ui_mod.color_accent);
    }

    fn drawSpeedo(self: *const Hud, r: *render.Renderer, ui: *const Ui, speed: f32, thrust: f32) void {
        const facia_pos = ui.pos(Anchor.bottom | Anchor.right, Vec2i.init(-141, -45));
        const bar_pos = ui.pos(Anchor.bottom | Anchor.right, Vec2i.init(-141, -40));
        drawSpeedoBars(r, ui, bar_pos, thrust / 65.0, Rgba.init(255, 0, 0, 128));
        drawSpeedoBars(r, ui, bar_pos, speed / 2166.0, Rgba.init(0, 0, 0, 0));
        r.push2d(facia_pos, ui.scaled(r.textureSize(self.speedo_facia)), Rgba.white, self.speedo_facia);
    }

    fn drawSpeedoBars(r: *render.Renderer, ui: *const Ui, at: Vec2i, f_in: f32, override: Rgba) void {
        if (f_in <= 0) return;
        var f = f_in;
        if (f - @floor(f) > 0.9) f = @ceil(f);
        f = @min(f, 13);

        const bars: usize = @intFromFloat(f);
        var i: usize = 1;
        while (i < bars) : (i += 1) drawSpeedoBar(r, ui, at, &speedo_bars[i - 1], &speedo_bars[i], 1, override);
        if (bars > 12) return;

        var last_fraction = f - @as(f32, @floatFromInt(bars)) + 0.1;
        if (last_fraction <= 0) return;
        last_fraction = @min(last_fraction, 1);
        const last_bar: usize = if (bars == 0) 1 else bars;
        drawSpeedoBar(r, ui, at, &speedo_bars[last_bar - 1], &speedo_bars[last_bar], last_fraction, override);
    }

    fn lerpByte(a: u8, b: u8, t: f32) u8 {
        return @intFromFloat(std.math.clamp(math.lerp(@floatFromInt(a), @floatFromInt(b), t), 0, 255));
    }

    fn drawSpeedoBar(r: *render.Renderer, ui: *const Ui, at: Vec2i, a: *const SpeedoBar, b: *const SpeedoBar, f: f32, override: Rgba) void {
        var left_color = a.color;
        var right_color = Rgba.init(lerpByte(a.color.r, b.color.r, f), lerpByte(a.color.g, b.color.g, f), lerpByte(a.color.b, b.color.b, f), lerpByte(a.color.a, b.color.a, f));
        if (override.a > 0) {
            left_color = override;
            right_color = override;
        }

        const right_h = math.lerp(@floatFromInt(a.height), @floatFromInt(b.height), f);
        const top_left = ui.scaled(Vec2i.init(a.x + 1, a.y));
        const bottom_left = ui.scaled(Vec2i.init(a.x + 1 - @divTrunc(a.height, speedo_skew), a.y + a.height));
        const top_right_x: i32 = @intFromFloat(math.lerp(@floatFromInt(a.x + 1), @floatFromInt(b.x), f));
        const top_right_y: i32 = @intFromFloat(math.lerp(@floatFromInt(a.y), @floatFromInt(b.y), f));
        const top_right = ui.scaled(Vec2i.init(top_right_x, top_right_y));
        const bottom_right = ui.scaled(Vec2i.init(
            top_right_x - @as(i32, @intFromFloat(right_h / @as(f32, @floatFromInt(speedo_skew)))),
            top_right_y + @as(i32, @intFromFloat(right_h)),
        ));

        const p = struct {
            fn corner(base: Vec2i, v: Vec2i) Vec3 {
                return Vec3.init(@floatFromInt(base.x + v.x), @floatFromInt(base.y + v.y), 0);
            }
        };
        const uv0 = Vec2.init(0, 0);
        r.pushTris(.{ .vertices = .{
            .{ .pos = p.corner(at, bottom_left), .uv = uv0, .color = left_color },
            .{ .pos = p.corner(at, top_right), .uv = uv0, .color = right_color },
            .{ .pos = p.corner(at, top_left), .uv = uv0, .color = left_color },
        } }, r.no_texture);
        r.pushTris(.{ .vertices = .{
            .{ .pos = p.corner(at, bottom_right), .uv = uv0, .color = right_color },
            .{ .pos = p.corner(at, top_right), .uv = uv0, .color = right_color },
            .{ .pos = p.corner(at, bottom_left), .uv = uv0, .color = left_color },
        } }, r.no_texture);
    }
};
