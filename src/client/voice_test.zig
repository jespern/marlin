//! Unit tests for voice.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in voice.zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const voice = @import("voice.zig");
const DownloadProgress = voice.DownloadProgress;
const Engine = voice.Engine;
const cleanTranscript = voice.cleanTranscript;
const download = voice.download;
const modelsDir = voice.modelsDir;
const prewarmModel = voice.prewarmModel;
const recordArgv = voice.recordArgv;
const sttArgv = voice.sttArgv;

test {
    std.testing.refAllDecls(voice);
}

test "engine catalog round-trips config names and knows its dependencies" {
    inline for (@typeInfo(Engine).@"enum".fields) |f| {
        const engine = @field(Engine, f.name);
        try std.testing.expectEqual(engine, Engine.parse(engine.configName()).?);
        try std.testing.expect(engine.binaryCandidates().len > 0);
        try std.testing.expect(engine.installHint().len > 0);
    }
    try std.testing.expect(Engine.parse("nope") == null);
    // Whisper engines download a model; parakeet self-manages.
    try std.testing.expect(Engine.whisper_turbo.modelUrl() != null);
    try std.testing.expect(Engine.parakeet.modelUrl() == null);
}

test "stt argv shapes: whisper stdout flags, parakeet sidecar layout" {
    const gpa = std.testing.allocator;
    const whisper = try sttArgv(gpa, .{
        .engine = .whisper_turbo,
        .mode = .ptt,
        .model_path = "/m/turbo.bin",
        .stt_bin = "/usr/local/bin/whisper-cli",
    }, "/tmp/v.wav", "/tmp");
    defer gpa.free(whisper);
    try std.testing.expectEqualStrings("-nt", whisper[5]);
    try std.testing.expectEqualStrings("/m/turbo.bin", whisper[2]);

    const parakeet = try sttArgv(gpa, .{
        .engine = .parakeet,
        .mode = .toggle,
        .stt_bin = "parakeet-mlx",
    }, "/tmp/v.wav", "/tmp");
    defer gpa.free(parakeet);
    try std.testing.expectEqualStrings("--output-format", parakeet[2]);
}

test "transcript cleaning folds whitespace and strips stray timestamps" {
    const gpa = std.testing.allocator;
    const cleaned = try cleanTranscript(gpa, "  the council \n has [00:00.000 --> 00:02.000] reached\ta verdict \n");
    defer gpa.free(cleaned);
    try std.testing.expectEqualStrings("the council has reached a verdict", cleaned);
}

test "record argv asks for 16k mono wav" {
    const gpa = std.testing.allocator;
    const argv = try recordArgv(gpa, "/opt/homebrew/bin/ffmpeg", "/tmp/v.wav");
    defer gpa.free(argv);
    try std.testing.expectEqualStrings("16000", argv[argv.len - 3]);
    try std.testing.expectEqualStrings("/tmp/v.wav", argv[argv.len - 1]);
}

test "model download: real network smoke (MARLIN_VOICE_NET_TEST=1)" {
    if (std.c.getenv("MARLIN_VOICE_NET_TEST") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.SkipZigTest);
    try environ.put("HOME", home);
    const dir = try modelsDir(gpa, &environ);
    defer gpa.free(dir);
    const dest = try std.fs.path.join(gpa, &.{ dir, Engine.whisper_base.modelFileName().? });
    defer gpa.free(dest);

    var progress = DownloadProgress{};
    try download(gpa, io, Engine.whisper_base.modelUrl().?, dest, &progress);
    const done = progress.done.load(.acquire);
    const total = progress.total.load(.acquire);
    try std.testing.expect(done > 100 * 1024 * 1024); // base is ~148 MB
    try std.testing.expect(total == done);
    const st = try Io.Dir.cwd().statFile(io, dest, .{});
    try std.testing.expectEqual(done, st.size);
}

test "prewarm reads a file to completion and tolerates absence" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-voice-prewarm");
    defer temp.deinit();
    const path = try std.fs.path.join(gpa, &.{ temp.path, "model.bin" });
    defer gpa.free(path);
    const blob = try gpa.alloc(u8, 6 * 1024 * 1024); // spans scratch chunks
    defer gpa.free(blob);
    @memset(blob, 0xab);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = blob });

    prewarmModel(gpa, io, path); // must complete without error signaling
    prewarmModel(gpa, io, "/definitely/not/here.bin"); // and shrug at absence
}
