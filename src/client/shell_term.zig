//! Client-side terminal emulation for the experimental shell tab (`!!`).
//!
//! A read-only libghostty-vt mirror of a shell the daemon runs: restored
//! from the daemon's snapshot, then fed the PTY output that follows it, and
//! drawn into a vaxis window. The daemon's own mirror answers the program's
//! terminal queries, so this one never writes back.
const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");

/// Matches the daemon's mirror, so a restored snapshot keeps its history.
pub const scrollback_bytes: usize = 16 * 1024 * 1024;
const max_continuation_bytes: usize = 64 * 1024;

pub const Emulator = struct {
    gpa: std.mem.Allocator,
    terminal: vt.Terminal,
    /// Persistent so escape sequences split across output chunks parse.
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    /// Bumped whenever the terminal changes, to invalidate derived views.
    generation: u64 = 0,

    /// A blank terminal. Heap-allocated: the stream points at `terminal`.
    pub fn create(gpa: std.mem.Allocator, io: Io, grid_cols: u16, grid_rows: u16) !*Emulator {
        const terminal: vt.Terminal = try .init(io, gpa, .{
            .cols = @max(grid_cols, 1),
            .rows = @max(grid_rows, 1),
            .max_scrollback_bytes = scrollback_bytes,
        });
        return adopt(gpa, terminal, "");
    }

    /// Restore a daemon snapshot: the terminal moves to its final address,
    /// then its stream replays any half-parsed sequence exactly once.
    pub fn fromSnapshot(gpa: std.mem.Allocator, io: Io, bytes: []const u8) !*Emulator {
        var reader: Io.Reader = .fixed(bytes);
        var decoded = try vt.snapshot.decode(gpa, io, &reader, .{ .max_continuation_bytes = max_continuation_bytes });
        defer decoded.deinit(gpa);
        const pending: []const u8 = switch (decoded.continuation) {
            .ground => "",
            .bytes => |b| b,
        };
        return adopt(gpa, decoded.toOwned(), pending);
    }

    fn adopt(gpa: std.mem.Allocator, terminal: vt.Terminal, pending: []const u8) !*Emulator {
        var owned = terminal;
        const self = gpa.create(Emulator) catch |err| {
            owned.deinit(gpa);
            return err;
        };
        self.* = .{ .gpa = gpa, .terminal = owned, .stream = undefined };
        self.stream = self.terminal.vtStream();
        if (pending.len > 0) self.stream.nextSlice(pending);
        return self;
    }

    pub fn destroy(self: *Emulator) void {
        const gpa = self.gpa;
        self.stream.deinit();
        self.render.deinit(gpa);
        self.terminal.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn feed(self: *Emulator, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
        self.generation +%= 1;
    }

    /// Full-screen programs (vim, htop) run on the alternate screen.
    pub fn onAlternateScreen(self: *const Emulator) bool {
        return self.terminal.screens.active_key == .alternate;
    }

    pub fn resize(self: *Emulator, grid_cols: u16, grid_rows: u16) !void {
        if (grid_cols == 0 or grid_rows == 0) return;
        if (grid_cols == self.terminal.cols and grid_rows == self.terminal.rows) return;
        try self.terminal.resize(self.gpa, .{ .cols = grid_cols, .rows = grid_rows });
        self.generation +%= 1;
    }

    /// Move the viewport through scrollback; negative is up.
    pub fn scroll(self: *Emulator, rows_delta: isize) void {
        self.terminal.scrollViewport(.{ .delta = rows_delta });
    }

    pub fn scrollToBottom(self: *Emulator) void {
        self.terminal.scrollViewport(.bottom);
    }

    /// True while the viewport shows history rather than the live screen.
    pub fn scrolledBack(self: *const Emulator) bool {
        return self.terminal.screens.active.pages.viewport != .active;
    }

    /// True when the program asked for mouse reports (htop, vim, ...).
    pub fn tracksMouse(self: *const Emulator) bool {
        return self.terminal.flags.mouse_event != .none;
    }

    /// Encode a mouse event at grid cell (col, row) for a program tracking
    /// the mouse. Cell pixel sizes may be zero when the host terminal never
    /// said; any consistent size works for cell-based reports.
    pub fn encodeMouse(self: *const Emulator, writer: *Io.Writer, mouse: vaxis.Mouse, col: u16, row: u16, cell_width: u16, cell_height: u16) !void {
        const cw: u32 = if (cell_width > 0) cell_width else 10;
        const ch: u32 = if (cell_height > 0) cell_height else 20;
        const button: ?vt.input.MouseButton = switch (mouse.button) {
            .left => .left,
            .middle => .middle,
            .right => .right,
            .wheel_up => .four,
            .wheel_down => .five,
            .wheel_left => .six,
            .wheel_right => .seven,
            .none => null,
            else => return,
        };
        const action: vt.input.MouseAction = switch (mouse.type) {
            .press => .press,
            .release => .release,
            .motion, .drag => .motion,
        };
        try vt.input.encodeMouse(writer, .{
            .action = action,
            .button = button,
            .mods = .{ .shift = mouse.mods.shift, .alt = mouse.mods.alt, .ctrl = mouse.mods.ctrl },
            .pos = .{
                .x = (@as(f32, @floatFromInt(col)) + 0.5) * @as(f32, @floatFromInt(cw)),
                .y = (@as(f32, @floatFromInt(row)) + 0.5) * @as(f32, @floatFromInt(ch)),
            },
        }, .fromTerminal(&self.terminal, .{
            .screen = .{ .width = cw * self.terminal.cols, .height = ch * self.terminal.rows },
            .cell = .{ .width = cw, .height = ch },
            .padding = .{},
        }));
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
