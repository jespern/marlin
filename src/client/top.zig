//! Live top(1)-style session catalog, shared with the attached TUI overlay.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

const proto = @import("../core/proto.zig");
const session_handle = @import("../core/session_handle.zig");
const attach = @import("attach.zig");
const render = @import("render.zig");

const Palette = render.Palette;

pub const AttachPick = struct {
    sid: ?u64 = null,
};

pub const RowView = struct {
    sid: u64,
    parent_sid: ?u64,
    kind: proto.SessionKind,
    state: proto.SessionState,
    created_at: i64,
    archived: bool = false,
    depth: usize = 0,
    title: []const u8,
    cwd: []const u8,
    model: []const u8,
};

pub const Columns = struct {
    handle: usize = 8,
    state: usize = 9,
    age: usize = 4,
    model: usize = 0,
    cwd: usize = 0,
    title: usize = 1,
};

pub fn computeColumns(width: usize) Columns {
    const fixed: usize = 8 + 2 + 9 + 2 + 4 + 2;
    if (width <= fixed) return .{ .title = 1 };
    var remaining = width - fixed;
    var result = Columns{};
    if (width >= 52) {
        result.model = @min(@as(usize, 14), remaining / 3);
        remaining -|= result.model + 2;
    }
    if (width >= 76) {
        result.cwd = @min(@as(usize, 24), remaining / 2);
        remaining -|= result.cwd + 2;
    }
    result.title = @max(remaining, 1);
    return result;
}

pub fn stateLabel(state: proto.SessionState) []const u8 {
    return switch (state) {
        .idle => "idle",
        .running => "running",
        .awaiting_approval => "approval",
        .err => "error",
        .done => "done",
    };
}

pub fn stateStyle(state: proto.SessionState, selected: bool, archived: bool) vaxis.Style {
    var style: vaxis.Style = switch (state) {
        .idle => .{ .fg = .{ .index = 2 } },
        .running => .{ .fg = Palette.soft_blue, .bold = true },
        .awaiting_approval => .{ .fg = .{ .index = 3 }, .bold = true },
        .err => .{ .fg = .{ .index = 1 }, .bold = true },
        .done => .{ .fg = .{ .index = 8 }, .dim = true },
    };
    if (selected) style.bg = Palette.prompt_bg;
    if (archived) style.dim = true;
    return style;
}

pub fn rowStyle(selected: bool, archived: bool) vaxis.Style {
    var style: vaxis.Style = .{};
    if (selected) style.bg = Palette.prompt_bg;
    if (archived) {
        style.fg = .{ .index = 8 };
        style.dim = true;
    }
    return style;
}

pub fn formatAge(buf: []u8, created_at_ms: i64, now_ms: i64) []const u8 {
    if (created_at_ms <= 0) return "-";
    const seconds: u64 = @intCast(@max(@divTrunc(now_ms - created_at_ms, 1000), 0));
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
    const minutes = seconds / 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "?";
    const hours = minutes / 60;
    if (hours < 48) return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "?";
    return std.fmt.bufPrint(buf, "{d}d", .{hours / 24}) catch "?";
}

pub fn modelName(model: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, model, '/') orelse return model;
    return model[slash + 1 ..];
}

pub fn truncateRight(text: []const u8, width: usize) []const u8 {
    if (render.displayWidth(text) <= width) return text;
    if (width == 0) return "";
    if (width == 1) return "…";
    return text[0..render.hardCellBreak(text, 0, width - 1)];
}

pub fn truncateLeft(arena: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
    if (render.displayWidth(text) <= width) return text;
    if (width == 0) return "";
    if (width == 1) return "…";
    var start = text.len;
    var cells: usize = 0;
    while (start > 0 and cells < width - 1) {
        const prev = render.utf8Floor(text, start - 1);
        const cp = text[prev..start];
        const cp_width = render.displayWidth(cp);
        if (cells + cp_width > width - 1) break;
        cells += cp_width;
        start = prev;
    }
    return std.fmt.allocPrint(arena, "…{s}", .{text[start..]});
}

fn padded(arena: std.mem.Allocator, text: []const u8, width: usize, right: bool) ![]const u8 {
    const cells = render.displayWidth(text);
    const pad = width -| cells;
    const blank = try render.spaces(arena, pad);
    return if (right)
        std.fmt.allocPrint(arena, "{s}{s}", .{ blank, text })
    else
        std.fmt.allocPrint(arena, "{s}{s}", .{ text, blank });
}

fn rowLessThan(rows: []const RowView, a: usize, b: usize) bool {
    return rows[a].created_at < rows[b].created_at or
        (rows[a].created_at == rows[b].created_at and rows[a].sid < rows[b].sid);
}

fn appendTreeOrder(
    arena: std.mem.Allocator,
    rows: []const RowView,
    parent_sid: u64,
    emitted: []bool,
    out: *std.ArrayList(usize),
) !void {
    var children: std.ArrayList(usize) = .empty;
    defer children.deinit(arena);
    for (rows, 0..) |row, i| {
        if (!emitted[i] and row.parent_sid == parent_sid) try children.append(arena, i);
    }
    std.mem.sort(usize, children.items, rows, rowLessThan);
    for (children.items) |i| {
        if (emitted[i]) continue;
        emitted[i] = true;
        try out.append(arena, i);
        try appendTreeOrder(arena, rows, rows[i].sid, emitted, out);
    }
}

pub fn orderedIndices(arena: std.mem.Allocator, rows: []const RowView) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    var emitted = try arena.alloc(bool, rows.len);
    @memset(emitted, false);

    var roots: std.ArrayList(usize) = .empty;
    defer roots.deinit(arena);
    for (rows, 0..) |row, i| {
        var parent_present = row.parent_sid == null;
        if (row.parent_sid) |parent_sid| {
            for (rows) |candidate| {
                if (candidate.sid == parent_sid) {
                    parent_present = true;
                    break;
                }
            }
        }
        if (row.parent_sid == null or !parent_present) try roots.append(arena, i);
    }
    std.mem.sort(usize, roots.items, rows, rowLessThan);
    for (roots.items) |i| {
        if (emitted[i]) continue;
        emitted[i] = true;
        try out.append(arena, i);
        try appendTreeOrder(arena, rows, rows[i].sid, emitted, &out);
    }

    var remaining: std.ArrayList(usize) = .empty;
    defer remaining.deinit(arena);
    for (rows, 0..) |_, i| if (!emitted[i]) try remaining.append(arena, i);
    std.mem.sort(usize, remaining.items, rows, rowLessThan);
    for (remaining.items) |i| try out.append(arena, i);
    return out.toOwnedSlice(arena);
}

pub fn orderedRows(arena: std.mem.Allocator, rows: []const RowView) ![]const RowView {
    const order = try orderedIndices(arena, rows);
    const result = try arena.alloc(RowView, rows.len);
    for (order, 0..) |source, i| result[i] = rows[source];
    return result;
}

pub fn rowSegments(
    arena: std.mem.Allocator,
    row: RowView,
    known_ids: []const u64,
    columns: Columns,
    now_ms: i64,
    selected: bool,
) ![]const vaxis.Segment {
    var handle_buf: session_handle.Full = undefined;
    const handle = session_handle.display(&handle_buf, row.sid, known_ids);
    var age_buf: [32]u8 = undefined;
    const age = formatAge(&age_buf, row.created_at, now_ms);
    const base = rowStyle(selected, row.archived);
    const state_style = stateStyle(row.state, selected, row.archived);
    const title = if (row.title.len > 0) row.title else "(untitled)";
    const indent = try render.spaces(arena, row.depth * 2);
    const title_prefix = if (row.parent_sid != null)
        try std.fmt.allocPrint(arena, "{s}↳ ", .{indent})
    else
        "";
    const title_room = columns.title -| render.displayWidth(title_prefix);
    const short_title = truncateRight(title, title_room);

    var out = try arena.alloc(vaxis.Segment, 11);
    var n: usize = 0;
    out[n] = .{ .text = try padded(arena, truncateRight(handle, columns.handle), columns.handle, false), .style = base };
    n += 1;
    out[n] = .{ .text = "  ", .style = base };
    n += 1;
    out[n] = .{ .text = try padded(arena, stateLabel(row.state), columns.state, false), .style = state_style };
    n += 1;
    out[n] = .{ .text = "  ", .style = base };
    n += 1;
    out[n] = .{ .text = try padded(arena, age, columns.age, true), .style = base };
    n += 1;
    if (columns.model > 0) {
        out[n] = .{ .text = "  ", .style = base };
        n += 1;
        out[n] = .{ .text = try padded(arena, truncateRight(modelName(row.model), columns.model), columns.model, false), .style = base };
        n += 1;
    }
    if (columns.cwd > 0) {
        out[n] = .{ .text = "  ", .style = base };
        n += 1;
        out[n] = .{ .text = try padded(arena, try truncateLeft(arena, row.cwd, columns.cwd), columns.cwd, false), .style = base };
        n += 1;
    }
    out[n] = .{ .text = "  ", .style = base };
    n += 1;
    out[n] = .{ .text = try std.fmt.allocPrint(arena, "{s}{s}", .{ title_prefix, short_title }), .style = base };
    n += 1;
    return out[0..n];
}

pub fn headerText(arena: std.mem.Allocator, columns: Columns) ![]const u8 {
    const handle = try padded(arena, "HANDLE", columns.handle, false);
    const state = try padded(arena, "STATE", columns.state, false);
    const age = try padded(arena, "AGE", columns.age, true);
    if (columns.model > 0 and columns.cwd > 0) return std.fmt.allocPrint(arena, "{s}  {s}  {s}  {s}  {s}  TITLE", .{
        handle,
        state,
        age,
        try padded(arena, "MODEL", columns.model, false),
        try padded(arena, "CWD", columns.cwd, false),
    });
    if (columns.model > 0) return std.fmt.allocPrint(arena, "{s}  {s}  {s}  {s}  TITLE", .{
        handle,
        state,
        age,
        try padded(arena, "MODEL", columns.model, false),
    });
    return std.fmt.allocPrint(arena, "{s}  {s}  {s}  TITLE", .{ handle, state, age });
}

const OwnedRow = struct {
    sid: u64,
    parent_sid: ?u64,
    kind: proto.SessionKind,
    state: proto.SessionState,
    created_at: i64,
    archived: bool,
    title: []u8,
    cwd: []u8,
    model: []u8,

    fn init(gpa: std.mem.Allocator, info: proto.SessionInfo) !OwnedRow {
        return .{
            .sid = info.sid,
            .parent_sid = info.parent_sid,
            .kind = info.kind,
            .state = info.state,
            .created_at = info.created_at,
            .archived = info.archived,
            .title = try gpa.dupe(u8, info.title),
            .cwd = try gpa.dupe(u8, info.cwd),
            .model = try gpa.dupe(u8, info.model),
        };
    }

    fn deinit(self: *OwnedRow, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.cwd);
        gpa.free(self.model);
    }

    fn view(self: *const OwnedRow) RowView {
        return .{
            .sid = self.sid,
            .parent_sid = self.parent_sid,
            .kind = self.kind,
            .state = self.state,
            .created_at = self.created_at,
            .archived = self.archived,
            .title = self.title,
            .cwd = self.cwd,
            .model = self.model,
        };
    }
};

const PendingAction = enum { archive, unarchive, kill };

const Top = struct {
    gpa: std.mem.Allocator,
    io: Io,
    conn: *attach.Conn,
    rows: std.ArrayList(OwnedRow) = .empty,
    selected_sid: ?u64 = null,
    selected_fallback: usize = 0,
    scroll_top: usize = 0,
    show_archived: bool = false,
    confirm_kill: ?u64 = null,
    pending_action: ?PendingAction = null,
    notice: std.ArrayList(u8) = .empty,
    now_ms: i64,
    should_quit: bool = false,
    attach_sid: ?u64 = null,

    fn deinit(self: *Top) void {
        for (self.rows.items) |*row| row.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.notice.deinit(self.gpa);
    }

    fn setNotice(self: *Top, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        defer self.gpa.free(text);
        self.notice.clearRetainingCapacity();
        self.notice.appendSlice(self.gpa, text) catch {};
    }

    fn knownIds(self: *Top, arena: std.mem.Allocator) ![]const u64 {
        const ids = try arena.alloc(u64, self.rows.items.len);
        for (self.rows.items, 0..) |row, i| ids[i] = row.sid;
        return ids;
    }

    fn selectedIndex(self: *const Top) ?usize {
        if (self.rows.items.len == 0) return null;
        if (self.selected_sid) |sid| for (self.rows.items, 0..) |row, i| {
            if (row.sid == sid) return i;
        };
        return @min(self.selected_fallback, self.rows.items.len - 1);
    }

    fn normalizeSelection(self: *Top) void {
        if (self.selectedIndex()) |i| {
            self.selected_fallback = i;
            self.selected_sid = self.rows.items[i].sid;
        } else self.selected_sid = null;
    }

    fn move(self: *Top, delta: isize) void {
        const current = self.selectedIndex() orelse return;
        const next: usize = if (delta < 0)
            current -| @as(usize, @intCast(-delta))
        else
            @min(current + @as(usize, @intCast(delta)), self.rows.items.len - 1);
        self.selected_fallback = next;
        self.selected_sid = self.rows.items[next].sid;
        self.confirm_kill = null;
    }

    fn sortRows(self: *Top) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const views = arena.alloc(RowView, self.rows.items.len) catch return;
        for (self.rows.items, 0..) |*row, i| views[i] = row.view();
        const order = orderedIndices(arena, views) catch return;
        const sorted = self.gpa.alloc(OwnedRow, self.rows.items.len) catch return;
        defer self.gpa.free(sorted);
        for (order, 0..) |source, i| sorted[i] = self.rows.items[source];
        @memcpy(self.rows.items, sorted);
    }

    fn replace(self: *Top, incoming: []const proto.SessionInfo) void {
        for (self.rows.items) |*row| row.deinit(self.gpa);
        self.rows.clearRetainingCapacity();
        for (incoming) |info| {
            var row = OwnedRow.init(self.gpa, info) catch continue;
            self.rows.append(self.gpa, row) catch {
                row.deinit(self.gpa);
                continue;
            };
        }
        self.sortRows();
        self.normalizeSelection();
    }

    fn upsert(self: *Top, info: proto.SessionInfo) void {
        var row = OwnedRow.init(self.gpa, info) catch return;
        for (self.rows.items) |*existing| {
            if (existing.sid != info.sid) continue;
            existing.deinit(self.gpa);
            existing.* = row;
            self.sortRows();
            self.normalizeSelection();
            return;
        }
        self.rows.append(self.gpa, row) catch {
            row.deinit(self.gpa);
            return;
        };
        self.sortRows();
        self.normalizeSelection();
    }

    fn remove(self: *Top, sid: u64) void {
        for (self.rows.items, 0..) |*row, i| {
            if (row.sid != sid) continue;
            row.deinit(self.gpa);
            _ = self.rows.orderedRemove(i);
            if (self.selected_sid == sid) self.selected_sid = null;
            self.selected_fallback = @min(i, self.rows.items.len -| 1);
            break;
        }
        self.normalizeSelection();
    }

    fn handleLine(self: *Top, line: []u8) void {
        defer self.gpa.free(line);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const msg = proto.decode(proto.DaemonMsg, arena_state.allocator(), line) catch return;
        switch (msg) {
            .session_list_result => |result| self.replace(result.sessions),
            .session_upsert => |update| self.upsert(update.session),
            .session_remove => |removed| {
                self.remove(removed.sid);
                if (self.show_archived) self.conn.send(.{ .session_list = .{ .include_archived = true } }) catch {};
            },
            .ok => {
                if (self.pending_action) |action| self.setNotice("{s} requested", .{@tagName(action)});
                self.pending_action = null;
            },
            .err => |err| {
                self.setNotice("{s}: {s}", .{ err.code, err.msg });
                self.pending_action = null;
            },
            else => {},
        }
    }

    fn requestArchive(self: *Top) void {
        if (self.pending_action != null) return;
        const i = self.selectedIndex() orelse return;
        const row = self.rows.items[i];
        self.pending_action = if (row.archived) .unarchive else .archive;
        self.conn.send(.{ .session_archive = .{ .sid = row.sid, .archived = !row.archived } }) catch {
            self.pending_action = null;
            self.setNotice("could not update archive state", .{});
        };
    }

    fn requestKill(self: *Top, sid: u64) void {
        if (self.pending_action != null) return;
        self.pending_action = .kill;
        self.conn.send(.{ .session_kill = .{ .sid = sid } }) catch {
            self.pending_action = null;
            self.setNotice("could not kill session", .{});
        };
    }
};

const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    paste: []const u8,
    daemon_line: []u8,
    daemon_gone: []const u8,
    tick,
};

fn readerThread(gpa: std.mem.Allocator, conn: *attach.Conn, loop: *vaxis.Loop(Event)) void {
    var reason: []const u8 = "reader stopped";
    while (true) {
        const line = conn.readLine() catch |err| {
            reason = @errorName(err);
            break;
        };
        loop.postEvent(.{ .daemon_line = line }) catch {
            gpa.free(line);
            return;
        };
    }
    loop.postEvent(.{ .daemon_gone = reason }) catch {};
}

fn tickThread(io: Io, stop: *std.atomic.Value(bool), loop: *vaxis.Loop(Event)) void {
    while (!stop.load(.acquire)) {
        io.sleep(.fromSeconds(1), .awake) catch {};
        loop.postEvent(.tick) catch return;
    }
}

fn handleKey(app: *Top, key: vaxis.Key) void {
    if (app.confirm_kill) |sid| {
        if (key.matches('y', .{})) app.requestKill(sid);
        app.confirm_kill = null;
        return;
    }
    if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
        app.should_quit = true;
    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        app.move(1);
    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        app.move(-1);
    } else if (key.matches('g', .{})) {
        if (app.rows.items.len > 0) {
            app.selected_fallback = 0;
            app.selected_sid = app.rows.items[0].sid;
        }
    } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
        if (app.rows.items.len > 0) {
            app.selected_fallback = app.rows.items.len - 1;
            app.selected_sid = app.rows.items[app.rows.items.len - 1].sid;
        }
    } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
        app.move(10);
    } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
        app.move(-10);
    } else if (key.matches('a', .{})) {
        app.requestArchive();
    } else if (key.matches('x', .{}) or key.matches('K', .{ .shift = true })) {
        if (app.selectedIndex()) |i| app.confirm_kill = app.rows.items[i].sid;
    } else if (key.matches('A', .{ .shift = true })) {
        app.show_archived = !app.show_archived;
        if (app.show_archived) {
            app.conn.send(.{ .session_list = .{ .include_archived = true } }) catch app.setNotice("could not load archived sessions", .{});
        } else {
            var i = app.rows.items.len;
            while (i > 0) {
                i -= 1;
                if (app.rows.items[i].archived) app.remove(app.rows.items[i].sid);
            }
        }
    } else if (key.matches(vaxis.Key.enter, .{})) {
        if (app.selectedIndex()) |i| {
            app.attach_sid = app.rows.items[i].sid;
            app.should_quit = true;
        }
    }
}

pub fn rowDepth(rows: []const RowView, row: RowView) usize {
    var depth: usize = 0;
    var parent = row.parent_sid;
    var remaining = rows.len;
    while (parent != null and remaining > 0) : (remaining -= 1) {
        depth += 1;
        const parent_sid = parent.?;
        parent = null;
        for (rows) |candidate| {
            if (candidate.sid == parent_sid) {
                parent = candidate.parent_sid;
                break;
            }
        }
    }
    return depth;
}

pub fn drawCatalog(
    win: vaxis.Window,
    arena: std.mem.Allocator,
    rows: []const RowView,
    known_ids: []const u64,
    selected_sid: ?u64,
    scroll_top: *usize,
    now_ms: i64,
    show_archived: bool,
    notice: []const u8,
    confirm_kill: bool,
    embedded: bool,
) !void {
    win.clear();
    if (win.width < 20 or win.height < 4) return;

    var running: usize = 0;
    var approvals: usize = 0;
    var errors: usize = 0;
    var archived: usize = 0;
    var selected_index: usize = 0;
    for (rows, 0..) |row, i| {
        if (row.sid == selected_sid) selected_index = i;
        switch (row.state) {
            .running => running += 1,
            .awaiting_approval => approvals += 1,
            .err => errors += 1,
            else => {},
        }
        if (row.archived) archived += 1;
    }

    const summary = try std.fmt.allocPrint(arena, " marlin top — {d} sessions · {d} running · {d} approval · {d} error{s}{s}", .{
        rows.len,
        running,
        approvals,
        errors,
        if (show_archived) @as([]const u8, " · ") else " · archived hidden",
        if (show_archived) try std.fmt.allocPrint(arena, "{d} archived", .{archived}) else "",
    });
    _ = win.printSegment(.{ .text = summary, .style = .{ .fg = Palette.soft_blue, .bold = true } }, .{ .wrap = .none });

    const columns = computeColumns(win.width -| 1);
    _ = win.printSegment(.{ .text = try headerText(arena, columns), .style = .{ .fg = .{ .index = 8 }, .bold = true } }, .{ .row_offset = 2, .col_offset = 1, .wrap = .none });

    const body_height: usize = win.height -| 4;
    if (rows.len == 0) {
        _ = win.printSegment(.{ .text = " no sessions — marlin run \"task\" to start one", .style = .{ .fg = .{ .index = 8 }, .dim = true } }, .{ .row_offset = 3, .wrap = .none });
    } else {
        if (selected_index < scroll_top.*) scroll_top.* = selected_index;
        if (selected_index >= scroll_top.* + body_height) scroll_top.* = selected_index - body_height + 1;
        scroll_top.* = @min(scroll_top.*, rows.len -| body_height);
        const end = @min(rows.len, scroll_top.* + body_height);
        for (rows[scroll_top.*..end], 0..) |row, offset| {
            const selected = row.sid == selected_sid;
            var display_row = row;
            display_row.depth = rowDepth(rows, row);
            const row_win = win.child(.{ .y_off = @intCast(offset + 3), .height = 1, .width = win.width });
            row_win.fill(.{ .style = rowStyle(selected, row.archived) });
            _ = row_win.print(try rowSegments(arena, display_row, known_ids, columns, now_ms, selected), .{ .col_offset = 1, .wrap = .none });
        }
    }

    const footer: []const u8 = if (confirm_kill)
        " kill session tree? y confirm · any other key cancel"
    else if (notice.len > 0)
        notice
    else if (embedded)
        " j/k move · Enter switch · a archive · x kill · Ctrl+S/Esc close"
    else
        " j/k move · Enter attach · a archive · x kill · A archived · q quit";
    const footer_win = win.child(.{ .y_off = win.height - 1, .height = 1, .width = win.width });
    footer_win.fill(.{ .style = Palette.command_menu });
    _ = footer_win.printSegment(.{ .text = footer, .style = Palette.command_description }, .{ .wrap = .none });
}

fn draw(app: *Top, vx: *vaxis.Vaxis, arena: std.mem.Allocator) !void {
    const views = try arena.alloc(RowView, app.rows.items.len);
    for (app.rows.items, 0..) |*row, i| views[i] = row.view();
    try drawCatalog(
        vx.window(),
        arena,
        views,
        try app.knownIds(arena),
        app.selected_sid,
        &app.scroll_top,
        app.now_ms,
        app.show_archived,
        app.notice.items,
        app.confirm_kill != null,
        false,
    );
}

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    self_exe: []const u8,
    out: *AttachPick,
) !u8 {
    const conn = attach.connect(gpa, io, environ, self_exe) catch |err| {
        try eprint(io, "marlin top: cannot reach daemon: {t}\n", .{err});
        return 1;
    };
    var conn_owned = true;
    defer if (conn_owned) conn.deinit();
    var app = Top{ .gpa = gpa, .io = io, .conn = conn, .now_ms = render.nowWallMs(io) };
    defer app.deinit();

    var disconnect_reason: ?[]const u8 = null;
    {
        var tty_buf: [4096]u8 = undefined;
        var tty = try vaxis.Tty.init(io, &tty_buf);
        defer tty.deinit();
        const writer = tty.writer();
        var vx = try vaxis.init(io, gpa, environ, .{ .system_clipboard_allocator = gpa });
        defer vx.deinit(gpa, tty.writer());
        var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
        try loop.installResizeHandler();
        try loop.start();
        defer loop.stop();
        try vx.enterAltScreen(writer);
        try writer.flush();
        try vx.queryTerminal(writer, .fromSeconds(1));
        var ws = tty.getWinsize() catch vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
        if (ws.rows == 0 or ws.cols == 0) ws = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
        try vx.resize(gpa, writer, ws);

        var reader = try std.Thread.spawn(.{}, readerThread, .{ gpa, conn, &loop });
        defer conn.deinit();
        defer reader.join();
        defer conn.shutdown();
        conn_owned = false;
        try conn.send(.{ .session_watch = .{ .incremental = true } });

        var tick_stop: std.atomic.Value(bool) = .init(false);
        const ticker = try std.Thread.spawn(.{}, tickThread, .{ io, &tick_stop, &loop });
        defer ticker.join();
        defer tick_stop.store(true, .release);

        while (!app.should_quit) {
            var frame_arena = std.heap.ArenaAllocator.init(gpa);
            defer frame_arena.deinit();
            try draw(&app, &vx, frame_arena.allocator());
            try vx.render(writer);
            try writer.flush();

            const event = try loop.nextEvent();
            switch (event) {
                .key_press => |key| handleKey(&app, key),
                .winsize => |size| try vx.resize(gpa, writer, size),
                .daemon_line => |line| {
                    app.handleLine(line);
                    while (try loop.tryEvent()) |queued| switch (queued) {
                        .daemon_line => |more| app.handleLine(more),
                        .daemon_gone => |reason| disconnect_reason = reason,
                        .key_press => |key| handleKey(&app, key),
                        .winsize => |size| try vx.resize(gpa, writer, size),
                        .tick => app.now_ms = render.nowWallMs(io),
                        .paste => |text| gpa.free(@constCast(text)),
                        .key_release, .mouse => {},
                    };
                },
                .daemon_gone => |reason| disconnect_reason = reason,
                .tick => app.now_ms = render.nowWallMs(io),
                .paste => |text| gpa.free(@constCast(text)),
                .key_release, .mouse => {},
            }
            if (disconnect_reason != null) app.should_quit = true;
        }
    }

    out.sid = app.attach_sid;
    if (disconnect_reason) |reason| {
        try eprint(io, "marlin top: connection lost ({s})\n", .{reason});
        return 1;
    }
    return 0;
}

fn eprint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stderr(), io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
