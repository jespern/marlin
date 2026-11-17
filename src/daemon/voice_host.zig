//! Dictation on the daemon's machine for a client attached from another one
//! (`--remote`): the client records with its own microphone and sends the
//! clip; this machine holds the engine, the model, and the [voice] config,
//! and transcribes, as it already does for the phone. A local TUI does all
//! of this itself (client/tui.zig); the catalog, downloader, and transcriber
//! are shared (core/voice.zig, core/voice_transcribe.zig).
//!
//! These are plain functions: the daemon runs setup and transcription on
//! worker threads and sends what they return (daemon.zig voice_*).

const std = @import("std");
const Io = std.Io;
const proto = @import("../core/proto.zig");
const config = @import("../core/config.zig");
const voice = @import("../core/voice.zig");
const voice_transcribe = @import("../core/voice_transcribe.zig");

/// What is set up here and what could be. Strings are arena-owned.
pub fn status(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, host: []const u8) !proto.VoiceStatus {
    var loaded = try config.load(arena, io, environ);
    defer loaded.deinit();
    const cfg = loaded.value;
    const engines = try arena.alloc(proto.VoiceEngine, std.meta.tags(voice.Engine).len);
    for (std.meta.tags(voice.Engine), engines) |engine, *info| info.* = .{
        .name = engine.configName(),
        .available = try voice.findBinary(arena, io, environ, engine.binaryCandidates()) != null,
        .install_hint = engine.installHint(),
    };
    const ffmpeg = try voice.findBinary(arena, io, environ, &.{"ffmpeg"}) != null;
    const engine = voice.Engine.parse(cfg.voice_engine);
    return .{
        .enabled = cfg.voice_enabled and engine != null and cfg.voice_stt_bin.len > 0 and ffmpeg,
        .engine = if (engine) |e| e.configName() else "",
        .mode = if (std.mem.eql(u8, cfg.voice_mode, "toggle")) "toggle" else "ptt",
        .host = try arena.dupe(u8, host),
        .ffmpeg = ffmpeg,
        .engines = engines,
    };
}

pub const SetError = error{NotSetUp};

/// Turn voice on or off, or change its mode, keeping the rest of the setup.
pub fn set(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, enabled: ?bool, mode: ?[]const u8) !void {
    var loaded = try config.load(gpa, io, environ);
    defer loaded.deinit();
    const cfg = loaded.value;
    if (voice.Engine.parse(cfg.voice_engine) == null or cfg.voice_stt_bin.len == 0) return error.NotSetUp;
    const new_mode: []const u8 = if (mode) |m| (if (std.mem.eql(u8, m, "toggle")) "toggle" else "ptt") else cfg.voice_mode;
    try config.setVoice(gpa, io, environ, enabled orelse cfg.voice_enabled, cfg.voice_engine, new_mode, cfg.voice_model, cfg.voice_stt_bin);
}

/// Set up `engine` here: its binary and ffmpeg must be installed; the model
/// downloads (resumably) through `progress`; then [voice] is written. Null
/// on success, else what the user should do (gpa-owned).
pub fn setup(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    host: []const u8,
    engine: voice.Engine,
    mode: voice.Mode,
    progress: *voice.DownloadProgress,
) !?[]u8 {
    const bin = (try voice.findBinary(gpa, io, environ, engine.binaryCandidates())) orelse
        return try std.fmt.allocPrint(gpa, "{s} needs `{s}` on {s}: install it there, then /voice setup again", .{ engine.configName(), engine.installHint(), host });
    defer gpa.free(bin);
    const ffmpeg = (try voice.findBinary(gpa, io, environ, &.{"ffmpeg"})) orelse
        return try std.fmt.allocPrint(gpa, "voice needs ffmpeg on {s} to read the clips: `brew install ffmpeg` there, then /voice setup again", .{host});
    gpa.free(ffmpeg);

    var model: []u8 = &.{};
    defer gpa.free(model);
    if (engine.modelUrl()) |url| {
        const dir = try voice.modelsDir(gpa, environ);
        defer gpa.free(dir);
        model = try std.fs.path.join(gpa, &.{ dir, engine.modelFileName().? });
        voice.download(gpa, io, url, model, progress) catch |err| return switch (err) {
            error.Cancelled => try gpa.dupe(u8, "voice setup cancelled; /voice setup resumes the download"),
            else => try std.fmt.allocPrint(gpa, "the model download on {s} failed ({t}); /voice setup resumes it", .{ host, err }),
        };
    }
    try config.setVoice(gpa, io, environ, true, engine.configName(), if (mode == .toggle) "toggle" else "ptt", model, bin);
    return null;
}

pub const Transcript = union(enum) {
    /// gpa-owned; empty when nothing was heard.
    text: []u8,
    /// What went wrong, for the user (static).
    err: []const u8,
};

/// One clip (any format ffmpeg reads), transcribed with this machine's setup.
pub fn transcribe(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, audio: []const u8) Transcript {
    var loaded = config.load(gpa, io, environ) catch return .{ .err = "cannot read Marlin's config on the daemon's machine" };
    defer loaded.deinit();
    const rt = voice_transcribe.runtime(gpa, io, environ, loaded.value) catch
        return .{ .err = "voice isn't set up on the daemon's machine: /voice setup" };
    defer gpa.free(rt.ffmpeg);
    const text = voice_transcribe.transcribe(gpa, io, environ, rt, audio) catch |err| {
        std.log.warn("dictation failed: {t}", .{err});
        return .{ .err = "transcription failed on the daemon's machine" };
    };
    return .{ .text = text };
}
