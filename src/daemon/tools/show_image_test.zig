const std = @import("std");
const show_image = @import("show_image.zig");

test "show_image returns a PNG as media and explains everything else" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "chart.png", .data = @embedFile("png_sample_rgba") });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "not an image" });

    const shown = show_image.run(gpa, io, .{ .path = "chart.png" }, dir);
    defer shown.deinit(gpa);
    try std.testing.expectEqual(@import("../../core/block.zig").ToolStatus.ok, shown.status);
    try std.testing.expectEqual(@as(usize, 1), shown.media.len);
    try std.testing.expectEqualStrings("image/png", shown.media[0].mime);
    try std.testing.expectEqualStrings("chart.png", shown.media[0].name);
    try std.testing.expect(std.mem.startsWith(u8, shown.output, "Shown to the user: chart.png"));

    const text = show_image.run(gpa, io, .{ .path = "notes.txt" }, dir);
    defer text.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, text.output, "error: notes.txt is not a PNG image"));
    const missing = show_image.run(gpa, io, .{ .path = "gone.png" }, dir);
    defer missing.deinit(gpa);
    try std.testing.expectEqualStrings("error: gone.png does not exist", missing.output);
    try std.testing.expectEqual(@as(usize, 0), missing.media.len);
}
