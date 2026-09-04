//! Keyboard and mouse input for the TUI: the key dispatcher, the composer's
//! vim operator/motion machinery and its pending state, copy-mode keys, and
//! the small key predicates the dispatcher is written in terms of. Split out
//! of tui.zig; everything here operates on a `*tui.App` and the App methods
//! are re-exposed there so call sites read the same.

const std = @import("std");
const vaxis = @import("vaxis");
const proto = @import("../core/proto.zig");
const Editor = @import("editor.zig");
const effects = @import("effects.zig");
const media = @import("media.zig");
const voice = @import("voice.zig");
const tui = @import("tui.zig");
const App = tui.App;
const Mode = tui.Mode;
const PickerKind = tui.PickerKind;
const render = @import("render.zig");
const SelectionPoint = render.SelectionPoint;
const nextCpEndFor = render.nextCpEndFor;
const nextWordCol = render.nextWordCol;
const TabMouseAction = tui.TabMouseAction;
const popLastCodepoint = tui.popLastCodepoint;
const council_done_item = tui.council_done_item;
const prevWordCol = render.prevWordCol;
const commands = @import("commands.zig");
const commandSuggestions = commands.commandSuggestions;
const completeSuggestion = commands.completeSuggestion;
const commandQuery = commands.commandQuery;
const isCommandInput = commands.isCommandInput;

pub fn handleKey(app: *App, key: vaxis.Key) !void {
    if (key.matches('s', .{ .ctrl = true })) {
        if (app.top_view != null) app.closeTop() else app.openTop();
        return;
    }

    if (app.setup_prompt != .none) {
        const ed = &app.view.editor;
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('g', .{ .ctrl = true })) {
            app.view.editor.clearSensitive();
            app.setup_prompt = .none;
            app.openPicker(.setup_provider);
            app.setNotice("provider setup · choose a backend", .{});
        } else if (isEnterKey(key)) {
            const value = try ed.takeExpandedSensitive();
            defer {
                @memset(value, 0);
                app.gpa.free(value);
            }
            app.submitSetupPrompt(value);
        } else if (editCommand(key)) |command| {
            applyEditCommand(ed, command);
        } else if (key.text) |text| {
            ed.insertSlice(text);
        }
        return;
    }

    if (app.otel_header_prompt) {
        const ed = &app.view.editor;
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('g', .{ .ctrl = true })) {
            app.cancelOtelSetup();
        } else if (isEnterKey(key)) {
            const headers = try ed.takeExpandedSensitive();
            defer {
                @memset(headers, 0);
                app.gpa.free(headers);
            }
            app.submitOtelHeaders(std.mem.trim(u8, headers, " \t\r\n"));
        } else if (editCommand(key)) |command| {
            applyEditCommand(ed, command);
        } else if (key.text) |text| {
            ed.insertSlice(text);
        }
        return;
    }

    if (key.matches('t', .{ .ctrl = true })) {
        app.view.show_tool_transcript = !app.view.show_tool_transcript;
        if (app.view.show_tool_transcript)
            app.setNotice("tool transcript expanded", .{})
        else
            app.setNotice("tool transcript collapsed", .{});
        return;
    }

    if (key.matches('l', .{ .ctrl = true })) {
        app.clearView();
        return;
    }

    if (key.matches('v', .{ .ctrl = true })) {
        app.attachClipboard();
        return;
    }

    // Ctrl+C is never an implicit process exit. A repeated keypress can land
    // after an interrupt transitions the session to idle; quitting then would
    // make the stop gesture race the daemon status update.
    if (key.matches('c', .{ .ctrl = true })) {
        if (app.view.state == .running or app.view.state == .awaiting_approval) {
            app.interrupt();
        } else {
            app.setNotice("nothing to interrupt · q or /quit exits", .{});
        }
        return;
    }

    if (app.council_detail_name.items.len > 0) {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            app.closeCouncilDetail();
        } else if (key.matches('e', .{})) {
            const name = app.gpa.dupe(u8, app.council_detail_name.items) catch return;
            defer app.gpa.free(name);
            app.closeCouncilDetail();
            app.openCouncilPicker(name);
        }
        return;
    }

    // Shortcut help is modal: only explicit close keys act on it. Global
    // Ctrl commands above remain available for redraw, transcript, and abort.
    if (app.shortcut_help) {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('?', .{}) or key.matches('q', .{})) {
            app.shortcut_help = false;
            app.help_scroll = 0;
        } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            app.help_scroll +|= 1; // clamped when drawn
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            app.help_scroll -|= 1;
        } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
            app.help_scroll +|= 10;
        } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
            app.help_scroll -|= 10;
        }
        return;
    }

    if (app.top_view != null) {
        if (app.top_view.?.confirm_kill) |sid| {
            if (key.matches('y', .{})) app.killTopSession(sid);
            if (app.top_view) |*view| view.confirm_kill = null;
            return;
        }
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            app.closeTop();
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            app.moveTopSelection(1);
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            app.moveTopSelection(-1);
        } else if (key.matches('g', .{})) {
            app.setTopEdgeSelection(false);
        } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
            app.setTopEdgeSelection(true);
        } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
            app.moveTopSelection(10);
        } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
            app.moveTopSelection(-10);
        } else if (key.matches('a', .{})) {
            if (app.topSelectedIndex()) |i| app.archiveTopSession(app.sessions.items[i].sid);
        } else if (key.matches('x', .{}) or key.matches('K', .{ .shift = true })) {
            if (app.topSelectedIndex()) |i| app.top_view.?.confirm_kill = app.sessions.items[i].sid;
        } else if (isEnterKey(key)) {
            if (app.topSelectedIndex()) |i| {
                const sid = app.sessions.items[i].sid;
                app.closeTop();
                app.switchSession(sid, true) catch app.setNotice("could not switch session", .{});
            }
        }
        return;
    }

    // Readline-style reverse-i-search stays inside the composer. The editor
    // displays the candidate; printable keys edit the independent query.
    if (app.history_search_active) {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('g', .{ .ctrl = true })) {
            app.cancelHistorySearch();
        } else if (key.matches('r', .{ .ctrl = true })) {
            app.cycleHistorySearch();
        } else if (isEnterKey(key)) {
            app.acceptHistorySearch();
        } else if (key.matches(vaxis.Key.backspace, .{}) or key.matches('h', .{ .ctrl = true })) {
            popLastCodepoint(&app.history_search_query);
            app.refreshHistorySearch(true);
        } else if (key.text) |text| {
            if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
                app.history_search_query.appendSlice(app.gpa, text) catch {};
                app.refreshHistorySearch(true);
            }
        }
        return;
    }

    // Pickers swallow all keys while open. Typing filters; Up/Down or
    // Ctrl+n/p navigate; Enter applies or toggles; Esc closes/cancels.
    if (app.picker) |sel| {
        if (key.matches(vaxis.Key.escape, .{})) {
            if (app.picker_kind == .council)
                app.cancelCouncilEdit()
            else {
                if (app.picker_kind == .search_prompt or app.picker_kind == .search) {
                    app.search_pending = false;
                    app.clearSearchHits();
                }
                app.picker = null;
                app.picker_filter.clearRetainingCapacity();
            }
            return;
        }
        // The model catalog can exceed a small stack buffer; this arena lives
        // only for the key event and keeps filtering allocation bounded there.
        var picker_arena = std.heap.ArenaAllocator.init(app.gpa);
        defer picker_arena.deinit();
        const items = app.pickerItems(picker_arena.allocator()) catch return;
        const n = items.len;

        if (isEnterKey(key) and app.picker_kind == .search_prompt) {
            app.submitSearch();
        } else if (isEnterKey(key)) {
            if (n > 0) {
                const pick = items[@min(sel, n - 1)];
                if (app.picker_kind == .council) {
                    if (std.mem.eql(u8, pick, council_done_item))
                        app.saveCouncilEdit()
                    else
                        app.toggleCouncilModel(pick);
                } else {
                    app.picker = null;
                    app.applyPickerItem(pick);
                    app.picker_filter.clearRetainingCapacity();
                }
            }
        } else if (isArchivePickerKey(app.picker_kind, key)) {
            if (n > 0) app.archivePickerSession(items[@min(sel, n - 1)]);
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            if (n > 0) app.picker = if (sel + 1 < n) sel + 1 else 0;
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            if (n > 0) app.picker = if (sel > 0) sel - 1 else n - 1;
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            if (app.picker_filter.items.len > 0) {
                _ = app.picker_filter.pop();
                app.picker = 0;
            }
        } else if (key.text) |txt| {
            if (txt.len > 0 and txt[0] >= 0x20 and txt[0] != 0x7f) {
                app.picker_filter.appendSlice(app.gpa, txt) catch {};
                app.picker = 0;
            }
        }
        return;
    }

    if (app.setup_required and app.view.editor.isEmpty() and isEnterKey(key)) {
        app.beginSetup(true);
        return;
    }

    if (isPlanToggleKey(key)) {
        app.togglePlanMode();
        return;
    }

    // A finished proposal is an OFFER, not a modal: its four keys act, and
    // every other key — tab switches, Ctrl+N, alt+N, pickers — passes
    // through untouched. Esc dismisses (the proposal stays in the
    // transcript; Plan mode remains on).
    if (app.view.plan_proposal_ready and app.view.plan_mode and app.view.state == .idle) {
        const action = planProposalAction(key);
        if (action != .none) {
            switch (action) {
                .implement => app.acceptPlanProposal(),
                .revise => {
                    app.view.plan_proposal_ready = false;
                    app.mode = .insert;
                    app.setNotice("revise the plan in the composer", .{});
                },
                .dismiss => {
                    app.view.plan_proposal_ready = false;
                    app.setNotice("proposal dismissed · Plan mode remains on", .{});
                },
                .none => unreachable,
            }
            return;
        }
    }

    // A mode-independent, single-chord alias for /new. Pickers retain Vim's
    // Ctrl+n navigation because their modal block above consumes it first.
    if (isNewSessionKey(key)) {
        app.newSession() catch app.setNotice("could not create session", .{});
        return;
    }

    // Close-pane muscle memory without risking a draft or attachment.
    if (isArchiveCurrentKey(app, key)) {
        app.archiveCurrentSession();
        return;
    }

    // Option/Alt+1..9 jumps straight to that tab (strip order) from either
    // mode. Below the modal blocks on purpose: an open picker or help panel
    // keeps swallowing every key.
    if (key.mods.alt and !key.mods.ctrl and key.codepoint >= '1' and key.codepoint <= '9') {
        app.jumpToTab(@intCast(key.codepoint - '0'));
        return;
    }

    // Voice dictation: ctrl+space in either mode. Esc discards an active
    // recording or cancels a model download. Dormant (never consumes keys)
    // until /voice setup ran.
    if (isVoiceKey(key)) {
        if (app.handleVoiceKey()) return;
    }
    if (app.voice_rt.phase == .recording and key.matches(vaxis.Key.escape, .{})) {
        app.abortVoiceRecording();
        return;
    }
    if (app.voice_rt.download != null and key.matches(vaxis.Key.escape, .{})) {
        app.voiceCancelDownload();
        return;
    }

    // Approval hotkeys work in both modes when the input is empty.
    if (app.view.pending != null and app.view.editor.isEmpty()) {
        if (key.matches('y', .{})) {
            app.approveReply(true);
            return;
        }
        if (key.matches('n', .{})) {
            app.approveReply(false);
            return;
        }
    }
    // Nothing parked HERE but something parked elsewhere: y/n jump to it
    // instead of dead-keying. Deliberately never answers a background
    // approval blind — you approve only what is on screen.
    if (app.view.pending == null and app.view.editor.isEmpty() and
        (key.matches('y', .{}) or key.matches('n', .{})))
    {
        if (app.firstAwaitingSid()) |awaiting_sid| {
            app.switchSession(awaiting_sid, true) catch return;
            app.setNotice("approval pending here — y approves, n denies", .{});
            return;
        }
    }

    switch (app.mode) {
        .insert => {
            const ed = &app.view.editor;
            if (key.matches('r', .{ .ctrl = true })) {
                app.beginHistorySearch();
                return;
            }
            // Same width draw() gives the editor: terminal minus the prompt.
            const edit_w: usize = app.term_cols -| 2;
            var command_arena = std.heap.ArenaAllocator.init(app.gpa);
            defer command_arena.deinit();
            const suggestions = commandSuggestions(app, command_arena.allocator()) catch &.{};
            // A recalled /command still looks like an autocomplete query.
            // While walking history, Up/Down must keep walking history rather
            // than being captured by the command menu.
            if (suggestions.len > 0 and !ed.isWalkingHistory()) {
                app.command_selection = @min(app.command_selection, suggestions.len - 1);
                if (isNextInputRowKey(key)) {
                    app.command_selection = if (app.command_selection + 1 < suggestions.len)
                        app.command_selection + 1
                    else
                        0;
                    return;
                } else if (isPreviousInputRowKey(key) or key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    app.command_selection = if (app.command_selection > 0)
                        app.command_selection - 1
                    else
                        suggestions.len - 1;
                    return;
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    completeSuggestion(ed, suggestions[app.command_selection], true);
                    app.command_selection = 0;
                    return;
                } else if (isEnterKey(key)) {
                    const suggestion = suggestions[app.command_selection];
                    completeSuggestion(ed, suggestion, false);
                    app.command_selection = 0;
                    if (suggestion.submit_on_enter) {
                        const text = try ed.takeExpandedWithImages(app.attachments.items.len);
                        defer app.gpa.free(text);
                        app.submitInput(text);
                    }
                    return;
                }
            }
            if (key.matches(vaxis.Key.escape, .{})) {
                app.mode = .normal; // draft survives: editor state untouched
                app.view.sel_anchor = null;
            } else if (isNewlineKey(key)) {
                ed.insertNewline();
            } else if (key.matches(vaxis.Key.enter, .{})) {
                const text = try ed.takeExpandedWithImages(app.attachments.items.len);
                defer app.gpa.free(text);
                app.submitInput(text);
            } else if (isPreviousInputRowKey(key)) {
                if (!ed.moveUp(edit_w)) ed.histUp();
                app.command_selection = 0;
            } else if (isNextInputRowKey(key)) {
                if (!ed.moveDown(edit_w)) ed.histDown();
                app.command_selection = 0;
            } else if (editCommand(key)) |command| {
                applyEditCommand(ed, command);
                app.command_selection = 0;
            } else if (key.text) |text| {
                ed.insertSlice(text);
                app.command_selection = 0;
            }
        },
        .normal => {
            if (app.copy_cursor != null) {
                app.copyModeKey(key);
                return;
            }
            if (app.vim.pending_g) {
                app.vim.pending_g = false;
                const count = app.vim.pending_count;
                app.vim.pending_count = 0;
                if (key.matches('g', .{})) {
                    app.view.scroll_up = std.math.maxInt(usize); // clamped in draw
                    app.maybeRequestHistoryAtTop();
                } else if (key.matches('s', .{})) {
                    app.mode = .insert;
                    app.startScreensaver(app.screensaver_kind);
                } else if (key.matches('t', .{})) {
                    // vim Ngt is absolute; here N indexes the recency list.
                    if (count > 0) app.jumpToSession(count) else app.cycleSession(1);
                } else if (key.matches('T', .{ .shift = true }) or key.matches('T', .{})) {
                    var steps = @max(count, 1);
                    while (steps > 0) : (steps -= 1) app.cycleSession(-1);
                }
                return;
            }
            if (app.vim.pending_replace) {
                app.vim.pending_replace = false;
                if (key.text) |txt| {
                    app.view.editor.pushUndo();
                    app.view.editor.replaceUnderCursor(txt);
                }
                return;
            }
            if (app.vim.pending_find != 0) {
                const kind = app.vim.pending_find;
                app.vim.pending_find = 0;
                if (key.codepoint <= 0x7f and key.codepoint >= 0x20) {
                    app.resolveFind(kind, @intCast(key.codepoint), app.takeCount());
                } else {
                    app.vim.pending_op = 0;
                    app.vim.pending_count = 0;
                }
                return;
            }
            if (app.vim.pending_op != 0) {
                app.operatorKey(key);
                return;
            }
            if ((key.codepoint >= '1' and key.codepoint <= '9') or
                (key.codepoint == '0' and app.vim.pending_count > 0))
            {
                app.vim.pending_count = app.vim.pending_count * 10 + @as(usize, @intCast(key.codepoint - '0'));
                return;
            }
            if (tabNavigationDirection(key)) |direction| {
                var steps = app.takeCount();
                while (steps > 0) : (steps -= 1) app.cycleTab(direction);
            } else if (key.matches('/', .{})) {
                app.openSearchPrompt(app.view.sid);
            } else if (key.matches('n', .{})) {
                app.nextSearchHit(1);
            } else if (key.matches('N', .{ .shift = true }) or key.matches('N', .{})) {
                app.nextSearchHit(-1);
            } else if (key.matches('?', .{})) {
                app.shortcut_help = true;
            } else if (key.matches(vaxis.Key.escape, .{})) {
                // Normal mode is an excursion from a prompt, not a resting
                // state, so a BARE Esc goes back to typing. But a half-typed
                // count/operator/find is cancelled first and stays in normal:
                // `d` Esc must never land in insert with the cursor live.
                if (app.hasPending()) {
                    app.clearPending();
                } else {
                    app.view.editor.pushUndo();
                    app.mode = .insert;
                }
            } else if (key.matches('i', .{})) {
                app.clearPending();
                app.view.editor.pushUndo();
                app.mode = .insert;
            } else if (key.matches(':', .{})) {
                // The normal-mode prompt shows ':'; honor it. Commands live
                // behind `/` in insert, so `:` opens that menu on an empty
                // composer and otherwise just enters insert.
                app.clearPending();
                app.view.editor.pushUndo();
                app.mode = .insert;
                if (app.view.editor.isEmpty()) app.view.editor.insertSlice("/");
            } else if (key.matches('a', .{})) {
                // Vim append: archive moved to /archive — a destructive-ish
                // action must not sit on the muscle-memory insert key.
                app.clearPending();
                app.view.editor.pushUndo();
                app.view.editor.moveRight();
                app.mode = .insert;
            } else if (key.matches('A', .{ .shift = true }) or key.matches('A', .{})) {
                app.clearPending();
                app.view.editor.pushUndo();
                app.view.editor.moveLineEnd();
                app.mode = .insert;
            } else if (key.matches('I', .{ .shift = true }) or key.matches('I', .{})) {
                app.clearPending();
                app.view.editor.pushUndo();
                app.view.editor.moveLineStart();
                app.mode = .insert;
            } else if (key.matches('q', .{})) {
                // Sessions are durable, so quitting is a detach; nothing is lost.
                _ = app.takeCount();
                app.should_quit = true;
            } else if (key.matches('J', .{ .shift = true }) or key.matches('J', .{})) {
                // vim J: join lines. Sessions cycle on gt/gT (tab-style).
                app.view.editor.pushUndo();
                var joins = app.takeCount();
                joins = if (joins > 1) joins - 1 else 1;
                while (joins > 0) : (joins -= 1) {
                    if (!app.view.editor.joinLines()) break;
                }
            } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                app.view.scroll_up -|= app.takeCount();
            } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                app.view.scroll_up +|= app.takeCount();
                app.maybeRequestHistoryAtTop();
            } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
                app.view.scroll_up -|= 20 * app.takeCount();
            } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
                app.view.scroll_up +|= 20 * app.takeCount();
                app.maybeRequestHistoryAtTop();
            } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
                _ = app.takeCount(); // no line addressing in a transcript; consume, don't leak
                app.view.scroll_up = 0;
            } else if (key.matches('g', .{})) {
                app.vim.pending_g = true;
            } else if (key.matches('v', .{}) or key.matches('V', .{ .shift = true }) or key.matches('V', .{})) {
                app.enterCopyMode();
            } else if (key.matches('h', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.moveLeft();
            } else if (key.matches('l', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.moveRight();
            } else if (key.matches('w', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.moveWordStart();
            } else if (key.matches('e', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.moveWordRight();
            } else if (key.matches('b', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.moveWordLeft();
            } else if (key.matches('W', .{ .shift = true }) or key.matches('W', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.moveWORDStart();
            } else if (key.matches('E', .{ .shift = true }) or key.matches('E', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.moveWORDEnd();
            } else if (key.matches('B', .{ .shift = true }) or key.matches('B', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.moveWORDLeft();
            } else if (key.matches('%', .{})) {
                _ = app.takeCount();
                app.view.editor.moveMatchingBracket();
            } else if (key.matches('0', .{})) {
                app.view.editor.moveLineStart();
            } else if (key.matches('^', .{}) or key.matches('_', .{})) {
                _ = app.takeCount();
                app.view.editor.moveFirstNonBlank();
            } else if (key.matches('$', .{})) {
                app.view.editor.moveLineEnd();
            } else if (key.matches('f', .{}) or key.matches('t', .{}) or
                key.matches('F', .{ .shift = true }) or key.matches('T', .{ .shift = true }))
            {
                app.vim.pending_find = @intCast(key.codepoint);
            } else if (key.matches(';', .{}) or key.matches(',', .{})) {
                if (app.vim.last_find_kind != 0) {
                    const kind = if (key.matches(';', .{}))
                        app.vim.last_find_kind
                    else switch (app.vim.last_find_kind) {
                        'f' => @as(u8, 'F'),
                        'F' => 'f',
                        't' => 'T',
                        'T' => 't',
                        else => app.vim.last_find_kind,
                    };
                    const remembered_ch = app.vim.last_find_ch;
                    app.resolveFind(kind, remembered_ch, app.takeCount());
                    app.vim.last_find_kind = if (key.matches(',', .{})) switch (kind) {
                        'f' => @as(u8, 'F'),
                        'F' => 'f',
                        't' => 'T',
                        'T' => 't',
                        else => kind,
                    } else kind;
                }
            } else if (key.matches('r', .{})) {
                app.vim.pending_replace = true;
            } else if (key.matches('~', .{})) {
                app.view.editor.pushUndo();
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.toggleCaseUnderCursor();
            } else if (key.matches('x', .{})) {
                app.view.editor.pushUndo();
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.deleteAfter();
            } else if (key.matches('X', .{ .shift = true })) {
                app.view.editor.pushUndo();
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.view.editor.deleteBefore();
            } else if (key.matches('s', .{})) {
                app.view.editor.pushUndo();
                app.view.editor.deleteAfter();
                app.mode = .insert;
            } else if (key.matches('S', .{ .shift = true })) {
                app.vim.pending_op = 'c';
                app.operatorKey(.{ .codepoint = 'c' });
            } else if (key.matches('C', .{ .shift = true })) {
                app.applyOperator('c', app.view.editor.toLineEndRange());
            } else if (key.matches('Y', .{ .shift = true })) {
                app.applyOperator('y', app.view.editor.lineRangeAt(true));
            } else if (key.matches('D', .{ .shift = true }) or key.matches('D', .{})) {
                app.applyOperator('d', app.view.editor.toLineEndRange());
            } else if (key.matches('o', .{})) {
                app.view.editor.pushUndo();
                app.view.editor.openLine(true);
                app.mode = .insert;
            } else if (key.matches('O', .{ .shift = true })) {
                app.view.editor.pushUndo();
                app.view.editor.openLine(false);
                app.mode = .insert;
            } else if (key.matches('u', .{})) {
                if (!app.view.editor.undo()) app.setNotice("already at oldest change", .{});
            } else if (key.matches('r', .{ .ctrl = true })) {
                if (!app.view.editor.redo()) app.setNotice("already at newest change", .{});
            } else if (key.matches('d', .{})) {
                app.vim.pending_op = 'd';
            } else if (key.matches('c', .{})) {
                app.vim.pending_op = 'c';
            } else if (key.matches('y', .{})) {
                app.vim.pending_op = 'y';
            } else if (key.matches('p', .{}) or key.matches('P', .{ .shift = true })) {
                if (app.yank_register.items.len > 0) {
                    app.view.editor.pushUndo();
                    const before = key.matches('P', .{ .shift = true });
                    if (app.yank_linewise) {
                        const line = app.view.editor.lineRangeAt(true);
                        app.view.editor.cursor = if (before) line.start else line.end;
                        const at = app.view.editor.cursor;
                        app.view.editor.insertSlice(app.yank_register.items);
                        app.view.editor.cursor = at;
                    } else {
                        if (!before) app.view.editor.moveRight();
                        app.view.editor.insertSlice(app.yank_register.items);
                    }
                } else {
                    app.setNotice("yank register empty — y in copy mode (v) fills it", .{});
                }
            }
        },
    }
}

/// Mouse: the wheel ALWAYS scrolls the session view — never the input box,
/// never history. A left click on the permanent top strip activates its tab.
/// Left press/drag/release below it selects terminal-cell ranges; release
/// copies the precise range via OSC52. A left press on a code panel's header
/// row (the ⧉ copy affordance) copies the whole block instead.
pub fn handleMouse(app: *App, m: vaxis.Mouse) void {
    if (app.top_view != null) return;
    // Some terminals report the release button as `none`, so complete an
    // active left-button drag based on event type before switching on button.
    if (m.type == .release and app.view.sel_dragging) {
        if (app.view.last_view_h > 0) {
            const terminal_row: usize = if (m.row < 0) 0 else @intCast(m.row);
            const raw_row = terminal_row -| app.tabBarRows();
            const row = @min(raw_row, app.view.last_view_h - 1);
            const col: usize = if (m.col < 0) 0 else @intCast(m.col);
            if (app.visibleLineAtRow(row)) |line|
                app.view.sel_head = .{ .line = line, .col = col };
        }
        app.view.sel_dragging = false;
        if (app.view.sel_anchor) |anchor| {
            if (anchor.line != app.view.sel_head.line or anchor.col != app.view.sel_head.col) {
                app.view.copy_pending = true;
            } else {
                app.view.sel_anchor = null;
            }
        }
        return;
    }

    const terminal_row: usize = if (m.row < 0) 0 else @intCast(m.row);
    if (terminal_row < app.tabBarRows()) {
        const col: usize = if (m.col < 0) 0 else @intCast(m.col);
        if (app.tabAtColumn(col)) |sid| {
            if (tabMouseAction(m)) |action| switch (action) {
                // A tab flagged ! takes you TO the parked approval, not to
                // the tree's root; keyboard jumps (alt+N, gt) stay literal.
                .activate => {
                    const target = app.awaitingSessionInTree(sid) orelse sid;
                    app.switchSession(target, true) catch app.setNotice("could not switch session", .{});
                },
                // Reserved for a future tab menu; right-click intentionally
                // has no product behavior yet.
                .context_menu => {},
            };
        }
        // Preserve the global wheel contract even when the pointer happens
        // to be over the strip; other non-click events belong to no view.
        if (m.button != .wheel_up and m.button != .wheel_down) return;
    }

    switch (m.button) {
        .wheel_up => {
            app.view.scroll_up +|= 3;
            app.maybeRequestHistoryAtTop();
        },
        .wheel_down => app.view.scroll_up -|= 3,
        .left => {
            const row = terminal_row - app.tabBarRows();
            // Only selectable body rows inside the session view participate;
            // the sticky prompt is a duplicate of durable scrollback.
            if (row >= app.view.last_view_h or app.visibleLineAtRow(row) == null) {
                if (m.type == .press) app.view.sel_anchor = null;
                return;
            }
            const point = SelectionPoint{
                .line = app.visibleLineAtRow(row).?,
                .col = if (m.col < 0) 0 else @intCast(m.col),
            };
            switch (m.type) {
                .press => {
                    // Code panel header rows are copy buttons, not
                    // selectable content; a press there stages the block.
                    if (app.stageCodeBlockCopy(point.line)) return;
                    app.view.sel_anchor = point;
                    app.view.sel_head = point;
                    app.view.sel_dragging = true;
                },
                .drag => {
                    if (app.view.sel_dragging) app.view.sel_head = point;
                },
                .release => {}, // active drags are completed above
                .motion => {},
            }
        },
        else => {},
    }
}

pub fn tabMouseAction(m: vaxis.Mouse) ?TabMouseAction {
    if (m.type != .press) return null;
    return switch (m.button) {
        .left => .activate,
        .right => .context_menu,
        else => null,
    };
}

pub fn isEnterKey(key: vaxis.Key) bool {
    if (key.mods.shift or key.mods.alt or key.mods.ctrl or key.mods.super or key.mods.hyper or key.mods.meta) return false;
    if (key.codepoint == vaxis.Key.enter or key.codepoint == '\n' or key.codepoint == vaxis.Key.kp_enter) return true;
    const text = key.text orelse return false;
    return std.mem.eql(u8, text, "\r") or std.mem.eql(u8, text, "\n");
}

pub fn isNewlineKey(key: vaxis.Key) bool {
    // Key.matches intentionally consumes Shift for printable text, which
    // could make plain Enter look shifted when a terminal attaches text to
    // control keys. Modifier-sensitive Enter handling must be exact.
    return (key.codepoint == vaxis.Key.enter and (key.mods.shift or key.mods.alt)) or
        (key.codepoint == 'j' and key.mods.ctrl and !key.mods.alt);
}

/// Common readline bindings plus their native terminal-key equivalents. Keep
/// this translation separate from Editor so key compatibility can be tested
/// without constructing a complete TUI App.
pub const EditCommand = enum {
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_line_start,
    move_line_end,
    delete_before,
    delete_after,
    delete_word_before,
    delete_word_before_whitespace,
    delete_word_after,
    delete_to_line_start,
    delete_to_line_end,
};

pub fn editCommand(key: vaxis.Key) ?EditCommand {
    if (key.matches(vaxis.Key.left, .{ .alt = true }) or key.matches('b', .{ .alt = true }))
        return .move_word_left;
    if (key.matches(vaxis.Key.right, .{ .alt = true }) or key.matches('f', .{ .alt = true }))
        return .move_word_right;
    if (key.matches(vaxis.Key.left, .{}) or key.matches('b', .{ .ctrl = true }))
        return .move_left;
    if (key.matches(vaxis.Key.right, .{}) or key.matches('f', .{ .ctrl = true }))
        return .move_right;
    if (key.matches(vaxis.Key.home, .{}) or key.matches('a', .{ .ctrl = true }))
        return .move_line_start;
    if (key.matches(vaxis.Key.end, .{}) or key.matches('e', .{ .ctrl = true }))
        return .move_line_end;
    if (key.matches(vaxis.Key.backspace, .{ .alt = true }))
        return .delete_word_before;
    if (key.matches(vaxis.Key.delete, .{ .alt = true }) or key.matches('d', .{ .alt = true }))
        return .delete_word_after;
    if (key.matches(vaxis.Key.backspace, .{}) or key.matches('h', .{ .ctrl = true }))
        return .delete_before;
    if (key.matches(vaxis.Key.delete, .{}) or key.matches('d', .{ .ctrl = true }))
        return .delete_after;
    if (key.matches('k', .{ .ctrl = true }))
        return .delete_to_line_end;
    if (key.matches('u', .{ .ctrl = true }))
        return .delete_to_line_start;
    if (key.matches('w', .{ .ctrl = true }))
        return .delete_word_before_whitespace;
    return null;
}

pub fn applyEditCommand(ed: *Editor, command: EditCommand) void {
    // Destructive readline chords get their own undo unit: `Ctrl+U` on a
    // long draft followed by `Esc u` must bring the draft back, not report
    // "already at oldest change" because the insert session was one unit.
    switch (command) {
        .delete_word_before,
        .delete_word_before_whitespace,
        .delete_word_after,
        .delete_to_line_start,
        .delete_to_line_end,
        => ed.pushUndo(),
        else => {},
    }
    switch (command) {
        .move_left => ed.moveLeft(),
        .move_right => ed.moveRight(),
        .move_word_left => ed.moveWordLeft(),
        .move_word_right => ed.moveWordRight(),
        .move_line_start => ed.moveLineStart(),
        .move_line_end => ed.moveLineEnd(),
        .delete_before => ed.deleteBefore(),
        .delete_after => ed.deleteAfter(),
        .delete_word_before => ed.deleteWordBefore(),
        .delete_word_before_whitespace => ed.deleteWordBeforeWhitespace(),
        .delete_word_after => ed.deleteWordAfter(),
        .delete_to_line_start => ed.deleteToLineStart(),
        .delete_to_line_end => ed.deleteToLineEnd(),
    }
}

pub fn isPreviousInputRowKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true });
}

pub fn isNextInputRowKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.down, .{});
}

pub fn isNewSessionKey(key: vaxis.Key) bool {
    return key.matches('n', .{ .ctrl = true });
}

/// Ctrl+W on an empty composer archives (close-pane muscle memory). Ctrl+D
/// deliberately does NOT: an empty composer is the normal state while
/// reading a transcript, and Ctrl+D there is vim/less page-down — archiving
/// the session you were reading is the wrong surprise.
pub fn isArchiveCurrentKey(app: *const App, key: vaxis.Key) bool {
    return key.matches('w', .{ .ctrl = true }) and
        app.view.editor.isEmpty() and app.attachments.items.len == 0 and
        app.copy_cursor == null;
}

pub fn isArchivePickerKey(kind: PickerKind, key: vaxis.Key) bool {
    return kind == .session and
        (key.matches(vaxis.Key.delete, .{}) or key.matches('d', .{ .ctrl = true }));
}

pub fn isPlanToggleKey(key: vaxis.Key) bool {
    return key.matchExact(vaxis.Key.tab, .{ .shift = true });
}

pub const PlanProposalAction = enum { none, implement, revise, dismiss };

pub fn planProposalAction(key: vaxis.Key) PlanProposalAction {
    if (isEnterKey(key)) return .implement;
    if (key.matches('e', .{})) return .revise;
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) return .dismiss;
    return .none;
}

pub fn tabNavigationDirection(key: vaxis.Key) ?i8 {
    if (key.matches('>', .{}) or key.matches(vaxis.Key.right, .{})) return 1;
    if (key.matches('<', .{}) or key.matches(vaxis.Key.left, .{})) return -1;
    return null;
}

/// True for the dictation hotkey in both kitty (' '+ctrl) and legacy (NUL)
/// encodings.
pub fn isVoiceKey(key: vaxis.Key) bool {
    return key.matches(' ', .{ .ctrl = true }) or key.codepoint == 0;
}

/// Consume the numeric prefix (default 1).
pub fn takeCount(self: *App) usize {
    const n = if (self.vim.pending_count == 0) 1 else self.vim.pending_count;
    self.vim.pending_count = 0;
    return n;
}

pub fn hasPending(self: *const App) bool {
    return self.vim.pending_count != 0 or self.vim.pending_op != 0 or self.vim.pending_find != 0 or
        self.vim.pending_g or self.vim.pending_replace;
}

/// Cancel whatever is half-typed — count, operator, find, `g` prefix,
/// `r`. Also run on every insert-mode entry so a stale count never
/// survives a round trip.
pub fn clearPending(self: *App) void {
    self.vim.pending_count = 0;
    self.vim.pending_op = 0;
    self.vim.pending_find = 0;
    self.vim.pending_g = false;
    self.vim.pending_replace = false;
}

/// Repeat a forward range motion `n` times from the cursor by walking a
/// scratch cursor; the editor is restored before returning.
pub fn repeatForwardRange(self: *App, comptime range_fn: fn (*const Editor) Editor.Range, n: usize) Editor.Range {
    const ed = &self.view.editor;
    const saved = ed.cursor;
    var end = saved;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = range_fn(ed);
        if (r.end == end and i > 0) break;
        end = r.end;
        ed.cursor = @min(end, ed.text.items.len);
    }
    ed.cursor = saved;
    return .{ .start = saved, .end = end };
}

pub fn repeatBackwardRange(self: *App, comptime range_fn: fn (*const Editor) Editor.Range, n: usize) Editor.Range {
    const ed = &self.view.editor;
    const saved = ed.cursor;
    var start = saved;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = range_fn(ed);
        if (r.start == start and i > 0) break;
        start = r.start;
        ed.cursor = start;
    }
    ed.cursor = saved;
    return .{ .start = start, .end = saved };
}

/// Resolve a completed f/t/F/T: either move the cursor or feed the
/// pending operator (df" / ct)). Inclusive for f, exclusive for t.
pub fn resolveFind(self: *App, kind: u8, ch: u8, count: usize) void {
    const ed = &self.view.editor;
    const forward = kind == 'f' or kind == 't';
    const target = ed.findOnLine(ch, forward, count) orelse {
        self.vim.pending_op = 0;
        return;
    };
    self.vim.last_find_kind = kind;
    self.vim.last_find_ch = ch;
    const t = ed.text.items;
    if (self.vim.pending_op != 0) {
        const op = self.vim.pending_op;
        self.vim.pending_op = 0;
        const range: Editor.Range = switch (kind) {
            'f' => .{ .start = ed.cursor, .end = nextCpEndFor(t, target) },
            't' => .{ .start = ed.cursor, .end = target },
            'F' => .{ .start = target, .end = ed.cursor },
            'T' => .{ .start = nextCpEndFor(t, target), .end = ed.cursor },
            else => return,
        };
        self.applyOperator(op, range);
        return;
    }
    ed.cursor = switch (kind) {
        'f', 'F' => target,
        't' => if (target > 0) target - 1 else 0,
        'T' => nextCpEndFor(t, target),
        else => target,
    };
}

pub fn applyOperator(self: *App, op: u8, range: Editor.Range) void {
    if (range.end <= range.start) return;
    const slice = self.view.editor.text.items[range.start..range.end];
    self.yank_register.clearRetainingCapacity();
    self.yank_register.appendSlice(self.gpa, slice) catch {};
    self.yank_linewise = slice.len > 0 and slice[slice.len - 1] == '\n';
    switch (op) {
        'y' => self.view.editor.cursor = range.start,
        'd' => {
            self.view.editor.pushUndo();
            self.view.editor.deleteRange(range.start, range.end);
        },
        'c' => {
            self.view.editor.pushUndo();
            self.view.editor.deleteRange(range.start, range.end);
            self.mode = .insert;
        },
        else => {},
    }
}

/// Second (and third) key of a d/c/y sequence: a motion, a doubled
/// operator for the whole line, or an i/a text object. Anything else
/// cancels, vim-style.
pub fn operatorKey(self: *App, key: vaxis.Key) void {
    const op = self.vim.pending_op;
    const ed = &self.view.editor;
    if (self.vim.pending_obj != 0) {
        const around = self.vim.pending_obj == 'a';
        self.vim.pending_op = 0;
        self.vim.pending_obj = 0;
        const range: ?Editor.Range = if (key.matches('w', .{}))
            ed.innerWordRange(around)
        else if (key.matches('W', .{ .shift = true }) or key.matches('W', .{}))
            ed.innerWORDRange(around)
        else if (key.matches('<', .{}) or key.matches('>', .{}))
            ed.delimRange('<', '>', around)
        else if (key.matches('"', .{}))
            ed.quoteRange('"', around)
        else if (key.matches('\'', .{}))
            ed.quoteRange('\'', around)
        else if (key.matches('`', .{}))
            ed.quoteRange('`', around)
        else if (key.matches('(', .{}) or key.matches(')', .{}) or key.matches('b', .{}))
            ed.delimRange('(', ')', around)
        else if (key.matches('[', .{}) or key.matches(']', .{}))
            ed.delimRange('[', ']', around)
        else if (key.matches('{', .{}) or key.matches('}', .{}))
            ed.delimRange('{', '}', around)
        else
            null;
        if (range) |r| self.applyOperator(op, r);
        return;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        self.vim.pending_op = 0;
        self.vim.pending_count = 0;
        return;
    }
    if ((key.codepoint >= '1' and key.codepoint <= '9') or
        (key.codepoint == '0' and self.vim.pending_count > 0))
    {
        self.vim.pending_count = self.vim.pending_count * 10 + @as(usize, @intCast(key.codepoint - '0'));
        return;
    }
    if (key.matches('i', .{}) or key.matches('a', .{})) {
        self.vim.pending_obj = if (key.matches('a', .{})) 'a' else 'i';
        return;
    }
    if (key.matches('f', .{}) or key.matches('t', .{}) or
        key.matches('F', .{ .shift = true }) or key.matches('T', .{ .shift = true }))
    {
        // Operator + find: keep the operator pending, await the char.
        self.vim.pending_find = @intCast(key.codepoint);
        return;
    }
    const count = self.takeCount();
    self.vim.pending_op = 0;
    const range: ?Editor.Range = if (key.codepoint == op)
        // dd deletes the line including its newline; cc keeps the shell.
        ed.linesRange(count, op != 'c')
    else if (key.matches('w', .{}))
        // vim's famous special case: `cw` on a non-blank changes to the
        // END of the word (like `ce`) and keeps the following space.
        (if (op == 'c' and !ed.cursorOnBlank())
            self.repeatForwardRange(Editor.wordEndRange, count)
        else
            self.repeatForwardRange(Editor.wordForwardRange, count))
    else if (key.matches('e', .{}))
        self.repeatForwardRange(Editor.wordEndRange, count)
    else if (key.matches('b', .{}))
        self.repeatBackwardRange(Editor.wordBackRange, count)
    else if (key.matches('W', .{ .shift = true }) or key.matches('W', .{}))
        (if (op == 'c' and !ed.cursorOnBlank())
            self.repeatForwardRange(Editor.wordEndRangeBig, count)
        else
            self.repeatForwardRange(Editor.wordForwardRangeBig, count))
    else if (key.matches('E', .{ .shift = true }) or key.matches('E', .{}))
        self.repeatForwardRange(Editor.wordEndRangeBig, count)
    else if (key.matches('B', .{ .shift = true }) or key.matches('B', .{}))
        self.repeatBackwardRange(Editor.wordBackRangeBig, count)
    else if (key.matches('%', .{}))
        ed.matchingBracketRange()
    else if (key.matches('$', .{}))
        ed.toLineEndRange()
    else if (key.matches('0', .{}))
        ed.toLineStartRange()
    else if (key.matches('^', .{}) or key.matches('_', .{}))
        ed.toFirstNonBlankRange()
    else
        null;
    if (range) |r| self.applyOperator(op, r);
}

pub fn copyModeKey(self: *App, key: vaxis.Key) void {
    var cursor = self.copy_cursor orelse return;
    const total = if (self.view.last_total_lines > 0) self.view.last_total_lines else 1;
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
        if (self.view.sel_anchor != null) {
            self.view.sel_anchor = null;
        } else {
            self.copy_cursor = null;
        }
        return;
    } else if (key.matches('y', .{})) {
        self.yankSelection(cursor);
        return;
    } else if (key.matches('v', .{})) {
        self.copy_linewise = false;
        self.view.sel_anchor = cursor;
        self.view.sel_head = cursor;
        return;
    } else if (key.matches('V', .{ .shift = true }) or key.matches('V', .{})) {
        self.copy_linewise = true;
        self.view.sel_anchor = cursor;
        self.updateCopySelection(cursor);
        return;
    } else if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        cursor.col -|= 1;
    } else if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        cursor.col +|= 1;
    } else if (key.matches('j', .{})) {
        cursor.line = @min(cursor.line + 1, total - 1);
    } else if (key.matches('k', .{})) {
        cursor.line -|= 1;
    } else if (key.matches('0', .{})) {
        cursor.col = 0;
    } else if (key.matches('^', .{})) {
        const line = self.copy_cursor_line_text.items;
        var col: usize = 0;
        while (col < line.len and (line[col] == ' ' or line[col] == '\t')) col += 1;
        cursor.col = col;
    } else if (key.matches('$', .{})) {
        cursor.col = self.copy_cursor_line_width -| 1;
    } else if (key.matches('w', .{})) {
        cursor.col = nextWordCol(self.copy_cursor_line_text.items, cursor.col);
    } else if (key.matches('b', .{})) {
        cursor.col = prevWordCol(self.copy_cursor_line_text.items, cursor.col);
    } else if (key.matches('g', .{})) {
        cursor.line = 0;
    } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
        cursor.line = total - 1;
    } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
        cursor.line = @min(cursor.line + 20, total - 1);
    } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
        cursor.line -|= 20;
    } else if (key.matches(vaxis.Key.down, .{})) {
        self.view.scroll_up -|= 1;
        self.clampCopyCursorToView();
        return;
    } else if (key.matches(vaxis.Key.up, .{})) {
        self.view.scroll_up +|= 1;
        self.clampCopyCursorToView();
        self.maybeRequestHistoryAtTop();
        return;
    } else return;
    self.copy_cursor = cursor;
    if (self.view.sel_anchor != null) self.updateCopySelection(cursor);
    self.followCopyCursor();
    self.maybeRequestHistoryAtTop();
}
