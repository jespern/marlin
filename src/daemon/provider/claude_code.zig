//! Claude Code delegation provider: `claudecode/<model>` sessions run their
//! turns through the OFFICIAL `claude` binary in headless stream-json mode.
//!
//! Why a subprocess and not a wire dialect: subscription (Pro/Max) inference
//! is only sanctioned through Anthropic's own binary — subscription OAuth
//! tokens are rejected (and accounts restricted) outside Claude Code. The
//! binary authenticates itself, runs its OWN agent loop with its OWN tools
//! and permission system, and streams structured events; marlin remains the
//! multiplexer and durable transcript. Consequences, stated honestly:
//!   - marlin's approval gate, seatbelt, network screening, and secret
//!     redaction do NOT reach inside the subprocess; Claude Code's own
//!     permission system governs (mapped from the session approval mode).
//!   - marlin's tools are not advertised; Claude Code uses its native set.
//!   - context/compaction is Claude Code's; marlin's L0/L1/L2 do not apply.
//!
//! This module owns the pure parts (argv, session identity, event decode);
//! the turn driver lives in loop.zig next to the persistence machinery.

const std = @import("std");

/// Env override for the binary; also the test seam for fixture scripts.
pub const binary_env = "MARLIN_CLAUDE_CODE_BIN";
pub const default_binary = "claude";

pub fn binaryPath(environ: ?*const std.process.Environ.Map) []const u8 {
    const env = environ orelse return default_binary;
    const override = env.get(binary_env) orelse return default_binary;
    return if (override.len == 0) default_binary else override;
}

/// Claude Code's own permission posture for the delegated session.
pub const Permissions = enum { accept_edits, bypass };

pub const ArgvOpts = struct {
    binary: []const u8,
    prompt: []const u8,
    /// Model string after "claudecode/"; "default" omits --model.
    model: []const u8,
    session_uuid: []const u8,
    /// First turn creates the Claude Code session; later turns resume it.
    fresh: bool,
    permissions: Permissions,
    max_turns: u32,
};

pub fn buildArgv(arena: std.mem.Allocator, opts: ArgvOpts) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        opts.binary,
        "-p",
        opts.prompt,
        "--output-format",
        "stream-json",
        "--verbose",
    });
    if (!std.mem.eql(u8, opts.model, "default")) {
        try argv.appendSlice(arena, &.{ "--model", opts.model });
    }
    if (opts.fresh) {
        try argv.appendSlice(arena, &.{ "--session-id", opts.session_uuid });
    } else {
        try argv.appendSlice(arena, &.{ "--resume", opts.session_uuid });
    }
    switch (opts.permissions) {
        .accept_edits => try argv.appendSlice(arena, &.{ "--permission-mode", "acceptEdits" }),
        .bypass => try argv.append(arena, "--dangerously-skip-permissions"),
    }
    try argv.appendSlice(arena, &.{
        "--max-turns",
        try std.fmt.allocPrint(arena, "{d}", .{opts.max_turns}),
    });
    return argv.items;
}

/// Deterministic v4-shaped UUID from the marlin session id: the Claude Code
/// session identity needs no storage or migration — it is re-derivable after
/// any daemon restart, and --resume/--session-id take it from here.
pub fn sessionUuid(buf: *[36]u8, sid: u64) []const u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("marlin-claude-code-session");
    hasher.update(std.mem.asBytes(&sid));
    hasher.final(&digest);
    var bytes: [16]u8 = digest[0..16].*;
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    const hex = "0123456789abcdef";
    var out: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[out] = '-';
            out += 1;
        }
        buf[out] = hex[b >> 4];
        buf[out + 1] = hex[b & 0xf];
        out += 2;
    }
    return buf[0..36];
}

// --------------------------------------------------------------- events --

pub const Event = union(enum) {
    /// system/init: the Claude Code session is live.
    init,
    /// Assistant text content block (progress commentary or the final prose).
    text: []const u8,
    /// Assistant tool_use content block.
    tool_use: struct {
        id: []const u8,
        name: []const u8,
        /// Re-stringified input object (arena-owned).
        input_json: []const u8,
    },
    /// Tool result echoed back to the model (flattened to text).
    tool_result: struct {
        tool_use_id: []const u8,
        text: []const u8,
        is_error: bool,
    },
    /// Terminal event: the turn's outcome and usage.
    result: struct {
        text: []const u8,
        is_error: bool,
        tokens_in: u64,
        tokens_out: u64,
        cached_tokens: u64,
    },
};

/// Decode one stream-json line into zero or more events (an assistant
/// message carries several content blocks). Event payloads are arena-owned.
/// Unknown/irrelevant lines decode to nothing — the stream format grows.
pub fn decodeLine(
    arena: std.mem.Allocator,
    line: []const u8,
    out: *std.ArrayList(Event),
) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch return error.BadLine;
    const root = switch (parsed) {
        .object => |o| o,
        else => return error.BadLine,
    };
    const t = strField(root, "type") orelse return error.BadLine;

    if (std.mem.eql(u8, t, "system")) {
        if (strField(root, "subtype")) |st| if (std.mem.eql(u8, st, "init"))
            try out.append(arena, .init);
        return;
    }
    if (std.mem.eql(u8, t, "assistant")) {
        const content = messageContent(root) orelse return;
        for (content) |item| {
            if (item != .object) continue;
            const bt = strField(item.object, "type") orelse continue;
            if (std.mem.eql(u8, bt, "text")) {
                const text = strField(item.object, "text") orelse continue;
                if (text.len > 0) try out.append(arena, .{ .text = text });
            } else if (std.mem.eql(u8, bt, "tool_use")) {
                const input = item.object.get("input") orelse std.json.Value{ .null = {} };
                try out.append(arena, .{ .tool_use = .{
                    .id = strField(item.object, "id") orelse "",
                    .name = strField(item.object, "name") orelse "",
                    .input_json = try stringifyValue(arena, input),
                } });
            }
        }
        return;
    }
    if (std.mem.eql(u8, t, "user")) {
        const content = messageContent(root) orelse return;
        for (content) |item| {
            if (item != .object) continue;
            const bt = strField(item.object, "type") orelse continue;
            if (!std.mem.eql(u8, bt, "tool_result")) continue;
            try out.append(arena, .{ .tool_result = .{
                .tool_use_id = strField(item.object, "tool_use_id") orelse "",
                .text = try flattenContent(arena, item.object.get("content")),
                .is_error = boolField(item.object, "is_error") orelse false,
            } });
        }
        return;
    }
    if (std.mem.eql(u8, t, "result")) {
        var tokens_in: u64 = 0;
        var tokens_out: u64 = 0;
        var cached: u64 = 0;
        if (root.get("usage")) |u| if (u == .object) {
            tokens_in = uintField(u.object, "input_tokens") orelse 0;
            tokens_out = uintField(u.object, "output_tokens") orelse 0;
            cached = uintField(u.object, "cache_read_input_tokens") orelse 0;
        };
        const subtype = strField(root, "subtype") orelse "";
        try out.append(arena, .{ .result = .{
            .text = strField(root, "result") orelse "",
            .is_error = !std.mem.eql(u8, subtype, "success"),
            .tokens_in = tokens_in + cached,
            .tokens_out = tokens_out,
            .cached_tokens = cached,
        } });
        return;
    }
    // stream_event (partial deltas, not requested), unknown types: ignore.
}

fn messageContent(root: std.json.ObjectMap) ?[]std.json.Value {
    const msg = root.get("message") orelse return null;
    if (msg != .object) return null;
    const content = msg.object.get("content") orelse return null;
    return if (content == .array) content.array.items else null;
}

/// tool_result content is a string or an array of text blocks; flatten.
fn flattenContent(arena: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const v = value orelse return "";
    switch (v) {
        .string => |s| return s,
        .array => |items| {
            var acc: std.ArrayList(u8) = .empty;
            for (items.items) |item| {
                if (item != .object) continue;
                const text = strField(item.object, "text") orelse continue;
                if (acc.items.len > 0) try acc.append(arena, '\n');
                try acc.appendSlice(arena, text);
            }
            return acc.items;
        },
        else => return "",
    }
}

fn stringifyValue(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (value == .null) return "{}";
    var aw: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.write(value);
    return aw.toOwnedSlice();
}

fn strField(map: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = map.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolField(map: std.json.ObjectMap, key: []const u8) ?bool {
    const v = map.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn uintField(map: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = map.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

// ---------------------------------------------------------------- tests --

test "session uuid is stable, v4-shaped, and sid-distinct" {
    var a: [36]u8 = undefined;
    var b: [36]u8 = undefined;
    var c: [36]u8 = undefined;
    const ua = sessionUuid(&a, 42);
    const ub = sessionUuid(&b, 42);
    const uc = sessionUuid(&c, 43);
    try std.testing.expectEqualStrings(ua, ub);
    try std.testing.expect(!std.mem.eql(u8, ua, uc));
    try std.testing.expectEqual(@as(usize, 36), ua.len);
    try std.testing.expectEqual(@as(u8, '4'), ua[14]);
    try std.testing.expect(ua[8] == '-' and ua[13] == '-' and ua[18] == '-' and ua[23] == '-');
}

test "argv: fresh vs resume, model passthrough, permission mapping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fresh = try buildArgv(arena, .{
        .binary = "claude",
        .prompt = "hi",
        .model = "fable-5",
        .session_uuid = "u-u-i-d",
        .fresh = true,
        .permissions = .accept_edits,
        .max_turns = 32,
    });
    try std.testing.expectEqualStrings("--session-id", fresh[8]);
    try std.testing.expectEqualStrings("--model", fresh[6]);
    try std.testing.expectEqualStrings("fable-5", fresh[7]);
    try std.testing.expectEqualStrings("--permission-mode", fresh[10]);
    try std.testing.expectEqualStrings("acceptEdits", fresh[11]);

    const resumed = try buildArgv(arena, .{
        .binary = "claude",
        .prompt = "hi",
        .model = "default",
        .session_uuid = "u-u-i-d",
        .fresh = false,
        .permissions = .bypass,
        .max_turns = 8,
    });
    // "default" model omits --model entirely.
    for (resumed) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--model"));
    try std.testing.expectEqualStrings("--resume", resumed[6]);
    try std.testing.expectEqualStrings("--dangerously-skip-permissions", resumed[8]);
}

test "decode: init, assistant blocks, tool_result shapes, result usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var events: std.ArrayList(Event) = .empty;

    try decodeLine(arena, "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s\"}", &events);
    try decodeLine(arena,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"working"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
    , &events);
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}],"is_error":false}]}}
    , &events);
    try decodeLine(arena,
        \\{"type":"result","subtype":"success","result":"done","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":90}}
    , &events);
    // Unknown types are ignored, not errors.
    try decodeLine(arena, "{\"type\":\"stream_event\",\"event\":{}}", &events);

    try std.testing.expectEqual(@as(usize, 5), events.items.len);
    try std.testing.expect(events.items[0] == .init);
    try std.testing.expectEqualStrings("working", events.items[1].text);
    try std.testing.expectEqualStrings("Bash", events.items[2].tool_use.name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", events.items[2].tool_use.input_json);
    try std.testing.expectEqualStrings("a\nb", events.items[3].tool_result.text);
    const result = events.items[4].result;
    try std.testing.expectEqualStrings("done", result.text);
    try std.testing.expectEqual(@as(u64, 100), result.tokens_in);
    try std.testing.expectEqual(@as(u64, 5), result.tokens_out);
    try std.testing.expectEqual(@as(u64, 90), result.cached_tokens);
    try std.testing.expect(!result.is_error);
}

test {
    std.testing.refAllDecls(@This());
}
