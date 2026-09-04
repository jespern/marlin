//! Focused TOML decoder for Marlin's configuration surface.
//!
//! Marlin deliberately accepts only the TOML shapes its runtime consumes:
//! scalar table keys, arrays of strings, `[[tools.exec]]`, and `[[mcp]]`.
//! Unknown tables/keys are ignored so a newer config remains usable by an
//! older binary, while malformed values in known fields fail startup.

const std = @import("std");

pub const Policy = enum { auto, ask, deny };

pub const ExecTool = struct {
    name: []const u8,
    cmd: []const []const u8,
    description: []const u8,
    schema: []const u8,
    mutating: bool,
    parallel_safe: bool,
    timeout_ms: u32,
};

pub const McpServer = struct {
    name: []const u8,
    cmd: []const []const u8,
    mutating: bool,
    readonly_tools: []const []const u8 = &.{},
    mutating_tools: []const []const u8 = &.{},
};

pub const Hooks = struct {
    on_session_done: ?[]const u8 = null,
    on_approval_needed: ?[]const u8 = null,
    on_error: ?[]const u8 = null,
    on_turn_done: ?[]const u8 = null,
};

/// Named review council (`[[council]]`): an ordered roster of registry-form
/// model ids, expanded by clients when the user invokes /review <name>.
pub const Council = struct {
    name: []const u8,
    models: []const []const u8,
};

/// OpenAI Chat Completions-compatible provider. The table name is the model
/// id prefix: `[providers.acme]` resolves `acme/<model>`.
pub const Provider = struct {
    name: []const u8,
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
};

pub const Document = struct {
    setup_completed: ?bool = null,
    model_default: ?[]const u8 = null,
    model_compaction: ?[]const u8 = null,
    model_favorites: ?[]const []const u8 = null,
    output_headroom_tokens: ?u32 = null,
    compaction_headroom_tokens: ?u32 = null,
    inline_tool_cap_bytes: ?u32 = null,
    prune_protect_tokens: ?u32 = null,
    prune_min_reclaim_tokens: ?u32 = null,
    mutating_tools_policy: ?Policy = null,
    readonly_tools_policy: ?Policy = null,
    permissions_enabled: ?bool = null,
    workspace_enabled: ?bool = null,
    web_enabled: ?bool = null,
    voice_enabled: ?bool = null,
    voice_engine: ?[]const u8 = null,
    voice_mode: ?[]const u8 = null,
    voice_model: ?[]const u8 = null,
    voice_stt_bin: ?[]const u8 = null,
    web_tailscale: ?bool = null,
    ui_tab_bar: ?bool = null,
    ui_bell: ?bool = null,
    ui_screensaver_after_ms: ?u64 = null,
    ui_screensaver_effect: ?[]const u8 = null,
    network_blocklists: ?[]const u8 = null,
    network_allow: ?[]const u8 = null,
    network_deny: ?[]const u8 = null,
    skill_directories: ?[]const []const u8 = null,
    openrouter_sort: ??[]const u8 = null,
    exec_tools: []const ExecTool = &.{},
    mcp_servers: []const McpServer = &.{},
    councils: []const Council = &.{},
    providers: []const Provider = &.{},
    hooks: Hooks = .{},
};

const Section = enum {
    unknown,
    setup,
    model,
    context,
    approval,
    permissions,
    workspace,
    web,
    ui,
    voice,
    network,
    hooks,
    skills,
    provider,
    exec_tool,
    mcp,
    council,
};

const PendingExec = struct {
    name: ?[]const u8 = null,
    cmd: ?[]const []const u8 = null,
    description: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    mutating: bool = true,
    parallel_safe: bool = false,
    timeout_ms: u32 = 10_000,
};

const PendingMcp = struct {
    name: ?[]const u8 = null,
    cmd: ?[]const []const u8 = null,
    mutating: bool = true,
    readonly_tools: []const []const u8 = &.{},
    mutating_tools: []const []const u8 = &.{},
};

const PendingCouncil = struct {
    name: ?[]const u8 = null,
    models: ?[]const []const u8 = null,
};

const PendingProvider = struct {
    name: []const u8,
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
};

pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Document {
    var doc = Document{};
    var exec_tools: std.ArrayList(ExecTool) = .empty;
    var mcp_servers: std.ArrayList(McpServer) = .empty;
    var councils: std.ArrayList(Council) = .empty;
    var providers: std.ArrayList(Provider) = .empty;
    var pending_exec: ?PendingExec = null;
    var pending_mcp: ?PendingMcp = null;
    var pending_council: ?PendingCouncil = null;
    var pending_provider: ?PendingProvider = null;
    var section: Section = .unknown;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const without_comment = stripComment(raw);
        const line = std.mem.trim(u8, without_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            try finishPending(arena, &exec_tools, &pending_exec, &mcp_servers, &pending_mcp, &councils, &pending_council, &providers, &pending_provider);
            if (std.mem.startsWith(u8, line, "[[") and std.mem.endsWith(u8, line, "]]")) {
                const name = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
                if (std.mem.eql(u8, name, "tools.exec")) {
                    section = .exec_tool;
                    pending_exec = .{};
                } else if (std.mem.eql(u8, name, "mcp")) {
                    section = .mcp;
                    pending_mcp = .{};
                } else if (std.mem.eql(u8, name, "council")) {
                    section = .council;
                    pending_council = .{};
                } else {
                    section = .unknown;
                }
                continue;
            }
            if (!std.mem.endsWith(u8, line, "]")) return error.InvalidToml;
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            const provider_prefix = "providers.";
            if (std.mem.startsWith(u8, name, provider_prefix) and name.len > provider_prefix.len) {
                section = .provider;
                pending_provider = .{ .name = try arena.dupe(u8, name[provider_prefix.len..]) };
            } else {
                section = sectionFor(name);
            }
            continue;
        }

        const equal = findUnquoted(line, '=') orelse return error.InvalidToml;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidToml;

        switch (section) {
            .setup => if (std.mem.eql(u8, key, "completed")) {
                doc.setup_completed = try boolean(value);
            },
            .model => {
                if (std.mem.eql(u8, key, "default")) doc.model_default = try string(arena, value);
                if (std.mem.eql(u8, key, "compaction")) doc.model_compaction = try optionalString(arena, value);
                if (std.mem.eql(u8, key, "favorites")) doc.model_favorites = try stringArray(arena, value);
            },
            .context => {
                if (std.mem.eql(u8, key, "output_headroom")) doc.output_headroom_tokens = try unsigned(u32, value);
                if (std.mem.eql(u8, key, "compaction_headroom")) doc.compaction_headroom_tokens = try unsigned(u32, value);
                if (std.mem.eql(u8, key, "inline_tool_cap")) doc.inline_tool_cap_bytes = try unsigned(u32, value);
                if (std.mem.eql(u8, key, "prune_protect_tokens")) doc.prune_protect_tokens = try unsigned(u32, value);
                if (std.mem.eql(u8, key, "prune_min_reclaim_tokens")) doc.prune_min_reclaim_tokens = try unsigned(u32, value);
            },
            .approval => {
                if (std.mem.eql(u8, key, "default_mutating")) doc.mutating_tools_policy = try policy(value);
                if (std.mem.eql(u8, key, "default_readonly")) doc.readonly_tools_policy = try policy(value);
            },
            .permissions => if (std.mem.eql(u8, key, "enabled")) {
                doc.permissions_enabled = try boolean(value);
            },
            .workspace => if (std.mem.eql(u8, key, "enabled")) {
                doc.workspace_enabled = try boolean(value);
            },
            .web => {
                if (std.mem.eql(u8, key, "enabled")) doc.web_enabled = try boolean(value);
                if (std.mem.eql(u8, key, "tailscale")) doc.web_tailscale = try boolean(value);
            },
            .ui => {
                if (std.mem.eql(u8, key, "tab_bar")) doc.ui_tab_bar = try boolean(value);
                if (std.mem.eql(u8, key, "bell")) doc.ui_bell = try boolean(value);
                if (std.mem.eql(u8, key, "screensaver_after")) doc.ui_screensaver_after_ms = try durationMs(value);
                if (std.mem.eql(u8, key, "screensaver_effect")) doc.ui_screensaver_effect = try string(arena, value);
            },
            .voice => {
                if (std.mem.eql(u8, key, "enabled")) doc.voice_enabled = try boolean(value);
                if (std.mem.eql(u8, key, "engine")) doc.voice_engine = try string(arena, value);
                if (std.mem.eql(u8, key, "mode")) doc.voice_mode = try string(arena, value);
                if (std.mem.eql(u8, key, "model")) doc.voice_model = try string(arena, value);
                if (std.mem.eql(u8, key, "stt_bin")) doc.voice_stt_bin = try string(arena, value);
            },
            .network => {
                if (std.mem.eql(u8, key, "blocklists")) doc.network_blocklists = try string(arena, value);
                if (std.mem.eql(u8, key, "allow")) doc.network_allow = try string(arena, value);
                if (std.mem.eql(u8, key, "deny")) doc.network_deny = try string(arena, value);
            },
            .skills => if (std.mem.eql(u8, key, "directories")) {
                doc.skill_directories = try stringArray(arena, value);
            },
            .provider => {
                const current = &(pending_provider orelse return error.InvalidToml);
                if (std.mem.eql(u8, key, "base_url")) current.base_url = try string(arena, value);
                if (std.mem.eql(u8, key, "api_key_env")) current.api_key_env = try string(arena, value);
                if (std.mem.eql(u8, current.name, "openrouter") and std.mem.eql(u8, key, "sort")) {
                    doc.openrouter_sort = try optionalString(arena, value);
                }
            },
            .hooks => {
                if (std.mem.eql(u8, key, "on_session_done")) doc.hooks.on_session_done = try optionalString(arena, value);
                if (std.mem.eql(u8, key, "on_approval_needed")) doc.hooks.on_approval_needed = try optionalString(arena, value);
                if (std.mem.eql(u8, key, "on_error")) doc.hooks.on_error = try optionalString(arena, value);
                if (std.mem.eql(u8, key, "on_turn_done")) doc.hooks.on_turn_done = try optionalString(arena, value);
            },
            .exec_tool => {
                const current = &(pending_exec orelse return error.InvalidToml);
                if (std.mem.eql(u8, key, "name")) current.name = try string(arena, value);
                if (std.mem.eql(u8, key, "cmd")) current.cmd = try command(arena, value);
                if (std.mem.eql(u8, key, "description")) current.description = try string(arena, value);
                if (std.mem.eql(u8, key, "schema")) current.schema = try string(arena, value);
                if (std.mem.eql(u8, key, "mutating")) current.mutating = try boolean(value);
                if (std.mem.eql(u8, key, "parallel_safe")) current.parallel_safe = try boolean(value);
                if (std.mem.eql(u8, key, "timeout_ms")) current.timeout_ms = try unsigned(u32, value);
            },
            .mcp => {
                const current = &(pending_mcp orelse return error.InvalidToml);
                if (std.mem.eql(u8, key, "name")) current.name = try string(arena, value);
                if (std.mem.eql(u8, key, "cmd")) current.cmd = try command(arena, value);
                if (std.mem.eql(u8, key, "mutating")) current.mutating = try boolean(value);
                if (std.mem.eql(u8, key, "readonly_tools")) current.readonly_tools = try stringArray(arena, value);
                if (std.mem.eql(u8, key, "mutating_tools")) current.mutating_tools = try stringArray(arena, value);
            },
            .council => {
                const current = &(pending_council orelse return error.InvalidToml);
                if (std.mem.eql(u8, key, "name")) current.name = try string(arena, value);
                if (std.mem.eql(u8, key, "models")) current.models = try stringArray(arena, value);
            },
            .unknown => {},
        }
    }
    try finishPending(arena, &exec_tools, &pending_exec, &mcp_servers, &pending_mcp, &councils, &pending_council, &providers, &pending_provider);
    doc.exec_tools = try exec_tools.toOwnedSlice(arena);
    doc.mcp_servers = try mcp_servers.toOwnedSlice(arena);
    doc.councils = try councils.toOwnedSlice(arena);
    doc.providers = try providers.toOwnedSlice(arena);
    return doc;
}

fn finishPending(
    arena: std.mem.Allocator,
    exec_tools: *std.ArrayList(ExecTool),
    pending_exec: *?PendingExec,
    mcp_servers: *std.ArrayList(McpServer),
    pending_mcp: *?PendingMcp,
    councils: *std.ArrayList(Council),
    pending_council: *?PendingCouncil,
    providers: *std.ArrayList(Provider),
    pending_provider: *?PendingProvider,
) !void {
    if (pending_provider.*) |pending| {
        try providers.append(arena, .{
            .name = pending.name,
            .base_url = pending.base_url,
            .api_key_env = pending.api_key_env,
        });
        pending_provider.* = null;
    }
    if (pending_council.*) |pending| {
        const name = pending.name orelse return error.CouncilMissingName;
        const models = pending.models orelse return error.CouncilMissingModels;
        if (models.len == 0) return error.CouncilMissingModels;
        try councils.append(arena, .{ .name = name, .models = models });
        pending_council.* = null;
    }
    if (pending_exec.*) |pending| {
        const name = pending.name orelse return error.ExecToolMissingName;
        const cmd = pending.cmd orelse return error.ExecToolMissingCommand;
        if (cmd.len == 0) return error.ExecToolMissingCommand;
        try exec_tools.append(arena, .{
            .name = name,
            .cmd = cmd,
            .description = pending.description orelse name,
            .schema = pending.schema orelse "{\"type\":\"object\",\"properties\":{}}",
            .mutating = pending.mutating,
            .parallel_safe = pending.parallel_safe,
            .timeout_ms = pending.timeout_ms,
        });
        pending_exec.* = null;
    }
    if (pending_mcp.*) |pending| {
        const name = pending.name orelse return error.McpServerMissingName;
        const cmd = pending.cmd orelse return error.McpServerMissingCommand;
        if (cmd.len == 0) return error.McpServerMissingCommand;
        try mcp_servers.append(arena, .{
            .name = name,
            .cmd = cmd,
            .mutating = pending.mutating,
            .readonly_tools = pending.readonly_tools,
            .mutating_tools = pending.mutating_tools,
        });
        pending_mcp.* = null;
    }
}

fn sectionFor(name: []const u8) Section {
    if (std.mem.eql(u8, name, "setup")) return .setup;
    const entries = .{
        .{ "model", Section.model },
        .{ "context", Section.context },
        .{ "approval", Section.approval },
        .{ "permissions", Section.permissions },
        .{ "workspace", Section.workspace },
        .{ "web", Section.web },
        .{ "voice", Section.voice },
        .{ "ui", Section.ui },
        .{ "network", Section.network },
        .{ "hooks", Section.hooks },
        .{ "skills", Section.skills },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return .unknown;
}

fn stripComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    var escaped = false;
    for (line, 0..) |byte, i| {
        if (quote) |q| {
            if (q == '"' and byte == '\\' and !escaped) {
                escaped = true;
                continue;
            }
            if (byte == q and !escaped) quote = null;
            escaped = false;
            continue;
        }
        if (byte == '"' or byte == '\'') quote = byte else if (byte == '#') return line[0..i];
    }
    return line;
}

fn findUnquoted(value: []const u8, needle: u8) ?usize {
    var quote: ?u8 = null;
    var escaped = false;
    for (value, 0..) |byte, i| {
        if (quote) |q| {
            if (q == '"' and byte == '\\' and !escaped) {
                escaped = true;
                continue;
            }
            if (byte == q and !escaped) quote = null;
            escaped = false;
        } else if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (byte == needle) {
            return i;
        }
    }
    return null;
}

fn string(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len < 2) return error.ExpectedString;
    if (value[0] == '"' and value[value.len - 1] == '"') {
        return std.json.parseFromSliceLeaky([]const u8, arena, value, .{});
    }
    if (value[0] == '\'' and value[value.len - 1] == '\'') return arena.dupe(u8, value[1 .. value.len - 1]);
    return error.ExpectedString;
}

fn optionalString(arena: std.mem.Allocator, value: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, value, "null")) return null;
    return try string(arena, value);
}

fn durationMs(value: []const u8) !u64 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.ExpectedDuration;
    return parseDurationMs(value[1 .. value.len - 1]) catch return error.ExpectedDuration;
}

pub fn parseDurationMs(raw: []const u8) !u64 {
    if (std.mem.eql(u8, raw, "off")) return 0;
    if (raw.len < 2) return error.InvalidDuration;
    const multiplier: u64 = switch (raw[raw.len - 1]) {
        's' => std.time.ms_per_s,
        'm' => std.time.ms_per_min,
        'h' => std.time.ms_per_hour,
        else => return error.InvalidDuration,
    };
    const amount = std.fmt.parseInt(u64, raw[0 .. raw.len - 1], 10) catch return error.InvalidDuration;
    if (amount == 0) return error.InvalidDuration;
    const duration = std.math.mul(u64, amount, multiplier) catch return error.InvalidDuration;
    if (duration > std.math.maxInt(i64)) return error.InvalidDuration;
    return duration;
}

fn command(arena: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    if (value.len > 0 and value[0] == '[') return stringArray(arena, value);
    const one = try arena.alloc([]const u8, 1);
    one[0] = try string(arena, value);
    return one;
}

fn stringArray(arena: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.ExpectedStringArray;
    var out: std.ArrayList([]const u8) = .empty;
    const body = value[1 .. value.len - 1];
    var start: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        const byte = if (at_end) ',' else body[i];
        if (!at_end and quote != null) {
            if (quote.? == '"' and byte == '\\' and !escaped) {
                escaped = true;
                continue;
            }
            if (byte == quote.? and !escaped) quote = null;
            escaped = false;
            continue;
        }
        if (!at_end and (byte == '"' or byte == '\'')) {
            quote = byte;
            continue;
        }
        if (byte != ',') continue;
        const item = std.mem.trim(u8, body[start..i], " \t\r");
        if (item.len > 0) try out.append(arena, try string(arena, item));
        start = i + 1;
    }
    if (quote != null) return error.UnclosedString;
    return out.toOwnedSlice(arena);
}

fn boolean(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.ExpectedBoolean;
}

fn unsigned(comptime T: type, value: []const u8) !T {
    return std.fmt.parseUnsigned(T, value, 10) catch error.ExpectedUnsigned;
}

fn policy(value: []const u8) !Policy {
    if (value.len < 2) return error.ExpectedPolicy;
    const parsed = if ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\''))
        value[1 .. value.len - 1]
    else
        return error.ExpectedPolicy;
    return std.meta.stringToEnum(Policy, parsed) orelse error.ExpectedPolicy;
}
