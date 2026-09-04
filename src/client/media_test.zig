//! Unit tests for media.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in media.zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const media = @import("media.zig");
const fromPath = media.fromPath;
const mac_clipboard_script = media.mac_clipboard_script;

test {
    std.testing.refAllDecls(media);
}

test "path attachment detects and encodes PNG" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, threaded.io(), "marlin-media");
    defer temp.deinit();
    const bytes = "\x89PNG\r\n\x1a\nbody";
    const shot = try std.fs.path.join(gpa, &.{ temp.path, "shot.png" });
    defer gpa.free(shot);
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = shot, .data = bytes });
    const path = try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), shot, gpa);
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
