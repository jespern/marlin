//! Terminal-owned state that sits outside Marlin's cell grid.

const std = @import("std");
const vaxis = @import("vaxis");

pub const Progress = enum(u8) {
    hidden = 0,
    normal = 1,
    error_state = 2,
    indeterminate = 3,
    warning = 4,
};

pub fn progressForStates(states: []const @import("../core/proto.zig").SessionState) Progress {
    var running = false;
    for (states) |state| switch (state) {
        .awaiting_approval => return .warning,
        .running => running = true,
        else => {},
    };
    return if (running) .indeterminate else .hidden;
}

pub fn writeProgress(writer: *std.Io.Writer, state: Progress, percent: u8) !void {
    try writer.print("\x1b]9;4;{d};{d}\x1b\\", .{ @intFromEnum(state), @min(percent, 100) });
}

pub fn writeWorkingDirectory(writer: *std.Io.Writer, hostname: []const u8, path: []const u8) !void {
    if (path.len == 0 or path[0] != '/') return error.InvalidAbsolutePath;
    try writer.writeAll("\x1b]7;file://");
    for (hostname) |byte| try writeUriByte(writer, byte, false);
    for (path) |byte| try writeUriByte(writer, byte, true);
    try writer.writeAll("\x1b\\");
}

fn writeUriByte(writer: *std.Io.Writer, byte: u8, allow_slash: bool) !void {
    if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~' or
        (allow_slash and byte == '/'))
    {
        try writer.writeByte(byte);
        return;
    }
    const hex = "0123456789ABCDEF";
    try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
}

pub fn writeNotification(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    sid: u64,
    title: []const u8,
    body: []const u8,
) !void {
    const encoder = std.base64.standard.Encoder;
    const title_buf = try allocator.alloc(u8, encoder.calcSize(title.len));
    defer allocator.free(title_buf);
    const body_buf = try allocator.alloc(u8, encoder.calcSize(body.len));
    defer allocator.free(body_buf);
    const title_b64 = encoder.encode(title_buf, title);
    const body_b64 = encoder.encode(body_buf, body);
    try writer.print("\x1b]99;i=marlin-{d}:d=0:e=1:p=title;{s}\x1b\\", .{ sid, title_b64 });
    try writer.print("\x1b]99;i=marlin-{d}:d=1:e=1:p=body;{s}\x1b\\", .{ sid, body_b64 });
}

pub const Theme = struct {
    foreground: ?[3]u8 = null,
    background: ?[3]u8 = null,
    palette: [16]?[3]u8 = [_]?[3]u8{null} ** 16,
    shimmer: [10]vaxis.Color = fallback_shimmer,

    pub fn applyReport(self: *Theme, report: vaxis.Color.Report) void {
        switch (report.kind) {
            .fg => self.foreground = report.value,
            .bg => self.background = report.value,
            .index => |index| if (index < self.palette.len) {
                self.palette[index] = report.value;
            },
            .cursor => {},
        }
        self.rebuildShimmer();
    }

    fn rebuildShimmer(self: *Theme) void {
        const fg = self.foreground orelse return;
        const bg = self.background orelse return;
        const weights = [_]u8{ 38, 47, 58, 72, 87, 100, 87, 72, 58, 47 };
        for (&self.shimmer, weights) |*color, weight| {
            var rgb: [3]u8 = undefined;
            for (&rgb, fg, bg) |*channel, foreground, background| {
                const mixed = @as(u16, foreground) * weight + @as(u16, background) * (100 - weight);
                channel.* = @intCast(mixed / 100);
            }
            color.* = .{ .rgb = rgb };
        }
    }
};

const fallback_shimmer = [10]vaxis.Color{
    .{ .rgb = .{ 0x6e, 0x6e, 0x6e } },
    .{ .rgb = .{ 0x7e, 0x7e, 0x7e } },
    .{ .rgb = .{ 0x96, 0x96, 0x96 } },
    .{ .rgb = .{ 0xb6, 0xb6, 0xb6 } },
    .{ .rgb = .{ 0xdc, 0xdc, 0xdc } },
    .{ .rgb = .{ 0xff, 0xff, 0xff } },
    .{ .rgb = .{ 0xdc, 0xdc, 0xdc } },
    .{ .rgb = .{ 0xb6, 0xb6, 0xb6 } },
    .{ .rgb = .{ 0x96, 0x96, 0x96 } },
    .{ .rgb = .{ 0x7e, 0x7e, 0x7e } },
};
