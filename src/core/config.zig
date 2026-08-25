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
    if (doc.network_blocklists) |value| cfg.network_blocklists = value;
    if (doc.network_allow) |value| cfg.network_allow = value;
    if (doc.network_deny) |value| cfg.network_deny = value;
    if (doc.skill_directories) |value| cfg.skill_directories = value;
    if (doc.openrouter_sort) |value| cfg.openrouter_sort = value;
    cfg.exec_tools = doc.exec_tools;
    cfg.mcp_servers = doc.mcp_servers;
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
