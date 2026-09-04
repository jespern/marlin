//! Kitty graphics transport probe for animated RGB framebuffers.
//!
//! Run a single rate:
//!   zig run -O ReleaseFast scripts/kitty-pixel-probe.zig -- --fps 30 --seconds 5
//!
//! Run the standard comparison:
//!   zig run -O ReleaseFast scripts/kitty-pixel-probe.zig -- --sweep
//!
//! Run the 24-second demoscene sequence:
//!   zig run -O ReleaseFast scripts/kitty-pixel-probe.zig -- --demo --cols "$(tput cols)" --rows "$(tput lines)"
//!
//! Validate generation and encoding without emitting terminal escapes:
//!   zig run -O ReleaseFast scripts/kitty-pixel-probe.zig -- --dry-run --sweep

const std = @import("std");
const Io = std.Io;

const image_id: u32 = 0x4d_50_00_01;
const chunk_size: usize = 4096;

const Options = struct {
    width: u16 = 320,
    height: u16 = 180,
    cols: u16 = 80,
    rows: u16 = 24,
    fps: u16 = 30,
    seconds: u16 = 5,
    sweep: bool = false,
    demo: bool = false,
    scene: ?Scene = null,
    dry_run: bool = false,
};

const Totals = struct {
    frames: u64 = 0,
    late_frames: u64 = 0,
    raw_bytes: u64 = 0,
    wire_bytes: u64 = 0,
    generation_ns: i128 = 0,
    encoding_ns: i128 = 0,
    write_ns: i128 = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = parseArgs(args[1..]) catch |err| {
        stderrPrint(init.io, "pixel-probe: {s}\n\n", .{@errorName(err)});
        usage(init.io);
        return 2;
    };

    if (!options.dry_run and !(Io.File.stdout().isTty(init.io) catch false)) {
        stderrPrint(init.io, "pixel-probe: stdout is not a terminal; use --dry-run for validation\n", .{});
        return 2;
    }

    if (options.sweep) {
        for ([_]u16{ 15, 30, 60 }, 0..) |fps, index| {
            var run_options = options;
            run_options.fps = fps;
            if (!options.dry_run and index > 0) {
                stderrPrint(init.io, "\nnext rate in 1 second...\n", .{});
                init.io.sleep(.fromSeconds(1), .awake) catch {};
            }
            try run(init.gpa, init.io, run_options);
        }
    } else {
        try run(init.gpa, init.io, options);
    }
    return 0;
}

fn run(gpa: std.mem.Allocator, io: Io, options: Options) !void {
    const pixel_count = @as(usize, options.width) * options.height;
    const raw = try gpa.alloc(u8, pixel_count * 3);
    defer gpa.free(raw);
    const scratch = try gpa.alloc(u8, raw.len);
    defer gpa.free(scratch);
    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    defer gpa.free(encoded);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    if (!options.dry_run) {
        try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        try out.flush();
    }
    defer if (!options.dry_run) {
        deleteImage(out) catch {};
        out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    };

    const frame_ns: i128 = @divFloor(std.time.ns_per_s, @as(i128, options.fps));
    const duration_seconds: u16 = if (options.demo) 24 else options.seconds;
    const target_frames = @as(u64, options.fps) * duration_seconds;
    const began = now(io);
    var totals: Totals = .{};

    while (totals.frames < target_frames) : (totals.frames += 1) {
        const generation_start = now(io);
        if (options.demo)
            renderDemo(raw, scratch, options.width, options.height, totals.frames, options.fps)
        else if (options.scene) |scene|
            renderScene(scene, raw, options.width, options.height, totals.frames, options.fps)
        else
            renderPlasma(raw, options.width, options.height, totals.frames, options.fps);
        const generation_end = now(io);

        _ = std.base64.standard.Encoder.encode(encoded, raw);
        const encoding_end = now(io);

        if (!options.dry_run) {
            try transmitFrame(out, encoded, options);
            try out.flush();
        }
        const write_end = now(io);

        totals.raw_bytes += raw.len;
        totals.wire_bytes += encoded.len + protocolOverhead(encoded.len);
        totals.generation_ns += generation_end - generation_start;
        totals.encoding_ns += encoding_end - generation_end;
        totals.write_ns += write_end - encoding_end;

        const deadline = began + @as(i128, @intCast(totals.frames + 1)) * frame_ns;
        const remaining = deadline - now(io);
        if (remaining > 0) {
            io.sleep(.fromNanoseconds(@intCast(remaining)), .awake) catch {};
        } else {
            totals.late_frames += 1;
        }
    }

    const elapsed = now(io) - began;
    report(io, options, duration_seconds, totals, elapsed);
}

const Scene = enum(u2) {
    plasma,
    tunnel,
    metaballs,
    horizon,
};

fn renderDemo(rgb: []u8, scratch: []u8, width: u16, height: u16, frame: u64, fps: u16) void {
    const scene_frames = @as(u64, fps) * 6;
    const transition_frames = @as(u64, fps);
    const scene_index: u2 = @intCast((frame / scene_frames) % 4);
    const local_frame = frame % scene_frames;
    const scene: Scene = @enumFromInt(scene_index);
    renderScene(scene, rgb, width, height, frame, fps);

    const transition_start = scene_frames - transition_frames;
    if (local_frame < transition_start) return;
    const next_index: u8 = (@as(u8, scene_index) + 1) % 4;
    const next: Scene = @enumFromInt(next_index);
    renderScene(next, scratch, width, height, frame, fps);
    const linear = @as(f32, @floatFromInt(local_frame - transition_start)) / @as(f32, @floatFromInt(transition_frames));
    const mix = linear * linear * (3.0 - 2.0 * linear);
    blendFrames(rgb, scratch, mix);
}

fn renderScene(scene: Scene, rgb: []u8, width: u16, height: u16, frame: u64, fps: u16) void {
    switch (scene) {
        .plasma => renderPlasma(rgb, width, height, frame, fps),
        .tunnel => renderTunnel(rgb, width, height, frame, fps),
        .metaballs => renderMetaballs(rgb, width, height, frame, fps),
        .horizon => renderHorizon(rgb, width, height, frame, fps),
    }
}

fn renderPlasma(rgb: []u8, width: u16, height: u16, frame: u64, fps: u16) void {
    const time = seconds(frame, fps);
    const center_x = @as(f32, @floatFromInt(width)) * 0.5;
    const center_y = @as(f32, @floatFromInt(height)) * 0.5;
    var y: u16 = 0;
    var offset: usize = 0;
    while (y < height) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y));
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f32, @floatFromInt(x));
            const dx = (xf - center_x) / center_x;
            const dy = (yf - center_y) / center_y;
            const radial = @sqrt(dx * dx + dy * dy);
            const value = @sin(xf * 0.035 + time * 2.1) +
                @sin(yf * 0.052 - time * 1.7) +
                @sin((dx + dy) * 7.0 + time) +
                @sin(radial * 12.0 - time * 2.4);
            const phase = (value + 4.0) / 8.0 * std.math.tau;
            rgb[offset] = colorChannel(@sin(phase));
            rgb[offset + 1] = colorChannel(@sin(phase + 2.094));
            rgb[offset + 2] = colorChannel(@sin(phase + 4.188));
            offset += 3;
        }
    }
}

fn renderTunnel(rgb: []u8, width: u16, height: u16, frame: u64, fps: u16) void {
    const time = seconds(frame, fps);
    const center_x = @as(f32, @floatFromInt(width)) * 0.5 + @sin(time * 0.7) * 24.0;
    const center_y = @as(f32, @floatFromInt(height)) * 0.5 + @cos(time * 0.9) * 14.0;
    const scale = @as(f32, @floatFromInt(height));
    var y: u16 = 0;
    var offset: usize = 0;
    while (y < height) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y));
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f32, @floatFromInt(x));
            const dx = (xf - center_x) / scale;
            const dy = (yf - center_y) / scale;
            const distance = @sqrt(dx * dx + dy * dy) + 0.025;
            const angle = std.math.atan2(dy, dx);
            const depth = 0.55 / distance + time * 1.8;
            const spiral = angle * 4.0 + depth * 1.7 + @sin(depth * 0.45);
            const bands = @sin(depth * 7.0) * 0.55 + @sin(spiral * 2.0) * 0.45;
            const glow = @min(1.0, 0.08 / distance);
            const phase = spiral + bands * 1.4;
            rgb[offset] = unitChannel(0.13 + glow * 0.8 + (@sin(phase) * 0.5 + 0.5) * 0.24);
            rgb[offset + 1] = unitChannel(0.02 + glow * 0.22 + (@sin(phase + 2.1) * 0.5 + 0.5) * 0.18);
            rgb[offset + 2] = unitChannel(0.22 + glow * 0.65 + (@sin(phase + 4.2) * 0.5 + 0.5) * 0.42);
            offset += 3;
        }
    }
}

fn renderMetaballs(rgb: []u8, width: u16, height: u16, frame: u64, fps: u16) void {
    const time = seconds(frame, fps);
    const w = @as(f32, @floatFromInt(width));
    const h = @as(f32, @floatFromInt(height));
    const centers = [5][3]f32{
        .{ w * 0.50 + @sin(time * 1.3) * w * 0.23, h * 0.50 + @cos(time * 0.9) * h * 0.27, h * 0.22 },
        .{ w * 0.50 + @cos(time * 0.7 + 1.4) * w * 0.29, h * 0.50 + @sin(time * 1.1) * h * 0.31, h * 0.19 },
        .{ w * 0.50 + @sin(time * 0.8 + 3.1) * w * 0.34, h * 0.50 + @cos(time * 1.4 + 0.8) * h * 0.22, h * 0.17 },
        .{ w * 0.50 + @cos(time * 1.5 + 4.2) * w * 0.20, h * 0.50 + @sin(time * 0.6 + 2.0) * h * 0.36, h * 0.15 },
        .{ w * 0.50 + @sin(time * 1.0 + 5.0) * w * 0.27, h * 0.50 + @sin(time * 1.7 + 4.0) * h * 0.18, h * 0.13 },
    };
    var y: u16 = 0;
    var offset: usize = 0;
    while (y < height) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y));
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f32, @floatFromInt(x));
            var field: f32 = 0;
            for (centers) |ball| {
                const dx = xf - ball[0];
                const dy = yf - ball[1];
                field += ball[2] * ball[2] / (dx * dx + dy * dy + 18.0);
            }
            const edge = smoothstep(0.72, 1.12, field);
            const inner = smoothstep(1.05, 2.8, field);
            const shimmer = @sin(field * 4.5 - time * 2.0) * 0.5 + 0.5;
            rgb[offset] = unitChannel(0.015 + edge * (0.55 + inner * 0.4));
            rgb[offset + 1] = unitChannel(0.025 + edge * (0.08 + shimmer * 0.28));
            rgb[offset + 2] = unitChannel(0.07 + edge * (0.55 + (1.0 - inner) * 0.35));
            offset += 3;
        }
    }
}

fn renderHorizon(rgb: []u8, width: u16, height: u16, frame: u64, fps: u16) void {
    const time = seconds(frame, fps);
    const w = @as(f32, @floatFromInt(width));
    const h = @as(f32, @floatFromInt(height));
    const horizon = h * 0.52;
    const sun_x = w * 0.5 + @sin(time * 0.22) * w * 0.08;
    const sun_y = h * 0.30;
    const sun_radius = h * 0.22;
    var y: u16 = 0;
    var offset: usize = 0;
    while (y < height) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y));
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f32, @floatFromInt(x));
            var red: f32 = 0.015;
            var green: f32 = 0.008;
            var blue: f32 = 0.055 + (1.0 - yf / h) * 0.08;

            const sun_dx = xf - sun_x;
            const sun_dy = yf - sun_y;
            const sun_distance = @sqrt(sun_dx * sun_dx + sun_dy * sun_dy);
            if (sun_distance < sun_radius and yf < horizon) {
                const sun = 1.0 - sun_distance / sun_radius;
                const stripe = @sin((yf - sun_y) * 0.42 + time * 1.4);
                const stripe_mask: f32 = if (stripe > -0.35) 1.0 else 0.18;
                red += (0.75 + sun * 0.25) * stripe_mask;
                green += (0.08 + sun * 0.35) * stripe_mask;
                blue += (0.20 + sun * 0.24) * stripe_mask;
            }

            if (yf >= horizon) {
                const depth = (yf - horizon + 1.0) / (h - horizon);
                const perspective = 1.0 / depth;
                const scroll = time * 1.7;
                const horizontal = @abs(@sin((perspective * 1.15 - scroll) * std.math.pi));
                const spread = (xf - w * 0.5) * depth * 0.11;
                const vertical = @abs(@sin(spread * std.math.pi));
                const grid = @max(smoothstep(0.86, 1.0, horizontal), smoothstep(0.90, 1.0, vertical));
                const fade = depth * depth;
                red += grid * fade * 0.72;
                green += grid * fade * 0.08;
                blue += grid * fade * 0.82;
            } else {
                const ridge = horizon - 8.0 - @sin(xf * 0.035 + time * 0.4) * 7.0 - @sin(xf * 0.081 - time * 0.7) * 3.5;
                if (yf > ridge) {
                    red *= 0.25;
                    green *= 0.2;
                    blue *= 0.32;
                }
            }
            rgb[offset] = unitChannel(red);
            rgb[offset + 1] = unitChannel(green);
            rgb[offset + 2] = unitChannel(blue);
            offset += 3;
        }
    }
}

fn blendFrames(destination: []u8, source: []const u8, mix: f32) void {
    const keep = 1.0 - mix;
    for (destination, source) |*dst, src| {
        dst.* = @intFromFloat(@as(f32, @floatFromInt(dst.*)) * keep + @as(f32, @floatFromInt(src)) * mix);
    }
}

fn seconds(frame: u64, fps: u16) f32 {
    return @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(fps));
}

fn smoothstep(low: f32, high: f32, value: f32) f32 {
    const t = std.math.clamp((value - low) / (high - low), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn colorChannel(value: f32) u8 {
    return unitChannel(value * 0.5 + 0.5);
}

fn unitChannel(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0);
}

fn transmitFrame(out: *Io.Writer, encoded: []const u8, options: Options) !void {
    var offset: usize = 0;
    const first_end = @min(chunk_size, encoded.len);
    const more: u1 = if (first_end < encoded.len) 1 else 0;
    try out.print(
        "\x1b_Ga=T,f=24,s={d},v={d},i={d},q=2,m={d},c={d},r={d},C=1;{s}\x1b\\",
        .{ options.width, options.height, image_id, more, options.cols, options.rows, encoded[0..first_end] },
    );
    offset = first_end;
    while (offset < encoded.len) {
        const end = @min(offset + chunk_size, encoded.len);
        const chunk_more: u1 = if (end < encoded.len) 1 else 0;
        try out.print("\x1b_Gm={d};{s}\x1b\\", .{ chunk_more, encoded[offset..end] });
        offset = end;
    }
}

fn deleteImage(out: *Io.Writer) !void {
    try out.print("\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{image_id});
}

fn protocolOverhead(encoded_len: usize) usize {
    const chunks = (encoded_len + chunk_size - 1) / chunk_size;
    return 96 + chunks * 12;
}

fn report(io: Io, options: Options, duration_seconds: u16, totals: Totals, elapsed_ns: i128) void {
    const frames = @as(f64, @floatFromInt(totals.frames));
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const wire_mib = @as(f64, @floatFromInt(totals.wire_bytes)) / (1024.0 * 1024.0);
    stderrPrint(io,
        \\pixel-probe {d}x{d} -> {d}x{d} cells, target {d} fps for {d}s{s}
        \\  achieved: {d:.2} fps, late: {d}/{d} frames
        \\  average: generation {d:.3} ms, base64 {d:.3} ms, write+flush {d:.3} ms
        \\  transport: {d:.2} MiB total, {d:.2} MiB/s ({d:.2} Mbit/s)
        \\  note: write+flush measures local submission, not terminal presentation latency
        \\
    , .{
        options.width,
        options.height,
        options.cols,
        options.rows,
        options.fps,
        duration_seconds,
        if (options.dry_run) " (dry run)" else "",
        frames / elapsed_s,
        totals.late_frames,
        totals.frames,
        nsPerFrame(totals.generation_ns, totals.frames),
        nsPerFrame(totals.encoding_ns, totals.frames),
        nsPerFrame(totals.write_ns, totals.frames),
        wire_mib,
        wire_mib / elapsed_s,
        wire_mib * 8.0 / elapsed_s,
    });
}

fn nsPerFrame(ns: i128, frames: u64) f64 {
    if (frames == 0) return 0;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(frames)) / std.time.ns_per_ms;
}

fn now(io: Io) i128 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--sweep")) {
            options.sweep = true;
        } else if (std.mem.eql(u8, arg, "--demo")) {
            options.demo = true;
            options.fps = 60;
        } else if (std.mem.eql(u8, arg, "--scene")) {
            options.scene = try parseScene(try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--fps")) {
            options.fps = try nextUnsigned(u16, args, &index);
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            options.seconds = try nextUnsigned(u16, args, &index);
        } else if (std.mem.eql(u8, arg, "--width")) {
            options.width = try nextUnsigned(u16, args, &index);
        } else if (std.mem.eql(u8, arg, "--height")) {
            options.height = try nextUnsigned(u16, args, &index);
        } else if (std.mem.eql(u8, arg, "--cols")) {
            options.cols = try nextUnsigned(u16, args, &index);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            options.rows = try nextUnsigned(u16, args, &index);
        } else {
            return error.UnknownArgument;
        }
    }
    const modes = @as(u8, @intFromBool(options.sweep)) + @as(u8, @intFromBool(options.demo)) + @as(u8, @intFromBool(options.scene != null));
    if (modes > 1) return error.ConflictingModes;
    if (options.fps == 0 or options.seconds == 0 or options.width == 0 or options.height == 0 or options.cols == 0 or options.rows == 0)
        return error.ValueMustBePositive;
    if (@as(usize, options.width) * options.height > 1920 * 1080) return error.FrameTooLarge;
    return options;
}

fn nextUnsigned(comptime T: type, args: []const []const u8, index: *usize) !T {
    return std.fmt.parseUnsigned(T, try nextValue(args, index), 10);
}

fn nextValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return args[index.*];
}

fn parseScene(value: []const u8) !Scene {
    if (std.mem.eql(u8, value, "plasma")) return .plasma;
    if (std.mem.eql(u8, value, "tunnel")) return .tunnel;
    if (std.mem.eql(u8, value, "metaballs")) return .metaballs;
    if (std.mem.eql(u8, value, "horizon")) return .horizon;
    return error.UnknownScene;
}

fn usage(io: Io) void {
    stderrPrint(io,
        \\usage: zig run -O ReleaseFast scripts/kitty-pixel-probe.zig -- [options]
        \\  --demo        play the 24-second sequence at 60 fps
        \\  --scene NAME  render plasma, tunnel, metaballs, or horizon
        \\  --sweep       run 15, 30, and 60 fps
        \\  --fps N       target fps (default 30; may override --demo)
        \\  --seconds N   duration per rate (default 5)
        \\  --width N     framebuffer width (default 320)
        \\  --height N    framebuffer height (default 180)
        \\  --cols N      displayed terminal columns (default 80)
        \\  --rows N      displayed terminal rows (default 24)
        \\  --dry-run     generate and encode without terminal output
        \\
    , .{});
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    writer.interface.print(fmt, args) catch return;
    writer.interface.flush() catch {};
}

test "argument parsing and wire overhead" {
    const options = try parseArgs(&.{ "--fps", "60", "--seconds", "2", "--dry-run" });
    try std.testing.expectEqual(@as(u16, 60), options.fps);
    try std.testing.expectEqual(@as(u16, 2), options.seconds);
    try std.testing.expect(options.dry_run);
    try std.testing.expect(protocolOverhead(4097) > protocolOverhead(4096));

    const demo = try parseArgs(&.{ "--demo", "--fps", "30" });
    try std.testing.expect(demo.demo);
    try std.testing.expectEqual(@as(u16, 30), demo.fps);
    try std.testing.expectError(error.ConflictingModes, parseArgs(&.{ "--demo", "--scene", "tunnel" }));
    try std.testing.expectError(error.UnknownScene, parseArgs(&.{ "--scene", "nope" }));
}

test "frame transmission uses one stable image and valid continuation chunks" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const payload = try std.testing.allocator.alloc(u8, chunk_size + 1);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'A');

    try transmitFrame(&output.writer, payload, .{});
    const bytes = output.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b_Ga=T,f=24,s=320,v=180,i=1297088513,q=2,m=1,c=80,r=24,C=1;"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b\\\x1b_Gm=0;A\x1b\\") != null);
}
