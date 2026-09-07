//! Additive sprite particles: weapon trails and impact bursts. A fixed
//! pool, swap-removed as particles expire, drawn as camera-facing sprites
//! with the lighter blend and depth writes off.

const std = @import("std");
const math = @import("math.zig");
const render = @import("render.zig");
const Rng = @import("rng.zig").Rng;
const Vec2i = math.Vec2i;
const Vec3 = math.Vec3;
const Rgba = math.Rgba;

pub const max_particles = 1024;

pub const Kind = enum(u8) { fire = 0, fire_white = 1, smoke = 2, ebolt = 3, halo = 4, greeny = 5 };

pub const Particle = extern struct {
    position: Vec3,
    velocity: Vec3,
    size: i32,
    timer: f32,
    texture: u16,
    _pad: u16 = 0,
};

pub const Particles = extern struct {
    items: [max_particles]Particle,
    active: u32,
    /// First texture of `effects.cmp`; kinds index from it.
    texture_start: u16,
    _pad: u16 = 0,

    pub fn init(texture_start: u16) Particles {
        return .{ .items = undefined, .active = 0, .texture_start = texture_start };
    }

    pub fn spawn(self: *Particles, position: Vec3, kind: Kind, velocity: Vec3, size: i32, rng: *Rng) void {
        if (self.active >= max_particles) return;
        self.items[self.active] = .{
            .position = position,
            .velocity = velocity,
            .size = size,
            .timer = rng.float(0.75, 1.0),
            .texture = self.texture_start + @intFromEnum(kind),
        };
        self.active += 1;
    }

    pub fn update(self: *Particles, dt: f32) void {
        var i: u32 = 0;
        while (i < self.active) {
            const p = &self.items[i];
            p.timer -= dt;
            p.position = p.position.add(p.velocity.scale(dt));
            if (p.timer < 0) {
                self.active -= 1;
                self.items[i] = self.items[self.active];
                continue;
            }
            i += 1;
        }
    }

    pub fn draw(self: *const Particles, r: *render.Renderer) void {
        if (self.active == 0) return;
        r.setModelMat(&math.Mat4.identity);
        r.setDepthWrite(false);
        r.setBlendMode(.lighter);
        r.setDepthOffset(-32.0);
        for (self.items[0..self.active]) |p| {
            r.pushSprite(p.position, Vec2i.init(p.size, p.size), Rgba.init(128, 128, 128, 128), p.texture);
        }
        r.setDepthOffset(0);
        r.setDepthWrite(true);
        r.setBlendMode(.normal);
    }
};

/// A random vector inside a sphere of radius `max_len`, as `vec3_rand`.
pub fn randomVector(rng: *Rng, max_len: f32) Vec3 {
    var v: Vec3 = undefined;
    while (true) {
        v = Vec3.init(rng.float(-1, 1), rng.float(-1, 1), rng.float(-1, 1));
        if (v.lenSq() <= 1) break;
    }
    return v.scale(max_len);
}
