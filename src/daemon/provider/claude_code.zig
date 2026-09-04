//! Guest-session adapter: `claudecode/<model>` turns run through the OFFICIAL
//! `claude` binary in headless stream-json mode. Not a wire dialect.
//!
//! Why a guest and not a model: subscription (Pro/Max) inference is only
//! sanctioned through Anthropic's own binary — subscription OAuth outside
//! Claude Code is rejected (and accounts restricted). The binary is the
//! agent (its tools, permissions, context). Marlin is the multiplexer:
//! persist stream-json as blocks, attach/interrupt/reboot, park their
//! permission prompts on our approval bar. Frozen adapter — do not chase
//! parity with the native loop (docs/ARCHITECTURE.md, Native vs guest).
//!
//!   - Seatbelt, network screening, Marlin tools/MCP, task/plan, L0/L1/L2
//!     do NOT reach inside the subprocess.
//!   - The approval bar DOES: mux UX, not harness policy. ccAutoAllow is
//!     fail-closed to ask; it is not native read_file enforcement.
//!
//! This module owns argv, session identity, and event decode; the spawn
//! driver currently lives in loop.zig (a remaining wall leak).

const std = @import("std");
const Effort = @import("../../core/effort.zig").Effort;

/// Env override for the binary; also the test seam for fixture scripts.
pub const binary_env = "MARLIN_CLAUDE_CODE_BIN";
pub const default_binary = "claude";

pub fn binaryPath(environ: ?*const std.process.Environ.Map) []const u8 {
    const env = environ orelse return default_binary;
    const override = env.get(binary_env) orelse return default_binary;
    return if (override.len == 0) default_binary else override;
}

/// Claude Code's own permission posture for the delegated session.
pub const Permissions = enum { accept_edits, bypass, plan };

/// Wiring for the marlin permission bridge: instead of headless auto-deny,
/// Claude Code's permission prompts route over MCP to
/// `<marlin_exe> cc_approve --sid <sid>`, which asks the daemon.
pub const Bridge = struct { marlin_exe: []const u8, sid: u64 };

pub const ArgvOpts = struct {
    binary: []const u8,
    prompt: []const u8,
    /// Model string after "claudecode/"; "default" omits --model.
    model: []const u8,
    session_uuid: []const u8,
    /// First turn creates the Claude Code session; later turns resume it.
    fresh: bool,
    permissions: Permissions,
    /// Non-null routes permission prompts to marlin's approval gate instead
    /// of the headless default (auto-deny). Ignored under .bypass, which
    /// never prompts at all.
    bridge: ?Bridge = null,
    max_turns: u32,
    /// Marlin effort; `auto` omits `--effort`. Claude Code accepts
    /// low/medium/high/xhigh/max (`claude --help`).
    effort: Effort = .auto,
};

/// Map Marlin effort onto Claude `--effort`. `auto` means omit the flag.
/// `none`/`minimal` have no CC equivalent and collapse to `low`.
pub fn effortFlag(effort: Effort) ?[]const u8 {
    return switch (effort) {
        .auto => null,
        .none, .minimal, .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
        .max => "max",
    };
}

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
        .accept_edits => {
            if (opts.bridge) |bridge| {
                // Bridge mode: default permissions, with every prompt routed
                // to marlin over MCP. acceptEdits would silently skip the
                // bridge for edits, losing outside-workspace protection.
                const mcp_config = try std.json.Stringify.valueAlloc(arena, .{
                    .mcpServers = .{ .marlin = .{
                        .type = "stdio",
                        .command = bridge.marlin_exe,
                        .args = .{ "cc_approve", "--sid", try std.fmt.allocPrint(arena, "{d}", .{bridge.sid}) },
                    } },
                }, .{});
                try argv.appendSlice(arena, &.{
                    "--permission-mode",        "default",
                    "--permission-prompt-tool", "mcp__marlin__approve",
                    "--mcp-config",             mcp_config,
                });
            } else {
                try argv.appendSlice(arena, &.{ "--permission-mode", "acceptEdits" });
            }
        },
        .bypass => try argv.append(arena, "--dangerously-skip-permissions"),
        .plan => try argv.appendSlice(arena, &.{ "--permission-mode", "plan" }),
    }
    try argv.appendSlice(arena, &.{
        "--max-turns",
        try std.fmt.allocPrint(arena, "{d}", .{opts.max_turns}),
    });
    if (effortFlag(opts.effort)) |level| {
        try argv.appendSlice(arena, &.{ "--effort", level });
    }
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
        /// Joined `errors` array (e.g. "No conversation found with session
        /// ID: …"); empty on success.
        error_text: []const u8,
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
        var first_result: ?usize = null;
        var result_count: usize = 0;
        for (content) |item| {
            if (item != .object) continue;
            const bt = strField(item.object, "type") orelse continue;
            if (!std.mem.eql(u8, bt, "tool_result")) continue;
            try out.append(arena, .{ .tool_result = .{
                .tool_use_id = strField(item.object, "tool_use_id") orelse "",
                .text = try flattenContent(arena, item.object.get("content")),
                .is_error = boolField(item.object, "is_error") orelse false,
            } });
            if (first_result == null) first_result = out.items.len - 1;
            result_count += 1;
        }
        // The event-level toolUseResult describes ONE result; only adopt it
        // when the mapping is unambiguous, and never over an error text.
        if (result_count == 1) {
            const tr = &out.items[first_result.?].tool_result;
            if (!tr.is_error) {
                if (diffFromToolUseResult(arena, root)) |diff| tr.text = diff;
            }
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
        var error_text: std.ArrayList(u8) = .empty;
        if (root.get("errors")) |errs| if (errs == .array) {
            for (errs.array.items) |item| {
                if (item != .string) continue;
                if (error_text.items.len > 0) try error_text.appendSlice(arena, "; ");
                try error_text.appendSlice(arena, item.string);
            }
        };
        try out.append(arena, .{
            .result = .{
                .text = strField(root, "result") orelse "",
                // Trust either error signal: an auth failure (logged-out claude,
                // observed live) reports subtype "success" WITH is_error true.
                .is_error = !std.mem.eql(u8, subtype, "success") or
                    (boolField(root, "is_error") orelse false),
                .error_text = error_text.items,
                .tokens_in = tokens_in + cached,
                .tokens_out = tokens_out,
                .cached_tokens = cached,
            },
        });
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

/// Claude Code attaches rich tool metadata to the EVENT, not to the
/// model-facing content: for Edit/Write/MultiEdit its `structuredPatch`
/// carries the hunks CC's own UI renders as a diff, while `message.content`
/// only says "The file … has been updated successfully". Reconstruct that
/// change in the NATIVE file tools' dialect — "<verb> … in <path>" intro plus
/// bare @@ hunks, no ---/+++ headers — so every client treats guest edits
/// exactly like native ones (collapse-stop, authored-diff line cap, language
/// sniffing from the intro path). The field is undocumented CC internals, and
/// even its NAME differs by surface: `tool_use_result` on -p stream-json
/// stdout (what we read), `toolUseResult` in the on-disk session transcripts.
/// Accept both; ANY shape surprise returns null and the caller keeps the
/// flat text (fail soft, never error).
fn diffFromToolUseResult(arena: std.mem.Allocator, root: std.json.ObjectMap) ?[]const u8 {
    const tur = root.get("tool_use_result") orelse root.get("toolUseResult") orelse return null;
    if (tur != .object) return null;
    const path = strField(tur.object, "filePath") orelse return null;
    const patch = tur.object.get("structuredPatch") orelse return null;
    if (patch != .array) return null;
    if (patch.array.items.len > 0)
        return hunkDiff(arena, path, strField(tur.object, "originalFile"), patch.array.items);
    // Write creating a new file carries no hunks, only the content; render
    // the same all-additions preview the native write tool produces.
    const kind = strField(tur.object, "type") orelse return null;
    if (!std.mem.eql(u8, kind, "create")) return null;
    const content = strField(tur.object, "content") orelse return null;
    return creationDiff(arena, path, content);
}

fn hunkDiff(
    arena: std.mem.Allocator,
    path: []const u8,
    original: ?[]const u8,
    hunks: []const std.json.Value,
) ?[]const u8 {
    var acc: std.Io.Writer.Allocating = .init(arena);
    const w = &acc.writer;
    w.print("edited {d} hunk{s} in {s}\n", .{
        hunks.len,
        if (hunks.len == 1) "" else "s",
        path,
    }) catch return null;
    for (hunks) |hunk_value| {
        if (hunk_value != .object) return null;
        const hunk = hunk_value.object;
        const old_start = uintField(hunk, "oldStart") orelse return null;
        const old_lines = uintField(hunk, "oldLines") orelse return null;
        const new_start = uintField(hunk, "newStart") orelse return null;
        const new_lines = uintField(hunk, "newLines") orelse return null;
        const lines = hunk.get("lines") orelse return null;
        if (lines != .array) return null;
        w.print("@@ -{d},{d} +{d},{d} @@", .{ old_start, old_lines, new_start, new_lines }) catch return null;
        if (original) |orig| {
            const ctx = enclosingDeclaration(orig, old_start, leadingContextLines(lines.array.items));
            if (ctx.len > 0) w.print(" {s}", .{ctx[0..@min(ctx.len, 60)]}) catch return null;
        }
        w.print("\n", .{}) catch return null;
        for (lines.array.items) |line_value| {
            if (line_value != .string) return null;
            w.print("{s}\n", .{line_value.string}) catch return null;
        }
    }
    const text = acc.toOwnedSlice() catch return null;
    return std.mem.trimEnd(u8, text, "\n");
}

/// Hunk-header context, matching the native unifiedDiff (git's -p
/// heuristic): the nearest line at column 0 starting with a letter or
/// underscore, at or above the hunk's first CHANGED line — the hunk's own
/// leading context lines count as candidates, hence the offset.
fn enclosingDeclaration(original: []const u8, old_start: u64, leading_context: usize) []const u8 {
    if (old_start == 0) return "";
    const last_candidate = old_start - 1 + leading_context;
    var declaration: []const u8 = "";
    var line_no: u64 = 1;
    var it = std.mem.splitScalar(u8, original, '\n');
    while (it.next()) |line| : (line_no += 1) {
        if (line_no > last_candidate) break;
        if (line.len > 0 and (std.ascii.isAlphabetic(line[0]) or line[0] == '_')) declaration = line;
    }
    return declaration;
}

fn leadingContextLines(lines: []const std.json.Value) usize {
    var count: usize = 0;
    for (lines) |line_value| {
        if (line_value != .string or !std.mem.startsWith(u8, line_value.string, " ")) break;
        count += 1;
    }
    return count;
}

/// Same shape and cap as the native write tool's creation preview.
const creation_preview_lines = 40;

fn creationDiff(arena: std.mem.Allocator, path: []const u8, content: []const u8) ?[]const u8 {
    var total: usize = std.mem.count(u8, content, "\n");
    if (content.len > 0 and content[content.len - 1] != '\n') total += 1;
    if (total == 0) return null;
    var acc: std.Io.Writer.Allocating = .init(arena);
    const w = &acc.writer;
    w.print("created {s} ({d} bytes)\n@@ -0,0 +1,{d} @@\n", .{ path, content.len, total }) catch return null;
    var shown: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (shown == total or shown == creation_preview_lines) break;
        w.print("+{s}\n", .{line}) catch return null;
        shown += 1;
    }
    if (total > shown) {
        w.print("… {d} more new lines\n", .{total - shown}) catch return null;
    }
    const text = acc.toOwnedSlice() catch return null;
    return std.mem.trimEnd(u8, text, "\n");
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
