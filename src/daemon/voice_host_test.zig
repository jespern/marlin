//! Unit tests for voice_host.zig: dictation set up and transcribed on the
//! daemon's machine for a client attached over `--remote`.
const std = @import("std");
const Io = std.Io;
const voice = @import("../core/voice.zig");
const voice_host = @import("voice_host.zig");

test {
    std.testing.refAllDecls(voice_host);
}

/// A private machine: stand-in ffmpeg and parakeet on PATH, its own config
/// and data directories.
const Machine = struct {
    temp: @import("../testing/temp_dir.zig").Dir,
    env: std.process.Environ.Map,

    fn init(gpa: std.mem.Allocator, io: Io) !Machine {
        var m: Machine = .{ .temp = try .initFromProcess(gpa, io, "marlin-voice-host"), .env = .init(gpa) };
        errdefer m.deinit();
        try m.script(io, "ffmpeg",
            \\#!/bin/sh
            \\in=""; while [ $# -gt 1 ]; do [ "$1" = -i ] && in="$2"; shift; done
            \\cp "$in" "$1"
            \\
        );
        try m.script(io, "parakeet-mlx",
            \\#!/bin/sh
            \\[ "$(cat "$1")" = AUDIO ] || exit 3
            \\printf ' hello   there \n'
            \\
        );
        const path = try std.fmt.allocPrint(gpa, "{s}/bin:/bin:/usr/bin", .{m.temp.path});
        defer gpa.free(path);
        try m.env.put("PATH", path);
        try m.env.put("HOME", m.temp.path);
        try m.env.put("TMPDIR", m.temp.path);
        inline for (.{ .{ "XDG_CONFIG_HOME", "config" }, .{ "XDG_DATA_HOME", "data" } }) |dir| {
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ m.temp.path, dir[1] });
            defer gpa.free(full);
            try m.env.put(dir[0], full);
        }
        return m;
    }

    fn script(m: *Machine, io: Io, name: []const u8, body: []const u8) !void {
        const gpa = std.testing.allocator;
        const dir = try std.fmt.allocPrint(gpa, "{s}/bin", .{m.temp.path});
        defer gpa.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
        defer gpa.free(path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
        try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path, 0o700));
    }

    fn deinit(m: *Machine) void {
        m.env.deinit();
        m.temp.deinit();
    }
};

test "the daemon's machine reports, sets up, switches, and transcribes voice for a remote client" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var m = try Machine.init(gpa, io);
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    // Not set up: what could be, and on which machine.
    const before = try voice_host.status(arena.allocator(), io, &m.env, "victory");
    try std.testing.expect(!before.enabled);
    try std.testing.expectEqualStrings("", before.engine);
    try std.testing.expectEqualStrings("victory", before.host);
    try std.testing.expect(before.ffmpeg);
    for (before.engines) |engine| try std.testing.expectEqual(std.mem.eql(u8, engine.name, "parakeet"), engine.available);
    try std.testing.expectError(error.NotSetUp, voice_host.set(gpa, io, &m.env, true, null));
    const nothing = voice_host.transcribe(gpa, io, &m.env, "AUDIO");
    try std.testing.expect(nothing == .err);

    // A missing engine says what to install, and where.
    var progress: voice.DownloadProgress = .{};
    const missing = (try voice_host.setup(gpa, io, &m.env, "victory", .whisper_turbo, .ptt, &progress)).?;
    defer gpa.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "brew install whisper-cpp") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "victory") != null);

    try std.testing.expectEqual(@as(?[]u8, null), try voice_host.setup(gpa, io, &m.env, "victory", .parakeet, .ptt, &progress));
    const ready = try voice_host.status(arena.allocator(), io, &m.env, "victory");
    try std.testing.expect(ready.enabled);
    try std.testing.expectEqualStrings("parakeet", ready.engine);
    try std.testing.expectEqualStrings("ptt", ready.mode);

    try voice_host.set(gpa, io, &m.env, null, "toggle");
    try std.testing.expectEqualStrings("toggle", (try voice_host.status(arena.allocator(), io, &m.env, "victory")).mode);
    try voice_host.set(gpa, io, &m.env, false, null);
    try std.testing.expect(!(try voice_host.status(arena.allocator(), io, &m.env, "victory")).enabled);
    try voice_host.set(gpa, io, &m.env, true, null);

    const heard = voice_host.transcribe(gpa, io, &m.env, "AUDIO");
    defer if (heard == .text) gpa.free(heard.text);
    try std.testing.expectEqualStrings("hello there", heard.text);
}
