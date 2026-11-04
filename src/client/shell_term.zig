//! Client-side terminal emulation for the experimental shell tab (`!!`).
//!
//! PTY output from the daemon is fed through libghostty-vt; the resulting
//! grid is drawn into a vaxis window. Replies the emulated terminal owes the
//! program (cursor position and device attribute reports, ...) queue up in
//! `replies` and go back upstream as shell input, exactly as a terminal
//! would write them to its PTY.
const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");

pub const Emulator = struct {
    gpa: std.mem.Allocator,
    terminal: vt.Terminal,
    /// Persistent so escape sequences split across output chunks parse.
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    replies: std.ArrayList(u8) = .empty,

    /// Heap-allocated: the stream's handler points at `terminal`.
    pub fn create(gpa: std.mem.Allocator, io: Io, grid_cols: u16, grid_rows: u16) !*Emulator {
        const self = try gpa.create(Emulator);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .terminal = try .init(io, gpa, .{ .cols = @max(grid_cols, 1), .rows = @max(grid_rows, 1) }),
            .stream = undefined,
        };
        var handler = self.terminal.vtHandler();
        handler.effects.write_pty = writePty;
        handler.effects.device_attributes = deviceAttributes;
        self.stream = .init(.{ .allocator = gpa, .handler = handler });
        return self;
    }

    pub fn destroy(self: *Emulator) void {
        const gpa = self.gpa;
        self.stream.deinit();
        self.render.deinit(gpa);
        self.terminal.deinit(gpa);
        self.replies.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn feed(self: *Emulator, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    pub fn resize(self: *Emulator, grid_cols: u16, grid_rows: u16) !void {
        if (grid_cols == 0 or grid_rows == 0) return;
        if (grid_cols == self.terminal.cols and grid_rows == self.terminal.rows) return;
        try self.terminal.resize(self.gpa, .{ .cols = grid_cols, .rows = grid_rows });
    }

    pub fn cols(self: *const Emulator) u16 {
        return self.terminal.cols;
    }

    pub fn rows(self: *const Emulator) u16 {
        return self.terminal.rows;
    }

    /// Encode a key press for the program, honoring the modes it has set
    /// (application cursor keys, the Kitty keyboard protocol, ...).
    pub fn encodeKey(self: *const Emulator, writer: *Io.Writer, key: vaxis.Key) !void {
        const event = keyEvent(key) orelse return;
        var opts: vt.input.KeyEncodeOptions = .fromTerminal(&self.terminal);
        // The host terminal already resolved Option: a reported alt is Alt.
        opts.macos_option_as_alt = .true;
        try vt.input.encodeKey(writer, event, opts);
    }

    /// Encode pasted text, bracketed when the program asked for it.
    /// `text` is rewritten in place to neutralize unsafe control bytes.
    pub fn encodePaste(self: *const Emulator, writer: *Io.Writer, text: []u8) !void {
        const parts = vt.input.encodePaste(text, .fromTerminal(&self.terminal));
        for (parts) |part| try writer.writeAll(part);
    }

    /// Draw the visible grid. Cell text is formatted into `arena`, which must
    /// outlive the frame's render.
    pub fn draw(self: *Emulator, arena: std.mem.Allocator, win: vaxis.Window) !void {
        try self.render.update(self.gpa, &self.terminal);
        const row_data = self.render.row_data.slice();
        const row_cells = row_data.items(.cells);
        const height = @min(self.render.rows, win.height);
        for (0..height) |y| {
            const cells = row_cells[y].slice();
            const raws = cells.items(.raw);
            const styles = cells.items(.style);
            const graphemes = cells.items(.grapheme);
            const width = @min(raws.len, win.width);
            for (0..width) |x| {
                const raw = raws[x];
                if (raw.wide == .spacer_tail) continue;
                var cell: vaxis.Cell = .{
                    // Style id 0 is the default style; `styles` is undefined there.
                    .style = if (raw.style_id != 0) cellStyle(styles[x]) else .{},
                };
                switch (raw.content_tag) {
                    .codepoint, .codepoint_grapheme => if (raw.hasText() and raw.wide != .spacer_head) {
                        cell.char = .{
                            .grapheme = try graphemeText(arena, raw.codepoint(), if (raw.hasGrapheme()) graphemes[x] else &.{}),
                            .width = if (raw.wide == .wide) 2 else 1,
                        };
                    },
                    .bg_color_palette => cell.style.bg = .{ .index = raw.content.color_palette.data },
                    .bg_color_rgb => {
                        const rgb = raw.content.color_rgb;
                        cell.style.bg = .{ .rgb = .{ rgb.r, rgb.g, rgb.b } };
                    },
                }
                win.writeCell(@intCast(x), @intCast(y), cell);
            }
        }
        const cursor = self.render.cursor;
        if (cursor.visible) if (cursor.viewport) |at| if (at.x < win.width and at.y < win.height) {
            win.showCursor(at.x, at.y);
            win.setCursorShape(cursorShape(cursor.visual_style, cursor.blinking));
            return;
        };
        win.hideCursor();
    }

    fn writePty(handler: *vt.TerminalStream.Handler, bytes: []const u8) void {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        const self: *Emulator = @alignCast(@fieldParentPtr("stream", stream));
        self.replies.appendSlice(self.gpa, bytes) catch {};
    }

    fn deviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }
};

fn graphemeText(arena: std.mem.Allocator, first: u21, rest: []const u21) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [4]u8 = undefined;
    try out.appendSlice(arena, buf[0 .. std.unicode.utf8Encode(first, &buf) catch 0]);
    for (rest) |cp| try out.appendSlice(arena, buf[0 .. std.unicode.utf8Encode(cp, &buf) catch continue]);
    return out.items;
}

fn cellColor(color: vt.Style.Color) vaxis.Color {
    return switch (color.value()) {
        .none => .default,
        .palette => |index| .{ .index = index },
        .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    };
}

pub fn cellStyle(style: vt.Style) vaxis.Style {
    return .{
        .fg = cellColor(style.fg_color),
        .bg = cellColor(style.bg_color),
        .ul = cellColor(style.underline_color),
        .ul_style = switch (style.flags.underline) {
            .none => .off,
            .single => .single,
            .double => .double,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        },
        .bold = style.flags.bold,
        .dim = style.flags.faint,
        .italic = style.flags.italic,
        .blink = style.flags.blink,
        .reverse = style.flags.inverse,
        .invisible = style.flags.invisible,
        .strikethrough = style.flags.strikethrough,
    };
}

fn cursorShape(style: anytype, blinking: bool) vaxis.Cell.CursorShape {
    return switch (style) {
        .bar => if (blinking) .beam_blink else .beam,
        .underline => if (blinking) .underline_blink else .underline,
        else => if (blinking) .block_blink else .block,
    };
}

/// Translate a vaxis key press into the event libghostty-vt encodes.
/// Returns null for keys a shell has no use for (bare modifiers, ...).
pub fn keyEvent(key: vaxis.Key) ?vt.input.KeyEvent {
    const Key = vt.input.Key;
    const mods: vt.input.KeyMods = .{
        .shift = key.mods.shift,
        .ctrl = key.mods.ctrl,
        .alt = key.mods.alt,
        .super = key.mods.super,
        .caps_lock = key.mods.caps_lock,
        .num_lock = key.mods.num_lock,
    };
    const special: ?Key = switch (key.codepoint) {
        vaxis.Key.enter => .enter,
        vaxis.Key.tab => .tab,
        vaxis.Key.escape => .escape,
        vaxis.Key.backspace => .backspace,
        vaxis.Key.space => .space,
        vaxis.Key.insert => .insert,
        vaxis.Key.delete => .delete,
        vaxis.Key.left => .arrow_left,
        vaxis.Key.right => .arrow_right,
        vaxis.Key.up => .arrow_up,
        vaxis.Key.down => .arrow_down,
        vaxis.Key.page_up => .page_up,
        vaxis.Key.page_down => .page_down,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.f1...vaxis.Key.f1 + 11 => @fromBackingInt(@backingInt(Key.f1) + (key.codepoint - vaxis.Key.f1)),
        else => null,
    };
    const base = key.base_layout_codepoint orelse key.codepoint;
    const physical: Key = special orelse switch (base) {
        'a'...'z' => @fromBackingInt(@backingInt(Key.key_a) + (base - 'a')),
        'A'...'Z' => @fromBackingInt(@backingInt(Key.key_a) + (base - 'A')),
        '0'...'9' => @fromBackingInt(@backingInt(Key.digit_0) + (base - '0')),
        '`' => .backquote,
        '\\' => .backslash,
        '[' => .bracket_left,
        ']' => .bracket_right,
        ',' => .comma,
        '=' => .equal,
        '-' => .minus,
        '.' => .period,
        '\'' => .quote,
        ';' => .semicolon,
        '/' => .slash,
        else => .unidentified,
    };
    // Text the key produced; control chords and specials carry none. A key
    // outside the table (non-Latin layout, IME) still types its text.
    var text: []const u8 = key.text orelse "";
    if (special != null and key.codepoint != vaxis.Key.space) text = "";
    if (physical == .unidentified and text.len == 0) return null;
    return .{
        .action = .press,
        .key = physical,
        .mods = mods,
        .consumed_mods = if (text.len > 0 and key.mods.shift) .{ .shift = true } else .{},
        .utf8 = text,
        .unshifted_codepoint = if (special == null) base else 0,
    };
}
