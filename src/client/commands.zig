//! Composer commands for the TUI: the `/` and `!` command table, prefix
//! completion for the command menu, and the App methods that implement each
//! command. Split out of tui.zig; everything here operates on a `*tui.App`
//! and is re-exposed there as methods so call sites read the same.

const std = @import("std");
const proto = @import("../core/proto.zig");
const config = @import("../core/config.zig");
const effects = @import("effects.zig");
const voice = @import("voice.zig");
const Editor = @import("editor.zig");
const tui = @import("tui.zig");
const App = tui.App;
const RebuildScope = tui.RebuildScope;
const OwnedCouncil = tui.OwnedCouncil;
const shortcut_help_rows = tui.shortcut_help_rows;
const onOff = tui.onOff;
const notice_ttl_ms = App.notice_ttl_ms;

pub const ComposerCommand = struct {
    name: []const u8,
    usage: []const u8 = "",
    description: []const u8,
    accepts_args: bool = false,
};

/// Visible canonical commands and terse aliases. `/q` remains accepted by
/// the dispatcher, while prefix matching completes it to `/quit`.
pub const composer_commands = [_]ComposerCommand{
    .{ .name = "/model", .usage = " [model]", .description = "switch model or open the picker", .accepts_args = true },
    .{ .name = "/setup", .description = "choose and authenticate a provider or guest agent" },
    .{ .name = "/effort", .usage = " [level]", .description = "set reasoning effort or open the picker", .accepts_args = true },
    .{ .name = "/sandbox", .usage = " [on|off]", .description = "toggle the shell sandbox for this session", .accepts_args = true },
    .{ .name = "/permissions", .usage = " [full|default]", .description = "full access (no prompts) or default approvals", .accepts_args = true },
    .{ .name = "/network", .usage = " [on|off|status]", .description = "control managed-tool domain blocking", .accepts_args = true },
    .{ .name = "/mcp", .usage = " [add|remove|restart|reload]", .description = "inspect and manage MCP servers", .accepts_args = true },
    .{ .name = "/council", .usage = " [<name>|new <name>|edit <name>|remove <name>]", .description = "list, inspect, or edit review councils", .accepts_args = true },
    .{ .name = "/voice", .usage = " [setup|mode|off]", .description = "dictate into the composer (local STT; setup on first use)", .accepts_args = true },
    .{ .name = "/review", .usage = " <council> <question>", .description = "convene a named council on a question", .accepts_args = true },
    .{ .name = "/plan", .usage = " [task|off|clear]", .description = "enter Plan mode or manage its execution todo", .accepts_args = true },
    .{ .name = "/sessions", .description = "switch sessions" },
    .{ .name = "/top", .description = "live session overview and switcher" },
    .{ .name = "/search", .usage = " [query]", .description = "search across durable transcripts", .accepts_args = true },
    .{ .name = "/diagnostics", .description = "inspect recent turn, provider, and tool timing" },
    .{ .name = "/animate", .usage = " <" ++ effects.usage_list ++ ">", .description = "play a transient screen effect", .accepts_args = true },
    .{ .name = "/screensaver", .usage = " [" ++ effects.usage_list ++ "]", .description = "start a continuous full-screen effect", .accepts_args = true },
    .{ .name = "/otel", .usage = " [set <endpoint>|status|off]", .description = "configure live OTLP export", .accepts_args = true },
    .{ .name = "/new", .description = "start a new session" },
    .{ .name = "/rename", .usage = " <title>", .description = "rename this session", .accepts_args = true },
    .{ .name = "/archive", .usage = " [children]", .description = "archive this session, or its finished children", .accepts_args = true },
    .{ .name = "/attach", .usage = " <image-path>", .description = "attach a PNG, JPEG, GIF, or WebP image", .accepts_args = true },
    .{ .name = "/compact", .description = "compact the current context" },
    .{ .name = "/config", .usage = " [tabbar|bell on|off|screensaver <duration|effect> [effect]]", .description = "view or change UI settings (persisted)", .accepts_args = true },
    .{ .name = "/reboot", .usage = " [--build] [--force]", .description = "restart Marlin", .accepts_args = true },
    .{ .name = "/help", .description = "show commands and key bindings" },
    .{ .name = "/quit", .description = "leave Marlin (sessions keep running)" },
    .{ .name = "/detach", .description = "leave Marlin (sessions keep running)" },
    .{ .name = "!", .usage = " [command]", .description = "run a local command, or open an interactive shell", .accepts_args = true },
    .{ .name = "!c", .description = "copy the last full tool output" },
    .{ .name = "!s", .usage = " [" ++ effects.usage_list ++ "]", .description = "start the screensaver (alias for /screensaver)", .accepts_args = true },
    .{ .name = "!rb", .usage = " [client|both]", .description = "rebuild attached Marlin, local client, or both", .accepts_args = true },
};

pub const CommandSuggestion = struct {
    label: []const u8,
    usage: []const u8 = "",
    description: []const u8,
    replacement: []const u8,
    submit_on_enter: bool,
};

pub const OtelCommand = union(enum) {
    status,
    off,
    set: []const u8,
    content: bool,
};

pub fn parseOtelCommand(action_arg: ?[]const u8, rest_arg: []const u8) ?OtelCommand {
    const action = action_arg orelse "status";
    const rest = std.mem.trim(u8, rest_arg, " \t\r\n");
    if (std.mem.eql(u8, action, "status") and rest.len == 0) return .status;
    if (std.mem.eql(u8, action, "off") and rest.len == 0) return .off;
    if (std.mem.eql(u8, action, "set") and rest.len > 0 and
        std.mem.indexOfAny(u8, rest, " \t\r\n") == null)
        return .{ .set = rest };
    if (std.mem.eql(u8, action, "content")) {
        if (std.mem.eql(u8, rest, "on")) return .{ .content = true };
        if (std.mem.eql(u8, rest, "off")) return .{ .content = false };
    }
    return null;
}

pub fn commandQuery(editor: *const Editor) ?[]const u8 {
    const text = editor.text.items;
    if (text.len == 0 or (text[0] != '/' and text[0] != '!')) return null;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return null;
    if (std.mem.indexOfAny(u8, text, " \t")) |space| {
        const head = text[0..space];
        if (!std.mem.eql(u8, head, "/council") and
            !std.mem.eql(u8, head, "/review") and
            !std.mem.eql(u8, head, "/plan") and
            !std.mem.eql(u8, head, "/animate") and
            !std.mem.eql(u8, head, "/screensaver") and
            !std.mem.eql(u8, head, "/otel") and
            !std.mem.eql(u8, head, "!rb")) return null;
        const rest = std.mem.trimStart(u8, text[space..], " \t");
        if (std.mem.indexOfAny(u8, rest, " \t") != null) return null;
    }
    return text;
}

pub fn commandSuggestions(app: *const App, arena: std.mem.Allocator) ![]const CommandSuggestion {
    const query = commandQuery(&app.view.editor) orelse return &.{};
    var out: std.ArrayList(CommandSuggestion) = .empty;
    if (query.len > "/council".len and
        std.mem.eql(u8, query[0.."/council".len], "/council") and
        (query["/council".len] == ' ' or query["/council".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/council".len..], " \t");
        const actions = [_]struct { name: []const u8, description: []const u8 }{
            .{ .name = "new", .description = "create a council" },
            .{ .name = "edit", .description = "edit a council roster" },
            .{ .name = "remove", .description = "remove a council" },
        };
        for (actions) |action| {
            if (rest.len <= action.name.len and std.ascii.eqlIgnoreCase(rest, action.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/council {s} ", .{action.name});
                try out.append(arena, .{
                    .label = try std.fmt.allocPrint(arena, "/council {s}", .{action.name}),
                    .description = action.description,
                    .replacement = replacement,
                    .submit_on_enter = false,
                });
            }
        }
        for (app.councils.items) |council| {
            if (rest.len <= council.name.len and std.ascii.eqlIgnoreCase(rest, council.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/council {s}", .{council.name});
                try out.append(arena, .{
                    .label = replacement,
                    .description = try std.fmt.allocPrint(arena, "show council · {d} models", .{council.models.items.len}),
                    .replacement = replacement,
                    .submit_on_enter = true,
                });
            }
        }
        return out.items;
    }
    if (query.len > "/review".len and
        std.mem.eql(u8, query[0.."/review".len], "/review") and
        (query["/review".len] == ' ' or query["/review".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/review".len..], " \t");
        for (app.councils.items) |council| {
            if (rest.len <= council.name.len and std.ascii.eqlIgnoreCase(rest, council.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/review {s} ", .{council.name});
                try out.append(arena, .{
                    .label = try std.fmt.allocPrint(arena, "/review {s}", .{council.name}),
                    .description = try std.fmt.allocPrint(arena, "review with council · {d} models", .{council.models.items.len}),
                    .replacement = replacement,
                    .submit_on_enter = false,
                });
            }
        }
        return out.items;
    }
    if (query.len > "/otel".len and
        std.mem.eql(u8, query[0.."/otel".len], "/otel") and
        (query["/otel".len] == ' ' or query["/otel".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/otel".len..], " \t");
        const actions = [_]struct { name: []const u8, description: []const u8, submit: bool }{
            .{ .name = "set", .description = "set endpoint, then enter masked headers", .submit = false },
            .{ .name = "status", .description = "show live OTLP exporter state", .submit = true },
            .{ .name = "off", .description = "disable live OTLP export", .submit = true },
        };
        for (actions) |action| {
            if (rest.len <= action.name.len and std.ascii.eqlIgnoreCase(rest, action.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/otel {s}{s}", .{ action.name, if (action.submit) "" else " " });
                try out.append(arena, .{
                    .label = try std.fmt.allocPrint(arena, "/otel {s}", .{action.name}),
                    .description = action.description,
                    .replacement = replacement,
                    .submit_on_enter = action.submit,
                });
            }
        }
        return out.items;
    }
    if (query.len > "!rb".len and
        std.mem.eql(u8, query[0.."!rb".len], "!rb") and
        (query["!rb".len] == ' ' or query["!rb".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["!rb".len..], " \t");
        const actions = [_]struct { name: []const u8, description: []const u8 }{
            .{ .name = "client", .description = "rebuild only the local client" },
            .{ .name = "both", .description = "rebuild the local client and attached Marlin" },
        };
        for (actions) |action| {
            if (rest.len <= action.name.len and std.ascii.eqlIgnoreCase(rest, action.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "!rb {s}", .{action.name});
                try out.append(arena, .{
                    .label = replacement,
                    .description = action.description,
                    .replacement = replacement,
                    .submit_on_enter = true,
                });
            }
        }
        return out.items;
    }
    if (query.len > "/animate".len and
        std.mem.eql(u8, query[0.."/animate".len], "/animate") and
        (query["/animate".len] == ' ' or query["/animate".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/animate".len..], " \t");
        for (effects.kinds) |kind| {
            const name = kind.name();
            if (rest.len <= name.len and std.ascii.eqlIgnoreCase(rest, name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/animate {s}", .{name});
                try out.append(arena, .{
                    .label = replacement,
                    .description = kind.description(),
                    .replacement = replacement,
                    .submit_on_enter = true,
                });
            }
        }
        return out.items;
    }
    if (query.len > "/screensaver".len and
        std.mem.eql(u8, query[0.."/screensaver".len], "/screensaver") and
        (query["/screensaver".len] == ' ' or query["/screensaver".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/screensaver".len..], " \t");
        for (effects.kinds) |kind| {
            const name = kind.name();
            if (rest.len <= name.len and std.ascii.eqlIgnoreCase(rest, name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/screensaver {s}", .{name});
                try out.append(arena, .{
                    .label = replacement,
                    .description = kind.description(),
                    .replacement = replacement,
                    .submit_on_enter = true,
                });
            }
        }
        return out.items;
    }
    if (query.len > "/plan".len and
        std.mem.eql(u8, query[0.."/plan".len], "/plan") and
        (query["/plan".len] == ' ' or query["/plan".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/plan".len..], " \t");
        const actions = [_]struct { name: []const u8, description: []const u8 }{
            .{ .name = "off", .description = "leave Plan mode" },
            .{ .name = "clear", .description = "clear the durable execution todo" },
        };
        for (actions) |action| {
            if (rest.len <= action.name.len and std.ascii.eqlIgnoreCase(rest, action.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/plan {s}", .{action.name});
                try out.append(arena, .{
                    .label = replacement,
                    .description = action.description,
                    .replacement = replacement,
                    .submit_on_enter = true,
                });
            }
        }
        return out.items;
    }
    for (composer_commands) |command| {
        if (query.len <= command.name.len and std.ascii.eqlIgnoreCase(query, command.name[0..query.len])) {
            try out.append(arena, .{
                .label = command.name,
                .usage = command.usage,
                .description = command.description,
                .replacement = command.name,
                .submit_on_enter = true,
            });
        }
    }
    return out.items;
}

pub fn completeSuggestion(editor: *Editor, suggestion: CommandSuggestion, tab: bool) void {
    editor.clear();
    editor.insertSlice(suggestion.replacement);
    if (tab and suggestion.submit_on_enter) {
        for (composer_commands) |command| {
            if (std.mem.eql(u8, suggestion.replacement, command.name) and command.accepts_args) {
                editor.insertSlice(" ");
                break;
            }
        }
    }
}

/// Expand `/review <council> <question>` into the parent agent's turn input:
/// the named roster plus the council procedure, so invocation costs the user
/// one line. Caller frees.
pub fn buildReviewPrompt(gpa: std.mem.Allocator, council: *const OwnedCouncil, question: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "Convene the review council \"{s}\". Reviewers, in order:\n", .{council.name});
    for (council.models.items) |model| try out.print(gpa, "- {s}\n", .{model});
    try out.appendSlice(gpa,
        \\
        \\Load the `council` skill and follow its procedure with exactly this
        \\roster. If the skill is unavailable: write ONE self-contained review
        \\prompt (paths the read-only reviewers can open; paste diff hunks for
        \\anything uncommitted; require verdict, findings with file:line, and
        \\confidence), fan it out with task_batch calls of at most eight tasks
        \\each — one task per reviewer, identical prompt, the model ids above,
        \\and task for a final one-reviewer remainder, max_rounds 12 — then
        \\consolidate: agreements and disagreements
        \\attributed by model, false
        \\positives, and your recommendation. Report reviewers that fail.
        \\
        \\Question for the council:
    );
    try out.append(gpa, ' ');
    try out.appendSlice(gpa, question);
    return out.toOwnedSlice(gpa);
}

/// Composer text is a command when it starts with `/` or `!` — unless the
/// user typed a leading space, which means "send this verbatim" (the shell's
/// own history convention). That is the escape hatch for messages such as
/// `/usr/local/lib/foo.so is missing` or `!important`.
pub fn isCommandInput(text: []const u8) bool {
    if (text.len > 0 and (text[0] == ' ' or text[0] == '\t')) return false;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed.len > 0 and (trimmed[0] == '/' or trimmed[0] == '!');
}

pub fn runCommand(self: *App, cmd: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const head = it.next() orelse return;

    if (std.mem.eql(u8, head, "/quit") or std.mem.eql(u8, head, "/q") or
        std.mem.eql(u8, head, "/detach"))
    {
        self.should_quit = true;
    } else if (std.mem.eql(u8, head, "/setup")) {
        self.requestSetup(false);
    } else if (std.mem.eql(u8, head, "/model")) {
        const m = it.rest();
        if (m.len == 0) {
            self.openPicker(.model);
            // Ask the daemon for the full catalog (async; picker shows
            // favorites until the reply lands).
            if (self.catalog.items.len == 0) {
                self.conn.send(.{ .model_list = .{} }) catch {};
            }
            return;
        }
        self.applyModel(m);
    } else if (std.mem.eql(u8, head, "/effort")) {
        const value = it.rest();
        if (value.len == 0) {
            self.openPicker(.effort);
            return;
        }
        const selected = proto.ReasoningEffort.parse(value) orelse {
            self.setNotice("unknown effort {s} — use auto, none, minimal, low, medium, high, xhigh, or max", .{value});
            return;
        };
        self.applyEffort(selected);
    } else if (std.mem.eql(u8, head, "/search")) {
        const query = std.mem.trim(u8, it.rest(), " \t\r\n");
        self.openSearchPrompt(0);
        if (query.len > 0) {
            self.picker_filter.appendSlice(self.gpa, query) catch {
                self.picker = null;
                self.setNotice("could not start search", .{});
                return;
            };
            self.submitSearch();
        }
    } else if (std.mem.eql(u8, head, "/permissions")) {
        self.setPermissions(it.rest());
    } else if (std.mem.eql(u8, head, "/sandbox")) {
        self.toggleSandbox(it.rest());
    } else if (std.mem.eql(u8, head, "/network")) {
        self.networkCommand(it.rest());
    } else if (std.mem.eql(u8, head, "/mcp")) {
        const action = it.next();
        if (action == null) {
            self.conn.send(.{ .mcp_list = .{} }) catch {
                self.setNotice("could not request MCP status", .{});
            };
        } else if (std.mem.eql(u8, action.?, "restart")) {
            const name = it.next() orelse {
                self.setNotice("usage: /mcp restart <name>", .{});
                return;
            };
            if (it.next() != null) {
                self.setNotice("usage: /mcp restart <name>", .{});
                return;
            }
            self.conn.send(.{ .mcp_restart = .{ .name = name } }) catch {
                self.setNotice("could not restart MCP server", .{});
            };
        } else if (std.mem.eql(u8, action.?, "add")) {
            const name = it.next() orelse {
                self.setNotice("usage: /mcp add <name> <command> [args...]", .{});
                return;
            };
            var command: std.ArrayList([]const u8) = .empty;
            defer command.deinit(self.gpa);
            while (it.next()) |arg| command.append(self.gpa, arg) catch {
                self.setNotice("could not allocate MCP command", .{});
                return;
            };
            if (command.items.len == 0) {
                self.setNotice("usage: /mcp add <name> <command> [args...]", .{});
                return;
            }
            self.conn.send(.{ .mcp_add = .{ .name = name, .cmd = command.items } }) catch {
                self.setNotice("could not add MCP server", .{});
            };
        } else if (std.mem.eql(u8, action.?, "remove")) {
            const name = it.next() orelse {
                self.setNotice("usage: /mcp remove <name>", .{});
                return;
            };
            if (it.next() != null) {
                self.setNotice("usage: /mcp remove <name>", .{});
                return;
            }
            self.conn.send(.{ .mcp_remove = .{ .name = name } }) catch {
                self.setNotice("could not remove MCP server", .{});
            };
        } else if (std.mem.eql(u8, action.?, "reload") and it.next() == null) {
            self.conn.send(.{ .mcp_reload = .{} }) catch {
                self.setNotice("could not reload MCP config", .{});
            };
        } else {
            self.setNotice("usage: /mcp [add <name> <command> [args...]|remove <name>|restart <name>|reload]", .{});
        }
    } else if (std.mem.eql(u8, head, "/council")) {
        const action = it.next();
        if (action == null or std.mem.eql(u8, action.?, "list")) {
            if (self.councils.items.len > 0)
                self.openCouncilList()
            else
                self.council_list_pending = true;
            self.conn.send(.{ .council_list = .{} }) catch {
                self.council_list_pending = false;
                self.setNotice("could not request councils", .{});
            };
        } else if (std.mem.eql(u8, action.?, "new") or std.mem.eql(u8, action.?, "edit")) {
            const name = it.next() orelse {
                self.setNotice("usage: /council {s} <name>", .{action.?});
                return;
            };
            if (it.next() != null) {
                self.setNotice("usage: /council {s} <name>", .{action.?});
                return;
            }
            if (std.mem.eql(u8, action.?, "new") and self.councilByName(name) != null) {
                self.setNotice("council '{s}' already exists — use /council edit {s}", .{ name, name });
                return;
            }
            self.openCouncilPicker(name);
        } else if (std.mem.eql(u8, action.?, "set") or std.mem.eql(u8, action.?, "add")) {
            const name = it.next() orelse {
                self.setNotice("usage: /council set <name> <model...>", .{});
                return;
            };
            var models: std.ArrayList([]const u8) = .empty;
            defer models.deinit(self.gpa);
            while (it.next()) |model| models.append(self.gpa, model) catch return;
            if (models.items.len == 0) {
                self.setNotice("usage: /council set <name> <model...>", .{});
                return;
            }
            self.council_notice_pending = true;
            self.conn.send(.{ .council_set = .{ .name = name, .models = models.items } }) catch {
                self.setNotice("could not save council", .{});
            };
        } else if (std.mem.eql(u8, action.?, "remove") or std.mem.eql(u8, action.?, "delete")) {
            const name = it.next() orelse {
                self.setNotice("usage: /council remove <name>", .{});
                return;
            };
            self.council_notice_pending = true;
            self.conn.send(.{ .council_remove = .{ .name = name } }) catch {
                self.setNotice("could not remove council", .{});
            };
        } else if (it.next() == null) {
            self.showCouncilDetail(action.?);
        } else {
            self.setNotice("usage: /council [<name>|new <name>|edit <name>|remove <name>]", .{});
        }
    } else if (std.mem.eql(u8, head, "/plan")) {
        const arg = std.mem.trim(u8, it.rest(), " \t");
        if (std.mem.eql(u8, arg, "clear")) {
            if (self.view.state == .running or self.view.state == .awaiting_approval) {
                self.setNotice("cannot clear a plan mid-turn", .{});
                return;
            }
            self.conn.send(.{ .plan_clear = .{ .sid = self.view.sid } }) catch {
                self.setNotice("could not clear plan", .{});
            };
        } else if (std.mem.eql(u8, arg, "off")) {
            _ = self.setPlanMode(false);
        } else if (arg.len == 0) {
            _ = self.setPlanMode(true);
        } else if (self.setPlanMode(true)) {
            self.submitInput(arg);
        }
    } else if (std.mem.eql(u8, head, "/review")) {
        const name = it.next() orelse {
            self.setNotice("usage: /review <council> <question>", .{});
            return;
        };
        const question = std.mem.trim(u8, it.rest(), " \t");
        if (question.len == 0) {
            self.setNotice("usage: /review <council> <question>", .{});
            return;
        }
        const council = self.councilByName(name) orelse {
            if (self.councils.items.len == 0)
                self.setNotice("no councils configured — /council new <name>", .{})
            else
                self.setNotice("unknown council '{s}' — /council lists them", .{name});
            return;
        };
        if (proto.isGuestModel(self.view.model.items)) {
            self.setNotice("councils need a native session (guest sessions have no marlin tools)", .{});
            return;
        }
        const expanded = buildReviewPrompt(self.gpa, council, question) catch {
            self.setNotice("could not compose review prompt", .{});
            return;
        };
        defer self.gpa.free(expanded);
        self.submitInput(expanded);
    } else if (std.mem.eql(u8, head, "/voice")) {
        const action = it.next();
        if (action == null) {
            if (!self.voice_rt.enabled) self.startVoiceSetup() else self.voiceStatusNotice();
        } else if (std.mem.eql(u8, action.?, "setup")) {
            self.startVoiceSetup();
        } else if (std.mem.eql(u8, action.?, "off")) {
            if (self.voice_rt.setup) |st| {
                const environ = self.environ orelse return;
                config.setVoice(self.gpa, self.io, environ, false, st.engine.configName(), if (st.mode == .toggle) "toggle" else "ptt", st.model_path, st.stt_bin) catch {};
            }
            self.voice_rt.enabled = false;
            self.setNotice("voice off — /voice turns it back on", .{});
        } else if (std.mem.eql(u8, action.?, "on")) {
            if (self.voice_rt.setup) |st| {
                const environ = self.environ orelse return;
                config.setVoice(self.gpa, self.io, environ, true, st.engine.configName(), if (st.mode == .toggle) "toggle" else "ptt", st.model_path, st.stt_bin) catch {};
                self.voice_rt.enabled = true;
                self.voiceStatusNotice();
            } else self.startVoiceSetup();
        } else if (std.mem.eql(u8, action.?, "mode")) {
            const which = it.next() orelse {
                self.setNotice("usage: /voice mode ptt|toggle", .{});
                return;
            };
            const mode: voice.Mode = if (std.mem.eql(u8, which, "toggle")) .toggle else .ptt;
            if (self.voice_rt.setup) |*st| {
                st.mode = mode;
                const environ = self.environ orelse return;
                config.setVoice(self.gpa, self.io, environ, self.voice_rt.enabled, st.engine.configName(), if (mode == .toggle) "toggle" else "ptt", st.model_path, st.stt_bin) catch {};
                self.voiceStatusNotice();
            } else self.setNotice("voice is not set up — /voice setup first", .{});
        } else {
            self.setNotice("usage: /voice [setup|mode ptt|toggle|off|on]", .{});
        }
    } else if (std.mem.eql(u8, head, "/sessions")) {
        self.openPicker(.session);
    } else if (std.mem.eql(u8, head, "/top")) {
        self.openTop();
    } else if (std.mem.eql(u8, head, "/new")) {
        self.newSession() catch {
            self.setNotice("could not create session", .{});
        };
    } else if (std.mem.eql(u8, head, "/rename")) {
        const title = std.mem.trim(u8, it.rest(), " \t");
        if (title.len == 0) {
            self.setNotice("usage: /rename <title>", .{});
            return;
        }
        self.conn.send(.{ .session_rename = .{ .sid = self.view.sid, .title = title } }) catch {
            self.setNotice("could not rename session", .{});
            return;
        };
        self.setNotice("renamed to {s}", .{title});
    } else if (std.mem.eql(u8, head, "/archive")) {
        const arg = it.rest();
        if (arg.len == 0) {
            self.archiveCurrentSession();
        } else if (std.mem.eql(u8, arg, "children")) {
            self.archiveFinishedChildren();
        } else {
            self.setNotice("usage: /archive [children]", .{});
        }
    } else if (std.mem.eql(u8, head, "/attach")) {
        self.attachPath(it.rest());
    } else if (std.mem.eql(u8, head, "!")) {
        self.shellEscape(it.rest());
    } else if (std.mem.eql(u8, head, "!c")) {
        self.copyLastToolOutput();
    } else if (std.mem.eql(u8, head, "/reboot") or std.mem.eql(u8, head, "!rb")) {
        var rebuild: RebuildScope = if (std.mem.eql(u8, head, "!rb")) .attached else .none;
        var force = false;
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--build")) {
                rebuild = .attached;
            } else if (std.mem.eql(u8, arg, "--force")) {
                force = true;
            } else if (std.mem.eql(u8, head, "!rb") and std.mem.eql(u8, arg, "client")) {
                rebuild = .client;
            } else if (std.mem.eql(u8, head, "!rb") and std.mem.eql(u8, arg, "both")) {
                rebuild = .both;
            } else {
                if (std.mem.eql(u8, head, "!rb"))
                    self.setNotice("usage: !rb [client|both] [--force]", .{})
                else
                    self.setNotice("usage: /reboot [--build] [--force]", .{});
                return;
            }
        }
        if (self.view.state == .awaiting_approval and !force and rebuild != .client) {
            self.setNotice("approval pending — answer it, interrupt, or /reboot --force", .{});
            return;
        }
        if (self.view.state == .running and rebuild != .client) {
            self.setNotice("turn running — /reboot waits for it (interrupt first if you want force)", .{});
        }
        self.reboot_request = .{ .requested = true, .rebuild = rebuild, .force = force };
        self.should_quit = true;
    } else if (std.mem.eql(u8, head, "/compact")) {
        if (proto.isGuestModel(self.view.model.items)) {
            self.setNotice("guest agents manage their own context — /compact is native-only", .{});
            return;
        }
        if (self.view.state == .running or self.view.state == .awaiting_approval) {
            self.setNotice("cannot compact mid-turn", .{});
            return;
        }
        self.conn.send(.{ .session_compact = .{ .sid = self.view.sid } }) catch return;
        self.setNotice("compacting…", .{});
    } else if (std.mem.eql(u8, head, "/diagnostics")) {
        if (it.next() != null) {
            self.setNotice("usage: /diagnostics", .{});
            return;
        }
        self.conn.send(.{ .diagnostics = .{ .sid = self.view.sid } }) catch {
            self.setNotice("could not request diagnostics", .{});
        };
    } else if (std.mem.eql(u8, head, "/animate")) {
        const name = it.next() orelse {
            self.setNotice("usage: /animate <" ++ effects.usage_list ++ ">", .{});
            return;
        };
        const kind = effects.Kind.parse(name) orelse {
            self.setNotice("unknown effect {s}", .{name});
            return;
        };
        const sky_arg = it.next();
        if (it.next() != null) {
            self.setNotice("usage: /animate <" ++ effects.usage_list ++ "> [hour|cycle]", .{});
            return;
        }
        if (!self.applySkyArg(kind, sky_arg)) return;
        self.startUiAnimation(kind);
    } else if (std.mem.eql(u8, head, "/screensaver") or std.mem.eql(u8, head, "!s")) {
        const kind = if (it.next()) |name| effects.Kind.parse(name) orelse {
            self.setNotice("unknown effect {s}", .{name});
            return;
        } else self.screensaver_kind;
        const sky_arg = it.next();
        if (it.next() != null) {
            self.setNotice("usage: /screensaver [" ++ effects.usage_list ++ "] [hour|cycle]", .{});
            return;
        }
        if (!self.applySkyArg(kind, sky_arg)) return;
        self.startScreensaver(kind);
    } else if (std.mem.eql(u8, head, "/otel")) {
        self.otelCommand(it.next(), it.rest());
    } else if (std.mem.eql(u8, head, "/config")) {
        const setting = it.next();
        const value = it.next();
        const extra = it.next();
        if (it.next() != null) {
            self.setNotice("too many /config arguments", .{});
            return;
        }
        self.configCommand(setting, value, extra);
    } else if (std.mem.eql(u8, head, "/help")) {
        // The status bar is one row; the catalog is not. Open the help
        // panel scrolled to its generated COMMANDS section instead.
        self.shortcut_help = true;
        self.help_scroll = shortcut_help_rows.len;
    } else if (head.len > 1 and head[0] == '!') {
        // `!ls -la` — every shell and vim accept the bang glued to the
        // command. The exact `!c`/`!rb` shortcuts matched above.
        self.shellEscape(cmd[1..]);
    } else {
        self.setNotice("unknown command {s} (try /help)", .{head});
    }
}

/// `/config` — durable UI preferences serialized by the daemon.
pub fn configCommand(self: *App, setting: ?[]const u8, value: ?[]const u8, extra: ?[]const u8) void {
    const name = setting orelse {
        var duration_buf: [32]u8 = undefined;
        self.setNotice("config · tabbar {s} · bell {s} · screensaver {s} {s}", .{
            onOff(self.show_tab_bar),
            onOff(self.bell_enabled),
            config.formatDuration(&duration_buf, self.screensaver_timeout_ms) catch "invalid",
            self.screensaver_kind.name(),
        });
        return;
    };
    if (std.mem.eql(u8, name, "screensaver")) {
        const raw = value orelse {
            self.setNotice("usage: /config screensaver <30s|10m|1h|off|effect> [effect]", .{});
            return;
        };
        var after_ms = self.screensaver_timeout_ms;
        var kind = self.screensaver_kind;
        if (effects.Kind.parse(raw)) |parsed| {
            if (extra != null) {
                self.setNotice("usage: /config screensaver <duration|effect> [effect]", .{});
                return;
            }
            kind = parsed;
        } else {
            after_ms = config.parseDurationMs(raw) catch {
                self.setNotice("usage: /config screensaver <30s|10m|1h|off> [" ++ effects.usage_list ++ "]", .{});
                return;
            };
            if (extra) |effect_name| {
                kind = effects.Kind.parse(effect_name) orelse {
                    self.setNotice("unknown effect {s}", .{effect_name});
                    return;
                };
            }
        }
        const previous_timeout = self.screensaver_timeout_ms;
        const previous_kind = self.screensaver_kind;
        self.screensaver_timeout_ms = after_ms;
        self.screensaver_kind = kind;
        self.recordUserActivity();
        self.syncAnimationTicker();
        self.conn.send(.{ .ui_set_screensaver = .{
            .after_ms = after_ms,
            .effect = kind.name(),
        } }) catch |err| {
            self.screensaver_timeout_ms = previous_timeout;
            self.screensaver_kind = previous_kind;
            self.recordUserActivity();
            self.syncAnimationTicker();
            self.setNotice("screensaver setting not saved: {t}", .{err});
            return;
        };
        var duration_buf: [32]u8 = undefined;
        self.setNotice("screensaver {s} {s} (saving…)", .{
            config.formatDuration(&duration_buf, after_ms) catch "invalid",
            kind.name(),
        });
        return;
    }

    const is_tabbar = std.mem.eql(u8, name, "tabbar");
    const is_bell = std.mem.eql(u8, name, "bell");
    if (!is_tabbar and !is_bell) {
        self.setNotice("usage: /config <tabbar|bell> [on|off] or /config screensaver <duration|effect> [effect]", .{});
        return;
    }
    const current = if (is_tabbar) self.show_tab_bar else self.bell_enabled;
    const enable = if (value) |v| blk: {
        if (std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "true")) break :blk true;
        if (std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "false")) break :blk false;
        self.setNotice("usage: /config <tabbar|bell> [on|off]", .{});
        return;
    } else !current;
    if (is_tabbar) {
        self.show_tab_bar = enable;
        self.refresh_requested = true;
    } else {
        self.bell_enabled = enable;
    }
    const msg: proto.ClientMsg = if (is_tabbar)
        .{ .ui_set_tab_bar = .{ .enabled = enable } }
    else
        .{ .ui_set_bell = .{ .enabled = enable } };
    self.conn.send(msg) catch |err| {
        self.setNotice("{s} {s} (not saved: {t})", .{ name, onOff(enable), err });
        return;
    };
    self.setNotice("{s} {s} (saving…)", .{ name, onOff(enable) });
}

pub fn showMcpStatus(self: *App, servers: []const proto.McpServerInfo) void {
    self.notice.clearRetainingCapacity();
    self.armNoticeExpiry(2 * notice_ttl_ms); // a list the user asked to read
    if (servers.len == 0) {
        self.notice.appendSlice(self.gpa, "MCP · no servers configured") catch {};
        return;
    }
    self.notice.appendSlice(self.gpa, "MCP · ") catch return;
    for (servers, 0..) |server, i| {
        if (i > 0) self.notice.appendSlice(self.gpa, " · ") catch return;
        if (server.ready) {
            self.notice.print(self.gpa, "{s} ✓ {d} tools", .{ server.name, server.tool_count }) catch return;
        } else {
            const message = server.error_message orelse "unavailable";
            self.notice.print(self.gpa, "{s} ✗ {s}", .{ server.name, message[0..@min(message.len, 96)] }) catch return;
        }
    }
}

pub fn otelCommand(self: *App, action_arg: ?[]const u8, rest_arg: []const u8) void {
    const parsed = parseOtelCommand(action_arg, rest_arg) orelse {
        self.setNotice("usage: /otel [status|off|set <endpoint>|content on|content off]", .{});
        return;
    };
    switch (parsed) {
        .status => self.conn.send(.{ .otel_status = .{} }) catch {
            self.setNotice("could not request OTLP status", .{});
        },
        .off => self.conn.send(.{ .otel_configure = .{} }) catch {
            self.setNotice("could not disable OTLP export", .{});
        },
        .content => |enabled| self.conn.send(.{ .otel_content = .{ .enabled = enabled } }) catch {
            self.setNotice("could not toggle OTLP content capture", .{});
        },
        .set => |endpoint| {
            self.otel_endpoint.clearRetainingCapacity();
            self.otel_endpoint.appendSlice(self.gpa, endpoint) catch {
                self.setNotice("could not start OTLP setup", .{});
                return;
            };
            self.view.editor.clear();
            self.otel_header_prompt = true;
            self.mode = .insert;
            self.setNotice("enter OTLP headers: name=value[,name=value] · Enter applies · Esc cancels", .{});
        },
    }
}

pub fn submitOtelHeaders(self: *App, headers: []const u8) void {
    if (!self.otel_header_prompt) return;
    self.otel_header_prompt = false;
    defer self.otel_endpoint.clearRetainingCapacity();
    self.conn.sendSensitive(.{ .otel_configure = .{
        .endpoint = self.otel_endpoint.items,
        .headers = headers,
    } }) catch {
        self.setNotice("could not configure OTLP export", .{});
        return;
    };
    self.setNotice("configuring OTLP export…", .{});
}

pub fn cancelOtelSetup(self: *App) void {
    self.view.editor.clearSensitive();
    self.otel_endpoint.clearRetainingCapacity();
    self.otel_header_prompt = false;
    self.setNotice("OTLP setup cancelled", .{});
}

pub fn networkCommand(self: *App, arg: []const u8) void {
    if (proto.isGuestModel(self.view.model.items)) {
        self.setNotice("dnsblock is Marlin's; guest-agent networking is not filtered here", .{});
        return;
    }
    if (arg.len == 0 or std.mem.eql(u8, arg, "status")) {
        if (!self.conn.network_filtering) {
            if (self.conn.network_configured) {
                self.setNotice("network filter unavailable — configured rules failed to load; networking is fail-open", .{});
            } else {
                self.setNotice("network filter off — no blocklist or deny rules configured", .{});
            }
            return;
        }
        const state = if (self.currentNetworkFiltering()) "on" else "off";
        self.setNotice("network filter {s} — {d} rules from {d} feeds; fetch enforced · shell literals screened", .{
            state,
            self.conn.network_rule_count,
            self.conn.network_feed_count,
        });
        return;
    }
    if (self.view.state == .running or self.view.state == .awaiting_approval) {
        self.setNotice("cannot toggle network filtering mid-turn", .{});
        return;
    }
    const target = if (std.mem.eql(u8, arg, "on"))
        true
    else if (std.mem.eql(u8, arg, "off"))
        false
    else {
        self.setNotice("usage: /network [on|off|status]", .{});
        return;
    };
    if (target and !self.conn.network_filtering) {
        if (self.conn.network_configured) {
            self.setNotice("network filter unavailable — configured rules failed to load; reboot after connectivity returns", .{});
        } else {
            self.setNotice("network filter off — add [network] blocklists or deny rules, then reboot", .{});
        }
        return;
    }
    self.conn.send(.{ .session_set_network_filtering = .{ .sid = self.view.sid, .enabled = target } }) catch return;
    self.setNotice("network filter {s} for this session", .{if (target) @as([]const u8, "on") else "off"});
}

/// /permissions full|default — session-wide approval switch. Full
/// access means NOTHING asks (the --yolo mode, chosen mid-session);
/// default restores boundary-crossing prompts. Tracked optimistically:
/// the daemon rejects mid-turn switches with a visible err notice.
pub fn setPermissions(self: *App, arg: []const u8) void {
    const full = if (std.mem.eql(u8, arg, "full"))
        true
    else if (std.mem.eql(u8, arg, "default"))
        false
    else if (arg.len == 0)
        !self.view.permissions_full
    else {
        self.setNotice("usage: /permissions [full|default]", .{});
        return;
    };
    const mode: []const u8 = if (full) "auto" else "default";
    self.conn.send(.{ .session_set_approvals = .{ .sid = self.view.sid, .approvals = mode } }) catch return;
    self.view.permissions_full = full;
    if (full) {
        self.setNotice("permissions: FULL ACCESS — nothing will ask for approval", .{});
    } else {
        self.setNotice("permissions: default — boundary-crossing tools ask again", .{});
    }
}

pub fn toggleSandbox(self: *App, arg: []const u8) void {
    if (proto.isGuestModel(self.view.model.items)) {
        self.setNotice("sandbox is Marlin's; guest agents use their own permissions", .{});
        return;
    }
    if (self.view.state == .running or self.view.state == .awaiting_approval) {
        self.setNotice("cannot toggle sandbox mid-turn", .{});
        return;
    }
    const target = if (arg.len == 0)
        !self.currentSandboxed()
    else if (std.mem.eql(u8, arg, "on"))
        true
    else if (std.mem.eql(u8, arg, "off"))
        false
    else {
        self.setNotice("usage: /sandbox [on|off]", .{});
        return;
    };
    if (target and !self.conn.sandbox_available) {
        self.setNotice("sandbox unavailable on this platform — per-call approvals retained", .{});
        return;
    }
    self.conn.send(.{ .session_set_sandbox = .{ .sid = self.view.sid, .enabled = target } }) catch return;
    if (target) {
        self.setNotice("sandbox on — workspace shell runs without prompts", .{});
    } else {
        self.setNotice("sandbox off — every shell call asks again", .{});
    }
}
