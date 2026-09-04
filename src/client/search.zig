//! Search for the TUI: readline-style reverse history search over authored
//! prompts (Ctrl+R) and durable transcript search across sessions
//! (`/search`), including the jump that refocuses a session around a hit.
//! Split out of tui.zig; everything here operates on a `*tui.App` and the
//! methods are re-exposed there.

const std = @import("std");
const proto = @import("../core/proto.zig");
const session_handle = @import("../core/session_handle.zig");
const tui = @import("tui.zig");
const App = tui.App;
const PickerKind = tui.PickerKind;
const initial_replay_blocks = tui.initial_replay_blocks;
const deinitPlan = tui.deinitPlan;
const Editor = @import("editor.zig");

pub const SearchHitOwned = struct {
    sid: u64,
    seq: u64,
    label: []u8,

    fn deinit(self: *SearchHitOwned, gpa: std.mem.Allocator) void {
        gpa.free(self.label);
    }
};

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Small, allocation-free fuzzy matcher for authored-input recall. FTS is
/// intentionally not involved: Ctrl+R should match sparse subsequences and
/// reward word starts/contiguous runs like a shell-history picker.
pub fn fuzzyHistoryScore(candidate: []const u8, query: []const u8) ?i64 {
    if (query.len == 0) return 0;
    var at: usize = 0;
    var previous: ?usize = null;
    var score: i64 = 0;
    for (query) |query_byte| {
        const q = std.ascii.toLower(query_byte);
        var found: ?usize = null;
        while (at < candidate.len) : (at += 1) {
            if (std.ascii.toLower(candidate[at]) == q) {
                found = at;
                break;
            }
        }
        const index = found orelse return null;
        score += 10;
        if (previous) |prev| {
            if (index == prev + 1) score += 12;
        }
        if (index == 0 or std.ascii.isWhitespace(candidate[index - 1]) or
            std.mem.indexOfScalar(u8, "/_-.:", candidate[index - 1]) != null)
            score += 8;
        score -= @intCast(@min(index, 100));
        previous = index;
        at = index + 1;
    }
    score -= @intCast(@min(candidate.len / 16, 100));
    return score;
}

pub fn clearTranscriptForSearch(self: *App) void {
    self.clearHistoryBackfill();
    for (self.view.blocks.items) |*rendered| rendered.deinit(self.gpa);
    self.view.blocks.clearRetainingCapacity();
    self.view.delta.clearRetainingCapacity();
    self.view.reasoning_delta.clearRetainingCapacity();
    deinitPlan(self.gpa, &self.view.plan);
    self.view.layout_cache.reset(self.gpa);
    self.view.tail_layout_cache.reset(self.gpa);
    self.view.stream_layout_cache.reset(self.gpa);
    self.view.layout_epoch +%= 1;
    self.view.last_seq = 0;
    self.view.oldest_seq = 0;
    self.view.history_complete = false;
    self.view.history_loading = true;
    self.view.history_before_seq = 0;
    self.view.history_page_failed = false;
    self.view.scroll_up = 0;
    self.view.last_total_lines = 0;
    self.view.last_first_visible = 0;
    self.search.highlight_line = null;
    self.copy_cursor = null;
    self.view.sel_anchor = null;
}

pub fn jumpToSearchHit(self: *App, sid: u64, seq: u64) !void {
    if (sid == self.view.sid) {
        for (self.view.blocks.items) |rendered| {
            if (rendered.seq != seq) continue;
            self.search.target_seq = seq;
            self.search.highlight_line = null;
            var handle_buf: session_handle.Full = undefined;
            self.setNotice("match → {s}:{d}", .{ self.displaySessionHandle(&handle_buf, sid), seq });
            return;
        }
    }
    if (sid != self.view.sid) {
        try self.focusSession(sid, true);
    } else {
        self.conn.send(.{ .unsub = .{ .sid = sid } }) catch {};
    }

    self.clearTranscriptForSearch();
    self.search.target_seq = seq;
    try self.conn.send(.{ .sub = .{
        .sid = sid,
        .tail_limit = initial_replay_blocks,
        .around_seq = seq,
    } });
    self.rememberSession(sid);
    var handle_buf: session_handle.Full = undefined;
    self.setNotice("match → {s}:{d}", .{ self.displaySessionHandle(&handle_buf, sid), seq });
}

pub fn beginHistorySearch(self: *App) void {
    if (self.history_search.active) {
        self.cycleHistorySearch();
        return;
    }
    self.history_search.draft.clearRetainingCapacity();
    self.history_search.draft.appendSlice(self.gpa, self.view.editor.text.items) catch return;
    self.history_search.draft_cursor = self.view.editor.cursor;
    self.history_search.query.clearRetainingCapacity();
    self.history_search.match = null;
    self.history_search.active = true;
    self.refreshHistorySearch(true);
    self.conn.send(.{ .input_history = .{
        .sid = self.view.sid,
        .limit = Editor.max_history_entries,
    } }) catch {
        // The already-seeded current-session history remains useful when
        // a reconnect races the shortcut.
        self.setNotice("global input history unavailable", .{});
    };
}

pub fn refreshHistorySearch(self: *App, from_newest: bool) void {
    if (!self.history_search.active) return;
    const previous = self.history_search.match;
    var index = if (from_newest)
        self.view.editor.history.items.len
    else
        (self.history_search.match orelse self.view.editor.history.items.len);
    while (index > 0) {
        index -= 1;
        const candidate = self.view.editor.history.items[index];
        if (fuzzyHistoryScore(candidate, self.history_search.query.items) == null) continue;
        self.history_search.match = index;
        self.view.editor.replaceText(candidate);
        return;
    }
    if (!from_newest and previous != null) return;
    self.history_search.match = null;
    self.view.editor.replaceText(self.history_search.draft.items);
    self.view.editor.cursor = @min(self.history_search.draft_cursor, self.view.editor.text.items.len);
}

pub fn cycleHistorySearch(self: *App) void {
    self.refreshHistorySearch(false);
}

pub fn cancelHistorySearch(self: *App) void {
    if (!self.history_search.active) return;
    self.view.editor.replaceText(self.history_search.draft.items);
    self.view.editor.cursor = @min(self.history_search.draft_cursor, self.view.editor.text.items.len);
    self.finishHistorySearch();
}

pub fn acceptHistorySearch(self: *App) void {
    if (!self.history_search.active) return;
    self.finishHistorySearch();
}

pub fn finishHistorySearch(self: *App) void {
    self.history_search.active = false;
    self.history_search.query.clearRetainingCapacity();
    self.history_search.draft.clearRetainingCapacity();
    self.history_search.match = null;
}

pub fn clearSearchHits(self: *App) void {
    for (self.search.hits.items) |*hit| hit.deinit(self.gpa);
    self.search.hits.clearRetainingCapacity();
    self.search.labels.clearRetainingCapacity();
    self.search.cursor = 0;
}

pub fn openSearchPrompt(self: *App, session_id: u64) void {
    self.clearSearchHits();
    self.search.scope_sid = session_id;
    self.search.pending = false;
    self.openPicker(.search_prompt);
}

pub fn submitSearch(self: *App) void {
    const query = std.mem.trim(u8, self.picker_filter.items, " \t\r\n");
    if (query.len == 0 or self.search.pending) return;
    self.search.pending = true;
    self.conn.send(.{ .search = .{
        .query = query,
        .sid = self.search.scope_sid,
        .limit = 100,
    } }) catch {
        self.search.pending = false;
        self.setNotice("could not search transcript", .{});
    };
}

pub fn replaceSearchHits(self: *App, result: @FieldType(proto.DaemonMsg, "search_result")) void {
    if (!self.search.pending or result.sid != self.search.scope_sid) return;
    self.search.pending = false;
    self.clearSearchHits();
    for (result.hits) |hit| {
        self.rememberSession(hit.sid);
        var handle_buf: session_handle.Full = undefined;
        const location = if (hit.title.len > 0) hit.title else hit.cwd;
        const label = std.fmt.allocPrint(self.gpa, "{s}:{d} · {s} · {s} · {s}", .{
            self.displaySessionHandle(&handle_buf, hit.sid),
            hit.seq,
            location,
            @tagName(hit.kind),
            hit.snippet,
        }) catch continue;
        self.search.hits.append(self.gpa, .{
            .sid = hit.sid,
            .seq = hit.seq,
            .label = label,
        }) catch {
            self.gpa.free(label);
            continue;
        };
        self.search.labels.append(self.gpa, label) catch {
            var removed = self.search.hits.pop().?;
            removed.deinit(self.gpa);
        };
    }
    if (self.search.hits.items.len == 0) {
        self.picker = null;
        self.picker_filter.clearRetainingCapacity();
        self.setNotice("no transcript matches", .{});
        return;
    }
    self.picker_kind = .search;
    self.picker = 0;
    self.picker_filter.clearRetainingCapacity();
}

pub fn selectSearchHit(self: *App, label: []const u8) ?SearchHitOwned {
    for (self.search.hits.items, 0..) |hit, index| {
        if (!std.mem.eql(u8, hit.label, label)) continue;
        self.search.cursor = index;
        return hit;
    }
    return null;
}

pub fn nextSearchHit(self: *App, direction: i8) void {
    const len = self.search.hits.items.len;
    if (len == 0) {
        self.setNotice("no active search · press /", .{});
        return;
    }
    self.search.cursor = if (direction < 0)
        (self.search.cursor + len - 1) % len
    else
        (self.search.cursor + 1) % len;
    const hit = self.search.hits.items[self.search.cursor];
    self.jumpToSearchHit(hit.sid, hit.seq) catch self.setNotice("could not open search match", .{});
}
