//! Live session/agent/process work tree shared by `marlin top` and Ctrl+S.

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
    pause: proto.PauseState = .none,
    created_at: i64,
    archived: bool = false,
    depth: usize = 0,
    title: []const u8,
    cwd: []const u8,
    model: []const u8,
    activity_count: usize = 0,
    agent_count: usize = 0,
    process_count: usize = 0,
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

fn activityIndex(items: []const proto.GuestActivity, id: []const u8) ?usize {
    for (items, 0..) |item, i| if (std.mem.eql(u8, item.id, id)) return i;
    return null;
}

fn appendActivityTree(
    arena: std.mem.Allocator,
    items: []const proto.GuestActivity,
    parent_id: []const u8,
    emitted: []bool,
    out: *std.ArrayList(usize),
) !void {
    for (items, 0..) |item, i| {
        if (emitted[i] or !std.mem.eql(u8, item.parent_id, parent_id)) continue;
        emitted[i] = true;
        try out.append(arena, i);
        try appendActivityTree(arena, items, item.id, emitted, out);
    }
}

/// Stable parent-before-child order for provider-owned work ids. Orphans and
/// malformed cycles remain visible at the end instead of disappearing.
pub fn orderedActivityIndices(arena: std.mem.Allocator, items: []const proto.GuestActivity) ![]const usize {
    const emitted = try arena.alloc(bool, items.len);
    @memset(emitted, false);
    var out: std.ArrayList(usize) = .empty;
    for (items, 0..) |item, i| {
        if (item.parent_id.len > 0 and activityIndex(items, item.parent_id) != null) continue;
        emitted[i] = true;
        try out.append(arena, i);
        try appendActivityTree(arena, items, item.id, emitted, &out);
    }
    for (items, 0..) |_, i| if (!emitted[i]) try out.append(arena, i);
    return out.toOwnedSlice(arena);
}

pub fn activityDepth(items: []const proto.GuestActivity, item: proto.GuestActivity) usize {
    var depth: usize = 0;
    var parent = item.parent_id;
    while (parent.len > 0 and depth < items.len) : (depth += 1) {
        const i = activityIndex(items, parent) orelse break;
        parent = items[i].parent_id;
    }
    return depth;
}

pub const ActivityGroup = struct {
    sid: u64,
    items: []const proto.GuestActivity,
};

pub const ActivityRow = struct {
    sid: u64,
    item: proto.GuestActivity,
    depth: usize,
    /// Position in this session's parent-before-child activity order.
    position: usize,
};

pub const WorkRow = union(enum) {
    session: RowView,
    activity: ActivityRow,

    pub fn sid(self: WorkRow) u64 {
        return switch (self) {
            .session => |row| row.sid,
            .activity => |row| row.sid,
        };
    }
};

fn activityFor(groups: []const ActivityGroup, sid: u64) []const proto.GuestActivity {
    for (groups) |group| if (group.sid == sid) return group.items;
    return &.{};
}

/// One flattened operational tree: durable sessions are roots/branches and
/// provider-owned agents, tools, and processes appear directly beneath the
/// session that owns them. This is the shared model for Ctrl+S and `marlin top`.
pub fn workRows(arena: std.mem.Allocator, rows: []const RowView, groups: []const ActivityGroup) ![]const WorkRow {
    const sessions = try orderedRows(arena, rows);
    var result: std.ArrayList(WorkRow) = .empty;
    for (sessions) |row| {
        var display = row;
        display.depth = rowDepth(sessions, row);
        try result.append(arena, .{ .session = display });
        const items = activityFor(groups, row.sid);
        const order = try orderedActivityIndices(arena, items);
        for (order, 0..) |source, position| try result.append(arena, .{ .activity = .{
            .sid = row.sid,
            .item = items[source],
            .depth = display.depth + 1 + activityDepth(items, items[source]),
            .position = position,
        } });
    }
    return result.toOwnedSlice(arena);
}

pub fn selectedWorkIndex(rows: []const WorkRow, sid: ?u64, activity_position: ?usize) ?usize {
    const selected_sid = sid orelse return null;
    for (rows, 0..) |row, i| switch (row) {
        .session => |session| if (session.sid == selected_sid and activity_position == null) return i,
        .activity => |activity| if (activity_position) |position| {
            if (activity.sid == selected_sid and activity.position == position) return i;
        },
    };
    return null;
}

fn activityIcon(kind: proto.GuestActivityKind) []const u8 {
    return switch (kind) {
        .agent => "◆",
        .tool => "◇",
        .process => "▸",
    };
}

fn activityKindLabel(kind: proto.GuestActivityKind) []const u8 {
    return switch (kind) {
        .agent => "agent",
        .tool => "tool",
        .process => "process",
    };
}

pub fn drawActivityInspector(
    win: vaxis.Window,
    arena: std.mem.Allocator,
    handle: []const u8,
    model: []const u8,
    items: []const proto.GuestActivity,
    selected: *usize,
    scroll_top: *usize,
    now_ms: i64,
) !void {
    win.clear();
    if (win.width < 20 or win.height < 6) return;
    const order = try orderedActivityIndices(arena, items);
    if (order.len == 0) {
        _ = win.printSegment(.{ .text = " process tree — work finished", .style = .{ .fg = Palette.soft_blue, .bold = true } }, .{ .wrap = .none });
        _ = win.printSegment(.{ .text = " no live child work remains · ←/Esc back", .style = .{ .fg = .{ .index = 8 }, .dim = true } }, .{ .row_offset = 2, .wrap = .none });
        selected.* = 0;
        scroll_top.* = 0;
        return;
    }
    selected.* = @min(selected.*, order.len - 1);
    var agent_count: usize = 0;
    var process_count: usize = 0;
    for (items) |item| switch (item.kind) {
        .agent => agent_count += 1,
        .process => process_count += 1,
        .tool => {},
    };
    const header = try std.fmt.allocPrint(arena, " process tree — {s} · {s} · {d} live · {d} agent{s} · {d} proc{s}", .{
        handle,
        modelName(model),
        items.len,
        agent_count,
        if (agent_count == 1) "" else "s",
        process_count,
        if (process_count == 1) "" else "s",
    });
    _ = win.printSegment(.{ .text = header, .style = .{ .fg = Palette.soft_blue, .bold = true } }, .{ .wrap = .none });
    _ = win.printSegment(.{ .text = " STATE     AGE   KIND      WORK", .style = .{ .fg = .{ .index = 8 }, .bold = true } }, .{ .row_offset = 2, .wrap = .none });

    const detail_rows: usize = @min(6, @max(1, win.height / 4));
    const body_height: usize = win.height -| (4 + detail_rows);
    if (selected.* < scroll_top.*) scroll_top.* = selected.*;
    if (selected.* >= scroll_top.* + body_height) scroll_top.* = selected.* - body_height + 1;
    scroll_top.* = @min(scroll_top.*, order.len -| body_height);
    const end = @min(order.len, scroll_top.* + body_height);
    for (order[scroll_top.*..end], 0..) |source, offset| {
        const item = items[source];
        const is_selected = scroll_top.* + offset == selected.*;
        const base = rowStyle(is_selected, false);
        const row_win = win.child(.{ .y_off = @intCast(offset + 3), .height = 1, .width = win.width });
        row_win.fill(.{ .style = base });
        var age_buf: [32]u8 = undefined;
        const age = formatAge(&age_buf, item.started_at_ms, now_ms);
        const indent = try render.spaces(arena, activityDepth(items, item) * 2);
        const prefix = try std.fmt.allocPrint(arena, "{s}{s} {s}", .{ indent, activityIcon(item.kind), item.name });
        const display_detail = if (item.kind == .process) render.shellDisplayCommand(item.detail) else item.detail;
        const detail = if (display_detail.len > 0) try std.fmt.allocPrint(arena, " · {s}", .{display_detail}) else "";
        const line = try std.fmt.allocPrint(arena, " active    {s: >4}  {s: <8}  {s}{s}", .{
            age,
            activityKindLabel(item.kind),
            prefix,
            detail,
        });
        _ = row_win.printSegment(.{ .text = truncateRight(line, win.width -| 1), .style = base }, .{ .col_offset = 1, .wrap = .none });
        if (item.kind == .process and display_detail.len > 0) {
            const syntax_line = try std.fmt.allocPrint(arena, " {s}", .{line});
            render.applyLineSyntax(row_win, 0, .{
                .text = syntax_line,
                .style = base,
                .syntax = try render.shellCommandSpans(arena, display_detail, syntax_line.len - display_detail.len),
            });
        }
    }

    const chosen = items[order[selected.*]];
    const detail_top = win.height - detail_rows - 1;
    const detail_win = win.child(.{ .y_off = @intCast(detail_top), .height = @intCast(detail_rows), .width = win.width });
    detail_win.fill(.{ .style = Palette.prompt_panel });
    const identity = try std.fmt.allocPrint(arena, " {s} {s}  id {s}", .{ activityIcon(chosen.kind), activityKindLabel(chosen.kind), chosen.id });
    _ = detail_win.printSegment(.{ .text = truncateRight(identity, win.width -| 1), .style = .{ .fg = Palette.soft_blue, .bold = true } }, .{ .wrap = .none });
    if (detail_rows > 1 and chosen.parent_id.len > 0) {
        const parent = try std.fmt.allocPrint(arena, " parent {s}", .{chosen.parent_id});
        _ = detail_win.printSegment(.{ .text = truncateRight(parent, win.width -| 1), .style = Palette.command_description }, .{ .row_offset = 1, .wrap = .none });
    }
    if (detail_rows > 2 and chosen.detail.len > 0) {
        const display_detail = if (chosen.kind == .process) render.shellDisplayCommand(chosen.detail) else chosen.detail;
        _ = detail_win.printSegment(.{ .text = " command / task", .style = .{ .fg = .{ .index = 8 }, .bold = true } }, .{ .row_offset = 2, .wrap = .none });
        if (detail_rows > 3) {
            _ = detail_win.printSegment(.{ .text = display_detail, .style = Palette.command_description }, .{ .row_offset = 3, .col_offset = 1, .wrap = .word });
            if (chosen.kind == .process) render.applyLineSyntax(detail_win, 3, .{
                .text = try std.fmt.allocPrint(arena, " {s}", .{display_detail}),
                .style = Palette.command_description,
                .syntax = try render.shellCommandSpans(arena, display_detail, 1),
            });
        }
    }
    const footer_win = win.child(.{ .y_off = win.height - 1, .height = 1, .width = win.width });
    footer_win.fill(.{ .style = Palette.command_menu });
    _ = footer_win.printSegment(.{ .text = " j/k move · ←/Esc back · Ctrl+S close", .style = Palette.command_description }, .{ .wrap = .none });
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
    const activity_badge: []const u8 = if (row.activity_count == 0)
        ""
    else if (row.agent_count > 0 and row.process_count > 0)
        try std.fmt.allocPrint(arena, " · {d} agent{s}, {d} proc{s}", .{
            row.agent_count,
            if (row.agent_count == 1) "" else "s",
            row.process_count,
            if (row.process_count == 1) "" else "s",
        })
    else if (row.agent_count > 0)
        try std.fmt.allocPrint(arena, " · {d} agent{s}", .{ row.agent_count, if (row.agent_count == 1) "" else "s" })
    else if (row.process_count > 0)
        try std.fmt.allocPrint(arena, " · {d} proc{s}", .{ row.process_count, if (row.process_count == 1) "" else "s" })
    else
        try std.fmt.allocPrint(arena, " · {d} tool{s}", .{ row.activity_count, if (row.activity_count == 1) "" else "s" });
    const indent = try render.spaces(arena, row.depth * 2);
    const title_prefix = if (row.parent_sid != null)
        try std.fmt.allocPrint(arena, "{s}↳ ", .{indent})
    else
        "";
    const title_room = columns.title -| render.displayWidth(title_prefix);
    const decorated_title = try std.fmt.allocPrint(arena, "{s}{s}", .{ title, activity_badge });
    const short_title = truncateRight(decorated_title, title_room);

    var out = try arena.alloc(vaxis.Segment, 11);
    var n: usize = 0;
    out[n] = .{ .text = try padded(arena, truncateRight(handle, columns.handle), columns.handle, false), .style = base };
    n += 1;
    out[n] = .{ .text = "  ", .style = base };
    n += 1;
    out[n] = .{ .text = try padded(arena, if (row.pause != .none) @tagName(row.pause) else stateLabel(row.state), columns.state, false), .style = state_style };
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

fn activitySegments(
    arena: std.mem.Allocator,
    row: ActivityRow,
    columns: Columns,
    now_ms: i64,
    selected: bool,
) ![]const vaxis.Segment {
    const base = rowStyle(selected, false);
    var age_buf: [32]u8 = undefined;
    const age = formatAge(&age_buf, row.item.started_at_ms, now_ms);
    const display_detail = if (row.item.kind == .process) render.shellDisplayCommand(row.item.detail) else row.item.detail;
    const indent = try render.spaces(arena, row.depth * 2);
    const detail = if (display_detail.len > 0) try std.fmt.allocPrint(arena, " · {s}", .{display_detail}) else "";
    const title = try std.fmt.allocPrint(arena, "{s}{s} {s}{s}", .{ indent, activityIcon(row.item.kind), row.item.name, detail });

    var out = try arena.alloc(vaxis.Segment, 11);
    var n: usize = 0;
    out[n] = .{ .text = try padded(arena, "", columns.handle, false), .style = base };
    n += 1;
    out[n] = .{ .text = "  ", .style = base };
    n += 1;
    out[n] = .{ .text = try padded(arena, "active", columns.state, false), .style = .{ .fg = Palette.soft_blue, .bg = base.bg } };
    n += 1;
    out[n] = .{ .text = "  ", .style = base };
    n += 1;
    out[n] = .{ .text = try padded(arena, age, columns.age, true), .style = base };
    n += 1;
    if (columns.model > 0) {
        out[n] = .{ .text = "  ", .style = base };
        n += 1;
        out[n] = .{ .text = try padded(arena, activityKindLabel(row.item.kind), columns.model, false), .style = base };
        n += 1;
    }
    if (columns.cwd > 0) {
        out[n] = .{ .text = "  ", .style = base };
        n += 1;
        out[n] = .{ .text = try padded(arena, "", columns.cwd, false), .style = base };
        n += 1;
    }
    out[n] = .{ .text = "  ", .style = base };
    n += 1;
    out[n] = .{ .text = truncateRight(title, columns.title), .style = base };
    n += 1;
    return out[0..n];
}

fn drawActivityDetail(win: vaxis.Window, arena: std.mem.Allocator, row: ActivityRow) !void {
    win.fill(.{ .style = Palette.prompt_panel });
    const identity = try std.fmt.allocPrint(arena, " {s} {s} · id {s}", .{ activityIcon(row.item.kind), activityKindLabel(row.item.kind), row.item.id });
    _ = win.printSegment(.{ .text = truncateRight(identity, win.width -| 1), .style = .{ .fg = Palette.soft_blue, .bold = true } }, .{ .wrap = .none });
    if (win.height > 1 and row.item.parent_id.len > 0) {
        const parent = try std.fmt.allocPrint(arena, " parent {s}", .{row.item.parent_id});
        _ = win.printSegment(.{ .text = truncateRight(parent, win.width -| 1), .style = Palette.command_description }, .{ .row_offset = 1, .wrap = .none });
    }
    if (win.height > 2 and row.item.detail.len > 0) {
        const detail = if (row.item.kind == .process) render.shellDisplayCommand(row.item.detail) else row.item.detail;
        _ = win.printSegment(.{ .text = detail, .style = Palette.command_description }, .{ .row_offset = 2, .col_offset = 1, .wrap = .word });
        if (row.item.kind == .process) render.applyLineSyntax(win, 2, .{
            .text = try std.fmt.allocPrint(arena, " {s}", .{detail}),
            .style = Palette.command_description,
            .syntax = try render.shellCommandSpans(arena, detail, 1),
        });
    }
}

pub fn outputLines(arena: std.mem.Allocator, output: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (output, 0..) |byte, i| {
        if (byte != '\n') continue;
        const end = if (i > start and output[i - 1] == '\r') i - 1 else i;
        try lines.append(arena, output[start..end]);
        start = i + 1;
    }
    if (start < output.len)
        try lines.append(arena, if (output[output.len - 1] == '\r') output[start .. output.len - 1] else output[start..])
    else if (output.len > 0 and output[output.len - 1] == '\n')
        try lines.append(arena, "");
    return lines.toOwnedSlice(arena);
}

fn wrappedOutputLines(arena: std.mem.Allocator, output: []const u8, width: usize) ![]const []const u8 {
    const logical = try outputLines(arena, output);
    var wrapped: std.ArrayList([]const u8) = .empty;
    for (logical) |line| {
        if (line.len == 0) {
            try wrapped.append(arena, "");
            continue;
        }
        var start: usize = 0;
        while (start < line.len) {
            var end = render.wordBreak(line, start, width);
            if (end == start) end = render.hardCellBreak(line, start, width);
            if (end == start) break;
            try wrapped.append(arena, line[start..end]);
            start = end;
            while (start < line.len and line[start] == ' ') start += 1;
        }
    }
    return wrapped.toOwnedSlice(arena);
}

pub fn drawActivityOutput(
    win: vaxis.Window,
    arena: std.mem.Allocator,
    row: ActivityRow,
    output_scroll: *usize,
) !void {
    win.clear();
    if (win.width < 20 or win.height < 4) return;
    const title = try std.fmt.allocPrint(arena, " output — {s} {s}", .{ activityIcon(row.item.kind), row.item.name });
    _ = win.printSegment(.{ .text = truncateRight(title, win.width -| 1), .style = .{ .fg = Palette.soft_blue, .bold = true } }, .{ .wrap = .none });
    if (row.item.detail.len > 0) {
        const detail = if (row.item.kind == .process) render.shellDisplayCommand(row.item.detail) else row.item.detail;
        _ = win.printSegment(.{ .text = truncateRight(try std.fmt.allocPrint(arena, " {s}", .{detail}), win.width -| 1), .style = Palette.command_description }, .{ .row_offset = 1, .wrap = .none });
    }

    const body_top: usize = 3;
    const body_height = win.height -| (body_top + 1);
    const lines = try wrappedOutputLines(arena, row.item.output, @max(1, win.width -| 2));
    if (lines.len == 0) {
        output_scroll.* = 0;
        _ = win.printSegment(.{
            .text = " No output has been emitted by this harness yet.",
            .style = .{ .fg = .{ .index = 8 }, .dim = true },
        }, .{ .row_offset = @intCast(body_top), .wrap = .none });
    } else if (body_height > 0) {
        const max_scroll = lines.len -| body_height;
        output_scroll.* = @min(output_scroll.*, max_scroll);
        const end = lines.len - output_scroll.*;
        const begin = end -| body_height;
        for (lines[begin..end], 0..) |line, i| {
            _ = win.printSegment(.{ .text = line, .style = Palette.tab_inactive }, .{
                .row_offset = @intCast(body_top + i),
                .col_offset = 1,
                .wrap = .none,
            });
        }
    }
    const footer_win = win.child(.{ .y_off = win.height - 1, .height = 1, .width = win.width });
    footer_win.fill(.{ .style = Palette.command_menu });
    _ = footer_win.printSegment(.{ .text = " j/k scroll · G follow bottom · Esc back · Ctrl+S close", .style = Palette.command_description }, .{ .wrap = .none });
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
    pause: proto.PauseState = .none,
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
            .pause = info.pause,
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
            .pause = self.pause,
            .created_at = self.created_at,
            .archived = self.archived,
            .title = self.title,
            .cwd = self.cwd,
            .model = self.model,
        };
    }
};

const PendingAction = enum { archive, unarchive, kill };

const OwnedActivitySnapshot = struct {
    arena: std.heap.ArenaAllocator,
    items: []const proto.GuestActivity,

    fn deinit(self: *OwnedActivitySnapshot) void {
        self.arena.deinit();
    }
};

pub const Top = struct {
    gpa: std.mem.Allocator,
    io: Io,
    conn: *attach.Conn,
    rows: std.ArrayList(OwnedRow) = .empty,
    activities: std.AutoHashMapUnmanaged(u64, OwnedActivitySnapshot) = .empty,
    selected_sid: ?u64 = null,
    selected_activity: ?usize = null,
    selected_fallback: usize = 0,
    scroll_top: usize = 0,
    inspecting_activity: bool = false,
    activity_output_scroll: usize = 0,
    show_archived: bool = false,
    confirm_kill: ?u64 = null,
    pending_action: ?PendingAction = null,
    notice: std.ArrayList(u8) = .empty,
    now_ms: i64,
    should_quit: bool = false,
    attach_sid: ?u64 = null,

    pub fn deinit(self: *Top) void {
        for (self.rows.items) |*row| row.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        var activity_it = self.activities.valueIterator();
        while (activity_it.next()) |snapshot| snapshot.deinit();
        self.activities.deinit(self.gpa);
        self.notice.deinit(self.gpa);
    }

    pub fn activity(self: *const Top, sid: u64) []const proto.GuestActivity {
        return if (self.activities.get(sid)) |snapshot| snapshot.items else &.{};
    }

    fn replaceActivity(self: *Top, sid: u64, items: []const proto.GuestActivity) void {
        if (items.len == 0) {
            if (self.activities.fetchRemove(sid)) |removed| {
                var snapshot = removed.value;
                snapshot.deinit();
            }
            if (self.selected_sid == sid) {
                self.selected_activity = null;
                self.inspecting_activity = false;
            }
            return;
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = arena.allocator();
        const owned = a.alloc(proto.GuestActivity, items.len) catch return arena.deinit();
        for (items, owned) |item, *copy| copy.* = .{
            .id = a.dupe(u8, item.id) catch return arena.deinit(),
            .parent_id = a.dupe(u8, item.parent_id) catch return arena.deinit(),
            .kind = item.kind,
            .name = a.dupe(u8, item.name) catch return arena.deinit(),
            .detail = a.dupe(u8, item.detail) catch return arena.deinit(),
            .output = a.dupe(u8, item.output) catch return arena.deinit(),
            .started_at_ms = item.started_at_ms,
        };
        const previous = self.activities.fetchPut(self.gpa, sid, .{ .arena = arena, .items = owned }) catch {
            arena.deinit();
            return;
        };
        if (previous) |old| {
            var snapshot = old.value;
            snapshot.deinit();
        }
        if (self.selected_sid == sid) if (self.selected_activity) |position| {
            self.selected_activity = @min(position, owned.len - 1);
        };
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

    fn work(self: *const Top, arena: std.mem.Allocator) ![]const WorkRow {
        const views = try arena.alloc(RowView, self.rows.items.len);
        const groups = try arena.alloc(ActivityGroup, self.rows.items.len);
        for (self.rows.items, 0..) |*row, i| {
            views[i] = row.view();
            const items = self.activity(row.sid);
            views[i].activity_count = items.len;
            for (items) |item| switch (item.kind) {
                .agent => views[i].agent_count += 1,
                .process => views[i].process_count += 1,
                .tool => {},
            };
            groups[i] = .{ .sid = row.sid, .items = items };
        }
        return workRows(arena, views, groups);
    }

    fn normalizeSelection(self: *Top) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const rows = self.work(arena_state.allocator()) catch return;
        if (rows.len == 0) {
            self.selected_sid = null;
            self.selected_activity = null;
            return;
        }
        if (selectedWorkIndex(rows, self.selected_sid, self.selected_activity)) |i| {
            self.selected_fallback = i;
            return;
        }
        const i = @min(self.selected_fallback, rows.len - 1);
        self.selectWorkRow(rows[i], i);
    }

    fn move(self: *Top, delta: isize) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const rows = self.work(arena_state.allocator()) catch return;
        if (rows.len == 0) return;
        const current = selectedWorkIndex(rows, self.selected_sid, self.selected_activity) orelse @min(self.selected_fallback, rows.len - 1);
        const next: usize = if (delta < 0)
            current -| @as(usize, @intCast(-delta))
        else
            @min(current + @as(usize, @intCast(delta)), rows.len - 1);
        self.selectWorkRow(rows[next], next);
        self.confirm_kill = null;
    }

    fn moveEdge(self: *Top, last: bool) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const rows = self.work(arena_state.allocator()) catch return;
        if (rows.len == 0) return;
        const i = if (last) rows.len - 1 else 0;
        self.selectWorkRow(rows[i], i);
        self.confirm_kill = null;
    }

    fn selectWorkRow(self: *Top, row: WorkRow, fallback: usize) void {
        self.selected_fallback = fallback;
        switch (row) {
            .session => |session| {
                self.selected_sid = session.sid;
                self.selected_activity = null;
            },
            .activity => |work_activity| {
                self.selected_sid = work_activity.sid;
                self.selected_activity = work_activity.position;
            },
        }
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

    pub fn handleLine(self: *Top, line: []u8) void {
        defer self.gpa.free(line);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const msg = proto.decode(proto.DaemonMsg, arena_state.allocator(), line) catch return;
        switch (msg) {
            .session_list_result => |result| self.replace(result.sessions),
            .session_upsert => |update| self.upsert(update.session),
            // Upserts carry structural changes only (create, rename); turn
            // state moves on the compact status path. Task children never
            // get a title upsert, so without this they read running forever.
            .status => |s| for (self.rows.items) |*row| {
                if (row.sid == s.sid) {
                    row.state = s.state;
                    row.pause = s.pause;
                    break;
                }
            },
            .guest_activity => |snapshot| self.replaceActivity(snapshot.sid, snapshot.items),
            .session_remove => |removed| {
                self.replaceActivity(removed.sid, &.{});
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
    if (app.inspecting_activity) {
        if (key.matches(vaxis.Key.escape, .{})) {
            app.inspecting_activity = false;
        } else if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
            app.should_quit = true;
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            app.activity_output_scroll +|= 1;
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            app.activity_output_scroll -|= 1;
        } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
            app.activity_output_scroll +|= 10;
        } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
            app.activity_output_scroll -|= 10;
        } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
            app.activity_output_scroll = 0;
        }
        return;
    }
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
        app.moveEdge(false);
    } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
        app.moveEdge(true);
    } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
        app.move(10);
    } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
        app.move(-10);
    } else if (key.matches('a', .{})) {
        if (app.selected_activity == null) app.requestArchive() else app.setNotice("select a session to archive", .{});
    } else if (key.matches('x', .{}) or key.matches('K', .{ .shift = true })) {
        if (app.selected_activity == null) {
            if (app.selectedIndex()) |i| app.confirm_kill = app.rows.items[i].sid;
        } else app.setNotice("select a session to kill", .{});
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
        if (app.selected_activity != null) {
            app.inspecting_activity = true;
            app.activity_output_scroll = 0;
        } else if (app.selectedIndex()) |i| {
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
    activity_groups: []const ActivityGroup,
    known_ids: []const u64,
    selected_sid: ?u64,
    selected_activity: ?usize,
    scroll_top: *usize,
    now_ms: i64,
    show_archived: bool,
    notice: []const u8,
    confirm_kill: bool,
    embedded: bool,
    inspecting_activity: bool,
    output_scroll: *usize,
) !void {
    win.clear();
    if (win.width < 20 or win.height < 4) return;
    const work = try workRows(arena, rows, activity_groups);

    var running: usize = 0;
    var approvals: usize = 0;
    var errors: usize = 0;
    var archived: usize = 0;
    var live_work: usize = 0;
    const selected_index = selectedWorkIndex(work, selected_sid, selected_activity) orelse 0;
    for (rows) |row| {
        switch (row.state) {
            .running => running += 1,
            .awaiting_approval => approvals += 1,
            .err => errors += 1,
            else => {},
        }
        if (row.archived) archived += 1;
        live_work += row.activity_count;
    }

    if (inspecting_activity and work.len > 0) switch (work[selected_index]) {
        .activity => |activity| return drawActivityOutput(win, arena, activity, output_scroll),
        .session => {},
    };

    const summary = try std.fmt.allocPrint(arena, " marlin work tree — {d} sessions · {d} running · {d} live work · {d} approval · {d} error{s}{s}", .{
        rows.len,
        running,
        live_work,
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
        scroll_top.* = @min(scroll_top.*, work.len -| body_height);
        const end = @min(work.len, scroll_top.* + body_height);
        for (work[scroll_top.*..end], 0..) |row, offset| {
            const selected = scroll_top.* + offset == selected_index;
            const row_win = win.child(.{ .y_off = @intCast(offset + 3), .height = 1, .width = win.width });
            switch (row) {
                .session => |session| {
                    row_win.fill(.{ .style = rowStyle(selected, session.archived) });
                    _ = row_win.print(try rowSegments(arena, session, known_ids, columns, now_ms, selected), .{ .col_offset = 1, .wrap = .none });
                },
                .activity => |activity| {
                    row_win.fill(.{ .style = rowStyle(selected, false) });
                    const segments = try activitySegments(arena, activity, columns, now_ms, selected);
                    _ = row_win.print(segments, .{ .col_offset = 1, .wrap = .none });
                },
            }
        }
    }

    const footer: []const u8 = if (confirm_kill)
        " kill session tree? y confirm · any other key cancel"
    else if (notice.len > 0)
        notice
    else if (embedded)
        " j/k move · Enter open/switch · a archive · x kill · Ctrl+S/Esc close"
    else
        " j/k move · Enter open/attach · a archive · x kill · A archived · q quit";
    const footer_win = win.child(.{ .y_off = win.height - 1, .height = 1, .width = win.width });
    footer_win.fill(.{ .style = Palette.command_menu });
    _ = footer_win.printSegment(.{ .text = footer, .style = Palette.command_description }, .{ .wrap = .none });
}

fn draw(app: *Top, vx: *vaxis.Vaxis, arena: std.mem.Allocator) !void {
    const views = try arena.alloc(RowView, app.rows.items.len);
    const groups = try arena.alloc(ActivityGroup, app.rows.items.len);
    for (app.rows.items, 0..) |*row, i| {
        views[i] = row.view();
        const activity = app.activity(row.sid);
        groups[i] = .{ .sid = row.sid, .items = activity };
        views[i].activity_count = activity.len;
        for (activity) |item| switch (item.kind) {
            .agent => views[i].agent_count += 1,
            .process => views[i].process_count += 1,
            .tool => {},
        };
    }
    try drawCatalog(
        vx.window(),
        arena,
        views,
        groups,
        try app.knownIds(arena),
        app.selected_sid,
        app.selected_activity,
        &app.scroll_top,
        app.now_ms,
        app.show_archived,
        app.notice.items,
        app.confirm_kill != null,
        false,
        app.inspecting_activity,
        &app.activity_output_scroll,
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
