const std = @import("std");
const Io = std.Io;
const wipeout_effect = @import("wipeout_effect.zig");
const voice = @import("voice.zig");
const wipeout = @import("../wipeout/root.zig");

test "bundle destination sits in the data root" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MARLIN_WIPEOUT_DATA", "/tmp/wp-root");
    const dest = try wipeout_effect.bundleDestination(gpa, &environ);
    defer gpa.free(dest);
    try std.testing.expectEqualStrings("/tmp/wp-root/wipeout.pak", dest);
    try std.testing.expectEqualStrings(wipeout.assets.default_bundle_url, wipeout_effect.bundleUrl(&environ));
    try environ.put("MARLIN_WIPEOUT_URL", "http://127.0.0.1:1/x.pak");
    try std.testing.expectEqualStrings("http://127.0.0.1:1/x.pak", wipeout_effect.bundleUrl(&environ));
}

test "bundle download: real network smoke (MARLIN_WIPEOUT_NET_TEST=1)" {
    if (std.c.getenv("MARLIN_WIPEOUT_NET_TEST") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-wipeout-bundle");
    defer temp.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MARLIN_WIPEOUT_DATA", temp.path);
    if (std.c.getenv("MARLIN_WIPEOUT_URL")) |url| try environ.put("MARLIN_WIPEOUT_URL", std.mem.span(url));
    try environ.put("XDG_STATE_HOME", temp.path);

    // Nothing there yet: the game reports missing assets.
    try std.testing.expectError(error.AssetsMissing, wipeout_effect.Game.create(gpa, io, &environ, .{}));

    const dest = try wipeout_effect.bundleDestination(gpa, &environ);
    defer gpa.free(dest);
    var progress = voice.DownloadProgress{};
    try voice.download(gpa, io, wipeout_effect.bundleUrl(&environ), dest, &progress);
    try std.testing.expect(progress.done.load(.acquire) > 1024 * 1024);

    var bundle = try wipeout.bundle.Bundle.open(gpa, io, dest);
    defer bundle.deinit();
    try std.testing.expect(bundle.get(wipeout.assets.tree_probe_file) != null);

    // And the whole game comes up from the bundle alone.
    const game = try wipeout_effect.Game.create(gpa, io, &environ, .{});
    defer game.destroy();
    try std.testing.expect(game.session.bundle != null);
}
