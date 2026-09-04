//! Unit tests for layout.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in layout.zig.

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

const layout = @import("layout.zig");
const ExpandPair = layout.ExpandPair;
const LayoutCache = layout.LayoutCache;
const RenderBlock = layout.RenderBlock;
const StreamLayoutCache = layout.StreamLayoutCache;
const StreamTraffic = layout.StreamTraffic;
const TailLayoutCache = layout.TailLayoutCache;
const Transcript = layout.Transcript;
const activePromptLineRange = layout.activePromptLineRange;
const appendNetworkSuccessLine = layout.appendNetworkSuccessLine;
const appendToolCallLine = layout.appendToolCallLine;
const currentInflightCall = layout.currentInflightCall;
const diffIntroNote = layout.diffIntroNote;
const diffSummaryNote = layout.diffSummaryNote;
const layoutBlockRange = layout.layoutBlockRange;
const layoutLines = layout.layoutLines;
const max_layout_lines = layout.max_layout_lines;
const scanToolBatch = layout.scanToolBatch;
const streamTraffic = layout.streamTraffic;
const toolDisplayArg = layout.toolDisplayArg;
const toolDisplayName = layout.toolDisplayName;
const workingDetail = layout.workingDetail;
const workingLabel = layout.workingLabel;
const wrapPromptCard = layout.wrapPromptCard;
const wrapReasoningCard = layout.wrapReasoningCard;

test {
    std.testing.refAllDecls(layout);
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

    lines.clearRetainingCapacity();
    try appendNetworkSuccessLine(arena, &lines, .{
        .kind = .tool_call,
        .text = try arena.dupe(u8, "{\"url\":\"https://example.com/spec\"}"),
        .label = try arena.dupe(u8, "fetch"),
    }, .{
        .kind = .tool_result,
        .text = try arena.dupe(u8, "readable body"),
        .label = try arena.dupe(u8, ""),
        .payload_bytes = 43_212,
    }, cwd, 100);
    try std.testing.expectEqualStrings("  ✓ Fetched ", lines.items[0].text);
    try std.testing.expectEqualStrings("https://example.com/spec", lines.items[0].text2);
    try std.testing.expectEqualStrings(" · 42.2KiB", lines.items[0].text3);
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

    // Network reads retain a compact receipt, but not the fetched page body.
    const network = [_]RenderBlock{
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{\"url\":\"https://example.com/spec\"}"), .label = try arena.dupe(u8, "fetch") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "large fetched page body"), .label = try arena.dupe(u8, ""), .payload_bytes = 98_765 },
    };
    var network_expand: std.ArrayList(ExpandPair) = .empty;
    defer network_expand.deinit(arena);
    const network_batch = try scanToolBatch(arena, &network, 0, &network_expand);
    try std.testing.expectEqual(@as(usize, 0), network_batch.ok_count);
    try std.testing.expectEqual(@as(usize, 1), network_expand.items.len);
    try std.testing.expect(!network_expand.items[0].show_result);
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

test "working activity names each operational phase" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var cache = LayoutCache{};
    defer cache.reset(gpa);
    var tail = TailLayoutCache{};
    defer tail.reset(gpa);
    var stream = StreamLayoutCache{};
    defer stream.reset(gpa);
    var transcript = Transcript{
        .io = threaded.io(),
        .blocks = &.{},
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
    const now_ms = nowWallMs(transcript.io);

    const cases = [_]struct { phase: proto.TurnPhase, label: []const u8 }{
        .{ .phase = .starting, .label = "Starting turn thread…" },
        .{ .phase = .context, .label = "Preparing request context…" },
        .{ .phase = .provider, .label = "Waiting for model…" },
        .{ .phase = .approval, .label = "Waiting for approval…" },
        .{ .phase = .tool, .label = "Running tool…" },
        .{ .phase = .child, .label = "Waiting for child agent…" },
        .{ .phase = .compaction, .label = "Compacting context…" },
        .{ .phase = .finishing, .label = "Finalizing response…" },
    };
    for (cases) |case| {
        transcript.turn_phase = case.phase;
        try std.testing.expectEqualStrings(case.label, workingLabel(&transcript, now_ms));
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    transcript.turn_phase = .provider;
    transcript.stream_bytes = 4096;
    transcript.stream_status_at_ms = now_ms;
    try std.testing.expectEqualStrings("Receiving model response…", workingLabel(&transcript, now_ms));
    try std.testing.expectEqual(StreamTraffic.up, streamTraffic(&transcript, now_ms).?);
    const active_lines = try layoutLines(arena, gpa, &transcript, 80);
    const active = active_lines.items[active_lines.items.len - 1];
    const active_text = try lineText(arena, active);
    try std.testing.expect(std.mem.indexOf(u8, active_text, "streaming ↑ 4.0KiB") != null);
    const active_arrow = std.mem.indexOf(u8, active_text, "↑").?;
    try std.testing.expect(vaxis.Color.eql(
        render.syntaxForBytes(active.syntax, active_arrow, active_arrow + "↑".len).?.fg,
        Palette.stream_up.fg,
    ));

    transcript.stream_quiet_ms = 4000;
    try std.testing.expectEqualStrings("Receiving model response…", workingLabel(&transcript, now_ms));
    try std.testing.expectEqual(StreamTraffic.down, streamTraffic(&transcript, now_ms).?);
    const stalled_lines = try layoutLines(arena, gpa, &transcript, 80);
    const stalled = stalled_lines.items[stalled_lines.items.len - 1];
    const stalled_text = try lineText(arena, stalled);
    try std.testing.expect(std.mem.indexOf(u8, stalled_text, "streaming ↓ 4.0KiB") != null);
    const stalled_arrow = std.mem.indexOf(u8, stalled_text, "↓").?;
    try std.testing.expect(vaxis.Color.eql(
        render.syntaxForBytes(stalled.syntax, stalled_arrow, stalled_arrow + "↓".len).?.fg,
        Palette.stream_down.fg,
    ));
    transcript.stream_quiet_ms = 0;

    transcript.turn_started_ms = now_ms - 12_000;
    transcript.phase_started_ms = now_ms - 3_000;
    const detail = try workingDetail(arena, &transcript);
    try std.testing.expect(std.mem.indexOf(u8, detail.text, " total") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.text, " here") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.text, "streaming ↑ 4.0KiB") != null);
}

test "running Bash activity syntax-highlights the displayed command" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const blocks = [_]RenderBlock{
        .{
            .kind = .user_msg,
            .text = try gpa.dupe(u8, "verify it"),
            .label = try gpa.dupe(u8, ""),
        },
        .{
            .kind = .tool_call,
            .text = try gpa.dupe(u8, "{\"command\":\"zig build --summary all && printf 'done'\"}"),
            .label = try gpa.dupe(u8, "bash"),
        },
    };
    defer {
        for (@constCast(&blocks)) |*rb| rb.deinit(gpa);
    }
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
    const lines = try layoutLines(arena, gpa, &transcript, 120);

    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "Running tool…") == null) continue;
        const command_at = std.mem.indexOf(u8, text, "zig build").?;
        const flag_at = std.mem.indexOf(u8, text, "--summary").?;
        const operator_at = std.mem.indexOf(u8, text, "&&").?;
        const string_at = std.mem.indexOf(u8, text, "'done'").?;
        try std.testing.expect(vaxis.Color.eql(render.syntaxForBytes(line.syntax, command_at, command_at + 1).?.fg, Palette.shell_executable.fg));
        try std.testing.expect(vaxis.Color.eql(render.syntaxForBytes(line.syntax, flag_at, flag_at + 1).?.fg, Palette.shell_flag.fg));
        try std.testing.expect(vaxis.Color.eql(render.syntaxForBytes(line.syntax, operator_at, operator_at + 1).?.fg, Palette.shell_operator.fg));
        try std.testing.expect(vaxis.Color.eql(render.syntaxForBytes(line.syntax, string_at, string_at + 1).?.fg, Palette.shell_string.fg));
        return;
    }
    return error.TestExpectedEqual;
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
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "handover to guest") != null);
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
