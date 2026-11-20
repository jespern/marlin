//! Messages one agent sends another arrive as input. Since user_msg/steer
//! carry `from`, the sender is explicit; messages stored before that are
//! recognized by the header daemon/tools/sessions.zig wrote, so old ones
//! fold and stay out of prompt history too.

const std = @import("std");

pub const Parsed = struct {
    /// "title · handle", or the outside assistant's name.
    from: []const u8,
    /// The sender's words, without the header.
    body: []const u8,
};

const session_prefix = "[Message from another Marlin session: \"";
const outside_suffix = ", the user's assistant outside Marlin. It reads your reply here.]";
const outside_prefix = "[Message from ";

/// Recognize a legacy agent message. `from` is allocated (title · handle).
pub fn parseLegacy(gpa: std.mem.Allocator, text: []const u8) !?Parsed {
    if (!std.mem.startsWith(u8, text, outside_prefix)) return null;
    const header_end = std.mem.indexOf(u8, text, "]\n\n") orelse return null;
    const header = text[0 .. header_end + 1];
    const body = text[header_end + 3 ..];
    if (std.mem.startsWith(u8, header, session_prefix)) {
        // `"TITLE" (MODEL), handle HANDLE. Answer …]` — the title may hold
        // quotes and parentheses, so anchor on the last `), handle `.
        const handle_marker = "), handle ";
        const handle_at = std.mem.lastIndexOf(u8, header, handle_marker) orelse return null;
        const handle_start = handle_at + handle_marker.len;
        const handle_end = std.mem.indexOfScalarPos(u8, header, handle_start, '.') orelse return null;
        const model_open = std.mem.lastIndexOf(u8, header[0..handle_at], "\" (") orelse return null;
        if (model_open < session_prefix.len) return null;
        const title = header[session_prefix.len..model_open];
        return .{
            .from = try std.fmt.allocPrint(gpa, "{s} · {s}", .{ title, header[handle_start..handle_end] }),
            .body = body,
        };
    }
    if (std.mem.endsWith(u8, header, outside_suffix)) {
        return .{
            .from = try gpa.dupe(u8, header[outside_prefix.len .. header.len - outside_suffix.len]),
            .body = body,
        };
    }
    return null;
}
