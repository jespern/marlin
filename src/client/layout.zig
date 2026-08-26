//! Transcript layout, folding, and cache state for the Marlin TUI.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");
const render = @import("render.zig");
const markdown = @import("markdown.zig");
const Palette = render.Palette;
const LinkSpan = render.LinkSpan;
const SyntaxSpan = render.SyntaxSpan;
const Line = render.Line;
const spinner_frames = render.spinner_frames;
const shimmerSpans = render.shimmerSpans;
const lastNonEmptyLine = render.lastNonEmptyLine;
const utf8Floor = render.utf8Floor;
const clipText = render.clipText;
const isLegacyRehydration = render.isLegacyRehydration;
const rehydrationLabel = render.rehydrationLabel;
const isCompactionStatusNote = render.isCompactionStatusNote;
const nowWallMs = render.nowWallMs;
const lineText = render.lineText;
const SyntaxLanguage = render.SyntaxLanguage;
const diffLanguage = render.diffLanguage;
const syntaxSpans = render.syntaxSpans;
const shellCommandSpans = render.shellCommandSpans;
const gitLogSpans = render.gitLogSpans;
const findLinkSpans = render.findLinkSpans;
const linksForChunk = render.linksForChunk;
const resolveLineLinks = render.resolveLineLinks;
const blankLine = render.blankLine;
const wrapInto = render.wrapInto;
const wrapPrefixed = render.wrapPrefixed;
const displayWidth = render.displayWidth;
const hardCellBreak = render.hardCellBreak;
const wordBreak = render.wordBreak;
const spaces = render.spaces;
const inlineMarkdown = markdown.inlineMarkdown;
const markdownGutter = markdown.markdownGutter;
const markdownMeasure = markdown.markdownMeasure;
const appendTranslatedInline = markdown.appendTranslatedInline;
const lineWidthBytes = markdown.lineWidthBytes;
const wrapMarkdown = markdown.wrapMarkdown;

pub const LayoutCache = struct {
    arena_state: ?*std.heap.ArenaAllocator = null,
    lines: std.ArrayList(Line) = .empty,
    covered: usize = 0,
    width: usize = 0,
    expanded: bool = false,
    epoch: u64 = 0,
    label_state: []const u8 = "",

    pub fn allocator(self: *LayoutCache, gpa: std.mem.Allocator) !std.mem.Allocator {
        if (self.arena_state == null) {
            const st = try gpa.create(std.heap.ArenaAllocator);
            st.* = .init(gpa);
            self.arena_state = st;
        }
        return self.arena_state.?.allocator();
    }

    pub fn reset(self: *LayoutCache, gpa: std.mem.Allocator) void {
        if (self.arena_state) |st| {
            st.deinit();
            gpa.destroy(st);
        }
        // The lines list itself lives in the arena; dropping the arena
        // dropped it too.
        self.* = .{};
    }
};

/// Durable layout for the mutable tail (normally the current turn). It is
/// rebuilt only when a block or relevant state changes; spinner and stream
/// frames simply append their ephemeral lines. This keeps frame cost O(1)
/// with respect to even a very large active turn.
pub const TailLayoutCache = struct {
    arena_state: ?*std.heap.ArenaAllocator = null,
    lines: std.ArrayList(Line) = .empty,
    start: usize = 0,
    end: usize = 0,
    width: usize = 0,
    expanded: bool = false,
    epoch: u64 = 0,
    state: proto.SessionState = .idle,

    pub fn allocator(self: *TailLayoutCache, gpa: std.mem.Allocator) !std.mem.Allocator {
        if (self.arena_state == null) {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            self.arena_state = arena;
        }
        return self.arena_state.?.allocator();
    }

    pub fn reset(self: *TailLayoutCache, gpa: std.mem.Allocator) void {
        if (self.arena_state) |arena| {
            arena.deinit();
            gpa.destroy(arena);
        }
        self.* = .{};
    }
};

/// Append-only live assistant layout. Streaming text is provisional, so it
/// uses a light prose rail and receives full Markdown treatment only when the
/// finalized durable block arrives. Complete wrapped rows are baked once;
/// only the short unfinished row is reconsidered as new deltas arrive.
pub const StreamLayoutCache = struct {
    arena_state: ?*std.heap.ArenaAllocator = null,
    lines: std.ArrayList(Line) = .empty,
    pending: std.ArrayList(u8) = .empty,
    source_len: usize = 0,
    width: usize = 0,
    first_prefix: []const u8 = "",
    continuation_prefix: []const u8 = "",
    at_line_start: bool = true,

    pub fn allocator(self: *StreamLayoutCache, gpa: std.mem.Allocator) !std.mem.Allocator {
        if (self.arena_state == null) {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            self.arena_state = arena;
        }
        return self.arena_state.?.allocator();
    }

    pub fn reset(self: *StreamLayoutCache, gpa: std.mem.Allocator) void {
        self.pending.deinit(gpa);
        if (self.arena_state) |arena| {
            arena.deinit();
            gpa.destroy(arena);
        }
        self.* = .{};
    }

    pub fn prepare(self: *StreamLayoutCache, gpa: std.mem.Allocator, width: usize) !void {
        if (self.width == width and self.first_prefix.len > 0) return;
        const arena = try self.allocator(gpa);
        self.width = width;
        self.first_prefix = try std.fmt.allocPrint(arena, "{s}• ", .{markdownGutter(width)});
        self.continuation_prefix = try spaces(arena, displayWidth(self.first_prefix));
    }

    pub fn discardPendingPrefix(self: *StreamLayoutCache, count: usize) void {
        const remaining = self.pending.items.len - count;
        std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[count..]);
        self.pending.items.len = remaining;
    }

    pub fn appendRow(self: *StreamLayoutCache, gpa: std.mem.Allocator, text: []const u8) !void {
        const arena = try self.allocator(gpa);
        const prefix = if (self.at_line_start) self.first_prefix else self.continuation_prefix;
        const rendered = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, text });
        try self.lines.append(arena, .{ .text = rendered, .style = Palette.assistant });
        self.at_line_start = false;
    }

    pub fn appendBlank(self: *StreamLayoutCache, gpa: std.mem.Allocator) !void {
        const arena = try self.allocator(gpa);
        if (self.lines.items.len == 0 or lineWidthBytes(self.lines.items[self.lines.items.len - 1]) != 0)
            try self.lines.append(arena, .{ .text = "", .style = .{} });
    }

    pub fn commitCompleteLine(self: *StreamLayoutCache, gpa: std.mem.Allocator, text: []const u8) !void {
        if (text.len == 0) {
            try self.appendBlank(gpa);
            self.at_line_start = true;
            return;
        }
        var start: usize = 0;
        while (start < text.len) {
            const prefix = if (self.at_line_start) self.first_prefix else self.continuation_prefix;
            const capacity = markdownMeasure(self.width) -| displayWidth(prefix);
            if (capacity == 0) return;
            var end = wordBreak(text, start, capacity);
            if (end == start) end = hardCellBreak(text, start, capacity);
            try self.appendRow(gpa, text[start..end]);
            start = end;
            while (start < text.len and (text[start] == ' ' or text[start] == '\t')) start += 1;
        }
        self.at_line_start = true;
    }

    pub fn commitFullPendingRows(self: *StreamLayoutCache, gpa: std.mem.Allocator) !void {
        while (self.pending.items.len > 0) {
            const prefix = if (self.at_line_start) self.first_prefix else self.continuation_prefix;
            const capacity = markdownMeasure(self.width) -| displayWidth(prefix);
            if (capacity == 0) return;
            var end = wordBreak(self.pending.items, 0, capacity);
            if (end >= self.pending.items.len) return;
            if (end == 0) end = hardCellBreak(self.pending.items, 0, capacity);
            try self.appendRow(gpa, self.pending.items[0..end]);
            while (end < self.pending.items.len and
                (self.pending.items[end] == ' ' or self.pending.items[end] == '\t')) end += 1;
            self.discardPendingPrefix(end);
        }
    }

    pub fn update(self: *StreamLayoutCache, gpa: std.mem.Allocator, text: []const u8, width: usize) !void {
        if (self.width != width or text.len < self.source_len) self.reset(gpa);
        try self.prepare(gpa, width);
        try self.pending.appendSlice(gpa, text[self.source_len..]);
        self.source_len = text.len;

        while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |newline| {
            try self.commitCompleteLine(gpa, self.pending.items[0..newline]);
            self.discardPendingPrefix(newline + 1);
        }
        try self.commitFullPendingRows(gpa);
    }

    pub fn appendTo(self: *const StreamLayoutCache, arena: std.mem.Allocator, out: *std.ArrayList(Line)) !void {
        try out.appendSlice(arena, self.lines.items);
        if (self.pending.items.len == 0) return;
        try out.append(arena, .{
            .text = if (self.at_line_start) self.first_prefix else self.continuation_prefix,
            .style = Palette.assistant,
            .text2 = self.pending.items,
            .style2 = Palette.assistant,
        });
    }
};

/// A block reduced to what the renderer needs (owned copies).
pub const RenderBlock = struct {
    kind: block.BlockKind,
    /// Durable identity from the block log. Zero marks an optimistic local
    /// echo that will be reconciled when the daemon block arrives.
    seq: u64 = 0,
    turn_id: u64 = 0,
    /// Primary text (message text, tool output, note...).
    text: []u8,
    /// tool_call: "name" — used for the collapsed header line.
    label: []u8,
    /// Terminal completed plan revision. Intermediate revisions stay in the
    /// pinned App plan only; retaining all of them would waste memory and
    /// render duplicate historical tables.
    plan_items: []block.PlanItem = &.{},
    status: block.ToolStatus = .ok,
    /// Content-addressed uncapped tool output. Null means `text` is already
    /// the complete result and can be copied without another daemon query.
    full_body_ref: ?[]u8 = null,
    /// reasoning blocks: true = deliberate mid-turn narration (visible);
    /// false = raw provider reasoning (folded; ctrl+t reveals).
    commentary: bool = false,
    /// Locally inserted for instant submit feedback. The matching durable
    /// block clears this bit instead of producing a duplicate render block.
    pending_echo: bool = false,
    /// Identity of the input awaiting its daemon ok/err. Zero after ack.
    pending_request_id: u64 = 0,
    /// Non-null only for a new-turn echo whose optimistic running state must
    /// be restored if the daemon rejects that exact request.
    pending_prior_state: ?proto.SessionState = null,

    pub fn deinit(self: *RenderBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.label);
        for (self.plan_items) |item| gpa.free(item.step);
        if (self.plan_items.len > 0) gpa.free(self.plan_items);
        if (self.full_body_ref) |ref| gpa.free(ref);
    }
};

fn completedPlan(items: []const block.PlanItem) bool {
    if (items.len == 0) return false;
    for (items) |item| if (item.status != .completed) return false;
    return true;
}

fn clonePlanItems(gpa: std.mem.Allocator, source: []const block.PlanItem) ![]block.PlanItem {
    if (source.len == 0) return &.{};
    const items = try gpa.alloc(block.PlanItem, source.len);
    var copied: usize = 0;
    errdefer {
        for (items[0..copied]) |item| gpa.free(item.step);
        gpa.free(items);
    }
    for (source, items) |item, *copy| {
        copy.* = item;
        copy.step = try gpa.dupe(u8, item.step);
        copied += 1;
    }
    return items;
}

/// Convert a durable block into its owned presentation form without the live
/// side effects in App.applyBlock. Older history pages are buffered off-screen
/// and prepended atomically only after their replay marker arrives.
pub fn allocDurableRenderBlock(gpa: std.mem.Allocator, b: block.Block) !?RenderBlock {
    var kind = b.kind();
    var text: []const u8 = "";
    var label: []const u8 = "";
    var status: block.ToolStatus = .ok;
    var full_body_ref: ?[]const u8 = null;
    var generated_text: ?[]u8 = null;
    var generated_label: ?[]u8 = null;
    var plan_items: []block.PlanItem = &.{};
    defer if (generated_text) |owned| gpa.free(owned);
    defer if (generated_label) |owned| gpa.free(owned);
    errdefer {
        for (plan_items) |item| gpa.free(item.step);
        if (plan_items.len > 0) gpa.free(plan_items);
    }

    switch (b.body) {
        .user_msg => |u| {
            if (u.synthetic or isLegacyRehydration(u.text)) {
                kind = .system_note;
                generated_text = try rehydrationLabel(gpa, u.text);
                text = generated_text.?;
            } else {
                text = u.text;
                if (u.attachments.len > 0) {
                    generated_label = try mediaLabel(gpa, u.attachments);
                    label = generated_label.?;
                }
            }
        },
        .steer => |s| text = s.text,
        .assistant_msg => |a| text = a.text,
        .reasoning => |r| text = r.text,
        .tool_call => |tc| {
            text = tc.args_json;
            label = tc.name;
        },
        .tool_result => |tr| {
            text = tr.inline_body;
            status = tr.status;
            full_body_ref = tr.full_body_ref;
            if (tr.attachments.len > 0) {
                generated_label = try mediaLabel(gpa, tr.attachments);
                label = generated_label.?;
            }
        },
        .approval => |ap| text = if (ap.decision) |decision| @tagName(decision) else "pending",
        .plan => |plan| {
            if (!completedPlan(plan.items)) return null;
            plan_items = try clonePlanItems(gpa, plan.items);
        },
        .system_note => |sn| {
            if (isCompactionStatusNote(sn.text)) return null;
            text = sn.text;
        },
        .compaction => text = "context compacted",
    }

    const owned_text = if (generated_text) |owned| blk: {
        generated_text = null;
        break :blk owned;
    } else try gpa.dupe(u8, text);
    errdefer gpa.free(owned_text);
    const owned_label = if (generated_label) |owned| blk: {
        generated_label = null;
        break :blk owned;
    } else try gpa.dupe(u8, label);
    errdefer gpa.free(owned_label);
    const owned_ref = if (full_body_ref) |ref| try gpa.dupe(u8, ref) else null;

    return .{
        .kind = kind,
        .seq = b.seq,
        .turn_id = b.turn_id,
        .text = owned_text,
        .label = owned_label,
        .plan_items = plan_items,
        .status = status,
        .full_body_ref = owned_ref,
    };
}

pub fn mediaLabel(gpa: std.mem.Allocator, refs: []const block.MediaRef) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (refs, 0..) |ref, i| {
        if (i > 0) try out.append(gpa, '\n');
        try out.print(gpa, "▣ {s} · {s} · {Bi:.1}", .{ ref.name, ref.mime, ref.byte_len });
    }
    return out.toOwnedSlice(gpa);
}

pub fn wrapPromptCard(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    width: usize,
) !void {
    const first_prefix = " ❯ ";
    const continuation = "   ";
    const prefix_cells: usize = 3;
    const body_width = width -| (prefix_cells + 1); // keep right padding
    if (body_width < 8) return;

    try lines.append(arena, .{ .text = "", .style = Palette.prompt_text, .fill_style = Palette.prompt_panel });
    var first = true;
    var logical = std.mem.splitScalar(u8, text, '\n');
    while (logical.next()) |raw_line| {
        const source_links = try findLinkSpans(arena, raw_line);
        var rest = raw_line;
        while (true) {
            const take = @min(rest.len, body_width);
            const chunk_start = raw_line.len - rest.len;
            const prefix = if (first) first_prefix else continuation;
            const links = try linksForChunk(
                arena,
                source_links,
                chunk_start,
                chunk_start + take,
                prefix.len,
            );
            try lines.append(arena, .{
                .text = prefix,
                .style = if (first) Palette.prompt_mark else Palette.prompt_text,
                .text2 = rest[0..take],
                .style2 = Palette.prompt_text,
                .fill_style = Palette.prompt_panel,
                .links = links,
                .links_resolved = true,
            });
            first = false;
            if (take == rest.len) break;
            rest = rest[take..];
        }
    }
    try lines.append(arena, .{ .text = "", .style = Palette.prompt_text, .fill_style = Palette.prompt_panel });
}

/// Reasoning/progress narration: a small mark and muted text, flat on the
/// default background. CONTENT-ONLY like every renderer — the layout loop
/// owns all separating air (see layoutBlockRange's section discipline).
pub fn wrapReasoningCard(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    width: usize,
) !void {
    const prefix = "  · ";
    const cont = "    ";

    // Commentary arrives with inline markdown (**bold**, `code`, links);
    // render it instead of showing the markers verbatim. Newlines flatten
    // to spaces — the card is prose, not layout.
    const flat = try arena.dupe(u8, text);
    std.mem.replaceScalar(u8, flat, '\n', ' ');
    const im = try inlineMarkdown(arena, flat);

    const avail = @max(@as(usize, 8), (width -| 2) -| prefix.len);
    var start: usize = 0;
    var first = true;
    while (first or start < im.text.len) {
        var end = wordBreak(im.text, start, avail);
        if (end == start and start < im.text.len) end = hardCellBreak(im.text, start, avail);
        const head: []const u8 = if (first) prefix else cont;
        var styles: std.ArrayList(SyntaxSpan) = .empty;
        var links: std.ArrayList(LinkSpan) = .empty;
        try appendTranslatedInline(arena, &styles, &links, im, start, end, head.len);
        try lines.append(arena, .{
            .text = head,
            .style = if (first) Palette.reasoning_mark else Palette.reasoning,
            .text2 = im.text[start..end],
            .style2 = Palette.reasoning,
            .syntax = styles.items,
            .links = links.items,
            .links_resolved = true,
        });
        first = false;
        start = end;
        while (start < im.text.len and im.text[start] == ' ') start += 1;
        if (start >= im.text.len) break;
    }
}

pub const CollapsedToolRun = struct {
    count: usize,
    /// First block after the run.
    next: usize,
};

pub fn isDiffOutput(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "\n@@ ") != null or std.mem.startsWith(u8, text, "@@ ");
}

/// Tools whose diff output is a change the agent MADE. Only these stop the
/// collapse run below; a diff the agent merely read (`bash git diff …`) is
/// ordinary command output and collapses like any other success. Covers both
/// vocabularies: native (edit/write_file) and Claude Code guest sessions
/// (Edit/Write/…), whose bridge emits diffs in the same dialect.
pub fn isFileEditTool(label: []const u8) bool {
    const authored = [_][]const u8{ "edit", "write_file", "Edit", "Write", "MultiEdit", "NotebookEdit" };
    for (authored) |name| {
        if (std.mem.eql(u8, label, name)) return true;
    }
    return false;
}

/// A failed command can emit hundreds of perfectly ordinary compiler or test
/// lines. Reserve red for the lines that actually summarize the failure; the
/// surrounding transcript stays at the same quiet level as successful tool
/// output, so the useful diagnostic remains easy to find.
pub fn isSalientToolErrorLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const prefixes = [_][]const u8{
        "error:",
        "fatal:",
        "panic:",
        "fail ",
        "fail:",
        "denied:",
        "blocked:",
        "permission denied",
        "access denied",
        "[exit code:",
    };
    for (prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(trimmed, prefix)) return true;
    }
    return std.ascii.indexOfIgnoreCase(trimmed, " fail ") != null or
        std.ascii.indexOfIgnoreCase(trimmed, ": permission denied") != null or
        std.ascii.indexOfIgnoreCase(trimmed, ": access denied") != null;
}

/// A calls-first batch can be visible while its tools are still running.
/// Return its extent only when it is the incomplete tail of the transcript.
pub fn pendingToolBatch(blocks: []const RenderBlock, start: usize) ?CollapsedToolRun {
    if (start >= blocks.len or blocks[start].kind != .tool_call) return null;
    const turn_id = blocks[start].turn_id;
    if (start > 0 and
        blocks[start - 1].kind == .tool_call and
        blocks[start - 1].turn_id == turn_id) return null;

    var calls_end = start;
    while (calls_end < blocks.len and
        blocks[calls_end].kind == .tool_call and
        blocks[calls_end].turn_id == turn_id) : (calls_end += 1)
    {}
    const count = calls_end - start;
    if (count < 2) return null;

    var i = calls_end;
    var results: usize = 0;
    scan_results: while (i < blocks.len and results < count and blocks[i].turn_id == turn_id) {
        switch (blocks[i].kind) {
            .approval, .reasoning, .system_note, .plan => i += 1,
            .tool_result => {
                results += 1;
                i += 1;
            },
            else => break :scan_results,
        }
    }
    if (results < count and i == blocks.len) return .{ .count = count, .next = i };
    return null;
}

/// Flatten blocks + delta into wrapped display lines for a given width.
/// Returned list and its line slices use `arena` (per-frame).
/// Render blocks[start..end) as display lines. `alloc` owns every derived
/// string: the frame arena for the live tail, the layout cache's arena for
/// baked completed turns. `allow_fold` enables the running-command fold,
/// which reads live session state and therefore applies only to the tail.
/// The collapsed-transcript machinery renders call/result pairs from two
/// places (the sequential walk and batch-failure expansion); one renderer
/// each keeps them identical.
pub fn appendToolCallLine(
    alloc: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    rb: RenderBlock,
    cwd: []const u8,
    w: usize,
    /// Dim annotation after the argument (e.g. "96 bytes" distilled from an
    /// authored diff's intro line, which is not rendered as a body line).
    note: ?[]const u8,
) !void {
    // Keep the machinery subdued. Bash commands receive semantic shell
    // roles; for file tools the emphasized value is a path.
    const hi = toolDisplayArg(rb.label, rb.text, cwd);
    const head = try std.fmt.allocPrint(alloc, "  ⚙ {s} ", .{toolDisplayName(rb.label)});
    const note_text: []const u8 = if (note) |n|
        try std.fmt.allocPrint(alloc, " · {s}", .{n})
    else
        "";
    if (hi) |h| {
        const hi_capped = h[0..@min(h.len, w -| (head.len + 2))];
        const is_bash = std.ascii.eqlIgnoreCase(rb.label, "bash");
        try lines.append(alloc, .{
            .text = head,
            .style = Palette.tool,
            .text2 = hi_capped,
            .style2 = if (is_bash) Palette.shell_command else Palette.tool_cmd,
            .text3 = note_text,
            .style3 = Palette.collapse_hint,
            .syntax = if (is_bash)
                try shellCommandSpans(alloc, hi_capped, head.len)
            else
                try diffCountSpans(alloc, note_text, head.len + hi_capped.len),
        });
    } else {
        try lines.append(alloc, .{
            .text = head,
            .style = Palette.tool,
            .text2 = note_text,
            .style2 = Palette.collapse_hint,
            .syntax = try diffCountSpans(alloc, note_text, head.len),
        });
    }
}

/// Color the compact diffstat at the end of a tool-line note without
/// sacrificing the separate machinery/path/note styles used by the row.
fn diffCountSpans(alloc: std.mem.Allocator, note: []const u8, base: usize) ![]const SyntaxSpan {
    const plus_space = std.mem.lastIndexOf(u8, note, " +") orelse return &.{};
    const minus_space = std.mem.indexOfPos(u8, note, plus_space + 2, " -") orelse return &.{};
    const plus = plus_space + 1;
    const minus = minus_space + 1;
    if (plus + 1 == minus_space or minus + 1 == note.len) return &.{};
    for (note[plus + 1 .. minus_space]) |c| if (!std.ascii.isDigit(c)) return &.{};
    for (note[minus + 1 ..]) |c| if (!std.ascii.isDigit(c)) return &.{};

    const spans = try alloc.alloc(SyntaxSpan, 2);
    spans[0] = .{
        .start = base + plus,
        .end = base + minus_space,
        .style = .{ .fg = Palette.diff_add.fg, .bold = true },
    };
    spans[1] = .{
        .start = base + minus,
        .end = base + note.len,
        .style = .{ .fg = Palette.diff_del.fg, .bold = true },
    };
    return spans;
}

/// The ⚙-line annotation distilled from an authored diff's intro line:
/// "created x (96 bytes)" → "96 bytes" · "edited 2 hunks in x" → "2 hunks" ·
/// "wrote 84 bytes to x" → "84 bytes" · "replaced 3 occurrence(s) in x" →
/// "3 occurrence(s)". Null when the first line matches no known intro.
pub fn diffIntroNote(text: []const u8) ?[]const u8 {
    const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    if (std.mem.endsWith(u8, first, " bytes)")) {
        if (std.mem.lastIndexOfScalar(u8, first, '(')) |open|
            return first[open + 1 .. first.len - 1];
    }
    if (std.mem.startsWith(u8, first, "wrote ")) {
        if (std.mem.indexOf(u8, first, " bytes to ")) |at| return first[6 .. at + 6];
    }
    for ([_][]const u8{ " hunk", " occurrence" }) |word| {
        const at = std.mem.indexOf(u8, first, word) orelse continue;
        const count_start = (std.mem.lastIndexOfScalar(u8, first[0..at], ' ') orelse continue) + 1;
        const in_at = std.mem.indexOfPos(u8, first, at, " in ") orelse continue;
        return first[count_start..in_at];
    }
    return null;
}

const DiffStats = struct {
    added: usize = 0,
    removed: usize = 0,
};

/// Count changed lines in native and guest-authored diffs. Creation previews
/// carry their omitted-line count explicitly, so their diffstat remains exact.
fn diffStats(text: []const u8) DiffStats {
    var stats: DiffStats = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
            stats.added += 1;
        } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
            stats.removed += 1;
        } else if (std.mem.startsWith(u8, line, "… ") and std.mem.endsWith(u8, line, " more new lines")) {
            const count = line["… ".len .. line.len - " more new lines".len];
            stats.added += std.fmt.parseInt(usize, count, 10) catch 0;
        }
    }
    return stats;
}

fn diffSummaryNote(alloc: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const intro = diffIntroNote(text) orelse return null;
    const stats = diffStats(text);
    if (stats.added == 0 and stats.removed == 0) return intro;
    return try std.fmt.allocPrint(alloc, "{s} · +{d} -{d}", .{ intro, stats.added, stats.removed });
}

pub fn appendToolResultLines(alloc: std.mem.Allocator, lines: *std.ArrayList(Line), rb: RenderBlock, tool_label: []const u8) !void {
    // Collapsed: show at most 8 lines — but a diff the agent
    // AUTHORED (edit/write tools) shows whole (up to 24) because
    // a truncated diff misleads. Diffs merely read via bash keep
    // diff coloring but the ordinary cap.
    const is_diff = isDiffOutput(rb.text);
    const authored = is_diff and isFileEditTool(tool_label);
    const max_shown: usize = if (authored) 24 else 8;
    const language = if (is_diff) diffLanguage(rb.text) else SyntaxLanguage.generic;
    var shown: usize = 0;
    var total: usize = 0;
    var diff_nums: DiffLineNumbers = .{};
    var first = true;
    var it = std.mem.splitScalar(u8, rb.text, '\n');
    while (it.next()) |l| {
        defer first = false;
        // An authored diff's intro line ("created x (96 bytes)") is rendered
        // as a dim note on the ⚙ line instead; the hunks speak for themselves.
        if (first and authored and rb.status == .ok and !std.mem.startsWith(u8, l, "@@ ")) continue;
        total += 1;
        if (shown < max_shown) {
            if (rb.status == .ok and is_diff) {
                if (try appendDiffLine(alloc, lines, "    ", l, language, Palette.tool_out, &diff_nums))
                    shown += 1
                else
                    total -= 1;
                continue;
            } else if (rb.status != .ok) {
                // One failure marker establishes the section;
                // repeating it for every stack-frame line creates
                // a solid red wall with no visual hierarchy.
                const prefix: []const u8 = if (shown == 0) switch (rb.status) {
                    .err => "    ✗ ",
                    .denied => "    ⊘ ",
                    .interrupted => "    ⏹ ",
                    .ok => unreachable,
                } else "      ";
                const salient = isSalientToolErrorLine(l) or
                    (rb.status == .denied and shown == 0);
                try lines.append(alloc, .{
                    .text = prefix,
                    .style = if (shown == 0) Palette.tool_err else Palette.tool_out,
                    .text2 = l,
                    .style2 = if (salient) Palette.tool_err else Palette.tool_out,
                });
            } else {
                const glyph = "    ";
                const git_syntax = try gitLogSpans(alloc, l, glyph.len);
                if (git_syntax.len > 0) {
                    try lines.append(alloc, .{
                        .text = glyph,
                        .style = Palette.tool_out,
                        .text2 = l,
                        .style2 = Palette.git_subject,
                        .syntax = git_syntax,
                    });
                } else {
                    const prefixed = try std.fmt.allocPrint(alloc, "{s}{s}", .{ glyph, l });
                    try lines.append(alloc, .{ .text = prefixed, .style = Palette.tool_out });
                }
            }
            shown += 1;
        }
    }
    if (total > shown) {
        const more = try std.fmt.allocPrint(alloc, "    … {d} more lines", .{total - shown});
        try lines.append(alloc, .{ .text = more, .style = Palette.tool_out });
    }
}

/// One completed tool batch: N consecutive same-turn calls followed by
/// their N results (approval/reasoning/note blocks may interleave). Results
/// are persisted in call order, so pairing is positional.
pub const ScannedBatch = struct {
    next: usize,
    complete: bool,
    ok_count: usize,
};

pub const ExpandPair = struct { call: usize, result: usize };

/// Scan the batch starting at `start`; pairs that must stay visible (failed
/// results, or author-diffs from the edit/write tools whose truncation would
/// mislead) are appended to `expand`.
pub fn scanToolBatch(
    alloc: std.mem.Allocator,
    blocks: []const RenderBlock,
    start: usize,
    expand: *std.ArrayList(ExpandPair),
) !ScannedBatch {
    const turn_id = blocks[start].turn_id;
    var calls_end = start;
    while (calls_end < blocks.len and
        blocks[calls_end].kind == .tool_call and
        blocks[calls_end].turn_id == turn_id) : (calls_end += 1)
    {}
    const call_count = calls_end - start;

    var matched: usize = 0;
    var ok_count: usize = 0;
    var i = calls_end;
    while (i < blocks.len and matched < call_count) : (i += 1) {
        switch (blocks[i].kind) {
            .approval, .reasoning, .system_note, .plan => {},
            .tool_result => {
                const call_idx = start + matched;
                const failed = blocks[i].status != .ok;
                const author_diff = isDiffOutput(blocks[i].text) and
                    isFileEditTool(blocks[call_idx].label);
                if (failed or author_diff) {
                    try expand.append(alloc, .{ .call = call_idx, .result = i });
                } else {
                    ok_count += 1;
                }
                matched += 1;
            },
            else => break,
        }
    }
    return .{ .next = i, .complete = matched == call_count, .ok_count = ok_count };
}

/// Emit and reset the accumulated "Ran N commands" summary. Deferred so
/// consecutive tool stretches merge across interleaved commentary cards
/// instead of stacking one summary line per provider round.
pub fn flushRanSummary(alloc: std.mem.Allocator, lines: *std.ArrayList(Line), pending: *usize) !void {
    if (pending.* == 0) return;
    try blankLine(alloc, lines);
    const summary = try std.fmt.allocPrint(alloc, "Ran {d} {s}", .{
        pending.*,
        if (pending.* == 1) "command" else "commands",
    });
    try lines.append(alloc, .{
        .text = "  • ",
        .style = Palette.note,
        .text2 = summary,
        .style2 = Palette.assistant,
        .text3 = " · ctrl+t to view transcript",
        .style3 = Palette.collapse_hint,
    });
    pending.* = 0;
}

const PlanTableWidths = struct { task: usize, time: usize };

fn planTableWidths(total: usize) PlanTableWidths {
    const time = @min(@as(usize, 10), @max(@as(usize, 7), total / 6));
    return .{ .task = total -| (time + 3), .time = time };
}

fn formatPlanDuration(alloc: std.mem.Allocator, duration_ms: u64) ![]const u8 {
    if (duration_ms == 0) return "";
    if (duration_ms < 1_000) return "<1s";
    const seconds = (duration_ms +| 500) / 1_000;
    if (seconds < 60) return std.fmt.allocPrint(alloc, "{d}s", .{seconds});
    const minutes = seconds / 60;
    if (minutes < 60)
        return std.fmt.allocPrint(alloc, "{d}m {d}s", .{ minutes, seconds % 60 });
    return std.fmt.allocPrint(alloc, "{d}h {d}m", .{ minutes / 60, minutes % 60 });
}

fn planBorder(
    alloc: std.mem.Allocator,
    widths: PlanTableWidths,
    left: []const u8,
    join: []const u8,
    right: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, left);
    for (0..widths.task) |_| try out.appendSlice(alloc, "─");
    try out.appendSlice(alloc, join);
    for (0..widths.time) |_| try out.appendSlice(alloc, "─");
    try out.appendSlice(alloc, right);
    return out.toOwnedSlice(alloc);
}

/// Only the latest completed revision appears in the transcript;
/// intermediate plan updates remain implementation detail.
fn visibleCompletedPlan(blocks: []const RenderBlock, index: usize) bool {
    if (index >= blocks.len or !completedPlan(blocks[index].plan_items)) return false;
    for (blocks[index + 1 ..]) |later| {
        if (later.kind == .plan) return false;
    }
    return true;
}

fn completedPlanDuration(items: []const block.PlanItem) u64 {
    var total: u64 = 0;
    for (items) |item| total +|= item.duration_ms;
    return total;
}

fn appendArchivedPlanTable(
    alloc: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    items: []const block.PlanItem,
    width: usize,
) !void {
    try blankLine(alloc, lines);
    if (width < 16) {
        for (items) |item| {
            const duration = try formatPlanDuration(alloc, item.duration_ms);
            const suffix = if (duration.len > 0)
                try std.fmt.allocPrint(alloc, "  {s}", .{duration})
            else
                "";
            try lines.append(alloc, .{
                .text = "  ✔ ",
                .style = Palette.plan_done_mark,
                .text2 = item.step,
                .style2 = Palette.plan_pending,
                .text3 = suffix,
                .style3 = Palette.plan_pending,
            });
        }
    } else {
        const widths = planTableWidths(width);
        try lines.append(alloc, .{
            .text = try planBorder(alloc, widths, "┌", "┬", "┐"),
            .style = Palette.plan_header,
        });
        for (items) |item| {
            const available = widths.task -| 3;
            const end = hardCellBreak(item.step, 0, available);
            const step = item.step[0..end];
            const left = try std.fmt.allocPrint(alloc, "│ ✔ {s}", .{step});
            const left_pad = try spaces(alloc, (widths.task + 1) -| displayWidth(left));
            const duration = try formatPlanDuration(alloc, item.duration_ms);
            const time_pad = try spaces(alloc, widths.time -| (displayWidth(duration) + 1));
            const row = try std.fmt.allocPrint(alloc, "{s}{s}│{s}{s} │", .{
                left, left_pad, time_pad, duration,
            });
            const middle = left.len + left_pad.len;
            const check_start = "│ ".len;
            const spans = try alloc.alloc(SyntaxSpan, 4);
            spans[0] = .{ .start = 0, .end = "│".len, .style = Palette.plan_header };
            spans[1] = .{ .start = check_start, .end = check_start + "✔".len, .style = Palette.plan_done_mark };
            spans[2] = .{ .start = middle, .end = middle + "│".len, .style = Palette.plan_header };
            spans[3] = .{ .start = row.len - "│".len, .end = row.len, .style = Palette.plan_header };
            try lines.append(alloc, .{
                .text = row,
                .style = Palette.plan_pending,
                .syntax = spans,
            });
        }
        try lines.append(alloc, .{
            .text = try planBorder(alloc, widths, "└", "┴", "┘"),
            .style = Palette.plan_header,
        });
    }

    const total_ms = completedPlanDuration(items);
    if (total_ms > 0) {
        const duration = try formatPlanDuration(alloc, total_ms);
        const summary = try std.fmt.allocPrint(alloc, "Completed {d} {s} in {s}", .{
            items.len,
            if (items.len == 1) "step" else "steps",
            duration,
        });
        try wrapPrefixed(alloc, lines, "  ✓ ", summary, Palette.note, width);
    }
}

pub const max_layout_lines: usize = 50_000;

pub const LineRange = struct {
    start: usize,
    len: usize,
};

pub const ApprovalView = struct {
    tool: []const u8,
    args: []const u8,
};

/// App-free input to transcript layout. The TUI owns the mutable caches and
/// supplies only the slices and scalar state needed for one frame.
pub const Transcript = struct {
    io: Io,
    blocks: []const RenderBlock,
    show_tool_transcript: bool,
    state: proto.SessionState,
    layout_epoch: u64,
    delta: []const u8,
    reasoning_delta: []const u8,
    spinner_frame: usize,
    turn_started_ms: i64,
    call_started_ms: i64,
    stream_bytes: u64,
    stream_quiet_ms: u64,
    stream_status_at_ms: i64,
    /// The TUI's TODO table supplies its own spinner and active-step timer;
    /// suppress this competing live-status row while that table is visible.
    show_working_ticker: bool = true,
    cwd: []const u8 = "",
    approval: ?ApprovalView,
    layout_cache: *LayoutCache,
    tail_layout_cache: *TailLayoutCache,
    stream_layout_cache: *StreamLayoutCache,
};

pub const InflightCall = struct { rb: *const RenderBlock, queued: usize };

/// The tool call executing right now. Within the active turn's tail (after
/// the last user_msg/steer), calls precede results in provider order.
pub fn currentInflightCall(blocks: []const RenderBlock) ?InflightCall {
    var start = blocks.len;
    while (start > 0) : (start -= 1) {
        const kind = blocks[start - 1].kind;
        if (kind == .user_msg or kind == .steer) break;
    }
    var calls: usize = 0;
    var results: usize = 0;
    for (blocks[start..]) |rb| switch (rb.kind) {
        .tool_call => calls += 1,
        .tool_result => results += 1,
        else => {},
    };
    if (calls <= results) return null;
    var seen: usize = 0;
    for (blocks[start..]) |*rb| {
        if (rb.kind != .tool_call) continue;
        if (seen == results) return .{ .rb = rb, .queued = calls - results - 1 };
        seen += 1;
    }
    return null;
}

/// Compact live telemetry for the transcript ticker. The returned text begins
/// with a separator so it can be appended directly to the Working label.
fn workingDetail(arena: std.mem.Allocator, transcript: *const Transcript) ![]const u8 {
    const elapsed_s: i64 = if (transcript.turn_started_ms > 0)
        @max(0, @divTrunc(nowWallMs(transcript.io) - transcript.turn_started_ms, 1000))
    else
        0;
    const elapsed = if (elapsed_s >= 60)
        try std.fmt.allocPrint(arena, " · {d}m {d}s", .{ @divTrunc(elapsed_s, 60), @mod(elapsed_s, 60) })
    else
        try std.fmt.allocPrint(arena, " · {d}s", .{elapsed_s});

    var detail = elapsed;
    const stream_fresh = transcript.stream_status_at_ms > 0 and
        nowWallMs(transcript.io) - transcript.stream_status_at_ms <
            (if (transcript.stream_bytes == 0) @as(i64, 15_000) else 3000);
    if (stream_fresh and currentInflightCall(transcript.blocks) == null) {
        const quiet_s = transcript.stream_quiet_ms / 1000;
        if (transcript.stream_bytes == 0) {
            detail = try std.fmt.allocPrint(arena, "{s} · waiting for provider · {d}s", .{
                elapsed, quiet_s,
            });
        } else if (quiet_s >= 3) {
            detail = try std.fmt.allocPrint(arena, "{s} · streaming {Bi:.1} · last token {d}s ago", .{
                elapsed, transcript.stream_bytes, quiet_s,
            });
        } else {
            detail = try std.fmt.allocPrint(arena, "{s} · streaming {Bi:.1}", .{
                elapsed, transcript.stream_bytes,
            });
        }
    }
    if (currentInflightCall(transcript.blocks)) |cur| {
        const arg_full = toolDisplayArg(cur.rb.label, cur.rb.text, transcript.cwd) orelse "";
        const arg = arg_full[0..utf8Floor(arg_full, @min(arg_full.len, 60))];
        const call_s: i64 = if (transcript.call_started_ms > 0)
            @max(0, @divTrunc(nowWallMs(transcript.io) - transcript.call_started_ms, 1000))
        else
            0;
        const sep: []const u8 = if (arg.len > 0) " " else "";
        const queued = if (cur.queued > 0)
            try std.fmt.allocPrint(arena, " (+{d} queued)", .{cur.queued})
        else
            "";
        detail = try std.fmt.allocPrint(arena, "{s} · {s}{s}{s} · {d}s{s}", .{
            elapsed, toolDisplayName(cur.rb.label), sep, arg, call_s, queued,
        });
    }
    return detail;
}

/// SECTION DISCIPLINE (the transcript's one spacing rule, pinned by the
/// "transcript spacing invariant" test): every section — prompt card,
/// assistant prose, reasoning line, Ran-N summary, expanded diff pair,
/// steer, note, compaction — requests exactly ONE leading blank through
/// blankLine (which dedupes and no-ops at the top). Dense tool rows stack
/// flush within a group, but the group start breathes like any section.
/// Renderers emit content only; nothing ever appends trailing air.
pub fn layoutBlockRange(
    alloc: std.mem.Allocator,
    transcript: *const Transcript,
    lines: *std.ArrayList(Line),
    start: usize,
    end: usize,
    w: usize,
    last_tool_label: *[]const u8,
    allow_fold: bool,
) !void {
    // A corrupt or unexpectedly pathological transcript must degrade to a
    // visible truncation, never an unbounded allocation loop in the TUI.
    const max_layout_steps = (end - start) *| 2 +| 1_024;
    var pending_ran: usize = 0;
    // Dense tool rows stack flush within a group; the group START gets one
    // blank like any other section. Tracks whether the last emitted row was
    // dense machinery (tool call/result/approval) or prose.
    var last_dense = false;
    var block_idx: usize = start;
    var layout_steps: usize = 0;
    while (block_idx < end) : (block_idx += 1) {
        if (layout_steps >= max_layout_steps or lines.items.len >= max_layout_lines) {
            try lines.append(alloc, .{
                .text = "  [transcript rendering truncated at safety limit]",
                .style = Palette.tool_err,
            });
            break;
        }
        layout_steps += 1;
        const rb = transcript.blocks[block_idx];
        if (!transcript.show_tool_transcript and rb.kind == .tool_call) {
            const blocks_all = transcript.blocks;
            // Fold completed batches into one summary, merging consecutive
            // batches of this turn. Failed pairs (and author-diffs) stay
            // visible INDIVIDUALLY — one failing sibling must not dump the
            // whole group into the transcript.
            var expand: std.ArrayList(ExpandPair) = .empty;
            var folded: usize = 0;
            var scan_idx = block_idx;
            var scan_end = block_idx;
            while (scan_idx < end and
                blocks_all[scan_idx].kind == .tool_call and
                blocks_all[scan_idx].turn_id == rb.turn_id)
            {
                const batch = try scanToolBatch(alloc, blocks_all, scan_idx, &expand);
                if (!batch.complete) break;
                folded += batch.ok_count;
                scan_end = batch.next;
                scan_idx = batch.next;
                if (expand.items.len > 0) break; // surface failures promptly
            }

            // A trailing call/batch with no results yet is still executing:
            // fold it into the summary line instead of flashing detail lines
            // that vanish when a fast command completes. Approval-parked
            // calls keep their detail line — the user must see what they
            // are deciding on.
            var running_count: usize = 0;
            var running_call_idx: usize = 0;
            if (allow_fold and transcript.state == .running and expand.items.len == 0 and
                scan_idx < blocks_all.len and
                blocks_all[scan_idx].kind == .tool_call and
                blocks_all[scan_idx].turn_id == rb.turn_id)
            {
                if (pendingToolBatch(blocks_all, scan_idx)) |batch| {
                    running_count = batch.count;
                    scan_end = blocks_all.len;
                } else {
                    var j = scan_idx + 1;
                    while (j < blocks_all.len and blocks_all[j].kind == .approval) : (j += 1) {}
                    if (j == blocks_all.len) {
                        running_count = 1;
                        running_call_idx = scan_idx;
                        scan_end = blocks_all.len;
                    }
                }
            }

            if (expand.items.len == 0 and running_count == 0 and folded > 0) {
                pending_ran += folded;
                if (scan_end > block_idx) {
                    block_idx = scan_end - 1;
                    continue;
                }
            }
            const total_ran = pending_ran + folded;
            if (total_ran > 0 or expand.items.len > 0 or running_count > 0) {
                pending_ran = 0;
                const summary = if (total_ran > 0)
                    try std.fmt.allocPrint(alloc, "Ran {d} {s}", .{
                        total_ran,
                        if (total_ran == 1) "command" else "commands",
                    })
                else if (running_count > 1)
                    try std.fmt.allocPrint(alloc, "Running {d} commands", .{running_count})
                else if (running_count == 1)
                    "Running"
                else
                    try std.fmt.allocPrint(alloc, "{d} {s} failed", .{
                        expand.items.len,
                        if (expand.items.len == 1) "command" else "commands",
                    });
                var hint: []const u8 = " · ctrl+t to view transcript";
                if (running_count == 1) {
                    const call = blocks_all[running_call_idx];
                    const hi = toolDisplayArg(call.label, call.text, transcript.cwd) orelse "";
                    const capped = hi[0..@min(hi.len, 60)];
                    hint = try std.fmt.allocPrint(alloc, " · {s} {s}{s}", .{
                        toolDisplayName(call.label),
                        capped,
                        if (capped.len < hi.len) "…" else "",
                    });
                } else if (total_ran > 0 and running_count > 1) {
                    hint = try std.fmt.allocPrint(alloc, " · running {d} more", .{running_count});
                }
                if (total_ran > 0 or running_count > 0) {
                    try blankLine(alloc, lines);
                    try lines.append(alloc, .{
                        .text = "  • ",
                        .style = Palette.note,
                        .text2 = summary,
                        .style2 = Palette.assistant,
                        .text3 = hint,
                        .style3 = Palette.collapse_hint,
                    });
                }
                for (expand.items) |pair| {
                    // Authored diffs and failures are sections the user reads,
                    // not machinery: give them air instead of hugging the
                    // summary line above.
                    try blankLine(alloc, lines);
                    const result = blocks_all[pair.result];
                    const note = if (result.status == .ok) try diffSummaryNote(alloc, result.text) else null;
                    try appendToolCallLine(alloc, lines, blocks_all[pair.call], transcript.cwd, w, note);
                    try appendToolResultLines(alloc, lines, result, blocks_all[pair.call].label);
                }
                // Whatever follows brings its own leading blank; nothing
                // in the transcript appends trailing air.
                last_dense = false;
                if (scan_end > block_idx) {
                    block_idx = scan_end - 1;
                    continue;
                }
            }
        }
        switch (rb.kind) {
            .user_msg => {
                try flushRanSummary(alloc, lines, &pending_ran);
                try blankLine(alloc, lines);
                try wrapPromptCard(alloc, lines, rb.text, w);
                if (rb.label.len > 0)
                    try wrapPrefixed(alloc, lines, "  ", rb.label, Palette.status_model, w);
            },
            .assistant_msg => {
                try flushRanSummary(alloc, lines, &pending_ran);
                try blankLine(alloc, lines);
                try wrapMarkdown(alloc, lines, rb.text, w);
            },
            .reasoning => {
                // Raw provider reasoning folds out of the default view: some
                // models (grok) fill it with drafted replies and summarizer
                // fragments, which reads as two narrators fighting. The
                // model's deliberate one-line narration (commentary=true)
                // stays; ctrl+t reveals everything.
                if (transcript.show_tool_transcript or rb.commentary) {
                    try blankLine(alloc, lines);
                    try wrapReasoningCard(alloc, lines, try clipText(alloc, rb.text, 280), w);
                }
            },
            .tool_call => {
                try flushRanSummary(alloc, lines, &pending_ran);
                if (!last_dense) try blankLine(alloc, lines);
                last_tool_label.* = rb.label;
                try appendToolCallLine(alloc, lines, rb, transcript.cwd, w, null);
            },
            .tool_result => try appendToolResultLines(alloc, lines, rb, last_tool_label.*),
            .approval => {
                const txt = try std.fmt.allocPrint(alloc, "    [approval: {s}]", .{rb.text});
                try wrapInto(alloc, lines, txt, .{ .text = txt, .style = Palette.note });
            },
            .steer => {
                try flushRanSummary(alloc, lines, &pending_ran);
                try blankLine(alloc, lines);
                try wrapPrefixed(alloc, lines, "  ↪ ", rb.text, Palette.steer, w);
            },
            .plan => {
                if (visibleCompletedPlan(transcript.blocks, block_idx)) {
                    try flushRanSummary(alloc, lines, &pending_ran);
                    try appendArchivedPlanTable(alloc, lines, rb.plan_items, w);
                }
            },
            .system_note => {
                if (block.isHandoverNote(rb.text)) {
                    try flushRanSummary(alloc, lines, &pending_ran);
                    try blankLine(alloc, lines);
                    try wrapPrefixed(alloc, lines, "  ", "handover for Claude Code", Palette.note, w);
                    try wrapMarkdown(alloc, lines, block.handoverBody(rb.text), w);
                } else {
                    try blankLine(alloc, lines);
                    const txt = try std.fmt.allocPrint(alloc, "[{s}]", .{try clipText(alloc, rb.text, 480)});
                    try wrapPrefixed(alloc, lines, "  ", txt, Palette.note, w);
                }
            },
            .compaction => {
                try flushRanSummary(alloc, lines, &pending_ran);
                try blankLine(alloc, lines);
                try wrapPrefixed(alloc, lines, "  ≋ ", "context compacted", Palette.note, w);
            },
        }
    }
    try flushRanSummary(alloc, lines, &pending_ran);
}

fn handoverInProgress(blocks: []const RenderBlock) bool {
    var awaiting_summary = false;
    for (blocks) |rb| {
        if (rb.kind != .system_note) continue;
        if (block.isHandoverAnnounce(rb.text)) awaiting_summary = true;
        if (block.isHandoverNote(rb.text)) awaiting_summary = false;
    }
    return awaiting_summary;
}

/// Blocks of COMPLETED turns are immutable layout input: collapse runs never
/// cross turn boundaries and folding only affects the active tail. Everything
/// before the final turn-id group (which also covers optimistic echoes) is
/// safe to bake into the layout cache.
pub fn stableBlockCount(transcript: *const Transcript) usize {
    const items = transcript.blocks;
    if (items.len == 0) return 0;
    if (transcript.state != .running and transcript.state != .awaiting_approval) {
        var has_pending = false;
        for (items) |item| has_pending = has_pending or item.pending_echo;
        if (!has_pending) return items.len;
    }
    const last_turn = items[items.len - 1].turn_id;
    var i = items.len;
    while (i > 0 and items[i - 1].turn_id == last_turn) i -= 1;
    return i;
}

fn rangeSeamNeedsBlank(stable_lines: []const Line, tail_lines: []const Line) bool {
    if (stable_lines.len == 0 or tail_lines.len == 0) return false;
    const last = stable_lines[stable_lines.len - 1];
    const first = tail_lines[0];
    const last_blank = last.text.len == 0 and last.text2.len == 0 and
        last.text3.len == 0 and last.fill_style == null;
    const first_blank = first.text.len == 0 and first.text2.len == 0 and
        first.text3.len == 0 and first.fill_style == null;
    return !last_blank and !first_blank;
}

/// Range occupied by the active turn's prompt card in the most recent
/// layoutLines result. The active turn starts with its user_msg; prompt-card
/// rows are the contiguous filled rows at the head of the mutable tail.
pub fn activePromptLineRange(transcript: *const Transcript) ?LineRange {
    if (transcript.state != .running and transcript.state != .awaiting_approval) return null;
    const stable = stableBlockCount(transcript);
    if (stable >= transcript.blocks.len or transcript.blocks[stable].kind != .user_msg) return null;

    const tail_lines = transcript.tail_layout_cache.lines.items;
    var len: usize = 0;
    while (len < tail_lines.len and tail_lines[len].fill_style != null) : (len += 1) {}
    if (len == 0) return null;
    return .{
        .start = transcript.layout_cache.lines.items.len +
            @intFromBool(rangeSeamNeedsBlank(transcript.layout_cache.lines.items, tail_lines)),
        .len = len,
    };
}

pub fn layoutLines(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    transcript: *Transcript,
    width: u16,
) !std.ArrayList(Line) {
    var lines: std.ArrayList(Line) = .empty;
    const w: usize = if (width == 0) 80 else width;

    // Completed turns bake once into the persistent cache; each frame then
    // costs O(active turn), not O(session). Any key change or epoch bump
    // (session switch, echo reconcile) rebuilds from scratch.
    const cache = transcript.layout_cache;
    if (cache.width != w or cache.expanded != transcript.show_tool_transcript or
        cache.epoch != transcript.layout_epoch or cache.covered > transcript.blocks.len)
    {
        cache.reset(gpa);
        cache.width = w;
        cache.expanded = transcript.show_tool_transcript;
        cache.epoch = transcript.layout_epoch;
    }
    const stable = stableBlockCount(transcript);
    if (stable > cache.covered) {
        const bake_alloc = try cache.allocator(gpa);
        const prev = cache.lines.items.len;
        var label = cache.label_state;
        try layoutBlockRange(bake_alloc, transcript, &cache.lines, cache.covered, stable, w, &label, false);
        cache.label_state = label;
        try resolveLineLinks(bake_alloc, cache.lines.items[prev..]);
        cache.covered = stable;
    }
    try lines.appendSlice(arena, cache.lines.items);

    const tail_cache = transcript.tail_layout_cache;
    if (tail_cache.start != cache.covered or tail_cache.end != transcript.blocks.len or
        tail_cache.width != w or tail_cache.expanded != transcript.show_tool_transcript or
        tail_cache.epoch != transcript.layout_epoch or tail_cache.state != transcript.state)
    {
        tail_cache.reset(gpa);
        tail_cache.start = cache.covered;
        tail_cache.end = transcript.blocks.len;
        tail_cache.width = w;
        tail_cache.expanded = transcript.show_tool_transcript;
        tail_cache.epoch = transcript.layout_epoch;
        tail_cache.state = transcript.state;
        if (tail_cache.start < tail_cache.end) {
            const tail_alloc = try tail_cache.allocator(gpa);
            var label_state = cache.label_state;
            try layoutBlockRange(tail_alloc, transcript, &tail_cache.lines, tail_cache.start, tail_cache.end, w, &label_state, true);
            try resolveLineLinks(tail_alloc, tail_cache.lines.items);
        }
    }
    // Seam between independently-built ranges: the tail is laid out into its
    // own empty list, so its first section's leading blank (a no-op at the
    // top of any range) must be restored here. Ranges split at turn
    // boundaries, so the seam is always a section start, never mid-group.
    if (rangeSeamNeedsBlank(lines.items, tail_cache.lines.items))
        try lines.append(arena, .{ .text = "", .style = .{} });
    try lines.appendSlice(arena, tail_cache.lines.items);

    // Streaming region: provider reasoning summaries are verbose by nature
    // (first-person deliberation), so the live view is a one-line ticker
    // showing only the freshest thought — not a growing wall. The durable
    // card at round end is clipped separately below.
    if (transcript.reasoning_delta.len > 0) {
        const tail = lastNonEmptyLine(transcript.reasoning_delta);
        const cap = @min(tail.len, w -| 8);
        try lines.append(arena, .{
            .text = "  · ",
            .style = Palette.reasoning_mark,
            .text2 = tail[0..utf8Floor(tail, cap)],
            .style2 = Palette.collapse_hint,
        });
    }
    if (transcript.delta.len > 0) {
        try blankLine(arena, &lines);
        try transcript.stream_layout_cache.update(gpa, transcript.delta, w);
        try transcript.stream_layout_cache.appendTo(arena, &lines);
    } else if (transcript.reasoning_delta.len == 0 and transcript.state == .running and transcript.show_working_ticker) {
        try blankLine(arena, &lines);
        const head = try std.fmt.allocPrint(arena, "{s} ", .{
            spinner_frames[transcript.spinner_frame % spinner_frames.len],
        });
        const word: []const u8 = if (handoverInProgress(transcript.blocks))
            "Generating handover…"
        else
            "Working…";
        const detail = try workingDetail(arena, transcript);
        try lines.append(arena, .{
            .text = head,
            .style = Palette.working,
            .text2 = word,
            .style2 = Palette.working,
            .text3 = detail,
            .style3 = Palette.collapse_hint,
            .syntax = try shimmerSpans(arena, word, head.len, transcript.spinner_frame),
        });
    }

    // Approval card.
    if (transcript.approval) |approval| {
        try blankLine(arena, &lines);
        const arg = toolDisplayArg(approval.tool, approval.args, transcript.cwd) orelse "";
        const card = try std.fmt.allocPrint(arena, "⚠ approve {s}{s}{s} ?  [y]es / [n]o", .{
            toolDisplayName(approval.tool),
            if (arg.len > 0) " " else "",
            arg,
        });
        try wrapPrefixed(arena, &lines, "", card, Palette.approval_card, w);
    }
    try resolveLineLinks(arena, lines.items);
    return lines;
}

pub fn extractHighlightArg(tool_name: []const u8, args_json: []const u8) ?[]const u8 {
    if (isFileTool(tool_name))
        return extractJsonStringRaw(args_json, "path") orelse
            extractJsonStringRaw(args_json, "file_path");
    if (std.ascii.eqlIgnoreCase(tool_name, "bash"))
        return extractJsonStringRaw(args_json, "command");
    if (std.ascii.eqlIgnoreCase(tool_name, "grep") or std.ascii.eqlIgnoreCase(tool_name, "glob"))
        return extractJsonStringRaw(args_json, "pattern");
    if (std.ascii.eqlIgnoreCase(tool_name, "fetch") or std.ascii.eqlIgnoreCase(tool_name, "webfetch"))
        return extractJsonStringRaw(args_json, "url");
    if (std.ascii.eqlIgnoreCase(tool_name, "websearch"))
        return extractJsonStringRaw(args_json, "query");
    if (std.ascii.eqlIgnoreCase(tool_name, "task"))
        return extractJsonStringRaw(args_json, "description") orelse
            extractJsonStringRaw(args_json, "prompt");
    if (std.mem.eql(u8, tool_name, "plan_update"))
        return extractJsonStringRaw(args_json, "explanation");
    for ([_][]const u8{ "path", "file_path", "command", "pattern", "url", "query", "description", "prompt" }) |key| {
        if (extractJsonStringRaw(args_json, key)) |value| return value;
    }
    return null;
}

fn isReadTool(tool_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tool_name, "read") or
        std.mem.eql(u8, tool_name, "read_file");
}

fn isFileTool(tool_name: []const u8) bool {
    return isReadTool(tool_name) or
        std.ascii.eqlIgnoreCase(tool_name, "write") or
        std.mem.eql(u8, tool_name, "write_file") or
        std.ascii.eqlIgnoreCase(tool_name, "edit");
}

pub fn toolDisplayName(tool_name: []const u8) []const u8 {
    if (isReadTool(tool_name)) return "Read";
    if (std.ascii.eqlIgnoreCase(tool_name, "write") or std.mem.eql(u8, tool_name, "write_file")) return "Write";
    if (std.ascii.eqlIgnoreCase(tool_name, "edit")) return "Edit";
    if (std.ascii.eqlIgnoreCase(tool_name, "bash")) return "Bash";
    if (std.ascii.eqlIgnoreCase(tool_name, "grep")) return "Grep";
    if (std.ascii.eqlIgnoreCase(tool_name, "glob")) return "Glob";
    if (std.ascii.eqlIgnoreCase(tool_name, "fetch") or std.ascii.eqlIgnoreCase(tool_name, "webfetch")) return "Fetch";
    if (std.ascii.eqlIgnoreCase(tool_name, "websearch")) return "Search";
    if (std.ascii.eqlIgnoreCase(tool_name, "task")) return "Task";
    if (std.mem.eql(u8, tool_name, "task_batch")) return "Tasks";
    if (std.mem.eql(u8, tool_name, "plan_update")) return "Plan";
    return tool_name;
}

/// Reduce file-tool targets to session-relative paths. Absolute targets
/// outside the session retain only their basename rather than filling the
/// transcript with a machine-specific prefix.
pub fn toolDisplayArg(tool_name: []const u8, args_json: []const u8, cwd: []const u8) ?[]const u8 {
    const arg = extractHighlightArg(tool_name, args_json) orelse return null;
    const generic_path = extractJsonStringRaw(args_json, "path") orelse
        extractJsonStringRaw(args_json, "file_path");
    const is_path = isFileTool(tool_name) or
        (generic_path != null and generic_path.?.ptr == arg.ptr and generic_path.?.len == arg.len);
    if (!is_path or !std.fs.path.isAbsolute(arg)) return arg;

    const root = if (std.mem.eql(u8, cwd, "/")) cwd else std.mem.trimEnd(u8, cwd, "/");
    if (root.len > 0 and std.mem.startsWith(u8, arg, root)) {
        if (arg.len == root.len) return ".";
        if (std.mem.eql(u8, root, "/")) return arg[1..];
        if (arg[root.len] == '/') return arg[root.len + 1 ..];
    }
    return std.fs.path.basename(arg);
}

/// Find "key":"..." and return the raw (still-escaped) string contents.
pub fn extractJsonStringRaw(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    var at = std.mem.indexOf(u8, json, needle) orelse return null;
    at += needle.len;
    while (at < json.len and (json[at] == ' ' or json[at] == '\t')) at += 1;
    if (at >= json.len or json[at] != '"') return null;
    at += 1;
    var end = at;
    while (end < json.len) : (end += 1) {
        if (json[end] == '\\') {
            end += 1;
            continue;
        }
        if (json[end] == '"') break;
    }
    if (end > json.len) return null;
    return json[at..end];
}

test "reasoning cards leave one separator row between transcript landmarks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;

    try wrapPromptCard(arena, &lines, "request", 80);
    try wrapReasoningCard(arena, &lines, "first update", 80);
    try wrapReasoningCard(arena, &lines, "second update", 80);
    try lines.append(arena, .{
        .text = "  • ",
        .style = Palette.note,
        .text2 = "Ran 6 commands",
        .style2 = Palette.assistant,
    });

    for (lines.items[1..], 1..) |line, i| {
        const previous = lines.items[i - 1];
        const previous_empty = previous.text.len == 0 and previous.text2.len == 0 and previous.text3.len == 0;
        const current_empty = line.text.len == 0 and line.text2.len == 0 and line.text3.len == 0;
        try std.testing.expect(!(previous_empty and current_empty));
    }
}

test "tool calls render semantic arguments instead of raw JSON" {
    const cwd = "/Users/example/Work/marlin";
    const args =
        \\{"file_path":"/Users/example/Work/marlin/src/client/layout.zig","offset":20}
    ;
    try std.testing.expectEqualStrings("Read", toolDisplayName("Read"));
    try std.testing.expectEqualStrings("Read", toolDisplayName("read_file"));
    try std.testing.expectEqualStrings("Edit", toolDisplayName("edit"));
    try std.testing.expectEqualStrings("Write", toolDisplayName("write_file"));
    try std.testing.expectEqualStrings("Bash", toolDisplayName("bash"));
    try std.testing.expectEqualStrings("src/client/layout.zig", toolDisplayArg("Read", args, cwd).?);
    try std.testing.expectEqualStrings("src/client/layout.zig", toolDisplayArg("Edit",
        \\{"file_path":"/Users/example/Work/marlin/src/client/layout.zig","old_string":"x","new_string":"y"}
    , cwd).?);
    try std.testing.expectEqualStrings("zig build test", toolDisplayArg("Bash",
        \\{"command":"zig build test","description":"verify"}
    , cwd).?);
    try std.testing.expectEqualStrings("src/main.zig", toolDisplayArg("mcp_read_source",
        \\{"path":"/Users/example/Work/marlin/src/main.zig"}
    , cwd).?);
    try std.testing.expectEqualStrings("secrets.txt", toolDisplayArg("Read",
        \\{"file_path":"/outside/private/secrets.txt"}
    , cwd).?);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try appendToolCallLine(arena, &lines, .{
        .kind = .tool_call,
        .text = try arena.dupe(u8, args),
        .label = try arena.dupe(u8, "Read"),
    }, cwd, 100, null);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("  ⚙ Read ", lines.items[0].text);
    try std.testing.expectEqualStrings("src/client/layout.zig", lines.items[0].text2);
    try std.testing.expect(std.mem.indexOfScalar(u8, lines.items[0].text2, '{') == null);

    lines.clearRetainingCapacity();
    try appendToolCallLine(arena, &lines, .{
        .kind = .tool_call,
        .text = try arena.dupe(u8, "{malformed}"),
        .label = try arena.dupe(u8, "Read"),
    }, cwd, 100, null);
    try std.testing.expectEqualStrings("", lines.items[0].text2);

    lines.clearRetainingCapacity();
    try appendToolCallLine(arena, &lines, .{
        .kind = .tool_call,
        .text = try arena.dupe(u8, "{\"anything\":\"still private\"}"),
        .label = try arena.dupe(u8, "custom_tool"),
    }, cwd, 100, null);
    try std.testing.expectEqualStrings("  ⚙ custom_tool ", lines.items[0].text);
    try std.testing.expectEqualStrings("", lines.items[0].text2);
}

test "diff intro notes distill to counts for the tool line" {
    try std.testing.expectEqualStrings("96 bytes", diffIntroNote("created /tmp/a.zig (96 bytes)\n@@ -0,0 +1,5 @@").?);
    try std.testing.expectEqualStrings("2 hunks", diffIntroNote("edited 2 hunks in src/x.zig\n@@ -1 +1 @@").?);
    try std.testing.expectEqualStrings("84 bytes", diffIntroNote("wrote 84 bytes to x\n@@ -1 +1 @@").?);
    try std.testing.expectEqualStrings("1 occurrence(s)", diffIntroNote("replaced 1 occurrence(s) in x\n@@ -1 +1 @@").?);
    try std.testing.expect(diffIntroNote("The file has been updated successfully.") == null);
}

test "authored diff notes include exact colored diffstats" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const native =
        "replaced 1 occurrence(s) in src/x.zig\n" ++
        "@@ -1,2 +1,3 @@\n" ++
        "-old\n" ++
        "+new\n" ++
        "+another";
    try std.testing.expectEqualStrings("1 occurrence(s) · +2 -1", (try diffSummaryNote(arena, native)).?);

    const guest =
        "edited 2 hunks in src/x.zig\n" ++
        "@@ -1 +1 @@\n-old\n+new\n" ++
        "@@ -8,2 +8,3 @@\n-gone\n+first\n+second";
    try std.testing.expectEqualStrings("2 hunks · +3 -2", (try diffSummaryNote(arena, guest)).?);

    const creation =
        "created src/big.zig (1000 bytes)\n" ++
        "@@ -0,0 +1,43 @@\n+one\n+two\n… 41 more new lines";
    try std.testing.expectEqualStrings("1000 bytes · +43 -0", (try diffSummaryNote(arena, creation)).?);

    var lines: std.ArrayList(Line) = .empty;
    try appendToolCallLine(arena, &lines, .{
        .kind = .tool_call,
        .text = try arena.dupe(u8, "{\"path\":\"src/x.zig\"}"),
        .label = try arena.dupe(u8, "edit"),
    }, "/repo", 100, "1 occurrence(s) · +18 -5");
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].syntax.len);
    try std.testing.expect(vaxis.Color.eql(Palette.diff_add.fg, lines.items[0].syntax[0].style.fg));
    try std.testing.expect(vaxis.Color.eql(Palette.diff_del.fg, lines.items[0].syntax[1].style.fg));
    try std.testing.expect(lines.items[0].syntax[0].style.bold);
    try std.testing.expect(lines.items[0].syntax[1].style.bold);
}

pub fn hunkContextStart(line: []const u8) ?usize {
    if (!std.mem.startsWith(u8, line, "@@")) return null;
    const close = std.mem.indexOfPos(u8, line, 2, "@@") orelse return null;
    var start = close + 2;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    return if (start < line.len) start else null;
}

/// Turn a raw unified-diff line into a gutter + code row. Changed rows carry
/// a subtle full-width surface; syntax is an independent foreground overlay.
/// Line-number gutter state for a streamed diff: seeded by each @@ hunk
/// header, advanced per rendered line. Adds/context show the NEW file's
/// number, deletions the OLD one; inactive (no header seen) renders none.
pub const DiffLineNumbers = struct {
    old: usize = 0,
    new: usize = 0,
    active: bool = false,

    pub fn onHunk(self: *DiffLineNumbers, line: []const u8) void {
        self.active = false;
        const minus = std.mem.indexOfScalar(u8, line, '-') orelse return;
        const plus = std.mem.indexOfScalarPos(u8, line, minus, '+') orelse return;
        self.old = parseLeadingInt(line[minus + 1 ..]) orelse return;
        self.new = parseLeadingInt(line[plus + 1 ..]) orelse return;
        self.active = true;
    }

    pub fn parseLeadingInt(text: []const u8) ?usize {
        var end: usize = 0;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        if (end == 0) return null;
        return std.fmt.parseInt(usize, text[0..end], 10) catch null;
    }
};

/// Returns whether a display line was appended: @@ headers feed the
/// line-number gutter but render at most their enclosing-declaration
/// context — the raw hunk arithmetic is machinery the gutter replaces.
pub fn appendDiffLine(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    glyph: []const u8,
    line: []const u8,
    language: SyntaxLanguage,
    fallback_style: vaxis.Style,
    nums: *DiffLineNumbers,
) !bool {
    if (std.mem.startsWith(u8, line, "@@ ")) {
        nums.onHunk(line);
        const start = hunkContextStart(line) orelse return false;
        const head = try std.fmt.allocPrint(arena, "{s}… ", .{glyph});
        try lines.append(arena, .{
            .text = head,
            .style = Palette.diff_hunk,
            .text2 = line[start..],
            .style2 = Palette.diff_hunk,
            .syntax = try syntaxSpans(arena, line[start..], language, head.len),
        });
        return true;
    }

    const is_add = std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++");
    const is_del = std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---");
    const is_context = std.mem.startsWith(u8, line, " ");
    if (is_add or is_del or is_context) {
        var number: usize = 0;
        if (nums.active) {
            if (is_add) {
                number = nums.new;
                nums.new += 1;
            } else if (is_del) {
                number = nums.old;
                nums.old += 1;
            } else {
                number = nums.new;
                nums.new += 1;
                nums.old += 1;
            }
        }
        const gutter = if (nums.active)
            try std.fmt.allocPrint(arena, "{s}{d:>4} {c}", .{ glyph, number, line[0] })
        else
            try std.fmt.allocPrint(arena, "{s}{c}", .{ glyph, line[0] });
        const code = line[1..];
        const code_style = if (is_add)
            Palette.diff_add_code
        else if (is_del)
            Palette.diff_del_code
        else
            Palette.diff_context;
        const marker_style = if (is_add)
            Palette.diff_add
        else if (is_del)
            Palette.diff_del
        else
            Palette.diff_context;
        const syntax = try syntaxSpans(arena, code, language, gutter.len);
        try lines.append(arena, .{
            .text = gutter,
            .style = marker_style,
            .text2 = code,
            .style2 = code_style,
            .fill_style = if (is_add or is_del) code_style else null,
            .syntax = syntax,
        });
        return true;
    }

    const text = try std.fmt.allocPrint(arena, "{s}{s}", .{ glyph, line });
    try lines.append(arena, .{ .text = text, .style = fallback_style });
    return true;
}

test "successful tools collapse but diffs and failures stop the run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]RenderBlock{
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "grep") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "one match"), .label = try arena.dupe(u8, "") },
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "read_file") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "contents"), .label = try arena.dupe(u8, "") },
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "edit") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "@@ fn main()\n-old\n+new"), .label = try arena.dupe(u8, "") },
    };

    var expand: std.ArrayList(ExpandPair) = .empty;
    defer expand.deinit(arena);
    const first = try scanToolBatch(arena, &blocks, 0, &expand);
    try std.testing.expectEqual(@as(usize, 1), first.ok_count);
    try std.testing.expectEqual(@as(usize, 2), first.next);
    const second = try scanToolBatch(arena, &blocks, 2, &expand);
    try std.testing.expectEqual(@as(usize, 1), second.ok_count);
    try std.testing.expect(expand.items.len == 0);
    // The edit diff must stay visible: zero foldable, one expanded pair.
    const third = try scanToolBatch(arena, &blocks, 4, &expand);
    try std.testing.expectEqual(@as(usize, 0), third.ok_count);
    try std.testing.expectEqual(@as(usize, 1), expand.items.len);
    try std.testing.expectEqual(@as(usize, 4), expand.items[0].call);

    // Guest sessions label the same authored change "Edit" (Claude Code
    // vocabulary); it must stop the run exactly like the native "edit".
    const guest = [_]RenderBlock{
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "Edit") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "edited 1 hunk in a.zig\n@@ -1 +1 @@\n-old\n+new"), .label = try arena.dupe(u8, "") },
    };
    var guest_expand: std.ArrayList(ExpandPair) = .empty;
    defer guest_expand.deinit(arena);
    const guest_batch = try scanToolBatch(arena, &guest, 0, &guest_expand);
    try std.testing.expectEqual(@as(usize, 0), guest_batch.ok_count);
    try std.testing.expectEqual(@as(usize, 1), guest_expand.items.len);
}

test "diffs merely read via bash collapse like any other success" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]RenderBlock{
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "bash") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new"), .label = try arena.dupe(u8, "") },
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "grep") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "one match"), .label = try arena.dupe(u8, "") },
    };

    // The bash `git diff` output looks like a diff but the agent changed
    // nothing — it folds like any other success.
    var expand: std.ArrayList(ExpandPair) = .empty;
    defer expand.deinit(arena);
    const batch = try scanToolBatch(arena, &blocks, 0, &expand);
    try std.testing.expectEqual(@as(usize, 1), batch.ok_count);
    try std.testing.expect(expand.items.len == 0);
}

test "tool collapse never crosses a durable turn boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]RenderBlock{
        .{ .kind = .tool_call, .turn_id = 11, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "grep") },
        .{ .kind = .tool_result, .turn_id = 11, .text = try arena.dupe(u8, "match"), .label = try arena.dupe(u8, "") },
        .{ .kind = .tool_call, .turn_id = 12, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "read_file") },
        .{ .kind = .tool_result, .turn_id = 12, .text = try arena.dupe(u8, "contents"), .label = try arena.dupe(u8, "") },
    };

    var expand: std.ArrayList(ExpandPair) = .empty;
    defer expand.deinit(arena);
    const batch = try scanToolBatch(arena, &blocks, 0, &expand);
    try std.testing.expectEqual(@as(usize, 1), batch.ok_count);
    try std.testing.expectEqual(@as(usize, 2), batch.next);
}

test "stream layout is append-only and matches a one-shot provisional wrap" {
    const gpa = std.testing.allocator;
    const source =
        "This is a deliberately long streamed paragraph with enough words to wrap several times " ++
        "without reconsidering the completed rows on every provider delta.\n\n" ++
        "A second line keeps the prose rail stable while the durable block will later render **Markdown**.";

    var incremental = StreamLayoutCache{};
    defer incremental.reset(gpa);
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    var at: usize = 0;
    while (at < source.len) {
        const end = @min(at + 7, source.len);
        try received.appendSlice(gpa, source[at..end]);
        try incremental.update(gpa, received.items, 52);
        at = end;
    }
    try std.testing.expectEqual(source.len, incremental.source_len);
    try std.testing.expect(incremental.lines.items.len > 2);

    var one_shot = StreamLayoutCache{};
    defer one_shot.reset(gpa);
    try one_shot.update(gpa, source, 52);

    const Render = struct {
        fn text(gpa_inner: std.mem.Allocator, cache: *const StreamLayoutCache) ![]u8 {
            var arena_state = std.heap.ArenaAllocator.init(gpa_inner);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var lines: std.ArrayList(Line) = .empty;
            try cache.appendTo(arena, &lines);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa_inner);
            for (lines.items) |line| {
                try out.appendSlice(gpa_inner, try lineText(arena, line));
                try out.append(gpa_inner, '\n');
            }
            return out.toOwnedSlice(gpa_inner);
        }
    };
    const incremental_text = try Render.text(gpa, &incremental);
    defer gpa.free(incremental_text);
    const one_shot_text = try Render.text(gpa, &one_shot);
    defer gpa.free(one_shot_text);
    try std.testing.expectEqualStrings(one_shot_text, incremental_text);

    // A finalized/error-cleared delta restarts the cache instead of retaining
    // either its copied rows or a stale source cursor.
    try incremental.update(gpa, "", 52);
    try std.testing.expectEqual(@as(usize, 0), incremental.source_len);
    try std.testing.expectEqual(@as(usize, 0), incremental.lines.items.len);
}

test "layout line safety limit produces a visible truncation" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const blocks = [_]RenderBlock{.{
        .kind = .system_note,
        .text = @constCast("after limit"),
        .label = @constCast(""),
    }};
    var cache = LayoutCache{};
    defer cache.reset(gpa);
    var tail = TailLayoutCache{};
    defer tail.reset(gpa);
    var stream = StreamLayoutCache{};
    defer stream.reset(gpa);
    var transcript = Transcript{
        .io = threaded.io(),
        .blocks = &blocks,
        .show_tool_transcript = false,
        .state = .idle,
        .layout_epoch = 0,
        .delta = "",
        .reasoning_delta = "",
        .spinner_frame = 0,
        .turn_started_ms = 0,
        .call_started_ms = 0,
        .stream_bytes = 0,
        .stream_quiet_ms = 0,
        .stream_status_at_ms = 0,
        .approval = null,
        .layout_cache = &cache,
        .tail_layout_cache = &tail,
        .stream_layout_cache = &stream,
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try lines.resize(arena, max_layout_lines);
    var label: []const u8 = "";
    try layoutBlockRange(arena, &transcript, &lines, 0, 1, 120, &label, false);
    try std.testing.expectEqual(max_layout_lines + 1, lines.items.len);
    try std.testing.expectEqualStrings(
        "  [transcript rendering truncated at safety limit]",
        lines.items[lines.items.len - 1].text,
    );
}

test "active prompt range identifies the running turn card" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const blocks = [_]RenderBlock{
        .{ .kind = .user_msg, .turn_id = 1, .text = @constCast("old prompt"), .label = @constCast("") },
        .{ .kind = .assistant_msg, .turn_id = 1, .text = @constCast("old answer"), .label = @constCast("") },
        .{ .kind = .user_msg, .turn_id = 2, .text = @constCast("keep this visible"), .label = @constCast("") },
        .{ .kind = .reasoning, .turn_id = 2, .text = @constCast("working below it"), .label = @constCast(""), .commentary = true },
    };
    var cache = LayoutCache{};
    defer cache.reset(gpa);
    var tail = TailLayoutCache{};
    defer tail.reset(gpa);
    var stream = StreamLayoutCache{};
    defer stream.reset(gpa);
    var transcript = Transcript{
        .io = threaded.io(),
        .blocks = &blocks,
        .show_tool_transcript = false,
        .state = .running,
        .layout_epoch = 0,
        .delta = "",
        .reasoning_delta = "",
        .spinner_frame = 0,
        .turn_started_ms = 0,
        .call_started_ms = 0,
        .stream_bytes = 0,
        .stream_quiet_ms = 0,
        .stream_status_at_ms = 0,
        .approval = null,
        .layout_cache = &cache,
        .tail_layout_cache = &tail,
        .stream_layout_cache = &stream,
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), gpa, &transcript, 80);
    const prompt = activePromptLineRange(&transcript).?;
    try std.testing.expect(prompt.start > 0);
    try std.testing.expectEqual(@as(usize, 3), prompt.len);
    try std.testing.expect(lines.items[prompt.start].fill_style != null);
    try std.testing.expectEqualStrings("keep this visible", lines.items[prompt.start + 1].text2);
    try std.testing.expect(lines.items[prompt.start + prompt.len].fill_style == null);

    transcript.state = .idle;
    try std.testing.expect(activePromptLineRange(&transcript) == null);
}

test "completed plan moves immediately into transcript with timing summary" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var first_items = [_]block.PlanItem{
        .{ .step = "Inspect", .status = .completed, .duration_ms = 18_400 },
        .{ .step = "Implement", .status = .completed, .duration_ms = 65_000 },
    };
    var final_items = [_]block.PlanItem{
        .{ .step = "Inspect", .status = .completed, .duration_ms = 18_400 },
        .{ .step = "Implement", .status = .completed, .duration_ms = 68_000 },
    };
    const blocks = [_]RenderBlock{
        .{ .kind = .plan, .turn_id = 1, .text = @constCast(""), .label = @constCast(""), .plan_items = &first_items },
        .{ .kind = .plan, .turn_id = 1, .text = @constCast(""), .label = @constCast(""), .plan_items = &final_items },
        .{ .kind = .assistant_msg, .turn_id = 1, .text = @constCast("Implemented and verified the change."), .label = @constCast("") },
    };
    var cache = LayoutCache{};
    defer cache.reset(gpa);
    var tail = TailLayoutCache{};
    defer tail.reset(gpa);
    var stream = StreamLayoutCache{};
    defer stream.reset(gpa);
    var transcript = Transcript{
        .io = threaded.io(),
        .blocks = &blocks,
        .show_tool_transcript = false,
        .state = .running,
        .layout_epoch = 0,
        .delta = "",
        .reasoning_delta = "",
        .spinner_frame = 0,
        .turn_started_ms = 0,
        .call_started_ms = 0,
        .stream_bytes = 0,
        .stream_quiet_ms = 0,
        .stream_status_at_ms = 0,
        .approval = null,
        .layout_cache = &cache,
        .tail_layout_cache = &tail,
        .stream_layout_cache = &stream,
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var archived_lines: std.ArrayList(Line) = .empty;
    var label: []const u8 = "";
    transcript.blocks = &blocks;
    try layoutBlockRange(arena, &transcript, &archived_lines, 0, blocks.len, 80, &label, false);
    var top_count: usize = 0;
    var bottom_count: usize = 0;
    var saw_latest_duration = false;
    var saw_summary = false;
    var saw_recap = false;
    var summary_line: ?usize = null;
    var recap_line: ?usize = null;
    for (archived_lines.items, 0..) |line, index| {
        if (std.mem.startsWith(u8, line.text, "┌")) top_count += 1;
        if (std.mem.startsWith(u8, line.text, "└")) bottom_count += 1;
        if (std.mem.indexOf(u8, line.text, "1m 8s") != null) saw_latest_duration = true;
        if (std.mem.indexOf(u8, line.text, "Completed 2 steps in 1m 26s") != null) {
            saw_summary = true;
            summary_line = index;
        }
        if (std.mem.indexOf(u8, line.text, "Implemented and verified the change.") != null) {
            saw_recap = true;
            recap_line = index;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), top_count);
    try std.testing.expectEqual(@as(usize, 1), bottom_count);
    try std.testing.expect(saw_latest_duration);
    try std.testing.expect(saw_summary);
    try std.testing.expect(saw_recap);
    try std.testing.expect(summary_line.? < recap_line.?);
}

test "current in-flight call follows calls-first result order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var blocks = std.ArrayList(RenderBlock).empty;

    try blocks.append(arena, .{ .kind = .tool_call, .text = try arena.dupe(u8, "old"), .label = try arena.dupe(u8, "bash") });
    try blocks.append(arena, .{ .kind = .user_msg, .text = try arena.dupe(u8, "do things"), .label = try arena.dupe(u8, "") });
    try std.testing.expect(currentInflightCall(blocks.items) == null);

    try blocks.append(arena, .{ .kind = .tool_call, .text = try arena.dupe(u8, "first"), .label = try arena.dupe(u8, "read_file") });
    try blocks.append(arena, .{ .kind = .tool_call, .text = try arena.dupe(u8, "second"), .label = try arena.dupe(u8, "grep") });
    const first = currentInflightCall(blocks.items).?;
    try std.testing.expectEqualStrings("first", first.rb.text);
    try std.testing.expectEqual(@as(usize, 1), first.queued);

    try blocks.append(arena, .{ .kind = .tool_result, .text = try arena.dupe(u8, "done"), .label = try arena.dupe(u8, "") });
    const second = currentInflightCall(blocks.items).?;
    try std.testing.expectEqualStrings("second", second.rb.text);
    try std.testing.expectEqual(@as(usize, 0), second.queued);

    try blocks.append(arena, .{ .kind = .tool_result, .text = try arena.dupe(u8, "done"), .label = try arena.dupe(u8, "") });
    try std.testing.expect(currentInflightCall(blocks.items) == null);
}

test "handover notes render in full instead of a clipped system card" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const long_body = "A" ** 600;
    const note = try std.fmt.allocPrint(gpa, "{s}{s}", .{ block.handover_prefix, long_body });
    defer gpa.free(note);
    const blocks = [_]RenderBlock{.{
        .kind = .system_note,
        .text = note,
        .label = "",
    }};
    var cache = LayoutCache{};
    defer cache.reset(gpa);
    var tail = TailLayoutCache{};
    defer tail.reset(gpa);
    var stream = StreamLayoutCache{};
    defer stream.reset(gpa);
    var transcript = Transcript{
        .io = threaded.io(),
        .blocks = &blocks,
        .show_tool_transcript = false,
        .state = .idle,
        .layout_epoch = 0,
        .delta = "",
        .reasoning_delta = "",
        .spinner_frame = 0,
        .turn_started_ms = 0,
        .call_started_ms = 0,
        .stream_bytes = 0,
        .stream_quiet_ms = 0,
        .stream_status_at_ms = 0,
        .approval = null,
        .layout_cache = &cache,
        .tail_layout_cache = &tail,
        .stream_layout_cache = &stream,
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    var label: []const u8 = "";
    try layoutBlockRange(arena, &transcript, &lines, 0, 1, 80, &label, false);
    var joined: std.ArrayList(u8) = .empty;
    for (lines.items) |line| try joined.appendSlice(arena, line.text);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "handover for Claude Code") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "AAAA") != null);
}

test "handover in progress uses the generating-handover working word" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const blocks = [_]RenderBlock{.{
        .kind = .system_note,
        .text = @constCast("Switching to Claude Code (claudecode/fable). Generating a handover summary with the current model…"),
        .label = @constCast(""),
    }};
    var cache = LayoutCache{};
    defer cache.reset(gpa);
    var tail = TailLayoutCache{};
    defer tail.reset(gpa);
    var stream = StreamLayoutCache{};
    defer stream.reset(gpa);
    var transcript = Transcript{
        .io = threaded.io(),
        .blocks = &blocks,
        .show_tool_transcript = false,
        .state = .running,
        .layout_epoch = 0,
        .delta = "",
        .reasoning_delta = "",
        .spinner_frame = 0,
        .turn_started_ms = 0,
        .call_started_ms = 0,
        .stream_bytes = 0,
        .stream_quiet_ms = 0,
        .stream_status_at_ms = 0,
        .approval = null,
        .layout_cache = &cache,
        .tail_layout_cache = &tail,
        .stream_layout_cache = &stream,
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), gpa, &transcript, 80);
    var found = false;
    for (lines.items) |line| {
        if (std.mem.indexOf(u8, line.text, "Generating handover") != null or
            std.mem.indexOf(u8, line.text2, "Generating handover") != null)
            found = true;
    }
    try std.testing.expect(found);

    transcript.show_working_ticker = false;
    const absorbed = try layoutLines(arena_state.allocator(), gpa, &transcript, 80);
    for (absorbed.items) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line.text, "Generating handover") == null);
        try std.testing.expect(std.mem.indexOf(u8, line.text2, "Generating handover") == null);
    }
}

test {
    std.testing.refAllDecls(@This());
}
