//! Marlin as an MCP server, for the user's assistants outside Marlin (Robin
//! first): `POST /mcp` on the web companion (web.zig), Streamable HTTP,
//! bearer tokens with scopes (mobile/mcp_tokens.zig).
//!
//! Tools, each needing a token scope:
//!   read  sessions, read_session, wait_for_session, attention
//!   act   message_session, approve, answer
//! and one resource, `marlin://attention`: the newest moments a session
//! needed its user (daemon/attention.zig). A 2026-07-28 client hears about
//! new ones through `subscriptions/listen`, then calls `attention` with the
//! last seq it saw; after downtime the same call catches it up.
//!
//! Protocol: 2026-07-28 (stateless: server/discover, per-request `_meta`,
//! subscriptions/listen) and, for older clients, 2025-11-25 and the two
//! before it, served without sessions: `initialize` answers, nothing is
//! remembered, and there is no GET stream (405), so those clients get the
//! tools and resource but no subscriptions.
//!
//! This module is the protocol only: one request in, one response out. The
//! HTTP layer checks the token first and runs the listen stream; the daemon
//! runs the tools (daemon.runAgentTool, as for sessions' own agents).

const std = @import("std");
const build_options = @import("build_options");
const sessions_tool = @import("../daemon/tools/sessions.zig");
const attention = @import("../daemon/attention.zig");

pub const path = "/mcp";
pub const modern = "2026-07-28";
pub const legacy = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26" };
pub const supported = [_][]const u8{ modern, legacy[0] };
pub const resource_uri = "marlin://attention";
/// Moments the resource shows.
pub const resource_moments: u32 = 50;
pub const max_body_bytes = 1024 * 1024;

const meta_version = "io.modelcontextprotocol/protocolVersion";
const meta_capabilities = "io.modelcontextprotocol/clientCapabilities";
const meta_server_info = "io.modelcontextprotocol/serverInfo";
const meta_subscription = "io.modelcontextprotocol/subscriptionId";

pub const code_parse = -32700;
pub const code_invalid_request = -32600;
pub const code_method_not_found = -32601;
pub const code_invalid_params = -32602;
pub const code_header_mismatch = -32020;
pub const code_unsupported_version = -32022;
/// 2025-11-25 resources: no such resource.
pub const code_resource_not_found = -32002;

/// `{}` in JSON: an empty anonymous struct would serialize as `[]`.
const Empty = struct {};

const instructions = "Marlin runs coding-agent sessions for its user. `attention` says what needs the user (approvals and questions waiting, turns finished or failed); subscribe to " ++ resource_uri ++ " to hear when it changes. `sessions`, `read_session` and `wait_for_session` look into sessions; `message_session`, `approve` and `answer` act in them.";

pub const Scope = enum { read, act };

const Tool = struct { spec: sessions_tool.Spec, scope: Scope };

/// Every tool, in the order tools/list shows them.
pub const tools = [_]Tool{
    .{ .spec = sessions_tool.specs[0], .scope = .read }, // sessions
    .{ .spec = sessions_tool.specs[1], .scope = .read }, // read_session
    .{ .spec = sessions_tool.specs[3], .scope = .read }, // wait_for_session
    .{ .spec = attention.specs[0], .scope = .read }, // attention
    .{ .spec = sessions_tool.specs[2], .scope = .act }, // message_session
    .{ .spec = attention.specs[1], .scope = .act }, // approve
    .{ .spec = attention.specs[2], .scope = .act }, // answer
};

pub fn findTool(name: []const u8) ?Tool {
    for (tools) |tool| if (std.mem.eql(u8, tool.spec.name, name)) return tool;
    return null;
}

/// What the request's token may do (its scopes) and who holds it.
pub const Grant = struct {
    name: []const u8,
    read: bool,
    act: bool,

    pub fn allows(self: Grant, scope: Scope) bool {
        return switch (scope) {
            .read => self.read,
            .act => self.act,
        };
    }
};

pub const ToolResult = struct { text: []const u8, ok: bool };

/// Runs a tool in the daemon for `caller`. Null when the daemon cannot be
/// reached. Injected so the protocol runs in tests without one.
pub const Backend = struct {
    ctx: ?*anyopaque,
    call: *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, caller: []const u8, name: []const u8, args_json: []const u8) ?ToolResult,
};

pub const Request = struct {
    body: []const u8,
    /// MCP-Protocol-Version, Mcp-Method and Mcp-Name headers, if sent.
    version_header: ?[]const u8 = null,
    method_header: ?[]const u8 = null,
    name_header: ?[]const u8 = null,
    grant: Grant,
};

pub const Response = struct {
    status: u16 = 200,
    /// JSON; empty for 202.
    body: []const u8 = "",
    /// Set with 403 for a token that lacks the scope: the scope needed.
    insufficient_scope: ?Scope = null,
    /// subscriptions/listen accepted: the HTTP layer answers with an event
    /// stream that starts with `body` (the acknowledgement) and then sends
    /// `updated` each time the attention log grows, until either side
    /// closes. `end` is the closing result.
    listen: ?Listen = null,
};

pub const Listen = struct {
    /// notifications/resources/updated for the attention resource, or null
    /// when the client asked for nothing this server sends: then `end`
    /// follows the acknowledgement at once.
    updated: ?[]const u8,
    end: []const u8,
};

pub fn handle(arena: std.mem.Allocator, req: Request, backend: Backend) !Response {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch
        return errorResponse(arena, 400, .null, code_parse, "parse error", null);
    if (parsed != .object) return errorResponse(arena, 400, .null, code_invalid_request, "send one JSON-RPC message, not a batch", null);
    const msg = parsed.object;
    const method_value = msg.get("method") orelse {
        // A JSON-RPC response from an older client (to a request this server
        // never sends): accepted and ignored.
        if (msg.get("result") != null or msg.get("error") != null) return .{ .status = 202 };
        return errorResponse(arena, 400, msg.get("id") orelse .null, code_invalid_request, "missing method", null);
    };
    if (method_value != .string) return errorResponse(arena, 400, msg.get("id") orelse .null, code_invalid_request, "method must be a string", null);
    const method = method_value.string;
    // Notifications (notifications/initialized, cancelled, …) need no answer.
    const id = msg.get("id") orelse return .{ .status = 202 };
    const params: std.json.ObjectMap = if (msg.get("params")) |p| switch (p) {
        .object => |o| o,
        else => return errorResponse(arena, 400, id, code_invalid_params, "params must be an object", null),
    } else .empty;

    const meta: ?std.json.ObjectMap = if (params.get("_meta")) |m| (if (m == .object) m.object else null) else null;
    const meta_ver: ?[]const u8 = if (meta) |m| (if (m.get(meta_version)) |v| (if (v == .string) v.string else null) else null) else null;
    const is_modern = meta_ver != null or (req.version_header != null and std.mem.eql(u8, req.version_header.?, modern));

    if (!is_modern) return handleLegacy(arena, req, id, method, params, backend);

    // 2026-07-28: every request says its version and capabilities in _meta,
    // and the headers repeat what the body says.
    const version = meta_ver orelse return errorResponse(arena, 400, id, code_invalid_params, "missing _meta " ++ meta_version, null);
    if (meta.?.get(meta_capabilities) == null) return errorResponse(arena, 400, id, code_invalid_params, "missing _meta " ++ meta_capabilities, null);
    if (!std.mem.eql(u8, version, modern)) return unsupportedVersion(arena, id, version);
    if (!headerMatches(req.version_header, version)) return errorResponse(arena, 400, id, code_header_mismatch, "MCP-Protocol-Version does not match _meta", null);
    if (!headerMatches(req.method_header, method)) return errorResponse(arena, 400, id, code_header_mismatch, "Mcp-Method does not match the body", null);
    if (std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "resources/read")) {
        const key = if (std.mem.eql(u8, method, "tools/call")) "name" else "uri";
        const named = if (params.get(key)) |v| (if (v == .string) v.string else null) else null;
        if (named == null) return errorResponse(arena, 400, id, code_invalid_params, if (key[0] == 'n') "missing params.name" else "missing params.uri", null);
        if (!headerMatches(req.name_header, named.?)) return errorResponse(arena, 400, id, code_header_mismatch, "Mcp-Name does not match the body", null);
    }

    if (std.mem.eql(u8, method, "server/discover")) {
        return result(arena, id, true, .{
            .supportedVersions = &supported,
            .capabilities = .{ .tools = Empty{}, .resources = .{ .subscribe = true } },
            .instructions = instructions,
            ._meta = .{ .@"io.modelcontextprotocol/serverInfo" = serverInfo() },
        });
    }
    if (std.mem.eql(u8, method, "subscriptions/listen")) return listen(arena, req, id, params);
    return (try common(arena, req, id, method, params, backend, true)) orelse
        errorResponse(arena, 404, id, code_method_not_found, "method not found", null);
}

fn handleLegacy(arena: std.mem.Allocator, req: Request, id: std.json.Value, method: []const u8, params: std.json.ObjectMap, backend: Backend) !Response {
    if (req.version_header) |v| if (!isLegacy(v))
        return unsupportedVersion(arena, id, v);
    if (std.mem.eql(u8, method, "initialize")) {
        const asked: []const u8 = if (params.get("protocolVersion")) |v| (if (v == .string) v.string else "") else "";
        return result(arena, id, false, .{
            // The asked version when served, else the newest older one.
            .protocolVersion = if (isLegacy(asked)) asked else legacy[0],
            .capabilities = .{ .tools = Empty{}, .resources = Empty{} },
            .serverInfo = serverInfo(),
            .instructions = instructions,
        });
    }
    if (std.mem.eql(u8, method, "ping")) return result(arena, id, false, Empty{});
    return (try common(arena, req, id, method, params, backend, false)) orelse
        errorResponse(arena, 404, id, code_method_not_found, "method not found", null);
}

/// Methods both eras share; null for an unknown method.
fn common(arena: std.mem.Allocator, req: Request, id: std.json.Value, method: []const u8, params: std.json.ObjectMap, backend: Backend, is_modern: bool) !?Response {
    if (std.mem.eql(u8, method, "tools/list")) return try listTools(arena, req.grant, id, is_modern);
    if (std.mem.eql(u8, method, "tools/call")) return try callTool(arena, req.grant, id, params, backend, is_modern);
    if (std.mem.eql(u8, method, "resources/list")) {
        const Resource = struct { uri: []const u8, name: []const u8, title: []const u8, description: []const u8, mimeType: []const u8 };
        const listed: []const Resource = if (req.grant.read) &.{.{
            .uri = resource_uri,
            .name = "attention",
            .title = "What needs the user",
            .description = "The newest moments Marlin sessions needed their user, as the attention tool returns them.",
            .mimeType = "application/json",
        }} else &.{};
        return try result(arena, id, is_modern, .{ .resources = listed });
    }
    if (std.mem.eql(u8, method, "resources/templates/list"))
        return try result(arena, id, is_modern, .{ .resourceTemplates = &[_]struct {}{} });
    if (std.mem.eql(u8, method, "resources/read")) return try readResource(arena, req.grant, id, params, backend, is_modern);
    return null;
}

fn listTools(arena: std.mem.Allocator, grant: Grant, id: std.json.Value, is_modern: bool) !Response {
    const Annotations = struct { readOnlyHint: bool, destructiveHint: bool, openWorldHint: bool };
    const Listed = struct { name: []const u8, description: []const u8, inputSchema: std.json.Value, annotations: Annotations };
    var listed: std.ArrayList(Listed) = .empty;
    // A token sees only the tools it may call.
    for (tools) |tool| if (grant.allows(tool.scope)) try listed.append(arena, .{
        .name = tool.spec.name,
        .description = tool.spec.description,
        .inputSchema = try std.json.parseFromSliceLeaky(std.json.Value, arena, tool.spec.schema, .{}),
        .annotations = .{ .readOnlyHint = !tool.spec.mutating, .destructiveHint = false, .openWorldHint = false },
    });
    return result(arena, id, is_modern, .{ .tools = listed.items });
}

fn callTool(arena: std.mem.Allocator, grant: Grant, id: std.json.Value, params: std.json.ObjectMap, backend: Backend, is_modern: bool) !Response {
    const name = if (params.get("name")) |v| (if (v == .string) v.string else "") else "";
    const tool = findTool(name) orelse return errorResponse(arena, 200, id, code_invalid_params, "unknown tool", null);
    if (!grant.allows(tool.scope)) return scopeError(arena, id, tool.scope);
    const args_json = if (params.get("arguments")) |args| try std.json.Stringify.valueAlloc(arena, args, .{}) else "{}";
    const outcome = backend.call(backend.ctx, arena, grant.name, name, args_json) orelse
        ToolResult{ .text = "error: could not reach the Marlin daemon", .ok = false };
    const Content = struct { type: []const u8 = "text", text: []const u8 };
    const content = [_]Content{.{ .text = outcome.text }};
    // The attention log is JSON: also give it structured.
    if (outcome.ok and std.mem.eql(u8, name, attention.attention_name)) {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, outcome.text, .{})) |structured| {
            return result(arena, id, is_modern, .{ .content = &content, .structuredContent = structured, .isError = false });
        } else |_| {}
    }
    return result(arena, id, is_modern, .{ .content = &content, .isError = !outcome.ok });
}

fn readResource(arena: std.mem.Allocator, grant: Grant, id: std.json.Value, params: std.json.ObjectMap, backend: Backend, is_modern: bool) !Response {
    const uri = if (params.get("uri")) |v| (if (v == .string) v.string else "") else "";
    if (!std.mem.eql(u8, uri, resource_uri))
        return errorResponse(arena, 200, id, if (is_modern) code_invalid_params else code_resource_not_found, "resource not found", .{ .uri = uri });
    if (!grant.read) return scopeError(arena, id, .read);
    var args_buf: [32]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "{{\"last\":{d}}}", .{resource_moments}) catch unreachable;
    const outcome = backend.call(backend.ctx, arena, grant.name, attention.attention_name, args) orelse
        return errorResponse(arena, 200, id, -32603, "could not reach the Marlin daemon", null);
    if (!outcome.ok) return errorResponse(arena, 200, id, -32603, outcome.text, null);
    const Contents = struct { uri: []const u8, mimeType: []const u8, text: []const u8 };
    return result(arena, id, is_modern, .{ .contents = &[_]Contents{.{ .uri = resource_uri, .mimeType = "application/json", .text = outcome.text }} });
}

fn listen(arena: std.mem.Allocator, req: Request, id: std.json.Value, params: std.json.ObjectMap) !Response {
    if (!req.grant.read) return scopeError(arena, id, .read);
    const wanted = params.get("notifications") orelse
        return errorResponse(arena, 400, id, code_invalid_params, "missing notifications", null);
    if (wanted != .object) return errorResponse(arena, 400, id, code_invalid_params, "notifications must be an object", null);
    // Only resource updates for the attention resource are sent; anything
    // else asked for is left out of the acknowledgement (the tool and
    // resource lists never change).
    var attention_wanted = false;
    if (wanted.object.get("resourceSubscriptions")) |uris| if (uris == .array) {
        for (uris.array.items) |uri| {
            if (uri == .string and std.mem.eql(u8, uri.string, resource_uri)) attention_wanted = true;
        }
    };
    const Granted = struct { resourceSubscriptions: []const []const u8 };
    const granted: Granted = .{ .resourceSubscriptions = if (attention_wanted) &.{resource_uri} else &.{} };
    const ack = try notification(arena, "notifications/subscriptions/acknowledged", .{
        ._meta = .{ .@"io.modelcontextprotocol/subscriptionId" = id },
        .notifications = granted,
    });
    const updated = if (attention_wanted) try notification(arena, "notifications/resources/updated", .{
        ._meta = .{ .@"io.modelcontextprotocol/subscriptionId" = id },
        .uri = resource_uri,
    }) else null;
    const end = (try result(arena, id, true, .{ ._meta = .{ .@"io.modelcontextprotocol/subscriptionId" = id } })).body;
    return .{ .body = ack, .listen = .{ .updated = updated, .end = end } };
}

fn serverInfo() struct { name: []const u8, title: []const u8, version: []const u8 } {
    return .{ .name = "marlin", .title = "Marlin", .version = build_options.version };
}

fn isLegacy(version: []const u8) bool {
    for (legacy) |v| if (std.mem.eql(u8, v, version)) return true;
    return false;
}

/// Header names compare case-insensitively (HTTP does); values must equal the
/// body's, and a missing header is a mismatch: 2026-07-28 requires them.
/// Non-ASCII values arrive as `=?base64?…?=`.
fn headerMatches(header: ?[]const u8, want: []const u8) bool {
    const value = header orelse return false;
    if (std.mem.startsWith(u8, value, "=?base64?") and std.mem.endsWith(u8, value, "?=")) {
        const encoded = value["=?base64?".len .. value.len - 2];
        var buf: [1024]u8 = undefined;
        const decoder = std.base64.standard.Decoder;
        const len = decoder.calcSizeForSlice(encoded) catch return false;
        if (len > buf.len) return false;
        decoder.decode(buf[0..len], encoded) catch return false;
        return std.mem.eql(u8, buf[0..len], want);
    }
    return std.mem.eql(u8, value, want);
}

fn result(arena: std.mem.Allocator, id: std.json.Value, is_modern: bool, value: anytype) !Response {
    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("result");
    // Every 2026-07-28 result says whether it is complete.
    if (is_modern) {
        const fields = try std.json.Stringify.valueAlloc(arena, value, .{});
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, fields, .{});
        var object = parsed.object;
        try object.put(arena, "resultType", .{ .string = "complete" });
        try json.write(std.json.Value{ .object = object });
    } else try json.write(value);
    try json.endObject();
    return .{ .body = out.written() };
}

fn notification(arena: std.mem.Allocator, method: []const u8, params: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{ .jsonrpc = "2.0", .method = method, .params = params }, .{});
}

fn errorResponse(arena: std.mem.Allocator, status: u16, id: std.json.Value, code: i64, message: []const u8, data: anytype) !Response {
    const body = if (@TypeOf(data) == @TypeOf(null))
        try std.json.Stringify.valueAlloc(arena, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }, .{})
    else
        try std.json.Stringify.valueAlloc(arena, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message, .data = data } }, .{});
    return .{ .status = status, .body = body };
}

fn unsupportedVersion(arena: std.mem.Allocator, id: std.json.Value, requested: []const u8) !Response {
    return errorResponse(arena, 400, id, code_unsupported_version, "Unsupported protocol version", .{ .supported = &supported, .requested = requested });
}

fn scopeError(arena: std.mem.Allocator, id: std.json.Value, needed: Scope) !Response {
    var response = try errorResponse(arena, 403, id, code_invalid_request, switch (needed) {
        .read => "this token lacks the read scope",
        .act => "this token lacks the act scope",
    }, null);
    response.insufficient_scope = needed;
    return response;
}
