const std = @import("std");

pub const idle_ms: i64 = 3 * 60 * 1000;
pub const max_text_bytes: usize = 600;

pub fn clipped(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end > 0 and end < text.len and text[end] & 0xc0 == 0x80) : (end -= 1) {}
    return text[0..end];
}

pub fn plainText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |word| {
        if (out.items.len > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, clipped(word, max_text_bytes - out.items.len));
        if (out.items.len >= max_text_bytes) break;
    }
    return out.toOwnedSlice(allocator);
}
