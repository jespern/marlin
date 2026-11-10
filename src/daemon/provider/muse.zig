//! Muse Code (Meta's terminal coding agent) as a guest. `muse serve` speaks
//! MSP, the Muse Session Protocol: JSON-RPC 2.0 over stdio, one message per
//! line, the same framing as Codex's app-server, so decoding is shared with
//! provider/codex.zig. What is Muse's own lives here: command ids, permission
//! profiles, effort names, and reading its items.
const std = @import("std");
const Io = std.Io;
const codex = @import("codex.zig");
const Effort = @import("../../core/effort.zig").Effort;

pub const binary_env = "MARLIN_MUSE_BIN";
pub const default_binary = "muse";

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
pub const boolField = codex.boolField;
pub const stringify = codex.stringify;

/// MSP refuses any command id that is not a UUIDv7: 48 bits of Unix
/// milliseconds, the version, then random bits.
pub fn commandId(io: Io, buf: *[36]u8) []const u8 {
    const ts = Io.Timestamp.now(io, .real);
    const millis: u64 = @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    return formatUuid7(millis, bytes, buf);
}

pub fn formatUuid7(millis: u64, random: [16]u8, buf: *[36]u8) []const u8 {
    var bytes = random;
    std.mem.writeInt(u48, bytes[0..6], @truncate(millis), .big);
    bytes[6] = 0x70 | (bytes[6] & 0x0f);
    bytes[8] = 0x80 | (bytes[8] & 0x3f);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    _ = std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
    return buf;
}

/// Muse's permission profiles, chosen from Marlin's session permissions:
/// read-only children stay read-only, full access drops the sandbox and every
/// prompt, and otherwise Muse asks and Marlin's picker answers. (Muse's own
/// default, `:auto-review`, has a model approve actions instead of the user.)
pub fn permissionProfile(full_tools: bool, auto_approve: bool) []const u8 {
    if (!full_tools) return ":read-only";
    return if (auto_approve) ":unrestricted" else ":ask-me";
}

/// Muse's effort names, or null to keep its own default. Meta's provider
/// does not accept `none`.
pub fn reasoningEffort(effort: Effort) ?[]const u8 {
    return switch (effort) {
        .auto => null,
        .none, .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
        .max => "max",
    };
}

/// The model to ask for: null keeps the user's configured Muse model.
pub fn modelId(model: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, model, "default")) null else model;
}

/// Marlin's names for Muse's tools, so they render and summarize like the
/// other agents' (Bash shows its command, Read its path); others keep theirs.
pub fn toolName(tool: []const u8) []const u8 {
    if (std.mem.eql(u8, tool, "bash")) return "Bash";
    if (std.mem.eql(u8, tool, "read_file")) return "Read";
    if (std.mem.eql(u8, tool, "write_file")) return "Write";
    if (std.mem.eql(u8, tool, "edit_file") or std.mem.eql(u8, tool, "apply_patch")) return "Edit";
    if (std.mem.eql(u8, tool, "web_search")) return "WebSearch";
    if (std.mem.eql(u8, tool, "web_fetch")) return "WebFetch";
    return tool;
}

/// A finished tool call's output as the user should read it. Shell calls
/// report a JSON envelope around the command's output; everything else is
/// already text.
pub fn toolOutput(arena: std.mem.Allocator, visible: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, visible, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return visible;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch return visible;
    const output = strField(parsed, "output") orelse return visible;
    if (strField(parsed, "terminal_status")) |status| if (!std.mem.eql(u8, status, "completed")) {
        return std.fmt.allocPrint(arena, "{s}\n[{s}]", .{ output, status }) catch output;
    };
    if (intField(parsed, "exit_code")) |code| if (code != 0) {
        return std.fmt.allocPrint(arena, "{s}\n[exit {d}]", .{ output, code }) catch output;
    };
    return output;
}

/// Item kinds that keep working after the turn that started them ends:
/// Muse runs subagents in background workflows and reports back in a turn of
/// its own when they finish. The workflow is what completes; its subagents'
/// items never leave `inProgress` (see subagentDone).
pub fn isBackgroundKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "workflow") or
        std.mem.eql(u8, kind, "backgroundTerminalCompletion");
}

/// A subagent item stays `inProgress` after its agent finishes; the update
/// that carries its duration or result is the end.
pub fn subagentDone(item: std.json.Value) bool {
    return field(item, "result") != null or intField(item, "durationMs") != null or itemFinished(item);
}

pub fn itemFinished(item: std.json.Value) bool {
    const status = strField(item, "status") orelse return false;
    return !std.mem.eql(u8, status, "inProgress");
}

/// `turn/completed` error kinds that mean the Meta login is missing or
/// expired.
pub fn isAuthError(err_value: std.json.Value) bool {
    const kind = strField(err_value, "kind") orelse return false;
    return std.mem.eql(u8, kind, "authRequired") or std.mem.eql(u8, kind, "authExpired");
}
