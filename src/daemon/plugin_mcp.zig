//! MCP servers shipped by Claude Code plugins: `.mcp.json` at the plugin
//! root and `mcpServers` in plugin.json (an inline map, a relative path to
//! a JSON file, or an array of either). Servers register as
//! `plugin_<plugin>_<server>`, so their tools get Claude Code's names
//! (`mcp__plugin_<plugin>_<server>__<tool>`) and skills that name them work.

const std = @import("std");
const Io = std.Io;
const config = @import("../core/config.zig");

/// One server as the plugin declares it, before variable expansion.
pub const Def = struct {
    name: []const u8,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    /// `KEY=value`
    env: []const []const u8 = &.{},
    url: ?[]const u8 = null,
    /// `Name: value`
    headers: []const []const u8 = &.{},
};

/// Every server the plugin at `plugin_dir` declares. Unsupported shapes
/// fail the whole plugin rather than install half of it.
/// `manifests` are plugin.json and the marketplace entry, in that order.
pub fn declared(arena: std.mem.Allocator, io: Io, plugin_dir: []const u8, manifests: []const std.json.Value) ![]Def {
    var out: std.ArrayList(Def) = .empty;
    const dot_mcp = try std.fs.path.join(arena, &.{ plugin_dir, ".mcp.json" });
    if (try readJson(arena, io, dot_mcp)) |doc| try collectFile(arena, &out, doc);
    for (manifests) |m| if (m == .object) if (m.object.get("mcpServers")) |value| {
        try collectManifestValue(arena, io, plugin_dir, &out, value);
    };
    // A later declaration of a name replaces an earlier one.
    var unique: std.ArrayList(Def) = .empty;
    for (out.items, 0..) |def, i| {
        const replaced = for (out.items[i + 1 ..]) |later| {
            if (std.mem.eql(u8, later.name, def.name)) break true;
        } else false;
        if (!replaced) try unique.append(arena, def);
    }
    return unique.items;
}

fn collectManifestValue(arena: std.mem.Allocator, io: Io, plugin_dir: []const u8, out: *std.ArrayList(Def), value: std.json.Value) !void {
    switch (value) {
        .object => try collectMap(arena, out, value),
        .string => |path| {
            if (!std.mem.endsWith(u8, path, ".json")) return error.UnsupportedMcpBundle;
            const full = try containedPath(arena, io, plugin_dir, path);
            const doc = (try readJson(arena, io, full)) orelse return error.MissingMcpConfig;
            try collectFile(arena, out, doc);
        },
        .array => |items| for (items.items) |item| try collectManifestValue(arena, io, plugin_dir, out, item),
        else => return error.InvalidMcpConfig,
    }
}

/// A `.mcp.json`-style document: `{"mcpServers": {...}}`, or the bare map.
fn collectFile(arena: std.mem.Allocator, out: *std.ArrayList(Def), doc: std.json.Value) !void {
    if (doc != .object) return error.InvalidMcpConfig;
    try collectMap(arena, out, doc.object.get("mcpServers") orelse doc);
}

fn collectMap(arena: std.mem.Allocator, out: *std.ArrayList(Def), map: std.json.Value) !void {
    if (map != .object) return error.InvalidMcpConfig;
    var it = map.object.iterator();
    while (it.next()) |entry| try out.append(arena, try parseServer(arena, entry.key_ptr.*, entry.value_ptr.*));
}

fn parseServer(arena: std.mem.Allocator, name: []const u8, value: std.json.Value) !Def {
    if (value != .object or name.len == 0 or name.len > 64) return error.InvalidMcpConfig;
    const obj = value.object;
    var def: Def = .{ .name = name };
    const kind = if (obj.get("type")) |t| (if (t == .string) t.string else return error.InvalidMcpConfig) else null;
    if (obj.get("url")) |url| {
        if (url != .string) return error.InvalidMcpConfig;
        const k = kind orelse return error.InvalidMcpConfig; // a url needs a type
        if (!std.mem.eql(u8, k, "http") and !std.mem.eql(u8, k, "streamable-http")) return error.UnsupportedMcpTransport;
        def.url = url.string;
        if (obj.get("headers")) |headers| def.headers = try pairs(arena, headers, ": ");
        if (obj.get("headersHelper") != null) return error.UnsupportedMcpTransport;
        return def;
    }
    if (kind) |k| if (!std.mem.eql(u8, k, "stdio")) return error.UnsupportedMcpTransport;
    const command = obj.get("command") orelse return error.InvalidMcpConfig;
    if (command != .string or command.string.len == 0) return error.InvalidMcpConfig;
    def.command = command.string;
    if (obj.get("args")) |args| {
        if (args != .array) return error.InvalidMcpConfig;
        var list: std.ArrayList([]const u8) = .empty;
        for (args.array.items) |arg| {
            if (arg != .string) return error.InvalidMcpConfig;
            try list.append(arena, arg.string);
        }
        def.args = list.items;
    }
    if (obj.get("env")) |env| def.env = try pairs(arena, env, "=");
    return def;
}

fn pairs(arena: std.mem.Allocator, value: std.json.Value, separator: []const u8) ![]const []const u8 {
    if (value != .object) return error.InvalidMcpConfig;
    var list: std.ArrayList([]const u8) = .empty;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidMcpConfig;
        try list.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ entry.key_ptr.*, separator, entry.value_ptr.string }));
    }
    return list.items;
}

fn readJson(arena: std.mem.Allocator, io: Io, path: []const u8) !?std.json.Value {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .allocate = .alloc_always });
}

fn containedPath(arena: std.mem.Allocator, io: Io, root: []const u8, relative: []const u8) ![]const u8 {
    const trimmed = if (std.mem.startsWith(u8, relative, "./")) relative[2..] else relative;
    if (trimmed.len == 0 or std.fs.path.isAbsolute(trimmed) or std.mem.indexOf(u8, trimmed, "..") != null) return error.UnsafePluginPath;
    const canonical_root = try Io.Dir.cwd().realPathFileAlloc(io, root, arena);
    const path = try Io.Dir.cwd().realPathFileAlloc(io, try std.fs.path.join(arena, &.{ root, trimmed }), arena);
    if (!std.mem.startsWith(u8, path, canonical_root) or path.len <= canonical_root.len or path[canonical_root.len] != '/') return error.UnsafePluginPath;
    return path;
}

/// `plugin_<plugin>_<server>` with anything outside [A-Za-z0-9_-] as `_`.
pub fn serverName(arena: std.mem.Allocator, plugin: []const u8, server: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(arena, "plugin_{s}_{s}", .{ plugin, server });
    for (name) |*c| if (!std.ascii.isAlphanumeric(c.*) and c.* != '_' and c.* != '-') {
        c.* = '_';
    };
    return name;
}

pub const Vars = struct {
    plugin_root: []const u8,
    plugin_data: []const u8,
    environ: *const std.process.Environ.Map,
};

/// Claude Code's substitutions: ${CLAUDE_PLUGIN_ROOT}, ${CLAUDE_PLUGIN_DATA},
/// ${VAR}, ${VAR:-default}. An unset variable without a default stays as
/// written, as in Claude Code.
pub fn expand(arena: std.mem.Allocator, text: []const u8, vars: Vars) ![]const u8 {
    if (std.mem.indexOf(u8, text, "${") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '$' and text[i + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, text, i + 2, '}')) |close| {
                const body = text[i + 2 .. close];
                const sep = std.mem.indexOf(u8, body, ":-");
                const key = if (sep) |s| body[0..s] else body;
                const fallback: ?[]const u8 = if (sep) |s| body[s + 2 ..] else null;
                const value: ?[]const u8 = if (std.mem.eql(u8, key, "CLAUDE_PLUGIN_ROOT"))
                    vars.plugin_root
                else if (std.mem.eql(u8, key, "CLAUDE_PLUGIN_DATA"))
                    vars.plugin_data
                else
                    vars.environ.get(key);
                if (value orelse fallback) |v| {
                    try out.appendSlice(arena, v);
                } else {
                    std.log.warn("plugin MCP config: ${{{s}}} is not set", .{key});
                    try out.appendSlice(arena, text[i .. close + 1]);
                }
                i = close + 1;
                continue;
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}

/// One installed plugin's servers as Marlin MCP config, variables expanded.
pub fn configsFor(
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    plugin: []const u8,
    plugin_dir: []const u8,
    data_dir: []const u8,
    manifests: []const std.json.Value,
) ![]config.McpServer {
    const vars: Vars = .{ .plugin_root = plugin_dir, .plugin_data = data_dir, .environ = environ };
    var out: std.ArrayList(config.McpServer) = .empty;
    for (try declared(arena, io, plugin_dir, manifests)) |def| {
        var server: config.McpServer = .{ .name = try serverName(arena, plugin, def.name), .mutating = true };
        if (def.url) |url| {
            server.url = try expand(arena, url, vars);
            var headers: std.ArrayList([]const u8) = .empty;
            for (def.headers) |line| try headers.append(arena, try expand(arena, line, vars));
            server.headers = headers.items;
        } else {
            var cmd: std.ArrayList([]const u8) = .empty;
            try cmd.append(arena, try expand(arena, def.command.?, vars));
            for (def.args) |arg| try cmd.append(arena, try expand(arena, arg, vars));
            server.cmd = cmd.items;
            var env: std.ArrayList([]const u8) = .empty;
            for (def.env) |line| try env.append(arena, try expand(arena, line, vars));
            server.env = env.items;
        }
        try out.append(arena, server);
    }
    return out.items;
}
