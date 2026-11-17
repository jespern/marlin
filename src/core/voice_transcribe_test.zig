//! Unit tests for voice_transcribe.zig. Tests live beside the module they
//! cover (docs/TESTING.md); anything they reach into is `pub` there.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const temp_dir = @import("../testing/temp_dir.zig");
const voice_transcribe = @import("voice_transcribe.zig");

test {
    std.testing.refAllDecls(voice_transcribe);
}

fn script(gpa: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, body: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path, 0o700));
    return path;
}

test "dictation needs /voice setup and ffmpeg; it never guesses" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/nonexistent");
    const cfg: config.Config = .{};
    try std.testing.expectError(error.VoiceNotSetUp, voice_transcribe.runtime(gpa, threaded.io(), &env, cfg));
    var enabled = cfg;
    enabled.voice_enabled = true;
    enabled.voice_engine = "whisper-turbo";
    enabled.voice_stt_bin = "whisper-cli";
    // Configured, but no ffmpeg on PATH to convert the phone's audio.
    try std.testing.expectError(error.VoiceNotSetUp, voice_transcribe.runtime(gpa, threaded.io(), &env, enabled));
}

test "a clip is converted, transcribed, cleaned, and its files removed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try temp_dir.Dir.initFromProcess(gpa, io, "web-transcribe");
    defer tmp.deinit();

    // Stand-ins: ffmpeg copies `-i <in>` to the last argument; the engine
    // checks it got the converted wav and prints whisper-style output.
    const ffmpeg = try script(gpa, io, tmp.path, "ffmpeg",
        \\#!/bin/sh
        \\in=""; while [ $# -gt 1 ]; do [ "$1" = -i ] && in="$2"; shift; done
        \\cp "$in" "$1"
        \\
    );
    defer gpa.free(ffmpeg);
    const stt = try script(gpa, io, tmp.path, "whisper-cli",
        \\#!/bin/sh
        \\while [ $# -gt 0 ]; do [ "$1" = -f ] && wav="$2"; shift; done
        \\[ "$(cat "$wav")" = AUDIO ] || exit 3
        \\printf '[00:00:00.000 --> 00:00:01.000]  push   the\n commits \n'
        \\
    );
    defer gpa.free(stt);

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const path_env = try std.fmt.allocPrint(gpa, "{s}:/bin:/usr/bin", .{tmp.path});
    defer gpa.free(path_env);
    try env.put("PATH", path_env); // stand-ins first; cp and cat from the system
    try env.put("TMPDIR", tmp.path);
    var cfg: config.Config = .{};
    cfg.voice_enabled = true;
    cfg.voice_engine = "whisper-turbo";
    cfg.voice_model = "/models/ggml.bin";
    cfg.voice_stt_bin = stt;

    const rt = try voice_transcribe.runtime(gpa, io, &env, cfg);
    defer gpa.free(rt.ffmpeg);
    const text = try voice_transcribe.transcribe(gpa, io, &env, rt, "AUDIO");
    defer gpa.free(text);
    try std.testing.expectEqualStrings("push the commits", text);

    // Nothing of the clip is left behind.
    var dir = try Io.Dir.cwd().openDir(io, tmp.path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, "marlin-dictation-"));
}
