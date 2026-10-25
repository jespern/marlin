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
const shellDisplayCommand = render.shellDisplayCommand;
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
    timestamp_ms: ?i64 = null,
    kind: block.BlockKind,
    /// Durable identity from the block log. Zero marks an optimistic local
    /// echo that will be reconciled when the daemon block arrives.
    seq: u64 = 0,
    turn_id: u64 = 0,
    /// Primary text (message text, tool output, note...).
    text: []u8,
    /// tool_call: "name" — used for the collapsed header line.
    label: []u8,
    call_id: []u8 = &.{},
    /// Terminal completed plan revision. Intermediate revisions stay in the
    /// pinned App plan only; retaining all of them would waste memory and
    /// render duplicate historical tables.
    plan_items: []block.PlanItem = &.{},
    status: block.ToolStatus = .ok,
    /// Content-addressed uncapped tool output. Null means `text` is already
    /// the complete result and can be copied without another daemon query.
    full_body_ref: ?[]u8 = null,
    /// Source payload size supplied by the tool runtime when available.
    payload_bytes: ?u64 = null,
    /// reasoning blocks: true = deliberate mid-turn narration (visible);
    /// false = raw provider reasoning (folded; ctrl+t reveals).
    commentary: bool = false,
    /// Locally inserted for instant submit feedback. The matching durable
    /// block clears this bit instead of producing a duplicate render block.
    pending_echo: bool = false,
    /// Identity of the input awaiting its daemon ok/err. Zero after ack.
    pending_request_id: u64 = 0,
    /// Durable frontier at submission, so replay cannot match an older repeat.
    pending_after_seq: u64 = 0,
    /// Non-null only for a new-turn echo whose optimistic running state must
    /// be restored if the daemon rejects that exact request.
    pending_prior_state: ?proto.SessionState = null,

    pub fn deinit(self: *RenderBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.label);
        if (self.call_id.len > 0) gpa.free(self.call_id);
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

const commentary_word_delimiters = " \t\r\n-_/\\.,:;!?()[]{}<>`'\"|+=*&^%$#@~";
const commentary_stop_words = [_][]const u8{
    "a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "only", "or", "the", "to", "with",
};

fn significantCommentaryWord(word: []const u8) bool {
    if (word.len < 2) return false;
    for (commentary_stop_words) |stop| {
        if (std.ascii.eqlIgnoreCase(word, stop)) return false;
    }
    return true;
}

fn commentaryWordStem(word: []const u8) []const u8 {
    const suffixes = [_][]const u8{ "ing", "ed", "es", "s" };
    for (suffixes) |suffix| {
        if (word.len >= suffix.len + 4 and std.ascii.endsWithIgnoreCase(word, suffix))
            return word[0 .. word.len - suffix.len];
    }
    return word;
}

fn commentaryWordsEqual(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(commentaryWordStem(a), commentaryWordStem(b));
}

fn commentaryHasWord(text: []const u8, word: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, text, commentary_word_delimiters);
    while (words.next()) |candidate| {
        if (significantCommentaryWord(candidate) and commentaryWordsEqual(candidate, word)) return true;
    }
    return false;
}

fn commentaryWordSeenBefore(text: []const u8, word: []const u8) bool {
    const offset = @intFromPtr(word.ptr) - @intFromPtr(text.ptr);
    return commentaryHasWord(text[0..offset], word);
}

fn normalizedCommentaryEqual(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and !std.ascii.isAlphanumeric(a[ai])) ai += 1;
        while (bi < b.len and !std.ascii.isAlphanumeric(b[bi])) bi += 1;
        if (ai == a.len or bi == b.len) return ai == a.len and bi == b.len;
        if (std.ascii.toLower(a[ai]) != std.ascii.toLower(b[bi])) return false;
        ai += 1;
        bi += 1;
    }
}

pub fn commentaryNearDuplicate(a: []const u8, b: []const u8) bool {
    if (normalizedCommentaryEqual(a, b)) return true;

    var a_count: usize = 0;
    var b_count: usize = 0;
    var shared: usize = 0;
    var a_words = std.mem.tokenizeAny(u8, a, commentary_word_delimiters);
    while (a_words.next()) |word| {
        if (!significantCommentaryWord(word) or commentaryWordSeenBefore(a, word)) continue;
        a_count += 1;
        if (commentaryHasWord(b, word)) shared += 1;
    }
    var b_words = std.mem.tokenizeAny(u8, b, commentary_word_delimiters);
    while (b_words.next()) |word| {
        if (significantCommentaryWord(word) and !commentaryWordSeenBefore(b, word)) b_count += 1;
    }
    const smaller = @min(a_count, b_count);
    return smaller >= 5 and shared * 10 >= smaller * 7;
}

fn commentarySuperseded(blocks: []const RenderBlock, index: usize) bool {
    const current = blocks[index];
    var next = index + 1;
    while (next < blocks.len and blocks[next].turn_id == current.turn_id) : (next += 1) {
        const candidate = blocks[next];
        if ((candidate.kind == .reasoning and candidate.commentary) or candidate.kind == .assistant_msg) {
            if (commentaryNearDuplicate(current.text, candidate.text)) return true;
        }
    }
    return false;
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
    var payload_bytes: ?u64 = null;
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
                text = u.display_text orelse u.text;
                if (u.attachments.len > 0) {
                    generated_label = try mediaLabel(gpa, u.attachments);
                    label = generated_label.?;
                }
            }
        },
        .steer => |s| text = s.display_text orelse s.text,
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
            payload_bytes = tr.payload_bytes;
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
    errdefer if (owned_ref) |ref| gpa.free(ref);
    const call_id = switch (b.body) {
        .tool_call => |call| call.call_id,
        .tool_result => |result| result.call_id,
        else => "",
    };
    const owned_call_id: []u8 = if (call_id.len > 0) try gpa.dupe(u8, call_id) else &.{};

    return .{
        .kind = kind,
        .seq = b.seq,
        .timestamp_ms = b.ts,
        .turn_id = b.turn_id,
        .text = owned_text,
        .label = owned_label,
        .call_id = owned_call_id,
        .plan_items = plan_items,
        .status = status,
        .full_body_ref = owned_ref,
        .payload_bytes = payload_bytes,
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
    return wrapInputCard(arena, lines, text, width, false, false);
}

fn wrapInputCard(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    width: usize,
    steer: bool,
    queued: bool,
) !void {
    const first_prefix = if (steer) " ↪ " else " ❯ ";
    const continuation = "   ";
    const prefix_cells: usize = 3;
    const body_width = width -| (prefix_cells + 1); // keep right padding
    if (body_width < 8) return;

    try lines.append(arena, .{ .text = if (queued) "   Queued" else "", .style = Palette.collapse_hint, .fill_style = Palette.prompt_panel });
    var first = true;
    var logical = std.mem.splitScalar(u8, text, '\n');
    while (logical.next()) |raw_line| {
        const source_links = try findLinkSpans(arena, raw_line);
        var rest = raw_line;
        while (true) {
            const take = render.promptRowEnd(rest, 0, body_width);
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
                .style = if (!first) Palette.prompt_text else if (steer) Palette.steer else Palette.prompt_mark,
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

/// Reasoning/progress narration: a small mark and assistant-priority text,
/// flat on the default background. CONTENT-ONLY like every renderer — the layout loop
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

/// Keep the normal view readable while Ctrl+T retains the complete text.
/// Bound the source window as well as the rows: live thinking can be large.
pub fn wrapReasoningPreview(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    width: usize,
    latest: bool,
) !void {
    const budget = @min(@max(width, 8) * 3 * 4, 4096);
    const start = if (latest and text.len > budget) render.nextCpEndFor(text, text.len - budget) else 0;
    const end = if (latest) text.len else utf8Floor(text, @min(text.len, budget));
    var preview: std.ArrayList(Line) = .empty;
    try wrapReasoningCard(arena, &preview, text[start..end], width -| 2);
    const count = @min(preview.items.len, 3);
    const first = if (latest) preview.items.len - count else 0;
    const output_start = lines.items.len;
    try lines.appendSlice(arena, preview.items[first..][0..count]);
    if (count == 0) return;
    const head = &lines.items[output_start];
    const marker = if (first > 0 or start > 0) "  … " else "  · ";
    const shift = marker.len - head.text.len;
    if (shift > 0) {
        const syntax = try arena.dupe(SyntaxSpan, head.syntax);
        for (syntax) |*span| {
            span.start += shift;
            span.end += shift;
        }
        head.syntax = syntax;
        const links = try arena.dupe(LinkSpan, head.links);
        for (links) |*span| {
            span.start += shift;
            span.end += shift;
        }
        head.links = links;
    }
    head.text = marker;
    head.style = Palette.reasoning_mark;
    if (!latest and (preview.items.len > count or end < text.len)) {
        lines.items[lines.items.len - 1].text3 = " …";
        lines.items[lines.items.len - 1].style3 = Palette.collapse_hint;
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
/// vocabularies: native (edit/write_file) and guest sessions (Edit/Write/…),
/// whose adapters emit unified diffs.
pub fn isFileEditTool(label: []const u8) bool {
    const authored = [_][]const u8{ "edit", "write_file", "Edit", "Write", "MultiEdit", "NotebookEdit" };
    for (authored) |name| {
        if (std.mem.eql(u8, label, name)) return true;
    }
    return false;
}

/// Successful network reads remain visible even when ordinary successful
/// tools fold into "Ran N commands". Their often-large result bodies stay
/// collapsed; the durable row records exactly which URL/query was accessed.
pub fn isNetworkReadTool(label: []const u8) bool {
    return std.ascii.eqlIgnoreCase(label, "fetch") or
        std.ascii.eqlIgnoreCase(label, "webfetch") or
        std.ascii.eqlIgnoreCase(label, "websearch") or
        std.ascii.eqlIgnoreCase(label, "web_search");
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
    /// A paired completed result can carry fields omitted from the started
    /// event. Codex WebSearch, for example, reports an empty query at start
    /// and the actual query only on completion.
    completed_result: ?RenderBlock,
) !void {
    const output_start = lines.items.len;
    defer stampOutputLines(lines.items[output_start..], rb.timestamp_ms);
    // Keep the machinery subdued. Bash commands receive semantic shell
    // roles; for file tools the emphasized value is a path.
    const hi = try completedToolDisplayArg(alloc, rb, completed_result, cwd);
    const head = try std.fmt.allocPrint(alloc, "  ⚙ {s} ", .{toolDisplayName(rb.label)});
    const note_text: []const u8 = if (note) |n|
        try std.fmt.allocPrint(alloc, " · {s}", .{n})
    else
        "";
    if (hi) |h| {
        const available = w -| (displayWidth(head) + displayWidth(note_text) + 2);
        const hi_capped = h[0..hardCellBreak(h, 0, available)];
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

pub fn appendNetworkSuccessLine(
    alloc: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    rb: RenderBlock,
    result: RenderBlock,
    cwd: []const u8,
    w: usize,
) !void {
    const output_start = lines.items.len;
    defer stampOutputLines(lines.items[output_start..], result.timestamp_ms);
    const action: []const u8 = if (std.ascii.indexOfIgnoreCase(rb.label, "search") != null)
        "Searched"
    else
        "Fetched";
    const head = try std.fmt.allocPrint(alloc, "  ✓ {s} ", .{action});
    const arg = (try completedToolDisplayArg(alloc, rb, result, cwd)) orelse toolDisplayName(rb.label);
    const capped = arg[0..utf8Floor(arg, @min(arg.len, w -| (head.len + 2)))];
    const payload_bytes: u64 = result.payload_bytes orelse @intCast(result.text.len);
    const detail = try std.fmt.allocPrint(alloc, "{s} · {Bi:.1}", .{
        if (capped.len < arg.len) "…" else "",
        payload_bytes,
    });
    try lines.append(alloc, .{
        .text = head,
        .style = Palette.note,
        .text2 = capped,
        .style2 = Palette.tool_cmd,
        .text3 = detail,
        .style3 = Palette.collapse_hint,
    });
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
    var in_hunk = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@ ")) in_hunk = true;
        if (line.len == 0) in_hunk = false;
        if (std.mem.startsWith(u8, line, "+") and (in_hunk or !std.mem.startsWith(u8, line, "+++"))) {
            stats.added += 1;
        } else if (std.mem.startsWith(u8, line, "-") and (in_hunk or !std.mem.startsWith(u8, line, "---"))) {
            stats.removed += 1;
        } else if (std.mem.startsWith(u8, line, "… ") and std.mem.endsWith(u8, line, " more new lines")) {
            const count = line["… ".len .. line.len - " more new lines".len];
            stats.added += std.fmt.parseInt(usize, count, 10) catch 0;
        }
    }
    return stats;
}

pub fn diffSummaryNote(alloc: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const intro = diffIntroNote(text);
    if (intro == null and !isDiffOutput(text)) return null;
    const stats = diffStats(text);
    if (intro) |note| {
        if (stats.added == 0 and stats.removed == 0) return note;
        return try std.fmt.allocPrint(alloc, "{s} · +{d} -{d}", .{ note, stats.added, stats.removed });
    }
    return try std.fmt.allocPrint(alloc, "+{d} -{d}", .{ stats.added, stats.removed });
}

pub fn appendToolResultLines(alloc: std.mem.Allocator, lines: *std.ArrayList(Line), rb: RenderBlock, tool_label: []const u8) !void {
    const output_start = lines.items.len;
    defer stampOutputLines(lines.items[output_start..], rb.timestamp_ms);
    // Collapsed: show at most 8 lines — but a diff the agent
    // AUTHORED (edit/write tools) shows whole (up to 24) because
    // a truncated diff misleads. Diffs merely read via bash keep
    // diff coloring but the ordinary cap.
    const is_diff = isDiffOutput(rb.text);
    const authored = is_diff and isFileEditTool(tool_label);
    const max_shown: usize = if (authored) 24 else 8;
    var language = if (is_diff) diffLanguage(rb.text) else SyntaxLanguage.generic;
    var shown: usize = 0;
    var total: usize = 0;
    var diff_nums: DiffLineNumbers = .{};
    var first = true;
    var it = std.mem.splitScalar(u8, rb.text, '\n');
    while (it.next()) |l| {
        defer first = false;
        if (l.len == 0) diff_nums.active = false;
        if (!diff_nums.active and (std.mem.startsWith(u8, l, "--- ") or std.mem.startsWith(u8, l, "+++ ")) and
            !std.mem.eql(u8, l[4..], "/dev/null")) language = render.languageForPath(l[4..]);
        // An authored diff's intro line ("created x (96 bytes)") is rendered
        // as a dim note on the ⚙ line instead; the hunks speak for themselves.
        if (first and authored and rb.status == .ok and diffIntroNote(rb.text) != null) continue;
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

pub const ExpandPair = struct {
    call: usize,
    result: usize,
    show_result: bool = true,
};

/// Prefer durable call IDs; when IDs are unavailable, fall back to a
/// calls-first batch with results in the same order.
fn pairedToolResult(blocks: []const RenderBlock, call_idx: usize) ?RenderBlock {
    if (call_idx >= blocks.len or blocks[call_idx].kind != .tool_call) return null;
    const turn_id = blocks[call_idx].turn_id;
    if (blocks[call_idx].call_id.len > 0) {
        for (blocks[call_idx + 1 ..]) |candidate| {
            if (candidate.turn_id != turn_id) break;
            if (candidate.kind == .tool_result and std.mem.eql(u8, candidate.call_id, blocks[call_idx].call_id)) return candidate;
        }
        return null;
    }
    var calls_start = call_idx;
    while (calls_start > 0 and blocks[calls_start - 1].kind == .tool_call and
        blocks[calls_start - 1].turn_id == turn_id) : (calls_start -= 1)
    {}
    const ordinal = call_idx - calls_start;

    var calls_end = call_idx + 1;
    while (calls_end < blocks.len and blocks[calls_end].kind == .tool_call and
        blocks[calls_end].turn_id == turn_id) : (calls_end += 1)
    {}

    var result_ordinal: usize = 0;
    var i = calls_end;
    while (i < blocks.len and blocks[i].turn_id == turn_id) : (i += 1) {
        switch (blocks[i].kind) {
            .approval, .reasoning, .system_note, .plan => {},
            .tool_result => {
                if (result_ordinal == ordinal) return blocks[i];
                result_ordinal += 1;
            },
            else => break,
        }
    }
    return null;
}

fn pairedToolCallIndex(blocks: []const RenderBlock, result_idx: usize) ?usize {
    const result = blocks[result_idx];
    if (result.call_id.len == 0) return null;
    var i = result_idx;
    while (i > 0) {
        i -= 1;
        if (blocks[i].turn_id != result.turn_id) break;
        if (blocks[i].kind == .tool_call and std.mem.eql(u8, blocks[i].call_id, result.call_id)) return i;
    }
    return null;
}

/// Scan the batch starting at `start`; pairs that must stay visible (failed
/// results, or author-diffs from the edit/write tools whose truncation would
/// mislead) are appended to `expand`. Successful network reads retain only a
/// compact success row: page/search result bodies remain folded.
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
                const call_idx = pairedToolCallIndex(blocks, i) orelse start + matched;
                const failed = blocks[i].status != .ok;
                const author_diff = isDiffOutput(blocks[i].text) and
                    isFileEditTool(blocks[call_idx].label);
                const network_read = !failed and isNetworkReadTool(blocks[call_idx].label);
                if (failed or author_diff or network_read) {
                    try expand.append(alloc, .{
                        .call = call_idx,
                        .result = i,
                        .show_result = !network_read,
                    });
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
pub fn flushRanSummary(alloc: std.mem.Allocator, lines: *std.ArrayList(Line), pending: *usize, timestamp_ms: ?i64) !void {
    if (pending.* == 0) return;
    try blankLine(alloc, lines);
    const summary = try std.fmt.allocPrint(alloc, "Ran {d} {s}", .{
        pending.*,
        if (pending.* == 1) "command" else "commands",
    });
    try lines.append(alloc, .{
        .timestamp_ms = timestamp_ms,
        .text = "  • ",
        .style = Palette.note,
        .text2 = summary,
        .style2 = Palette.assistant,
        .text3 = " · ctrl+t to view transcript",
        .style3 = Palette.collapse_hint,
    });
    pending.* = 0;
}

pub const PlanTableWidths = struct { task: usize, time: usize };

pub fn planTableWidths(total: usize) PlanTableWidths {
    const time = @min(@as(usize, 10), @max(@as(usize, 7), total / 6));
    return .{ .task = total -| (time + 3), .time = time };
}

pub fn formatPlanDuration(alloc: std.mem.Allocator, duration_ms: u64) ![]const u8 {
    if (duration_ms == 0) return "";
    if (duration_ms < 1_000) return "<1s";
    var buf: [duration_buf_len]u8 = undefined;
    return alloc.dupe(u8, formatSeconds(&buf, (duration_ms +| 500) / 1_000));
}

pub const duration_buf_len = 32;

/// The one human elapsed-time shape in the TUI: `45s`, `8m 12s`, `1h 3m`.
/// Plans, the working ticker, live guest work, and notices all use it, so a
/// glance never has to convert 492s in its head.
pub fn formatSeconds(buf: []u8, seconds: u64) []const u8 {
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
    const minutes = seconds / 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m {d}s", .{ minutes, seconds % 60 }) catch "?";
    return std.fmt.bufPrint(buf, "{d}h {d}m", .{ minutes / 60, minutes % 60 }) catch "?";
}

fn secondsAlloc(alloc: std.mem.Allocator, seconds: i64) ![]const u8 {
    var buf: [duration_buf_len]u8 = undefined;
    return alloc.dupe(u8, formatSeconds(&buf, @intCast(@max(seconds, 0))));
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

/// A parked ask_user question for the picker card. Option slices point into
/// the view's fixed buffers, valid for the frame like ApprovalView's.
pub const QuestionView = struct {
    question: []const u8,
    options: [9][]const u8 = undefined,
    count: usize = 0,
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
    shimmer_shades: []const vaxis.Color = &render.shimmer_shades,
    turn_started_ms: i64,
    turn_phase: proto.TurnPhase = .idle,
    phase_started_ms: i64 = 0,
    call_started_ms: i64,
    stream_bytes: u64,
    stream_quiet_ms: u64,
    stream_status_at_ms: i64,
    /// The TUI's TODO table supplies its own spinner and active-step timer;
    /// suppress this competing live-status row while that table is visible.
    show_working_ticker: bool = true,
    /// Guest prose renders as assistant text, exposed thinking gets a compact
    /// preview, and tools use a one-line trail instead of "Ran N commands".
    guest: bool = false,
    guest_activity: []const proto.GuestActivity = &.{},
    cwd: []const u8 = "",
    approval: ?ApprovalView,
    question: ?QuestionView = null,
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

fn streamStatusFresh(transcript: *const Transcript, now_ms: i64) bool {
    return transcript.stream_status_at_ms > 0 and
        now_ms - transcript.stream_status_at_ms <
            (if (transcript.stream_bytes == 0) @as(i64, 15_000) else 3000);
}

pub const StreamTraffic = enum { up, down };

pub fn streamTraffic(transcript: *const Transcript, now_ms: i64) ?StreamTraffic {
    if (transcript.turn_phase != .provider or transcript.stream_bytes == 0 or
        !streamStatusFresh(transcript, now_ms)) return null;
    return if (transcript.stream_quiet_ms < 3000) .up else .down;
}

pub fn workingLabel(transcript: *const Transcript, now_ms: i64) []const u8 {
    if (handoverInProgress(transcript.blocks)) return "Generating handover…";
    if (currentInflightCall(transcript.blocks) != null) return "Running tool…";
    return switch (transcript.turn_phase) {
        .idle => "Working…",
        .starting => "Starting turn thread…",
        .context => "Preparing request context…",
        .provider => if (streamTraffic(transcript, now_ms) != null)
            "Receiving model response…"
        else
            "Waiting for model…",
        .approval => "Waiting for approval…",
        .tool => "Running tool…",
        .child => "Waiting for child agent…",
        .background => "Waiting on background task…",
        .compaction => "Compacting context…",
        .finishing => "Finalizing response…",
    };
}

const WorkingDetail = struct {
    text: []const u8,
    shell_command: ?[]const u8 = null,
    shell_offset: usize = 0,
};

/// Compact live telemetry for the transcript ticker. The returned text begins
/// with a separator so it can be appended directly to the activity label.
pub fn workingDetail(arena: std.mem.Allocator, transcript: *const Transcript) !WorkingDetail {
    const now_ms = nowWallMs(transcript.io);
    const elapsed_s: i64 = if (transcript.turn_started_ms > 0)
        @max(0, @divTrunc(now_ms - transcript.turn_started_ms, 1000))
    else
        0;
    const phase_s: i64 = if (transcript.phase_started_ms > 0)
        @max(0, @divTrunc(now_ms - transcript.phase_started_ms, 1000))
    else
        0;
    const elapsed = try std.fmt.allocPrint(arena, " · {s} total · {s} here", .{
        try secondsAlloc(arena, elapsed_s),
        try secondsAlloc(arena, phase_s),
    });

    var detail = WorkingDetail{ .text = elapsed };
    const stream_fresh = streamStatusFresh(transcript, now_ms);
    if (stream_fresh and currentInflightCall(transcript.blocks) == null) {
        const quiet_s = transcript.stream_quiet_ms / 1000;
        if (transcript.stream_bytes == 0) {
            detail.text = try std.fmt.allocPrint(arena, "{s} · waiting for provider · {s}", .{
                elapsed, try secondsAlloc(arena, @intCast(quiet_s)),
            });
        } else if (quiet_s >= 3) {
            detail.text = try std.fmt.allocPrint(arena, "{s} · streaming ↓ {Bi:.1} · last token {s} ago", .{
                elapsed, transcript.stream_bytes, try secondsAlloc(arena, @intCast(quiet_s)),
            });
        } else {
            detail.text = try std.fmt.allocPrint(arena, "{s} · streaming ↑ {Bi:.1}", .{
                elapsed, transcript.stream_bytes,
            });
        }
    }
    if (currentInflightCall(transcript.blocks)) |cur| {
        const arg_full = (try toolDisplayArgDecoded(arena, cur.rb.label, cur.rb.text, transcript.cwd)) orelse "";
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
        const tool_prefix = try std.fmt.allocPrint(arena, "{s} · {s}{s}", .{
            elapsed, toolDisplayName(cur.rb.label), sep,
        });
        detail = .{
            .text = try std.fmt.allocPrint(arena, "{s}{s} · {d}s{s}", .{ tool_prefix, arg, call_s, queued }),
            .shell_command = if (std.ascii.eqlIgnoreCase(cur.rb.label, "bash") and arg.len > 0) arg else null,
            .shell_offset = tool_prefix.len,
        };
    }
    return detail;
}

fn activityHasParent(items: []const proto.GuestActivity, parent_id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, parent_id)) return true;
    return false;
}

fn activityIsLastChild(items: []const proto.GuestActivity, index: usize, parent_id: []const u8) bool {
    for (items[index + 1 ..]) |item| {
        const effective_parent = if (activityHasParent(items, item.parent_id)) item.parent_id else "";
        if (std.mem.eql(u8, effective_parent, parent_id)) return false;
    }
    return true;
}

fn appendGuestActivityChildren(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    items: []const proto.GuestActivity,
    parent_id: []const u8,
    depth: usize,
    now_ms: i64,
    fallback_timestamp: ?i64,
) !void {
    for (items, 0..) |item, item_index| {
        const effective_parent = if (activityHasParent(items, item.parent_id)) item.parent_id else "";
        if (!std.mem.eql(u8, effective_parent, parent_id)) continue;
        const indent = try arena.alloc(u8, depth * 3);
        @memset(indent, ' ');
        const icon: []const u8 = if (depth == 0)
            (if (item.kind == .agent) "◇" else "•")
        else if (activityIsLastChild(items, item_index, effective_parent))
            "└─"
        else
            "├─";
        const elapsed_s: i64 = if (item.started_at_ms > 0) @max(0, @divTrunc(now_ms - item.started_at_ms, 1000)) else 0;
        const item_detail = if (std.ascii.eqlIgnoreCase(item.name, "bash"))
            shellDisplayCommand(item.detail)
        else
            item.detail;
        const activity_head = try std.fmt.allocPrint(arena, "{s}{s} {s}", .{ indent, icon, item.name });
        const detail = if (item_detail.len > 0) try std.fmt.allocPrint(arena, " · {s}", .{item_detail}) else "";
        const activity_text = try std.fmt.allocPrint(arena, "{s}{s}", .{ activity_head, detail });
        try lines.append(arena, .{
            .timestamp_ms = if (item.started_at_ms > 0) item.started_at_ms else fallback_timestamp,
            .text = "  ",
            .style = Palette.working,
            .text2 = activity_text,
            .style2 = if (item.kind == .agent) Palette.status_model else Palette.collapse_hint,
            .text3 = try std.fmt.allocPrint(arena, " · {s}", .{try secondsAlloc(arena, elapsed_s)}),
            .style3 = Palette.collapse_hint,
            .syntax = if (std.ascii.eqlIgnoreCase(item.name, "bash") and item_detail.len > 0)
                try shellCommandSpans(arena, item_detail, 2 + activity_head.len + " · ".len)
            else
                &.{},
        });
        try appendGuestActivityChildren(arena, lines, items, item.id, depth + 1, now_ms, fallback_timestamp);
    }
}

fn stampOutputLines(lines: []Line, timestamp_ms: ?i64) void {
    const timestamp = timestamp_ms orelse return;
    var started = false;
    for (lines) |*line| {
        if (line.timestamp_ms != null) {
            started = false;
            continue;
        }
        if (!started) {
            if (std.mem.trim(u8, line.text, " ").len == 0 and line.text2.len == 0 and line.text3.len == 0) continue;
            started = true;
        }
        line.timestamp_ms = timestamp;
    }
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
    var pending_timestamp: ?i64 = null;
    // Dense tool rows stack flush within a group; the group START gets one
    // blank like any other section. Tracks whether the last emitted row was
    // dense machinery (tool call/result/approval) or prose.
    var last_dense = false;
    var block_idx: usize = start;
    var layout_steps: usize = 0;
    while (block_idx < end) : (block_idx += 1) {
        if (layout_steps >= max_layout_steps or lines.items.len >= max_layout_lines) {
            try lines.append(alloc, .{
                .timestamp_ms = transcript.blocks[block_idx].timestamp_ms,
                .text = "  [transcript rendering truncated at safety limit]",
                .style = Palette.tool_err,
            });
            break;
        }
        layout_steps += 1;
        const rb = transcript.blocks[block_idx];
        const block_start = lines.items.len;
        defer stampOutputLines(lines.items[block_start..], rb.timestamp_ms);
        if (!transcript.show_tool_transcript and !transcript.guest and rb.kind == .tool_call) {
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
                if (expand.items.len > 0) break; // surface retained rows promptly
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
                pending_timestamp = blocks_all[scan_end - 1].timestamp_ms;
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
                    const hi = (try toolDisplayArgDecoded(alloc, call.label, call.text, transcript.cwd)) orelse "";
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
                        .timestamp_ms = if (scan_end > block_idx) blocks_all[scan_end - 1].timestamp_ms else pending_timestamp orelse rb.timestamp_ms,
                        .text = "  • ",
                        .style = Palette.note,
                        .text2 = summary,
                        .style2 = Palette.assistant,
                        .text3 = hint,
                        .style3 = Palette.collapse_hint,
                    });
                }
                for (expand.items) |pair| {
                    // Authored diffs, failures, and network receipts are
                    // sections the user reads, not machinery: give them air
                    // instead of hugging the summary line above.
                    try blankLine(alloc, lines);
                    const result = blocks_all[pair.result];
                    if (pair.show_result) {
                        const note = if (result.status == .ok) try diffSummaryNote(alloc, result.text) else null;
                        try appendToolCallLine(alloc, lines, blocks_all[pair.call], transcript.cwd, w, note, result);
                        try appendToolResultLines(alloc, lines, result, blocks_all[pair.call].label);
                    } else {
                        try appendNetworkSuccessLine(alloc, lines, blocks_all[pair.call], result, transcript.cwd, w);
                    }
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
                try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                try blankLine(alloc, lines);
                try wrapPromptCard(alloc, lines, rb.text, w);
                if (rb.label.len > 0)
                    try wrapPrefixed(alloc, lines, "  ", rb.label, Palette.status_model, w);
            },
            .assistant_msg => {
                try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                try blankLine(alloc, lines);
                try wrapMarkdown(alloc, lines, rb.text, w);
            },
            .reasoning => {
                // Guest summaries get a compact preview; native raw thinking
                // stays folded because it can contain drafted replies.
                if (transcript.guest and rb.commentary) {
                    // Deliberate progress updates: full text, assistant styling.
                    // Still superseded by a later message saying the same.
                    if (transcript.show_tool_transcript or !commentarySuperseded(transcript.blocks, block_idx)) {
                        try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                        try blankLine(alloc, lines);
                        try wrapMarkdown(alloc, lines, rb.text, w);
                    }
                } else if (transcript.guest and !transcript.show_tool_transcript) {
                    try blankLine(alloc, lines);
                    try wrapReasoningPreview(alloc, lines, rb.text, w, false);
                } else if (transcript.show_tool_transcript or
                    (rb.commentary and !commentarySuperseded(transcript.blocks, block_idx)))
                {
                    try blankLine(alloc, lines);
                    const text = if (transcript.show_tool_transcript) rb.text else try clipText(alloc, rb.text, 280);
                    try wrapReasoningCard(alloc, lines, text, w);
                }
            },
            .tool_call => {
                try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                if (!last_dense) try blankLine(alloc, lines);
                last_tool_label.* = rb.label;
                const result = pairedToolResult(transcript.blocks, block_idx);
                const note = if (result != null and result.?.status == .ok and isFileEditTool(rb.label))
                    try diffSummaryNote(alloc, result.?.text)
                else
                    null;
                try appendToolCallLine(
                    alloc,
                    lines,
                    rb,
                    transcript.cwd,
                    w,
                    note,
                    result,
                );
            },
            .tool_result => {
                const tool_label = if (pairedToolCallIndex(transcript.blocks, block_idx)) |call_idx|
                    transcript.blocks[call_idx].label
                else
                    last_tool_label.*;
                // Guest trail: the call line is the progress signal; a
                // successful result body is machinery unless it is an
                // authored diff. Failures always show.
                if (transcript.guest and !transcript.show_tool_transcript and rb.status == .ok and
                    !(isFileEditTool(tool_label) and isDiffOutput(rb.text))) continue;
                try appendToolResultLines(alloc, lines, rb, tool_label);
            },
            .approval => {
                const txt = try std.fmt.allocPrint(alloc, "    [approval: {s}]", .{rb.text});
                try wrapInto(alloc, lines, txt, .{ .text = txt, .style = Palette.note });
            },
            .steer => {
                try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                try blankLine(alloc, lines);
                try wrapInputCard(alloc, lines, rb.text, w, true, rb.pending_echo);
            },
            .plan => {
                if (visibleCompletedPlan(transcript.blocks, block_idx)) {
                    try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                    try appendArchivedPlanTable(alloc, lines, rb.plan_items, w);
                }
            },
            .system_note => {
                if (std.mem.eql(u8, rb.label, "Recap") or std.mem.eql(u8, rb.label, "Last exchange")) {
                    try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                    try blankLine(alloc, lines);
                    try wrapPrefixed(alloc, lines, "  ", rb.label, Palette.note, w);
                    try wrapPrefixed(alloc, lines, "  ", rb.text, Palette.note, w);
                } else if (std.mem.eql(u8, rb.label, "diagnostics")) {
                    try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                    try blankLine(alloc, lines);
                    try wrapPrefixed(alloc, lines, "  ", "diagnostics", Palette.note, w);
                    try wrapMarkdown(alloc, lines, rb.text, w);
                } else if (block.isHandoverNote(rb.text)) {
                    try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                    try blankLine(alloc, lines);
                    try wrapPrefixed(alloc, lines, "  ", "handover to guest", Palette.note, w);
                    try wrapMarkdown(alloc, lines, block.handoverBody(rb.text), w);
                } else {
                    try blankLine(alloc, lines);
                    const txt = try std.fmt.allocPrint(alloc, "[{s}]", .{try clipText(alloc, rb.text, 480)});
                    try wrapPrefixed(alloc, lines, "  ", txt, Palette.note, w);
                }
            },
            .compaction => {
                try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
                try blankLine(alloc, lines);
                try wrapPrefixed(alloc, lines, "  ≋ ", "context compacted", Palette.note, w);
            },
        }
    }
    try flushRanSummary(alloc, lines, &pending_ran, pending_timestamp);
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
    var i = items.len;
    while (i > 0 and items[i - 1].pending_echo) i -= 1;
    if (i == 0) return 0;
    const last_turn = items[i - 1].turn_id;
    while (i > 0 and (items[i - 1].pending_echo or items[i - 1].turn_id == last_turn)) i -= 1;
    for (items[0..i], 0..) |item, index| {
        if (item.pending_echo) return index;
    }
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

    const live_timestamp: ?i64 = if (transcript.phase_started_ms > 0) transcript.phase_started_ms else if (transcript.turn_started_ms > 0) transcript.turn_started_ms else if (transcript.blocks.len > 0) transcript.blocks[transcript.blocks.len - 1].timestamp_ms else null;
    // Live thinking follows the latest few wrapped lines. Expanded transcripts
    // expose the full stream, just as they do for completed reasoning.
    if (transcript.reasoning_delta.len > 0) {
        try blankLine(arena, &lines);
        const first = lines.items.len;
        defer stampOutputLines(lines.items[first..], live_timestamp);
        if (transcript.show_tool_transcript)
            try wrapReasoningCard(arena, &lines, transcript.reasoning_delta, w)
        else
            try wrapReasoningPreview(arena, &lines, transcript.reasoning_delta, w, true);
    }
    if (transcript.delta.len > 0) {
        const first = lines.items.len;
        defer stampOutputLines(lines.items[first..], live_timestamp);
        try blankLine(arena, &lines);
        try transcript.stream_layout_cache.update(gpa, transcript.delta, w);
        try transcript.stream_layout_cache.appendTo(arena, &lines);
    } else if (transcript.state == .running and transcript.show_working_ticker and
        (transcript.reasoning_delta.len == 0 or transcript.guest_activity.len > 0))
    {
        try blankLine(arena, &lines);
        if (transcript.guest_activity.len > 0) {
            try appendGuestActivityChildren(arena, &lines, transcript.guest_activity, "", 0, nowWallMs(transcript.io), live_timestamp);
        }
        if (transcript.reasoning_delta.len == 0) {
            try blankLine(arena, &lines);
            const head = try std.fmt.allocPrint(arena, "{s} ", .{
                spinner_frames[transcript.spinner_frame % spinner_frames.len],
            });
            const now_ms = nowWallMs(transcript.io);
            const word = workingLabel(transcript, now_ms);
            const detail = try workingDetail(arena, transcript);
            var syntax: std.ArrayList(SyntaxSpan) = .empty;
            if (streamTraffic(transcript, now_ms)) |traffic| {
                const arrow = if (traffic == .up) "↑" else "↓";
                if (std.mem.indexOf(u8, detail.text, arrow)) |arrow_at| {
                    try syntax.append(arena, .{
                        .start = head.len + word.len + arrow_at,
                        .end = head.len + word.len + arrow_at + arrow.len,
                        .style = if (traffic == .up) Palette.stream_up else Palette.stream_down,
                    });
                }
            }
            try syntax.appendSlice(arena, try shimmerSpans(arena, word, head.len, transcript.spinner_frame, transcript.shimmer_shades));
            if (detail.shell_command) |command| {
                try syntax.appendSlice(arena, try shellCommandSpans(
                    arena,
                    command,
                    head.len + word.len + detail.shell_offset,
                ));
            }
            try lines.append(arena, .{
                .timestamp_ms = live_timestamp,
                .text = head,
                .style = Palette.working,
                .text2 = word,
                .style2 = Palette.working,
                .text3 = detail.text,
                .style3 = Palette.collapse_hint,
                .syntax = syntax.items,
            });
        }
    }

    // Approval card.
    if (transcript.approval) |approval| {
        const first = lines.items.len;
        defer stampOutputLines(lines.items[first..], live_timestamp);
        try blankLine(arena, &lines);
        const arg = (try toolDisplayArgDecoded(arena, approval.tool, approval.args, transcript.cwd)) orelse "";
        const card = try std.fmt.allocPrint(arena, "⚠ approve {s}{s}{s} ?  [y]es / [n]o", .{
            toolDisplayName(approval.tool),
            if (arg.len > 0) " " else "",
            arg,
        });
        try wrapPrefixed(arena, &lines, "", card, Palette.approval_card, w);
    }

    // Question card: the agent asked the user to choose. Numbered options
    // answer on their digit; the composer answers in the user's own words.
    if (transcript.question) |question| {
        const first = lines.items.len;
        defer stampOutputLines(lines.items[first..], live_timestamp);
        try blankLine(arena, &lines);
        const head = try std.fmt.allocPrint(arena, "? {s}", .{question.question});
        try wrapPrefixed(arena, &lines, "", head, Palette.approval_card, w);
        for (question.options[0..question.count], 1..) |option, n| {
            const row = try std.fmt.allocPrint(arena, "[{d}] {s}", .{ n, option });
            try wrapPrefixed(arena, &lines, "  ", row, .{}, w);
        }
        try wrapPrefixed(arena, &lines, "  ", "1-9 picks · or type your own answer and press Enter", Palette.tool_out, w);
    }
    try resolveLineLinks(arena, lines.items);
    return lines;
}

pub fn extractHighlightArg(tool_name: []const u8, args_json: []const u8) ?[]const u8 {
    if (isFileTool(tool_name))
        return extractJsonStringRaw(args_json, "path") orelse
            extractJsonStringRaw(args_json, "file_path");
    if (std.ascii.eqlIgnoreCase(tool_name, "bash"))
        return if (extractJsonStringRaw(args_json, "command")) |command|
            shellDisplayCommand(command)
        else
            null;
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
    if (std.ascii.eqlIgnoreCase(tool_name, "sleep")) return "Sleep";
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
    return shortenDisplayPath(arg, cwd);
}

const DisplayArg = struct {
    value: []const u8,
    is_path: bool = false,
};

const DisplayArgsJson = struct {
    path: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    filePath: ?[]const u8 = null,
    notebook_path: ?[]const u8 = null,
    changes: ?[]const struct { path: []const u8 = "" } = null,
    command: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    url: ?[]const u8 = null,
    query: ?[]const u8 = null,
    description: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    explanation: ?[]const u8 = null,
};

/// Extract a display argument from parsed JSON so consumers such as the shell
/// highlighter receive the actual string value, not JSON escape syntax. The
/// parser projects only display-relevant fields, so a large Write/Edit body
/// is skipped rather than copied into the frame arena. The raw extractor
/// remains as a best-effort fallback for non-shell malformed payloads and for
/// callers that cannot provide scratch allocation.
pub fn toolDisplayArgDecoded(
    arena: std.mem.Allocator,
    tool_name: []const u8,
    args_json: []const u8,
    cwd: []const u8,
) !?[]const u8 {
    if (std.ascii.eqlIgnoreCase(tool_name, "sleep")) {
        const duration = std.json.parseFromSliceLeaky(struct {
            durationMs: ?u64 = null,
            duration_ms: ?u64 = null,
        }, arena, args_json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        return try formatSleepDuration(arena, duration.durationMs orelse duration.duration_ms orelse return null);
    }
    const parsed = std.json.parseFromSliceLeaky(DisplayArgsJson, arena, args_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return malformedDisplayArg(tool_name, args_json, cwd),
    };

    if (isFileEditTool(tool_name)) {
        if (parsed.changes) |changes| {
            var paths: std.ArrayList(u8) = .empty;
            for (changes) |change| {
                if (change.path.len == 0) continue;
                if (paths.items.len > 0) try paths.appendSlice(arena, ", ");
                try paths.appendSlice(arena, if (std.fs.path.isAbsolute(change.path)) shortenDisplayPath(change.path, cwd) else change.path);
            }
            if (paths.items.len > 0) return paths.items;
        }
    }
    const arg = decodedDisplayArg(tool_name, parsed) orelse return null;
    if (!arg.is_path or !std.fs.path.isAbsolute(arg.value)) return arg.value;
    return shortenDisplayPath(arg.value, cwd);
}

fn formatSleepDuration(arena: std.mem.Allocator, duration_ms: u64) ![]const u8 {
    if (duration_ms == 0) return "0s";
    if (duration_ms < std.time.ms_per_s) return std.fmt.allocPrint(arena, "{d}ms", .{duration_ms});
    var out: std.ArrayList(u8) = .empty;
    var remaining = duration_ms;
    for ([_]struct { u64, []const u8 }{
        .{ std.time.ms_per_hour, "h" },
        .{ std.time.ms_per_min, "m" },
    }) |unit| {
        if (remaining >= unit[0]) try out.print(arena, "{d}{s}", .{ remaining / unit[0], unit[1] });
        remaining %= unit[0];
    }
    if (remaining > 0) {
        try out.print(arena, "{d}", .{remaining / std.time.ms_per_s});
        if (remaining % std.time.ms_per_s != 0) {
            var fraction: [3]u8 = undefined;
            const digits = try std.fmt.bufPrint(&fraction, "{d:0>3}", .{remaining % std.time.ms_per_s});
            try out.print(arena, ".{s}", .{std.mem.trimEnd(u8, digits, "0")});
        }
        try out.append(arena, 's');
    }
    return out.items;
}

fn completedToolDisplayArg(
    arena: std.mem.Allocator,
    call: RenderBlock,
    result: ?RenderBlock,
    cwd: []const u8,
) !?[]const u8 {
    const started = try toolDisplayArgDecoded(arena, call.label, call.text, cwd);
    if (started) |value| if (value.len > 0) return value;
    if (isFileEditTool(call.label)) {
        const completed = result orelse return started;
        var path: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, completed.text, '\n');
        while (lines.next()) |line| {
            if ((std.mem.startsWith(u8, line, "+++ ") or std.mem.startsWith(u8, line, "--- ")) and
                !std.mem.eql(u8, line[4..], "/dev/null"))
            {
                path = line[4..];
                if (std.mem.startsWith(u8, line, "+++ ")) break;
            }
            if (std.mem.startsWith(u8, line, "@@ ")) break;
        }
        if (path) |value| return if (std.fs.path.isAbsolute(value)) shortenDisplayPath(value, cwd) else value;
    }
    if (!isNetworkReadTool(call.label)) return started;
    const completed = result orelse return started;
    const enriched = try toolDisplayArgDecoded(arena, call.label, completed.text, cwd);
    if (enriched) |value| if (value.len > 0) return value;
    return started;
}

fn malformedDisplayArg(tool_name: []const u8, args_json: []const u8, cwd: []const u8) ?[]const u8 {
    // JSON escape syntax is not shell syntax. Suppressing one malformed Bash
    // preview is preferable to handing it to the shell lexer and coloring an
    // arbitrary suffix as a quoted string.
    if (std.ascii.eqlIgnoreCase(tool_name, "bash")) return null;
    return toolDisplayArg(tool_name, args_json, cwd);
}

fn decodedDisplayArg(tool_name: []const u8, root: DisplayArgsJson) ?DisplayArg {
    if (isFileTool(tool_name) or isFileEditTool(tool_name)) {
        if (root.path) |value| return .{ .value = value, .is_path = true };
        if (root.file_path) |value| return .{ .value = value, .is_path = true };
        if (root.filePath) |value| return .{ .value = value, .is_path = true };
        if (root.notebook_path) |value| return .{ .value = value, .is_path = true };
        return null;
    }
    if (std.ascii.eqlIgnoreCase(tool_name, "bash"))
        return if (root.command) |value| .{ .value = shellDisplayCommand(value) } else null;
    if (std.ascii.eqlIgnoreCase(tool_name, "grep") or std.ascii.eqlIgnoreCase(tool_name, "glob"))
        return if (root.pattern) |value| .{ .value = value } else null;
    if (std.ascii.eqlIgnoreCase(tool_name, "fetch") or std.ascii.eqlIgnoreCase(tool_name, "webfetch"))
        return if (root.url) |value| .{ .value = value } else null;
    if (std.ascii.eqlIgnoreCase(tool_name, "websearch"))
        return if (root.query) |value| .{ .value = value } else null;
    if (std.ascii.eqlIgnoreCase(tool_name, "task")) {
        if (root.description) |value| return .{ .value = value };
        if (root.prompt) |value| return .{ .value = value };
        return null;
    }
    if (std.mem.eql(u8, tool_name, "plan_update"))
        return if (root.explanation) |value| .{ .value = value } else null;

    for ([_]struct { ?[]const u8, bool }{
        .{ root.path, true },
        .{ root.file_path, true },
        .{ root.command, false },
        .{ root.pattern, false },
        .{ root.url, false },
        .{ root.query, false },
        .{ root.description, false },
        .{ root.prompt, false },
    }) |candidate| {
        if (candidate[0]) |value|
            return .{ .value = value, .is_path = candidate[1] };
    }
    return null;
}

fn shortenDisplayPath(arg: []const u8, cwd: []const u8) []const u8 {
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

    const is_add = std.mem.startsWith(u8, line, "+") and (nums.active or !std.mem.startsWith(u8, line, "+++"));
    const is_del = std.mem.startsWith(u8, line, "-") and (nums.active or !std.mem.startsWith(u8, line, "---"));
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
