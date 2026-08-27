//! Configuration: ~/.config/marlin/config.toml → an owned Config view.
//!
//! `Loaded` owns every dynamic slice referenced by `Config`; keep it alive
//! for as long as the daemon or client uses the value.

const std = @import("std");
const Io = std.Io;
const Effort = @import("effort.zig").Effort;
const credentials = @import("credentials.zig");
const toml = @import("config_toml.zig");

pub const ExecTool = toml.ExecTool;
pub const McpServer = toml.McpServer;
pub const Council = toml.Council;
pub const Hooks = toml.Hooks;
pub const Policy = toml.Policy;

pub const Config = struct {
    model_default: []const u8 = "openrouter/anthropic/claude-sonnet-4.5",
    model_compaction: ?[]const u8 = null, // null → use model_default
    /// `.auto` omits the request parameter and preserves the model default.
    effort_default: Effort = .auto,
    /// OpenRouter otherwise prioritizes price. Throughput routing is the
    /// interactive-agent default; null restores OpenRouter's own policy.
    openrouter_sort: ?[]const u8 = "throughput",

    /// Model picker list (/model with no args). Curated, not fetched:
    /// OpenRouter exposes 300+ models and a dump of that is not a picker.
    /// User-defined favorites replace these defaults when present in TOML.
    model_favorites: []const []const u8 = &.{
        // Delegated Claude Code sessions (subscription inference; picking one
        // errors clearly when the binary is absent). Aliases resolve to the
        // latest model of each family, per `claude --help`.
        "claudecode/fable",
        "claudecode/sonnet",
        "openrouter/anthropic/claude-sonnet-4.5",
        "openrouter/anthropic/claude-opus-4.5",
        "openrouter/openai/gpt-5.2",
        "openrouter/google/gemini-2.5-pro",
        "openrouter/x-ai/grok-4.6",
        "openrouter/deepseek/deepseek-v4",
        "openrouter/z-ai/glm-5.3",
        "openrouter/moonshotai/kimi-k3",
    },

    /// Context engine (docs/ARCHITECTURE.md §6).
    output_headroom_tokens: u32 = 16_000,
    compaction_headroom_tokens: u32 = 8_000,
    inline_tool_cap_bytes: u32 = 8_000,
    prune_protect_tokens: u32 = 40_000, // OpenCode constants
    prune_min_reclaim_tokens: u32 = 20_000,

    /// Approval defaults (docs/ARCHITECTURE.md §7).
    mutating_tools_policy: Policy = .ask,
    readonly_tools_policy: Policy = .auto,

    /// Capability permissions (docs/PERMISSIONS.md). Secret environment
    /// isolation is unconditional; this flag gates the capability
    /// approval/enforcement flow. On by default: every enforcement-affecting
    /// surface is canary-gated and fails closed to legacy ask behavior, so
    /// the flag only changes behavior on a platform whose sandbox proved
    /// itself at daemon startup. MARLIN_PERMISSIONS=0 opts out.
    permissions_enabled: bool = true,

    /// Allow-by-default hostname policy for Marlin-owned network tools.
    /// Values are comma-separated catalog ids/domains. An explicit deny wins;
    /// an explicit allow overrides subscribed feed matches.
    network_blocklists: ?[]const u8 = null,
    network_allow: ?[]const u8 = null,
    network_deny: ?[]const u8 = null,

    /// Process-boundary extensions (M5). All slices are owned by `Loaded`.
    exec_tools: []const ExecTool = &.{},
    mcp_servers: []const McpServer = &.{},
    councils: []const Council = &.{},
    /// Voice dictation ([voice], written by /voice setup). Dormant until
    /// enabled; nothing else in marlin mentions its dependencies.
    voice_enabled: bool = false,
    voice_engine: []const u8 = "",
    voice_mode: []const u8 = "ptt",
    voice_model: []const u8 = "",
    voice_stt_bin: []const u8 = "",
    hooks: Hooks = .{},
    skill_directories: []const []const u8 = &.{},

    /// Workspace layer (docs/WORKSPACE.md): COW shadow snapshots and write
    /// leases. Independent of permissions and OFF until M4.5 lands.
    workspace_enabled: bool = false,

    /// `marlin web` gate. OFF by default and deliberately opt-in: the web
    /// bridge is an unauthenticated localhost surface that can drive every
    /// daemon capability (including shutdown). `[web] enabled = true` or
    /// MARLIN_WEB=1 turns it on.
    web_enabled: bool = false,

    /// `marlin web` attempts `tailscale serve` so the UI is reachable at a
    /// fixed tailnet https URL (the tailnet is the trust boundary). On by
    /// default; degrades silently to localhost-only when tailscale is absent
    /// or logged out. `[web] tailscale = false` opts out.
    web_tailscale: bool = true,

    /// TUI chrome (`[ui]`): the top tab strip. Toggleable live via /config;
    /// the daemon serializes persistence through setUiTabBar.
    ui_tab_bar: bool = true,
};

pub fn defaults() Config {
    return .{};
}

/// Defaults plus environment overrides, primarily for focused tests and the
/// rollout compatibility layer. Normal daemon startup uses `load` below.
pub fn fromEnviron(environ: *const std.process.Environ.Map) Config {
    var c = defaults();
    applyEnviron(&c, environ);
    return c;
}

fn applyEnviron(c: *Config, environ: *const std.process.Environ.Map) void {
    if (environ.get("MARLIN_PERMISSIONS")) |v| {
        c.permissions_enabled = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true");
    }
    if (environ.get("MARLIN_WEB")) |v| {
        c.web_enabled = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true");
    }
    if (environ.get("MARLIN_NETWORK_BLOCKLISTS")) |value| c.network_blocklists = value;
    if (environ.get("MARLIN_NETWORK_ALLOW")) |value| c.network_allow = value;
    if (environ.get("MARLIN_NETWORK_DENY")) |value| c.network_deny = value;
    if (environ.get("MARLIN_OPENROUTER_SORT")) |value| {
        c.openrouter_sort = if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "none")) null else value;
    }
}

pub const Loaded = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    value: Config,

    pub fn deinit(self: *Loaded) void {
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
        self.* = undefined;
    }
};

const starter_config =
    \\# Marlin starter configuration. Existing files are never rewritten.
    \\# See docs/PERMISSIONS.md for network policy scope and overrides.
    \\
    \\[network]
    \\blocklists = "hagezi-tif-mini"
    \\
;

/// Load the XDG-aware config file once. A missing file is initialized with a
/// sparse starter configuration; a present malformed file fails startup rather
/// than silently running with a different tool or approval policy than intended.
pub fn load(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !Loaded {
    const arena_state = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_state);
    arena_state.* = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = defaults();
    const config_dir = try credentials.configDir(arena, environ);
    const default_skills = try std.fs.path.join(arena, &.{ config_dir, "skills" });
    const skill_dirs = try arena.alloc([]const u8, 1);
    skill_dirs[0] = default_skills;
    cfg.skill_directories = skill_dirs;

    const path = try std.fs.path.join(arena, &.{ config_dir, "config.toml" });
    const cwd = Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, path, arena, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            var atomic = try cwd.createFileAtomic(io, path, .{ .make_path = true });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, starter_config);
            atomic.link(io) catch |link_err| switch (link_err) {
                error.PathAlreadyExists => {},
                else => return link_err,
            };
            break :blk try cwd.readFileAlloc(io, path, arena, .limited(2 * 1024 * 1024));
        },
        else => return err,
    };
    const doc = try toml.parse(arena, bytes);
    applyDocument(&cfg, doc);
    // Environment is the final override layer during the M3.5 rollout.
    applyEnviron(&cfg, environ);
    try validate(gpa, cfg);
    return .{ .gpa = gpa, .arena_state = arena_state, .value = cfg };
}

const max_config_bytes = 2 * 1024 * 1024;

/// Read the exact config bytes so daemon-owned MCP edits can be rolled back if
/// rebuilding the live extension registry fails.
pub fn readRawAlloc(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const dir = try credentials.configDir(gpa, environ);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "config.toml" });
    defer gpa.free(path);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes));
}

/// Replace config.toml atomically. Readers see either the complete old file or
/// the complete new file, never a partially written MCP table.
pub fn replaceRaw(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    bytes: []const u8,
) !void {
    if (bytes.len > max_config_bytes) return error.StreamTooLong;
    const dir = try credentials.configDir(gpa, environ);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "config.toml" });
    defer gpa.free(path);
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

pub fn addMcpServer(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    name: []const u8,
    cmd: []const []const u8,
) !void {
    const current = try readRawAlloc(gpa, io, environ);
    defer gpa.free(current);
    const updated = try addMcpServerText(gpa, current, name, cmd);
    defer gpa.free(updated);
    try replaceRaw(gpa, io, environ, updated);
}

pub fn removeMcpServer(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    name: []const u8,
) !void {
    const current = try readRawAlloc(gpa, io, environ);
    defer gpa.free(current);
    const updated = try removeMcpServerText(gpa, current, name);
    defer gpa.free(updated);
    try replaceRaw(gpa, io, environ, updated);
}

/// Persist the TUI tab-bar preference (`[ui] tab_bar`), editing the user's
/// config.toml surgically: replace the existing key line, insert it into an
/// existing [ui] table, or append a fresh table — everything else stays
/// byte-for-byte, and the result must reparse before it may replace the file.
pub fn setUiTabBar(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    enabled: bool,
) !void {
    const current = try readRawAlloc(gpa, io, environ);
    defer gpa.free(current);
    const updated = try setScalarText(gpa, current, "ui", "tab_bar", if (enabled) "true" else "false");
    defer gpa.free(updated);
    try replaceRaw(gpa, io, environ, updated);
}

/// Set `key = value` inside `[section]` of a TOML document, preserving all
/// other bytes. Section/key matching mirrors the parser (trimmed lines,
/// comments stripped); the produced text is parse-verified by the caller's
/// value being a valid literal and a final toml.parse here.
fn setScalarText(
    gpa: std.mem.Allocator,
    current: []const u8,
    section: []const u8,
    key: []const u8,
    value: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var in_section = false;
    var replaced = false;
    var offset: usize = 0;
    while (offset < current.len) {
        const line_end = std.mem.indexOfScalarPos(u8, current, offset, '\n') orelse current.len;
        const next = if (line_end < current.len) line_end + 1 else line_end;
        const raw = current[offset..line_end];
        const line = std.mem.trim(u8, raw, " \t\r");

        if (line.len > 0 and line[0] == '[') {
            if (in_section and !replaced) {
                // Leaving the target section without having found the key:
                // insert it at the section's end, before this next header.
                try out.print(gpa, "{s} = {s}\n", .{ key, value });
                replaced = true;
            }
            const header = std.mem.trim(u8, std.mem.trim(u8, line, "[]"), " \t");
            in_section = std.mem.eql(u8, header, section);
        } else if (in_section and !replaced) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const line_key = std.mem.trim(u8, line[0..eq], " \t");
                if (std.mem.eql(u8, line_key, key)) {
                    try out.print(gpa, "{s} = {s}\n", .{ key, value });
                    replaced = true;
                    offset = next;
                    continue;
                }
            }
        }
        try out.appendSlice(gpa, current[offset..next]);
        if (next == line_end and line_end == current.len and raw.len > 0) try out.append(gpa, '\n');
        offset = next;
    }
    if (!replaced) {
        if (in_section) {
            // Section was the last one in the file; append the key to it.
            try out.print(gpa, "{s} = {s}\n", .{ key, value });
        } else {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
            if (out.items.len > 0) try out.append(gpa, '\n');
            try out.print(gpa, "[{s}]\n{s} = {s}\n", .{ section, key, value });
        }
    }

    var verify_arena = std.heap.ArenaAllocator.init(gpa);
    defer verify_arena.deinit();
    _ = try toml.parse(verify_arena.allocator(), out.items);
    return out.toOwnedSlice(gpa);
}

/// Define or replace a named review council (durable [[council]] table).
/// Replace semantics make /council set the edit verb too.
pub fn setCouncil(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    name: []const u8,
    models: []const []const u8,
) !void {
    const current = try readRawAlloc(gpa, io, environ);
    defer gpa.free(current);
    const updated = try setCouncilText(gpa, current, name, models);
    defer gpa.free(updated);
    try replaceRaw(gpa, io, environ, updated);
}

pub fn removeCouncil(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    name: []const u8,
) !void {
    const current = try readRawAlloc(gpa, io, environ);
    defer gpa.free(current);
    const updated = try removeCouncilText(gpa, current, name);
    defer gpa.free(updated);
    try replaceRaw(gpa, io, environ, updated);
}

/// Persist the complete [voice] section (replace-or-append): /voice setup
/// owns every key, so whole-section replacement keeps hand edits from
/// half-surviving a re-setup.
pub fn setVoice(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    enabled: bool,
    engine: []const u8,
    mode: []const u8,
    model: []const u8,
    stt_bin: []const u8,
) !void {
    const current = try readRawAlloc(gpa, io, environ);
    defer gpa.free(current);
    const without = try removeSectionText(gpa, current, "[voice]");
    defer gpa.free(without);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, without);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
    if (out.items.len > 0) try out.append(gpa, '\n');
    try out.print(gpa, "[voice]\nenabled = {}\n", .{enabled});
    try out.appendSlice(gpa, "engine = ");
    try appendTomlString(&out, gpa, engine);
    try out.appendSlice(gpa, "\nmode = ");
    try appendTomlString(&out, gpa, mode);
    if (model.len > 0) {
        try out.appendSlice(gpa, "\nmodel = ");
        try appendTomlString(&out, gpa, model);
    }
    try out.appendSlice(gpa, "\nstt_bin = ");
    try appendTomlString(&out, gpa, stt_bin);
    try out.append(gpa, '\n');

    var verify_arena = std.heap.ArenaAllocator.init(gpa);
    defer verify_arena.deinit();
    _ = try toml.parse(verify_arena.allocator(), out.items);
    try replaceRaw(gpa, io, environ, out.items);
}

/// Remove one `[section]` (header through the line before the next header).
/// Absent section returns the input unchanged.
fn removeSectionText(gpa: std.mem.Allocator, current: []const u8, header: []const u8) ![]u8 {
    var offset: usize = 0;
    while (offset < current.len) {
        const line_end = std.mem.indexOfScalarPos(u8, current, offset, '\n') orelse current.len;
        const next = if (line_end < current.len) line_end + 1 else line_end;
        const line = std.mem.trim(u8, current[offset..line_end], " \t\r");
        if (!std.mem.eql(u8, line, header)) {
            offset = next;
            continue;
        }
        var section_end = next;
        while (section_end < current.len) {
            const candidate_end = std.mem.indexOfScalarPos(u8, current, section_end, '\n') orelse current.len;
            const candidate = std.mem.trim(u8, current[section_end..candidate_end], " \t\r");
            if (candidate.len > 0 and candidate[0] == '[') break;
            section_end = if (candidate_end < current.len) candidate_end + 1 else candidate_end;
        }
        const out = try gpa.alloc(u8, current.len - (section_end - offset));
        @memcpy(out[0..offset], current[0..offset]);
        @memcpy(out[offset..], current[section_end..]);
        return out;
    }
    return gpa.dupe(u8, current);
}

fn setCouncilText(
    gpa: std.mem.Allocator,
    current: []const u8,
    name: []const u8,
    models: []const []const u8,
) ![]u8 {
    try validateToolName(name);
    if (models.len == 0) return error.CouncilMissingModels;
    for (models) |model| {
        if (std.mem.indexOfScalar(u8, model, '/') == null) return error.CouncilBadModel;
    }

    // Replace-or-append: strip any existing table with this name first.
    const without = removeCouncilText(gpa, current, name) catch |err| switch (err) {
        error.UnknownCouncil => try gpa.dupe(u8, current),
        else => return err,
    };
    defer gpa.free(without);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, without);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
    if (out.items.len > 0) try out.append(gpa, '\n');
    try out.appendSlice(gpa, "[[council]]\nname = ");
    try appendTomlString(&out, gpa, name);
    try out.appendSlice(gpa, "\nmodels = [");
    for (models, 0..) |model, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try appendTomlString(&out, gpa, model);
    }
    try out.appendSlice(gpa, "]\n");

    // Validate the generated document before it can replace the user's file.
    var verify_arena = std.heap.ArenaAllocator.init(gpa);
    defer verify_arena.deinit();
    _ = try toml.parse(verify_arena.allocator(), out.items);
    return out.toOwnedSlice(gpa);
}

fn removeCouncilText(gpa: std.mem.Allocator, current: []const u8, name: []const u8) ![]u8 {
    try validateToolName(name);
    var offset: usize = 0;
    while (offset < current.len) {
        const line_end = std.mem.indexOfScalarPos(u8, current, offset, '\n') orelse current.len;
        const next = if (line_end < current.len) line_end + 1 else line_end;
        const line = std.mem.trim(u8, current[offset..line_end], " \t\r");
        if (!std.mem.startsWith(u8, line, "[[council]]")) {
            offset = next;
            continue;
        }

        var table_end = next;
        while (table_end < current.len) {
            const candidate_end = std.mem.indexOfScalarPos(u8, current, table_end, '\n') orelse current.len;
            const candidate = std.mem.trim(u8, current[table_end..candidate_end], " \t\r");
            if (candidate.len > 0 and candidate[0] == '[') break;
            table_end = if (candidate_end < current.len) candidate_end + 1 else candidate_end;
        }

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const table = try toml.parse(arena_state.allocator(), current[offset..table_end]);
        if (table.councils.len == 1 and std.mem.eql(u8, table.councils[0].name, name)) {
            const out = try gpa.alloc(u8, current.len - (table_end - offset));
            @memcpy(out[0..offset], current[0..offset]);
            @memcpy(out[offset..], current[table_end..]);
            return out;
        }
        offset = table_end;
    }
    return error.UnknownCouncil;
}

fn addMcpServerText(
    gpa: std.mem.Allocator,
    current: []const u8,
    name: []const u8,
    cmd: []const []const u8,
) ![]u8 {
    try validateToolName(name);
    if (cmd.len == 0) return error.McpServerMissingCommand;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try toml.parse(arena_state.allocator(), current);
    for (doc.mcp_servers) |server| {
        if (std.mem.eql(u8, server.name, name)) return error.DuplicateMcpServer;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, current);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
    if (out.items.len > 0) try out.append(gpa, '\n');
    try out.appendSlice(gpa, "[[mcp]]\nname = ");
    try appendTomlString(&out, gpa, name);
    try out.appendSlice(gpa, "\ncmd = [");
    for (cmd, 0..) |arg, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try appendTomlString(&out, gpa, arg);
    }
    try out.appendSlice(gpa, "]\n");

    // Validate the generated document before it can replace the user's file.
    var verify_arena = std.heap.ArenaAllocator.init(gpa);
    defer verify_arena.deinit();
    _ = try toml.parse(verify_arena.allocator(), out.items);
    return out.toOwnedSlice(gpa);
}

fn removeMcpServerText(gpa: std.mem.Allocator, current: []const u8, name: []const u8) ![]u8 {
    try validateToolName(name);
    var offset: usize = 0;
    while (offset < current.len) {
        const line_end = std.mem.indexOfScalarPos(u8, current, offset, '\n') orelse current.len;
        const next = if (line_end < current.len) line_end + 1 else line_end;
        const line = std.mem.trim(u8, current[offset..line_end], " \t\r");
        if (!std.mem.startsWith(u8, line, "[[mcp]]")) {
            offset = next;
            continue;
        }

        var table_end = next;
        while (table_end < current.len) {
            const candidate_end = std.mem.indexOfScalarPos(u8, current, table_end, '\n') orelse current.len;
            const candidate = std.mem.trim(u8, current[table_end..candidate_end], " \t\r");
            if (candidate.len > 0 and candidate[0] == '[') break;
            table_end = if (candidate_end < current.len) candidate_end + 1 else candidate_end;
        }

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const table = try toml.parse(arena_state.allocator(), current[offset..table_end]);
        if (table.mcp_servers.len == 1 and std.mem.eql(u8, table.mcp_servers[0].name, name)) {
            const out = try gpa.alloc(u8, current.len - (table_end - offset));
            @memcpy(out[0..offset], current[0..offset]);
            @memcpy(out[offset..], current[table_end..]);
            return out;
        }
        offset = table_end;
    }
    return error.UnknownMcpServer;
}

fn appendTomlString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    try out.append(gpa, '"');
    for (value) |byte| switch (byte) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\x08' => try out.appendSlice(gpa, "\\b"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\x0c' => try out.appendSlice(gpa, "\\f"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        0...7, 11, 14...31, 127 => try out.print(gpa, "\\u00{X:0>2}", .{byte}),
        else => try out.append(gpa, byte),
    };
    try out.append(gpa, '"');
}

test "web ui stays off unless deliberately enabled" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();

    try std.testing.expect(!defaults().web_enabled);
    try std.testing.expect(!fromEnviron(&environ).web_enabled);
    try environ.put("MARLIN_WEB", "1");
    try std.testing.expect(fromEnviron(&environ).web_enabled);
    try environ.put("MARLIN_WEB", "0");
    try std.testing.expect(!fromEnviron(&environ).web_enabled);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try toml.parse(arena_state.allocator(), "[web]\nenabled = true\n");
    var cfg = defaults();
    applyDocument(&cfg, doc);
    try std.testing.expect(cfg.web_enabled);
}

pub fn networkPolicyConfigured(cfg: Config) bool {
    return hasCsvEntry(cfg.network_blocklists) or hasCsvEntry(cfg.network_deny);
}

fn hasCsvEntry(value: ?[]const u8) bool {
    const raw = value orelse return false;
    var entries = std.mem.splitScalar(u8, raw, ',');
    while (entries.next()) |entry| {
        if (std.mem.trim(u8, entry, " \t\r\n").len > 0) return true;
    }
    return false;
}

fn applyDocument(cfg: *Config, doc: toml.Document) void {
    if (doc.model_default) |value| cfg.model_default = value;
    if (doc.model_compaction) |value| cfg.model_compaction = value;
    if (doc.model_favorites) |value| cfg.model_favorites = value;
    if (doc.output_headroom_tokens) |value| cfg.output_headroom_tokens = value;
    if (doc.compaction_headroom_tokens) |value| cfg.compaction_headroom_tokens = value;
    if (doc.inline_tool_cap_bytes) |value| cfg.inline_tool_cap_bytes = value;
    if (doc.prune_protect_tokens) |value| cfg.prune_protect_tokens = value;
    if (doc.prune_min_reclaim_tokens) |value| cfg.prune_min_reclaim_tokens = value;
    if (doc.mutating_tools_policy) |value| cfg.mutating_tools_policy = value;
    if (doc.readonly_tools_policy) |value| cfg.readonly_tools_policy = value;
    if (doc.permissions_enabled) |value| cfg.permissions_enabled = value;
    if (doc.workspace_enabled) |value| cfg.workspace_enabled = value;
    if (doc.web_enabled) |value| cfg.web_enabled = value;
    if (doc.web_tailscale) |value| cfg.web_tailscale = value;
    if (doc.ui_tab_bar) |value| cfg.ui_tab_bar = value;
    if (doc.network_blocklists) |value| cfg.network_blocklists = value;
    if (doc.network_allow) |value| cfg.network_allow = value;
    if (doc.network_deny) |value| cfg.network_deny = value;
    if (doc.skill_directories) |value| cfg.skill_directories = value;
    if (doc.openrouter_sort) |value| cfg.openrouter_sort = value;
    cfg.exec_tools = doc.exec_tools;
    cfg.mcp_servers = doc.mcp_servers;
    cfg.councils = doc.councils;
    if (doc.voice_enabled) |v| cfg.voice_enabled = v;
    if (doc.voice_engine) |v| cfg.voice_engine = v;
    if (doc.voice_mode) |v| cfg.voice_mode = v;
    if (doc.voice_model) |v| cfg.voice_model = v;
    if (doc.voice_stt_bin) |v| cfg.voice_stt_bin = v;
    cfg.hooks = doc.hooks;
}

fn validate(gpa: std.mem.Allocator, cfg: Config) !void {
    if (cfg.model_default.len == 0) return error.EmptyDefaultModel;
    if (cfg.output_headroom_tokens == 0 or cfg.inline_tool_cap_bytes == 0) return error.InvalidContextLimit;
    if (cfg.prune_protect_tokens <= cfg.prune_min_reclaim_tokens) return error.InvalidPruneThresholds;
    if (cfg.openrouter_sort) |sort| {
        if (!std.mem.eql(u8, sort, "throughput") and
            !std.mem.eql(u8, sort, "latency") and
            !std.mem.eql(u8, sort, "price")) return error.InvalidOpenRouterSort;
    }
    for (cfg.exec_tools, 0..) |tool, i| {
        try validateToolName(tool.name);
        if (tool.cmd.len == 0) return error.ExecToolMissingCommand;
        for (cfg.exec_tools[0..i]) |previous| {
            if (std.mem.eql(u8, previous.name, tool.name)) return error.DuplicateExecTool;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, tool.schema, .{}) catch return error.InvalidExecToolSchema;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidExecToolSchema;
    }
    for (cfg.mcp_servers, 0..) |server, i| {
        try validateToolName(server.name);
        if (server.cmd.len == 0) return error.McpServerMissingCommand;
        for (cfg.mcp_servers[0..i]) |previous| {
            if (std.mem.eql(u8, previous.name, server.name)) return error.DuplicateMcpServer;
        }
    }
}

fn validateToolName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidExtensionName;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return error.InvalidExtensionName;
    }
}

test "defaults are sane" {
    const c = defaults();
    try std.testing.expectEqual(Effort.auto, c.effort_default);
    try std.testing.expectEqualStrings("throughput", c.openrouter_sort.?);
    try std.testing.expect(c.output_headroom_tokens > 0);
    try std.testing.expect(c.prune_protect_tokens > c.prune_min_reclaim_tokens);
    try std.testing.expect(c.permissions_enabled);
    try std.testing.expect(!c.workspace_enabled);
}

test "MARLIN_PERMISSIONS opts out of capability permissions" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();

    try std.testing.expect(fromEnviron(&environ).permissions_enabled);
    try environ.put("MARLIN_PERMISSIONS", "0");
    try std.testing.expect(!fromEnviron(&environ).permissions_enabled);
    try environ.put("MARLIN_PERMISSIONS", "1");
    try std.testing.expect(fromEnviron(&environ).permissions_enabled);
    try environ.put("MARLIN_PERMISSIONS", "true");
    try std.testing.expect(fromEnviron(&environ).permissions_enabled);
}

test "network policy environment bridge is opt-in" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();

    try std.testing.expect(fromEnviron(&environ).network_blocklists == null);
    try environ.put("MARLIN_NETWORK_BLOCKLISTS", "hagezi-tif-mini");
    try environ.put("MARLIN_NETWORK_ALLOW", "safe.example");
    try environ.put("MARLIN_NETWORK_DENY", "blocked.example");
    const cfg = fromEnviron(&environ);
    try std.testing.expectEqualStrings("hagezi-tif-mini", cfg.network_blocklists.?);
    try std.testing.expectEqualStrings("safe.example", cfg.network_allow.?);
    try std.testing.expectEqualStrings("blocked.example", cfg.network_deny.?);
}

test "missing config creates sparse network starter without replacing existing files" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-config-starter");
    defer temp.deinit();
    const root = temp.path;

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", root);

    var loaded = try load(gpa, io, &environ);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("hagezi-tif-mini", loaded.value.network_blocklists.?);
    try std.testing.expect(networkPolicyConfigured(loaded.value));

    const path = try std.fs.path.join(gpa, &.{ root, "marlin", "config.toml" });
    defer gpa.free(path);
    const created = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
    defer gpa.free(created);
    try std.testing.expectEqualStrings(starter_config, created);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "[network]\ndeny = \"preserved.example\"\n" });
    var reloaded = try load(gpa, io, &environ);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("preserved.example", reloaded.value.network_deny.?);
    try std.testing.expect(reloaded.value.network_blocklists == null);
}

test "load reads XDG config and environment wins" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-config");
    defer temp.deinit();
    const root = temp.path;
    const dir = try std.fs.path.join(gpa, &.{ root, "marlin" });
    defer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "config.toml" });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\[model]
        \\default = "local/test"
        \\[approval]
        \\default_mutating = "deny"
        \\[permissions]
        \\enabled = true
        \\[network]
        \\blocklists = "hagezi-tif-mini"
        \\allow = "safe.example"
        \\deny = "from-config.example"
        \\[[tools.exec]]
        \\name = "echo_json"
        \\cmd = ["sh", "-c", "cat"]
        \\schema = '{"type":"object"}'
    });

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", root);
    try environ.put("MARLIN_PERMISSIONS", "0");
    var loaded = try load(gpa, io, &environ);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("local/test", loaded.value.model_default);
    try std.testing.expectEqual(Policy.deny, loaded.value.mutating_tools_policy);
    try std.testing.expect(!loaded.value.permissions_enabled);
    try std.testing.expectEqualStrings("hagezi-tif-mini", loaded.value.network_blocklists.?);
    try std.testing.expectEqualStrings("safe.example", loaded.value.network_allow.?);
    try std.testing.expectEqualStrings("from-config.example", loaded.value.network_deny.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.exec_tools.len);
    try std.testing.expectEqualStrings("echo_json", loaded.value.exec_tools[0].name);
}

test "MCP config edits round-trip escaped commands and preserve other tables" {
    const gpa = std.testing.allocator;
    const original =
        \\[model]
        \\default = "local/test"
        \\[[mcp]]
        \\name = "keep"
        \\cmd = ["keep-server"]
        \\[network]
        \\deny = "blocked.example"
    ;
    const added = try addMcpServerText(gpa, original, "new-server", &.{ "server path", "--label=\"quoted\"", "line\nbreak" });
    defer gpa.free(added);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try toml.parse(arena_state.allocator(), added);
    try std.testing.expectEqual(@as(usize, 2), doc.mcp_servers.len);
    try std.testing.expectEqualStrings("server path", doc.mcp_servers[1].cmd[0]);
    try std.testing.expectEqualStrings("--label=\"quoted\"", doc.mcp_servers[1].cmd[1]);
    try std.testing.expectEqualStrings("line\nbreak", doc.mcp_servers[1].cmd[2]);
    try std.testing.expectError(error.DuplicateMcpServer, addMcpServerText(gpa, added, "new-server", &.{"nope"}));

    const removed = try removeMcpServerText(gpa, added, "keep");
    defer gpa.free(removed);
    var removed_arena = std.heap.ArenaAllocator.init(gpa);
    defer removed_arena.deinit();
    const after = try toml.parse(removed_arena.allocator(), removed);
    try std.testing.expectEqual(@as(usize, 1), after.mcp_servers.len);
    try std.testing.expectEqualStrings("new-server", after.mcp_servers[0].name);
    try std.testing.expectEqualStrings("blocked.example", after.network_deny.?);
    try std.testing.expectError(error.UnknownMcpServer, removeMcpServerText(gpa, removed, "missing"));
}

test "council config text edits: set replaces, remove deletes, garbage rejected" {
    const gpa = std.testing.allocator;
    const base = "[model]\ndefault = \"openrouter/x\"\n";

    const one = try setCouncilText(gpa, base, "core", &.{ "openrouter/a/b", "openrouter/c/d" });
    defer gpa.free(one);
    try std.testing.expect(std.mem.indexOf(u8, one, "[[council]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"openrouter/a/b\", \"openrouter/c/d\"") != null);

    // set again = replace, not duplicate
    const two = try setCouncilText(gpa, one, "core", &.{"openrouter/e/f"});
    defer gpa.free(two);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, two, "[[council]]"));
    try std.testing.expect(std.mem.indexOf(u8, two, "openrouter/e/f") != null);
    try std.testing.expect(std.mem.indexOf(u8, two, "openrouter/a/b") == null);

    const removed = try removeCouncilText(gpa, two, "core");
    defer gpa.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "[[council]]") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "default = ") != null);

    try std.testing.expectError(error.UnknownCouncil, removeCouncilText(gpa, base, "nope"));
    try std.testing.expectError(error.CouncilBadModel, setCouncilText(gpa, base, "bad", &.{"notamodel"}));
    try std.testing.expectError(error.CouncilMissingModels, setCouncilText(gpa, base, "bad", &.{}));
}

test "ui scalar edits: replace in place, insert into section, append section" {
    const gpa = std.testing.allocator;

    // No [ui] section: appended, other tables untouched byte-for-byte.
    const base = "[model]\ndefault = \"openrouter/x\"\n";
    const appended = try setScalarText(gpa, base, "ui", "tab_bar", "false");
    defer gpa.free(appended);
    try std.testing.expect(std.mem.startsWith(u8, appended, base));
    try std.testing.expect(std.mem.indexOf(u8, appended, "[ui]\ntab_bar = false\n") != null);

    // Existing key: replaced in place, once.
    const replaced = try setScalarText(gpa, appended, "ui", "tab_bar", "true");
    defer gpa.free(replaced);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replaced, "tab_bar"));
    try std.testing.expect(std.mem.indexOf(u8, replaced, "tab_bar = true") != null);

    // Existing section without the key, followed by another section: the key
    // lands inside [ui], not at the file end.
    const sandwich = "[ui]\n# chrome prefs\n[web]\nenabled = true\n";
    const inserted = try setScalarText(gpa, sandwich, "ui", "tab_bar", "false");
    defer gpa.free(inserted);
    const ui_at = std.mem.indexOf(u8, inserted, "[ui]").?;
    const key_at = std.mem.indexOf(u8, inserted, "tab_bar = false").?;
    const web_at = std.mem.indexOf(u8, inserted, "[web]").?;
    try std.testing.expect(ui_at < key_at and key_at < web_at);
    try std.testing.expect(std.mem.indexOf(u8, inserted, "# chrome prefs") != null);
}

test "voice section: parse, whole-section replace, removal helper" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try toml.parse(arena_state.allocator(),
        \\[voice]
        \\enabled = true
        \\engine = "whisper-turbo"
        \\mode = "toggle"
        \\model = "/data/ggml-large-v3-turbo.bin"
        \\stt_bin = "/opt/homebrew/bin/whisper-cli"
        \\
        \\[web]
        \\enabled = true
        \\
    );
    try std.testing.expect(doc.voice_enabled.?);
    try std.testing.expectEqualStrings("whisper-turbo", doc.voice_engine.?);
    try std.testing.expectEqualStrings("toggle", doc.voice_mode.?);

    const base = "[voice]\nenabled = false\nengine = \"x\"\n\n[web]\nenabled = true\n";
    const removed = try removeSectionText(gpa, base, "[voice]");
    defer gpa.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "[voice]") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "[web]") != null);

    const untouched = try removeSectionText(gpa, "[web]\nenabled = true\n", "[voice]");
    defer gpa.free(untouched);
    try std.testing.expectEqualStrings("[web]\nenabled = true\n", untouched);
}
