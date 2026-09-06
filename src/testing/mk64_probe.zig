const std = @import("std");
const mk64 = @import("mk64");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 6) {
        std.debug.print("usage: mk64-probe ROM snapshot.ppm [path-point] [drive-ticks]\n", .{});
        return error.InvalidArguments;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(bytes);
    var track = try mk64.course.Course.load(init.gpa, bytes);
    defer track.deinit();
    const renderer = try init.gpa.create(mk64.render.Renderer);
    defer init.gpa.destroy(renderer);
    const point = if (args.len > 3) try std.fmt.parseFloat(f32, args[3]) else 0;
    if (!std.math.isFinite(point)) return error.InvalidPathPoint;
    const sprite = try mk64.kart.Sprite.load(init.gpa, bytes);
    var game = mk64.game.Game.init(&track);
    var trial: ?mk64.trial.Trial = null;
    var race: ?mk64.race.Race = null;
    const opponents = try init.gpa.alloc(mk64.kart.Sprite, 7);
    defer init.gpa.free(opponents);
    const hud = try mk64.hud.Hud.load(init.gpa, bytes);
    if (args.len >= 5 and std.mem.eql(u8, args[4], "asset-audit")) {
        const sprites = try init.gpa.alloc(mk64.kart.Sprite, 8);
        defer init.gpa.free(sprites);
        sprites[0] = sprite;
        for (sprites[1..], 1..) |*kart, i| kart.* = try mk64.kart.Sprite.loadCharacter(init.gpa, bytes, i);
        const json = try std.json.Stringify.valueAlloc(init.gpa, .{
            .schema = "marlin-mk64-asset-audit-v1",
            .source_sha1 = "579c48e211ae952530ffc8738709f078d5dd215e",
            .rom_bytes = bytes.len,
            .loaded_vertices = track.vertices.len,
            .visual = track.triangles,
            .collision = track.collision,
            .textures = track.textures,
            .path = track.path,
            .sprites = sprites,
            .hud = hud,
        }, .{ .emit_strings_as_arrays = true });
        defer init.gpa.free(json);
        var file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{});
        defer file.close(init.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(init.io, &buffer);
        try writer.interface.writeAll(json);
        try writer.interface.flush();
        std.debug.print("asset audit: {d} visual triangles, {d} collision triangles, {d} path points; decoded resources written to {s}\n", .{ track.triangles.len, track.collision.len, track.path.len, args[2] });
        return;
    }
    if (args.len >= 5) {
        if (std.mem.eql(u8, args[4], "item-view")) {
            for (opponents, 0..) |*kart, i| kart.* = try mk64.kart.Sprite.loadCharacter(init.gpa, bytes, i + 1);
            race = mk64.race.Race.init(&track, .cc100, &game);
            game.pos = mk64.items.positions[2].add(.{ .x = 0, .y = 0, .z = 90 });
            game.yaw = 0;
            trial = .{ .phase = .racing, .elapsed = 60 };
            race.?.items.held[0] = true;
            race.?.items.kind[0] = .red_shell;
            _ = race.?.items.world.spawn(.red_shell, 0, game, false);
            _ = race.?.items.world.spawn(.banana, 0, game, true);
            race.?.items.world.actors[0].pos = game.pos.add(.{ .x = -12, .y = 3, .z = -40 });
            race.?.items.world.actors[1].pos = game.pos.add(.{ .x = 12, .y = 3, .z = -40 });
            race.?.items.beginHold(0, game);
            race.?.items.world.shields[0] = game.pos.add(.{ .x = 0, .y = 3, .z = 14 });
            race.?.items.world.actors[0].target = 0;
            race.?.items.world.actors[0].owner = 1;
        } else if (std.mem.eql(u8, args[4], "race-test")) {
            for (opponents, 0..) |*kart, i| kart.* = try mk64.kart.Sprite.loadCharacter(init.gpa, bytes, i + 1);
            const result = try raceTest(&track, if (args.len > 5) std.meta.stringToEnum(mk64.engine.Class, args[5]) orelse return error.InvalidClass else .cc100);
            game = result.game;
            trial = result.trial;
            race = result.race;
        } else if (std.mem.eql(u8, args[4], "trial-test")) {
            const result = try trialTest(init.gpa, init.io, &track, args[2], if (args.len > 5) std.meta.stringToEnum(mk64.engine.Class, args[5]) orelse return error.InvalidClass else .cc100);
            game = result.game;
            trial = result.trial;
        } else if (std.mem.eql(u8, args[4], "grid")) {
            game = mk64.trial.Trial.grid(&track);
            trial = .{};
        } else if (std.mem.eql(u8, args[4], "drift-test")) {
            game = try driftTest(&track);
        } else {
            const lap_test = std.mem.eql(u8, args[4], "lap-test");
            const ticks = if (lap_test) 15000 else try std.fmt.parseInt(u32, args[4], 10);
            if (ticks > 100000) return error.InvalidTickCount;
            for (0..ticks) |_| {
                game.tick(&track, if (lap_test) mk64.autopilot.follow(game, &track) else .{ .accelerate = true });
                if (lap_test) {
                    const body = game.pos.add(.{ .x = 0, .y = 6 + game.controller.drift.height, .z = 0 });
                    const screen = game.camera().project(body) orelse return error.KartBehindCamera;
                    if (!std.math.isFinite(screen.x) or !std.math.isFinite(screen.y) or screen.x < 0 or screen.x >= 320 or screen.y < 0 or screen.y >= 240) return error.KartOutsideCamera;
                }
                if (game.finished) break;
            }
            if (lap_test and !game.finished) {
                std.debug.print("lap test stuck at path {d}, position {d:.1},{d:.1},{d:.1}\n", .{ game.nearest, game.pos.x, game.pos.y, game.pos.z });
                return error.LapTestFailed;
            }
        }
        renderer.draw(&track, game.camera());
        if (race) |r| hud.drawDefense(renderer, game.camera(), r.items);
        if (race) |r| hud.drawProjectiles(renderer, game.camera(), r.items.world);
        if (race) |r| hud.drawBoxes(renderer, game.camera(), r.items, trial.?.elapsed);
        if (race) |r| for (r.opponents, opponents) |cpu, *kart| kart.drawOpponent(renderer, game.camera(), cpu);
        sprite.drawGame(renderer, &game);
        if (trial) |t| hud.draw(renderer, game, t, null);
        if (race) |*r| hud.drawRace(renderer, game, trial.?, r, &track);
        std.debug.print("drive: position {d:.2},{d:.2},{d:.2}; speed {d:.2}; path {d}; laps {d}; ticks {d}\n", .{ game.pos.x, game.pos.y, game.pos.z, game.speed, game.nearest, game.laps, game.ticks });
    } else renderer.draw(&track, mk64.render.Camera.along(track.path, point));
    // Benchmark rendering across a full circuit, independent of terminal throughput.
    const began = std.Io.Clock.awake.now(init.io).nanoseconds;
    for (0..73) |i| renderer.draw(&track, mk64.render.Camera.along(track.path, @floatFromInt(i * 10)));
    const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - began;
    std.debug.print("73-view render sweep: {d:.2} ms/frame\n", .{@as(f64, @floatFromInt(elapsed)) / 73 / 1e6});
    if (args.len >= 5) {
        renderer.draw(&track, game.camera());
        if (race) |r| hud.drawDefense(renderer, game.camera(), r.items);
        if (race) |r| hud.drawProjectiles(renderer, game.camera(), r.items.world);
        if (race) |r| hud.drawBoxes(renderer, game.camera(), r.items, trial.?.elapsed);
        if (race) |r| for (r.opponents, opponents) |cpu, *kart| kart.drawOpponent(renderer, game.camera(), cpu);
        sprite.drawGame(renderer, &game);
        if (trial) |t| hud.draw(renderer, game, t, null);
        if (race) |*r| hud.drawRace(renderer, game, trial.?, r, &track);
    } else renderer.draw(&track, mk64.render.Camera.along(track.path, point));
    var file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{});
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.writeAll("P6\n320 240\n255\n");
    try writer.interface.writeAll(&renderer.rgb);
    try writer.interface.flush();
    std.debug.print("MK64: {d} vertices, {d} triangles ({d} visible), {d} texture bytes, {d} path points; wrote {s}\n", .{ track.vertices.len, track.triangles.len, renderer.triangles, track.textures.len, track.path.len, args[2] });
}

fn driftTest(track: *const mk64.course.Course) !mk64.game.Game {
    var snapshot: ?mk64.game.Game = null;
    const fixtures = [_]struct { start: usize, right: bool }{ .{ .start = 460, .right = false }, .{ .start = 380, .right = true } };
    for (fixtures) |fixture| {
        const start = fixture.start;
        const right = fixture.right;
        var g = mk64.autopilot.rollingStart(track, start);
        var ready = false;
        var boosted = false;
        var max_offset: f32 = 0;
        var min_speed: f32 = 100;
        var release_speed: f32 = 0;
        var peak_boost: f32 = 0;
        var grass_ticks: usize = 0;
        var no_boost: ?mk64.game.Game = null;
        var boost_gain: f32 = 0;
        // Fixed key sequence, never reads charge state to decide inputs:
        // 20 ticks in, 25 out, 10 in, 25 out, 10 in, then release.
        // Recovery uses the same path-following steering as the lap probe.
        for (0..120) |tick| {
            const input = if (tick < 90) mk64.autopilot.driftInput(tick, right) else mk64.autopilot.follow(g, track);
            if (tick == 90) no_boost = g;
            g.tick(track, input);
            if (no_boost) |*control| {
                control.controller.drift.charge = 0;
                control.controller.drift.turbo_ticks = 0;
                control.controller.drift.boost_force = 0;
                control.tick(track, input);
                boost_gain = @max(boost_gain, g.speed - control.speed);
            }
            if (g.controller.drift.charge >= 2) {
                if (!right) snapshot = g;
                ready = true;
            }
            boosted = boosted or g.controller.drift.turbo_ticks > 0;
            const d = g.pos.sub(track.path[g.nearest].pos);
            max_offset = @max(max_offset, @sqrt(d.x * d.x + d.z * d.z));
            min_speed = @min(min_speed, g.speed);
            const contact = mk64.game.sampleContact(track, g.pos, g.yaw);
            for (contact.surfaces) |surface| {
                if (surface == 8) {
                    grass_ticks += 1;
                    break;
                }
            }
            if (tick == 89) release_speed = g.speed;
            if (tick >= 90) peak_boost = @max(peak_boost, g.speed);
        }
        std.debug.print("drift path {d} right={any}: ready={any}, boost={any}; offset {d:.1}, grass ticks {d}, speed {d:.2}->{d:.2}, boost-only gain {d:.2}\n", .{ start, right, ready, boosted, max_offset, grass_ticks, release_speed, peak_boost, boost_gain });
        if (!ready or !boosted or min_speed < 4 or peak_boost < release_speed + 0.5 or grass_ticks != 0 or boost_gain < 0.3) return error.DriftTestFailed;
    }
    return snapshot orelse error.MissingDriftSnapshot;
}

const TrialResult = struct { game: mk64.game.Game, trial: mk64.trial.Trial };
fn trialTest(gpa: std.mem.Allocator, io: std.Io, track: *const mk64.course.Course, image_path: []const u8, engine: mk64.engine.Class) !TrialResult {
    var g = mk64.trial.Trial.grid(track);
    g.controller.engine = engine;
    g.controller.top_speed = engine.top();
    var t = mk64.trial.Trial{};
    var frames: std.ArrayList(mk64.ghost.Pose) = .empty;
    defer frames.deinit(gpa);
    for (0..15000) |_| {
        const before = t.elapsed;
        if (t.phase == .racing and before == 0) try frames.append(gpa, mk64.ghost.pose(g));
        // Synthetic inputs stand in for manual play to exercise the eligible-save path.
        t.tick(&g, track, mk64.autopilot.follow(g, track), false);
        if (t.elapsed > before) try frames.append(gpa, mk64.ghost.pose(g));
        if (t.phase == .finished) break;
    }
    if (!t.eligible() or t.laps != 3) return error.TrialDidNotFinish;
    const run = mk64.ghost.Run{ .ticks = t.elapsed, .splits = t.splits, .frames = frames.items };
    const path = try std.fmt.allocPrint(gpa, "{s}.ghost", .{image_path});
    defer gpa.free(path);
    try mk64.ghost.save(gpa, io, path, run);
    const loaded = (try mk64.ghost.load(gpa, io, path)) orelse return error.GhostMissing;
    defer loaded.deinit(gpa);
    if (loaded.ticks != run.ticks or !std.mem.eql(u32, &loaded.splits, &run.splits) or loaded.frames.len != run.frames.len) return error.GhostMismatch;
    for (loaded.frames, run.frames) |actual, expected| {
        if (!std.meta.eql(actual, expected)) return error.GhostMismatch;
    }
    t.saved = true;
    std.debug.print("time trial: {d} ticks; splits {any}; {d} ghost samples saved/reloaded exactly\n", .{ t.elapsed, t.splits, loaded.frames.len });
    return .{ .game = g, .trial = t };
}

const RaceResult = struct { game: mk64.game.Game, trial: mk64.trial.Trial, race: mk64.race.Race };
fn raceTest(track: *const mk64.course.Course, engine: mk64.engine.Class) !RaceResult {
    try projectileTest(track);
    try redShellTest(track);
    try defenseTest(track);
    var g = mk64.trial.Trial.grid(track);
    var t = mk64.trial.Trial{};
    var r = mk64.race.Race.init(track, engine, &g);
    var snapshot: RaceResult = undefined;
    if (r.place(g, track) != 8) return error.InvalidGridOrder;
    for (0..18000) |tick| {
        if (tick == 200) {
            const old = r;
            g.paused = true;
            r.tick(&g, t, track);
            if (!std.meta.eql(old, r)) return error.PausedRaceAdvanced;
            g.paused = false;
        }
        t.tick(&g, track, mk64.autopilot.follow(g, track), true);
        r.tick(&g, t, track);
        if (t.phase == .racing) r.items.autoUse(0, &g);
        if (r.items.held[0]) snapshot = .{ .game = g, .trial = t, .race = r };
        if (tick == 240) snapshot = .{ .game = g, .trial = t, .race = r };
        if (r.finish_count == 8) break;
    }
    std.debug.print("race {s}: {d}/8 finished; order {any}; contacts {d}; CPU boosts {d}\n", .{ engine.label(), r.finish_count, r.finish_order, r.contacts, r.boosts });
    for (r.opponents, r.trials, 0..) |cpu, result, i| {
        std.debug.print("  CPU {d}: lap {d}, path {d}, valid={any}, ticks {d}\n", .{ i + 1, result.laps, cpu.nearest, result.valid, result.elapsed });
        if (!result.valid) return error.InvalidCpuLap;
    }
    std.debug.print("  items: {d} pickups, {d} uses, {d} hits, {d} blocks\n", .{ r.items.pickups, r.items.uses, r.items.world.hits, r.items.world.blocks });
    if (r.items.pickups == 0 or r.items.uses == 0) return error.ItemsNeverUsed;
    if (r.finish_count != 8 or !t.valid) return error.RaceTestFailed;
    var first: u32 = std.math.maxInt(u32);
    var last: u32 = 0;
    for (r.trials) |result| {
        first = @min(first, result.elapsed);
        last = @max(last, result.elapsed);
    }
    std.debug.print("  CPU field spread: {d:.1}s; baseline player place: {d}/8\n", .{ @as(f32, @floatFromInt(last - first)) / 60, r.finish_place[0] });
    if (last - first < 600 or r.finish_place[0] > 4) return error.CpuFieldTooStrongOrUniform;
    if (engine == .cc100 and r.boosts == 0) return error.CpuNeverBoosted;
    return snapshot;
}

fn projectileTest(track: *const mk64.course.Course) !void {
    var owner = mk64.trial.Trial.grid(track);
    var target = owner;
    target.pos.z -= 18;
    var dummy = owner;
    dummy.finished = true;
    var w = mk64.projectiles.World{};
    if (!w.spawn(.shell, 0, owner, false)) return error.NoProjectile;
    for (0..5) |_| w.tick(track, .{ &owner, &target, &dummy, &dummy, &dummy, &dummy, &dummy, &dummy });
    if (w.hits != 1 or target.controller.spin_ticks == 0 or owner.controller.spin_ticks != 0) return error.ProjectileMissedTarget;
    // Stationary banana at a racer's body uses the same collision/recovery rules.
    target.controller.hit_immunity = 0;
    w.actors[0] = .{ .active = true, .kind = .banana, .owner = 0, .pos = target.pos.add(.{ .x = 0, .y = 3, .z = 0 }) };
    w.tick(track, .{ &owner, &target, &dummy, &dummy, &dummy, &dummy, &dummy, &dummy });
    if (w.hits != 2) return error.BananaMissedTarget;
}

fn redShellTest(track: *const mk64.course.Course) !void {
    var owner = mk64.trial.Trial.grid(track);
    var target = owner;
    target.pos.x += 20;
    target.pos.z -= 80;
    target.path_progress = 4;
    var dummy = owner;
    dummy.finished = true;
    var red = mk64.projectiles.World{};
    var green = mk64.projectiles.World{};
    _ = red.spawn(.red_shell, 0, owner, false);
    _ = green.spawn(.shell, 0, owner, false);
    for (0..30) |_| green.tick(track, .{ &owner, &target, &dummy, &dummy, &dummy, &dummy, &dummy, &dummy });
    if (green.hits != 0) return error.InvalidHomingFixture;
    for (0..30) |_| red.tick(track, .{ &owner, &target, &dummy, &dummy, &dummy, &dummy, &dummy, &dummy });
    if (red.hits != 1) return error.RedShellFailedToHome;
}

fn defenseTest(track: *const mk64.course.Course) !void {
    var defender = mk64.trial.Trial.grid(track);
    var attacker = defender;
    attacker.pos.z += 60;
    var dummy = defender;
    dummy.finished = true;
    const racers = [8]*mk64.game.Game{ &defender, &attacker, &dummy, &dummy, &dummy, &dummy, &dummy, &dummy };
    for ([_]mk64.items.Kind{ .banana, .shell, .red_shell }) |kind| {
        var items = mk64.items.Items{};
        items.held[0] = true;
        items.kind[0] = kind;
        items.beginHold(0, defender);
        _ = items.world.spawn(.red_shell, 1, attacker, false);
        for (0..15) |_| {
            items.prepareDefense(track, racers);
            items.world.tick(track, racers);
            items.finishDefense();
        }
        if (items.world.blocks != 1 or items.world.hits != 0 or items.held[0] or items.trailing[0]) return error.DefenseFailed;
        // Release after interception must not throw another item.
        items.releaseHold(0, &defender, false);
        if (items.uses != 0) return error.BlockedItemUsedTwice;
    }
    var items = mk64.items.Items{};
    items.held[0] = true;
    items.kind[0] = .banana;
    items.beginHold(0, defender);
    _ = items.world.spawn(.shell, 1, attacker, false);
    _ = items.world.spawn(.shell, 1, attacker, false);
    for (0..15) |_| {
        items.prepareDefense(track, racers);
        items.world.tick(track, racers);
        items.finishDefense();
    }
    if (items.world.blocks != 1 or items.world.hits != 1) return error.GuardBlockedMoreThanOneShell;
}
