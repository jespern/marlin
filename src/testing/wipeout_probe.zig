//! Standalone probe for the wipEout port's loaders and software renderer.
//!
//!   zig build wipeout-probe -- --track 1 --seconds 10
//!   zig build wipeout-probe -- --dry-run --seconds 5
//!   zig build wipeout-probe -- --snapshot /tmp/frame.ppm --frame 120
//!
//! Live runs fly a camera along the circuit and ship each frame through the
//! Kitty graphics protocol, filling the largest centered 4:3 area. Dry runs
//! measure render, deflate, and encode cost without touching the terminal.

const std = @import("std");
const vaxis = @import("vaxis");
const Io = std.Io;
const wipeout = @import("wipeout");
const math = wipeout.math;
const Vec3 = math.Vec3;

/// Two image ids alternate so each frame is placed as a new image before the
/// previous one is deleted; the terminal never shows a gap between frames.
const image_ids = [2]u32{ 0x57_49_50_31, 0x57_49_50_32 };
const chunk_size: usize = 4096;
/// Sleep to this close to the deadline, then spin: sleep wake-up jitter is
/// a few ms, which is enough to cross a terminal refresh boundary and judder.
const spin_margin_ns: i128 = 2 * std.time.ns_per_ms;

pub const Options = struct {
    track: u8 = 1,
    fps: u16 = 30,
    /// Run length; drive mode runs until quit when unset.
    seconds: ?u16 = null,
    width: u32 = 320,
    height: u32 = 240,
    cols: ?u16 = null,
    rows: ?u16 = null,
    dry_run: bool = false,
    raw: bool = false,
    snapshot: ?[]const u8 = null,
    frame: u32 = 0,
    /// Headless: fly for --seconds, write the frames with the most uncovered
    /// pixels into this directory as PPM plus a coordinate list.
    scan_cracks: ?[]const u8 = null,
    /// With --snapshot: print rasterizer decisions for this pixel ("x,y").
    probe_pixel: ?[2]u32 = null,
    /// Triangle edge dilation in 1/16 px (renderer default when unset).
    dilation: ?i64 = null,
    /// Append one CSV line per frame (timings, payload size, tris) here.
    log_frames: ?[]const u8 = null,
    /// Put a player ship on the grid and read the keyboard instead of flying
    /// the free camera.
    drive: bool = false,
    /// Steer the ship automatically along the centre line (headless demo
    /// and physics smoke test; with --drive it yields to real key presses).
    autopilot: bool = false,
    pilot: u8 = 0,
    rapier: bool = false,
    /// Keep the countdown hover instead of starting the race at once.
    intro: bool = false,
    /// Apply the CRT post pass to the output.
    crt: bool = false,
    /// Only the player on the track (the parity harness uses this).
    time_trial: bool = false,
    /// Headless test hook: throw the player off the track at this frame.
    fall_at: ?u64 = null,
    difficulty: wipeout.race.Difficulty = .normal,
    /// zlib encoder threads (1 = single-stream std deflate).
    bands: u8 = 6,
    /// Output scale over the render size (the CRT pass wants 2).
    scale: u8 = 1,
    /// Print primitive statistics for the given pilot's ship model and exit.
    dump_model: bool = false,
    /// With --snapshot: also write the per-pixel owner ids (u16 LE, row
    /// major) to this file, tagging each ship polygon individually.
    owner_map: ?[]const u8 = null,
    /// Write the action bitmask fed to the ship each frame (one decimal per
    /// line, bit i = action i) for replay through the reference build.
    record_input: ?[]const u8 = null,
    /// Drive the ship from a recorded bitmask file instead of keys/autopilot.
    replay_input: ?[]const u8 = null,
    /// Write ship state per frame as CSV for parity comparison.
    ship_log: ?[]const u8 = null,
    assets: ?[]const u8 = null,
    /// Headless: drive the whole game (title, menus, races) from a script
    /// of "frame:action" entries; see `runGame`.
    game_script: ?[]const u8 = null,
    /// Path prefix for the frames a game script asks for.
    shots: []const u8 = "/tmp/wipeout-game",
    /// Camera speed along the centre line, in world units per second.
    speed: f32 = 6000,
    /// Camera height above the track centre line, in world units (+y is down).
    height_above: f32 = 700,
    /// How far ahead along the centre line the camera looks, in world units.
    look_ahead: f32 = 9000,
};

const Display = struct {
    cols: u16,
    rows: u16,
    row: u16,
    col: u16,
};

const Totals = struct {
    frames: u64 = 0,
    late_frames: u64 = 0,
    /// Schedule slots skipped after falling more than a frame behind.
    dropped_frames: u64 = 0,
    raw_bytes: u64 = 0,
    payload_bytes: u64 = 0,
    wire_bytes: u64 = 0,
    render_ns: i128 = 0,
    compress_ns: i128 = 0,
    encode_ns: i128 = 0,
    write_ns: i128 = 0,
    tris: u64 = 0,
    /// Longest render+deflate+encode+write span of any frame.
    max_frame_ns: i128 = 0,
    /// Frames whose local work exceeded 20 ms before pacing.
    slow_frames: u64 = 0,
    worst_frame_index: u64 = 0,
    worst_tris: u32 = 0,
    worst_pixels: u32 = 0,
    worst_visited: u32 = 0,
    worst_section: u32 = 0,
    worst_render_ns: i128 = 0,
    slow_indices: [24]u64 = undefined,
    slow_logged: usize = 0,
};

/// Camera that glides along the section centre line at constant speed and
/// looks at a point a fixed distance further along, so neither position nor
/// heading jumps when a section boundary is crossed. Both are lightly
/// smoothed to round off the corners of the polyline.
const FlyCamera = struct {
    section: u32 = 0,
    frac: f32 = 0,
    position: Vec3 = Vec3.zero,
    look: Vec3 = Vec3.zero,
    angle: Vec3 = Vec3.zero,
    started: bool = false,

    const smoothing: f32 = 0.2;

    fn advance(self: *FlyCamera, track: *const wipeout.track.Track, units_per_frame: f32, height_above: f32, look_ahead: f32) void {
        const sections = track.sections;
        var remaining = units_per_frame;
        var guard: usize = 0;
        while (guard < sections.len) : (guard += 1) {
            const here = sections[self.section];
            const seg_len = @max(sections[here.next].center.sub(here.center).len(), 1.0);
            const left = (1.0 - self.frac) * seg_len;
            if (remaining < left) {
                self.frac += remaining / seg_len;
                break;
            }
            remaining -= left;
            self.section = here.next;
            self.frac = 0;
        }

        const path_pos = pointAt(sections, self.section, self.frac).add(Vec3.init(0, -height_above, 0));
        const ahead = pointAhead(sections, self.section, self.frac, look_ahead).add(Vec3.init(0, -height_above * 0.35, 0));

        if (!self.started) {
            self.position = path_pos;
            self.look = ahead;
            self.started = true;
        } else {
            self.position = self.position.lerp(path_pos, smoothing);
            self.look = self.look.lerp(ahead, smoothing);
        }
        self.angle = wipeout.anglesTowards(self.look.sub(self.position));
    }

    fn pointAt(sections: []const wipeout.track.Section, section: u32, frac: f32) Vec3 {
        const here = sections[section];
        return here.center.lerp(sections[here.next].center, frac);
    }

    /// Walk `distance` units forward along the centre line from (section, frac).
    fn pointAhead(sections: []const wipeout.track.Section, start_section: u32, start_frac: f32, distance: f32) Vec3 {
        var section = start_section;
        var frac = start_frac;
        var remaining = distance;
        var guard: usize = 0;
        while (guard < sections.len) : (guard += 1) {
            const here = sections[section];
            const seg_len = @max(sections[here.next].center.sub(here.center).len(), 1.0);
            const left = (1.0 - frac) * seg_len;
            if (remaining < left) {
                frac += remaining / seg_len;
                break;
            }
            remaining -= left;
            section = here.next;
            frac = 0;
        }
        return pointAt(sections, section, frac);
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = parseArgs(args[1..]) catch |err| {
        if (err != error.HelpRequested) stderrPrint(init.io, "wipeout-probe: {s}\n\n", .{@errorName(err)});
        usage(init.io);
        return if (err == error.HelpRequested) 0 else 2;
    };

    const live = !options.dry_run and options.snapshot == null and options.scan_cracks == null and options.game_script == null;
    if (live and !(Io.File.stdout().isTty(init.io) catch false)) {
        stderrPrint(init.io, "wipeout-probe: stdout is not a terminal; use --dry-run or --snapshot\n", .{});
        return 2;
    }

    const root = if (options.assets) |explicit|
        try arena.dupe(u8, explicit)
    else
        wipeout.assets.defaultRoot(arena, init.environ_map) catch |err| {
            stderrPrint(init.io, "wipeout-probe: cannot resolve asset root: {s}\n", .{@errorName(err)});
            return 2;
        };

    const display = if (options.cols != null or options.rows != null)
        Display{ .cols = options.cols orelse 80, .rows = options.rows orelse 24, .row = 0, .col = 0 }
    else if (!live)
        fitDisplay(80, 24, 640, 384)
    else
        terminalDisplay(init.io) catch fitDisplay(80, 24, 640, 384);

    if (options.game_script) |script| {
        runGame(init.gpa, init.io, options, root, script) catch |err| {
            stderrPrint(init.io, "wipeout-probe: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }

    run(init.gpa, init.io, options, root, display) catch |err| {
        stderrPrint(init.io, "wipeout-probe: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn terminalDisplay(io: Io) !Display {
    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();
    const size = try tty.getWinsize();
    return fitDisplay(size.cols, size.rows, size.x_pixel, size.y_pixel);
}

fn fitDisplay(term_cols: u16, term_rows: u16, pixel_width: u16, pixel_height: u16) Display {
    if (term_cols == 0 or term_rows == 0) return .{ .cols = 80, .rows = 24, .row = 0, .col = 0 };
    const cell_width: f32 = if (pixel_width > 0) @as(f32, @floatFromInt(pixel_width)) / @as(f32, @floatFromInt(term_cols)) else 8.0;
    const cell_height: f32 = if (pixel_height > 0) @as(f32, @floatFromInt(pixel_height)) / @as(f32, @floatFromInt(term_rows)) else 16.0;
    const full_width = @as(f32, @floatFromInt(term_cols)) * cell_width;
    const full_height = @as(f32, @floatFromInt(term_rows)) * cell_height;
    var cols = term_cols;
    var rows = term_rows;
    if (full_width / full_height > 4.0 / 3.0) {
        cols = @intFromFloat(@round(full_height * (4.0 / 3.0) / cell_width));
    } else {
        rows = @intFromFloat(@round(full_width * (3.0 / 4.0) / cell_height));
    }
    cols = std.math.clamp(cols, 1, term_cols);
    rows = std.math.clamp(rows, 1, term_rows);
    return .{ .cols = cols, .rows = rows, .row = (term_rows - rows) / 2, .col = (term_cols - cols) / 2 };
}

fn run(gpa: std.mem.Allocator, io: Io, options: Options, root: []const u8, display: Display) !void {
    const live = !options.dry_run and options.snapshot == null and options.scan_cracks == null and options.game_script == null;
    // The extracted tree when it is there, else the bundle (the checkout
    // ships one under assets/), the same way the client opens them.
    var source = wipeout.assets.openSource(gpa, io, root) catch |err| {
        stderrPrint(io, "wipeout-probe: no wipEout data under {s}: {s}\n", .{ root, @errorName(err) });
        return err;
    };
    defer if (source == .bundle) source.bundle.deinit();
    const assets = switch (source) {
        .tree => wipeout.assets.Assets.init(io, gpa, root),
        .bundle => |*b| wipeout.assets.Assets.initBundle(io, gpa, root, b),
    };
    var dir_buf: [32]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "wipeout/track{d:0>2}", .{options.track});

    var renderer = try wipeout.render.Renderer.init(gpa, options.width, options.height);
    defer renderer.deinit();
    if (options.dilation) |d| renderer.edge_dilation = d;

    const load_start = now(io);
    var track = try wipeout.track.load(gpa, &assets, &renderer, dir);
    defer track.deinit(gpa);
    var scene = try wipeout.scene.load(gpa, &assets, &renderer, dir, wipeout.skyYOffset(options.track));
    defer scene.deinit(gpa);
    const load_ns = now(io) - load_start;

    var lap_length: f32 = 0;
    for (track.sections) |s| lap_length += track.sections[s.next].center.sub(s.center).len();
    stderrPrint(io, "loaded {s}: {d} sections ({d:.0} units per lap), {d} faces, {d} scenery objects, {d} textures in {d:.1} ms\n", .{
        dir,
        track.sections.len,
        lap_length,
        track.faces.len,
        scene.objects.len,
        renderer.texturesLen(),
        @as(f64, @floatFromInt(load_ns)) / std.time.ns_per_ms,
    });

    const out_w: u32 = @as(u32, options.width) * options.scale;
    const out_h: u32 = @as(u32, options.height) * options.scale;
    const raw_len = @as(usize, out_w) * out_h * 3;
    const rgb = try gpa.alloc(u8, raw_len);
    defer gpa.free(rgb);
    const zbuf = try gpa.alloc(u8, raw_len + 4096);
    defer gpa.free(zbuf);
    const window = try gpa.alloc(u8, 2 * std.compress.flate.max_window_len);
    defer gpa.free(window);
    const encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(raw_len));
    defer gpa.free(encoded);

    var camera = FlyCamera{};
    const units_per_frame = options.speed / @as(f32, @floatFromInt(options.fps));

    const circuit = wipeout.defs.circuitSettings(options.track);
    var race: ?Race = null;
    if (options.drive or options.autopilot or options.replay_input != null) {
        var race_assets = try wipeout.race.loadAssets(gpa, &assets, &renderer);
        errdefer race_assets.deinit(gpa);
        const ui = try wipeout.ui.Ui.load(gpa, &assets, &renderer);
        const hud = try wipeout.hud.Hud.load(gpa, &assets, &renderer);
        var rng = wipeout.rng.Rng.seed(0x5eed);
        const field = wipeout.race.Race.init(&track, .{
            .track = options.track,
            .pilot = options.pilot,
            .class = if (options.rapier) .rapier else .venom,
            .race_type = if (options.time_trial) .time_trial else .single,
            .difficulty = options.difficulty,
            .intro = options.intro,
        }, &rng, race_assets.particle_textures.start);
        race = .{
            .assets = race_assets,
            .ui = ui,
            .hud = hud,
            .field = field,
            .input = .{},
            .rng = rng,
            .start_line_pos = circuit.start_line_pos,
            .autopilot = options.autopilot,
            .fall_at = options.fall_at,
        };
        if (options.replay_input) |path| {
            race.?.replay = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
        }
        if (options.record_input) |path| {
            race.?.record_file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        }
        if (options.ship_log) |path| {
            race.?.log_file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
            race.?.log_writer = .init(race.?.log_file.?, io, &race.?.log_buffer);
            try race.?.log_writer.?.interface.writeAll("frame,section,num,px,py,pz,vx,vy,vz,ax,ay,az,speed,thrust,flying,mode\n");
        }
        if (options.record_input) |_| {
            race.?.record_writer = .init(race.?.record_file.?, io, &race.?.record_buffer);
        }
    }
    defer if (race) |*r| {
        if (r.log_writer) |*w| w.interface.flush() catch {};
        if (r.log_file) |f| f.close(io);
        if (r.record_writer) |*w| w.interface.flush() catch {};
        if (r.record_file) |f| f.close(io);
        if (r.replay) |data| gpa.free(data);
        r.assets.deinit(gpa);
    };

    if (options.dump_model) {
        var models = try wipeout.ship.loadModels(gpa, &assets, &renderer);
        defer models.deinit(gpa);
        dumpModel(io, &models.objects[wipeout.defs.pilotToModel(options.pilot)]);
        return;
    }

    var keys: ?*KeyReader = null;
    defer if (keys) |k| k.stop();
    if (options.drive and live) {
        keys = try KeyReader.start(gpa, io);
    }

    if (options.scan_cracks) |dir_out| {
        try scanCracks(io, &renderer, &track, &scene, &camera, options, units_per_frame, rgb, dir_out);
        return;
    }

    if (options.snapshot) |path| {
        const dt = 1.0 / @as(f32, @floatFromInt(options.fps));
        var i: u32 = 0;
        while (i <= options.frame) : (i += 1) {
            if (race) |*r| r.step(&track, null, dt) else camera.advance(&track, units_per_frame, options.height_above, options.look_ahead);
        }
        renderer.debug_pixel = options.probe_pixel;
        renderer.debug_prim_ids = options.owner_map != null;
        renderFrame(&renderer, &track, &scene, &camera, if (race) |*r| r else null);
        renderer.debug_pixel = null;
        renderer.debug_prim_ids = false;
        presentFrame(&renderer, options, rgb, @as(f32, @floatFromInt(options.frame)) * dt);
        if (options.owner_map) |owner_path| {
            const file = try Io.Dir.cwd().createFile(io, owner_path, .{ .truncate = true });
            defer file.close(io);
            var obuf: [64 * 1024]u8 = undefined;
            var ow: Io.File.Writer = .init(file, io, &obuf);
            try ow.interface.writeAll(std.mem.sliceAsBytes(renderer.owner));
            try ow.interface.flush();
        }
        if (race) |*r| {
            const sh = r.field.playerShipConst();
            stderrPrint(io, "ship: section {d} pos ({d:.0},{d:.0},{d:.0}) speed {d:.0} lap {d} flying={} rank {d}\n", .{
                sh.section, sh.position.x, sh.position.y, sh.position.z, sh.speed, sh.lap, sh.flags.flying, sh.position_rank,
            });
            var active_pads: u32 = 0;
            for (r.field.pickups[0..r.field.pickup_count]) |pad| active_pads += pad.active;
            const pl = r.field.playerShipConst();
            stderrPrint(io, "  weapons active {d}, particles {d}, droid {s}, pickups {d} ({d} armed), player mode {s} rescue={} tow={} remote={} camera {s}\n", .{
                r.field.weapons.active, r.field.particles.active, @tagName(r.field.droid.mode), r.field.pickup_count, active_pads,
                @tagName(pl.mode),      pl.flags.in_rescue,       pl.flags.in_tow,              pl.flags.view_remote, @tagName(r.field.camera.mode),
            });
            for (r.field.ships, 0..) |other, pi| {
                stderrPrint(io, "  pilot {d}: mode {s} progress {d} rank {d} speed {d:.0} section {d} flying={} weapon {s} over_face {d}\n", .{
                    pi, @tagName(other.mode), other.total_section_num, other.position_rank, other.speed, other.section, other.flags.flying, @tagName(other.weapon_type), other.over_face,
                });
            }
        }
        try writePpm(io, path, @as(u32, options.width) * options.scale, @as(u32, options.height) * options.scale, rgb);
        stderrPrint(io, "wrote {s} (frame {d}, {d} tris, {d} pixels shaded, camera section {d}, {d} crack pixels)\n", .{
            path,
            options.frame,
            renderer.stats.tris,
            renderer.stats.pixels,
            camera.section,
            countCracks(&renderer),
        });
        return;
    }

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    if (!options.dry_run) {
        try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        // Keyboard flags are per screen, so push them only after switching
        // to the alternate screen: disambiguate (1), report event types
        // (2), report all keys as escape codes (8).
        if (keys != null) try out.writeAll("\x1b[>11u");
        try out.flush();
    }
    defer if (!options.dry_run) {
        for (image_ids) |id| deleteImage(out, id) catch {};
        if (keys != null) out.writeAll("\x1b[<u") catch {};
        out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    };

    const frame_ns: i128 = @divFloor(std.time.ns_per_s, @as(i128, options.fps));
    const seconds: u64 = options.seconds orelse 10;
    const unlimited = options.seconds == null and options.drive and live;
    const target_frames = @as(u64, options.fps) * seconds;
    var totals: Totals = .{};

    // Render-ahead pipeline: the frame for deadline N is rendered and encoded
    // right after frame N-1 is presented, so the only work left at the
    // deadline is the terminal write. A scheduling stall shorter than the
    // slack (~25 ms at 30 fps for this scene) then never reaches the screen.
    var log_file: ?Io.File = null;
    defer if (log_file) |f| f.close(io);
    var log_buffer: [64 * 1024]u8 = undefined;
    var log_writer: ?Io.File.Writer = null;
    if (options.log_frames) |path| {
        log_file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        log_writer = .init(log_file.?, io, &log_buffer);
        try log_writer.?.interface.writeAll("frame,section,render_ms,deflate_ms,write_ms,payload_bytes,tris,pixels\n");
    }
    defer if (log_writer) |*lw| lw.interface.flush() catch {};

    const race_ptr: ?*Race = if (race) |*r| r else null;
    var par_encoder = wipeout.parzlib.Encoder.init(gpa, options.bands);
    defer par_encoder.deinit();
    const encoder: ?*wipeout.parzlib.Encoder = if (options.bands > 1) &par_encoder else null;
    var pending = prepareFrame(io, &renderer, &track, &scene, &camera, race_ptr, keys, options, units_per_frame, rgb, zbuf, window, encoded, encoder);
    var began = now(io);
    const wall_start = began;

    while (unlimited or totals.frames < target_frames) : (totals.frames += 1) {
        var deadline = began + @as(i128, @intCast(totals.frames + 1)) * frame_ns;
        const slack = deadline - now(io);
        if (slack > spin_margin_ns) {
            io.sleep(.fromNanoseconds(@intCast(slack - spin_margin_ns)), .awake) catch {};
        } else if (slack < 0) {
            totals.late_frames += 1;
            if (-slack > frame_ns) {
                // More than a whole frame behind (the terminal stalled on a
                // write, or the machine did): resynchronise the schedule to
                // now instead of presenting every missed frame back to back,
                // which would only bury the terminal deeper.
                const behind: u64 = @intCast(@divFloor(-slack, frame_ns));
                totals.dropped_frames += behind;
                began += @as(i128, @intCast(behind)) * frame_ns;
                deadline = began + @as(i128, @intCast(totals.frames + 1)) * frame_ns;
            }
        }
        while (now(io) < deadline) std.atomic.spinLoopHint();

        const write_start = now(io);
        if (!options.dry_run) {
            const id = image_ids[@intCast(totals.frames % 2)];
            try transmitFrame(out, pending.encoded, options, display, pending.compressed, id);
            if (totals.frames > 0) try deleteImage(out, image_ids[@intCast((totals.frames + 1) % 2)]);
            try out.flush();
        }
        const write_end = now(io);

        totals.raw_bytes += rgb.len;
        totals.payload_bytes += pending.payload_len;
        totals.wire_bytes += pending.encoded.len + protocolOverhead(pending.encoded.len);
        totals.render_ns += pending.render_ns;
        totals.compress_ns += pending.compress_ns;
        totals.encode_ns += pending.encode_ns;
        totals.write_ns += write_end - write_start;
        totals.tris += pending.tris;
        if (log_writer) |*lw| {
            lw.interface.print("{d},{d},{d:.3},{d:.3},{d:.3},{d},{d},{d}\n", .{
                totals.frames,
                pending.section,
                @as(f64, @floatFromInt(pending.render_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(pending.compress_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(write_end - write_start)) / std.time.ns_per_ms,
                pending.payload_len,
                pending.tris,
                pending.pixels,
            }) catch {};
        }
        const frame_work = pending.render_ns + pending.compress_ns + pending.encode_ns + (write_end - write_start);
        if (frame_work > totals.max_frame_ns) {
            totals.max_frame_ns = frame_work;
            totals.worst_frame_index = totals.frames;
            totals.worst_tris = pending.tris;
            totals.worst_pixels = pending.pixels;
            totals.worst_visited = pending.visited;
            totals.worst_section = pending.section;
            totals.worst_render_ns = pending.render_ns;
        }
        if (frame_work > 20 * std.time.ns_per_ms) {
            totals.slow_frames += 1;
            if (totals.slow_logged < totals.slow_indices.len) {
                totals.slow_indices[totals.slow_logged] = totals.frames;
                totals.slow_logged += 1;
            }
        }

        if (keys) |k| {
            if (k.wantsQuit()) break;
        }
        pending = prepareFrame(io, &renderer, &track, &scene, &camera, race_ptr, keys, options, units_per_frame, rgb, zbuf, window, encoded, encoder);
    }

    report(io, options, display, totals, now(io) - wall_start);
    if (totals.slow_logged > 0) {
        stderrPrint(io, "  slow frame indices:", .{});
        for (totals.slow_indices[0..totals.slow_logged]) |i| stderrPrint(io, " {d}", .{i});
        stderrPrint(io, "\n", .{});
    }
}

const PreparedFrame = struct {
    encoded: []const u8,
    compressed: bool,
    payload_len: usize,
    render_ns: i128,
    compress_ns: i128,
    encode_ns: i128,
    tris: u32,
    pixels: u32,
    visited: u32,
    section: u32,
};

fn prepareFrame(
    io: Io,
    renderer: *wipeout.render.Renderer,
    track: *wipeout.track.Track,
    scene: *wipeout.scene.Scene,
    camera: *FlyCamera,
    race: ?*Race,
    keys: ?*KeyReader,
    options: Options,
    units_per_frame: f32,
    rgb: []u8,
    zbuf: []u8,
    window: []u8,
    encoded: []u8,
    encoder: ?*wipeout.parzlib.Encoder,
) PreparedFrame {
    const dt = 1.0 / @as(f32, @floatFromInt(options.fps));
    if (race) |r| {
        r.step(track, keys, dt);
    } else {
        camera.advance(track, units_per_frame, options.height_above, options.look_ahead);
    }

    const render_start = now(io);
    renderFrame(renderer, track, scene, camera, race);
    const time: f32 = if (race) |r| @as(f32, @floatFromInt(r.frame)) * dt else @as(f32, @floatFromInt(camera.section)) * 0.1;
    presentFrame(renderer, options, rgb, time);
    const render_end = now(io);

    var payload: []const u8 = rgb;
    var compressed = false;
    if (!options.raw) {
        const z: ?[]u8 = if (encoder) |enc| enc.compress(zbuf, rgb) else deflate(zbuf, window, rgb);
        if (z) |zz| {
            if (zz.len < rgb.len) {
                payload = zz;
                compressed = true;
            }
        }
    }
    const compress_end = now(io);
    const encoded_frame = std.base64.standard.Encoder.encode(encoded[0..std.base64.standard.Encoder.calcSize(payload.len)], payload);
    const encode_end = now(io);

    return .{
        .encoded = encoded_frame,
        .compressed = compressed,
        .payload_len = payload.len,
        .render_ns = render_end - render_start,
        .compress_ns = compress_end - render_end,
        .encode_ns = encode_end - compress_end,
        .tris = renderer.stats.tris,
        .pixels = renderer.stats.pixels,
        .visited = renderer.stats.visited,
        .section = if (race) |r| r.field.playerShipConst().section else camera.section,
    };
}

fn renderFrame(renderer: *wipeout.render.Renderer, track: *const wipeout.track.Track, scene: *wipeout.scene.Scene, camera: *const FlyCamera, race: ?*Race) void {
    renderer.framePrepare();
    var position = camera.position;
    var angle = camera.angle;
    if (race) |r| {
        position = r.field.camera.position;
        angle = r.field.camera.angle;
        renderer.setScreenPosition(r.field.camera.shake);
    }
    renderer.setView(position, angle);
    const forward = wipeout.cameraForward(angle);
    // Per-polygon owner tags are only meaningful for the ship.
    const tag_prims = renderer.debug_prim_ids;
    renderer.debug_prim_ids = false;
    // As in the original race loop: scenery and track are drawn with
    // back-face culling off (their winding is not consistent), ships and
    // effects with it on.
    renderer.setCullBackface(false);
    scene.draw(renderer, position, forward);
    track.draw(renderer, position, forward);
    renderer.setCullBackface(true);
    if (race) |r| {
        renderer.draw_id = 0xfffd;
        renderer.debug_prim_ids = tag_prims;
        r.field.draw(renderer, track, &r.assets, 1.0 / 60.0);
        renderer.debug_prim_ids = false;
        const player = r.field.playerShipConst();
        r.hud.draw(renderer, &r.ui, player, .{
            .show_position = r.field.race_type != .time_trial,
            .autopilot = r.autopilot,
            .weapon_icons = r.assets.weapon_icons,
            .reticle = r.assets.reticle,
            .target_position = if (player.weapon_target >= 0) r.field.ships[@intCast(player.weapon_target)].position else null,
        });
    }
}

/// Copy the finished frame out, through the CRT pass when requested.
fn presentFrame(renderer: *wipeout.render.Renderer, options: Options, rgb: []u8, time: f32) void {
    const out_w: usize = @as(usize, options.width) * options.scale;
    const out_h: usize = @as(usize, options.height) * options.scale;
    if (options.crt) {
        wipeout.post.crt(renderer.color, renderer.width, renderer.height, rgb, out_w, out_h, time);
    } else if (options.scale == 1) {
        renderer.writeRgb(rgb);
    } else {
        wipeout.post.upscale(renderer.color, renderer.width, renderer.height, rgb, out_w, out_h);
    }
}

fn dumpModel(io: Io, obj: *const wipeout.object.Object) void {
    stderrPrint(io, "model '{s}': {d} vertices, {d} primitives, radius {d:.0}\n", .{ obj.nameSlice(), obj.vertices.len, obj.primitives.len, obj.radius });
    var counts = [_]u32{0} ** 11;
    for (obj.primitives) |p| counts[@intFromEnum(p.kind)] += 1;
    inline for (@typeInfo(wipeout.object.Kind).@"enum".fields, 0..) |f, i| {
        if (counts[i] > 0) stderrPrint(io, "  {s}: {d}\n", .{ f.name, counts[i] });
    }
    // Longest edge per primitive; report the worst few.
    var worst_len = [_]f32{0} ** 6;
    var worst_idx = [_]usize{0} ** 6;
    for (obj.primitives, 0..) |p, pi| {
        const n: usize = switch (p.kind) {
            .f3, .ft3, .g3, .gt3 => 3,
            .f4, .ft4, .g4, .gt4 => 4,
            else => 0,
        };
        if (n == 0) continue;
        var longest: f32 = 0;
        var a: usize = 0;
        while (a < n) : (a += 1) {
            var b: usize = a + 1;
            while (b < n) : (b += 1) {
                longest = @max(longest, obj.vertices[p.coords[a]].sub(obj.vertices[p.coords[b]]).len());
            }
        }
        var slot: usize = 0;
        var min: f32 = std.math.floatMax(f32);
        for (worst_len, 0..) |l, i| {
            if (l < min) {
                min = l;
                slot = i;
            }
        }
        if (longest > min) {
            worst_len[slot] = longest;
            worst_idx[slot] = pi;
        }
    }
    // The first primitives, verbatim, plus the longest-edged ones.
    var first: [6]usize = .{ 0, 1, 2, 3, 4, 5 };
    for (&first, 0..) |*f, i| f.* = @min(i, obj.primitives.len - 1);
    for (first) |pi| {
        const p = obj.primitives[pi];
        stderrPrint(io, "  prim {d} {s} flag 0x{x} tex {d}:", .{ pi, @tagName(p.kind), @as(u16, @bitCast(p.flag)), p.texture });
        const n: usize = switch (p.kind) {
            .f3, .ft3, .g3, .gt3 => 3,
            .f4, .ft4, .g4, .gt4 => 4,
            else => 1,
        };
        for (p.coords[0..n]) |c| {
            const v = obj.vertices[c];
            stderrPrint(io, " [{d}]=({d:.0},{d:.0},{d:.0})", .{ c, v.x, v.y, v.z });
        }
        stderrPrint(io, "\n", .{});
    }
    for (worst_idx, 0..) |pi, i| {
        const p = obj.primitives[pi];
        stderrPrint(io, "  prim {d} {s} flag 0x{x} longest edge {d:.0}:", .{ pi, @tagName(p.kind), @as(u16, @bitCast(p.flag)), worst_len[i] });
        const n: usize = switch (p.kind) {
            .f3, .ft3, .g3, .gt3 => 3,
            else => 4,
        };
        for (p.coords[0..n]) |c| {
            const v = obj.vertices[c];
            stderrPrint(io, " [{d}]=({d:.0},{d:.0},{d:.0})", .{ c, v.x, v.y, v.z });
        }
        stderrPrint(io, "\n", .{});
    }
}

/// A single player ship, its camera, and the input feeding it.
const Race = struct {
    assets: wipeout.race.Assets,
    ui: wipeout.ui.Ui,
    hud: wipeout.hud.Hud,
    field: wipeout.race.Race,
    input: wipeout.input.State,
    rng: wipeout.rng.Rng,
    start_line_pos: u16,
    autopilot: bool,
    fall_at: ?u64 = null,
    frame: u64 = 0,
    replay: ?[]u8 = null,
    replay_pos: usize = 0,
    record_file: ?Io.File = null,
    record_buffer: [4096]u8 = undefined,
    record_writer: ?Io.File.Writer = null,
    log_file: ?Io.File = null,
    log_buffer: [16 * 1024]u8 = undefined,
    log_writer: ?Io.File.Writer = null,

    fn step(self: *Race, track: *wipeout.track.Track, keys: ?*KeyReader, dt: f32) void {
        // The physics step is f64 like the reference's system_tick(); the
        // f32 dt only feeds the camera.
        const tick: f64 = 1.0 / @round(1.0 / @as(f64, dt));
        var any_key = false;
        if (keys) |k| {
            const toggles = k.autopilot_toggles.swap(0, .acq_rel);
            if (toggles % 2 == 1) self.autopilot = !self.autopilot;
            const snapshot = k.snapshot();
            for (snapshot, 0..) |down, i| {
                self.input.set(@enumFromInt(i), down);
                if (down) any_key = true;
            }
        }
        if (self.replay) |data| {
            // One decimal bitmask per line; past the end, no input.
            var mask: u32 = 0;
            if (self.replay_pos < data.len) {
                const end = std.mem.indexOfScalarPos(u8, data, self.replay_pos, '\n') orelse data.len;
                mask = std.fmt.parseUnsigned(u32, std.mem.trim(u8, data[self.replay_pos..end], " \r"), 10) catch 0;
                self.replay_pos = end + 1;
            }
            var i: usize = 0;
            while (i < wipeout.input.count) : (i += 1) self.input.set(@enumFromInt(i), (mask >> @intCast(i)) & 1 == 1);
        } else if (self.autopilot and !any_key) {
            self.steerAutomatically(track);
        }

        if (self.record_writer) |*w| {
            var mask: u32 = 0;
            var i: usize = 0;
            while (i < wipeout.input.count) : (i += 1) {
                if (self.input.held[i] != 0) mask |= @as(u32, 1) << @intCast(i);
            }
            w.interface.print("{d}\n", .{mask}) catch {};
        }

        if (self.fall_at) |at| {
            if (self.frame == at) {
                const player = self.field.playerShip();
                player.position = player.position.add(wipeout.math.Vec3.init(0, -6000, 12000));
                player.velocity = wipeout.math.Vec3.zero;
            }
        }
        self.field.update(track, &self.input, &self.rng, tick, &self.assets);
        self.input.endFrame();

        if (self.log_writer) |*w| {
            const sh = self.field.playerShipConst();
            w.interface.print("{d},{d},{d},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.6},{d:.6},{d:.6},{d:.4},{d:.4},{d},{d}\n", .{
                self.frame,
                sh.section,
                track.sections[sh.section].num,
                sh.position.x,
                sh.position.y,
                sh.position.z,
                sh.velocity.x,
                sh.velocity.y,
                sh.velocity.z,
                sh.angle.x,
                sh.angle.y,
                sh.angle.z,
                sh.speed,
                sh.thrust_mag,
                @intFromBool(sh.flags.flying),
                @intFromEnum(sh.mode),
            }) catch {};
        }
        self.frame += 1;
    }

    fn steerAutomatically(self: *Race, track: *const wipeout.track.Track) void {
        wipeout.autopilot.steer(self.field.playerShipConst(), track, &self.input);
    }
};

/// Reads the terminal in a thread and keeps a held-down table per action.
/// Uses the Kitty keyboard protocol so key releases are reported; without
/// it a game needs auto-repeat hacks to know when a key is let go.
const KeyReader = struct {
    const legacy_hold_ns: i128 = 180 * std.time.ns_per_ms;

    gpa: std.mem.Allocator,
    io: Io,
    tty: vaxis.Tty,
    /// Legacy (non-Kitty) input has no key releases; a plain-byte press
    /// stays held until `legacy_hold_ns` pass without a repeat.
    legacy_until: [wipeout.input.count]std.atomic.Value(i128) = undefined,
    tty_buffer: [4096]u8 = undefined,
    thread: ?std.Thread = null,
    held: [wipeout.input.count]std.atomic.Value(bool) = undefined,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// Tab presses not yet consumed by the race loop.
    autopilot_toggles: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn start(gpa: std.mem.Allocator, io: Io) !*KeyReader {
        const self = try gpa.create(KeyReader);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .tty = undefined };
        for (&self.held) |*h| h.* = std.atomic.Value(bool).init(false);
        for (&self.legacy_until) |*l| l.* = std.atomic.Value(i128).init(0);
        self.tty = try vaxis.Tty.init(io, &self.tty_buffer);
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    fn stop(self: *KeyReader) void {
        self.running.store(false, .release);
        // The reader thread is blocked in read(); restoring the terminal
        // and exiting the process ends it. Detach rather than join.
        if (self.thread) |t| t.detach();
        self.tty.deinit();
    }

    fn snapshot(self: *KeyReader) [wipeout.input.count]bool {
        var out: [wipeout.input.count]bool = undefined;
        const t = now(self.io);
        for (&out, 0..) |*o, i| {
            const until = self.legacy_until[i].load(.acquire);
            if (until != 0 and t > until) {
                self.held[i].store(false, .release);
                self.legacy_until[i].store(0, .release);
            }
            o.* = self.held[i].load(.acquire);
        }
        return out;
    }

    /// Plain-byte press with no release to come: hold briefly.
    fn legacyPress(self: *KeyReader, action: wipeout.input.Action) void {
        self.held[@intFromEnum(action)].store(true, .release);
        self.legacy_until[@intFromEnum(action)].store(now(self.io) + legacy_hold_ns, .release);
    }

    fn wantsQuit(self: *const KeyReader) bool {
        return self.quit.load(.acquire);
    }

    fn setAction(self: *KeyReader, action: wipeout.input.Action, down: bool) void {
        self.held[@intFromEnum(action)].store(down, .release);
    }

    fn readLoop(self: *KeyReader) void {
        var buf: [256]u8 = undefined;
        var pending: [512]u8 = undefined;
        var pending_len: usize = 0;
        while (self.running.load(.acquire)) {
            const n = std.posix.read(self.tty.fd.handle, &buf) catch return;
            if (n == 0) return;
            for (buf[0..n]) |byte| {
                if (pending_len < pending.len) {
                    pending[pending_len] = byte;
                    pending_len += 1;
                }
            }
            pending_len = self.consume(pending[0..pending_len]);
        }
    }

    /// Parse complete sequences from `bytes`; returns how many bytes of
    /// incomplete trailing input to keep.
    fn consume(self: *KeyReader, bytes: []u8) usize {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b) {
                if (i + 1 >= bytes.len) break; // need more
                if (bytes[i + 1] != '[') {
                    // Bare escape: quit.
                    self.quit.store(true, .release);
                    i += 1;
                    continue;
                }
                // CSI: find the final byte in 0x40..0x7e.
                var j = i + 2;
                while (j < bytes.len and (bytes[j] < 0x40 or bytes[j] > 0x7e)) j += 1;
                if (j >= bytes.len) break; // incomplete
                self.handleCsi(bytes[i + 2 .. j], bytes[j]);
                i = j + 1;
            } else {
                // Legacy plain byte (protocol not supported or not active):
                // a press with no release to follow, held for a short time.
                switch (b) {
                    'q', 'Q', 3 => self.quit.store(true, .release),
                    'x', 'X', ' ', 'w', 'W' => self.legacyPress(.thrust),
                    'z', 'Z' => self.legacyPress(.brake_left),
                    'c', 'C' => self.legacyPress(.brake_right),
                    'a', 'A' => self.legacyPress(.left),
                    'd', 'D' => self.legacyPress(.right),
                    'v', 'V' => self.legacyPress(.change_view),
                    else => {},
                }
                i += 1;
            }
        }
        // Shift the remainder to the front.
        const rest = bytes.len - i;
        if (rest > 0 and i > 0) std.mem.copyForwards(u8, bytes[0..rest], bytes[i..]);
        return rest;
    }

    fn handleCsi(self: *KeyReader, params: []const u8, final: u8) void {
        // params: "key[:shifted[:base]];[mods[:event]]" for 'u', or
        // "1;mods:event" for arrows and other legacy-final keys.
        var key: u32 = 0;
        var event: u32 = 1;
        var section: usize = 0;
        var sub: usize = 0;
        var value: u32 = 0;
        var have_value = false;
        var it: usize = 0;
        while (it <= params.len) : (it += 1) {
            const c: u8 = if (it < params.len) params[it] else ';';
            if (c >= '0' and c <= '9') {
                value = value * 10 + (c - '0');
                have_value = true;
            } else if (c == ':' or c == ';') {
                if (have_value) {
                    if (section == 0 and sub == 0) key = value;
                    if (section == 1 and sub == 1) event = value;
                }
                if (c == ':') {
                    sub += 1;
                } else {
                    section += 1;
                    sub = 0;
                }
                value = 0;
                have_value = false;
            }
        }
        const down = event != 3; // 1 press, 2 repeat, 3 release
        // "CSI D" with no parameters is a legacy arrow press that will never
        // report a release; hold it briefly like a plain byte.
        const legacy = params.len == 0 and final != 'u';
        const action: ?wipeout.input.Action = switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'u' => switch (key) {
                'x', 'X', ' ', 'w', 'W' => .thrust,
                'z', 'Z' => .brake_left,
                'c', 'C' => .brake_right,
                'a', 'A' => .left,
                'd', 'D' => .right,
                'v', 'V' => .change_view,
                'q', 'Q', 27 => blk: {
                    if (down) self.quit.store(true, .release);
                    break :blk null;
                },
                9 => blk: {
                    if (down) _ = self.autopilot_toggles.fetchAdd(1, .acq_rel);
                    break :blk null;
                },
                else => null,
            },
            else => null,
        };
        if (action) |a| {
            if (legacy) self.legacyPress(a) else self.setAction(a, down);
        }
    }
};

/// Pixels never written by opaque geometry (depth still at the clear value)
/// whose four neighbours all were: the signature of a crack between
/// adjacent triangles. Sky is drawn without depth writes, so genuine sky
/// shows as large connected regions and does not trip this.
fn countCracks(renderer: *const wipeout.render.Renderer) u32 {
    return collectCracks(renderer, null);
}

/// Pixels never written by opaque geometry (depth still at the clear value)
/// whose four neighbours all were: the signature of a crack between
/// adjacent triangles. Sky is drawn without depth writes, so genuine sky
/// shows as large connected regions and does not trip this. Coordinates go
/// into `out` (x, y pairs) when provided.
fn collectCracks(renderer: *const wipeout.render.Renderer, out: ?*std.ArrayList([3]u32)) u32 {
    const w = renderer.width;
    const h = renderer.height;
    var count: u32 = 0;
    var y: u32 = 1;
    while (y + 1 < h) : (y += 1) {
        var x: u32 = 1;
        while (x + 1 < w) : (x += 1) {
            const i = y * w + x;
            if (renderer.depth[i] < 1.0) continue;
            if (renderer.depth[i - 1] < 1.0 and renderer.depth[i + 1] < 1.0 and
                renderer.depth[i - w] < 1.0 and renderer.depth[i + w] < 1.0)
            {
                count += 1;
                // Third component: 0 = no triangle covered this pixel (a real
                // crack), 1 = covered but discarded as a transparent texel.
                const kind: u32 = if (renderer.covered[i] == 0) 0 else 1;
                if (out) |list| list.appendBounded(.{ x, y, kind }) catch {};
            }
        }
    }
    return count;
}

const ScanHit = struct { frame: u32, count: u32, section: u32 };

fn scanCracks(
    io: Io,
    renderer: *wipeout.render.Renderer,
    track: *const wipeout.track.Track,
    scene: *wipeout.scene.Scene,
    camera: *FlyCamera,
    options: Options,
    units_per_frame: f32,
    rgb: []u8,
    dir_out: []const u8,
) !void {
    Io.Dir.cwd().createDirPath(io, dir_out) catch {};
    const total_frames = @as(u32, options.fps) * (options.seconds orelse 10);
    var coords_buf: [512][3]u32 = undefined;
    var coords = std.ArrayList([3]u32).initBuffer(&coords_buf);
    var worst = [_]ScanHit{.{ .frame = 0, .count = 0, .section = 0 }} ** 4;
    // Owner pairs (left/right, then top/bottom) around uncovered pixels:
    // same-mesh pairs point at a rasterizer or data-tessellation problem,
    // cross-mesh pairs at meshes that merely abut in the data.
    var same_mesh: u64 = 0;
    var track_vs_scene: u64 = 0;
    var scene_vs_scene: u64 = 0;
    var other_pair: u64 = 0;
    var total_cracks: u64 = 0;
    var true_cracks: u64 = 0;
    var discards: u64 = 0;
    var frames_with_cracks: u32 = 0;

    var frame: u32 = 0;
    while (frame < total_frames) : (frame += 1) {
        camera.advance(track, units_per_frame, options.height_above, options.look_ahead);
        renderFrame(renderer, track, scene, camera, null);
        coords.clearRetainingCapacity();
        const count = collectCracks(renderer, &coords);
        total_cracks += count;
        for (coords.items) |c| {
            if (c[2] == 0) true_cracks += 1 else discards += 1;
            if (c[2] != 0) continue;
            const w = renderer.width;
            const i = c[1] * w + c[0];
            const pairs = [2][2]u16{
                .{ renderer.owner[i - 1], renderer.owner[i + 1] },
                .{ renderer.owner[i - w], renderer.owner[i + w] },
            };
            for (pairs) |pair| {
                const a = pair[0];
                const b = pair[1];
                if (a == b) {
                    same_mesh += 1;
                } else if ((a == wipeout.track.Track.draw_id) != (b == wipeout.track.Track.draw_id)) {
                    track_vs_scene += 1;
                } else if (a < 0xfff0 and b < 0xfff0) {
                    scene_vs_scene += 1;
                } else {
                    other_pair += 1;
                }
            }
        }
        if (count > 0) frames_with_cracks += 1;

        // Keep the four worst frames; write each as soon as it qualifies.
        var slot: ?usize = null;
        var min_count: u32 = std.math.maxInt(u32);
        for (worst, 0..) |hit, i| {
            if (hit.count < min_count) {
                min_count = hit.count;
                slot = i;
            }
        }
        if (count > min_count and slot != null) {
            worst[slot.?] = .{ .frame = frame, .count = count, .section = camera.section };
            var name_buf: [64]u8 = undefined;
            const ppm = try std.fmt.bufPrint(&name_buf, "slot{d}.ppm", .{slot.?});
            const ppm_path = try std.fs.path.join(renderer.gpa, &.{ dir_out, ppm });
            defer renderer.gpa.free(ppm_path);
            renderer.writeRgb(rgb);
            try writePpm(io, ppm_path, options.width, options.height, rgb);

            var txt_buf: [64]u8 = undefined;
            const txt = try std.fmt.bufPrint(&txt_buf, "slot{d}.txt", .{slot.?});
            const txt_path = try std.fs.path.join(renderer.gpa, &.{ dir_out, txt });
            defer renderer.gpa.free(txt_path);
            const file = try Io.Dir.cwd().createFile(io, txt_path, .{ .truncate = true });
            defer file.close(io);
            var buffer: [8192]u8 = undefined;
            var writer: Io.File.Writer = .init(file, io, &buffer);
            try writer.interface.print("frame {d} section {d} count {d}\n", .{ frame, camera.section, count });
            for (coords.items) |c| {
                const w = renderer.width;
                const i = c[1] * w + c[0];
                try writer.interface.print("{d},{d},{d} owners l{d} r{d} t{d} b{d}\n", .{
                    c[0],                  c[1],                  c[2],
                    renderer.owner[i - 1], renderer.owner[i + 1], renderer.owner[i - w],
                    renderer.owner[i + w],
                });
            }
            try writer.interface.flush();
        }
    }

    stderrPrint(io, "scanned {d} frames: {d} with uncovered pixels, {d} total ({d} uncovered by any triangle, {d} transparent-texel discards)\n", .{ total_frames, frames_with_cracks, total_cracks, true_cracks, discards });
    stderrPrint(io, "  neighbour owners around uncovered pixels: same mesh {d}, track/scenery {d}, scenery/scenery {d}, other {d}\n", .{ same_mesh, track_vs_scene, scene_vs_scene, other_pair });
    for (worst, 0..) |hit, i| {
        if (hit.count > 0) stderrPrint(io, "  slot{d}: frame {d} section {d} count {d}\n", .{ i, hit.frame, hit.section, hit.count });
    }
}

fn writePpm(io: Io, path: []const u8, width: u32, height: u32, rgb: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buffer);
    try writer.interface.writeAll(header);
    try writer.interface.writeAll(rgb);
    try writer.interface.flush();
}

fn deflate(dst: []u8, window: []u8, src: []const u8) ?[]u8 {
    var out: Io.Writer = .fixed(dst);
    var compressor = std.compress.flate.Compress.init(&out, window, .zlib, .fastest) catch return null;
    compressor.writer.writeAll(src) catch return null;
    compressor.finish() catch return null;
    return out.buffered();
}

fn transmitFrame(out: *Io.Writer, encoded: []const u8, options: Options, display: Display, compressed: bool, id: u32) !void {
    try out.print("\x1b[{d};{d}H", .{ display.row + 1, display.col + 1 });
    const first_end: usize = @min(chunk_size, encoded.len);
    const more: u1 = if (first_end < encoded.len) 1 else 0;
    try out.print(
        "\x1b_Ga=T,f=24,s={d},v={d},i={d},q=2{s},m={d},c={d},r={d},C=1;{s}\x1b\\",
        .{
            @as(u32, options.width) * options.scale,
            @as(u32, options.height) * options.scale,
            id,
            if (compressed) ",o=z" else "",
            more,
            display.cols,
            display.rows,
            encoded[0..first_end],
        },
    );
    var offset = first_end;
    while (offset < encoded.len) {
        const end = @min(offset + chunk_size, encoded.len);
        const chunk_more: u1 = if (end < encoded.len) 1 else 0;
        try out.print("\x1b_Gm={d};{s}\x1b\\", .{ chunk_more, encoded[offset..end] });
        offset = end;
    }
}

fn deleteImage(out: *Io.Writer, id: u32) !void {
    try out.print("\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{id});
}

fn protocolOverhead(encoded_len: usize) usize {
    const chunks = (encoded_len + chunk_size - 1) / chunk_size;
    return 112 + chunks * 12;
}

fn report(io: Io, options: Options, display: Display, totals: Totals, elapsed_ns: i128) void {
    const frames = @as(f64, @floatFromInt(totals.frames));
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const raw_mib = @as(f64, @floatFromInt(totals.raw_bytes)) / (1024.0 * 1024.0);
    const payload_mib = @as(f64, @floatFromInt(totals.payload_bytes)) / (1024.0 * 1024.0);
    const wire_mib = @as(f64, @floatFromInt(totals.wire_bytes)) / (1024.0 * 1024.0);
    stderrPrint(io,
        \\wipEout probe · track{d:0>2} · {d}x{d} -> {d}x{d} cells · {d} fps for {d}s{s}
        \\  achieved: {d:.2} fps · late {d}/{d} frames · {d} schedule slots dropped · {d:.0} tris/frame · worst frame {d:.1} ms · {d} frames over 20 ms
        \\  worst frame: #{d} at section {d}: render {d:.1} ms, {d} tris, {d} px visited, {d} px shaded
        \\  average: render {d:.3} ms · deflate {d:.3} ms · base64 {d:.3} ms · write {d:.3} ms
        \\  payload: raw {d:.2} MiB · after deflate {d:.2} MiB ({d:.1}%)
        \\  transport: {d:.2} MiB total · {d:.2} MiB/s · {d:.2} Mbit/s
        \\
    , .{
        options.track,
        options.width,
        options.height,
        display.cols,
        display.rows,
        options.fps,
        options.seconds orelse 10,
        if (options.dry_run) " (dry run)" else "",
        frames / elapsed_s,
        totals.late_frames,
        totals.frames,
        totals.dropped_frames,
        @as(f64, @floatFromInt(totals.tris)) / @max(frames, 1),
        @as(f64, @floatFromInt(totals.max_frame_ns)) / std.time.ns_per_ms,
        totals.slow_frames,
        totals.worst_frame_index,
        totals.worst_section,
        @as(f64, @floatFromInt(totals.worst_render_ns)) / std.time.ns_per_ms,
        totals.worst_tris,
        totals.worst_visited,
        totals.worst_pixels,
        nsPerFrame(totals.render_ns, totals.frames),
        nsPerFrame(totals.compress_ns, totals.frames),
        nsPerFrame(totals.encode_ns, totals.frames),
        nsPerFrame(totals.write_ns, totals.frames),
        raw_mib,
        payload_mib,
        payload_mib / @max(raw_mib, 0.0001) * 100.0,
        wire_mib,
        wire_mib / elapsed_s,
        wire_mib * 8.0 / elapsed_s,
    });
}

fn nsPerFrame(ns: i128, frames: u64) f64 {
    if (frames == 0) return 0;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(frames)) / std.time.ns_per_ms;
}

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            options.raw = true;
        } else if (std.mem.eql(u8, arg, "--track")) {
            options.track = try nextUnsigned(u8, args, &index);
        } else if (std.mem.eql(u8, arg, "--fps")) {
            options.fps = try nextUnsigned(u16, args, &index);
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            options.seconds = try nextUnsigned(u16, args, &index);
            if (options.seconds.? == 0) return error.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--width")) {
            options.width = try nextUnsigned(u32, args, &index);
        } else if (std.mem.eql(u8, arg, "--height")) {
            options.height = try nextUnsigned(u32, args, &index);
        } else if (std.mem.eql(u8, arg, "--cols")) {
            options.cols = try nextUnsigned(u16, args, &index);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            options.rows = try nextUnsigned(u16, args, &index);
        } else if (std.mem.eql(u8, arg, "--frame")) {
            options.frame = try nextUnsigned(u32, args, &index);
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            options.snapshot = try nextString(args, &index);
        } else if (std.mem.eql(u8, arg, "--probe-pixel")) {
            const text = try nextString(args, &index);
            const comma = std.mem.indexOfScalar(u8, text, ',') orelse return error.InvalidValue;
            options.probe_pixel = .{
                try std.fmt.parseUnsigned(u32, text[0..comma], 10),
                try std.fmt.parseUnsigned(u32, text[comma + 1 ..], 10),
            };
        } else if (std.mem.eql(u8, arg, "--dilation")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.dilation = try std.fmt.parseInt(i64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--drive")) {
            options.drive = true;
        } else if (std.mem.eql(u8, arg, "--autopilot")) {
            options.autopilot = true;
        } else if (std.mem.eql(u8, arg, "--intro")) {
            options.intro = true;
        } else if (std.mem.eql(u8, arg, "--crt")) {
            options.crt = true;
        } else if (std.mem.eql(u8, arg, "--time-trial")) {
            options.time_trial = true;
        } else if (std.mem.eql(u8, arg, "--game")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.game_script = args[index];
        } else if (std.mem.eql(u8, arg, "--shots")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.shots = args[index];
        } else if (std.mem.eql(u8, arg, "--fall-at")) {
            options.fall_at = try nextUnsigned(u64, args, &index);
        } else if (std.mem.eql(u8, arg, "--ai")) {
            const level = try nextString(args, &index);
            options.difficulty = std.meta.stringToEnum(wipeout.race.Difficulty, level) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--bands")) {
            options.bands = try nextUnsigned(u8, args, &index);
            if (options.scale == 1) options.scale = 2;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            options.scale = try nextUnsigned(u8, args, &index);
            if (options.scale == 0 or options.scale > 4) return error.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--rapier")) {
            options.rapier = true;
        } else if (std.mem.eql(u8, arg, "--record-input")) {
            options.record_input = try nextString(args, &index);
        } else if (std.mem.eql(u8, arg, "--replay-input")) {
            options.replay_input = try nextString(args, &index);
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--ship-log")) {
            options.ship_log = try nextString(args, &index);
        } else if (std.mem.eql(u8, arg, "--owner-map")) {
            options.owner_map = try nextString(args, &index);
        } else if (std.mem.eql(u8, arg, "--dump-model")) {
            options.dump_model = true;
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--pilot")) {
            options.pilot = try nextUnsigned(u8, args, &index);
        } else if (std.mem.eql(u8, arg, "--log-frames")) {
            options.log_frames = try nextString(args, &index);
        } else if (std.mem.eql(u8, arg, "--scan-cracks")) {
            options.scan_cracks = try nextString(args, &index);
        } else if (std.mem.eql(u8, arg, "--assets")) {
            options.assets = try nextString(args, &index);
        } else if (std.mem.eql(u8, arg, "--speed")) {
            options.speed = try nextFloat(args, &index);
        } else if (std.mem.eql(u8, arg, "--height-above")) {
            options.height_above = try nextFloat(args, &index);
        } else if (std.mem.eql(u8, arg, "--look-ahead")) {
            options.look_ahead = try nextFloat(args, &index);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else {
            return error.UnknownArgument;
        }
    }
    if (options.pilot >= wipeout.defs.num_pilots) return error.InvalidValue;
    if (options.track < 1 or options.track > 14 or options.fps == 0 or options.fps > 60 or
        options.width < 16 or options.height < 16 or options.width > 1920 or options.height > 1200 or
        (options.cols != null and options.cols.? == 0) or
        (options.rows != null and options.rows.? == 0)) return error.InvalidValue;
    return options;
}

fn nextUnsigned(comptime T: type, args: []const []const u8, index: *usize) !T {
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return std.fmt.parseUnsigned(T, args[index.*], 10);
}

fn nextFloat(args: []const []const u8, index: *usize) !f32 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return std.fmt.parseFloat(f32, args[index.*]);
}

fn nextString(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return args[index.*];
}

fn usage(io: Io) void {
    stderrPrint(io,
        \\usage: zig build wipeout-probe -- [options]
        \\  --track N          PSX track directory 1-14 (default 1)
        \\  --fps N            target rate, max 60 (default 30)
        \\  --seconds N        duration (default 10)
        \\  --width/--height   framebuffer size (default 320x240)
        \\  --cols/--rows      override automatic fullscreen placement
        \\  --speed F          camera speed in world units per second (default 6000)
        \\  --height-above F   camera height above the track (default 700)
        \\  --look-ahead F     look-at distance along the track (default 9000)
        \\  --assets DIR       data root containing wipeout/ (default XDG data dir)
        \\  --dry-run          render, compress, and encode without Kitty output
        \\  --snapshot FILE    write one frame as PPM and exit (see --frame)
        \\  --frame N          which frame --snapshot captures (default 0)
        \\  --scan-cracks DIR  headless lap scan; dump the frames with most uncovered pixels
        \\  --dilation N       triangle edge dilation in 1/16 px (default 2; 0 = exact)
        \\  --log-frames FILE  write per-frame timings and payload sizes as CSV
        \\  --drive            fly a ship with the keyboard (arrows steer/pitch, x or space
        \\                     thrust, z/c airbrakes, v view, Tab autopilot, q quits)
        \\  --autopilot        let the probe steer the ship along the track
        \\  --pilot N          pilot 0-7 (default 0, John Dekka / AG Systems)
        \\  --rapier           Rapier class handling instead of Venom
        \\  --intro            start with the countdown hover instead of racing at once
        \\  --game SCRIPT      headless: run the whole game (title, menus, races) from
        \\                     "frame:action,..." where action is an input name
        \\                     (menu_start, menu_down, thrust, ...), +name/-name to hold
        \\                     and release, or "shot" to write a frame as PPM
        \\  --shots PREFIX     PPM prefix for --game shots (default /tmp/wipeout-game)
        \\  --crt              apply the CRT post pass (implies --scale 2)
        \\  --time-trial       no opponents (parity replays use this)
        \\  --ai LEVEL         opponent strength: easy, normal, hard
        \\  --scale N          output N× the render size (nearest, or through the CRT pass)
        \\  --record-input F   write the per-frame action bitmask (for the parity harness)
        \\  --replay-input F   drive from a recorded bitmask file (implies --dry-run)
        \\  --ship-log F       write ship state per frame as CSV
        \\  --probe-pixel X,Y  with --snapshot: print rasterizer decisions for one pixel
        \\  --raw              disable zlib compression
        \\
    , .{});
}

fn now(io: Io) i128 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    writer.interface.print(fmt, args) catch return;
    writer.interface.flush() catch {};
}

/// Scripted end-to-end run of the game through `wipeout.session`.
fn runGame(gpa: std.mem.Allocator, io: Io, options: Options, root: []const u8, script: []const u8) !void {
    const Step = struct { frame: u64, kind: enum { press, hold, release, shot, hall }, action: wipeout.input.Action };
    var steps: std.ArrayList(Step) = .empty;
    defer steps.deinit(gpa);
    var it = std.mem.splitScalar(u8, script, ',');
    var last_frame: u64 = 0;
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " ");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidValue;
        const frame = try std.fmt.parseUnsigned(u64, trimmed[0..colon], 10);
        var name = trimmed[colon + 1 ..];
        var step = Step{ .frame = frame, .kind = .press, .action = .thrust };
        if (std.mem.eql(u8, name, "shot")) {
            step.kind = .shot;
        } else if (std.mem.eql(u8, name, "hall")) {
            step.kind = .hall;
        } else {
            if (name.len > 0 and name[0] == '+') {
                step.kind = .hold;
                name = name[1..];
            } else if (name.len > 0 and name[0] == '-') {
                step.kind = .release;
                name = name[1..];
            }
            step.action = std.meta.stringToEnum(wipeout.input.Action, name) orelse return error.InvalidValue;
        }
        try steps.append(gpa, step);
        last_frame = @max(last_frame, frame);
    }

    const session = try wipeout.session.Session.createWithRoot(gpa, io, try gpa.dupe(u8, root), null, wipeout.save.defaults, .{
        .crt = options.crt,
        .intro = options.intro,
    });
    defer session.destroy();
    session.autopilot = options.autopilot;
    const size = session.outputSize();
    const rgb = try gpa.alloc(u8, @as(usize, size.width) * size.height * 3);
    defer gpa.free(rgb);

    var release_next: ?wipeout.input.Action = null;
    var frame: u64 = 0;
    while (frame <= last_frame) : (frame += 1) {
        if (release_next) |action| {
            session.input.set(action, false);
            release_next = null;
        }
        for (steps.items) |step| {
            if (step.frame != frame) continue;
            switch (step.kind) {
                .press => {
                    session.input.set(step.action, true);
                    release_next = step.action;
                },
                .hold => session.input.set(step.action, true),
                .release => session.input.set(step.action, false),
                .hall => session.state.debugHallOfFame(65.0),
                .shot => {
                    const shot_size = session.outputSize();
                    const shot = try gpa.alloc(u8, @as(usize, shot_size.width) * shot_size.height * 3);
                    defer gpa.free(shot);
                    session.render(shot, shot_size.width, shot_size.height);
                    var path_buf: [256]u8 = undefined;
                    const path = try std.fmt.bufPrint(&path_buf, "{s}_{d}.ppm", .{ options.shots, frame });
                    try writePpm(io, path, shot_size.width, shot_size.height, shot);
                    stderrPrint(io, "frame {d}: scene {t} menu depth {d} -> {s}\n", .{ frame, session.state.scene, session.state.menu.depth(), path });
                },
            }
        }
        session.step();
    }
    if (session.load_error) |err| stderrPrint(io, "circuit load failed: {s}\n", .{@errorName(err)});
    stderrPrint(io, "done: scene {t} race_active {d} circuit {d} class {d} pilot {d} lives {d}\n", .{
        session.state.scene, session.state.race_active, session.state.circuit, session.state.race_class, session.state.pilot, session.state.lives,
    });
}
