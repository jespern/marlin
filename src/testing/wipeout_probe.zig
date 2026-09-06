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
    seconds: u16 = 10,
    width: u32 = 320,
    height: u32 = 240,
    cols: ?u16 = null,
    rows: ?u16 = null,
    dry_run: bool = false,
    raw: bool = false,
    snapshot: ?[]const u8 = null,
    frame: u32 = 0,
    assets: ?[]const u8 = null,
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

    const live = !options.dry_run and options.snapshot == null;
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
    const assets = wipeout.assets.Assets.init(io, gpa, root);
    var dir_buf: [32]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "wipeout/track{d:0>2}", .{options.track});

    var renderer = try wipeout.render.Renderer.init(gpa, options.width, options.height);
    defer renderer.deinit();

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

    const raw_len = @as(usize, options.width) * options.height * 3;
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

    if (options.snapshot) |path| {
        var i: u32 = 0;
        while (i <= options.frame) : (i += 1) camera.advance(&track, units_per_frame, options.height_above, options.look_ahead);
        renderFrame(&renderer, &track, &scene, &camera);
        renderer.writeRgb(rgb);
        try writePpm(io, path, options.width, options.height, rgb);
        stderrPrint(io, "wrote {s} (frame {d}, {d} tris, {d} pixels shaded, camera section {d})\n", .{
            path,
            options.frame,
            renderer.stats.tris,
            renderer.stats.pixels,
            camera.section,
        });
        return;
    }

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    if (!options.dry_run) {
        try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        try out.flush();
    }
    defer if (!options.dry_run) {
        for (image_ids) |id| deleteImage(out, id) catch {};
        out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    };

    const frame_ns: i128 = @divFloor(std.time.ns_per_s, @as(i128, options.fps));
    const target_frames = @as(u64, options.fps) * options.seconds;
    var totals: Totals = .{};

    // Render-ahead pipeline: the frame for deadline N is rendered and encoded
    // right after frame N-1 is presented, so the only work left at the
    // deadline is the terminal write. A scheduling stall shorter than the
    // slack (~25 ms at 30 fps for this scene) then never reaches the screen.
    var pending = prepareFrame(io, &renderer, &track, &scene, &camera, options, units_per_frame, rgb, zbuf, window, encoded);
    const began = now(io);

    while (totals.frames < target_frames) : (totals.frames += 1) {
        const deadline = began + @as(i128, @intCast(totals.frames + 1)) * frame_ns;
        const slack = deadline - now(io);
        if (slack > spin_margin_ns) {
            io.sleep(.fromNanoseconds(@intCast(slack - spin_margin_ns)), .awake) catch {};
        } else if (slack < 0) {
            totals.late_frames += 1;
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

        pending = prepareFrame(io, &renderer, &track, &scene, &camera, options, units_per_frame, rgb, zbuf, window, encoded);
    }

    report(io, options, display, totals, now(io) - began);
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
    track: *const wipeout.track.Track,
    scene: *wipeout.scene.Scene,
    camera: *FlyCamera,
    options: Options,
    units_per_frame: f32,
    rgb: []u8,
    zbuf: []u8,
    window: []u8,
    encoded: []u8,
) PreparedFrame {
    camera.advance(track, units_per_frame, options.height_above, options.look_ahead);

    const render_start = now(io);
    renderFrame(renderer, track, scene, camera);
    renderer.writeRgb(rgb);
    const render_end = now(io);

    var payload: []const u8 = rgb;
    var compressed = false;
    if (!options.raw) {
        if (deflate(zbuf, window, rgb)) |z| {
            if (z.len < rgb.len) {
                payload = z;
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
        .section = camera.section,
    };
}

fn renderFrame(renderer: *wipeout.render.Renderer, track: *const wipeout.track.Track, scene: *wipeout.scene.Scene, camera: *const FlyCamera) void {
    renderer.framePrepare();
    renderer.setView(camera.position, camera.angle);
    const forward = wipeout.cameraForward(camera.angle);
    scene.draw(renderer, camera.position, forward);
    track.draw(renderer, camera.position, forward);
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
            options.width,
            options.height,
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
        \\  achieved: {d:.2} fps · late {d}/{d} frames · {d:.0} tris/frame · worst frame {d:.1} ms · {d} frames over 20 ms
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
        options.seconds,
        if (options.dry_run) " (dry run)" else "",
        frames / elapsed_s,
        totals.late_frames,
        totals.frames,
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
    if (options.track < 1 or options.track > 14 or options.fps == 0 or options.fps > 60 or options.seconds == 0 or
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
