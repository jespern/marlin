//! Dictation recorded elsewhere, transcribed on the daemon's machine by the
//! engine `/voice setup` chose there (whisper.cpp or parakeet): clips from
//! the phone (web companion) and from TUIs attached over `--remote`
//! (daemon/voice_host.zig). Whatever the container (m4a on iOS, webm in
//! browsers, wav from a TUI), ffmpeg makes the 16 kHz mono wav every engine
//! wants. Audio lives only in temp files, deleted before returning;
//! the transcript goes back to the composer for review, never auto-sent.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const voice = @import("voice.zig");

pub const Error = error{ VoiceNotSetUp, ConvertFailed, TranscriberFailed };

/// The [voice] setup plus the ffmpeg that converts the browser's audio.
pub const Runtime = struct {
    setup: voice.Setup,
    ffmpeg: []const u8,
};

/// Resolve [voice] the way the TUI does (initVoiceFromConfig): enabled, a
/// known engine, its binary, and ffmpeg on PATH. Anything missing means
/// "run /voice setup", not a crash. ffmpeg is gpa-owned.
pub fn runtime(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, cfg: config.Config) !Runtime {
    if (!cfg.voice_enabled) return error.VoiceNotSetUp;
    const engine = voice.Engine.parse(cfg.voice_engine) orelse return error.VoiceNotSetUp;
    if (cfg.voice_stt_bin.len == 0) return error.VoiceNotSetUp;
    const ffmpeg = (try voice.findBinary(gpa, io, environ, &.{"ffmpeg"})) orelse return error.VoiceNotSetUp;
    return .{
        .setup = .{ .engine = engine, .mode = .toggle, .model_path = cfg.voice_model, .stt_bin = cfg.voice_stt_bin },
        .ffmpeg = ffmpeg,
    };
}

/// Transcribe one clip; returns the cleaned, gpa-owned transcript.
pub fn transcribe(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, rt: Runtime, audio: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp_root = environ.get("TMPDIR") orelse "/tmp";
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const dir = try std.fmt.allocPrint(arena, "{s}/marlin-dictation-{x}", .{ std.mem.trimEnd(u8, tmp_root, "/"), std.mem.readInt(u64, &nonce, .little) });
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const clip = try std.fs.path.join(arena, &.{ dir, "clip" });
    const wav = try std.fs.path.join(arena, &.{ dir, "clip.wav" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = clip, .data = audio });

    const convert = try std.process.run(arena, io, .{
        .argv = &.{ rt.ffmpeg, "-hide_banner", "-loglevel", "error", "-i", clip, "-ac", "1", "-ar", "16000", "-y", wav },
        .environ_map = environ,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    });
    if (convert.term != .exited or convert.term.exited != 0) return error.ConvertFailed;

    const stt = try std.process.run(arena, io, .{
        .argv = try voice.sttArgv(arena, rt.setup, wav, dir),
        .environ_map = environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } },
    });
    var text: []const u8 = stt.stdout;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        // parakeet writes a sidecar txt instead of using stdout.
        const sidecar = try std.fs.path.join(arena, &.{ dir, "clip.txt" });
        text = Io.Dir.cwd().readFileAlloc(io, sidecar, arena, .limited(1 << 20)) catch "";
    }
    const cleaned = try voice.cleanTranscript(gpa, text);
    const exited_ok = stt.term == .exited and stt.term.exited == 0;
    if (!exited_ok and cleaned.len == 0) {
        gpa.free(cleaned);
        return error.TranscriberFailed;
    }
    return cleaned;
}
