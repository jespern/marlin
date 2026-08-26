//! Local image capture for the protocol-only TUI client.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const max_image_bytes: usize = 10 * 1024 * 1024;

const mac_clipboard_script =
    \\ObjC.import('AppKit'); ObjC.import('Foundation');
    \\var p=$.NSPasteboard.generalPasteboard; var t=ObjC.unwrap(p.types).map(ObjC.unwrap); var d=null;
    \\if(t.indexOf('public.png')>=0){d=p.dataForType('public.png');}
    \\else if(t.indexOf('public.tiff')>=0){var x=p.dataForType('public.tiff'); var r=$.NSBitmapImageRep.imageRepWithData(x); d=r.representationUsingTypeProperties($.NSBitmapImageFileTypePNG,$({}));}
    \\d ? ObjC.unwrap(d.base64EncodedStringWithOptions(0)) : '';
;

pub const Pending = struct {
    name: []u8,
    mime: []u8,
    data_base64: []u8,

    pub fn deinit(self: *Pending, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.mime);
        gpa.free(self.data_base64);
        self.* = undefined;
    }
};

pub fn fromPath(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: []const u8,
    requested: []const u8,
) !Pending {
    const path = std.mem.trim(u8, requested, " \t\r\n\"'");
    if (path.len == 0) return error.EmptyPath;
    const absolute = if (std.fs.path.isAbsolute(path))
        try gpa.dupe(u8, path)
    else
        try std.fs.path.join(gpa, &.{ cwd, path });
    defer gpa.free(absolute);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, absolute, gpa, .limited(max_image_bytes));
    defer gpa.free(bytes);
    return fromBytes(gpa, std.fs.path.basename(path), bytes);
}

pub fn fromClipboard(
    gpa: std.mem.Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
) !Pending {
    return switch (builtin.os.tag) {
        .macos => fromMacClipboard(gpa, io, environ),
        .linux => fromLinuxClipboard(gpa, io, environ),
        else => error.ClipboardImageUnsupported,
    };
}

fn fromMacClipboard(
    gpa: std.mem.Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
) !Pending {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", mac_clipboard_script },
        .environ_map = environ,
        .stdout_limit = .limited(base64Limit()),
        .stderr_limit = .limited(16 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.ClipboardReadFailed;
    const encoded = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (encoded.len == 0) return error.NoImageOnClipboard;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    if (decoded_len > max_image_bytes) return error.ImageTooLarge;
    return .{
        .name = try gpa.dupe(u8, "clipboard.png"),
        .mime = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, encoded),
    };
}

fn fromLinuxClipboard(
    gpa: std.mem.Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
) !Pending {
    const commands = [_][]const []const u8{
        &.{ "wl-paste", "--no-newline", "--type", "image/png" },
        &.{ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" },
    };
    for (commands) |argv| {
        const result = std.process.run(gpa, io, .{
            .argv = argv,
            .environ_map = environ,
            .stdout_limit = .limited(max_image_bytes),
            .stderr_limit = .limited(16 * 1024),
        }) catch continue;
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0 and result.stdout.len > 0)
            return fromBytes(gpa, "clipboard.png", result.stdout);
    }
    return error.NoImageOnClipboard;
}

fn fromBytes(gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) !Pending {
    if (bytes.len == 0) return error.EmptyImage;
    if (bytes.len > max_image_bytes) return error.ImageTooLarge;
    const mime = detectMime(bytes) orelse return error.UnsupportedImage;
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    errdefer gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return .{
        .name = try gpa.dupe(u8, if (name.len > 0) name else "image"),
        .mime = try gpa.dupe(u8, mime),
        .data_base64 = encoded,
    };
}

fn detectMime(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xff\xd8\xff")) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

fn base64Limit() usize {
    return std.base64.standard.Encoder.calcSize(max_image_bytes) + 1024;
}

test "path attachment detects and encodes PNG" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes = "\x89PNG\r\n\x1a\nbody";
    try temp.dir.writeFile(threaded.io(), .{ .sub_path = "shot.png", .data = bytes });
    const path = try temp.dir.realPathFileAlloc(threaded.io(), "shot.png", gpa);
    defer gpa.free(path);
    var pending = try fromPath(gpa, threaded.io(), ".", path);
    defer pending.deinit(gpa);
    try std.testing.expectEqualStrings("image/png", pending.mime);
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(pending.data_base64);
    const decoded = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, pending.data_base64);
    try std.testing.expectEqualStrings(bytes, decoded);
}

test "mac clipboard script unwraps individual pasteboard type names" {
    try std.testing.expect(std.mem.indexOf(u8, mac_clipboard_script, "p.types).map(ObjC.unwrap)") != null);
}

test {
    std.testing.refAllDecls(@This());
}
