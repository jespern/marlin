//! A simple heading controller: full thrust and steering towards a point
//! two sections ahead on the centre line. Not the original's AI; enough to
//! lap a course hands-off, demo the game, and drive parity replays.

const std = @import("std");
const math = @import("math.zig");
const input = @import("input.zig");
const ship_mod = @import("ship.zig");
const track_mod = @import("track.zig");

pub fn steer(ship: *const ship_mod.Ship, track: *const track_mod.Track, in: *input.State) void {
    const sections = track.sections;
    var ahead = sections[ship.section].next;
    ahead = sections[ahead].next;
    const target = sections[ahead].center.sub(ship.position);
    const desired_yaw = -std.math.atan2(target.x, target.z);
    const delta = math.wrapAngle(desired_yaw - ship.angle.y);
    in.set(.thrust, ship.mode != .intro and !ship.finished());
    in.set(.left, delta > 0.02);
    in.set(.right, delta < -0.02);
    in.set(.up, false);
    in.set(.down, false);
    in.set(.brake_left, false);
    in.set(.brake_right, false);
}
