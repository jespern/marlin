//! show_image: put an image file in front of the user, inline in their
//! Marlin transcript (client/transcript_images.zig draws it). Native agents
//! get it as a tool whose result carries the image as media; Claude Code
//! guests get it through the marlin MCP bridge, which returns MCP image
//! content that the guest translation stores the same way.

const std = @import("std");
const Io = std.Io;
const files = @import("files.zig");
const registry = @import("registry.zig");

pub const spec_name = "show_image";
pub const spec_description = "Show the user an image file (PNG or JPEG, up to 8 MB) inline in their Marlin transcript: a chart, screenshot, or diagram you made or found. You see the image too.";
pub const spec_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The image file: absolute, or relative to the working directory"}},"required":["path"]}
;

pub const Args = struct { path: []const u8 };

/// The transcript draws images up to this size (see transcript_images).
pub const max_bytes: usize = 8 * 1024 * 1024;

pub const Loaded = struct {
    bytes: []u8,
    mime: []const u8,
    /// The file's base name, a slice of the caller's path.
    name: []const u8,
};

pub fn mimeOf(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    return null;
}

pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8, cwd: []const u8) !Loaded {
    const abs = try files.resolvePath(gpa, path, cwd);
    defer gpa.free(abs);
    const bytes = Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.ImageTooLarge,
        else => return err,
    };
    errdefer gpa.free(bytes);
    if (bytes.len > max_bytes) return error.ImageTooLarge;
    const mime = mimeOf(bytes) orelse return error.NotAnImage;
    return .{ .bytes = bytes, .mime = mime, .name = std.fs.path.basename(path) };
}

/// What the model reads back after a failed load.
pub fn failureText(gpa: std.mem.Allocator, path: []const u8, err: anyerror) []u8 {
    return switch (err) {
        error.NotAnImage => std.fmt.allocPrint(gpa, "error: {s} is not a PNG or JPEG image", .{path}),
        error.ImageTooLarge => std.fmt.allocPrint(gpa, "error: {s} is larger than 8 MB; save a smaller copy and show that", .{path}),
        error.FileNotFound => std.fmt.allocPrint(gpa, "error: {s} does not exist", .{path}),
        else => std.fmt.allocPrint(gpa, "error: could not read {s}: {t}", .{ path, err }),
    } catch @panic("oom");
}

pub fn run(gpa: std.mem.Allocator, io: Io, args: Args, cwd: []const u8) registry.ExecOut {
    const loaded = load(gpa, io, args.path, cwd) catch |err|
        return .{ .output = failureText(gpa, args.path, err), .status = .err };
    const media = gpa.alloc(registry.MediaOutput, 1) catch @panic("oom");
    media[0] = .{
        .bytes = loaded.bytes,
        .mime = gpa.dupe(u8, loaded.mime) catch @panic("oom"),
        .name = gpa.dupe(u8, loaded.name) catch @panic("oom"),
    };
    return .{
        .output = std.fmt.allocPrint(gpa, "Shown to the user: {s} ({Bi:.1})", .{ loaded.name, loaded.bytes.len }) catch @panic("oom"),
        .status = .ok,
        .media = media,
    };
}
