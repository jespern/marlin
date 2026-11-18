//! The attention log: each moment a session needs its user (an approval or
//! a question waiting, a turn finished or failed) and the moment a waiting
//! approval or question stopped waiting. The daemon records them where it
//! also pings the phone (daemon.needsUser, clearPendingApproval) and serves
//! them to assistants outside Marlin through the MCP server's `attention`
//! tool (client/mcp_server.zig). Readers catch up by sequence number.
//!
//! This module also holds the tools only an outside caller gets: the log,
//! and answering an approval or a question. Sessions keep their own way of
//! asking the user; they never answer each other's prompts.
const std = @import("std");

pub const Kind = enum { approval, question, done, failed, resolved };

pub const attention_name = "attention";
pub const approve_name = "approve";
pub const answer_name = "answer";
pub const names = [_][]const u8{ attention_name, approve_name, answer_name };

/// Moments one `attention` call returns by default and at most.
pub const default_limit: u32 = 100;
pub const max_limit: u32 = 500;
/// Longest final reply a `done` moment carries.
pub const max_reply_bytes: usize = 2000;

pub fn isTool(name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

pub const Spec = @import("tools/sessions.zig").Spec;

pub const specs = [_]Spec{
    .{
        .name = attention_name,
        .description = "What needs the user in Marlin, oldest first: an approval or a question waiting (with the id to answer it), a turn finished or failed (with its last reply), or a waiting item resolved (answered anywhere, or gone). Each moment has a growing `seq`; pass the last one you saw as `after` to get only newer ones, or `last` for the newest few. `latest` is the newest seq.",
        .schema =
        \\{"type":"object","properties":{"after":{"type":"integer","minimum":0,"description":"Only moments after this seq (default 0: the whole kept log)"},"last":{"type":"integer","minimum":1,"maximum":500,"description":"Instead of after: the newest this many"},"limit":{"type":"integer","minimum":1,"maximum":500,"description":"At most this many (default 100)"}}}
        ,
        .mutating = false,
    },
    .{
        .name = approve_name,
        .description = "Allow or deny an approval a Marlin session is waiting on, as the user would from Marlin's approval bar. Use the handle and approval_id from `attention`. Fails if that approval is no longer waiting.",
        .schema =
        \\{"type":"object","properties":{"handle":{"type":"string","description":"The session's handle"},"approval_id":{"type":"string"},"decision":{"type":"string","enum":["allow","deny"]}},"required":["handle","approval_id","decision"]}
        ,
        .mutating = true,
    },
    .{
        .name = answer_name,
        .description = "Answer a question a Marlin session is waiting on, as the user would from Marlin's picker: one of its options, or your own words. Use the handle and question_id from `attention`. Fails if that question is no longer waiting.",
        .schema =
        \\{"type":"object","properties":{"handle":{"type":"string","description":"The session's handle"},"question_id":{"type":"string"},"answer":{"type":"string","minLength":1,"maxLength":8192}},"required":["handle","question_id","answer"]}
        ,
        .mutating = true,
    },
};

pub const AttentionArgs = struct { after: ?u64 = null, last: ?u32 = null, limit: ?u32 = null };
pub const ApproveArgs = struct { handle: []const u8, approval_id: []const u8, decision: []const u8 };
pub const AnswerArgs = struct { handle: []const u8, question_id: []const u8, answer: []const u8 };

/// What a session's pending line (the approval_request or question_request
/// it replays to clients) is waiting for.
pub const Pending = struct {
    kind: Kind,
    id: []const u8,
    /// The moment's detail, JSON: the id, plus the tool and its arguments or
    /// the question and its options.
    detail: []const u8,
};

pub fn pending(arena: std.mem.Allocator, line: []const u8) ?Pending {
    const Line = struct {
        approval_request: ?struct { approval_id: []const u8, tool: []const u8, args_json: []const u8 } = null,
        question_request: ?struct { question_id: []const u8, question: []const u8, options: []const []const u8 } = null,
    };
    const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.approval_request) |a| {
        const args = std.json.parseFromSliceLeaky(std.json.Value, arena, a.args_json, .{}) catch std.json.Value{ .string = a.args_json };
        const detail = std.json.Stringify.valueAlloc(arena, .{ .approval_id = a.approval_id, .tool = a.tool, .args = args }, .{}) catch return null;
        return .{ .kind = .approval, .id = a.approval_id, .detail = detail };
    }
    if (parsed.question_request) |q| {
        const detail = std.json.Stringify.valueAlloc(arena, .{ .question_id = q.question_id, .question = q.question, .options = q.options }, .{}) catch return null;
        return .{ .kind = .question, .id = q.question_id, .detail = detail };
    }
    return null;
}

/// A `resolved` moment's detail: which approval or question stopped waiting.
pub fn resolvedDetail(arena: std.mem.Allocator, was: Pending) ![]const u8 {
    return switch (was.kind) {
        .approval => std.json.Stringify.valueAlloc(arena, .{ .approval_id = was.id }, .{}),
        else => std.json.Stringify.valueAlloc(arena, .{ .question_id = was.id }, .{}),
    };
}

/// A finished turn's detail: its last reply (clipped), and the error that
/// ended it, if any.
pub fn finishedDetail(arena: std.mem.Allocator, reply: ?[]const u8, err: ?[]const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{ .reply = if (reply) |r| clip(r, max_reply_bytes) else null, .@"error" = err }, .{ .emit_null_optional_fields = false });
}

pub const Event = struct {
    seq: u64,
    at_ms: i64,
    handle: []const u8,
    title: []const u8,
    kind: []const u8,
    /// The stored detail JSON, embedded as is.
    detail: []const u8,
};

/// The `attention` tool's answer: `{"latest":N,"events":[…]}`, each event its
/// fields followed by its detail's.
pub fn eventsJson(arena: std.mem.Allocator, latest: u64, events: []const Event) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("latest");
    try json.write(latest);
    try json.objectField("events");
    try json.beginArray();
    for (events) |event| {
        try json.beginObject();
        try json.objectField("seq");
        try json.write(event.seq);
        try json.objectField("at_ms");
        try json.write(event.at_ms);
        try json.objectField("handle");
        try json.write(event.handle);
        try json.objectField("title");
        try json.write(event.title);
        try json.objectField("kind");
        try json.write(event.kind);
        const detail = std.json.parseFromSliceLeaky(std.json.Value, arena, event.detail, .{}) catch std.json.Value{ .object = .empty };
        if (detail == .object) {
            var it = detail.object.iterator();
            while (it.next()) |field| {
                try json.objectField(field.key_ptr.*);
                try json.write(field.value_ptr.*);
            }
        }
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    return out.written();
}

/// At most `max` bytes, cut on a UTF-8 boundary.
fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}
