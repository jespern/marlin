//! Microphone capture for dictation. On macOS the client records in-process
//! through AudioQueue: ffmpeg's avfoundation input lost the first 0.9 s
//! (built-in mic) to 3.2 s (an external USB interface) of every recording,
//! while the native queue delivers audio about 0.2 s after the press. Other
//! platforms keep recording with ffmpeg (see voice.recordArgv).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const native = builtin.os.tag == .macos;

/// The format every engine wants: 16 kHz mono signed 16-bit PCM.
pub const sample_rate: u32 = 16_000;
/// 50 ms per buffer: the first audio arrives promptly, and stopping loses at
/// most one partial buffer's worth.
const buffer_bytes: u32 = sample_rate / 20 * 2;
const buffer_count = 4;

/// Called once, from the audio thread, when the first audio arrives: the
/// moment the microphone is really listening.
pub const OnListening = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    io: Io,
    queue: AudioQueueRef = null,
    mutex: Io.Mutex = .init,
    pcm: std.ArrayList(u8) = .empty,
    running: std.atomic.Value(bool) = .init(false),
    heard: std.atomic.Value(bool) = .init(false),
    on_listening: ?OnListening = null,
    failed: bool = false,

    /// Open the default input and start capturing. The recorder must stay
    /// at a fixed address until stop() or abort(): the audio thread holds it.
    pub fn start(self: *Recorder, on_listening: ?OnListening) !void {
        if (!native) return error.Unsupported;
        self.on_listening = on_listening;
        const format: AudioStreamBasicDescription = .{
            .mSampleRate = @floatFromInt(sample_rate),
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            .mBytesPerPacket = 2,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 2,
            .mChannelsPerFrame = 1,
            .mBitsPerChannel = 16,
        };
        // No run loop: callbacks arrive on the queue's own thread.
        if (AudioQueueNewInput(&format, callback, self, null, null, 0, &self.queue) != 0) return error.MicrophoneUnavailable;
        errdefer {
            _ = AudioQueueDispose(self.queue, 1);
            self.queue = null;
        }
        for (0..buffer_count) |_| {
            var buffer: ?*AudioQueueBuffer = null;
            if (AudioQueueAllocateBuffer(self.queue, buffer_bytes, &buffer) != 0) return error.MicrophoneUnavailable;
            if (AudioQueueEnqueueBuffer(self.queue, buffer, 0, null) != 0) return error.MicrophoneUnavailable;
        }
        self.running.store(true, .release);
        if (AudioQueueStart(self.queue, null) != 0) {
            self.running.store(false, .release);
            return error.MicrophoneUnavailable;
        }
    }

    /// Stop capturing and hand over the recorded PCM (gpa-owned).
    pub fn stop(self: *Recorder) ![]u8 {
        self.halt();
        if (self.failed) {
            self.pcm.deinit(self.gpa);
            return error.OutOfMemory;
        }
        return self.pcm.toOwnedSlice(self.gpa);
    }

    /// Stop and throw the recording away.
    pub fn abort(self: *Recorder) void {
        self.halt();
        self.pcm.deinit(self.gpa);
    }

    pub fn listening(self: *const Recorder) bool {
        return self.heard.load(.acquire);
    }

    fn halt(self: *Recorder) void {
        // `native` first, at compile time: AudioToolbox exists only on macOS.
        if (!native or self.queue == null) return;
        self.running.store(false, .release);
        // Synchronous: no callback runs after these return.
        _ = AudioQueueStop(self.queue, 1);
        _ = AudioQueueDispose(self.queue, 1);
        self.queue = null;
    }

    fn callback(user: ?*anyopaque, queue: AudioQueueRef, buffer: ?*AudioQueueBuffer, _: ?*const anyopaque, _: u32, _: ?*const anyopaque) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(user.?));
        const buf = buffer orelse return;
        const size = buf.mAudioDataByteSize;
        if (size > 0) {
            const bytes: [*]const u8 = @ptrCast(buf.mAudioData.?);
            self.mutex.lockUncancelable(self.io);
            self.pcm.appendSlice(self.gpa, bytes[0..size]) catch {
                self.failed = true;
            };
            self.mutex.unlock(self.io);
            if (!self.heard.swap(true, .acq_rel)) if (self.on_listening) |notify| notify.func(notify.ctx);
        }
        if (self.running.load(.acquire)) _ = AudioQueueEnqueueBuffer(queue, buf, 0, null);
    }
};

/// A RIFF/WAVE file around 16 kHz mono 16-bit PCM.
pub fn writeWav(io: Io, path: []const u8, pcm: []const u8) !void {
    var header: [44]u8 = undefined;
    const data_len: u32 = @intCast(pcm.len);
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], 36 + data_len, .little);
    @memcpy(header[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little);
    std.mem.writeInt(u16, header[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, header[22..24], 1, .little); // mono
    std.mem.writeInt(u32, header[24..28], sample_rate, .little);
    std.mem.writeInt(u32, header[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, header[32..34], 2, .little);
    std.mem.writeInt(u16, header[34..36], 16, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_len, .little);
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, &header);
    try file.writeStreamingAll(io, pcm);
}

// ------------------------------------------------------------- AudioQueue --

const AudioQueueRef = ?*opaque {};

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

const AudioQueueBuffer = extern struct {
    mAudioDataBytesCapacity: u32,
    mAudioData: ?*anyopaque,
    mAudioDataByteSize: u32,
    mUserData: ?*anyopaque,
    mPacketDescriptionCapacity: u32,
    mPacketDescriptions: ?*anyopaque,
    mPacketDescriptionCount: u32,
};

const kAudioFormatLinearPCM: u32 = 0x6C70636D; // 'lpcm'
const kLinearPCMFormatFlagIsSignedInteger: u32 = 1 << 2;
const kLinearPCMFormatFlagIsPacked: u32 = 1 << 3;

const InputCallback = *const fn (?*anyopaque, AudioQueueRef, ?*AudioQueueBuffer, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void;

extern "c" fn AudioQueueNewInput(format: *const AudioStreamBasicDescription, callback: InputCallback, user: ?*anyopaque, run_loop: ?*anyopaque, run_loop_mode: ?*anyopaque, flags: u32, out_queue: *AudioQueueRef) i32;
extern "c" fn AudioQueueAllocateBuffer(queue: AudioQueueRef, size: u32, out_buffer: *?*AudioQueueBuffer) i32;
extern "c" fn AudioQueueEnqueueBuffer(queue: AudioQueueRef, buffer: ?*AudioQueueBuffer, packet_count: u32, packets: ?*const anyopaque) i32;
extern "c" fn AudioQueueStart(queue: AudioQueueRef, start_time: ?*const anyopaque) i32;
extern "c" fn AudioQueueStop(queue: AudioQueueRef, immediate: u8) i32;
extern "c" fn AudioQueueDispose(queue: AudioQueueRef, immediate: u8) i32;
