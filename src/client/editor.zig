//! Multi-line input editor for the TUI prompt (M3 REPL upgrades).
//!
//! Replaces vaxis.widgets.TextInput (single-line gap buffer) with a plain
//! contiguous buffer + byte cursor. Design:
//!
//! - Logical text may contain '\n' (Alt+Enter / Ctrl+J inserts one).
//! - Display soft-wraps at the given width; the box grows 1..max_rows rows.
//! - Large text pastes become "[paste #N: X lines]" chips whose raw bytes are
//!   expanded on submit. Staged images appear as "[image #N]" placeholders;
//!   intact placeholders are display-only and stripped from submitted text.
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
history_bytes: usize = 0,
/// Non-null while walking history: index into `history`.
hist_idx: ?usize = null,
/// Draft saved when history walking began.
draft: ?[]u8 = null,
/// Column the cursor "wants" during vertical movement.
goal_col: ?usize = null,
/// Undo/redo snapshots (vim `u` / Ctrl+R). Insert-mode typing is grouped:
/// the TUI snapshots once at each normal→insert transition and before every
/// normal-mode mutation.
undo_stack: std.ArrayList(UndoState) = .empty,
redo_stack: std.ArrayList(UndoState) = .empty,

const UndoState = struct { text: []u8, cursor: usize };
const max_undo_states = 100;
pub const max_history_entries: usize = 256;
pub const max_history_bytes: usize = 2 * 1024 * 1024;
pub const max_history_entry_bytes: usize = 256 * 1024;

pub fn init(gpa: std.mem.Allocator) Editor {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Editor) void {
    for (self.undo_stack.items) |st| self.gpa.free(st.text);
    self.undo_stack.deinit(self.gpa);
    for (self.redo_stack.items) |st| self.gpa.free(st.text);
    self.redo_stack.deinit(self.gpa);
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
/// user_msg blocks, so history persists across reboots). Exact duplicates
/// collapse to their newest occurrence, matching shell-history recall.
pub fn pushHistory(self: *Editor, entry: []const u8) void {
    if (entry.len == 0 or entry.len > max_history_entry_bytes) return;
    var i: usize = 0;
    while (i < self.history.items.len) {
        if (!std.mem.eql(u8, self.history.items[i], entry)) {
            i += 1;
            continue;
        }
        const duplicate = self.history.orderedRemove(i);
        self.history_bytes -= duplicate.len;
        self.gpa.free(duplicate);
        if (self.hist_idx) |idx| self.hist_idx = if (idx <= i) idx else idx - 1;
        break;
    }
    while (self.history.items.len >= max_history_entries or
        self.history_bytes > max_history_bytes - entry.len)
    {
        const oldest = self.history.orderedRemove(0);
        self.history_bytes -= oldest.len;
        self.gpa.free(oldest);
        if (self.hist_idx) |idx| self.hist_idx = if (idx == 0) null else idx - 1;
    }
    const owned = self.gpa.dupe(u8, entry) catch return;
    self.history_bytes += owned.len;
    self.history.append(self.gpa, owned) catch {
        self.history_bytes -= owned.len;
        self.gpa.free(owned);
    };
}

pub fn clearHistory(self: *Editor) void {
    for (self.history.items) |entry| self.gpa.free(entry);
    self.history.clearRetainingCapacity();
    self.history_bytes = 0;
    self.hist_idx = null;
    if (self.draft) |draft| self.gpa.free(draft);
    self.draft = null;
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

/// Replace the current draft with a selected history entry. Unlike walking
/// history with Up/Down, a picker selection is an explicit new draft.
pub fn replaceText(self: *Editor, s: []const u8) void {
    self.setText(s);
    self.hist_idx = null;
    if (self.draft) |draft| {
        self.gpa.free(draft);
        self.draft = null;
    }
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

pub fn insertImagePlaceholder(self: *Editor, index: usize) void {
    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "[image #{d}]", .{index}) catch return;
    if (self.cursor > 0 and !std.ascii.isWhitespace(self.text.items[self.cursor - 1])) self.insertSlice(" ");
    self.insertSlice(label);
    if (self.cursor == self.text.items.len or !std.ascii.isWhitespace(self.text.items[self.cursor])) self.insertSlice(" ");
}

/// Submit-time expansion replaces text-paste chips and removes image
/// placeholders backed by the staged attachment count. Caller owns the
/// returned slice. Resets the editor.
pub fn takeExpandedWithImages(self: *Editor, image_count: usize) ![]u8 {
    return self.takeExpandedImpl(image_count, false);
}

pub fn takeExpandedSensitive(self: *Editor) ![]u8 {
    return self.takeExpandedImpl(0, true);
}

fn takeExpandedImpl(self: *Editor, image_count: usize, sensitive: bool) ![]u8 {
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
        } else if (t[i] == '[' and std.mem.startsWith(u8, t[i..], "[image #")) {
            if (parseImageLabel(t[i..])) |image| {
                if (image.index >= 1 and image.index <= image_count) {
                    i += image.label_len;
                    if (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) {
                        while (i < t.len and std.ascii.isWhitespace(t[i])) : (i += 1) {}
                    }
                    continue;
                }
            }
        }
        try out.append(self.gpa, t[i]);
        i += 1;
    }
    if (sensitive)
        self.clearSensitive()
    else
        self.clear();
    return out.toOwnedSlice(self.gpa);
}

pub fn takeExpanded(self: *Editor) ![]u8 {
    return self.takeExpandedWithImages(0);
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

fn parseImageLabel(s: []const u8) ?ChipRef {
    const prefix = "[image #".len;
    var j: usize = prefix;
    var index: usize = 0;
    var digits: usize = 0;
    while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {
        index = index * 10 + (s[j] - '0');
        digits += 1;
    }
    if (digits == 0 or j >= s.len or s[j] != ']') return null;
    return .{ .index = index, .label_len = j + 1 };
}

pub fn clear(self: *Editor) void {
    self.clearImpl(false);
}

pub fn clearSensitive(self: *Editor) void {
    self.clearImpl(true);
}

fn clearImpl(self: *Editor, sensitive: bool) void {
    for (self.undo_stack.items) |st| {
        if (sensitive) @memset(st.text, 0);
        self.gpa.free(st.text);
    }
    self.undo_stack.clearRetainingCapacity();
    for (self.redo_stack.items) |st| {
        if (sensitive) @memset(st.text, 0);
        self.gpa.free(st.text);
    }
    self.redo_stack.clearRetainingCapacity();
    if (sensitive) {
        @memset(self.text.allocatedSlice(), 0);
        self.text.clearAndFree(self.gpa);
    } else {
        self.text.clearRetainingCapacity();
    }
    self.cursor = 0;
    self.goal_col = null;
    self.hist_idx = null;
    if (self.draft) |d| {
        if (sensitive) @memset(d, 0);
        self.gpa.free(d);
        self.draft = null;
    }
    for (self.pastes.items) |p| {
        if (sensitive) @memset(p, 0);
        self.gpa.free(p);
    }
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
            // Word-aware: when the overflow lands mid-word, break after the
            // row's last space so the whole word moves down; a word longer
            // than the row still hard-splits.
            var break_pos = i;
            var scan = i;
            while (scan > start) : (scan -= 1) {
                if (t[scan - 1] == ' ') {
                    break_pos = scan;
                    break;
                }
            }
            if (n < row_buf.len) row_buf[n] = .{ .start = start, .end = break_pos };
            n += 1;
            start = break_pos;
            col = 0;
            var carried = break_pos;
            while (carried < i) {
                const ce = nextCpEnd(t, carried);
                col += cpDisplayWidth(t[carried..ce]);
                carried = ce;
            }
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
    self.drawImpl(win, prompt, prompt_style, text_style, false);
}

pub fn drawMasked(
    self: *const Editor,
    win: vaxis.Window,
    prompt: []const u8,
    prompt_style: vaxis.Style,
    text_style: vaxis.Style,
) void {
    self.drawImpl(win, prompt, prompt_style, text_style, true);
}

fn drawImpl(
    self: *const Editor,
    win: vaxis.Window,
    prompt: []const u8,
    prompt_style: vaxis.Style,
    text_style: vaxis.Style,
    masked: bool,
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
            if (masked) {
                var col: usize = 0;
                var at: usize = 0;
                while (at < seg.len and col < body_w) {
                    const end = nextCpEnd(seg, at);
                    _ = child.printSegment(.{ .text = "•", .style = text_style }, .{
                        .col_offset = @intCast(col),
                        .wrap = .none,
                    });
                    col += cpDisplayWidth(seg[at..end]);
                    at = end;
                }
            } else {
                _ = child.printSegment(.{ .text = seg, .style = text_style }, .{ .wrap = .none });
            }
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

test "sensitive submit clears editor and paste storage" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var secret: [600]u8 = undefined;
    @memset(&secret, 's');
    ed.paste(&secret);
    try testing.expectEqual(@as(usize, 1), ed.pastes.items.len);
    const out = try ed.takeExpandedSensitive();
    defer {
        @memset(out, 0);
        testing.allocator.free(out);
    }
    try testing.expectEqualSlices(u8, &secret, out);
    try testing.expect(ed.isEmpty());
    try testing.expectEqual(@as(usize, 0), ed.text.capacity);
    try testing.expectEqual(@as(usize, 0), ed.pastes.items.len);
    try testing.expectEqual(@as(usize, 0), ed.undo_stack.items.len);
    try testing.expectEqual(@as(usize, 0), ed.redo_stack.items.len);
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

test "image placeholders are visible drafts and stripped on submit" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("compare");
    ed.insertImagePlaceholder(1);
    ed.insertImagePlaceholder(2);
    ed.insertSlice("these");
    try testing.expectEqualStrings("compare [image #1] [image #2] these", ed.text.items);

    const out = try ed.takeExpandedWithImages(2);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("compare these", out);
}

test "image placeholder without a staged attachment remains literal" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("look [image #2]");
    const out = try ed.takeExpandedWithImages(1);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("look [image #2]", out);
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

test "history dedupes to the newest occurrence" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.pushHistory("same");
    ed.pushHistory("different");
    ed.pushHistory("same");
    try testing.expectEqual(@as(usize, 2), ed.history.items.len);
    try testing.expectEqualStrings("different", ed.history.items[0]);
    try testing.expectEqualStrings("same", ed.history.items[1]);
}

test "history evicts old entries and refuses megabyte submissions" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var buf: [32]u8 = undefined;
    for (0..max_history_entries + 10) |i| {
        const entry = try std.fmt.bufPrint(&buf, "entry-{d}", .{i});
        ed.pushHistory(entry);
    }
    try testing.expectEqual(max_history_entries, ed.history.items.len);
    try testing.expectEqualStrings("entry-10", ed.history.items[0]);

    const huge = try testing.allocator.alloc(u8, max_history_entry_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    ed.pushHistory(huge);
    try testing.expectEqual(max_history_entries, ed.history.items.len);
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

test "soft wrap moves whole words to the next row" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("hello marlin"); // width 10: "marlin" must not split
    const rows = ed.layoutRows(10);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("hello ", ed.text.items[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("marlin", ed.text.items[rows[1].start..rows[1].end]);

    // A word longer than the row still hard-splits rather than looping.
    var long = Editor.init(testing.allocator);
    defer long.deinit();
    long.insertSlice("abcdefghijklmnop");
    try testing.expectEqual(@as(usize, 2), long.layoutRows(10).len);
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

// ------------------------------------------------- vim operator ranges --

/// Half-open byte range in `text`, produced by the motion/text-object
/// helpers below and consumed by the composer's d/c/y operators.
pub const Range = struct { start: usize, end: usize };

/// Delete [start, end) and leave the cursor at the excision point.
pub fn deleteRange(self: *Editor, start: usize, end: usize) void {
    const t = self.text.items;
    const lo = @min(start, t.len);
    const hi = @min(@max(end, lo), t.len);
    if (hi == lo) return;
    self.text.replaceRange(self.gpa, lo, hi - lo, "") catch return;
    self.cursor = lo;
    self.goal_col = null;
}

/// vim `w` as an operator target: from the cursor to the start of the next
/// word (dw eats the word under the cursor plus trailing separators).
pub fn wordForwardRange(self: *const Editor) Range {
    const t = self.text.items;
    var i = self.cursor;
    if (i >= t.len) return .{ .start = i, .end = i };
    if (isWordCodepoint(t[i..nextCpEnd(t, i)])) {
        while (i < t.len and isWordCodepoint(t[i..nextCpEnd(t, i)])) i = nextCpEnd(t, i);
    } else {
        while (i < t.len and t[i] != ' ' and t[i] != '\n' and !isWordCodepoint(t[i..nextCpEnd(t, i)])) i = nextCpEnd(t, i);
    }
    while (i < t.len and t[i] == ' ') i += 1;
    return .{ .start = self.cursor, .end = i };
}

/// vim `b` as an operator target: from the previous word start to the cursor.
pub fn wordBackRange(self: *const Editor) Range {
    const t = self.text.items;
    var i = self.cursor;
    while (i > 0 and (t[i - 1] == ' ' or t[i - 1] == '\n')) i -= 1;
    while (i > 0) {
        const start = prevCpStart(t, i);
        if (!isWordCodepoint(t[start..i])) break;
        i = start;
    }
    return .{ .start = i, .end = self.cursor };
}

/// The logical line under the cursor. `with_newline` includes the trailing
/// '\n' (dd); cc keeps it so the line survives as an empty shell.
pub fn lineRangeAt(self: *const Editor, with_newline: bool) Range {
    const t = self.text.items;
    const start = lineStart(t, self.cursor);
    var end = if (std.mem.indexOfScalarPos(u8, t, @min(self.cursor, t.len), '\n')) |nl| nl else t.len;
    if (with_newline and end < t.len) end += 1;
    return .{ .start = start, .end = end };
}

pub fn toLineEndRange(self: *const Editor) Range {
    const t = self.text.items;
    const end = if (std.mem.indexOfScalarPos(u8, t, @min(self.cursor, t.len), '\n')) |nl| nl else t.len;
    return .{ .start = self.cursor, .end = end };
}

pub fn toLineStartRange(self: *const Editor) Range {
    return .{ .start = lineStart(self.text.items, self.cursor), .end = self.cursor };
}

/// iw / aw: the word under the cursor; `around` extends over trailing
/// spaces (or leading when there are none trailing), vim-style.
pub fn innerWordRange(self: *const Editor, around: bool) ?Range {
    const t = self.text.items;
    if (t.len == 0) return null;
    var lo = @min(self.cursor, t.len - 1);
    if (!isWordCodepoint(t[lo..nextCpEnd(t, lo)])) {
        // On a separator, the object is the separator run.
        var hi = lo;
        while (hi < t.len and !isWordCodepoint(t[hi..nextCpEnd(t, hi)]) and t[hi] != '\n') hi = nextCpEnd(t, hi);
        while (lo > 0) {
            const p = prevCpStart(t, lo);
            if (isWordCodepoint(t[p..lo]) or t[p] == '\n') break;
            lo = p;
        }
        return .{ .start = lo, .end = hi };
    }
    while (lo > 0) {
        const p = prevCpStart(t, lo);
        if (!isWordCodepoint(t[p..lo])) break;
        lo = p;
    }
    var hi = self.cursor;
    while (hi < t.len and isWordCodepoint(t[hi..nextCpEnd(t, hi)])) hi = nextCpEnd(t, hi);
    if (around) {
        var padded = hi;
        while (padded < t.len and t[padded] == ' ') padded += 1;
        if (padded > hi) {
            hi = padded;
        } else {
            while (lo > 0 and t[lo - 1] == ' ') lo -= 1;
        }
    }
    return .{ .start = lo, .end = hi };
}

/// i"/a" (and friends): the quoted span on the cursor's line — the pair
/// enclosing the cursor, or the first pair after it.
pub fn quoteRange(self: *const Editor, quote: u8, around: bool) ?Range {
    const t = self.text.items;
    const line = self.lineRangeAt(false);
    var positions_buf: [128]usize = undefined;
    var n: usize = 0;
    var i = line.start;
    while (i < line.end and n < positions_buf.len) : (i += 1) {
        if (t[i] == quote) {
            positions_buf[n] = i;
            n += 1;
        }
    }
    if (n < 2) return null;
    var pair: usize = 0;
    while (pair + 1 < n) : (pair += 2) {
        const open = positions_buf[pair];
        const close = positions_buf[pair + 1];
        if (self.cursor <= close or pair + 3 >= n + 1 and pair + 2 >= n) {
            if (self.cursor <= close) {
                return if (around)
                    .{ .start = open, .end = close + 1 }
                else
                    .{ .start = open + 1, .end = close };
            }
        }
    }
    return null;
}

/// i(/a( and bracket friends: nearest enclosing pair with nesting, across
/// the whole (possibly multi-line) draft.
pub fn delimRange(self: *const Editor, open: u8, close: u8, around: bool) ?Range {
    const t = self.text.items;
    if (t.len == 0) return null;
    const at = @min(self.cursor, t.len - 1);
    var open_idx: ?usize = if (t[at] == open) at else null;
    if (open_idx == null) {
        var depth: usize = 0;
        var i = at;
        while (i > 0) {
            i -= 1;
            if (t[i] == close) {
                depth += 1;
            } else if (t[i] == open) {
                if (depth == 0) {
                    open_idx = i;
                    break;
                }
                depth -= 1;
            }
        }
    }
    const o = open_idx orelse return null;
    var depth: usize = 0;
    var j = o + 1;
    while (j < t.len) : (j += 1) {
        if (t[j] == open) {
            depth += 1;
        } else if (t[j] == close) {
            if (depth == 0) {
                return if (around)
                    .{ .start = o, .end = j + 1 }
                else
                    .{ .start = o + 1, .end = j };
            }
            depth -= 1;
        }
    }
    return null;
}

test "operator ranges: words, lines, quotes, brackets" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("zig build test");
    ed.cursor = 0;
    var r = ed.wordForwardRange();
    try testing.expectEqualStrings("zig ", ed.text.items[r.start..r.end]);
    ed.cursor = 9; // inside "build"? no: "zig build test": 9 = ' ' after build
    ed.cursor = 5; // inside "build"
    r = ed.innerWordRange(false).?;
    try testing.expectEqualStrings("build", ed.text.items[r.start..r.end]);
    r = ed.innerWordRange(true).?;
    try testing.expectEqualStrings("build ", ed.text.items[r.start..r.end]);
    r = ed.wordBackRange();
    try testing.expectEqualStrings("b", ed.text.items[r.start..r.end]);

    ed.clear();
    ed.insertSlice("say \"hello there\" now");
    ed.cursor = 8; // inside the quotes
    r = ed.quoteRange('"', false).?;
    try testing.expectEqualStrings("hello there", ed.text.items[r.start..r.end]);
    r = ed.quoteRange('"', true).?;
    try testing.expectEqualStrings("\"hello there\"", ed.text.items[r.start..r.end]);

    ed.clear();
    ed.insertSlice("f(a, g(b), c)");
    ed.cursor = 7; // inside g(...)
    r = ed.delimRange('(', ')', false).?;
    try testing.expectEqualStrings("b", ed.text.items[r.start..r.end]);
    ed.cursor = 3; // inside f's parens
    r = ed.delimRange('(', ')', false).?;
    try testing.expectEqualStrings("a, g(b), c", ed.text.items[r.start..r.end]);

    ed.clear();
    ed.insertSlice("one\ntwo\nthree");
    ed.cursor = 5; // on "two"
    r = ed.lineRangeAt(true);
    try testing.expectEqualStrings("two\n", ed.text.items[r.start..r.end]);
    ed.deleteRange(r.start, r.end);
    try testing.expectEqualStrings("one\nthree", ed.text.items);
    try testing.expectEqual(@as(usize, 4), ed.cursor);
}

// -------------------------------------------------------------- undo/redo --

/// Snapshot the current state as an undo point. Call BEFORE a mutation.
pub fn pushUndo(self: *Editor) void {
    if (self.undo_stack.items.len > 0) {
        const top = self.undo_stack.items[self.undo_stack.items.len - 1];
        if (std.mem.eql(u8, top.text, self.text.items)) return; // no-op edit
    }
    const snap = self.gpa.dupe(u8, self.text.items) catch return;
    self.undo_stack.append(self.gpa, .{ .text = snap, .cursor = self.cursor }) catch {
        self.gpa.free(snap);
        return;
    };
    if (self.undo_stack.items.len > max_undo_states) {
        const oldest = self.undo_stack.orderedRemove(0);
        self.gpa.free(oldest.text);
    }
    for (self.redo_stack.items) |st| self.gpa.free(st.text);
    self.redo_stack.clearRetainingCapacity();
}

fn restoreState(self: *Editor, st: UndoState) void {
    self.text.clearRetainingCapacity();
    self.text.appendSlice(self.gpa, st.text) catch {};
    self.cursor = @min(st.cursor, self.text.items.len);
    self.goal_col = null;
}

pub fn undo(self: *Editor) bool {
    const st = self.undo_stack.pop() orelse return false;
    const current = self.gpa.dupe(u8, self.text.items) catch {
        self.gpa.free(st.text);
        return false;
    };
    self.redo_stack.append(self.gpa, .{ .text = current, .cursor = self.cursor }) catch self.gpa.free(current);
    self.restoreState(st);
    self.gpa.free(st.text);
    return true;
}

pub fn redo(self: *Editor) bool {
    const st = self.redo_stack.pop() orelse return false;
    const current = self.gpa.dupe(u8, self.text.items) catch {
        self.gpa.free(st.text);
        return false;
    };
    self.undo_stack.append(self.gpa, .{ .text = current, .cursor = self.cursor }) catch self.gpa.free(current);
    self.restoreState(st);
    self.gpa.free(st.text);
    return true;
}

// ------------------------------------------------------- vim-mode helpers --

/// vim `w`: cursor to the start of the NEXT word (moveWordRight is `e`).
pub fn moveWordStart(self: *Editor) void {
    self.cursor = self.wordForwardRange().end;
    self.goal_col = null;
}

/// vim `e` as an operator target: cursor through the end of the word.
pub fn wordEndRange(self: *const Editor) Range {
    return .{ .start = self.cursor, .end = wordEndAfter(self.text.items, self.cursor) };
}

/// `count` logical lines starting at the cursor's line (for 2dd/3yy).
pub fn linesRange(self: *const Editor, count: usize, with_newline: bool) Range {
    const t = self.text.items;
    const start = lineStart(t, self.cursor);
    var end = start;
    var remaining = @max(count, 1);
    while (remaining > 0) : (remaining -= 1) {
        end = if (std.mem.indexOfScalarPos(u8, t, end, '\n')) |nl| nl + 1 else t.len;
        if (end == t.len) break;
    }
    if (!with_newline and end > start and end <= t.len and end > 0 and t[end - 1] == '\n') end -= 1;
    return .{ .start = start, .end = end };
}

/// vim `r`: replace the codepoint under the cursor, cursor stays on it.
pub fn replaceUnderCursor(self: *Editor, replacement: []const u8) void {
    const t = self.text.items;
    if (self.cursor >= t.len or replacement.len == 0) return;
    const end = nextCpEnd(t, self.cursor);
    self.text.replaceRange(self.gpa, self.cursor, end - self.cursor, replacement) catch return;
    self.goal_col = null;
}

/// vim `~`: toggle ASCII case under the cursor and advance.
pub fn toggleCaseUnderCursor(self: *Editor) void {
    const t = self.text.items;
    if (self.cursor >= t.len) return;
    const ch = t[self.cursor];
    if (std.ascii.isLower(ch)) {
        self.text.items[self.cursor] = std.ascii.toUpper(ch);
    } else if (std.ascii.isUpper(ch)) {
        self.text.items[self.cursor] = std.ascii.toLower(ch);
    }
    self.cursor = nextCpEnd(t, self.cursor);
    self.goal_col = null;
}

/// vim `o`/`O`: open a new line below/above and place the cursor on it.
pub fn openLine(self: *Editor, below: bool) void {
    const line = self.lineRangeAt(false);
    if (below) {
        self.text.insertSlice(self.gpa, line.end, "\n") catch return;
        self.cursor = line.end + 1;
    } else {
        self.text.insertSlice(self.gpa, line.start, "\n") catch return;
        self.cursor = line.start;
    }
    self.goal_col = null;
}

/// vim J: join the next line onto this one — the newline (plus the next
/// line's leading whitespace) collapses to a single space, or to nothing
/// when either side is empty.
pub fn joinLines(self: *Editor) bool {
    const t = self.text.items;
    const line = self.lineRangeAt(false);
    if (line.end >= t.len) return false; // no next line
    var cut_end = line.end + 1;
    while (cut_end < t.len and (t[cut_end] == ' ' or t[cut_end] == '\t')) cut_end += 1;
    const left_empty = line.end == line.start;
    const right_empty = cut_end >= t.len or t[cut_end] == '\n';
    const glue: []const u8 = if (left_empty or right_empty) "" else " ";
    self.text.replaceRange(self.gpa, line.end, cut_end - line.end, glue) catch return false;
    self.cursor = line.end;
    self.goal_col = null;
    return true;
}

/// Find a character on the cursor's line (vim f/t/F/T). Returns the byte
/// index of the target character, honoring `count` occurrences.
pub fn findOnLine(self: *const Editor, ch: u8, forward: bool, count: usize) ?usize {
    const t = self.text.items;
    const line = self.lineRangeAt(false);
    var remaining = @max(count, 1);
    if (forward) {
        var i = @min(self.cursor + 1, line.end);
        while (i < line.end) : (i += 1) {
            if (t[i] == ch) {
                remaining -= 1;
                if (remaining == 0) return i;
            }
        }
    } else {
        var i = self.cursor;
        while (i > line.start) {
            i -= 1;
            if (t[i] == ch) {
                remaining -= 1;
                if (remaining == 0) return i;
            }
        }
    }
    return null;
}

test "undo groups and redo round trip" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("hello");
    ed.pushUndo();
    ed.insertSlice(" world");
    try testing.expect(ed.undo());
    try testing.expectEqualStrings("hello", ed.text.items);
    try testing.expect(ed.redo());
    try testing.expectEqualStrings("hello world", ed.text.items);
    try testing.expect(ed.redo() == false);
}

test "vim helpers: word start, lines range, find, replace, open" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("zig build test");
    ed.cursor = 0;
    ed.moveWordStart();
    try testing.expectEqual(@as(usize, 4), ed.cursor); // start of "build"

    try testing.expectEqual(@as(?usize, 10), ed.findOnLine('t', true, 1));
    try testing.expectEqual(@as(?usize, 13), ed.findOnLine('t', true, 2));
    try testing.expectEqual(@as(?usize, null), ed.findOnLine('z', true, 1));

    ed.cursor = 4;
    ed.replaceUnderCursor("B");
    try testing.expectEqualStrings("zig Build test", ed.text.items);
    ed.toggleCaseUnderCursor();
    try testing.expectEqualStrings("zig build test", ed.text.items);

    ed.clear();
    ed.insertSlice("one\ntwo\nthree");
    ed.cursor = 5;
    const two = ed.linesRange(2, true);
    try testing.expectEqualStrings("two\nthree", ed.text.items[two.start..two.end]);
    ed.openLine(true);
    try testing.expectEqualStrings("one\ntwo\n\nthree", ed.text.items);
    try testing.expectEqual(@as(usize, 8), ed.cursor);
}
