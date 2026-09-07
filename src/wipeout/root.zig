//! wipEout port: pure-Zig loaders and software renderer for the 1995 PSX
//! game data, presented through the terminal via Kitty graphics.
//!
//! Status: foundation slice. Track, scenery and sky load and render; game
//! logic, HUD, input, and state snapshots follow in later slices.

pub const math = @import("math.zig");
pub const bytes = @import("bytes.zig");
pub const image = @import("image.zig");
pub const assets = @import("assets.zig");
pub const render = @import("render.zig");
pub const track = @import("track.zig");
pub const object = @import("object.zig");
pub const scene = @import("scene.zig");
pub const defs = @import("defs.zig");
pub const input = @import("input.zig");
pub const rng = @import("rng.zig");
pub const ship = @import("ship.zig");
pub const camera = @import("camera.zig");
pub const post = @import("post.zig");
pub const ui = @import("ui.zig");
pub const hud = @import("hud.zig");
pub const snapshot = @import("snapshot.zig");
pub const autopilot = @import("autopilot.zig");
pub const parzlib = @import("parzlib.zig");
pub const kitty_transport = @import("kitty_transport.zig");
pub const race = @import("race.zig");
pub const weapon = @import("weapon.zig");
pub const particle = @import("particle.zig");
pub const droid = @import("droid.zig");
pub const save = @import("save.zig");
pub const menu = @import("menu.zig");
pub const game = @import("game.zig");
pub const session = @import("session.zig");
pub const bundle = @import("bundle.zig");

/// Per-circuit sky placement from the original game definition, indexed
/// by PSX track directory number (1-14).
pub fn skyYOffset(track_number: u8) f32 {
    return switch (track_number) {
        1 => -820,
        2 => -2520,
        3 => -1930,
        4, 5 => -5000,
        7 => -2260,
        8 => -40,
        9, 13 => -2700,
        11 => -240,
        12 => -2120,
        else => 0,
    };
}

/// Camera forward vector for the game's yaw/pitch/roll angle convention.
pub fn cameraForward(angle: math.Vec3) math.Vec3 {
    var m = math.Mat4.identity;
    m.setYawPitchRoll(angle);
    return m.forward();
}

/// Yaw/pitch that point `cameraForward` along `dir`.
pub fn anglesTowards(dir: math.Vec3) math.Vec3 {
    const d = dir.normalize();
    const pitch = @import("std").math.asin(@import("std").math.clamp(-d.y, -1.0, 1.0));
    const yaw = -@import("std").math.atan2(d.x, d.z);
    return math.Vec3.init(pitch, yaw, 0);
}

test {
    @import("std").testing.refAllDecls(@This());
}
