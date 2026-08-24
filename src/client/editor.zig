//! Multi-line input editor for the TUI prompt (M3 REPL upgrades).
//!
//! Replaces vaxis.widgets.TextInput (single-line gap buffer) with a plain
//! contiguous buffer + byte cursor. Design:
//!
//! - Logical text may contain '\n' (Alt+Enter / Ctrl+J inserts one).
//! - Display soft-wraps at the given width; the box grows 1..max_rows rows.
//! - Large pastes become "[paste #N: X lines]" chips in the text; the raw
//!   bytes live in `pastes` and are expanded on submit. The label is plain
//!   editable text — mangling it just means it goes verbatim, no magic.
//! - History: Up at the first row / Down at the last row walk previous
//!   submissions; the in-progress draft is saved and restored. History is
//!   seeded from replayed user_msg blocks, so it survives reboots.
//! - Cursor movement is codepoint-wise (UTF-8 safe, grapheme-naive: wide
//!   glyphs move as units because we step codepoints, but ZWJ sequences
//!   may take several presses — acceptable for a prompt).

const std = @import("std");
const vaxis = @import("vaxis");

const Editor = @This();

pub const max_rows: usize = 8;
/// Pastes larger than this (bytes or lines) become chips.
pub const chip_bytes: usize = 400;
pub const chip_lines: usize = 4;

gpa: std.mem.Allocator,
text: std.ArrayList(u8) = .empty,
/// Byte offset into `text`; always on a codepoint boundary.
cursor: usize = 0,
/// Raw paste payloads, 1-indexed by chip label.
pastes: std.ArrayList([]u8) = .empty,
/// Previous submissions, oldest first.
history: std.ArrayList([]u8) = .empty,
/// Non-null while walking history: index into `history`.
hist_idx: ?usize = null,
/// Draft saved when history walking began.
draft: ?[]u8 = null,
/// Column the cursor "wants" during vertical movement.
goal_col: ?usize = null,

pub fn init(gpa: std.mem.Allocator) Editor {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Editor) void {
    self.text.deinit(self.gpa);
    for (self.pastes.items) |p| self.gpa.free(p);
    self.pastes.deinit(self.gpa);
    for (self.history.items) |h| self.gpa.free(h);
    self.history.deinit(self.gpa);
    if (self.draft) |d| self.gpa.free(d);
}

pub fn isEmpty(self: *const Editor) bool {
    return self.text.items.len == 0;
}

pub fn isWalkingHistory(self: *const Editor) bool {
    return self.hist_idx != null;
}

// ---------------------------------------------------------------- history --

/// Record a submitted message (called for our own submits AND for replayed
/// user_msg blocks, so history persists across reboots). Consecutive
/// duplicates are skipped.
pub fn pushHistory(self: *Editor, entry: []const u8) void {
    if (entry.len == 0) return;
    if (self.history.items.len > 0 and
        std.mem.eql(u8, self.history.items[self.history.items.len - 1], entry))
        return;
    const owned = self.gpa.dupe(u8, entry) catch return;
    self.history.append(self.gpa, owned) catch self.gpa.free(owned);
}

fn histPrev(self: *Editor) void {
    if (self.history.items.len == 0) return;
    if (self.hist_idx == null) {
        // Entering history: stash the draft.
        if (self.draft) |d| self.gpa.free(d);
        self.draft = self.gpa.dupe(u8, self.text.items) catch return;
        self.hist_idx = self.history.items.len;
    }
    if (self.hist_idx.? == 0) return;
    self.hist_idx = self.hist_idx.? - 1;
    self.setText(self.history.items[self.hist_idx.?]);
}

fn histNext(self: *Editor) void {
    const idx = self.hist_idx orelse return;
    if (idx + 1 < self.history.items.len) {
        self.hist_idx = idx + 1;
        self.setText(self.history.items[self.hist_idx.?]);
    } else {
        // Past the newest: restore the draft.
        self.hist_idx = null;
        const d = self.draft orelse {
            self.setText("");
            return;
        };
        self.draft = null;
        self.setText(d);
        self.gpa.free(d);
    }
}

fn setText(self: *Editor, s: []const u8) void {
    self.text.clearRetainingCapacity();
    self.text.appendSlice(self.gpa, s) catch {};
    self.cursor = self.text.items.len;
    self.goal_col = null;
}

// ------------------------------------------------------------------ paste --

/// Bracketed-paste arrival. Small pastes insert inline (newlines and all —
/// the editor is multi-line now); big ones become chips.
pub fn paste(self: *Editor, data: []const u8) void {
    const nlines = 1 + std.mem.count(u8, data, "\n");
    if (data.len <= chip_bytes and nlines <= chip_lines) {
        self.insertSlice(data);
        return;
    }
    const owned = self.gpa.dupe(u8, data) catch return;
    self.pastes.append(self.gpa, owned) catch {
        self.gpa.free(owned);
        return;
    };
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "[paste #{d}: {d} lines]", .{
        self.pastes.items.len, nlines,
    }) catch return;
    self.insertSlice(label);
}

/// Submit-time expansion: replace intact "[paste #N: ...]" labels with their
/// payloads. Caller owns the returned slice. Resets the editor.
pub fn takeExpanded(self: *Editor) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.gpa);
    const t = self.text.items;
    var i: usize = 0;
    while (i < t.len) {
        if (t[i] == '[' and std.mem.startsWith(u8, t[i..], "[paste #")) {
            if (parseChipLabel(t[i..])) |chip| {
                if (chip.index >= 1 and chip.index <= self.pastes.items.len) {
                    try out.appendSlice(self.gpa, self.pastes.items[chip.index - 1]);
                    i += chip.label_len;
                    continue;
                }
            }
        }
        try out.append(self.gpa, t[i]);
        i += 1;
    }
    self.clear();
    return out.toOwnedSlice(self.gpa);
}

const ChipRef = struct { index: usize, label_len: usize };

fn parseChipLabel(s: []const u8) ?ChipRef {
    // "[paste #" already matched by caller; parse digits, then require
    // ": ... ]" with no intervening newline or '['.
    const prefix = "[paste #".len;
    var j: usize = prefix;
    var index: usize = 0;
    var digits: usize = 0;
    while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {
        index = index * 10 + (s[j] - '0');
        digits += 1;
    }
    if (digits == 0 or j >= s.len or s[j] != ':') return null;
    while (j < s.len) : (j += 1) {
        if (s[j] == ']') return .{ .index = index, .label_len = j + 1 };
        if (s[j] == '\n' or s[j] == '[') return null;
    }
    return null;
}

pub fn clear(self: *Editor) void {
    self.text.clearRetainingCapacity();
    self.cursor = 0;
    self.goal_col = null;
    self.hist_idx = null;
    if (self.draft) |d| {
        self.gpa.free(d);
        self.draft = null;
    }
    for (self.pastes.items) |p| self.gpa.free(p);
    self.pastes.clearRetainingCapacity();
}

// ---------------------------------------------------------------- editing --

pub fn insertSlice(self: *Editor, data: []const u8) void {
    self.text.insertSlice(self.gpa, self.cursor, data) catch return;
    self.cursor += data.len;
    self.goal_col = null;
    self.hist_idx = null;
}

pub fn insertNewline(self: *Editor) void {
    self.insertSlice("\n");
}

fn prevCpStart(t: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and (t[j] & 0b1100_0000) == 0b1000_0000) : (j -= 1) {}
    return j;
}

fn nextCpEnd(t: []const u8, i: usize) usize {
    if (i >= t.len) return t.len;
    const len = std.unicode.utf8ByteSequenceLength(t[i]) catch 1;
    return @min(i + len, t.len);
}

pub fn moveLeft(self: *Editor) void {
    self.cursor = prevCpStart(self.text.items, self.cursor);
    self.goal_col = null;
}

pub fn moveRight(self: *Editor) void {
    self.cursor = nextCpEnd(self.text.items, self.cursor);
    self.goal_col = null;
}

/// Option+Left / Alt+B: move to the beginning of the previous word.
/// A word is letters, digits, underscore, or any non-ASCII codepoint;
/// punctuation and whitespace are boundaries. This follows readline's
/// backward-word behavior: skip boundaries, then skip the word itself.
pub fn moveWordLeft(self: *Editor) void {
    self.cursor = wordStartBefore(self.text.items, self.cursor);
    self.goal_col = null;
}

fn wordStartBefore(t: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i > 0) {
        const start = prevCpStart(t, i);
        if (isWordCodepoint(t[start..i])) break;
        i = start;
    }
    while (i > 0) {
        const start = prevCpStart(t, i);
        if (!isWordCodepoint(t[start..i])) break;
        i = start;
    }
    return i;
}

/// Option+Right / Alt+F: move to the end of the next word.
pub fn moveWordRight(self: *Editor) void {
    self.cursor = wordEndAfter(self.text.items, self.cursor);
    self.goal_col = null;
}

fn wordEndAfter(t: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i < t.len) {
        const end = nextCpEnd(t, i);
        if (isWordCodepoint(t[i..end])) break;
        i = end;
    }
    while (i < t.len) {
        const end = nextCpEnd(t, i);
        if (!isWordCodepoint(t[i..end])) break;
        i = end;
    }
    return i;
}

fn isWordCodepoint(bytes: []const u8) bool {
    const cp = std.unicode.utf8Decode(bytes) catch return false;
    if (cp >= 0x80) return true;
    return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
}

pub fn deleteBefore(self: *Editor) void {
    if (self.cursor == 0) return;
    const start = prevCpStart(self.text.items, self.cursor);
    self.text.replaceRange(self.gpa, start, self.cursor - start, "") catch return;
    self.cursor = start;
    self.goal_col = null;
}

pub fn deleteAfter(self: *Editor) void {
    const t = self.text.items;
    if (self.cursor >= t.len) return;
    const end = nextCpEnd(t, self.cursor);
    self.text.replaceRange(self.gpa, self.cursor, end - self.cursor, "") catch return;
    self.goal_col = null;
}

/// Start of the logical line containing byte offset i.
fn lineStart(t: []const u8, i: usize) usize {
    if (std.mem.lastIndexOfScalar(u8, t[0..i], '\n')) |nl| return nl + 1;
    return 0;
}

/// End (exclusive of '\n') of the logical line containing byte offset i.
fn lineEnd(t: []const u8, i: usize) usize {
    if (std.mem.indexOfScalarPos(u8, t, i, '\n')) |nl| return nl;
    return t.len;
}

pub fn moveLineStart(self: *Editor) void {
    self.cursor = lineStart(self.text.items, self.cursor);
    self.goal_col = null;
}

pub fn moveLineEnd(self: *Editor) void {
    self.cursor = lineEnd(self.text.items, self.cursor);
    self.goal_col = null;
}

pub fn deleteToLineEnd(self: *Editor) void {
    const end = lineEnd(self.text.items, self.cursor);
    self.text.replaceRange(self.gpa, self.cursor, end - self.cursor, "") catch return;
}

pub fn deleteToLineStart(self: *Editor) void {
    const start = lineStart(self.text.items, self.cursor);
    self.text.replaceRange(self.gpa, start, self.cursor - start, "") catch return;
    self.cursor = start;
}

/// Option+Delete / Alt+Backspace: delete backward using the same word
/// boundaries as Option+Left.
pub fn deleteWordBefore(self: *Editor) void {
    const start = wordStartBefore(self.text.items, self.cursor);
    self.text.replaceRange(self.gpa, start, self.cursor - start, "") catch return;
    self.cursor = start;
    self.goal_col = null;
}

/// Ctrl+W: delete the whitespace-delimited word before the cursor.
pub fn deleteWordBeforeWhitespace(self: *Editor) void {
    const t = self.text.items;
    var i = self.cursor;
    while (i > 0 and isSpace(t[i - 1])) i -= 1;
    while (i > 0 and !isSpace(t[i - 1])) i -= 1;
    self.text.replaceRange(self.gpa, i, self.cursor - i, "") catch return;
    self.cursor = i;
    self.goal_col = null;
}

/// Alt+D / Option+Forward Delete: delete forward using the same word
/// boundaries as Option+Right.
pub fn deleteWordAfter(self: *Editor) void {
    const end = wordEndAfter(self.text.items, self.cursor);
    self.text.replaceRange(self.gpa, self.cursor, end - self.cursor, "") catch return;
    self.goal_col = null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// Vertical movement within the text. Returns false when the cursor is
/// already on the first/last display row — the caller then walks history.
pub fn moveUp(self: *Editor, width: usize) bool {
    const rows = self.layoutRows(width);
    const pos = self.cursorRowCol(rows, width);
    if (pos.row == 0) return false;
    self.placeCursor(rows, pos.row - 1, self.takeGoal(pos.col), width);
    return true;
}

pub fn moveDown(self: *Editor, width: usize) bool {
    const rows = self.layoutRows(width);
    const pos = self.cursorRowCol(rows, width);
    if (pos.row + 1 >= rows.len) return false;
    self.placeCursor(rows, pos.row + 1, self.takeGoal(pos.col), width);
    return true;
}

fn takeGoal(self: *Editor, current: usize) usize {
    if (self.goal_col) |g| return g;
    self.goal_col = current;
    return current;
}

pub fn histUp(self: *Editor) void {
    self.histPrev();
}

pub fn histDown(self: *Editor) void {
    self.histNext();
}

// ---------------------------------------------------------------- display --

/// A display row: byte range into `text` (newline excluded).
pub const Row = struct { start: usize, end: usize };

var row_buf: [256]Row = undefined;

/// Soft-wrap layout. Wrap unit is the codepoint (display-width aware).
/// Returns rows in a static buffer (single-threaded TUI; capacity is far
/// beyond max_rows * any sane width because long pastes are chips).
pub fn layoutRows(self: *const Editor, width: usize) []Row {
    const t = self.text.items;
    const w = if (width < 4) 4 else width;
    var n: usize = 0;
    var start: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        if (t[i] == '\n') {
            if (n < row_buf.len) row_buf[n] = .{ .start = start, .end = i };
            n += 1;
            i += 1;
            start = i;
            col = 0;
            continue;
        }
        const end = nextCpEnd(t, i);
        const cpw = cpDisplayWidth(t[i..end]);
        if (col + cpw > w) {
            if (n < row_buf.len) row_buf[n] = .{ .start = start, .end = i };
            n += 1;
            start = i;
            col = 0;
        }
        col += cpw;
        i = end;
    }
    if (n < row_buf.len) row_buf[n] = .{ .start = start, .end = t.len };
    n += 1;
    return row_buf[0..@min(n, row_buf.len)];
}

/// Approximate display width of one codepoint: wide for CJK/emoji ranges,
/// 1 otherwise. (Grapheme clusters beyond a single codepoint render wider
/// than we predict; cursor stays consistent because layout and cursor
/// mapping share this function.)
fn cpDisplayWidth(bytes: []const u8) usize {
    const cp = std.unicode.utf8Decode(bytes) catch return 1;
    if (cp >= 0x1100 and (cp <= 0x115F or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x2FFFD))) return 2;
    return 1;
}

pub const RowCol = struct { row: usize, col: usize };

pub fn cursorRowCol(self: *const Editor, rows: []const Row, width: usize) RowCol {
    _ = width;
    const t = self.text.items;
    for (rows, 0..) |r, ri| {
        // Cursor belongs to this row if within [start, end]; for a row that
        // ends in '\n' the position == end means "before the newline".
        const is_last = ri == rows.len - 1;
        const upper = if (is_last) r.end else r.end;
        if (self.cursor >= r.start and self.cursor <= upper) {
            // On soft-wrap boundaries cursor==end of row N == start of N+1;
            // prefer the later row so typing continues on the visible line,
            // except when the row ends with a hard newline.
            if (!is_last and self.cursor == r.end and
                (r.end >= t.len or t[r.end] != '\n'))
                continue;
            var col: usize = 0;
            var i = r.start;
            while (i < self.cursor) {
                const end = nextCpEnd(t, i);
                col += cpDisplayWidth(t[i..end]);
                i = end;
            }
            return .{ .row = ri, .col = col };
        }
    }
    return .{ .row = if (rows.len == 0) 0 else rows.len - 1, .col = 0 };
}

fn placeCursor(self: *Editor, rows: []const Row, row: usize, goal: usize, width: usize) void {
    _ = width;
    const t = self.text.items;
    const r = rows[row];
    var col: usize = 0;
    var i = r.start;
    while (i < r.end and col < goal) {
        const end = nextCpEnd(t, i);
        col += cpDisplayWidth(t[i..end]);
        i = end;
    }
    self.cursor = i;
}

/// How many rows the input box needs at `width` (1..max_rows).
pub fn displayHeight(self: *const Editor, width: usize) usize {
    const n = self.layoutRows(width).len;
    return @max(1, @min(n, max_rows));
}

/// Draw into `win` (height = displayHeight rows). The prompt and editable
/// text have separate styles so a parent input panel can keep one continuous
/// background beneath both. Continuation rows get matching indent.
pub fn draw(
    self: *const Editor,
    win: vaxis.Window,
    prompt: []const u8,
    prompt_style: vaxis.Style,
    text_style: vaxis.Style,
) void {
    const w: usize = win.width;
    const prompt_width: usize = win.gwidth(prompt);
    if (w <= prompt_width + 2) return;
    const body_w = w - prompt_width;
    const rows = self.layoutRows(body_w);
    const pos = self.cursorRowCol(rows, body_w);
    const h: usize = win.height;

    // Scroll the row window to keep the cursor visible.
    const first = if (pos.row >= h) pos.row + 1 - h else 0;
    const t = self.text.items;

    var screen_row: usize = 0;
    var ri = first;
    while (ri < rows.len and screen_row < h) : (ri += 1) {
        if (ri == 0) {
            _ = win.printSegment(.{ .text = prompt, .style = prompt_style }, .{
                .row_offset = @intCast(screen_row),
                .wrap = .none,
            });
        } else {
            // Continuation indent aligns with the prompt.
            var continuation_style = text_style;
            continuation_style.fg = .{ .index = 7 };
            continuation_style.dim = true;
            _ = win.printSegment(.{ .text = "…", .style = continuation_style }, .{
                .row_offset = @intCast(screen_row),
                .wrap = .none,
            });
        }
        const seg = t[rows[ri].start..rows[ri].end];
        if (seg.len > 0) {
            const child = win.child(.{
                .x_off = @intCast(prompt_width),
                .y_off = @intCast(screen_row),
                .width = @intCast(body_w),
                .height = 1,
            });
            _ = child.printSegment(.{ .text = seg, .style = text_style }, .{ .wrap = .none });
        }
        screen_row += 1;
    }

    win.showCursor(@intCast(prompt_width + pos.col), @intCast(pos.row - first));
}

// ------------------------------------------------------------------ tests --

const testing = std.testing;

test "insert, newline, expand-free submit round trip" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("hello");
    ed.insertNewline();
    ed.insertSlice("world");
    const out = try ed.takeExpanded();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello\nworld", out);
    try testing.expect(ed.isEmpty());
}

test "big paste becomes chip and expands on submit" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var big: [600]u8 = undefined;
    @memset(&big, 'x');
    ed.insertSlice("see: ");
    ed.paste(&big);
    try testing.expect(std.mem.indexOf(u8, ed.text.items, "[paste #1:") != null);
    const out = try ed.takeExpanded();
    defer testing.allocator.free(out);
    try testing.expect(out.len == "see: ".len + 600);
    try testing.expect(std.mem.startsWith(u8, out, "see: xxxx"));
}

test "small paste inserts inline" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.paste("just a line");
    try testing.expectEqualStrings("just a line", ed.text.items);
}

test "mangled chip label passes through verbatim" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("[paste #9: 4 lines]"); // no such paste
    const out = try ed.takeExpanded();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[paste #9: 4 lines]", out);
}

test "history walk saves and restores draft" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.pushHistory("first");
    ed.pushHistory("second");
    ed.insertSlice("draft in progress");
    ed.histUp();
    try testing.expectEqualStrings("second", ed.text.items);
    ed.histUp();
    try testing.expectEqualStrings("first", ed.text.items);
    ed.histDown();
    try testing.expectEqualStrings("second", ed.text.items);
    ed.histDown();
    try testing.expectEqualStrings("draft in progress", ed.text.items);
}

test "history dedupes consecutive" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.pushHistory("same");
    ed.pushHistory("same");
    try testing.expectEqual(@as(usize, 1), ed.history.items.len);
}

test "vertical movement and edge detection" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("one\ntwo\nthree");
    // cursor at end (row 2)
    try testing.expect(ed.moveUp(40)); // -> row 1
    try testing.expect(ed.moveUp(40)); // -> row 0
    try testing.expect(!ed.moveUp(40)); // at top: history's turn
    try testing.expect(ed.moveDown(40));
    try testing.expect(ed.moveDown(40));
    try testing.expect(!ed.moveDown(40)); // at bottom
}

test "soft wrap heights" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try testing.expectEqual(@as(usize, 1), ed.displayHeight(10));
    ed.insertSlice("aaaaaaaaaaaaaaaaaaaaaaaaa"); // 25 chars at width 10 = 3 rows
    try testing.expectEqual(@as(usize, 3), ed.displayHeight(10));
}

test "delete word and line ops" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("git commit -m wip");
    ed.deleteWordBeforeWhitespace();
    try testing.expectEqualStrings("git commit -m ", ed.text.items);
    ed.deleteToLineStart();
    try testing.expectEqualStrings("", ed.text.items);
}

test "word deletion uses readline boundaries" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("hello-world café");

    ed.deleteWordBefore();
    try testing.expectEqualStrings("hello-world ", ed.text.items);
    ed.deleteWordBefore();
    try testing.expectEqualStrings("hello-", ed.text.items);

    ed.moveLineStart();
    ed.deleteWordAfter();
    try testing.expectEqualStrings("-", ed.text.items);
}

test "utf8 cursor movement" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("aé漢");
    ed.moveLeft(); // before 漢
    ed.moveLeft(); // before é
    ed.deleteAfter(); // delete é
    try testing.expectEqualStrings("a漢", ed.text.items);
}

test "wordwise cursor movement crosses punctuation and unicode" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("one, two café");

    ed.moveWordLeft();
    try testing.expectEqual(@as(usize, "one, two ".len), ed.cursor);
    ed.moveWordLeft();
    try testing.expectEqual(@as(usize, "one, ".len), ed.cursor);
    ed.moveWordLeft();
    try testing.expectEqual(@as(usize, 0), ed.cursor);

    ed.moveWordRight();
    try testing.expectEqual(@as(usize, "one".len), ed.cursor);
    ed.moveWordRight();
    try testing.expectEqual(@as(usize, "one, two".len), ed.cursor);
    ed.moveWordRight();
    try testing.expectEqual(@as(usize, "one, two café".len), ed.cursor);
}
