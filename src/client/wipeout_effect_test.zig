const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const wipeout_effect = @import("wipeout_effect.zig");
const store = @import("asset_store");
const wipeout = @import("../wipeout/root.zig");

test "Backspace returns a race to the main menu and releases controls" {
    var session: wipeout.session.Session = undefined;
    session.state = wipeout.game.State.init(wipeout.save.defaults);
    session.state.startRaceDirect(1, 0, false);
    session.input = .{};
    session.input.set(.left, true);
    session.input.set(.fire, true);
    session.autopilot = true;
    var game = wipeout_effect.Game{ .session = &session, .gpa = undefined };

    try std.testing.expect(game.setKey(.{ .codepoint = vaxis.Key.backspace }, true));
    try std.testing.expectEqual(wipeout.game.Scene.main_menu, session.state.scene);
    try std.testing.expect(!session.input.anyHeld());
    try std.testing.expect(!session.autopilot);
}

test "Tab cannot enable the client autopilot" {
    var session: wipeout.session.Session = undefined;
    session.autopilot = false;
    var game = wipeout_effect.Game{ .session = &session, .gpa = undefined };

    try std.testing.expect(!game.setKey(.{ .codepoint = vaxis.Key.tab }, true));
    try std.testing.expect(!session.autopilot);
}

test "releaseKeys clears held controls and autopilot" {
    var session: wipeout.session.Session = undefined;
    session.input = .{};
    session.input.set(.right, true);
    session.input.set(.fire, true);
    session.autopilot = true;
    var game = wipeout_effect.Game{ .session = &session, .gpa = undefined };

    game.releaseKeys();
    try std.testing.expect(!session.input.anyHeld());
    try std.testing.expect(!session.input.isPressed(.fire));
    try std.testing.expect(!session.autopilot);
}

test "bundle destination sits in the data root" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MARLIN_WIPEOUT_DATA", "/tmp/wp-root");
    const dest = try wipeout_effect.bundleDestination(gpa, &environ);
    defer gpa.free(dest);
    try std.testing.expectEqualStrings("/tmp/wp-root/wo.pak", dest);
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
    try environ.put("XDG_CACHE_HOME", temp.path);
    try environ.put("XDG_DATA_HOME", temp.path);
    if (std.c.getenv("MARLIN_WIPEOUT_URL")) |url| try environ.put("MARLIN_WIPEOUT_URL", std.mem.span(url));
    try environ.put("XDG_STATE_HOME", temp.path);

    // Nothing there yet: the game reports missing assets.
    try std.testing.expectError(error.AssetsMissing, wipeout_effect.Game.create(gpa, io, &environ, .{}));

    const dest = try wipeout_effect.bundleDestination(gpa, &environ);
    defer gpa.free(dest);
    var progress = store.Progress{};
    try wipeout.assets.download(gpa, io, wipeout_effect.bundleUrl(&environ), dest, &progress);
    try std.testing.expect(progress.done.load(.acquire) > 1024 * 1024);

    var bundle = try wipeout.bundle.Bundle.open(gpa, io, dest);
    defer bundle.deinit();
    try std.testing.expect(bundle.get(wipeout.assets.tree_probe_file) != null);

    // And the whole game comes up from the bundle alone.
    const game = try wipeout_effect.Game.create(gpa, io, &environ, .{});
    defer game.destroy();
    try std.testing.expect(game.session.bundle != null);
}

test "!wipeout arguments: circuits and pilots by name, flags in any order, raw PSX numbers on request" {
    var buf: [256]u8 = undefined;
    const parse = wipeout_effect.parseLaunchArgs;

    const terramax = parse(&.{ "terramax", "rapier" }, &buf).ok;
    try std.testing.expectEqual(@as(u8, 6), terramax.track); // TERRAMAX's Rapier layout
    try std.testing.expect(terramax.rapier and terramax.explicit);
    try std.testing.expectEqual(@as(u8, 4), parse(&.{"karb"}, &buf).ok.track); // KARBONIS V, Venom
    try std.testing.expectEqual(@as(u8, 6), parse(&.{ "RAPIER", "Terr" }, &buf).ok.track); // order and case do not matter
    try std.testing.expectEqual(@as(u8, 1), parse(&.{"3"}, &buf).ok.track); // circuit 3 = TERRAMAX = PSX track 1
    try std.testing.expectEqual(@as(u8, 12), parse(&.{"track12"}, &buf).ok.track);
    try std.testing.expectEqual(@as(u8, 2), parse(&.{"arial"}, &buf).ok.pilot);
    try std.testing.expectEqual(@as(u8, 5), parse(&.{"arian"}, &buf).ok.pilot);
    try std.testing.expectEqual(@as(u8, 6), parse(&.{"feisar"}, &buf).ok.pilot); // a team names its first pilot
    try std.testing.expectEqual(@as(u8, 5), parse(&.{"pilot5"}, &buf).ok.pilot);

    const flags = parse(&.{ "dekka", "easy", "trial", "nointro", "nocrt" }, &buf).ok;
    try std.testing.expectEqual(@as(u8, 0), flags.pilot);
    try std.testing.expectEqual(wipeout.race.Difficulty.easy, flags.difficulty.?);
    try std.testing.expect(flags.time_trial and !flags.intro and flags.crt.? == false and flags.explicit);

    const bare = parse(&.{}, &buf).ok;
    try std.testing.expect(!bare.explicit); // resumes
    try std.testing.expect(parse(&.{"crt"}, &buf).ok.explicit == false); // a display flag alone still resumes

    // Refusals say what would work.
    const ambiguous = parse(&.{"k"}, &buf).invalid;
    try std.testing.expect(std.mem.indexOf(u8, ambiguous, "karbonis korodera") != null);
    try std.testing.expect(std.mem.indexOf(u8, parse(&.{"tetsuo"}, &buf).invalid, "surname") != null);
    try std.testing.expect(std.mem.indexOf(u8, parse(&.{"bogus"}, &buf).invalid, "circuits:") != null);
    try std.testing.expect(std.mem.indexOf(u8, parse(&.{"9"}, &buf).invalid, "1-7") != null);
    try std.testing.expect(std.mem.indexOf(u8, parse(&.{"track15"}, &buf).invalid, "1-14") != null);
}

test "!wipeout suggestions: circuits first, then pilots and flags, filtered by the word being typed" {
    var out: [32]wipeout_effect.Candidate = undefined;
    const first = wipeout_effect.launchCandidates(&.{}, "", &out);
    try std.testing.expectEqual(@as(usize, 7), first.len);
    try std.testing.expectEqualStrings("altima", first[0].word);
    try std.testing.expectEqualStrings("FIRESTAR · circuit 7 (bonus)", first[6].description);

    const te = wipeout_effect.launchCandidates(&.{}, "te", &out);
    try std.testing.expectEqual(@as(usize, 1), te.len);
    try std.testing.expectEqualStrings("terramax", te[0].word);

    const after_circuit = wipeout_effect.launchCandidates(&.{"terramax"}, "", &out);
    try std.testing.expectEqualStrings("dekka", after_circuit[0].word); // pilots come next
    for (after_circuit) |c| try std.testing.expect(!std.mem.eql(u8, c.word, "altima"));

    const r = wipeout_effect.launchCandidates(&.{"terramax"}, "r", &out);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("rapier", r[0].word);
    try std.testing.expectEqualStrings("race", r[1].word);

    const done = wipeout_effect.launchCandidates(&.{ "terramax", "arial", "rapier", "hard", "trial" }, "", &out);
    for (done) |c| try std.testing.expect(std.mem.eql(u8, c.word, "nointro") or std.mem.eql(u8, c.word, "crt") or std.mem.eql(u8, c.word, "nocrt") or std.mem.eql(u8, c.word, "new"));

    var buf: [96]u8 = undefined;
    const label = wipeout_effect.describeSelection(.{ .track = 6, .rapier = true, .pilot = 2, .explicit = true }, &buf);
    try std.testing.expectEqualStrings("TERRAMAX · RAPIER CLASS · ARIAL TETSUO", label);
    // Every key is the first word of the arcade name it stands for.
    for (wipeout_effect.circuit_keys, wipeout.defs.circuit_names) |key, name| {
        var words = std.mem.splitScalar(u8, name, ' ');
        try std.testing.expect(std.ascii.eqlIgnoreCase(key, words.next().?));
    }
}
