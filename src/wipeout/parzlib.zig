//! Parallel zlib encoding for large framebuffers. The input is cut into
//! row bands, each deflated on its own thread as an independent raw
//! stream whose last block is left non-final and byte aligned (a sync
//! flush); the fragments concatenate into one valid deflate stream behind
//! a zlib header, with an Adler-32 of the whole input as the trailer. A
//! decoder sees a single stream, so the Kitty graphics protocol accepts it
//! unchanged. Back-references never cross bands because each band starts
//! with an empty window.

const std = @import("std");
const flate = std.compress.flate;
const Io = std.Io;

pub const max_bands: usize = 8;

/// zlib header for deflate with a 32 KiB window and the fastest level;
/// 0x7801 is divisible by 31 as the format requires.
const header = [2]u8{ 0x78, 0x01 };

const BandJob = struct {
    src: []const u8,
    window: []u8,
    out: []u8,
    final: bool,
    /// Bytes produced, or null on failure.
    produced: ?usize = null,

    fn run(job: *BandJob) void {
        job.produced = compressBand(job.src, job.window, job.out, job.final);
    }
};

fn compressBand(src: []const u8, window: []u8, out: []u8, final: bool) ?usize {
    var writer: Io.Writer = .fixed(out);
    var compressor = flate.Compress.init(&writer, window, .raw, .fastest) catch return null;
    compressor.writer.writeAll(src) catch return null;
    if (final) {
        compressor.finish() catch return null;
    } else {
        compressor.writer.flush() catch return null;
    }
    return writer.buffered().len;
}

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    bands: usize,
    windows: [max_bands][]u8 = [_][]u8{&.{}} ** max_bands,
    outputs: [max_bands][]u8 = [_][]u8{&.{}} ** max_bands,

    pub fn init(gpa: std.mem.Allocator, bands: usize) Encoder {
        return .{ .gpa = gpa, .bands = std.math.clamp(bands, 1, max_bands) };
    }

    pub fn deinit(self: *Encoder) void {
        for (&self.windows) |*w| if (w.len > 0) self.gpa.free(w.*);
        for (&self.outputs) |*o| if (o.len > 0) self.gpa.free(o.*);
        self.* = undefined;
    }

    fn ensureBuffers(self: *Encoder, band_len: usize) !void {
        // Deflate can expand incompressible input slightly; leave room.
        const out_len = band_len + band_len / 8 + 4096;
        var i: usize = 0;
        while (i < self.bands) : (i += 1) {
            if (self.windows[i].len == 0) self.windows[i] = try self.gpa.alloc(u8, 2 * flate.max_window_len);
            if (self.outputs[i].len < out_len) {
                if (self.outputs[i].len > 0) self.gpa.free(self.outputs[i]);
                self.outputs[i] = try self.gpa.alloc(u8, out_len);
            }
        }
    }

    /// Compress `src` into `dst` as one zlib stream. Returns the used
    /// prefix of `dst`, or null when a band failed or the result would not
    /// fit; callers then fall back to sending the frame raw.
    pub fn compress(self: *Encoder, dst: []u8, src: []const u8) ?[]u8 {
        if (src.len == 0) return null;
        const bands = @min(self.bands, @max(src.len / (64 * 1024), 1));
        const band_len = (src.len + bands - 1) / bands;
        self.ensureBuffers(band_len) catch return null;

        var jobs: [max_bands]BandJob = undefined;
        var threads: [max_bands]?std.Thread = .{null} ** max_bands;
        var i: usize = 0;
        while (i < bands) : (i += 1) {
            const start = i * band_len;
            const end = @min(start + band_len, src.len);
            jobs[i] = .{ .src = src[start..end], .window = self.windows[i], .out = self.outputs[i], .final = i + 1 == bands };
        }
        i = 0;
        while (i + 1 < bands) : (i += 1) {
            threads[i] = std.Thread.spawn(.{}, BandJob.run, .{&jobs[i]}) catch blk: {
                jobs[i].run();
                break :blk null;
            };
        }
        jobs[bands - 1].run();
        for (threads[0..bands]) |maybe| {
            if (maybe) |th| th.join();
        }

        var total: usize = header.len + 4;
        i = 0;
        while (i < bands) : (i += 1) total += jobs[i].produced orelse return null;
        if (total > dst.len) return null;

        @memcpy(dst[0..header.len], &header);
        var pos: usize = header.len;
        i = 0;
        while (i < bands) : (i += 1) {
            const n = jobs[i].produced.?;
            @memcpy(dst[pos .. pos + n], jobs[i].out[0..n]);
            pos += n;
        }
        std.mem.writeInt(u32, dst[pos..][0..4], std.hash.Adler32.hash(src), .big);
        pos += 4;
        return dst[0..pos];
    }
};

test "parallel zlib stream decodes to the input" {
    const gpa = std.testing.allocator;
    // Enough data for several bands, with structure so deflate has work.
    const len = 640 * 480 * 3;
    const src = try gpa.alloc(u8, len);
    defer gpa.free(src);
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (src, 0..) |*b, i| b.* = if (i % 7 == 0) random.int(u8) else @truncate(i / 640);

    var encoder = Encoder.init(gpa, 6);
    defer encoder.deinit();
    const dst = try gpa.alloc(u8, len + 8192);
    defer gpa.free(dst);
    const compressed = encoder.compress(dst, src) orelse return error.CompressFailed;
    try std.testing.expect(compressed.len < len);

    var in: Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&in, .zlib, &window);
    const out = try gpa.alloc(u8, len);
    defer gpa.free(out);
    try decompress.reader.readSliceAll(out);
    try std.testing.expectEqualSlices(u8, src, out);
}
