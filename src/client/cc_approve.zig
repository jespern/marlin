//! marlin cc_approve — internal stdio MCP server the daemon wires into
//! delegated Claude Code sessions as their --permission-prompt-tool
//! (`claude -p … --mcp-config {…cc_approve --sid N}`).
//!
//! Headless `claude -p` cannot show permission prompts; without this bridge
//! anything not allowlisted is auto-denied. Each prompt arrives here as an
//! MCP tools/call ({tool_name, input}), is forwarded to the daemon as ONE
//! cc_approval message on a fresh connection, and blocks until the daemon
//! answers: instantly when policy auto-allows (workspace-scoped calls),
//! otherwise after a human decides on the parked approval bar. The reply is
//! the wire format Claude Code expects back from a permission prompt tool:
//! {"behavior":"allow","updatedInput":…} or {"behavior":"deny","message":…}.
//!
//! Failure mode is always deny (Claude Code's own semantics for a broken
//! prompt tool), never a hang or a silent allow.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");

/// One verdict, with the daemon's optional policy message (copied into a
/// fixed buffer: the wire arena dies before the reply is composed).
pub const Decision = struct {
    answer: proto.ApprovalAnswer,
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn init(answer: proto.ApprovalAnswer, text: ?[]const u8) Decision {
        var self = Decision{ .answer = answer };
        if (text) |value| {
            self.message_len = @min(value.len, self.message_buf.len);
            @memcpy(self.message_buf[0..self.message_len], value[0..self.message_len]);
        }
        return self;
    }

    fn message(self: *const Decision) ?[]const u8 {
        return if (self.message_len == 0) null else self.message_buf[0..self.message_len];
    }
};

/// Answers one forwarded prompt; injectable so tests need no daemon.
pub const Decider = struct {
    ctx: ?*anyopaque = null,
    decide: *const fn (ctx: ?*anyopaque, tool_name: []const u8, input_json: []const u8) Decision,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    var sid: ?u64 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--sid") and i + 1 < args.len) {
            i += 1;
            sid = std.fmt.parseInt(u64, args[i], 10) catch null;
        }
    }
    const session_id = sid orelse {
        std.log.err("usage: marlin cc_approve --sid <sid> (internal)", .{});
        return 2;
    };

    var daemon_decider = DaemonDecider{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .self_exe = self_exe,
        .sid = session_id,
    };
    const decider = Decider{ .ctx = &daemon_decider, .decide = DaemonDecider.decide };

    var in_buf: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &out_buf);

    while (true) {
        const line = proto.readLineAlloc(gpa, &reader.interface) catch break;
        defer gpa.free(line);
        const reply = handleLine(gpa, line, decider) orelse continue;
        defer gpa.free(reply);
        writer.interface.writeAll(reply) catch break;
        writer.interface.writeAll("\n") catch break;
        writer.interface.flush() catch break;
    }
    return 0;
}

/// Forwards to the daemon over a fresh socket connection per prompt: the
/// connection doubles as the pending request's lifetime (the daemon drops a
/// parked prompt when its bridge client disappears).
const DaemonDecider = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    sid: u64,

    fn decide(ctx: ?*anyopaque, tool_name: []const u8, input_json: []const u8) Decision {
        const self: *DaemonDecider = @ptrCast(@alignCast(ctx.?));
        return self.ask(tool_name, input_json) catch Decision.init(.denied, null);
    }

    fn ask(self: *DaemonDecider, tool_name: []const u8, input_json: []const u8) !Decision {
        const conn = try attach.connect(self.gpa, self.io, self.environ, self.self_exe);
        defer conn.deinit();
        try conn.send(.{ .cc_approval = .{
            .sid = self.sid,
            .tool = tool_name,
            .args_json = input_json,
        } });
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const result = try conn.recvUntil(arena_state.allocator(), .cc_approval_result);
        return Decision.init(result.decision, result.message);
    }
};

/// Handle one JSON-RPC line; null means no reply (notifications, garbage).
/// Returned reply is gpa-owned, newline not included.
pub fn handleLine(gpa: std.mem.Allocator, line: []const u8, decider: Decider) ?[]u8 {
    const Rpc = struct {
        id: ?std.json.Value = null,
        method: []const u8 = "",
        params: ?std.json.Value = null,
    };
    var parsed = std.json.parseFromSlice(Rpc, gpa, line, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const rpc = parsed.value;
    // Notifications (no id) never get replies, whatever the method.
    const id = rpc.id orelse return null;

    if (std.mem.eql(u8, rpc.method, "initialize")) {
        const requested: []const u8 = blk: {
            const params = rpc.params orelse break :blk default_protocol_version;
            if (params != .object) break :blk default_protocol_version;
            const v = params.object.get("protocolVersion") orelse break :blk default_protocol_version;
            break :blk if (v == .string) v.string else default_protocol_version;
        };
        const result = std.fmt.allocPrint(gpa,
            \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"marlin-approval-bridge","version":"{s}"}}}}
        , .{ requested, build_options.version }) catch return null;
        defer gpa.free(result);
        return rpcResult(gpa, id, result);
    }
    if (std.mem.eql(u8, rpc.method, "ping")) return rpcResult(gpa, id, "{}");
    if (std.mem.eql(u8, rpc.method, "tools/list")) {
        return rpcResult(gpa, id,
            \\{"tools":[{"name":"approve","description":"Forward one Claude Code permission prompt to the marlin approval gate.","inputSchema":{"type":"object","properties":{"tool_name":{"type":"string"},"input":{"type":"object"}},"required":["tool_name","input"]}}]}
        );
    }
    if (std.mem.eql(u8, rpc.method, "tools/call")) {
        return handleToolCall(gpa, id, rpc.params, decider);
    }
    return rpcError(gpa, id, -32601, "method not found");
}

const default_protocol_version = "2025-06-18";

fn handleToolCall(gpa: std.mem.Allocator, id: std.json.Value, params: ?std.json.Value, decider: Decider) ?[]u8 {
    const p = params orelse return rpcError(gpa, id, -32602, "missing params");
    if (p != .object) return rpcError(gpa, id, -32602, "params must be an object");
    const name = p.object.get("name") orelse return rpcError(gpa, id, -32602, "missing tool name");
    if (name != .string or !std.mem.eql(u8, name.string, "approve"))
        return rpcError(gpa, id, -32602, "unknown tool");

    // Anything malformed decides as a deny, not a protocol error: Claude
    // Code treats tool errors as prompt failures and the turn dies with it.
    var tool_name: []const u8 = "";
    var input_json: []const u8 = "{}";
    var input_owned: ?[]u8 = null;
    defer if (input_owned) |owned| gpa.free(owned);
    if (p.object.get("arguments")) |arguments| {
        if (arguments == .object) {
            if (arguments.object.get("tool_name")) |tn| {
                if (tn == .string) tool_name = tn.string;
            }
            if (arguments.object.get("input")) |input| {
                input_owned = std.json.Stringify.valueAlloc(gpa, input, .{}) catch null;
                if (input_owned) |owned| input_json = owned;
            }
        }
    }
    const decision: Decision = if (tool_name.len == 0)
        Decision.init(.denied, null)
    else
        decider.decide(decider.ctx, tool_name, input_json);

    const payload = switch (decision.answer) {
        .granted => std.fmt.allocPrint(gpa,
            \\{{"behavior":"allow","updatedInput":{s}}}
        , .{input_json}) catch return null,
        .denied => blk: {
            const text = decision.message() orelse "denied via marlin approval";
            const escaped_msg = std.json.Stringify.valueAlloc(gpa, text, .{}) catch return null;
            defer gpa.free(escaped_msg);
            break :blk std.fmt.allocPrint(gpa,
                \\{{"behavior":"deny","message":{s}}}
            , .{escaped_msg}) catch return null;
        },
    };
    defer gpa.free(payload);

    // The permission payload travels as the text of one MCP content block.
    const escaped = std.json.Stringify.valueAlloc(gpa, payload, .{}) catch return null;
    defer gpa.free(escaped);
    const result = std.fmt.allocPrint(gpa,
        \\{{"content":[{{"type":"text","text":{s}}}]}}
    , .{escaped}) catch return null;
    defer gpa.free(result);
    return rpcResult(gpa, id, result);
}

fn rpcResult(gpa: std.mem.Allocator, id: std.json.Value, result_json: []const u8) ?[]u8 {
    const id_json = std.json.Stringify.valueAlloc(gpa, id, .{}) catch return null;
    defer gpa.free(id_json);
    return std.fmt.allocPrint(gpa,
        \\{{"jsonrpc":"2.0","id":{s},"result":{s}}}
    , .{ id_json, result_json }) catch null;
}

fn rpcError(gpa: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) ?[]u8 {
    const id_json = std.json.Stringify.valueAlloc(gpa, id, .{}) catch return null;
    defer gpa.free(id_json);
    return std.fmt.allocPrint(gpa,
        \\{{"jsonrpc":"2.0","id":{s},"error":{{"code":{d},"message":"{s}"}}}}
    , .{ id_json, code, message }) catch null;
}

// ---------------------------------------------------------------- tests --
