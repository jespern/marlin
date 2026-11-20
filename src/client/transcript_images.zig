//! Images in the transcript: attachments the user sent and images tools
//! returned, drawn inline under their label with Kitty graphics. The client
//! fetches each once from the daemon's blob store (blob_get), hands the PNG
//! to the terminal as-is (Kitty decodes it), and reserves rows sized from its
//! pixels and the terminal's cell size. PNG only: a JPEG decoder would cost
//! about 100 KB of binary. Without Kitty graphics only the label shows.

const std = @import("std");
const shell_images = @import("shell_images.zig");

pub const Encoded = shell_images.Encoded;

/// Larger blobs stay a label: on the wire bytes travel as a JSON number
/// array (about 3.5×), and the protocol caps a line at 32 MiB.
pub const max_blob_bytes: u64 = 8 * 1024 * 1024;
pub fn isImageMime(mime: []const u8) bool {
    return std.mem.eql(u8, mime, "image/png");
}

pub const Entry = struct {
    state: enum { fetching, ready, failed },
    image: Encoded = .{ .format = .png, .width = 0, .height = 0, .data = &.{} },
};

pub const Cache = struct {
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            if (entry.value_ptr.image.data.len > 0) gpa.free(entry.value_ptr.image.data);
        }
        self.map.deinit(gpa);
    }

    pub fn get(self: *const Cache, hash: []const u8) ?*const Entry {
        return self.map.getPtr(hash);
    }

    /// Note a needed image; true when the caller must request it now.
    pub fn want(self: *Cache, gpa: std.mem.Allocator, hash: []const u8) bool {
        if (self.map.contains(hash)) return false;
        const key = gpa.dupe(u8, hash) catch return false;
        self.map.put(gpa, key, .{ .state = .fetching }) catch {
            gpa.free(key);
            return false;
        };
        return true;
    }

    pub fn awaiting(self: *const Cache, hash: []const u8) bool {
        const entry = self.map.get(hash) orelse return false;
        return entry.state == .fetching;
    }

    /// A requested image's bytes arrived. True when it is now drawable.
    pub fn deliver(self: *Cache, gpa: std.mem.Allocator, hash: []const u8, bytes: []const u8) bool {
        const entry = self.map.getPtr(hash) orelse return false;
        if (entry.state != .fetching) return false;
        entry.image = encode(gpa, bytes) catch {
            entry.state = .failed;
            return false;
        };
        entry.state = .ready;
        return true;
    }

    /// The daemon could not provide it (expired or missing).
    pub fn fail(self: *Cache, hash: []const u8) void {
        if (self.map.getPtr(hash)) |entry| entry.state = .failed;
    }
};

const png_signature = "\x89PNG\r\n\x1a\n";

/// The PNG as the terminal will receive it, with its size from the header.
pub fn encode(gpa: std.mem.Allocator, bytes: []const u8) !Encoded {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], png_signature) or !std.mem.eql(u8, bytes[12..16], "IHDR"))
        return error.UnsupportedImage;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0) return error.InvalidImage;
    return .{ .format = .png, .width = width, .height = height, .data = try gpa.dupe(u8, bytes) };
}

pub const Cells = struct { cols: u16, rows: u16 };

/// The cell box an image takes: never wider than `max_cols` or taller than
/// `max_rows`, never upscaled, aspect kept. Unknown cell size assumes 8×16.
pub fn fit(width: u32, height: u32, cell_w: u32, cell_h: u32, max_cols: u16, max_rows: u16) Cells {
    const cw: u64 = if (cell_w > 0) cell_w else 8;
    const ch: u64 = if (cell_h > 0) cell_h else 16;
    if (width == 0 or height == 0 or max_cols == 0 or max_rows == 0) return .{ .cols = 0, .rows = 0 };
    // Scale (as a fraction of the native size) that fits both bounds.
    var scale_num: u64 = 1;
    var scale_den: u64 = 1;
    const max_w_px = @as(u64, max_cols) * cw;
    const max_h_px = @as(u64, max_rows) * ch;
    if (width > max_w_px) {
        scale_num = max_w_px;
        scale_den = width;
    }
    if (@as(u64, height) * scale_num > max_h_px * scale_den) {
        scale_num = max_h_px;
        scale_den = height;
    }
    const shown_w = @max(1, @as(u64, width) * scale_num / scale_den);
    const shown_h = @max(1, @as(u64, height) * scale_num / scale_den);
    return .{
        .cols = @intCast(@min(max_cols, (shown_w + cw - 1) / cw)),
        .rows = @intCast(@min(max_rows, (shown_h + ch - 1) / ch)),
    };
}
