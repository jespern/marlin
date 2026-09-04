//! Unit tests for tui.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in tui.zig.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const vaxis = @import("vaxis");
const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");
const config = @import("../core/config.zig");
const session_handle = @import("../core/session_handle.zig");
const attach = @import("attach.zig");
const voice = @import("voice.zig");
const Editor = @import("editor.zig");
const effects = @import("effects.zig");
const media = @import("media.zig");
const render = @import("render.zig");
const top_view = @import("top.zig");
const markdown = @import("markdown.zig");
const layout_mod = @import("layout.zig");
const commands = @import("commands.zig");
const keys = @import("keys.zig");
const setup_mod = @import("setup.zig");
const search_mod = @import("search.zig");
const LayoutCache = layout_mod.LayoutCache;
const TailLayoutCache = layout_mod.TailLayoutCache;
const StreamLayoutCache = layout_mod.StreamLayoutCache;
const RenderBlock = layout_mod.RenderBlock;
const allocDurableRenderBlock = layout_mod.allocDurableRenderBlock;
const layoutBlockRange = layout_mod.layoutBlockRange;
const wrapPromptCard = layout_mod.wrapPromptCard;
const wrapReasoningCard = layout_mod.wrapReasoningCard;
const ExpandPair = layout_mod.ExpandPair;
const scanToolBatch = layout_mod.scanToolBatch;
const Transcript = layout_mod.Transcript;
const InflightCall = layout_mod.InflightCall;
const currentInflightCall = layout_mod.currentInflightCall;
const toolDisplayArg = layout_mod.toolDisplayArg;
const toolDisplayName = layout_mod.toolDisplayName;
const DiffLineNumbers = layout_mod.DiffLineNumbers;
const appendDiffLine = layout_mod.appendDiffLine;
const Palette = render.Palette;
const Line = render.Line;
const nextCpEndFor = render.nextCpEndFor;
const nextWordCol = render.nextWordCol;
const prevWordCol = render.prevWordCol;
const isLegacyRehydration = render.isLegacyRehydration;
const rehydrationLabel = render.rehydrationLabel;
const isCompactionStatusNote = render.isCompactionStatusNote;
const nowWallMs = render.nowWallMs;
const lineWidth = render.lineWidth;
const lineText = render.lineText;
const SyntaxLanguage = render.SyntaxLanguage;
const diffLanguage = render.diffLanguage;
const shellCommandSpans = render.shellCommandSpans;
const gitLogSpans = render.gitLogSpans;
const urlEnd = render.urlEnd;
const findLinkSpans = render.findLinkSpans;
const syntaxForBytes = render.syntaxForBytes;
const applyLineSyntax = render.applyLineSyntax;
const applyLineLinks = render.applyLineLinks;
const SelectionPoint = render.SelectionPoint;
const Selection = render.Selection;
const selectedText = render.selectedText;
const wrapPrefixed = render.wrapPrefixed;
const displayWidth = render.displayWidth;
const hardCellBreak = render.hardCellBreak;
const utf8Floor = render.utf8Floor;
const spaces = render.spaces;
const spinner_frames = render.spinner_frames;

const tui = @import("tui.zig");
const App = tui.App;
const EditCommand = tui.EditCommand;
const Mode = tui.Mode;
const OwnedCouncil = tui.OwnedCouncil;
const PickerKind = tui.PickerKind;
const PlanItemOwned = tui.PlanItemOwned;
const PlanProposalAction = tui.PlanProposalAction;
const RebuildScope = tui.RebuildScope;
const SetupPrompt = tui.SetupPrompt;
const TabActivity = tui.TabActivity;
const TabMouseAction = tui.TabMouseAction;
const TransportVerdicts = tui.TransportVerdicts;
const buildReviewPrompt = tui.buildReviewPrompt;
const commandQuery = tui.commandQuery;
const commandSuggestions = tui.commandSuggestions;
const completeSuggestion = tui.completeSuggestion;
const council_done_item = tui.council_done_item;
const dispatchEvent = tui.dispatchEvent;
const draw = tui.draw;
const drawUiAnimation = tui.drawUiAnimation;
const editCommand = tui.editCommand;
const formatModelPricing = tui.formatModelPricing;
const formatPlanDuration = tui.formatPlanDuration;
const handleKey = tui.handleKey;
const handleMouse = tui.handleMouse;
const hasUnfinishedPlan = tui.hasUnfinishedPlan;
const inputPanelHeight = tui.inputPanelHeight;
const isArchiveCurrentKey = tui.isArchiveCurrentKey;
const isArchivePickerKey = tui.isArchivePickerKey;
const isCommandInput = tui.isCommandInput;
const isEnterKey = tui.isEnterKey;
const isNewSessionKey = tui.isNewSessionKey;
const isNewlineKey = tui.isNewlineKey;
const isNextInputRowKey = tui.isNextInputRowKey;
const isPlanToggleKey = tui.isPlanToggleKey;
const isPreviousInputRowKey = tui.isPreviousInputRowKey;
const layoutLines = tui.layoutLines;
const layoutTabBar = tui.layoutTabBar;
const nextRootTabSid = tui.nextRootTabSid;
const parseOtelCommand = tui.parseOtelCommand;
const pickerModelLine = tui.pickerModelLine;
const planDisplayRange = tui.planDisplayRange;
const planItemTimeMs = tui.planItemTimeMs;
const planMarker = tui.planMarker;
const planProposalAction = tui.planProposalAction;
const planRule = tui.planRule;
const planSurfaceLayout = tui.planSurfaceLayout;
const planTableWidths = tui.planTableWidths;
const reconcilePendingEcho = tui.reconcilePendingEcho;
const rootTabSidAtIndex = tui.rootTabSidAtIndex;
const run = tui.run;
const setup_provider_items = tui.setup_provider_items;
const shortcut_help_rows = tui.shortcut_help_rows;
const statusContext = tui.statusContext;
const statusCwd = tui.statusCwd;
const statusModel = tui.statusModel;
const tabMouseAction = tui.tabMouseAction;
const tabNavigationDirection = tui.tabNavigationDirection;
const transient_animation_frames = tui.transient_animation_frames;
const validCatalogRate = tui.validCatalogRate;

test {
    std.testing.refAllDecls(tui);
}

test "command input: / and ! lead, a leading space sends verbatim" {
    try std.testing.expect(isCommandInput("/model x"));
    try std.testing.expect(isCommandInput("!ls -la"));
    try std.testing.expect(isCommandInput("!"));
    try std.testing.expect(!isCommandInput(" /usr/local/lib/foo.so is missing"));
    try std.testing.expect(!isCommandInput("\t!important"));
    try std.testing.expect(!isCommandInput("plain prose"));
    try std.testing.expect(!isCommandInput(""));
}

test "normal-mode reflexes: Esc cancels pending state, `!cmd` glues, counts do not leak, q detaches" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.mode = .normal;

    // Esc with a half-typed count/operator: cancel it, stay in normal —
    // never drop into insert with the cursor live. A bare Esc goes back to
    // typing, which is what normal mode is an excursion from.
    app.vim.pending_count = 5;
    app.vim.pending_op = 'd';
    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(Mode.normal, app.mode);
    try std.testing.expectEqual(@as(usize, 0), app.vim.pending_count);
    try std.testing.expectEqual(@as(u8, 0), app.vim.pending_op);
    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(Mode.insert, app.mode);
    app.mode = .normal;

    // `5G` consumes its count instead of arming the next `x`.
    try handleKey(&app, .{ .codepoint = '5' });
    try std.testing.expectEqual(@as(usize, 5), app.vim.pending_count);
    try handleKey(&app, .{ .codepoint = 'G' });
    try std.testing.expectEqual(@as(usize, 0), app.vim.pending_count);

    // `:` on an empty composer opens the command menu.
    try handleKey(&app, .{ .codepoint = ':' });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqualStrings("/", app.view.editor.text.items);
    app.view.editor.clear();
    app.mode = .normal;

    // `!ls -la` is a shell escape, not an unknown command.
    app.runCommand("!ls -la");
    try std.testing.expect(app.shell_requested);
    try std.testing.expectEqualStrings("ls -la", app.shell_command.items);
    app.shell_requested = false;
    app.should_quit = false;

    // q detaches immediately, even with live sessions — they keep running
    // in the daemon, so nothing is lost.
    app.replaceSessionSummaries(&.{
        .{ .sid = 1, .title = "busy", .model = "m", .status = "running", .state = .running, .created_at = 1, .running = true },
    });
    try handleKey(&app, .{ .codepoint = 'q' });
    try std.testing.expect(app.should_quit);

    // /detach is an alias for /quit.
    app.should_quit = false;
    app.runCommand("/detach");
    try std.testing.expect(app.should_quit);
}

test "manners: notices expire, the plan offer is not a modal, a background approval rings once" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();

    // Notice TTL: a fresh notice stays; a past deadline clears it on tick.
    app.setNotice("session → 3f2a", .{});
    app.expireNotice();
    try std.testing.expectEqualStrings("session → 3f2a", app.notice.items);
    app.notice_deadline_ms.store(1, .release);
    app.expireNotice();
    try std.testing.expectEqual(@as(usize, 0), app.notice.items.len);
    try std.testing.expectEqual(@as(i64, 0), app.notice_deadline_ms.load(.acquire));

    // A ready plan proposal lets unrelated keys through (j still scrolls)…
    app.mode = .normal;
    app.view.plan_mode = true;
    app.view.plan_proposal_ready = true;
    app.view.state = .idle;
    app.view.scroll_up = 5;
    try handleKey(&app, .{ .codepoint = 'j' });
    try std.testing.expectEqual(@as(usize, 4), app.view.scroll_up);
    try std.testing.expect(app.view.plan_proposal_ready);
    // …and Esc dismisses the offer instead of being a no-op trap.
    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expect(!app.view.plan_proposal_ready);
    try std.testing.expect(app.view.plan_mode);

    // An approval parked on a NON-focused session arms the bell; the
    // focused session's own approval does not.
    app.bell_pending = false;
    app.handleDaemonLine(try gpa.dupe(u8,
        \\{"approval_request":{"sid":2,"approval_id":"7","call_id":"c","tool":"bash","args_json":"{}"}}
    ));
    try std.testing.expect(app.bell_pending);
    app.bell_pending = false;
    app.handleDaemonLine(try gpa.dupe(u8,
        \\{"approval_request":{"sid":1,"approval_id":"8","call_id":"c","tool":"bash","args_json":"{}"}}
    ));
    try std.testing.expect(!app.bell_pending);
    app.bell_enabled = false;
    app.handleDaemonLine(try gpa.dupe(u8,
        \\{"approval_request":{"sid":3,"approval_id":"9","call_id":"c","tool":"bash","args_json":"{}"}}
    ));
    try std.testing.expect(!app.bell_pending);

    // /help opens the panel at the COMMANDS section; keys scroll and close it.
    app.runCommand("/help");
    try std.testing.expect(app.shortcut_help);
    try std.testing.expectEqual(shortcut_help_rows.len, app.help_scroll);
    try handleKey(&app, .{ .codepoint = 'k' });
    try std.testing.expectEqual(shortcut_help_rows.len - 1, app.help_scroll);
    try handleKey(&app, .{ .codepoint = 'q' });
    try std.testing.expect(!app.shortcut_help);
    try std.testing.expectEqual(@as(usize, 0), app.help_scroll);
}

test "composer WORD motions, %, i<, and vim's cw special case" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.mode = .normal;

    // W/E/B are whitespace-delimited where w/e/b split on punctuation.
    app.view.editor.insertSlice("foo-bar baz(qux) end");
    app.view.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'W' });
    try std.testing.expectEqual(@as(usize, 8), app.view.editor.cursor); // "baz(qux)"
    try handleKey(&app, .{ .codepoint = 'E' });
    try std.testing.expectEqual(@as(usize, 16), app.view.editor.cursor); // past ")"
    try handleKey(&app, .{ .codepoint = 'B' });
    try std.testing.expectEqual(@as(usize, 8), app.view.editor.cursor);

    // % jumps between matching brackets, searching forward on the line first.
    try handleKey(&app, .{ .codepoint = '%' }); // from "b" of baz: first bracket is "(" at 11 → ")" at 15
    try std.testing.expectEqual(@as(usize, 15), app.view.editor.cursor);
    try handleKey(&app, .{ .codepoint = '%' });
    try std.testing.expectEqual(@as(usize, 11), app.view.editor.cursor);

    // dW from the start removes the whole punctuated WORD and its space.
    app.view.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'W' });
    try std.testing.expectEqualStrings("baz(qux) end", app.view.editor.text.items);

    // i< is a text object like i( and i[.
    app.view.editor.clear();
    app.view.editor.insertSlice("see <the tag> here");
    app.view.editor.cursor = 7;
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'i' });
    try handleKey(&app, .{ .codepoint = '<' });
    try std.testing.expectEqualStrings("see <> here", app.view.editor.text.items);

    // vim's cw: on a non-blank it changes to the END of the word, keeping the
    // separator — the one place cw and dw legitimately differ.
    app.view.editor.clear();
    app.mode = .normal;
    app.view.editor.insertSlice("foo bar");
    app.view.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'c' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try std.testing.expectEqualStrings(" bar", app.view.editor.text.items);
    try std.testing.expectEqual(Mode.insert, app.mode);
    app.mode = .normal;
    app.view.editor.clear();
    app.view.editor.insertSlice("foo bar");
    app.view.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try std.testing.expectEqualStrings("bar", app.view.editor.text.items);
}

test {
    std.testing.refAllDecls(@This());
}

test "modified enter inserts a newline while plain enter submits" {
    try std.testing.expect(isNewlineKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .shift = true } }));
    try std.testing.expect(isNewlineKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .alt = true } }));
    try std.testing.expect(isNewlineKey(.{ .codepoint = 'j', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!isNewlineKey(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expect(!isNewlineKey(.{ .codepoint = vaxis.Key.enter, .text = "\r" }));
}

test "enter matching accepts terminal and keypad encodings" {
    try std.testing.expect(isEnterKey(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expect(isEnterKey(.{ .codepoint = '\n' }));
    try std.testing.expect(isEnterKey(.{ .codepoint = vaxis.Key.kp_enter }));
    try std.testing.expect(isEnterKey(.{ .codepoint = vaxis.Key.multicodepoint, .text = "\r" }));
    try std.testing.expect(isEnterKey(.{ .codepoint = vaxis.Key.multicodepoint, .text = "\n" }));
    try std.testing.expect(!isEnterKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .shift = true } }));
    try std.testing.expect(!isEnterKey(.{ .codepoint = 'x', .text = "x" }));
}

test "inline Ctrl+R search refines cycles and restores the draft" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    app.view.editor.pushHistory("banana launcher");
    app.view.editor.pushHistory("build release assets");
    app.view.editor.insertSlice("draft in progress");
    try app.history_search.draft.appendSlice(gpa, app.view.editor.text.items);
    app.history_search.draft_cursor = app.view.editor.cursor;
    app.history_search.active = true;
    app.refreshHistorySearch(true);
    try std.testing.expectEqualStrings("build release assets", app.view.editor.text.items);

    try app.history_search.query.append(gpa, 'b');
    app.refreshHistorySearch(true);
    app.cycleHistorySearch();
    try std.testing.expectEqualStrings("banana launcher", app.view.editor.text.items);

    app.history_search.query.clearRetainingCapacity();
    try app.history_search.query.appendSlice(gpa, "bln");
    app.refreshHistorySearch(true);
    try std.testing.expectEqualStrings("banana launcher", app.view.editor.text.items);

    app.cancelHistorySearch();
    try std.testing.expect(!app.history_search.active);
    try std.testing.expectEqualStrings("draft in progress", app.view.editor.text.items);
}

test "model picker formats provider pricing compactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("$3 → $15 / 1M", try formatModelPricing(arena, .{
        .model = "openrouter/paid",
        .input_per_million = 3,
        .output_per_million = 15,
    }));
    try std.testing.expectEqualStrings("$0.125 → $2.5 / 1M · tiered", try formatModelPricing(arena, .{
        .model = "openrouter/tiered",
        .input_per_million = 0.125,
        .output_per_million = 2.5,
        .tiered = true,
    }));
    try std.testing.expectEqualStrings("free", try formatModelPricing(arena, .{ .model = "openrouter/free", .input_per_million = 0, .output_per_million = 0 }));
    try std.testing.expectEqualStrings("price n/a", try formatModelPricing(arena, .{ .model = "openrouter/unknown" }));
    try std.testing.expectEqualStrings(
        " (guest) claudecode/fable",
        try pickerModelLine(arena, "claudecode/fable", null, "", 40),
    );
    try std.testing.expect(std.mem.endsWith(
        u8,
        try pickerModelLine(arena, "openrouter/example/model", null, " ☑", 40),
        " ☑",
    ));
    try std.testing.expectEqual(@as(?f64, null), validCatalogRate(-1));
    try std.testing.expectEqual(@as(?f64, null), validCatalogRate(std.math.nan(f64)));
}

test "model picker accepts priced and legacy catalogs" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();

    app.handleDaemonLine(try gpa.dupe(u8,
        \\{"model_list_result":{"models":["openrouter/example/model"],"pricing":[{"model":"openrouter/example/model","input_per_million":3,"output_per_million":15}]}}
    ));
    try std.testing.expectEqualStrings("openrouter/example/model", app.catalog.items[0]);
    const pricing = app.pricingForModel("openrouter/example/model").?;
    try std.testing.expectEqual(@as(?f64, 3), pricing.input_per_million);
    try std.testing.expectEqual(@as(?f64, 15), pricing.output_per_million);

    app.handleDaemonLine(try gpa.dupe(u8,
        \\{"model_list_result":{"models":["openrouter/legacy/model"]}}
    ));
    try std.testing.expectEqualStrings("openrouter/legacy/model", app.catalog.items[0]);
    try std.testing.expect(app.pricingForModel("openrouter/legacy/model") == null);
}

test "composer suggestions include commands, council actions, and council names" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    var council = OwnedCouncil{ .name = try gpa.dupe(u8, "adversarial") };
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/example/model"));
    try app.councils.append(gpa, council);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    app.view.editor.insertSlice("/com");
    var suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/compact", suggestions[0].label);

    app.view.editor.clear();
    app.view.editor.insertSlice("/council n");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/council new", suggestions[0].label);
    try std.testing.expect(!suggestions[0].submit_on_enter);

    app.view.editor.clear();
    app.view.editor.insertSlice("/council adv");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/council adversarial", suggestions[0].label);
    try std.testing.expect(suggestions[0].submit_on_enter);

    completeSuggestion(&app.view.editor, suggestions[0], false);
    try std.testing.expectEqualStrings("/council adversarial", app.view.editor.text.items);

    app.view.editor.clear();
    app.view.editor.insertSlice("/review adv");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/review adversarial", suggestions[0].label);
    try std.testing.expect(!suggestions[0].submit_on_enter);

    completeSuggestion(&app.view.editor, suggestions[0], false);
    try std.testing.expectEqualStrings("/review adversarial ", app.view.editor.text.items);
    try std.testing.expect(commandQuery(&app.view.editor) == null);

    app.view.editor.clear();
    app.view.editor.insertSlice("/otel s");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), suggestions.len);
    try std.testing.expectEqualStrings("/otel set", suggestions[0].label);
    try std.testing.expect(!suggestions[0].submit_on_enter);
    try std.testing.expectEqualStrings("/otel status", suggestions[1].label);
    try std.testing.expect(suggestions[1].submit_on_enter);

    app.view.editor.clear();
    app.view.editor.insertSlice("/plan c");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/plan clear", suggestions[0].label);
    try std.testing.expect(suggestions[0].submit_on_enter);

    app.view.editor.clear();
    app.view.editor.insertSlice("/animate m");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), suggestions.len); // matrix, metaballs
    try std.testing.expectEqualStrings("/animate matrix", suggestions[0].label);
    try std.testing.expectEqualStrings("/animate metaballs", suggestions[1].label);
    try std.testing.expect(suggestions[0].submit_on_enter);

    app.view.editor.clear();
    app.view.editor.insertSlice("/animate s");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 3), suggestions.len); // strings, stars, shadowbox
    try std.testing.expectEqualStrings("/animate strings", suggestions[0].label);
    try std.testing.expectEqualStrings("/animate stars", suggestions[1].label);
    try std.testing.expectEqualStrings("/animate shadowbox", suggestions[2].label);

    app.view.editor.clear();
    app.view.editor.insertSlice("/screensaver p");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), suggestions.len); // plasma, pacman
    try std.testing.expectEqualStrings("/screensaver plasma", suggestions[0].label);
    try std.testing.expectEqualStrings("/screensaver pacman", suggestions[1].label);

    app.view.editor.clear();
    app.view.editor.insertSlice("/screensaver tu");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/screensaver tunnel", suggestions[0].label);

    app.view.editor.clear();
    app.view.editor.insertSlice("!rb c");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("!rb client", suggestions[0].label);
    try std.testing.expect(suggestions[0].submit_on_enter);
}

test "named animations and screensavers share the selected effect engine" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.runCommand("/animate strings");
    try std.testing.expectEqual(effects.Kind.strings, app.ui_animation.?);
    try std.testing.expectEqual(effects.Kind.strings, app.effect_engine.?.kind());
    app.tickUiAnimation();
    try std.testing.expectEqual(@as(u64, 1), app.effect_engine.?.strings.frame);

    for (1..transient_animation_frames) |_| app.tickUiAnimation();
    try std.testing.expect(app.ui_animation == null);
    try std.testing.expect(!app.ui_animation_active.load(.acquire));

    app.runCommand("/screensaver stars");
    try std.testing.expect(app.screensaver_active);
    try std.testing.expectEqual(effects.Kind.matrix, app.screensaver_kind);
    try std.testing.expectEqual(effects.Kind.stars, app.effect_engine.?.kind());
    app.tickUiAnimation();
    try std.testing.expectEqual(@as(u64, 1), app.effect_engine.?.stars.frame);
    try std.testing.expect(app.dismissScreensaver());

    // `!s [effect]` is the /screensaver shortcut, not a shell escape.
    app.runCommand("!s strings");
    try std.testing.expect(app.screensaver_active);
    try std.testing.expect(!app.shell_requested);
    try std.testing.expectEqual(effects.Kind.strings, app.effect_engine.?.kind());
    try std.testing.expect(app.dismissScreensaver());
}

test "all effects preserve text transiently and cover it as screensavers" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .term_cols = 48,
        .term_rows = 18,
    };
    defer app.deinit();

    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 18,
        .cols = 48,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 48,
        .height = 18,
        .screen = &screen,
    };
    const baseline: vaxis.Style = .{ .fg = .{ .index = 4 }, .bg = .{ .index = 5 } };

    for (effects.kinds) |kind| {
        try std.testing.expect(app.resetEffectEngine(kind));
        // No Kitty graphics in a test App: pixel kinds start as their cell sibling.
        try std.testing.expectEqual(kind.fallback(), app.effect_engine.?.kind());
        for (0..40) |_| app.effect_engine.?.tick();
        win.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = baseline });
        win.writeCell(10, 8, .{ .char = .{ .grapheme = "x", .width = 1 }, .style = baseline });

        app.ui_animation = kind;
        app.ui_animation_frame = 30;
        app.screensaver_active = false;
        drawUiAnimation(&app, win);
        if (app.effect_engine.?.kind().fullScreenOnly()) {
            // The maze has no interleaved form: a transient run is opaque.
            try std.testing.expect(!std.mem.eql(u8, win.readCell(10, 8).?.char.grapheme, "x"));
        } else {
            try std.testing.expectEqualStrings("x", win.readCell(10, 8).?.char.grapheme);
        }

        app.ui_animation = null;
        app.screensaver_active = true;
        drawUiAnimation(&app, win);
        try std.testing.expect(!std.mem.eql(u8, win.readCell(10, 8).?.char.grapheme, "x"));
    }
}

test "pixel effects start as themselves only with Kitty graphics" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .term_cols = 80,
        .term_rows = 24,
    };
    defer app.deinit();

    try std.testing.expect(app.resetEffectEngine(.tunnel));
    try std.testing.expectEqual(effects.Kind.plasma, app.effect_engine.?.kind());
    try std.testing.expect(std.mem.indexOf(u8, app.notice.items, "needs Kitty graphics") != null);
    // Pac-Man keeps its kind and drops to its cell renderer.
    try std.testing.expect(app.resetEffectEngine(.pacman));
    try std.testing.expectEqual(effects.Kind.pacman, app.effect_engine.?.kind());
    try std.testing.expect(!app.effect_engine.?.isPixel());
    try std.testing.expect(std.mem.indexOf(u8, app.notice.items, "pacman on cells") != null);

    app.kitty_graphics = true;
    app.cell_px_w = 8;
    app.cell_px_h = 16;
    try std.testing.expect(app.resetEffectEngine(.tunnel));
    try std.testing.expectEqual(effects.Kind.tunnel, app.effect_engine.?.kind());
    try std.testing.expect(app.effect_engine.?.isPixel());
    try std.testing.expect(!app.effect_engine.?.hasImage()); // nothing transmitted yet
    app.effect_engine.?.tick();
    try std.testing.expect(app.resetEffectEngine(.pacman));
    try std.testing.expectEqual(effects.Kind.pacman, app.effect_engine.?.kind());
    try std.testing.expect(app.effect_engine.?.isPixel());
}

test "manual screensaver wake consumes the first input event" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    app.startScreensaver(app.screensaver_kind);

    var verdicts = TransportVerdicts{};
    try dispatchEvent(
        &app,
        undefined,
        undefined,
        gpa,
        .{ .key_press = .{ .codepoint = 'a', .text = "a" } },
        &verdicts,
    );
    try std.testing.expect(!app.screensaver_active);
    try std.testing.expect(app.view.editor.isEmpty());
}

test "a lone modifier neither wakes the screensaver nor counts as activity" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .screensaver_timeout_ms = 1_000,
    };
    defer app.deinit();
    const deadline = nowWallMs(app.io) + 500;
    app.screensaver_deadline_ms.store(deadline, .release);
    app.startScreensaver(app.screensaver_kind);

    // cmd-tab away from the terminal: the kitty protocol reports the lone
    // cmd press itself, which must not tear the screensaver down.
    var verdicts = TransportVerdicts{};
    try dispatchEvent(
        &app,
        undefined,
        undefined,
        gpa,
        .{ .key_press = .{ .codepoint = vaxis.Key.left_super } },
        &verdicts,
    );
    try std.testing.expect(app.screensaver_active);
    try std.testing.expectEqual(deadline, app.screensaver_deadline_ms.load(.acquire));

    // A real key still dismisses.
    try dispatchEvent(
        &app,
        undefined,
        undefined,
        gpa,
        .{ .key_press = .{ .codepoint = 'a', .text = "a" } },
        &verdicts,
    );
    try std.testing.expect(!app.screensaver_active);
}

test "mouse activity neither wakes nor postpones the screensaver" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .screensaver_timeout_ms = 1_000,
    };
    defer app.deinit();
    const deadline = nowWallMs(app.io) + 500;
    app.screensaver_deadline_ms.store(deadline, .release);

    var verdicts = TransportVerdicts{};
    try dispatchEvent(
        &app,
        undefined,
        undefined,
        gpa,
        .{ .mouse = .{ .col = 0, .row = 0, .button = .none, .mods = .{}, .type = .motion } },
        &verdicts,
    );
    try std.testing.expectEqual(deadline, app.screensaver_deadline_ms.load(.acquire));

    app.startScreensaver(app.screensaver_kind);
    try dispatchEvent(
        &app,
        undefined,
        undefined,
        gpa,
        .{ .mouse = .{ .col = 0, .row = 0, .button = .none, .mods = .{}, .type = .motion } },
        &verdicts,
    );
    try std.testing.expect(app.screensaver_active);
}

test "idle deadline starts the screensaver without daemon activity" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .screensaver_timeout_ms = 1_000,
    };
    defer app.deinit();
    app.screensaver_deadline_ms.store(nowWallMs(app.io) - 1, .release);
    app.tickUiAnimation();
    try std.testing.expect(app.screensaver_active);
}

test "gs starts the screensaver and returns to insert mode" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .mode = .normal,
    };
    defer app.deinit();
    try handleKey(&app, .{ .codepoint = 'g' });
    try handleKey(&app, .{ .codepoint = 's' });
    try std.testing.expect(app.screensaver_active);
    try std.testing.expectEqual(Mode.insert, app.mode);
}

test "command menu Tab completes and Enter runs the selection" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined, // completion and /help are entirely client-local
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.view.editor.insertSlice("/mo");
    try handleKey(&app, .{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqualStrings("/model ", app.view.editor.text.items);

    app.view.editor.clear();
    app.view.editor.insertSlice("/he");
    try handleKey(&app, .{ .codepoint = vaxis.Key.enter });
    try std.testing.expect(app.view.editor.isEmpty());
    try std.testing.expectEqualStrings("/help", app.view.editor.history.items[0]);
    try std.testing.expect(app.shortcut_help); // /help opens the panel at COMMANDS
}

test "history walks past recalled local commands without autocomplete capture" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.view.editor.pushHistory("ordinary prompt");
    app.view.editor.pushHistory("/help");
    try handleKey(&app, .{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqualStrings("/help", app.view.editor.text.items);
    try std.testing.expect(app.view.editor.isWalkingHistory());

    // `/help` matches the command menu, but this second Up still belongs to
    // history because the text was recalled rather than freshly typed.
    try handleKey(&app, .{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqualStrings("ordinary prompt", app.view.editor.text.items);
}

test "council list opens inspection before explicit editing" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    var council = OwnedCouncil{ .name = try gpa.dupe(u8, "core") };
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/example/model"));
    try app.councils.append(gpa, council);
    try app.catalog.append(gpa, try gpa.dupe(u8, "openrouter/example/model"));

    app.openCouncilList();
    try std.testing.expectEqual(PickerKind.council_list, app.picker_kind);
    try std.testing.expectEqual(@as(?usize, 0), app.picker);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const items = try app.pickerItems(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("core", items[0]);

    try handleKey(&app, .{ .codepoint = vaxis.Key.enter });
    try std.testing.expect(app.picker == null);
    try std.testing.expectEqualStrings("core", app.council_detail_name.items);
    try std.testing.expectEqual(@as(usize, 0), app.council_edit_models.items.len);

    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(@as(usize, 0), app.council_detail_name.items.len);

    app.runCommand("/council core");
    try std.testing.expectEqualStrings("core", app.council_detail_name.items);
    try std.testing.expectEqual(@as(usize, 0), app.council_edit_models.items.len);

    try handleKey(&app, .{ .codepoint = 'e', .text = "e" });
    try std.testing.expectEqual(@as(usize, 0), app.council_detail_name.items.len);
    try std.testing.expectEqual(PickerKind.council, app.picker_kind);
    try std.testing.expectEqualStrings("core", app.council_edit_name.items);
    try std.testing.expect(app.councilModelSelected("openrouter/example/model"));
}

test "council picker reuses catalog with Done and checked multi-select seats" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    try app.catalog.append(gpa, try gpa.dupe(u8, "openrouter/x-ai/grok-4.6"));
    try app.catalog.append(gpa, try gpa.dupe(u8, "openrouter/z-ai/glm-5.3"));
    var council = OwnedCouncil{ .name = try gpa.dupe(u8, "core") };
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/z-ai/glm-5.3"));
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/legacy/retired-model"));
    try app.councils.append(gpa, council);

    app.runCommand("/council edit core");
    try std.testing.expectEqual(PickerKind.council, app.picker_kind);
    try std.testing.expectEqual(@as(?usize, 0), app.picker);
    try std.testing.expectEqualStrings("core", app.council_edit_name.items);
    try std.testing.expect(app.councilModelSelected("openrouter/z-ai/glm-5.3"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const items = try app.pickerItems(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings(council_done_item, items[0]);
    try std.testing.expectEqualStrings("openrouter/legacy/retired-model", items[3]);

    app.picker = 1;
    try handleKey(&app, .{ .codepoint = vaxis.Key.multicodepoint, .text = "\r" });
    try std.testing.expect(app.councilModelSelected("openrouter/x-ai/grok-4.6"));
    try std.testing.expectEqual(@as(?usize, 1), app.picker);

    try app.picker_filter.appendSlice(gpa, "glm");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    const filtered = try app.pickerItems(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqualStrings(council_done_item, filtered[0]);
    try std.testing.expectEqualStrings("openrouter/z-ai/glm-5.3", filtered[1]);

    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expect(app.picker == null);
    try std.testing.expectEqual(@as(usize, 0), app.council_edit_models.items.len);
    try std.testing.expectEqualStrings("council edit cancelled", app.notice.items);
    try std.testing.expectEqual(@as(usize, 2), app.councils.items[0].models.items.len);
}

test "council Done refuses an empty roster without closing the picker" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .picker_kind = .council,
        .picker = 0,
    };
    defer app.deinit();
    try app.council_edit_name.appendSlice(gpa, "empty");
    try app.catalog.append(gpa, try gpa.dupe(u8, "openrouter/x-ai/grok-4.6"));

    try handleKey(&app, .{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqual(@as(?usize, 0), app.picker);
    try std.testing.expectEqualStrings("choose at least one model before Done", app.notice.items);
}

test "/effort opens the shared selector vocabulary" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined, // opening and filtering the selector are local
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.view.effort = .high;
    app.runCommand("/effort");
    try std.testing.expectEqual(PickerKind.effort, app.picker_kind);
    try std.testing.expectEqual(@as(?usize, 5), app.picker);
    try std.testing.expectEqualStrings("auto", app.pickerSource()[0]);
    try std.testing.expectEqualStrings("max", app.pickerSource()[proto.ReasoningEffort.choices.len - 1]);
    try std.testing.expectEqualStrings("high", app.pickerCurrent());
}

test "OTEL command parsing is vendor-neutral and strict" {
    try std.testing.expect(parseOtelCommand(null, "").? == .status);
    try std.testing.expect(parseOtelCommand("status", "").? == .status);
    try std.testing.expect(parseOtelCommand("off", "").? == .off);
    const set = parseOtelCommand("set", " https://otel.example ").?;
    try std.testing.expectEqualStrings("https://otel.example", set.set);
    try std.testing.expect(parseOtelCommand("set", "") == null);
    try std.testing.expect(parseOtelCommand("set", "https://otel.example extra") == null);
    try std.testing.expect(parseOtelCommand("mirador", "") == null);
}

test "provider setup distinguishes installed guests and advances custom fields without history" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.setup.readiness.codex_available = true;
    try std.testing.expectEqualStrings("  · login needed", app.setupProviderNote(setup_provider_items[1]));
    app.setup.readiness.codex_authenticated = true;
    try std.testing.expectEqualStrings("  ✓ signed in", app.setupProviderNote(setup_provider_items[1]));

    app.setupProviderChosen(setup_provider_items[7]);
    try std.testing.expectEqual(SetupPrompt.provider_name, app.setup.prompt);
    app.submitSetupPrompt("acme");
    try std.testing.expectEqual(SetupPrompt.base_url, app.setup.prompt);
    try std.testing.expectEqualStrings("ACME_API_KEY", app.setup.api_key_env.items);
    app.submitSetupPrompt("https://gateway.acme.test/v1");
    try std.testing.expectEqual(SetupPrompt.credential, app.setup.prompt);
    app.submitSetupPrompt("");
    try std.testing.expectEqual(SetupPrompt.model, app.setup.prompt);
    try std.testing.expectEqualStrings("NONE", app.setup.api_key_env.items);
    try std.testing.expectEqualStrings("acme/", app.view.editor.text.items);
    try std.testing.expectEqual(@as(usize, 0), app.view.editor.history.items.len);
    app.submitSetupPrompt("acme/");
    try std.testing.expectEqual(SetupPrompt.model, app.setup.prompt);
    try std.testing.expectEqualStrings("model id needs a name after provider/", app.notice.items);
}

test "required provider setup still permits an explicit quit" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .setup = .{ .required = true },
    };
    defer app.deinit();

    app.submitInput("/quit");
    try std.testing.expect(app.should_quit);
}

test "bang shell escape captures commands and bare interactive requests" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.submitInput("! printf 'hello world'");
    try std.testing.expect(app.shell_requested);
    try std.testing.expect(app.should_quit);
    try std.testing.expectEqualStrings("printf 'hello world'", app.shell_command.items);
    try std.testing.expectEqualStrings("! printf 'hello world'", app.view.editor.history.items[0]);

    app.should_quit = false;
    app.shell_requested = false;
    app.runCommand("!");
    try std.testing.expect(app.shell_requested);
    try std.testing.expect(app.should_quit);
    try std.testing.expectEqualStrings("", app.shell_command.items);
}

test "bang shell escape refuses remote transport" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .remote_transport = true,
    };
    defer app.deinit();

    app.runCommand("! pwd");
    try std.testing.expect(!app.shell_requested);
    try std.testing.expect(!app.should_quit);
    try std.testing.expect(std.mem.indexOf(u8, app.notice.items, "--remote") != null);
}

test "bang rb expands to reboot with build" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.submitInput("!rb");
    try std.testing.expect(app.reboot_request.requested);
    try std.testing.expectEqual(RebuildScope.attached, app.reboot_request.rebuild);
    try std.testing.expect(!app.reboot_request.force);
    try std.testing.expect(app.should_quit);
    try std.testing.expectEqualStrings("!rb", app.view.editor.history.items[0]);
}

test "bang rb supports client and both scopes" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.runCommand("!rb client");
    try std.testing.expectEqual(RebuildScope.client, app.reboot_request.rebuild);

    app.should_quit = false;
    app.reboot_request = .{};
    app.runCommand("!rb both --force");
    try std.testing.expectEqual(RebuildScope.both, app.reboot_request.rebuild);
    try std.testing.expect(app.reboot_request.force);
}

test "plain reboot refuses a focused approval unless forced" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
            .state = .awaiting_approval,
        },
    };
    defer app.deinit();

    app.runCommand("/reboot");
    try std.testing.expect(!app.reboot_request.requested);
    try std.testing.expect(!app.should_quit);
    try std.testing.expect(std.mem.indexOf(u8, app.notice.items, "approval pending") != null);

    app.runCommand("/reboot --build --force");
    try std.testing.expect(app.reboot_request.requested);
    try std.testing.expectEqual(RebuildScope.attached, app.reboot_request.rebuild);
    try std.testing.expect(app.reboot_request.force);
    try std.testing.expect(app.should_quit);
}

test "standard editor key bindings map to commands" {
    const Case = struct { key: vaxis.Key, command: EditCommand };
    const cases = [_]Case{
        .{ .key = .{ .codepoint = vaxis.Key.left }, .command = .move_left },
        .{ .key = .{ .codepoint = 'b', .mods = .{ .ctrl = true } }, .command = .move_left },
        .{ .key = .{ .codepoint = vaxis.Key.right }, .command = .move_right },
        .{ .key = .{ .codepoint = 'f', .mods = .{ .ctrl = true } }, .command = .move_right },
        .{ .key = .{ .codepoint = vaxis.Key.left, .mods = .{ .alt = true } }, .command = .move_word_left },
        .{ .key = .{ .codepoint = 'b', .mods = .{ .alt = true } }, .command = .move_word_left },
        .{ .key = .{ .codepoint = vaxis.Key.right, .mods = .{ .alt = true } }, .command = .move_word_right },
        .{ .key = .{ .codepoint = 'f', .mods = .{ .alt = true } }, .command = .move_word_right },
        .{ .key = .{ .codepoint = vaxis.Key.home }, .command = .move_line_start },
        .{ .key = .{ .codepoint = 'a', .mods = .{ .ctrl = true } }, .command = .move_line_start },
        .{ .key = .{ .codepoint = vaxis.Key.end }, .command = .move_line_end },
        .{ .key = .{ .codepoint = 'e', .mods = .{ .ctrl = true } }, .command = .move_line_end },
        .{ .key = .{ .codepoint = vaxis.Key.backspace }, .command = .delete_before },
        .{ .key = .{ .codepoint = 'h', .mods = .{ .ctrl = true } }, .command = .delete_before },
        .{ .key = .{ .codepoint = vaxis.Key.delete }, .command = .delete_after },
        .{ .key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } }, .command = .delete_after },
        .{ .key = .{ .codepoint = vaxis.Key.backspace, .mods = .{ .alt = true } }, .command = .delete_word_before },
        .{ .key = .{ .codepoint = 'w', .mods = .{ .ctrl = true } }, .command = .delete_word_before_whitespace },
        .{ .key = .{ .codepoint = vaxis.Key.delete, .mods = .{ .alt = true } }, .command = .delete_word_after },
        .{ .key = .{ .codepoint = 'd', .mods = .{ .alt = true } }, .command = .delete_word_after },
        .{ .key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } }, .command = .delete_to_line_start },
        .{ .key = .{ .codepoint = 'k', .mods = .{ .ctrl = true } }, .command = .delete_to_line_end },
    };
    for (cases) |case| try std.testing.expectEqual(case.command, editCommand(case.key).?);

    try std.testing.expect(isPreviousInputRowKey(.{ .codepoint = vaxis.Key.up }));
    try std.testing.expect(isPreviousInputRowKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } }));
    try std.testing.expect(isNextInputRowKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expect(!isNextInputRowKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
    try std.testing.expect(isNewSessionKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!isNewSessionKey(.{ .codepoint = 'n' }));
}

test "normal-mode tab shortcuts recognize angle brackets and arrows" {
    try std.testing.expectEqual(@as(?i8, 1), tabNavigationDirection(.{ .codepoint = '>' }));
    try std.testing.expectEqual(@as(?i8, -1), tabNavigationDirection(.{ .codepoint = '<' }));
    try std.testing.expectEqual(@as(?i8, 1), tabNavigationDirection(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(@as(?i8, -1), tabNavigationDirection(.{ .codepoint = vaxis.Key.left }));
    // Kitty reports the physical key plus shifted codepoint in its enhanced
    // keyboard mode; Key.matches must recognize that real terminal shape too.
    try std.testing.expectEqual(@as(?i8, 1), tabNavigationDirection(.{
        .codepoint = '.',
        .shifted_codepoint = '>',
        .text = ">",
        .mods = .{ .shift = true },
    }));
    try std.testing.expectEqual(@as(?i8, null), tabNavigationDirection(.{ .codepoint = 'h' }));
}

test "Ctrl+L clears transient view state without touching the draft" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
            .scroll_up = 12,
            .sel_anchor = .{ .line = 2, .col = 3 },
            .sel_dragging = true,
            .copy_pending = true,
        },
    };
    defer app.deinit();
    app.view.editor.insertSlice("draft survives");
    app.setNotice("old notice", .{});

    try handleKey(&app, .{ .codepoint = 'l', .mods = .{ .ctrl = true } });

    try std.testing.expectEqual(@as(usize, 0), app.view.scroll_up);
    try std.testing.expect(app.view.sel_anchor == null);
    try std.testing.expect(!app.view.sel_dragging);
    try std.testing.expect(!app.view.copy_pending);
    try std.testing.expect(app.refresh_requested);
    try std.testing.expectEqualStrings("", app.notice.items);
    try std.testing.expectEqualStrings("draft survives", app.view.editor.text.items);
}

test "Ctrl+C never exits an idle TUI or destroys its draft" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    app.view.editor.insertSlice("draft survives");

    try handleKey(&app, .{ .codepoint = 'c', .mods = .{ .ctrl = true } });

    try std.testing.expect(!app.should_quit);
    try std.testing.expectEqualStrings("draft survives", app.view.editor.text.items);
    try std.testing.expectEqualStrings("nothing to interrupt · q or /quit exits", app.notice.items);
}

test "correlated session creation replies clear only the matching pending request" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .awaiting_new_session = true,
        .pending_new_session_request_id = 77,
    };
    defer app.deinit();
    try app.pending_new_cwd.appendSlice(gpa, "/work");

    const unrelated = try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "request_failed",
        .msg = "other request failed",
        .request_id = 76,
    } });
    app.handleDaemonLine(unrelated);
    try std.testing.expect(app.awaiting_new_session);
    try std.testing.expectEqual(@as(u64, 77), app.pending_new_session_request_id);

    const matching = try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "request_failed",
        .msg = "create failed",
        .request_id = 77,
    } });
    app.handleDaemonLine(matching);
    try std.testing.expect(!app.awaiting_new_session);
    try std.testing.expectEqual(@as(u64, 0), app.pending_new_session_request_id);
    try std.testing.expectEqual(@as(usize, 0), app.pending_new_cwd.items.len);
}

test "session picker reserves archive chords without stealing filter text" {
    try std.testing.expect(isArchivePickerKey(.session, .{ .codepoint = vaxis.Key.delete }));
    try std.testing.expect(isArchivePickerKey(.session, .{ .codepoint = 'd', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!isArchivePickerKey(.session, .{ .codepoint = 'a' }));
    try std.testing.expect(!isArchivePickerKey(.session, .{ .codepoint = 'q' }));
    try std.testing.expect(!isArchivePickerKey(.model, .{ .codepoint = vaxis.Key.delete }));
}

test "Ctrl+N aliases /new in either mode while pickers keep navigation" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        // Avoid touching the deliberately absent test connection: this also
        // verifies key repeat cannot issue a second create request.
        .awaiting_new_session = true,
    };
    defer app.deinit();
    app.view.editor.insertSlice("draft survives");

    for ([_]Mode{ .insert, .normal }) |mode| {
        app.mode = mode;
        try handleKey(&app, .{ .codepoint = 'n', .mods = .{ .ctrl = true } });
        try std.testing.expectEqualStrings("new session already being created", app.notice.items);
        try std.testing.expectEqualStrings("draft survives", app.view.editor.text.items);
    }

    app.awaiting_new_session = false;
    app.picker_kind = .effort;
    app.picker = 0;
    try handleKey(&app, .{ .codepoint = 'n', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(?usize, 1), app.picker);
    try std.testing.expect(!app.awaiting_new_session);
}

test "staging images inserts numbered prompt placeholders" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.view.editor.insertSlice("compare");
    app.addAttachment(.{
        .name = try gpa.dupe(u8, "first.png"),
        .mime = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "AA=="),
    });
    app.addAttachment(.{
        .name = try gpa.dupe(u8, "second.png"),
        .mime = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "AA=="),
    });

    try std.testing.expectEqualStrings("compare [image #1] [image #2] ", app.view.editor.text.items);
    try std.testing.expectEqual(@as(usize, 2), app.attachments.items.len);
}

test "Ctrl+W archives only a truly empty composer outside copy mode; Ctrl+D never does" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    const ctrl_d = vaxis.Key{ .codepoint = 'd', .mods = .{ .ctrl = true } };
    const ctrl_w = vaxis.Key{ .codepoint = 'w', .mods = .{ .ctrl = true } };

    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_d)); // page-down while reading, never archive
    try std.testing.expect(isArchiveCurrentKey(&app, ctrl_w));
    try std.testing.expect(!isArchiveCurrentKey(&app, .{ .codepoint = 'd' }));
    try std.testing.expect(!isArchiveCurrentKey(&app, .{ .codepoint = 'w' }));

    app.view.editor.insertSlice("draft survives");
    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_d));
    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_w));
    app.view.editor.clear();

    try app.attachments.append(gpa, .{
        .name = try gpa.dupe(u8, "image.png"),
        .mime = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "AA=="),
    });
    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_d));
    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_w));
    app.clearAttachments();

    app.copy_cursor = .{ .line = 0, .col = 0 };
    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_d));
    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_w));
    app.copy_cursor = null;

    // The shared /archive path retains its running-session guard.
    app.view.state = .running;
    try handleKey(&app, ctrl_w);
    try std.testing.expect(std.mem.indexOf(u8, app.notice.items, "interrupt it first") != null);
}

test "Escape closes an active picker, then a bare Escape returns to insert" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
        .mode = .normal,
        .picker = 0,
    };
    defer app.deinit();
    app.view.editor.insertSlice("draft survives");

    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(Mode.normal, app.mode);
    try std.testing.expect(app.picker == null);

    // Nothing pending: Esc is the way back to typing; the draft survives.
    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqualStrings("draft survives", app.view.editor.text.items);
}

test "question mark opens modal shortcut help in normal mode" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
            .scroll_up = 8,
        },
        .mode = .normal,
    };
    defer app.deinit();

    try handleKey(&app, .{ .codepoint = '?' });
    try std.testing.expect(app.shortcut_help);

    try handleKey(&app, .{ .codepoint = 'j' });
    try std.testing.expectEqual(@as(usize, 8), app.view.scroll_up);
    try std.testing.expect(app.shortcut_help);

    try handleKey(&app, .{ .codepoint = 'q' });
    try std.testing.expect(!app.shortcut_help);
    try std.testing.expect(!app.should_quit);

    try handleKey(&app, .{ .codepoint = '?' });
    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expect(!app.shortcut_help);
    try std.testing.expectEqual(Mode.normal, app.mode);
}

test "a A I enter insert mode with vim cursor placement" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.view.editor.insertSlice("hello");
    app.view.editor.moveLineStart();
    app.mode = .normal;

    try handleKey(&app, .{ .codepoint = 'A', .mods = .{ .shift = true } });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(app.view.editor.text.items.len, app.view.editor.cursor);

    app.mode = .normal;
    try handleKey(&app, .{ .codepoint = 'I', .mods = .{ .shift = true } });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(@as(usize, 0), app.view.editor.cursor);

    app.mode = .normal;
    try handleKey(&app, .{ .codepoint = 'a' });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(@as(usize, 1), app.view.editor.cursor);
}

test "archive has no single-key binding; a enters insert even mid-turn" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
            .state = .running,
        },
        .mode = .normal,
    };
    defer app.deinit();

    try handleKey(&app, .{ .codepoint = 'a' });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(@as(usize, 0), app.notice.items.len);
}

test "selection is character precise on one or many lines" {
    const same = Selection.init(.{ .line = 4, .col = 8 }, .{ .line = 4, .col = 2 });
    const same_cols = same.columns(4, 20).?;
    try std.testing.expectEqual(@as(usize, 2), same_cols.start);
    try std.testing.expectEqual(@as(usize, 9), same_cols.end);

    const multi = Selection.init(.{ .line = 2, .col = 3 }, .{ .line = 4, .col = 5 });
    const first = multi.columns(2, 10).?;
    try std.testing.expectEqual(@as(usize, 3), first.start);
    try std.testing.expectEqual(@as(usize, 10), first.end);
    const middle = multi.columns(3, 10).?;
    try std.testing.expectEqual(@as(usize, 0), middle.start);
    try std.testing.expectEqual(@as(usize, 10), middle.end);
    const last = multi.columns(4, 10).?;
    try std.testing.expectEqual(@as(usize, 0), last.start);
    try std.testing.expectEqual(@as(usize, 6), last.end);
    try std.testing.expect(multi.columns(1, 10) == null);
}

test "one-line composer and scrollback prompt cards are three rows" {
    try std.testing.expectEqual(@as(usize, 3), inputPanelHeight(1));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapPromptCard(arena, &lines, "ship it", 80);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expect(lines.items[0].fill_style != null);
    try std.testing.expectEqualStrings(" ❯ ", lines.items[1].text);
    try std.testing.expectEqualStrings("ship it", lines.items[1].text2);
    try std.testing.expect(lines.items[2].fill_style != null);
}

test "reasoning cards are muted, padded, and inset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapReasoningCard(
        arena,
        &lines,
        "I am checking the implementation evidence before mapping it against the milestone exit criteria.",
        38,
    );

    // Content-only: no leading/trailing blanks — the layout loop owns air.
    try std.testing.expect(lines.items.len >= 2); // wrapped body
    try std.testing.expectEqualStrings("  · ", lines.items[0].text);
    try std.testing.expect(lines.items[0].style.bold);
    try std.testing.expect(lines.items[lines.items.len - 1].text2.len > 0);
    // Completed commentary is secondary narration: the same muted index-7
    // grey it streamed in as, one step below the assistant's final prose.
    try std.testing.expect(!lines.items[0].style2.italic);
    try std.testing.expect(!lines.items[0].style2.bold);
    try std.testing.expect(vaxis.Color.eql(lines.items[0].style2.fg, Palette.reasoning.fg));
    for (lines.items) |line| {
        // Flat CC-style narration: no background panel, ever — a filled
        // card highlighted the least important content and its padding
        // could not sit symmetric against reused separator rows.
        try std.testing.expect(line.fill_style == null);
        try std.testing.expect(displayWidth(try lineText(arena, line)) <= 36);
    }
}

test "bash previews distinguish commands flags operators strings and paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const command = "git log --oneline --decorate -8 && printf '\\n--- current ---\\n' && git diff --stat ./src";
    const spans = try shellCommandSpans(arena, command, 0);

    const first_git = syntaxForBytes(spans, 0, 1).?;
    const flag_at = std.mem.indexOf(u8, command, "--oneline").?;
    const operator_at = std.mem.indexOf(u8, command, "&&").?;
    const string_at = std.mem.indexOfScalar(u8, command, '\'').?;
    const printf_at = std.mem.indexOf(u8, command, "printf").?;
    const path_at = std.mem.indexOf(u8, command, "./src").?;

    try std.testing.expect(vaxis.Color.eql(first_git.fg, Palette.shell_executable.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, flag_at, flag_at + 1).?.fg, Palette.shell_flag.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, operator_at, operator_at + 1).?.fg, Palette.shell_operator.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, string_at, string_at + 1).?.fg, Palette.shell_string.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, printf_at, printf_at + 1).?.fg, Palette.shell_executable.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, path_at, path_at + 1).?.fg, Palette.shell_path.fg));
}

test "git oneline output separates hash refs and subject" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const line = "d892bef (HEAD -> main) Polish TUI output and reasoning controls";
    const spans = try gitLogSpans(arena_state.allocator(), line, 4);

    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(@as(usize, 4), spans[0].start);
    try std.testing.expectEqual(@as(usize, 11), spans[0].end);
    try std.testing.expect(vaxis.Color.eql(spans[0].style.fg, Palette.git_hash.fg));
    try std.testing.expect(vaxis.Color.eql(spans[1].style.fg, Palette.git_ref.fg));
    try std.testing.expectEqual(@as(usize, 0), (try gitLogSpans(arena_state.allocator(), "not a git log line", 4)).len);
}

test "status metadata is compact without losing its identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "anthropic/claude-sonnet-4.5",
        try statusModel(arena, "openrouter/anthropic/claude-sonnet-4.5"),
    );
    try std.testing.expectEqualStrings(
        "(guest) fable",
        try statusModel(arena, "claudecode/fable"),
    );
    try std.testing.expectEqualStrings(
        "(guest) codex/default",
        try statusModel(arena, "codex/default"),
    );
    try std.testing.expectEqualStrings("ctx n/a", try statusContext(arena, true, 0, 200_000));
    try std.testing.expectEqualStrings("ctx 12%", try statusContext(arena, false, 24_000, 200_000));
    try std.testing.expectEqualStrings("", try statusContext(arena, false, 0, 0));
    try std.testing.expectEqualStrings(
        "~/Work/marlin",
        try statusCwd(arena, "/Users/jespern/Work/marlin", "/Users/jespern"),
    );
    try std.testing.expectEqualStrings(
        "/opt/marlin",
        try statusCwd(arena, "/opt/marlin", "/Users/jespern"),
    );
}

test "diff language comes from edit summaries or git target paths" {
    try std.testing.expectEqual(
        SyntaxLanguage.zig,
        diffLanguage("replaced 1 occurrence(s) in src/client/tui.zig\n@@ -1,2 +1,2 @@"),
    );
    try std.testing.expectEqual(
        SyntaxLanguage.javascript,
        diffLanguage("diff --git a/web/app.ts b/web/app.ts\n--- a/web/app.ts\n+++ b/web/app.ts\n@@ -1 +1 @@"),
    );
    try std.testing.expectEqual(SyntaxLanguage.generic, diffLanguage("@@ -1 +1 @@"));
}

test "diff rows combine subtle surfaces with syntax foregrounds" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;

    var nums: DiffLineNumbers = .{};
    _ = try appendDiffLine(arena, &lines, "  ", "+    const msg = \"hello\";", .zig, Palette.tool_out, &nums);
    // A hunk header renders only its enclosing-declaration context…
    try std.testing.expect(try appendDiffLine(arena, &lines, "  ", "@@ -4,1 +4,1 @@ pub fn greet() void {", .zig, Palette.tool_out, &nums));
    _ = try appendDiffLine(arena, &lines, "  ", "+    greet();", .zig, Palette.tool_out, &nums);
    _ = try appendDiffLine(arena, &lines, "  ", "-    farewell();", .zig, Palette.tool_out, &nums);
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);
    // …while a bare one (no context) feeds the gutter and renders nothing.
    try std.testing.expect(!try appendDiffLine(arena, &lines, "  ", "@@ -9,1 +9,1 @@", .zig, Palette.tool_out, &nums));
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);

    // Before any hunk header: no number. After: new-file numbers for adds,
    // old-file numbers for deletions.
    try std.testing.expectEqualStrings("     4 +", lines.items[2].text);
    try std.testing.expectEqualStrings("     4 -", lines.items[3].text);

    const added = lines.items[0];
    try std.testing.expectEqualStrings("  +", added.text);
    try std.testing.expectEqualStrings("    const msg = \"hello\";", added.text2);
    try std.testing.expect(added.fill_style != null);
    try std.testing.expect(vaxis.Color.eql(added.fill_style.?.bg, Palette.diff_add_bg));
    try std.testing.expect(added.syntax.len >= 2); // `const` + string

    const hunk = lines.items[1];
    try std.testing.expect(std.mem.indexOf(u8, hunk.text, "@@") == null); // machinery hidden
    try std.testing.expect(std.mem.indexOf(u8, hunk.text2, "pub fn greet") != null);
    try std.testing.expect(hunk.syntax.len >= 3); // pub + fn + greet

    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 1,
        .cols = 48,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 48,
        .height = 1,
        .screen = &screen,
    };
    win.fill(.{ .style = added.fill_style.? });
    _ = win.print(&.{
        .{ .text = added.text, .style = added.style },
        .{ .text = added.text2, .style = added.style2 },
    }, .{ .wrap = .none });
    applyLineSyntax(win, 0, added);

    // Three gutter cells + four spaces puts the `c` in `const` at column 7.
    const keyword_cell = win.readCell(7, 0).?;
    try std.testing.expect(vaxis.Color.eql(keyword_cell.style.bg, Palette.diff_add_bg));
    try std.testing.expect(vaxis.Color.eql(keyword_cell.style.fg, Palette.syntax_keyword.fg));
}

test "plain and Markdown URLs become safe clickable spans" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "See https://marlin.wtf/docs, then [the repo](https://github.com/jespern/marlin).";
    const spans = try findLinkSpans(arena, text);

    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqualStrings("https://marlin.wtf/docs", spans[0].uri);
    try std.testing.expectEqualStrings("the repo", text[spans[1].start..spans[1].end]);
    try std.testing.expectEqualStrings("https://github.com/jespern/marlin", spans[1].uri);
    try std.testing.expectEqualStrings(spans[1].uri, spans[2].uri);

    const unsafe = try findLinkSpans(arena, "[nope](javascript:alert(1)) file:///tmp/secret");
    try std.testing.expectEqual(@as(usize, 0), unsafe.len);
}

test "wrapped URL pieces retain the complete OSC 8 destination" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "https://example.test/really/long/path";
    const text = "see " ++ uri;
    var lines: std.ArrayList(Line) = .empty;
    try wrapPrefixed(arena, &lines, "", text, Palette.assistant, 16);

    var linked_lines: usize = 0;
    for (lines.items) |line| {
        if (line.links.len == 0) continue;
        linked_lines += 1;
        for (line.links) |link| try std.testing.expectEqualStrings(uri, link.uri);
    }
    try std.testing.expect(linked_lines >= 2);
}

test "link spans attach OSC 8 metadata to rendered cells" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 1,
        .cols = 32,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 32,
        .height = 1,
        .screen = &screen,
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const text = "go https://marlin.wtf";
    const line = Line{
        .text = text,
        .style = Palette.assistant,
        .links = try findLinkSpans(arena_state.allocator(), text),
        .links_resolved = true,
    };
    _ = win.printSegment(.{ .text = text }, .{ .wrap = .none });
    applyLineLinks(win, 0, line);

    const linked = win.readCell(3, 0).?;
    try std.testing.expectEqualStrings("https://marlin.wtf", linked.link.uri);
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, linked.style.ul_style);
    try std.testing.expectEqualStrings("", win.readCell(0, 0).?.link.uri);
}

test "URL punctuation trimming keeps balanced path delimiters" {
    const text = "https://example.test/wiki/Foo_(bar)).";
    const end = urlEnd(text, 0);
    try std.testing.expectEqualStrings("https://example.test/wiki/Foo_(bar)", text[0..end]);
}

test "calls-first parallel tool batches collapse as one transcript run" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    const entries = [_]struct { block.BlockKind, []const u8, []const u8 }{
        .{ .tool_call, "{}", "read_file" },
        .{ .tool_call, "{}", "read_file" },
        .{ .tool_call, "{}", "grep" },
        .{ .tool_result, "first file", "" },
        .{ .tool_result, "second file", "" },
        .{ .tool_result, "matches", "" },
    };
    for (entries) |entry| {
        try app.view.blocks.append(gpa, .{
            .kind = entry[0],
            .turn_id = 9,
            .text = try gpa.dupe(u8, entry[1]),
            .label = try gpa.dupe(u8, entry[2]),
        });
    }

    var expand: std.ArrayList(ExpandPair) = .empty;
    defer expand.deinit(gpa);
    const batch = try scanToolBatch(gpa, app.view.blocks.items, 0, &expand);
    try std.testing.expectEqual(@as(usize, 3), batch.ok_count);
    try std.testing.expectEqual(@as(usize, 6), batch.next);
    try std.testing.expect(batch.complete);
    try std.testing.expect(expand.items.len == 0);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);
    var summaries: usize = 0;
    for (lines.items) |line| {
        if (std.mem.eql(u8, line.text2, "Ran 3 commands")) summaries += 1;
        try std.testing.expect(std.mem.indexOf(u8, line.text, "first file") == null);
        try std.testing.expect(std.mem.indexOf(u8, line.text2, "first file") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), summaries);
}

test "in-flight calls-first batch renders one compact running line" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
            .state = .running,
        },
    };
    defer app.deinit();
    for ([_][]const u8{ "read_file", "grep", "glob" }) |name| {
        try app.view.blocks.append(gpa, .{
            .kind = .tool_call,
            .turn_id = 9,
            .text = try gpa.dupe(u8, "{}"),
            .label = try gpa.dupe(u8, name),
        });
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);
    var summaries: usize = 0;
    for (lines.items) |line| {
        if (std.mem.eql(u8, line.text2, "Running 3 commands")) summaries += 1;
        try std.testing.expect(std.mem.indexOf(u8, line.text, "⚙") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), summaries);
}

test "failed tool output uses red only for its marker and salient diagnostics" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
            .show_tool_transcript = true,
        },
    };
    defer app.deinit();
    try app.view.blocks.append(gpa, .{
        .kind = .tool_call,
        .text = try gpa.dupe(u8, "{}"),
        .label = try gpa.dupe(u8, "bash"),
    });
    try app.view.blocks.append(gpa, .{
        .kind = .tool_result,
        .text = try gpa.dupe(
            u8,
            "compiler output\n/opt/zig/std.zig:10:2: stack frame\nerror: command failed\ncase one FAIL PermissionDenied\n[exit code: 1]",
        ),
        .label = try gpa.dupe(u8, ""),
        .status = .err,
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);

    var saw_marker = false;
    var saw_neutral_continuation = false;
    var saw_red_error = false;
    var saw_red_fail = false;
    for (lines.items) |line| {
        if (std.mem.eql(u8, line.text2, "compiler output")) {
            saw_marker = std.mem.eql(u8, line.text, "    ✗ ") and
                vaxis.Color.eql(line.style.fg, Palette.tool_err.fg) and
                vaxis.Color.eql(line.style2.fg, Palette.tool_out.fg) and
                line.style2.dim;
        } else if (std.mem.indexOf(u8, line.text2, "stack frame") != null) {
            saw_neutral_continuation = std.mem.eql(u8, line.text, "      ") and
                vaxis.Color.eql(line.style.fg, Palette.tool_out.fg) and
                vaxis.Color.eql(line.style2.fg, Palette.tool_out.fg);
        } else if (std.mem.startsWith(u8, line.text2, "error:")) {
            saw_red_error = vaxis.Color.eql(line.style2.fg, Palette.tool_err.fg);
        } else if (std.mem.indexOf(u8, line.text2, " FAIL ") != null) {
            saw_red_fail = vaxis.Color.eql(line.style2.fg, Palette.tool_err.fg);
        }
    }
    try std.testing.expect(saw_marker);
    try std.testing.expect(saw_neutral_continuation);
    try std.testing.expect(saw_red_error);
    try std.testing.expect(saw_red_fail);
}

test "durable user block reconciles optimistic local echo" {
    const gpa = std.testing.allocator;
    var rendered = [_]RenderBlock{.{
        .kind = .user_msg,
        .text = try gpa.dupe(u8, "hello"),
        .label = try gpa.dupe(u8, ""),
        .pending_echo = true,
    }};
    defer rendered[0].deinit(gpa);

    try std.testing.expect(reconcilePendingEcho(&rendered, .user_msg, "hello", 9, 3));
    try std.testing.expect(!rendered[0].pending_echo);
    try std.testing.expectEqual(@as(u64, 9), rendered[0].seq);
    try std.testing.expectEqual(@as(u64, 3), rendered[0].turn_id);
    try std.testing.expect(!reconcilePendingEcho(&rendered, .user_msg, "hello", 9, 3));
}

test "correlated daemon error removes only its optimistic input and restores state" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.view.state = .done;
    app.pushInputEcho(.user_msg, "rejected", 41, app.view.state);
    app.pushInputEcho(.steer, "unrelated", 42, null);
    app.view.state = .running;
    app.animation_active.store(true, .release);

    const line = try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "archived",
        .msg = "read only",
        .request_id = 41,
    } });
    app.handleDaemonLine(line);

    try std.testing.expectEqual(proto.SessionState.done, app.view.state);
    try std.testing.expect(!app.animation_active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), app.view.blocks.items.len);
    try std.testing.expectEqualStrings("unrelated", app.view.blocks.items[0].text);
    try std.testing.expectEqual(@as(u64, 42), app.view.blocks.items[0].pending_request_id);
    try std.testing.expectEqualStrings("rejected", app.view.editor.text.items);
}

test "correlated ok accepts the echo while generic errors cannot reject it" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.pushInputEcho(.user_msg, "accepted", 55, .idle);
    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .ok = .{ .request_id = 55 } }));
    try std.testing.expectEqual(@as(usize, 1), app.view.blocks.items.len);
    try std.testing.expect(app.view.blocks.items[0].pending_echo);
    try std.testing.expectEqual(@as(u64, 0), app.view.blocks.items[0].pending_request_id);

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "other_command",
        .msg = "unrelated",
    } }));
    try std.testing.expectEqual(@as(usize, 1), app.view.blocks.items.len);
}

test "replay marker completes a bounded tail without needing a connection" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 7,
            .editor = Editor.init(gpa),
            .history_complete = false,
            .history_loading = true,
        },
    };
    defer app.deinit();

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .replay_done = .{
        .sid = 7,
        .oldest_seq = 20,
        .newest_seq = 275,
        .has_older = true,
        .plan_items = &.{
            .{ .step = "Inspect", .status = .completed, .duration_ms = 18_400 },
            .{ .step = "Implement", .status = .in_progress, .started_at_ms = 20_000 },
        },
    } }));
    try std.testing.expectEqual(@as(u64, 20), app.view.oldest_seq);
    try std.testing.expect(!app.view.history_complete);
    try std.testing.expect(!app.view.history_loading);
    try std.testing.expectEqual(@as(usize, 2), app.view.plan.items.len);
    try std.testing.expectEqual(@as(u64, 18_400), app.view.plan.items[0].duration_ms);
    try std.testing.expectEqualStrings("Implement", app.view.plan.items[1].step);
    try std.testing.expectEqual(block.PlanStatus.in_progress, app.view.plan.items[1].status);
    try std.testing.expectEqual(@as(i64, 20_000), app.view.plan.items[1].started_at_ms);
}

test "replay marker never repins a completed plan" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 7,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    app.setPlan(&.{.{ .step = "Done", .status = .completed, .duration_ms = 1_000 }});

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .replay_done = .{
        .sid = 7,
        .plan_pinned = true,
        .plan_items = &.{.{ .step = "Done", .status = .completed, .duration_ms = 1_000 }},
    } }));
    try std.testing.expectEqual(@as(usize, 0), app.view.plan.items.len);
}

test "older replay page is prepended atomically in transcript order" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 7,
            .editor = Editor.init(gpa),
            .last_seq = 3,
            .oldest_seq = 3,
            .history_complete = false,
            .history_loading = true,
            .history_before_seq = 3,
        },
    };
    defer app.deinit();
    try app.view.blocks.append(gpa, .{
        .kind = .user_msg,
        .seq = 3,
        .turn_id = 2,
        .text = try gpa.dupe(u8, "newest"),
        .label = try gpa.dupe(u8, ""),
    });

    for ([_]struct { u64, []const u8 }{
        .{ 1, "oldest" },
        .{ 2, "middle" },
    }) |entry| {
        app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .blk = .{
            .sid = 7,
            .b = .{
                .id = entry[0],
                .session_id = 7,
                .turn_id = 1,
                .seq = entry[0],
                .ts = 0,
                .body = .{ .user_msg = .{ .text = entry[1] } },
            },
        } }));
    }
    // The visible list does not change before the page marker.
    try std.testing.expectEqual(@as(usize, 1), app.view.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.view.history_backfill.items.len);

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .replay_done = .{
        .sid = 7,
        .oldest_seq = 1,
        .newest_seq = 2,
        .has_older = false,
    } }));
    try std.testing.expectEqual(@as(usize, 3), app.view.blocks.items.len);
    try std.testing.expectEqualStrings("oldest", app.view.blocks.items[0].text);
    try std.testing.expectEqualStrings("middle", app.view.blocks.items[1].text);
    try std.testing.expectEqualStrings("newest", app.view.blocks.items[2].text);
    try std.testing.expectEqual(@as(u64, 1), app.view.oldest_seq);
    try std.testing.expect(app.view.history_complete);
    try std.testing.expect(!app.view.history_loading);
    try std.testing.expectEqual(@as(usize, 0), app.view.history_backfill.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.view.editor.history.items.len);
}

test "failed replay request releases buffered page and can be retried" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 7,
            .editor = Editor.init(gpa),
            .oldest_seq = 3,
            .history_complete = false,
            .history_loading = true,
            .history_before_seq = 3,
        },
    };
    defer app.deinit();
    try app.view.history_backfill.append(gpa, .{
        .kind = .user_msg,
        .seq = 2,
        .text = try gpa.dupe(u8, "owned page text"),
        .label = try gpa.dupe(u8, ""),
    });

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "request_failed",
        .msg = "store unavailable",
    } }));
    try std.testing.expect(!app.view.history_loading);
    try std.testing.expectEqual(@as(u64, 0), app.view.history_before_seq);
    try std.testing.expectEqual(@as(usize, 0), app.view.history_backfill.items.len);
    try std.testing.expect(!app.view.history_complete);
}

test "diagnostics render in scrollback with the full latest-turn waterfall" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 7,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    const rounds = [_]proto.DiagnosticRound{.{
        .round = 0,
        .duration_ms = 1250,
        .ttft_ms = 340,
        .pre_provider_ms = 90,
        .context_load_ms = 12,
        .store_wait_ms = 2,
        .context_rows = 40,
        .context_bytes = 8192,
        .context_vm_steps = 500,
        .setup_ms = 8,
        .assemble_ms = 4,
        .body_ms = 3,
        .bytes = 4096,
        .status = "ok",
        .provider = "openrouter",
        .generation_id = "gen-test-123",
        .tokens_in = 120,
        .tokens_out = 45,
    }};
    const tools = [_]proto.DiagnosticTool{.{
        .name = "read_file",
        .status = "ok",
        .duration_ms = 80,
    }};
    const msg: proto.DaemonMsg = .{ .diagnostics_result = .{
        .sid = 7,
        .sample_turns = 3,
        .successful_turns = 2,
        .failed_turns = 1,
        .interrupted_turns = 0,
        .abandoned_turns = 0,
        .checkpoint_turns = 1,
        .provider_requests = 4,
        .tool_calls = 1,
        .provider_p50_ms = 1000,
        .provider_p95_ms = 2200,
        .ttft_p50_ms = 250,
        .ttft_p95_ms = 500,
        .local_prep_p50_ms = 20,
        .local_prep_p95_ms = 35,
        .pre_provider_p50_ms = 40,
        .pre_provider_p95_ms = 90,
        .pre_provider_max_ms = 1200,
        .pre_provider_slow_turns = 1,
        .last_turn_id = 9,
        .last_trace_id = "0123456789abcdef0123456789abcdef",
        .last_outcome = "error",
        .last_error = "collector response retained in full",
        .last_duration_ms = 1500,
        .last_rounds = &rounds,
        .last_tools = &tools,
        .otlp_enabled = true,
        .otlp_pending = 2,
        .otlp_last_error = "HTTP 401 authorization failed",
    } };
    app.handleDaemonLine(try proto.encode(gpa, msg));

    try std.testing.expectEqual(@as(usize, 1), app.view.blocks.items.len);
    try std.testing.expectEqual(block.BlockKind.system_note, app.view.blocks.items[0].kind);
    try std.testing.expectEqualStrings("diagnostics", app.view.blocks.items[0].label);
    try std.testing.expect(std.mem.indexOf(u8, app.view.blocks.items[0].text, "Provider #1") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.view.blocks.items[0].text, "Legacy pre-provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.view.blocks.items[0].text, "500 steps") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.view.blocks.items[0].text, "HTTP 401 authorization failed") != null);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try layoutLines(arena, &app, 52);
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(gpa);
    for (lines.items) |line| {
        try rendered.appendSlice(gpa, try lineText(arena, line));
        try rendered.append(gpa, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "gen-test-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "HTTP 401") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "authorization failed") != null);
}

test "synthetic and legacy rehydration render as notes, not prompts or history" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.applyBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 4,
        .seq = 1,
        .ts = 0,
        .body = .{ .user_msg = .{
            .text = "[rehydrated after compaction] docs/PLAN.md:\nprivate contents",
            .synthetic = true,
        } },
    });
    app.applyBlock(.{
        .id = 2,
        .session_id = 1,
        .turn_id = 4,
        .seq = 2,
        .ts = 0,
        // Pre-marker durable blocks are recognized by their legacy prefix.
        .body = .{ .user_msg = .{ .text = "[rehydrated after compaction] src/main.zig:\nold contents" } },
    });

    try std.testing.expectEqual(@as(usize, 2), app.view.blocks.items.len);
    try std.testing.expectEqual(block.BlockKind.system_note, app.view.blocks.items[0].kind);
    try std.testing.expectEqualStrings("rehydrated docs/PLAN.md", app.view.blocks.items[0].text);
    try std.testing.expectEqualStrings("rehydrated src/main.zig", app.view.blocks.items[1].text);
    try std.testing.expectEqual(@as(usize, 0), app.view.editor.history.items.len);
}

test "compaction renders one marker without exposing its summary" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    app.applyBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 4,
        .seq = 1,
        .ts = 0,
        .body = .{ .compaction = .{
            .summary = "## Accomplished\nA huge internal summary that must stay hidden",
            .covers_from_seq = 1,
            .covers_to_seq = 10,
        } },
    });
    app.applyBlock(.{
        .id = 2,
        .session_id = 1,
        .turn_id = 4,
        .seq = 2,
        .ts = 0,
        .body = .{ .system_note = .{ .text = "context compacted automatically (headroom); summary + rehydrated files above replace the older conversation" } },
    });

    try std.testing.expectEqual(@as(usize, 1), app.view.blocks.items.len);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);
    var markers: usize = 0;
    for (lines.items) |line| {
        const rendered = try lineText(arena_state.allocator(), line);
        if (std.mem.indexOf(u8, rendered, "context compacted") != null) markers += 1;
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Accomplished") == null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "huge internal summary") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), markers);
}

test "legacy provider error notes are display-bounded" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    const old_raw_error = "provider returned HTTP 400: " ++ ("x" ** 1600) ++ " NEVER_RENDER_THIS_TAIL";
    app.pushBlock(.system_note, old_raw_error, "", .ok);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);
    var rendered_len: usize = 0;
    for (lines.items) |line| {
        const rendered = try lineText(arena_state.allocator(), line);
        rendered_len += rendered.len;
        try std.testing.expect(std.mem.indexOf(u8, rendered, "NEVER_RENDER_THIS_TAIL") == null);
    }
    try std.testing.expect(rendered_len < 550);
}

test "session labels round-trip ids and preserve inactive view state" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 0x2a,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.replaceSessionSummaries(&.{.{
        .sid = 0x2a,
        .title = "review",
        .cwd = "/tmp/project",
        .model = "provider/model",
        .status = "running",
        .state = .running,
        .created_at = 1,
        .running = true,
    }});
    try std.testing.expectEqual(@as(?u64, 0x2a), app.sessionIdForLabel(app.session_labels.items[0]));
    try std.testing.expectEqual(@as(?u64, null), app.sessionIdForLabel("no session label"));
    try std.testing.expectEqual(proto.SessionState.running, app.view.state);

    app.view.editor.insertSlice("draft survives");
    app.view.scroll_up = 17;
    app.pushBlock(.assistant_msg, "scrollback survives", "", .ok);
    try app.saveActiveView();
    try std.testing.expectEqual(@as(usize, 0), app.view.blocks.items.len);

    const saved = app.saved_views.get(0x2a).?;
    _ = app.saved_views.remove(0x2a);
    app.restoreSavedView(saved);
    gpa.destroy(saved);
    try std.testing.expectEqualStrings("draft survives", app.view.editor.text.items);
    try std.testing.expectEqual(@as(usize, 17), app.view.scroll_up);
    try std.testing.expectEqualStrings("scrollback survives", app.view.blocks.items[0].text);
}

test "incremental session catalog upserts preserve hierarchy and remove owned state" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 20,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.replaceSessionSummaries(&.{.{
        .sid = 10,
        .title = "older",
        .model = "m",
        .status = "idle",
        .created_at = 10,
        .running = false,
    }});
    app.upsertSessionSummary(.{
        .sid = 20,
        .title = "new root",
        .cwd = "/work",
        .model = "m",
        .status = "idle",
        .created_at = 20,
        .running = false,
    });
    app.upsertSessionSummary(.{
        .sid = 21,
        .parent_sid = 20,
        .kind = .task_child,
        .title = "child",
        .cwd = "/work",
        .model = "m",
        .status = "running",
        .state = .running,
        .created_at = 21,
        .running = true,
    });
    try std.testing.expectEqualSlices(u64, &.{ 20, 21, 10 }, &.{
        app.sessions.items[0].sid,
        app.sessions.items[1].sid,
        app.sessions.items[2].sid,
    });
    // Restoring an older archived root inserts by durable catalog order; it
    // must not jump ahead of sessions created while it was hidden.
    app.upsertSessionSummary(.{
        .sid = 15,
        .title = "restored",
        .model = "m",
        .status = "idle",
        .created_at = 15,
        .running = false,
    });
    try std.testing.expectEqualSlices(u64, &.{ 20, 21, 15, 10 }, &.{
        app.sessions.items[0].sid,
        app.sessions.items[1].sid,
        app.sessions.items[2].sid,
        app.sessions.items[3].sid,
    });

    app.upsertSessionSummary(.{
        .sid = 20,
        .title = "renamed",
        .cwd = "/work",
        .model = "new-model",
        .status = "running",
        .state = .running,
        .created_at = 20,
        .running = true,
        .sandboxed = true,
    });
    try std.testing.expectEqual(proto.SessionState.running, app.view.state);
    try std.testing.expectEqualStrings("new-model", app.sessions.items[0].model);
    try std.testing.expect(app.sessions.items[0].sandboxed);
    try std.testing.expect(app.session_labels.items[0].ptr == app.sessions.items[0].label.ptr);

    app.removeSessionSummary(21);
    try std.testing.expectEqual(@as(usize, 3), app.sessions.items.len);
    try std.testing.expect(app.sessionSummary(21) == null);
}

test "top overlay opens from command and Ctrl+S, tracks selection, and closes" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 20,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    app.replaceSessionSummaries(&.{
        .{ .sid = 20, .title = "root", .model = "m", .status = "idle", .created_at = 20, .running = false },
        .{ .sid = 21, .parent_sid = 20, .kind = .task_child, .title = "child", .model = "m", .status = "running", .state = .running, .created_at = 21, .running = true },
        .{ .sid = 10, .title = "older", .model = "m", .status = "idle", .created_at = 10, .running = false },
    });

    app.runCommand("/top");
    try std.testing.expectEqual(@as(?u64, 20), app.top_view.?.selected_sid);
    try handleKey(&app, .{ .codepoint = 'j' });
    try std.testing.expectEqual(@as(?u64, 21), app.top_view.?.selected_sid);
    app.removeSessionSummary(21);
    try std.testing.expectEqual(@as(?u64, 20), app.top_view.?.selected_sid);
    try handleKey(&app, .{ .codepoint = 's', .mods = .{ .ctrl = true } });
    try std.testing.expect(app.top_view == null);
    try handleKey(&app, .{ .codepoint = 's', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(?u64, 20), app.top_view.?.selected_sid);
    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expect(app.top_view == null);
}

test "top overlay kill requires confirmation before sending" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 20,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    app.replaceSessionSummaries(&.{.{ .sid = 20, .title = "root", .model = "m", .status = "idle", .created_at = 20, .running = false }});
    app.openTop();

    try handleKey(&app, .{ .codepoint = 'x' });
    try std.testing.expectEqual(@as(?u64, 20), app.top_view.?.confirm_kill);
    try handleKey(&app, .{ .codepoint = 'n' });
    try std.testing.expect(app.top_view.?.confirm_kill == null);
}

test "inactive session view cache evicts least recently used transcripts" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    for (1..App.max_saved_views + 4) |sid| {
        app.view.sid = sid;
        app.pushBlock(.assistant_msg, "cached transcript", "", .ok);
        try app.saveActiveView();
    }
    try std.testing.expectEqual(@as(usize, App.max_saved_views), app.saved_views.count());
    try std.testing.expect(app.saved_views.get(1) == null);
    try std.testing.expect(app.saved_views.get(App.max_saved_views + 3) != null);
}

test "tab bar is permanent, root-only, chronological, and rolls up child activity" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 30, .editor = Editor.init(gpa) } };
    defer app.deinit();

    app.replaceSessionSummaries(&.{
        .{ .sid = 20, .title = "", .cwd = "/work/beta", .model = "m", .status = "running", .state = .running, .created_at = 20, .running = true },
        .{ .sid = 30, .parent_sid = 20, .kind = .task_child, .title = "review crypto", .cwd = "/work/beta", .model = "m", .status = "err", .state = .err, .created_at = 21, .running = false },
        .{ .sid = 10, .title = "", .cwd = "/work/alpha", .model = "m", .status = "idle", .created_at = 10, .running = false },
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const layout = try layoutTabBar(arena_state.allocator(), &app, 120);
    try std.testing.expectEqual(@as(usize, 2), layout.items.len);
    try std.testing.expectEqual(@as(u64, 10), layout.items[0].sid);
    try std.testing.expectEqual(@as(u64, 20), layout.items[1].sid);
    try std.testing.expect(!layout.items[0].active);
    try std.testing.expect(layout.items[1].active); // focused child highlights its root
    try std.testing.expectEqual(TabActivity.err, layout.items[1].activity);
    try std.testing.expect(std.mem.indexOf(u8, layout.items[0].label, "alpha") != null);

    var empty = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 99, .editor = Editor.init(gpa) } };
    defer empty.deinit();
    const fallback = try layoutTabBar(arena_state.allocator(), &empty, 80);
    try std.testing.expectEqual(@as(usize, 1), fallback.items.len);
    try std.testing.expect(fallback.items[0].active);
    try std.testing.expectEqual(@as(u64, 99), fallback.items[0].sid);
}

test "normal-mode tab navigation follows chronological roots and wraps" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 30, .editor = Editor.init(gpa) } };
    defer app.deinit();

    app.replaceSessionSummaries(&.{
        .{ .sid = 20, .title = "second", .model = "m", .status = "idle", .created_at = 20, .running = false },
        .{ .sid = 30, .parent_sid = 20, .kind = .task_child, .title = "child", .model = "m", .status = "idle", .created_at = 21, .running = false },
        .{ .sid = 40, .title = "third", .model = "m", .status = "idle", .created_at = 20, .running = false },
        .{ .sid = 10, .title = "first", .model = "m", .status = "idle", .created_at = 10, .running = false },
    });

    // Alt+N indexing matches the rendered strip order: children never get a
    // slot, ties break on sid, and out-of-range indices are null (notice).
    try std.testing.expectEqual(@as(?u64, 10), rootTabSidAtIndex(app.sessions.items, 1));
    try std.testing.expectEqual(@as(?u64, 20), rootTabSidAtIndex(app.sessions.items, 2));
    try std.testing.expectEqual(@as(?u64, 40), rootTabSidAtIndex(app.sessions.items, 3));
    try std.testing.expectEqual(@as(?u64, null), rootTabSidAtIndex(app.sessions.items, 4));
    try std.testing.expectEqual(@as(?u64, null), rootTabSidAtIndex(app.sessions.items, 0));

    // Focused children navigate relative to their highlighted root. Equal
    // timestamps use sid as the same deterministic tie-break as the renderer.
    try std.testing.expectEqual(@as(?u64, 40), nextRootTabSid(app.sessions.items, app.rootSessionId(30), 1));
    try std.testing.expectEqual(@as(?u64, 10), nextRootTabSid(app.sessions.items, app.rootSessionId(30), -1));
    try std.testing.expectEqual(@as(?u64, 20), nextRootTabSid(app.sessions.items, 10, 1));
    try std.testing.expectEqual(@as(?u64, 40), nextRootTabSid(app.sessions.items, 10, -1));
    try std.testing.expectEqual(@as(?u64, 10), nextRootTabSid(app.sessions.items, 40, 1));

    // With one visible root, every shortcut is a no-op and never repurposes
    // Left/Right as composer movement in normal mode.
    var one = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 10, .editor = Editor.init(gpa) } };
    defer one.deinit();
    one.replaceSessionSummaries(&.{.{ .sid = 10, .title = "only", .model = "m", .status = "idle", .created_at = 10, .running = false }});
    one.view.editor.insertSlice("draft");
    one.view.editor.cursor = 2;
    one.mode = .normal;
    try handleKey(&one, .{ .codepoint = '>' });
    try handleKey(&one, .{ .codepoint = vaxis.Key.left });
    try handleKey(&one, .{ .codepoint = '<' });
    try handleKey(&one, .{ .codepoint = vaxis.Key.right });
    try std.testing.expectEqual(@as(usize, 2), one.view.editor.cursor);
}

test "tab overflow retains the active tab and tab hit testing is button-extensible" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 4, .editor = Editor.init(gpa) } };
    defer app.deinit();

    app.replaceSessionSummaries(&.{
        .{ .sid = 1, .title = "one", .model = "m", .status = "idle", .created_at = 1, .running = false },
        .{ .sid = 2, .title = "two", .model = "m", .status = "idle", .created_at = 2, .running = false },
        .{ .sid = 3, .title = "three", .model = "m", .status = "idle", .created_at = 3, .running = false },
        .{ .sid = 4, .title = "four", .model = "m", .status = "running", .state = .running, .created_at = 4, .running = true },
        .{ .sid = 5, .title = "five", .model = "m", .status = "idle", .created_at = 5, .running = false },
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const layout = try layoutTabBar(arena_state.allocator(), &app, 24);
    try std.testing.expect(layout.hidden_left or layout.hidden_right);
    var found_active = false;
    for (layout.items) |item| {
        if (item.sid == 4) found_active = item.active;
        try std.testing.expect(item.x + item.width <= 24);
    }
    try std.testing.expect(found_active);

    try app.tab_hits.append(gpa, .{ .start_col = 3, .end_col = 11, .sid = 4 });
    try std.testing.expectEqual(@as(?u64, 4), app.tabAtColumn(3));
    try std.testing.expectEqual(@as(?u64, 4), app.tabAtColumn(10));
    try std.testing.expectEqual(@as(?u64, null), app.tabAtColumn(11));
    try std.testing.expectEqual(TabMouseAction.activate, tabMouseAction(.{ .row = 0, .col = 4, .button = .left, .mods = .{}, .type = .press }).?);
    try std.testing.expectEqual(TabMouseAction.context_menu, tabMouseAction(.{ .row = 0, .col = 4, .button = .right, .mods = .{}, .type = .press }).?);
    try std.testing.expect(tabMouseAction(.{ .row = 0, .col = 4, .button = .left, .mods = .{}, .type = .release }) == null);

    // Clicking the already-active tab is a complete no-op and must not begin
    // transcript selection even when no connection object is available.
    handleMouse(&app, .{ .row = 0, .col = 4, .button = .left, .mods = .{}, .type = .press });
    try std.testing.expect(app.view.sel_anchor == null);
    handleMouse(&app, .{ .row = 0, .col = 4, .button = .wheel_up, .mods = .{}, .type = .press });
    try std.testing.expectEqual(@as(usize, 3), app.view.scroll_up);

    app.view.last_total_lines = 45;
    app.view.last_first_visible = 40;
    app.view.last_view_h = 5;
    handleMouse(&app, .{ .row = 1, .col = 7, .button = .left, .mods = .{}, .type = .press });
    try std.testing.expectEqual(@as(usize, 40), app.view.sel_anchor.?.line); // row 0 is the tab strip
}

test "active prompt scrolls normally before sticking at the top" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var vx = try vaxis.init(threaded.io(), gpa, &environ, .{});
    defer vx.deinit(gpa, &output.writer);
    try vx.resize(gpa, &output.writer, .{ .rows = 18, .cols = 80, .x_pixel = 0, .y_pixel = 0 });

    var conn: attach.Conn = undefined;
    conn.sandbox_available = false;
    conn.network_filtering = false;
    conn.network_configured = false;
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = &conn, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.view.state = .running;
    try app.view.blocks.append(gpa, .{ .kind = .user_msg, .turn_id = 1, .text = try gpa.dupe(u8, "old prompt"), .label = try gpa.dupe(u8, "") });
    try app.view.blocks.append(gpa, .{ .kind = .assistant_msg, .turn_id = 1, .text = try gpa.dupe(u8, "old answer"), .label = try gpa.dupe(u8, "") });
    try app.view.blocks.append(gpa, .{ .kind = .user_msg, .turn_id = 2, .text = try gpa.dupe(u8, "the active request"), .label = try gpa.dupe(u8, "") });

    var frame = std.heap.ArenaAllocator.init(gpa);
    defer frame.deinit();
    try draw(&app, &vx, frame.allocator());
    try std.testing.expectEqual(@as(usize, 0), app.view.last_pinned_rows);
    try std.testing.expectEqual(app.view.last_first_visible, app.visibleLineAtRow(0).?);

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try app.view.blocks.append(gpa, .{
            .kind = .reasoning,
            .turn_id = 2,
            .text = try std.fmt.allocPrint(gpa, "progress line {d}", .{i}),
            .label = try gpa.dupe(u8, ""),
            .commentary = true,
        });
    }
    app.view.layout_epoch +%= 1;
    frame.deinit();
    frame = std.heap.ArenaAllocator.init(gpa);
    try draw(&app, &vx, frame.allocator());
    try std.testing.expectEqual(@as(usize, 4), app.view.last_pinned_rows);
    try std.testing.expect(app.view.last_body_first > app.view.last_pinned_start + app.view.last_pinned_rows);
    try std.testing.expect(app.visibleLineAtRow(0) == null);
    try std.testing.expect(app.visibleLineAtRow(app.view.last_pinned_rows - 1) == null);
    try std.testing.expectEqual(app.view.last_body_first, app.visibleLineAtRow(app.view.last_pinned_rows).?);
    const pinned_mark = vx.window().readCell(1, @intCast(app.tabBarRows() + 1)).?;
    try std.testing.expectEqualStrings("#", pinned_mark.char.grapheme);
    try std.testing.expect(vaxis.Color.eql(pinned_mark.style.fg, Palette.pinned_prompt_mark.fg));

    app.view.scroll_up = 1;
    frame.deinit();
    frame = std.heap.ArenaAllocator.init(gpa);
    try draw(&app, &vx, frame.allocator());
    try std.testing.expectEqual(@as(usize, 0), app.view.last_pinned_rows);
    try std.testing.expectEqual(app.view.last_first_visible, app.visibleLineAtRow(0).?);
}

test "draw permanently reserves and paints the clickable tab row" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var vx = try vaxis.init(threaded.io(), gpa, &environ, .{});
    defer vx.deinit(gpa, &output.writer);
    try vx.resize(gpa, &output.writer, .{ .rows = 12, .cols = 80, .x_pixel = 0, .y_pixel = 0 });

    var conn: attach.Conn = undefined;
    conn.sandbox_available = false;
    conn.network_filtering = false;
    conn.network_configured = false;
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = &conn, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.setCwdStr("/work/marlin");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try draw(&app, &vx, arena_state.allocator());

    try std.testing.expectEqual(@as(usize, 1), app.tab_hits.items.len);
    try std.testing.expectEqual(@as(u64, 1), app.tab_hits.items[0].sid);
    try std.testing.expectEqual(@as(usize, 6), app.view.last_view_h);
    const tab_cell = vx.window().readCell(0, 0).?;
    try std.testing.expect(vaxis.Color.eql(tab_cell.style.bg, Palette.prompt_bg));
}

test "empty session draws the welcome card; content reclaims it" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var vx = try vaxis.init(threaded.io(), gpa, &environ, .{});
    defer vx.deinit(gpa, &output.writer);
    try vx.resize(gpa, &output.writer, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });

    var conn: attach.Conn = undefined;
    conn.sandbox_available = true;
    conn.network_filtering = true;
    conn.network_configured = true;
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = &conn, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.setModelStr("openrouter/example/model");
    const dv = "0.0.0-dev";
    @memcpy(app.welcome_daemon_version[0..dv.len], dv);
    app.welcome_daemon_version_len = dv.len;
    app.welcome_sandbox = true;
    app.welcome_dnsblock_rules = 173_613;
    app.build_mismatch = true;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try draw(&app, &vx, arena_state.allocator());

    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(gpa);
    var row: u16 = 0;
    while (row < 24) : (row += 1) {
        var col: u16 = 0;
        while (col < 80) : (col += 1) {
            const cell = vx.window().readCell(col, row) orelse continue;
            try screen.appendSlice(gpa, cell.char.grapheme);
        }
        try screen.append(gpa, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "marlin") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "daemon v0.0.0-dev · sandbox ✓ · dnsblock 173613 rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "⚠ daemon runs a different build — /reboot to sync") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "openrouter/example/model") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "send a prompt") != null);

    // Loading history, a running turn, or any transcript content reclaims
    // the area: the card is empty-state orientation, never chrome.
    app.view.history_loading = true;
    var frame2 = std.heap.ArenaAllocator.init(gpa);
    defer frame2.deinit();
    try draw(&app, &vx, frame2.allocator());
    var found = false;
    row = 0;
    scan: while (row < 24) : (row += 1) {
        var col: u16 = 0;
        var line_buf: [512]u8 = undefined;
        var line_len: usize = 0;
        while (col < 80) : (col += 1) {
            const cell = vx.window().readCell(col, row) orelse continue;
            const g = cell.char.grapheme;
            if (line_len + g.len <= line_buf.len) {
                @memcpy(line_buf[line_len..][0..g.len], g);
                line_len += g.len;
            }
        }
        if (std.mem.indexOf(u8, line_buf[0..line_len], "send a prompt") != null) {
            found = true;
            break :scan;
        }
    }
    try std.testing.expect(!found);
}

test "tool results retain full blob refs and inline !c stages clipboard text" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.applyBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 4,
        .seq = 7,
        .ts = 0,
        .body = .{ .tool_result = .{
            .call_id = "call",
            .status = .ok,
            .inline_body = "capped",
            .full_body_ref = "abc123",
        } },
    });
    try std.testing.expectEqualStrings("abc123", app.view.blocks.items[0].full_body_ref.?);
    app.view.blocks.items[0].deinit(gpa);
    app.view.blocks.clearRetainingCapacity();

    app.pushBlock(.tool_result, "complete output", "", .ok);
    app.runCommand("!c");
    try std.testing.expectEqualStrings("complete output", app.clipboard_pending.items);
    // No paired call in view → generic source label.
    try std.testing.expectEqualStrings("tool", app.clipboard_desc.items);
}

test "!c names the folded source it copies (positional batch pairing)" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined, // inline results only; !c never touches the socket
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    // One parallel batch: three calls then three results, same turn. The
    // last result pairs with the last call even though the transcript
    // folds all of them into a "Ran 3 commands" summary.
    const calls = [_]struct { id: []const u8, name: []const u8, args: []const u8 }{
        .{ .id = "c1", .name = "grep", .args = "{\"pattern\":\"foo\"}" },
        .{ .id = "c2", .name = "bash", .args = "{\"command\":\"ls\"}" },
        .{ .id = "c3", .name = "read_file", .args = "{\"path\":\"docs/PERMISSIONS.md\"}" },
    };
    var seq: u64 = 1;
    for (calls) |c| {
        app.applyBlock(.{
            .id = seq,
            .session_id = 1,
            .turn_id = 9,
            .seq = seq,
            .ts = 0,
            .body = .{ .tool_call = .{ .call_id = c.id, .name = c.name, .args_json = c.args } },
        });
        seq += 1;
    }
    for (calls) |c| {
        app.applyBlock(.{
            .id = seq,
            .session_id = 1,
            .turn_id = 9,
            .seq = seq,
            .ts = 0,
            .body = .{ .tool_result = .{
                .call_id = c.id,
                .status = .ok,
                .inline_body = "259|## Implementation slices",
                .full_body_ref = null,
            } },
        });
        seq += 1;
    }

    app.runCommand("!c");
    try std.testing.expectEqualStrings("259|## Implementation slices", app.clipboard_pending.items);
    try std.testing.expectEqualStrings("Read docs/PERMISSIONS.md", app.clipboard_desc.items);
}

test "local commands enter editor history" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined, // /help is entirely client-local
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.submitInput("/help");
    try std.testing.expectEqual(@as(usize, 1), app.view.editor.history.items.len);
    app.view.editor.histUp();
    try std.testing.expectEqualStrings("/help", app.view.editor.text.items);
}

test "layout cache: incremental result equals fresh one-shot layout" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const Fixture = struct {
        fn fill(app: *App, a: std.mem.Allocator, turns: usize) !void {
            var t: usize = 0;
            var seq: u64 = 1;
            while (t < turns) : (t += 1) {
                const turn_id = t + 10;
                try app.view.blocks.append(a, .{ .kind = .user_msg, .seq = seq, .turn_id = turn_id, .text = try a.dupe(u8, "do the thing"), .label = try a.dupe(u8, "") });
                seq += 1;
                try app.view.blocks.append(a, .{ .kind = .tool_call, .seq = seq, .turn_id = turn_id, .text = try a.dupe(u8, "{\"command\":\"zig build test\"}"), .label = try a.dupe(u8, "bash") });
                seq += 1;
                try app.view.blocks.append(a, .{ .kind = .tool_result, .seq = seq, .turn_id = turn_id, .status = if (t % 3 == 0) .err else .ok, .text = try a.dupe(u8, "line one\nline two\nline three"), .label = try a.dupe(u8, "") });
                seq += 1;
                try app.view.blocks.append(a, .{ .kind = .assistant_msg, .seq = seq, .turn_id = turn_id, .text = try a.dupe(u8, "done: **ok**"), .label = try a.dupe(u8, "") });
                seq += 1;
            }
        }
        fn rendered(a: std.mem.Allocator, app: *App) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            const lines = try layoutLines(a, app, 120);
            for (lines.items) |line| {
                try out.appendSlice(a, try lineText(a, line));
                try out.append(a, '\n');
            }
            return out.items;
        }
    };

    // Incremental: layout after 3 turns (warms cache), add 2 more, layout again.
    var warm = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer warm.deinit();
    try Fixture.fill(&warm, gpa, 3);
    var arena1 = std.heap.ArenaAllocator.init(gpa);
    defer arena1.deinit();
    _ = try Fixture.rendered(arena1.allocator(), &warm);
    try std.testing.expect(warm.view.layout_cache.covered > 0);
    for (warm.view.blocks.items) |*rb| rb.deinit(gpa);
    warm.view.blocks.clearRetainingCapacity();
    try Fixture.fill(&warm, gpa, 5);
    warm.view.layout_epoch +%= 1; // list rebuilt wholesale, as a session switch would
    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    _ = try Fixture.rendered(arena2.allocator(), &warm);
    try std.testing.expect(warm.view.layout_cache.covered > 0);
    // Now truly incremental: append one more turn on the warmed cache.
    try Fixture.fill(&warm, gpa, 1);
    var arena3 = std.heap.ArenaAllocator.init(gpa);
    defer arena3.deinit();
    const incremental = try Fixture.rendered(arena3.allocator(), &warm);

    // Fresh app, identical blocks, single cold layout.
    var fresh = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer fresh.deinit();
    try Fixture.fill(&fresh, gpa, 5);
    try Fixture.fill(&fresh, gpa, 1);
    var arena4 = std.heap.ArenaAllocator.init(gpa);
    defer arena4.deinit();
    const cold = try Fixture.rendered(arena4.allocator(), &fresh);

    try std.testing.expectEqualStrings(cold, incremental);
}

test "layout remains bounded around a dangling call between turns" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();

    const Entry = struct { block.BlockKind, u64, []const u8, []const u8 };
    const entries = [_]Entry{
        .{ .tool_call, 7, "{\"pattern\":\"one\"}", "grep" },
        .{ .tool_result, 7, "ok", "" },
        .{ .tool_call, 7, "{\"path\":\"one\"}", "read_file" },
        .{ .tool_result, 7, "ok", "" },
        .{ .tool_call, 7, "{\"path\":\"two\"}", "read_file" },
        .{ .tool_result, 7, "ok", "" },
        .{ .reasoning, 7, "editing", "" },
        // Historical interrupted turns can end with an unmatched call.
        .{ .tool_call, 7, "{\"path\":\"x\"}", "edit" },
        .{ .user_msg, 8, "next turn", "" },
        .{ .system_note, 8, "interrupted", "" },
    };
    for (entries, 0..) |entry, i| try app.view.blocks.append(gpa, .{
        .kind = entry[0],
        .seq = i + 1,
        .turn_id = entry[1],
        .text = try gpa.dupe(u8, entry[2]),
        .label = try gpa.dupe(u8, entry[3]),
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try layoutLines(arena, &app, 120);
    try std.testing.expect(lines.items.len < 100);
    var saw_summary = false;
    var saw_dangling = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "Ran 3 commands") != null) saw_summary = true;
        if (std.mem.indexOf(u8, text, "⚙ Edit") != null) saw_dangling = true;
    }
    try std.testing.expect(saw_summary);
    try std.testing.expect(saw_dangling);
}

test "raw provider reasoning folds; commentary narration stays visible" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();

    // The grok shape: raw reasoning (with a drafted reply inside) followed
    // by the model's deliberate one-line narration, both kind=reasoning.
    try app.view.blocks.append(gpa, .{
        .kind = .reasoning,
        .seq = 1,
        .turn_id = 7,
        .text = try gpa.dupe(u8, "The user wants a review. Thanks for the update, solid work!"),
        .label = try gpa.dupe(u8, ""),
    });
    try app.view.blocks.append(gpa, .{
        .kind = .reasoning,
        .seq = 2,
        .turn_id = 7,
        .text = try gpa.dupe(u8, "Re-reading the tree against the last review."),
        .label = try gpa.dupe(u8, ""),
        .commentary = true,
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const collapsed = try layoutLines(arena, &app, 120);
    var saw_raw = false;
    var saw_narration = false;
    for (collapsed.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "Thanks for the update") != null) saw_raw = true;
        if (std.mem.indexOf(u8, text, "Re-reading the tree") != null) saw_narration = true;
    }
    try std.testing.expect(!saw_raw);
    try std.testing.expect(saw_narration);

    // ctrl+t (transcript view) reveals the raw reasoning again.
    app.view.show_tool_transcript = true;
    app.view.layout_epoch +%= 1;
    const expanded = try layoutLines(arena, &app, 120);
    saw_raw = false;
    for (expanded.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "Thanks for the update") != null) saw_raw = true;
    }
    try std.testing.expect(saw_raw);
}

test "a failing sibling expands alone; healthy batch members stay folded" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();

    // Calls-first batch of three; the second result fails.
    const entries = [_]struct { block.BlockKind, []const u8, []const u8, block.ToolStatus }{
        .{ .tool_call, "{\"command\":\"zig version\"}", "bash", .ok },
        .{ .tool_call, "{\"command\":\"jq .lib_dir\"}", "bash", .ok },
        .{ .tool_call, "{\"pattern\":\"curl_easy\"}", "grep", .ok },
        .{ .tool_result, "0.16.0", "", .ok },
        .{ .tool_result, "jq: parse error", "", .err },
        .{ .tool_result, "141: curl_easy_setopt", "", .ok },
    };
    var seq: u64 = 1;
    for (entries) |entry| {
        try app.view.blocks.append(gpa, .{
            .kind = entry[0],
            .seq = seq,
            .turn_id = 7,
            .status = entry[3],
            .text = try gpa.dupe(u8, entry[1]),
            .label = try gpa.dupe(u8, entry[2]),
        });
        seq += 1;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try layoutLines(arena, &app, 120);

    var gear_lines: usize = 0;
    var saw_summary = false;
    var saw_failure = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "⚙") != null) gear_lines += 1;
        if (std.mem.indexOf(u8, text, "Ran 2 commands") != null) saw_summary = true;
        if (std.mem.indexOf(u8, text, "jq: parse error") != null) saw_failure = true;
    }
    // Exactly one expanded call (the failure); the two healthy pairs fold.
    try std.testing.expectEqual(@as(usize, 1), gear_lines);
    try std.testing.expect(saw_summary);
    try std.testing.expect(saw_failure);
}

test "tool summaries merge across commentary into one line" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();

    // Three rounds: commentary + one successful pair each. Previously this
    // rendered three separate "Ran 1 command" lines.
    var seq: u64 = 1;
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        try app.view.blocks.append(gpa, .{ .kind = .reasoning, .seq = seq, .turn_id = 7, .text = try gpa.dupe(u8, "checking things"), .label = try gpa.dupe(u8, "") });
        seq += 1;
        try app.view.blocks.append(gpa, .{ .kind = .tool_call, .seq = seq, .turn_id = 7, .text = try gpa.dupe(u8, "{\"command\":\"true\"}"), .label = try gpa.dupe(u8, "bash") });
        seq += 1;
        try app.view.blocks.append(gpa, .{ .kind = .tool_result, .seq = seq, .turn_id = 7, .text = try gpa.dupe(u8, "ok"), .label = try gpa.dupe(u8, "") });
        seq += 1;
    }
    try app.view.blocks.append(gpa, .{ .kind = .assistant_msg, .seq = seq, .turn_id = 7, .text = try gpa.dupe(u8, "done"), .label = try gpa.dupe(u8, "") });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try layoutLines(arena, &app, 120);

    var summaries: usize = 0;
    var merged = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "Ran ") != null) summaries += 1;
        if (std.mem.indexOf(u8, text, "Ran 3 commands") != null) merged = true;
    }
    try std.testing.expectEqual(@as(usize, 1), summaries);
    try std.testing.expect(merged);
}

test "copy mode: enter, select, yank fills selection and requests copy" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.mode = .normal;
    app.view.last_total_lines = 50;
    app.view.last_view_h = 10;
    app.view.last_first_visible = 40;

    try handleKey(&app, .{ .codepoint = 'v' });
    try std.testing.expect(app.copy_cursor != null);
    try std.testing.expectEqual(@as(usize, 49), app.copy_cursor.?.line);

    try handleKey(&app, .{ .codepoint = 'k' });
    try handleKey(&app, .{ .codepoint = 'k' });
    try std.testing.expectEqual(@as(usize, 47), app.copy_cursor.?.line);

    // Anchor char-wise, extend down one line, yank.
    try handleKey(&app, .{ .codepoint = 'v' });
    try std.testing.expect(app.view.sel_anchor != null);
    try handleKey(&app, .{ .codepoint = 'j' });
    try std.testing.expectEqual(@as(usize, 48), app.view.sel_head.line);
    try handleKey(&app, .{ .codepoint = 'y' });
    try std.testing.expect(app.view.copy_pending);
    try std.testing.expect(app.copy_cursor == null); // yank exits copy mode

    // Line-wise: V spans full lines in the selection endpoints.
    try handleKey(&app, .{ .codepoint = 'v' });
    try handleKey(&app, .{ .codepoint = 'V', .mods = .{ .shift = true } });
    try handleKey(&app, .{ .codepoint = 'k' });
    try handleKey(&app, .{ .codepoint = 'y' });
    try std.testing.expectEqual(@as(usize, 0), app.view.sel_anchor.?.col);
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), app.view.sel_head.col);
}

test "normal mode: p pastes the yank register into the composer" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.mode = .normal;
    try app.yank_register.appendSlice(gpa, "zig build test");
    try handleKey(&app, .{ .codepoint = 'p' });
    try std.testing.expectEqualStrings("zig build test", app.view.editor.text.items);

    // Motions operate on the composer: 0 then w lands after the first word.
    try handleKey(&app, .{ .codepoint = '0' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try handleKey(&app, .{ .codepoint = 'D' });
    // True-vim w: next word START, so D leaves the separator behind.
    try std.testing.expectEqualStrings("zig ", app.view.editor.text.items);

    // ^ is first non-blank, both as a motion and as an operator target.
    app.view.editor.clear();
    app.view.editor.insertSlice("   zig build test");
    app.view.editor.moveLineEnd();
    try handleKey(&app, .{ .codepoint = '^' });
    try std.testing.expectEqual(@as(usize, 3), app.view.editor.cursor);
    try handleKey(&app, .{ .codepoint = '0' });
    try handleKey(&app, .{ .codepoint = '^' });
    try std.testing.expectEqual(@as(usize, 3), app.view.editor.cursor); // forward from the indentation too
    app.view.editor.moveLineEnd();
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = '^' });
    try std.testing.expectEqualStrings("   ", app.view.editor.text.items);
}

test "composer operators: dw ci\" yy dd" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.mode = .normal;

    // dw from the start eats the first word and its trailing space.
    app.view.editor.insertSlice("zig build test");
    app.view.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try std.testing.expectEqualStrings("build test", app.view.editor.text.items);
    try std.testing.expectEqualStrings("zig ", app.yank_register.items);

    // ci" clears the quoted span and enters insert mode.
    app.view.editor.clear();
    app.view.editor.insertSlice("run \"the old thing\" now");
    app.view.editor.cursor = 8;
    try handleKey(&app, .{ .codepoint = 'c' });
    try handleKey(&app, .{ .codepoint = 'i' });
    try handleKey(&app, .{ .codepoint = '"' });
    try std.testing.expectEqualStrings("run \"\" now", app.view.editor.text.items);
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(@as(usize, 5), app.view.editor.cursor);

    // yy fills the register without touching the text.
    app.mode = .normal;
    app.view.editor.clear();
    app.view.editor.insertSlice("keep me");
    try handleKey(&app, .{ .codepoint = 'y' });
    try handleKey(&app, .{ .codepoint = 'y' });
    try std.testing.expectEqualStrings("keep me", app.view.editor.text.items);
    try std.testing.expectEqualStrings("keep me", app.yank_register.items);

    // dd removes the cursor's line including its newline.
    app.view.editor.clear();
    app.view.editor.insertSlice("one\ntwo\nthree");
    app.view.editor.cursor = 5;
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'd' });
    try std.testing.expectEqualStrings("one\nthree", app.view.editor.text.items);

    // An unknown motion cancels cleanly.
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'z' });
    try std.testing.expectEqualStrings("one\nthree", app.view.editor.text.items);
    try std.testing.expectEqual(@as(u8, 0), app.vim.pending_op);

    // di( around the cursor inside brackets.
    app.view.editor.clear();
    app.view.editor.insertSlice("call(alpha, beta)");
    app.view.editor.cursor = 7;
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'i' });
    try handleKey(&app, .{ .codepoint = '(' });
    try std.testing.expectEqualStrings("call()", app.view.editor.text.items);
}

test "vim completeness: counts, find, undo, synonyms, linewise paste" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.mode = .normal;

    // d2w with a count: two words and their separators.
    app.view.editor.insertSlice("one two three four");
    app.view.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = '2' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try std.testing.expectEqualStrings("three four", app.view.editor.text.items);

    // u undoes it; ctrl+r redoes it.
    try handleKey(&app, .{ .codepoint = 'u' });
    try std.testing.expectEqualStrings("one two three four", app.view.editor.text.items);
    try handleKey(&app, .{ .codepoint = 'r', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("three four", app.view.editor.text.items);

    // f/t with operator: dt<space> from start eats "three".
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 't' });
    try handleKey(&app, .{ .codepoint = ' ', .text = " " });
    try std.testing.expectEqualStrings(" four", app.view.editor.text.items);

    // 3w count motion, then x.
    app.view.editor.clear();
    app.view.editor.insertSlice("a bb ccc dddd");
    app.view.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = '3' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try std.testing.expectEqual(@as(usize, 9), app.view.editor.cursor); // start of dddd
    try handleKey(&app, .{ .codepoint = 'x' });
    try std.testing.expectEqualStrings("a bb ccc ddd", app.view.editor.text.items);

    // r replaces in place; ~ toggles case.
    app.view.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'r' });
    try handleKey(&app, .{ .codepoint = 'A', .text = "A" });
    try std.testing.expectEqualStrings("A bb ccc ddd", app.view.editor.text.items);
    try handleKey(&app, .{ .codepoint = '~' });
    try std.testing.expectEqualStrings("a bb ccc ddd", app.view.editor.text.items);

    // C changes to end of line and enters insert.
    app.view.editor.cursor = 2;
    try handleKey(&app, .{ .codepoint = 'C', .mods = .{ .shift = true } });
    try std.testing.expectEqualStrings("a ", app.view.editor.text.items);
    try std.testing.expectEqual(Mode.insert, app.mode);
    app.mode = .normal;

    // Linewise yank and paste below (Y then p).
    app.view.editor.clear();
    app.view.editor.insertSlice("alpha\nbeta");
    app.view.editor.cursor = 0;
    try handleKey(&app, .{ .codepoint = 'Y', .mods = .{ .shift = true } });
    try std.testing.expect(app.yank_linewise);
    try handleKey(&app, .{ .codepoint = 'p' });
    try std.testing.expectEqualStrings("alpha\nalpha\nbeta", app.view.editor.text.items);

    // o opens a line below and enters insert.
    app.mode = .normal;
    try handleKey(&app, .{ .codepoint = 'o' });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expect(std.mem.startsWith(u8, app.view.editor.text.items, "alpha\nalpha\n\n"));
}

test "J joins lines; gg tops; gt cycles sessions" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();
    app.mode = .normal;

    app.view.editor.insertSlice("one\n  two\nthree");
    app.view.editor.cursor = 0;
    try handleKey(&app, .{ .codepoint = 'J', .mods = .{ .shift = true } });
    try std.testing.expectEqualStrings("one two\nthree", app.view.editor.text.items);
    // 3J from the top joins all three lines (two joins).
    try handleKey(&app, .{ .codepoint = 'u' });
    try std.testing.expectEqualStrings("one\n  two\nthree", app.view.editor.text.items);
    app.view.editor.cursor = 0;
    try handleKey(&app, .{ .codepoint = '3' });
    try handleKey(&app, .{ .codepoint = 'J', .mods = .{ .shift = true } });
    try std.testing.expectEqualStrings("one two three", app.view.editor.text.items);

    // gg scrolls to top (clamped in draw); a lone g arms the prefix only.
    app.view.scroll_up = 0;
    try handleKey(&app, .{ .codepoint = 'g' });
    try std.testing.expect(app.vim.pending_g);
    try std.testing.expectEqual(@as(usize, 0), app.view.scroll_up);
    try handleKey(&app, .{ .codepoint = 'g' });
    try std.testing.expect(!app.vim.pending_g);
    try std.testing.expect(app.view.scroll_up > 0);

    // Ngt ordinal math: 1-based, clamps past the end, no-ops on empty.
    try std.testing.expectEqual(@as(?usize, 1), App.recentOrdinalIndex(3, 2));
    try std.testing.expectEqual(@as(?usize, 2), App.recentOrdinalIndex(3, 9));
    try std.testing.expectEqual(@as(?usize, null), App.recentOrdinalIndex(0, 2));
    try std.testing.expectEqual(@as(?usize, null), App.recentOrdinalIndex(3, 0));

    // Yank from copy mode exits it and schedules the highlight clear.
    app.view.last_total_lines = 5;
    app.copy_cursor = .{ .line = 1, .col = 0 };
    try handleKey(&app, .{ .codepoint = 'y' });
    try std.testing.expect(app.copy_cursor == null);
    try std.testing.expect(app.view.copy_pending);
    try std.testing.expect(app.view.sel_clear_after_copy);
}

test "Plan mode keys distinguish toggle and proposal actions" {
    try std.testing.expect(isPlanToggleKey(.{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } }));
    try std.testing.expect(!isPlanToggleKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(PlanProposalAction.implement, planProposalAction(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqual(PlanProposalAction.revise, planProposalAction(.{ .codepoint = 'e' }));
    try std.testing.expectEqual(PlanProposalAction.dismiss, planProposalAction(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(PlanProposalAction.dismiss, planProposalAction(.{ .codepoint = 'q' }));
    try std.testing.expectEqual(PlanProposalAction.none, planProposalAction(.{ .codepoint = 'x' }));
}

test "Plan clear result removes only the active session todo" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 7,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();
    try app.view.plan.append(gpa, .{ .step = try gpa.dupe(u8, "stale work"), .status = .in_progress });

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .plan_clear_result = .{
        .sid = 8,
        .cleared = true,
    } }));
    try std.testing.expectEqual(@as(usize, 1), app.view.plan.items.len);

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .plan_clear_result = .{
        .sid = 7,
        .cleared = true,
    } }));
    try std.testing.expectEqual(@as(usize, 0), app.view.plan.items.len);
    try std.testing.expectEqualStrings("execution plan cleared", app.notice.items);
}

test "finalized reasoning clears only its live stream channel across rounds" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 7,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    try app.view.reasoning_delta.appendSlice(gpa, "stale raw current raw");
    try app.view.delta.appendSlice(gpa, "stale commentary current commentary");
    try app.view.stream_layout_cache.update(gpa, app.view.delta.items, 80);

    app.applyBlock(.{
        .id = 1,
        .session_id = 7,
        .turn_id = 9,
        .seq = 1,
        .ts = 0,
        .body = .{ .reasoning = .{ .text = "current raw" } },
    });
    try std.testing.expectEqual(@as(usize, 0), app.view.reasoning_delta.items.len);
    try std.testing.expectEqualStrings("stale commentary current commentary", app.view.delta.items);

    try app.view.reasoning_delta.appendSlice(gpa, "next raw");
    app.applyBlock(.{
        .id = 2,
        .session_id = 7,
        .turn_id = 9,
        .seq = 2,
        .ts = 0,
        .body = .{ .reasoning = .{ .text = "current commentary", .commentary = true } },
    });
    try std.testing.expectEqual(@as(usize, 0), app.view.delta.items.len);
    try std.testing.expectEqualStrings("next raw", app.view.reasoning_delta.items);
    try std.testing.expectEqual(@as(usize, 0), app.view.stream_layout_cache.lines.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.view.stream_layout_cache.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.view.stream_layout_cache.source_len);

    try app.view.delta.appendSlice(gpa, "next commentary");
    try std.testing.expectEqualStrings("next commentary", app.view.delta.items);
}

test "Plan mode proposal becomes actionable only from a live finalized answer" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
            .plan_mode = true,
        },
    };
    defer app.deinit();

    app.view.history_loading = true;
    app.applyBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 1,
        .seq = 1,
        .ts = 0,
        .body = .{ .assistant_msg = .{ .text = "old proposal" } },
    });
    try std.testing.expect(!app.view.plan_proposal_ready);

    app.view.history_loading = false;
    app.applyBlock(.{
        .id = 2,
        .session_id = 1,
        .turn_id = 2,
        .seq = 2,
        .ts = 0,
        .body = .{ .assistant_msg = .{ .text = "new proposal" } },
    });
    try std.testing.expect(app.view.plan_proposal_ready);

    app.applyBlock(.{
        .id = 3,
        .session_id = 1,
        .turn_id = 3,
        .seq = 3,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "revise it" } },
    });
    try std.testing.expect(!app.view.plan_proposal_ready);
}

test "plan table centers current work and retains completed timings" {
    const items = [_]PlanItemOwned{
        .{ .step = @constCast("one"), .status = .completed },
        .{ .step = @constCast("two"), .status = .completed },
        .{ .step = @constCast("three"), .status = .in_progress },
        .{ .step = @constCast("four"), .status = .pending },
        .{ .step = @constCast("five"), .status = .pending },
        .{ .step = @constCast("six"), .status = .pending },
    };
    const visible = planDisplayRange(&items, 3);
    try std.testing.expectEqual(@as(usize, 1), visible.start);
    try std.testing.expectEqual(@as(usize, 3), visible.len);

    const completed = [_]PlanItemOwned{
        .{ .step = @constCast("one"), .status = .completed },
        .{ .step = @constCast("two"), .status = .completed },
    };
    try std.testing.expectEqual(@as(usize, 2), planDisplayRange(&completed, 5).len);
    try std.testing.expectEqual(@as(usize, 0), planDisplayRange(&items, 0).len);
    try std.testing.expect(hasUnfinishedPlan(&items));
    try std.testing.expect(!hasUnfinishedPlan(&completed));
}

test "live plan reserves a framed blank row above the composer" {
    const items = [_]PlanItemOwned{.{
        .step = @constCast("work"),
        .status = .in_progress,
    }};
    const with_plan = planSurfaceLayout(20, 0, 3, &items);
    try std.testing.expectEqual(@as(u16, 3), with_plan.plan_h);
    try std.testing.expectEqual(@as(u16, 12), with_plan.view_h);

    const without_plan = planSurfaceLayout(20, 0, 3, &.{});
    try std.testing.expectEqual(@as(u16, 0), without_plan.plan_h);
    try std.testing.expectEqual(@as(u16, 15), without_plan.view_h);
}

test "completed plan leaves the live panel and remains durable in transcript" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.applyBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 1,
        .seq = 1,
        .ts = 0,
        .body = .{ .plan = .{ .items = &.{.{ .step = "Inspect", .status = .in_progress }} } },
    });
    try std.testing.expectEqual(@as(usize, 0), app.view.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.view.plan.items.len);

    app.applyBlock(.{
        .id = 2,
        .session_id = 1,
        .turn_id = 1,
        .seq = 2,
        .ts = 0,
        .body = .{ .plan = .{ .items = &.{.{
            .step = "Inspect",
            .status = .completed,
            .duration_ms = 4_200,
        }} } },
    });
    try std.testing.expectEqual(@as(usize, 1), app.view.blocks.items.len);
    try std.testing.expectEqual(block.BlockKind.plan, app.view.blocks.items[0].kind);
    try std.testing.expectEqual(@as(usize, 0), app.view.plan.items.len);

    app.applyBlock(.{
        .id = 3,
        .session_id = 1,
        .turn_id = 2,
        .seq = 3,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "what next?" } },
    });
    try std.testing.expectEqual(@as(usize, 0), app.view.plan.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.view.blocks.items.len);
    try std.testing.expectEqual(block.BlockKind.plan, app.view.blocks.items[0].kind);
    try std.testing.expectEqualStrings("Inspect", app.view.blocks.items[0].plan_items[0].step);
}

test "plan table uses semantic markers, stable columns, and concise timing" {
    const pending = planMarker(.pending, .idle, 0);
    const active = planMarker(.in_progress, .running, 3);
    const paused = planMarker(.in_progress, .idle, 3);
    const failed = planMarker(.in_progress, .err, 3);
    const completed = planMarker(.completed, .idle, 0);

    try std.testing.expectEqualStrings("·", pending.glyph);
    try std.testing.expectEqualStrings(spinner_frames[3], active.glyph);
    try std.testing.expectEqualStrings("⏸", paused.glyph);
    try std.testing.expectEqual(@as(usize, 1), displayWidth(paused.glyph));
    try std.testing.expect(vaxis.Color.eql(Palette.plan_pending.fg, paused.glyph_style.fg));
    try std.testing.expect(!paused.text_style.bold);
    try std.testing.expectEqualStrings("×", failed.glyph);
    try std.testing.expectEqual(@as(usize, 1), displayWidth(failed.glyph));
    try std.testing.expect(vaxis.Color.eql(Palette.plan_error.fg, failed.glyph_style.fg));
    try std.testing.expectEqualStrings("✔", completed.glyph);
    try std.testing.expectEqual(@as(usize, 1), displayWidth(completed.glyph));
    try std.testing.expect(vaxis.Color.eql(Palette.plan_done_mark.fg, completed.glyph_style.fg));
    try std.testing.expect(vaxis.Color.eql(Palette.plan_pending.fg, completed.text_style.fg));
    try std.testing.expect(!completed.text_style.dim);
    try std.testing.expect(active.text_style.bold);

    const wide = planTableWidths(80);
    try std.testing.expectEqual(@as(usize, 67), wide.task);
    try std.testing.expectEqual(@as(usize, 10), wide.time);
    const narrow = planTableWidths(20);
    try std.testing.expectEqual(@as(usize, 10), narrow.task);
    try std.testing.expectEqual(@as(usize, 7), narrow.time);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("<1s", try formatPlanDuration(arena, 450));
    try std.testing.expectEqualStrings("18s", try formatPlanDuration(arena, 18_400));
    try std.testing.expectEqualStrings("2m 5s", try formatPlanDuration(arena, 125_000));
    try std.testing.expectEqualStrings("1h 2m", try formatPlanDuration(arena, 3_720_000));
    const task_rule = try planRule(arena, wide.task);
    const time_rule = try planRule(arena, wide.time);
    try std.testing.expectEqual(@as(usize, 67), displayWidth(task_rule));
    try std.testing.expectEqual(@as(usize, 10), displayWidth(time_rule));
    try std.testing.expect(std.mem.indexOf(u8, task_rule, "TODO") == null);
    try std.testing.expect(std.mem.indexOf(u8, time_rule, "TIME") == null);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = std.testing.allocator,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 1,
            .editor = Editor.init(std.testing.allocator),
            .state = .running,
        },
    };
    defer app.deinit();
    const timed_active = PlanItemOwned{
        .step = @constCast("work"),
        .status = .in_progress,
        .started_at_ms = 2_000,
        .duration_ms = 3_000,
    };
    try std.testing.expectEqual(@as(?u64, 6_000), planItemTimeMs(&app, timed_active, 5_000));
    app.view.state = .idle;
    try std.testing.expectEqual(@as(?u64, 3_000), planItemTimeMs(&app, timed_active, 50_000));
}

test "parked approvals are findable per tree and globally; badge follows the session" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .view = .{
            .sid = 10,
            .editor = Editor.init(gpa),
        },
    };
    defer app.deinit();

    app.replaceSessionSummaries(&.{ .{
        .sid = 10,
        .title = "focused root",
        .model = "m",
        .status = "idle",
        .created_at = 10,
        .running = false,
        .full_access = true,
    }, .{
        .sid = 20,
        .title = "other root",
        .model = "m",
        .status = "idle",
        .created_at = 20,
        .running = false,
    }, .{
        .sid = 21,
        .parent_sid = 20,
        .kind = .task_child,
        .title = "parked child",
        .model = "m",
        .status = "awaiting_approval",
        .state = .awaiting_approval,
        .created_at = 21,
        .running = false,
    } });

    // Activating the flagged tree lands on the parked child, not the root.
    try std.testing.expectEqual(@as(?u64, 21), app.awaitingSessionInTree(20));
    try std.testing.expectEqual(@as(?u64, null), app.awaitingSessionInTree(10));
    // y/n with nothing parked here jumps to the parked session.
    try std.testing.expectEqual(@as(?u64, 21), app.firstAwaitingSid());

    // FULL ACCESS is per session (server truth), not App state: an upsert
    // for the focused session updates the badge; other sessions never do.
    app.upsertSessionSummary(.{
        .sid = 10,
        .title = "focused root",
        .model = "m",
        .status = "idle",
        .created_at = 10,
        .running = false,
        .full_access = true,
    });
    try std.testing.expect(app.view.permissions_full);
    app.upsertSessionSummary(.{
        .sid = 10,
        .title = "focused root",
        .model = "m",
        .status = "idle",
        .created_at = 10,
        .running = false,
        .full_access = false,
    });
    try std.testing.expect(!app.view.permissions_full);
}

test "review prompt expansion names the council, roster, and question" {
    const gpa = std.testing.allocator;
    var council = OwnedCouncil{ .name = try gpa.dupe(u8, "core") };
    defer council.deinit(gpa);
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/x-ai/grok-4.6"));
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/z-ai/glm-5.3"));

    const prompt = try buildReviewPrompt(gpa, &council, "is the cache safe?");
    defer gpa.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "council \"core\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- openrouter/x-ai/grok-4.6\n- openrouter/z-ai/glm-5.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "task_batch") != null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "Question for the council: is the cache safe?"));
}

test "transcript spacing invariant: every section breathes, nothing doubles" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .view = .{ .sid = 1, .editor = Editor.init(gpa) } };
    defer app.deinit();

    // Every block kind, in deliberately hostile adjacency: summaries after
    // cards (the reported bug), commentary between tool stretches, notes and
    // markers back to back.
    const Entry = struct { block.BlockKind, u64, []const u8, []const u8, bool };
    const entries = [_]Entry{
        .{ .user_msg, 7, "start the work", "", false },
        .{ .tool_call, 7, "{\"command\":\"zig build\"}", "bash", false },
        .{ .tool_result, 7, "ok", "", false },
        .{ .tool_call, 7, "{\"pattern\":\"x\"}", "grep", false },
        .{ .tool_result, 7, "ok", "", false },
        .{ .user_msg, 7, "and now?", "", false },
        .{ .tool_call, 7, "{\"path\":\"a\"}", "read_file", false },
        .{ .tool_result, 7, "ok", "", false },
        .{ .reasoning, 7, "checking the gate before answering", "", true },
        .{ .tool_call, 7, "{\"path\":\"b\"}", "read_file", false },
        .{ .tool_result, 7, "ok", "", false },
        .{ .assistant_msg, 7, "all good", "", false },
        .{ .steer, 7, "also check the docs", "", false },
        .{ .compaction, 7, "", "", false },
        .{ .system_note, 7, "context compacted automatically", "", false },
        .{ .user_msg, 8, "next round", "", false },
        .{ .assistant_msg, 8, "done", "", false },
    };
    for (entries, 0..) |entry, i| try app.view.blocks.append(gpa, .{
        .kind = entry[0],
        .seq = i + 1,
        .turn_id = entry[1],
        .text = try gpa.dupe(u8, entry[2]),
        .label = try gpa.dupe(u8, entry[3]),
        .commentary = entry[4],
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Pass = struct { show_transcript: bool, state: proto.SessionState };
    for ([_]Pass{
        .{ .show_transcript = false, .state = .idle },
        .{ .show_transcript = true, .state = .idle },
        // Running splits the active turn into the tail layout range: the
        // freshly submitted prompt is the tail's first section and its air
        // must survive the range seam (the reported flush-card bug).
        .{ .show_transcript = false, .state = .running },
    }) |pass| {
        const show_transcript = pass.show_transcript;
        app.view.show_tool_transcript = show_transcript;
        app.view.state = pass.state;
        app.view.layout_epoch +%= 1;
        const lines = try layoutLines(arena, &app, 100);
        try std.testing.expect(lines.items.len > 0);

        var saw_dense_flush = false;
        for (lines.items, 0..) |line, i| {
            const plain_blank = line.text.len == 0 and line.text2.len == 0 and
                line.text3.len == 0 and line.fill_style == null;
            const prev: ?Line = if (i > 0) lines.items[i - 1] else null;
            const prev_plain_blank = if (prev) |p|
                p.text.len == 0 and p.text2.len == 0 and p.text3.len == 0 and p.fill_style == null
            else
                false;

            // 1. Never two plain blanks in a row; never a leading blank.
            if (plain_blank) try std.testing.expect(i > 0 and !prev_plain_blank);

            // 2. Content never sits flush under a card: a filled padding row
            //    is only ever followed by more card rows or a plain blank.
            if (prev != null and prev.?.fill_style != null and line.fill_style == null) {
                try std.testing.expect(plain_blank);
            }

            // 2b. Nor above one: a card's first filled row always has air —
            //     this is the range-seam case (a freshly submitted prompt
            //     starts the tail range, whose leading blank is a no-op in
            //     its own list and must be restored at concatenation).
            if (line.fill_style != null and prev != null and prev.?.fill_style == null) {
                try std.testing.expect(prev_plain_blank);
            }

            // 3. Section markers always breathe: one blank (or a card row,
            //    for labels attached to cards) directly above.
            const is_marker = std.mem.startsWith(u8, line.text, "  • ") or
                std.mem.startsWith(u8, line.text, "  · ") or
                std.mem.startsWith(u8, line.text, "  ↪ ") or
                std.mem.startsWith(u8, line.text, "  ≋ ");
            if (is_marker) {
                try std.testing.expect(i > 0);
                try std.testing.expect(prev_plain_blank or prev.?.fill_style != null);
            }

            // Dense grouping must survive: in the full transcript view a
            // result row sits flush under its call row.
            if (show_transcript and i > 0) {
                const text = try lineText(arena, line);
                const prev_text = try lineText(arena, prev.?);
                if (std.mem.indexOf(u8, prev_text, "⚙") != null and !plain_blank and
                    std.mem.indexOf(u8, text, "⚙") == null and text.len > 0)
                {
                    saw_dense_flush = true;
                }
            }
        }
        // 4. Nothing trails.
        const last = lines.items[lines.items.len - 1];
        try std.testing.expect(last.text.len > 0 or last.text2.len > 0 or
            last.text3.len > 0 or last.fill_style != null);
        if (show_transcript) try std.testing.expect(saw_dense_flush);
    }
}
