//! Unit tests for pairing.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in pairing.zig.

const std = @import("std");
const Io = std.Io;
const pairing = @import("pairing.zig");
const temp_dir = @import("../testing/temp_dir.zig");

test {
    std.testing.refAllDecls(pairing);
}

const token_a: [pairing.token_len]u8 = @splat('a');
const token_b: [pairing.token_len]u8 = @splat('b');

test "code match ignores separators and nothing else" {
    try std.testing.expect(pairing.codeMatches("482913", "482913"));
    try std.testing.expect(pairing.codeMatches("482913", "482 913"));
    try std.testing.expect(pairing.codeMatches("482913", " 482-913\n"));
    try std.testing.expect(!pairing.codeMatches("482913", "482914"));
    try std.testing.expect(!pairing.codeMatches("482913", "48291"));
    try std.testing.expect(!pairing.codeMatches("482913", "4829133"));
    try std.testing.expect(!pairing.codeMatches("482913", ""));
}

test "a code pairs once, then is gone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = pairing.State{ .code = .{ .digits = "123456", .expires_ms = 1000 } };
    try std.testing.expect(try pairing.redeemState(arena, &state, "123456", "iPhone", 10, &token_a));
    try std.testing.expect(state.code == null);
    try std.testing.expectEqual(@as(usize, 1), state.devices.len);
    try std.testing.expectEqual(@as(u32, 1), state.devices[0].id);
    try std.testing.expectEqualStrings("iPhone", state.devices[0].name);
    try std.testing.expect(pairing.stateHasToken(state, &token_a));
    try std.testing.expect(!pairing.stateHasToken(state, &token_b));
    // The token itself is never stored.
    try std.testing.expect(!std.mem.eql(u8, state.devices[0].token_sha256, &token_a));
    try std.testing.expect(!try pairing.redeemState(arena, &state, "123456", "iPad", 20, &token_b));
}

test "expired codes and repeated guesses burn the code" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var expired = pairing.State{ .code = .{ .digits = "123456", .expires_ms = 1000 } };
    try std.testing.expect(!try pairing.redeemState(arena, &expired, "123456", "iPhone", 1000, &token_a));
    try std.testing.expect(expired.code == null);

    var guessed = pairing.State{ .code = .{ .digits = "123456", .expires_ms = 1000 } };
    for (0..pairing.max_failures - 1) |i| {
        try std.testing.expect(!try pairing.redeemState(arena, &guessed, "000000", "x", 1, &token_a));
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), guessed.code.?.failures);
    }
    try std.testing.expect(!try pairing.redeemState(arena, &guessed, "000000", "x", 1, &token_a));
    try std.testing.expect(guessed.code == null);
    // The right code no longer works once burned.
    try std.testing.expect(!try pairing.redeemState(arena, &guessed, "123456", "x", 1, &token_a));
    try std.testing.expectEqual(@as(usize, 0), guessed.devices.len);
}

test "pairing past the cap drops the oldest device and keeps ids unique" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = pairing.State{};
    for (0..pairing.max_devices + 2) |i| {
        var token: [pairing.token_len]u8 = @splat('0');
        token[0] = @intCast('a' + i);
        state.code = .{ .digits = "123456", .expires_ms = 100 };
        try std.testing.expect(try pairing.redeemState(arena, &state, "123456", "d", 1, &token));
    }
    try std.testing.expectEqual(@as(usize, pairing.max_devices), state.devices.len);
    try std.testing.expectEqual(@as(u32, 3), state.devices[0].id);
    try std.testing.expectEqual(@as(u32, pairing.max_devices + 2), state.devices[state.devices.len - 1].id);
}

test "issue, redeem, verify, and revoke round-trip through the private file" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try temp_dir.Dir.initFromProcess(gpa, io, "pairing-test");
    defer tmp.deinit();
    const root = try std.fs.path.join(gpa, &.{ tmp.path, "marlin", "web" });
    defer gpa.free(root);

    // Nothing paired yet: no file, nothing verifies.
    try std.testing.expect(!try pairing.verify(gpa, io, root, &token_a));
    try std.testing.expect((try pairing.redeem(gpa, io, root, "123456", "iPhone", 0)) == null);

    const code = try pairing.issue(gpa, io, root, 1000);
    for (code) |ch| try std.testing.expect(std.ascii.isDigit(ch));
    const redeemed = (try pairing.redeem(gpa, io, root, &code, "iPhone", 2000)).?;
    try std.testing.expectEqual(@as(u32, 1), redeemed.id);
    try std.testing.expect(try pairing.verify(gpa, io, root, &redeemed.token));
    try std.testing.expect(!try pairing.verify(gpa, io, root, &token_a));
    try std.testing.expect(!try pairing.verify(gpa, io, root, "short"));
    // Single use.
    try std.testing.expect((try pairing.redeem(gpa, io, root, &code, "iPad", 3000)) == null);

    const file = try std.fs.path.join(gpa, &.{ root, "pairing.json" });
    defer gpa.free(file);
    const stat = try Io.Dir.cwd().statFile(io, file, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@backingInt(stat.permissions) & 0o777)));
    const bytes = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(64 * 1024));
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &redeemed.token) == null);

    try std.testing.expect(!try pairing.revoke(gpa, io, root, 99));
    try std.testing.expect(try pairing.revoke(gpa, io, root, redeemed.id));
    try std.testing.expect(!try pairing.verify(gpa, io, root, &redeemed.token));
}

test "device names come from the user agent" {
    try std.testing.expectEqualStrings("iPhone", pairing.deviceName("Mozilla/5.0 (iPhone; CPU iPhone OS 19_1 like Mac OS X)"));
    try std.testing.expectEqualStrings("Mac", pairing.deviceName("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"));
    try std.testing.expectEqualStrings("Android", pairing.deviceName("Mozilla/5.0 (Linux; Android 15)"));
    try std.testing.expectEqualStrings("browser", pairing.deviceName(null));
    try std.testing.expectEqualStrings("browser", pairing.deviceName("curl/8.7.1"));
}
