//! Antigravity CLI (`agy`, Google's agent CLI: Gemini 4 Neon and the other
//! models a Google sign-in offers) as a guest. `agy acp` speaks the Agent
//! Client Protocol (agentclientprotocol.com): JSON-RPC 2.0 over stdio, one
//! message per line, the same framing as Codex's app-server, so decoding is
//! shared with provider/codex.zig. What is ACP's or agy's own lives here:
//! session config options, tool calls as Marlin tools, diffs, permission
//! options, usage.
const std = @import("std");
const codex = @import("codex.zig");
const Effort = @import("../../core/effort.zig").Effort;
const files = @import("../tools/files.zig");

pub const binary_env = "MARLIN_AGY_BIN";
pub const default_binary = "agy";
/// ACP's protocol version this client speaks.
pub const protocol_version = 1;
/// kv: the model values agy's last session offered, one per line, for the
/// model picker (agy keeps no list on disk, and asking it starts a session).
pub const models_key = "agy_models";
pub const prefix = "agy/";

pub fn binaryPath(environ: ?*const std.process.Environ.Map) []const u8 {
    const env = environ orelse return default_binary;
    const override = env.get(binary_env) orelse return default_binary;
    return if (override.len == 0) default_binary else override;
}

pub const Inbound = codex.Inbound;
pub const Response = codex.Response;
pub const decodeLine = codex.decodeLine;
pub const field = codex.field;
pub const strField = codex.strField;
pub const intField = codex.intField;
pub const stringify = codex.stringify;

/// Marlin's own tools (ask_user, show_image, the session tools) through
/// `marlin cc_approve`, as an ACP stdio MCP server. agy asks for permission
/// over ACP, so the bridge leaves out Claude Code's `approve`.
pub const Bridge = struct { marlin_exe: []const u8, sid: u64 };

pub const EnvVar = struct { name: []const u8, value: []const u8 };
pub const McpServer = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8,
    env: []const EnvVar,
};

/// What the bridge needs to find the daemon, passed explicitly: ACP leaves
/// it to the agent whether an MCP server inherits its environment.
const bridge_env = [_][]const u8{ "HOME", "MARLIN_SOCKET", "XDG_RUNTIME_DIR" };

pub fn mcpServers(arena: std.mem.Allocator, bridge: ?Bridge, environ: ?*const std.process.Environ.Map) ![]const McpServer {
    const target = bridge orelse return &.{};
    var env: std.ArrayList(EnvVar) = .empty;
    if (environ) |map| for (bridge_env) |name| {
        if (map.get(name)) |value| try env.append(arena, .{ .name = name, .value = value });
    };
    const servers = try arena.alloc(McpServer, 1);
    servers[0] = .{
        .name = "marlin",
        .command = target.marlin_exe,
        .args = try arena.dupe([]const u8, &.{ "cc_approve", "--sid", try std.fmt.allocPrint(arena, "{d}", .{target.sid}), "--no-approve" }),
        .env = env.items,
    };
    return servers;
}

/// The model to select: null keeps the one agy's own settings choose.
pub fn modelValue(model: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, model, "default")) null else model;
}

/// agy's thinking levels, or null to keep the model's default.
pub fn thoughtLevel(effort: Effort) ?[]const u8 {
    return switch (effort) {
        .auto => null,
        .none, .minimal, .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh, .max => "xhigh",
    };
}

/// The select config option with this id (`model`, `thought_level`, …) in
/// a session's `configOptions`.
pub fn configOption(options: ?std.json.Value, id: []const u8) ?std.json.Value {
    const list = options orelse return null;
    if (list != .array) return null;
    for (list.array.items) |option| {
        if (std.mem.eql(u8, strField(option, "id") orelse "", id)) return option;
    }
    return null;
}

pub fn currentValue(options: ?std.json.Value, id: []const u8) ?[]const u8 {
    return strField(configOption(options, id) orelse return null, "currentValue");
}

/// Whether a select option offers this value. Thinking levels differ by
/// model, so one is set only where the model has it.
pub fn offers(options: ?std.json.Value, id: []const u8, value: []const u8) bool {
    const option = configOption(options, id) orelse return false;
    const values = field(option, "options") orelse return false;
    if (values != .array) return false;
    for (values.array.items) |entry| {
        if (std.mem.eql(u8, strField(entry, "value") orelse "", value)) return true;
    }
    return false;
}

/// The values of the `model` option, one per line (for `models_key`).
pub fn modelList(arena: std.mem.Allocator, options: ?std.json.Value) ![]const u8 {
    const option = configOption(options, "model") orelse return "";
    const values = field(option, "options") orelse return "";
    if (values != .array) return "";
    var out: std.ArrayList(u8) = .empty;
    for (values.array.items) |entry| {
        const value = strField(entry, "value") orelse continue;
        if (value.len == 0 or std.mem.indexOfScalar(u8, value, '\n') != null) continue;
        if (out.items.len > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, value);
    }
    return out.items;
}

/// `agy/<value>` for every saved model value.
pub fn appendModelIds(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), saved: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, saved, '\n');
    while (it.next()) |value| {
        const id = try std.fmt.allocPrint(arena, prefix ++ "{s}", .{value});
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, id)) break;
        } else try list.append(arena, id);
    }
}

/// The option answering a permission request: allow or reject this once,
/// falling back to the remembered kind when that is all the agent offers.
/// Null when it offers neither, which answers as cancelled.
pub fn permissionOption(options: ?std.json.Value, approve: bool) ?[]const u8 {
    const list = options orelse return null;
    if (list != .array) return null;
    const wanted: []const []const u8 = if (approve) &.{ "allow_once", "allow_always" } else &.{ "reject_once", "reject_always" };
    for (wanted) |kind| {
        for (list.array.items) |option| {
            if (std.mem.eql(u8, strField(option, "kind") orelse "", kind)) return strField(option, "optionId");
        }
    }
    return null;
}

/// Marlin's name for an ACP tool call, from its kind, so it renders and
/// summarizes like the other agents' (Bash shows its command, Read its
/// path); anything else keeps the agent's own name.
pub fn toolName(update: std.json.Value) []const u8 {
    const kind = strField(update, "kind") orelse "other";
    const names = [_]struct { []const u8, []const u8 }{
        .{ "execute", "Bash" },   .{ "read", "Read" },   .{ "edit", "Edit" },
        .{ "delete", "Delete" },  .{ "move", "Move" },   .{ "search", "Search" },
        .{ "fetch", "WebFetch" }, .{ "think", "Think" },
    };
    for (names) |entry| if (std.mem.eql(u8, kind, entry[0])) return entry[1];
    if (strField(update, "name")) |name| if (name.len > 0) return name;
    return strField(update, "title") orelse "tool";
}

/// A string in the tool's raw input under any of `keys`, ignoring case
/// (agy writes `CommandLine` and `Path`).
fn inputString(input: ?std.json.Value, keys: []const []const u8) ?[]const u8 {
    const value = input orelse return null;
    if (value != .object) return null;
    for (keys) |key| {
        var it = value.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) return entry.value_ptr.string;
        }
    }
    return null;
}

/// A tool call's arguments as Marlin persists them: the keys its transcript
/// and approval bar read (`command`, `path`, `url`, `query`, `pattern`) next
/// to the agent's own input, kept whole.
pub fn toolArgs(arena: std.mem.Allocator, update: std.json.Value) ![]const u8 {
    const kind = strField(update, "kind") orelse "other";
    const input = field(update, "rawInput");
    var args: std.json.ObjectMap = .empty;
    const title = strField(update, "title");
    if (std.mem.eql(u8, kind, "execute")) {
        if (inputString(input, &.{ "command", "CommandLine", "cmd" }) orelse title) |command|
            try args.put(arena, "command", .{ .string = command });
    }
    const location_path: ?[]const u8 = if (field(update, "locations")) |locations| blk: {
        if (locations != .array or locations.array.items.len == 0) break :blk null;
        break :blk strField(locations.array.items[0], "path");
    } else null;
    if (inputString(input, &.{ "path", "file_path", "AbsolutePath", "TargetFile" }) orelse location_path) |path|
        try args.put(arena, "path", .{ .string = path });
    inline for (.{ "url", "query", "pattern" }) |key| {
        if (inputString(input, &.{key})) |value| try args.put(arena, key, .{ .string = value });
    }
    if (title) |value| try args.put(arena, "title", .{ .string = value });
    if (input) |value| try args.put(arena, "input", value);
    return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = args }, .{});
}

/// A finished tool call's output as the user should read it: its text, and
/// each diff as a unified diff the transcript colours.
pub fn toolBody(arena: std.mem.Allocator, update: std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (field(update, "content")) |content| if (content == .array) for (content.array.items) |item| {
        const kind = strField(item, "type") orelse continue;
        if (std.mem.eql(u8, kind, "content")) {
            const inner = field(item, "content") orelse continue;
            const text = strField(inner, "text") orelse continue;
            if (out.items.len > 0 and !std.mem.endsWith(u8, out.items, "\n")) try out.append(arena, '\n');
            try out.appendSlice(arena, text);
        } else if (std.mem.eql(u8, kind, "diff")) {
            if (out.items.len > 0 and !std.mem.endsWith(u8, out.items, "\n")) try out.append(arena, '\n');
            try appendDiff(arena, &out, strField(item, "path") orelse "file", strField(item, "oldText"), strField(item, "newText") orelse "");
        }
    };
    if (out.items.len > 0) return out.items;
    const raw = field(update, "rawOutput") orelse return "";
    if (raw == .string) return raw.string;
    if (strField(raw, "output")) |output| return output;
    if (raw == .object and raw.object.count() == 0) return "";
    return stringify(arena, raw);
}

/// ACP diffs carry the text before and after; Marlin shows the change as a
/// unified diff. A new file (no old text) is all additions.
pub fn appendDiff(arena: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, old_text: ?[]const u8, new_text: []const u8) !void {
    const old = old_text orelse {
        try out.print(arena, "--- /dev/null\n+++ {s}\n", .{path});
        const count = if (new_text.len == 0) 0 else std.mem.count(u8, new_text, "\n") + @intFromBool(!std.mem.endsWith(u8, new_text, "\n"));
        try out.print(arena, "@@ -0,0 +{d},{d} @@\n", .{ @as(usize, @intFromBool(count > 0)), count });
        var it = std.mem.splitScalar(u8, new_text, '\n');
        while (it.next()) |line| {
            if (line.len == 0 and it.index == null) break;
            try out.print(arena, "+{s}\n", .{line});
        }
        return;
    };
    if (std.mem.eql(u8, old, new_text)) {
        try out.print(arena, "--- {s}\n+++ {s}\n", .{ path, path });
        return;
    }
    var prefix_len: usize = 0;
    while (prefix_len < old.len and prefix_len < new_text.len and old[prefix_len] == new_text[prefix_len]) prefix_len += 1;
    var suffix_len: usize = 0;
    while (suffix_len < old.len - prefix_len and suffix_len < new_text.len - prefix_len and
        old[old.len - 1 - suffix_len] == new_text[new_text.len - 1 - suffix_len]) suffix_len += 1;
    const hunk = files.unifiedDiff(arena, old, prefix_len, old.len - prefix_len - suffix_len, new_text[prefix_len .. new_text.len - suffix_len]) catch |err| switch (err) {
        error.DiffTooBig => {
            try out.print(arena, "edited {s} (change too large for an inline diff)\n", .{path});
            return;
        },
        else => return err,
    };
    try out.print(arena, "--- {s}\n+++ {s}\n", .{ path, path });
    try out.appendSlice(arena, hunk);
    if (!std.mem.endsWith(u8, out.items, "\n")) try out.append(arena, '\n');
}

/// The token counts of a session/prompt result (agy reports them; ACP
/// leaves usage to the agent). Input counts cached reads and writes too, as
/// the other guests' totals do.
pub const Usage = struct { input: u64 = 0, output: u64 = 0 };

pub fn promptUsage(result: ?std.json.Value) Usage {
    const usage = field(result orelse return .{}, "usage") orelse return .{};
    const count = struct {
        fn get(value: std.json.Value, key: []const u8) u64 {
            return @intCast(@max(0, intField(value, key) orelse 0));
        }
    }.get;
    return .{
        .input = count(usage, "inputTokens") + count(usage, "cachedReadTokens") + count(usage, "cachedWriteTokens"),
        .output = count(usage, "outputTokens"),
    };
}

/// A stop reason worth telling the user; null for an ordinary end.
pub fn stopNote(stop_reason: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, stop_reason, "max_tokens")) return "Antigravity stopped: the model reached its output token limit";
    if (std.mem.eql(u8, stop_reason, "max_turn_requests")) return "Antigravity stopped: the turn reached its limit of model requests";
    if (std.mem.eql(u8, stop_reason, "refusal")) return "Antigravity stopped: the model refused to continue";
    return null;
}
