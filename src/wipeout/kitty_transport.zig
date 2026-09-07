//! The Kitty graphics wire format for a shipped frame, shared by the client's
//! pixel-effect engine and the wipEout probe's `--client-transport`, so the
//! probe's A/B exercises the client's exact bytes.
//!
//! One frame is one synchronized update (DEC 2026) holding a cursor move to
//! the placement's top-left and one `a=T` (transmit-and-display) under a
//! fixed image id AND a fixed placement id (`p=1`). The placement id is what
//! keeps a 60 fps stream cheap: the protocol says a display without one
//! creates another placement of the same image every time (kitty
//! graphics-protocol.rst, "Not specifying a placement id ... results in
//! multiple placements"; Ghostty 1.3.1 ImageStorage.addPlacement mints an
//! internal id per call), and a terminal draws every placement every frame,
//! so the game slid into stutter as thousands piled up. With `p=1` the same
//! pair replaces the previous placement, "without flicker".
const std = @import("std");

pub const chunk_bytes: usize = 4096;
/// The one placement each image keeps; every frame replaces it.
pub const placement_id: u32 = 1;

/// Where the image goes, in 0-based cells, and how many cells it scales to.
pub const Placement = struct {
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,
};

/// One complete frame: BSU, cursor to `at`, the a=T with its continuation
/// chunks, ESU. The caller flushes.
pub fn shipFrame(w: *std.Io.Writer, encoded: []const u8, id: u32, width: u32, height: u32, compressed: bool, at: Placement) !void {
    try w.writeAll("\x1b[?2026h");
    try w.print("\x1b[{d};{d}H", .{ @as(u32, at.row) + 1, @as(u32, at.col) + 1 });
    try transmitEncoded(w, encoded, id, width, height, compressed, at.cols, at.rows);
    try w.writeAll("\x1b[?2026l");
}

/// The a=T itself: base64 `encoded` RGB (zlib'd when `compressed`) in 4 KiB
/// chunks, `q=2` so the terminal never answers, `C=1` so the cursor stays.
pub fn transmitEncoded(w: *std.Io.Writer, encoded: []const u8, id: u32, width: u32, height: u32, compressed: bool, cols: u16, rows: u16) !void {
    const first_end: usize = @min(chunk_bytes, encoded.len);
    const more: u1 = if (first_end < encoded.len) 1 else 0;
    try w.print(
        "\x1b_Ga=T,f=24,s={d},v={d},i={d},p={d},q=2{s},m={d},c={d},r={d},C=1;{s}\x1b\\",
        .{ width, height, id, placement_id, if (compressed) ",o=z" else "", more, cols, rows, encoded[0..first_end] },
    );
    var offset: usize = first_end;
    while (offset < encoded.len) {
        const end: usize = @min(offset + chunk_bytes, encoded.len);
        const m: u1 = if (end < encoded.len) 1 else 0;
        try w.print("\x1b_Gm={d};{s}\x1b\\", .{ m, encoded[offset..end] });
        offset = end;
    }
}

/// Drop the image and its placement (effect ended).
pub fn freeImage(w: *std.Io.Writer, id: u32) !void {
    try w.print("\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{id});
}

/// Bytes a frame costs on the wire: the payload plus ~40 of framing per chunk.
pub fn wireBytes(encoded_len: usize) usize {
    return encoded_len + 40 * (encoded_len / chunk_bytes + 1);
}
