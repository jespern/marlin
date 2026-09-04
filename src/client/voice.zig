//! Voice input: push-to-talk (or toggle) dictation into the composer.
//!
//! Dormant by design. Nothing here runs, appears in help, or demands a
//! dependency until the user invokes `/voice setup`. Everything heavy lives
//! at process boundaries — ffmpeg records, an STT engine transcribes — and
//! the daemon, protocol, and store never learn audio exists. Recordings are
//! temp files deleted after transcription; the transcript lands in the
//! composer for review, never auto-submitted.
//!
//! Engines are a fixed, tiny catalog (a config slot, not a registry):
//!   - whisper.cpp with large-v3-turbo (recommended: all languages, fast on
//!     Apple Silicon) or base (small download, weaker machines);
//!   - parakeet-mlx (experimental: fastest English-only, Apple Silicon; it
//!     downloads its own model on first use).
//! Switching engines is just `/voice setup` again.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Mode = enum { ptt, toggle };

pub const Engine = enum {
    whisper_turbo,
    whisper_base,
    parakeet,

    pub fn configName(self: Engine) []const u8 {
        return switch (self) {
            .whisper_turbo => "whisper-turbo",
            .whisper_base => "whisper-base",
            .parakeet => "parakeet",
        };
    }

    pub fn parse(name: []const u8) ?Engine {
        inline for (@typeInfo(Engine).@"enum".fields) |f| {
            const e = @field(Engine, f.name);
            if (std.mem.eql(u8, name, e.configName())) return e;
        }
        return null;
    }

    /// Picker line: what the user chooses between at setup.
    pub fn label(self: Engine) []const u8 {
        return switch (self) {
            .whisper_turbo => "whisper large-v3-turbo · all languages, ~1.6 GB model (recommended)",
            .whisper_base => "whisper base · all languages, ~148 MB model, lower accuracy",
            .parakeet => "parakeet-mlx · English only, fastest, downloads its own model (experimental)",
        };
    }

    pub fn modelUrl(self: Engine) ?[]const u8 {
        return switch (self) {
            .whisper_turbo => "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
            .whisper_base => "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
            .parakeet => null,
        };
    }

    pub fn modelFileName(self: Engine) ?[]const u8 {
        return switch (self) {
            .whisper_turbo => "ggml-large-v3-turbo.bin",
            .whisper_base => "ggml-base.bin",
            .parakeet => null,
        };
    }

    /// The executable the engine needs on PATH, plus the install hint we
    /// show when it is missing. Mentioned ONLY during /voice setup.
    pub fn binaryCandidates(self: Engine) []const []const u8 {
        return switch (self) {
            .whisper_turbo, .whisper_base => &.{ "whisper-cli", "whisper-cpp" },
            .parakeet => &.{"parakeet-mlx"},
        };
    }

    pub fn installHint(self: Engine) []const u8 {
        return switch (self) {
            .whisper_turbo, .whisper_base => "brew install whisper-cpp",
            .parakeet => "uv tool install parakeet-mlx",
        };
    }
};

/// Resolved, ready-to-run voice configuration (see config.zig [voice]).
pub const Setup = struct {
    engine: Engine,
    mode: Mode,
    /// Absolute model path (whisper engines only).
    model_path: []const u8 = "",
    /// STT binary resolved at setup time (absolute or PATH name).
    stt_bin: []const u8,
};

/// $XDG_DATA_HOME/marlin/models (or ~/.local/share/marlin/models): model
/// files are data, not state — they survive `rm -rf ~/.local/state/marlin`.
pub fn modelsDir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("XDG_DATA_HOME")) |data| {
        if (data.len > 0) return std.fs.path.join(gpa, &.{ data, "marlin", "models" });
    }
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".local", "share", "marlin", "models" });
}

/// First engine binary found on PATH, or null (checked via `command -v`
/// through the user's shell semantics — no, simpler: stat PATH entries).
pub fn findBinary(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    candidates: []const []const u8,
) !?[]u8 {
    const path_env = environ.get("PATH") orelse return null;
    for (candidates) |name| {
        var it = std.mem.tokenizeScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            const full = try std.fs.path.join(gpa, &.{ dir, name });
            if (Io.Dir.cwd().statFile(io, full, .{})) |_| {
                return full;
            } else |_| {
                gpa.free(full);
            }
        }
    }
    return null;
}

/// Capture command: 16 kHz mono wav, the format every engine wants.
/// ffmpeg finalizes the wav header on SIGINT, which is how recording stops.
pub fn recordArgv(gpa: std.mem.Allocator, ffmpeg: []const u8, wav_path: []const u8) ![]const []const u8 {
    const source: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "-f", "avfoundation", "-i", ":default" }
    else
        &.{ "-f", "alsa", "-i", "default" };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ ffmpeg, "-hide_banner", "-loglevel", "error" });
    try argv.appendSlice(gpa, source);
    try argv.appendSlice(gpa, &.{ "-ac", "1", "-ar", "16000", "-y", wav_path });
    return argv.toOwnedSlice(gpa);
}

/// Transcription command for one wav. Whisper prints the transcript on
/// stdout with -nt/-np; parakeet writes a .txt next to --output-dir, so the
/// caller checks stdout first and falls back to the sidecar file.
pub fn sttArgv(gpa: std.mem.Allocator, setup: Setup, wav_path: []const u8, out_dir: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    switch (setup.engine) {
        .whisper_turbo, .whisper_base => try argv.appendSlice(gpa, &.{
            setup.stt_bin, "-m", setup.model_path, "-f", wav_path, "-nt", "-np",
        }),
        .parakeet => try argv.appendSlice(gpa, &.{
            setup.stt_bin, wav_path, "--output-format", "txt", "--output-dir", out_dir,
        }),
    }
    return argv.toOwnedSlice(gpa);
}

/// Squash whisper/parakeet output into one composer-ready line: timestamps
/// stripped defensively (whisper -nt should omit them), whitespace folded.
pub fn cleanTranscript(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    while (it.next()) |word| {
        // Defensive: `[00:00:00.000 --> 00:00:02.000]` fragments.
        if (word.len > 0 and (word[0] == '[' or std.mem.eql(u8, word, "-->"))) continue;
        if (std.mem.endsWith(u8, word, "]") and std.mem.indexOfScalar(u8, word, ':') != null) continue;
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, word);
    }
    return out.toOwnedSlice(gpa);
}

/// Pull the model file through the page cache so the transcriber that runs
/// a few seconds from now (when the user releases the key) finds hot pages
/// instead of a cold SSD read. Reads into a small scratch buffer that is
/// immediately discarded: the residency lands in the kernel's file cache,
/// never in marlin's RSS. Errors are irrelevant — this is a hint.
pub fn prewarmModel(gpa: std.mem.Allocator, io: Io, path: []const u8) void {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    const scratch = gpa.alloc(u8, 4 * 1024 * 1024) catch return;
    defer gpa.free(scratch);
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositional(io, &.{scratch}, offset) catch return;
        if (n == 0) return;
        offset += n;
    }
}

// ------------------------------------------------------------- download --

pub const DownloadProgress = struct {
    /// Bytes on disk so far (includes a resumed prefix).
    done: std.atomic.Value(u64) = .init(0),
    /// 0 until the response headers reveal the size.
    total: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
};

pub const DownloadError = error{
    HttpStatus,
    Cancelled,
    TooManyRedirects,
} || anyerror;

/// Download `url` to `dest` with resume support: bytes land in `dest.part`
/// and the finished file is renamed into place, so a killed TUI or a lost
/// connection costs nothing but the retry. Progress is published through
/// atomics for the caller's render loop.
pub fn download(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    dest: []const u8,
    progress: *DownloadProgress,
) !void {
    // Already complete from a previous run?
    if (Io.Dir.cwd().statFile(io, dest, .{})) |st| {
        progress.done.store(st.size, .release);
        progress.total.store(st.size, .release);
        return;
    } else |_| {}

    const part_path = try std.fmt.allocPrint(gpa, "{s}.part", .{dest});
    defer gpa.free(part_path);
    if (std.fs.path.dirname(dest)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};

    var offset: u64 = 0;
    if (Io.Dir.cwd().statFile(io, part_path, .{})) |st| {
        offset = st.size;
    } else |_| {}

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var range_buf: [64]u8 = undefined;
    const range_value = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{offset});

    const uri = try std.Uri.parse(url);
    var request = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(8),
        .extra_headers = if (offset > 0)
            &.{.{ .name = "range", .value = range_value }}
        else
            &.{},
    });
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const status = @intFromEnum(response.head.status);
    if (offset > 0 and status == 200) {
        // Server ignored the range: start over.
        offset = 0;
    } else if (status == 416) {
        // Range beyond EOF — the .part is already the whole file.
        Io.Dir.renameAbsolute(part_path, dest, io) catch {};
        if (Io.Dir.cwd().statFile(io, dest, .{})) |st| {
            progress.done.store(st.size, .release);
            progress.total.store(st.size, .release);
            return;
        } else |_| {}
        return error.HttpStatus;
    } else if (status != 200 and status != 206) {
        return error.HttpStatus;
    }

    if (response.head.content_length) |len| {
        progress.total.store(offset + len, .release);
    }
    progress.done.store(offset, .release);

    const file = if (offset > 0)
        try Io.Dir.cwd().openFile(io, part_path, .{ .mode = .write_only })
    else
        try Io.Dir.cwd().createFile(io, part_path, .{ .truncate = true });
    defer file.close(io);

    var transfer_buf: [128 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var pos: u64 = offset;
    while (true) {
        if (progress.cancel.load(.acquire)) return error.Cancelled;
        const chunk = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try file.writePositionalAll(io, chunk, pos);
        pos += chunk.len;
        reader.toss(chunk.len);
        _ = progress.done.fetchAdd(chunk.len, .acq_rel);
    }
    try file.sync(io);

    // Verify completeness when the size was known; a short body must stay
    // a resumable .part, never masquerade as a finished model.
    const expected = progress.total.load(.acquire);
    const got = progress.done.load(.acquire);
    if (expected != 0 and got < expected) return error.EndOfStream;
    try Io.Dir.renameAbsolute(part_path, dest, io);
}

// ---------------------------------------------------------------- tests --
