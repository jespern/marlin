pub const cache = @import("cache.zig");
pub const assets = @import("assets.zig");
pub const trial = @import("trial.zig");
pub const ghost = @import("ghost.zig");
pub const hud = @import("hud.zig");
pub const rom = @import("rom.zig");
pub const course = @import("course.zig");
pub const render = @import("render.zig");
pub const handling = @import("handling.zig");
pub const game = @import("game.zig");
pub const autopilot = @import("autopilot.zig");
pub const kart = @import("kart.zig");
test {
    _ = cache;
    _ = assets;
    _ = projectiles;
    _ = items;
    _ = race;
    _ = rom;
    _ = trial;
    _ = ghost;
    _ = hud;
    _ = course;
    _ = render;
    _ = game;
    _ = handling;
    _ = kart;
    _ = autopilot;
}

pub const engine = @import("engine.zig");

pub const race = @import("race.zig");

pub const items = @import("items.zig");

pub const projectiles = @import("projectiles.zig");
