//! Unit tests for hud.zig. Tests live beside the module they cover
//! (docs/TESTING.md).

const std = @import("std");

const hud = @import("hud.zig");
const ship = @import("ship.zig");

test {
    std.testing.refAllDecls(hud);
}

test "the start countdown reads GET READY, 3, 2, 1, GO, and nothing when the intro is skipped" {
    // Hovering with plenty of time: the small hint.
    const ready = hud.countdown(.intro, ship.update_time_initial).?;
    try std.testing.expectEqualStrings("GET READY", ready.text);
    try std.testing.expect(!ready.big);

    // The last three seconds count down in big digits.
    try std.testing.expectEqualStrings("3", hud.countdown(.intro, 2.99).?.text);
    try std.testing.expectEqualStrings("3", hud.countdown(.intro, 2.01).?.text);
    try std.testing.expectEqualStrings("2", hud.countdown(.intro, 1.5).?.text);
    try std.testing.expectEqualStrings("1", hud.countdown(.intro, 0.2).?.text);
    try std.testing.expect(hud.countdown(.intro, 1.5).?.big);
    // A digit lands bright and fades toward its expiry.
    const fresh = hud.countdown(.intro, 2.99).?.color.a;
    const stale = hud.countdown(.intro, 2.05).?.color.a;
    try std.testing.expect(fresh > 240 and stale < fresh and stale >= 200);

    // GO for the first second of racing, clocked by the stall timer.
    const go = hud.countdown(.race, ship.update_time_stall - 0.1).?;
    try std.testing.expectEqualStrings("GO", go.text);
    try std.testing.expect(go.big);
    try std.testing.expect(hud.countdown(.race, ship.update_time_stall - 0.99) != null);
    try std.testing.expect(hud.countdown(.race, ship.update_time_stall - 1.5) == null);

    // A skipped intro starts racing with the timer at zero: no cue at all.
    try std.testing.expect(hud.countdown(.race, 0) == null);
    try std.testing.expect(hud.countdown(.intro, 0) == null);
    // Nothing during rescue or for AI modes.
    try std.testing.expect(hud.countdown(.rescue, 2.0) == null);
    try std.testing.expect(hud.countdown(.ai_intro, 2.0) == null);
}
