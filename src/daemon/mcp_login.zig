//! `/mcp login <server>`: one OAuth authorization in flight. A thread runs
//! discovery and client registration, reports the sign-in URL, then waits on
//! a loopback listener for the browser's redirect. A callback URL pasted into
//! Marlin (the browser could not reach this machine, e.g. over SSH) is
//! replayed into the same listener, so both paths finish identically.

const std = @import("std");
const Io = std.Io;
const http = @import("provider/http.zig");
const oauth = @import("tools/mcp_oauth.zig");

pub const Event = enum { url_ready, finished };

pub const Notify = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, job: *Job, event: Event) void,
};

pub const Job = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    client_id: u64,
    /// Whoever pasted the callback hears the outcome too.
    paste_client_id: ?u64 = null,
    name: []u8,
    url: []u8,
    challenge: []u8,
    auth_path: []u8,
    listener: Io.net.Server,
    port: u16,
    notify: Notify,
    thread: ?std.Thread = null,
    /// Written by the job thread before the matching event is posted.
    authorization_url: ?[]u8 = null,
    ok: bool = false,
    message: ?[]u8 = null,

    pub fn deinit(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.listener.deinit(self.io);
        self.gpa.free(self.name);
        self.gpa.free(self.url);
        self.gpa.free(self.challenge);
        self.gpa.free(self.auth_path);
        if (self.authorization_url) |value| self.gpa.free(value);
        if (self.message) |value| self.gpa.free(value);
        self.gpa.destroy(self);
    }

    /// Finish with a callback URL the user pasted. Only its path and query
    /// matter; the host was wherever their browser tried to go.
    pub fn deliver(self: *Job, callback_url: []const u8) !void {
        try self.replay(try callbackTarget(callback_url));
    }

    /// Abandon the login; the thread reports `finished` and exits.
    pub fn cancel(self: *Job) void {
        self.replay("/cancel") catch |err| std.log.warn("MCP login cancel failed: {t}", .{err});
    }

    fn replay(self: *Job, target: []const u8) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", self.port);
        var stream = try address.connect(self.io, .{ .mode = .stream });
        defer stream.close(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(stream, self.io, &buffer);
        try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n" ++ replay_header ++ ": 1\r\nConnection: close\r\n\r\n", .{target});
        try writer.interface.flush();
    }
};

/// Marks a request Marlin replayed from a paste: a mismatch there is the
/// user's answer and must end the login, not be waited out like a stray hit.
const replay_header = "X-Marlin-Replay";

/// Path and query of a pasted callback URL (or a pasted path).
pub fn callbackTarget(pasted: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, pasted, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "://")) |scheme_end| {
        const path = std.mem.indexOfScalarPos(u8, trimmed, scheme_end + 3, '/') orelse return error.InvalidCallback;
        return trimmed[path..];
    }
    if (std.mem.startsWith(u8, trimmed, "/")) return trimmed;
    return error.InvalidCallback;
}

pub fn start(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    client_id: u64,
    name: []const u8,
    url: []const u8,
    challenge: []const u8,
    auth_path: []const u8,
    notify: Notify,
) !*Job {
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    errdefer listener.deinit(io);
    job.* = .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .client_id = client_id,
        .name = try gpa.dupe(u8, name),
        .url = try gpa.dupe(u8, url),
        .challenge = try gpa.dupe(u8, challenge),
        .auth_path = try gpa.dupe(u8, auth_path),
        .listener = listener,
        .port = listener.socket.address.getPort(),
        .notify = notify,
    };
    job.thread = try std.Thread.spawn(.{}, run, .{job});
    return job;
}

fn run(job: *Job) void {
    var arena_state = std.heap.ArenaAllocator.init(job.gpa);
    defer arena_state.deinit();
    const outcome = runFlow(job, arena_state.allocator()) catch |err| blk: {
        const detail = oauth.failureDetail();
        break :blk Outcome{ .ok = false, .message = if (detail.len > 0)
            std.fmt.allocPrint(job.gpa, "{s} login failed: {t} ({s})", .{ job.name, err, detail }) catch null
        else
            std.fmt.allocPrint(job.gpa, "{s} login failed: {t}", .{ job.name, err }) catch null };
    };
    job.ok = outcome.ok;
    job.message = outcome.message;
    job.notify.func(job.notify.ctx, job, .finished);
}

const Outcome = struct { ok: bool, message: ?[]u8 };

fn runFlow(job: *Job, arena: std.mem.Allocator) !Outcome {
    oauth.clearDetail();
    var pool = try http.Pool.init(job.gpa, job.io, job.environ);
    defer pool.deinit();
    const redirect_uri = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/callback", .{job.port});
    const challenge = try oauth.parseChallenge(arena, job.challenge);
    const flow = try oauth.begin(&pool.client, job.gpa, arena, job.io, job.url, challenge, redirect_uri);
    job.authorization_url = try job.gpa.dupe(u8, flow.authorization_url);
    job.notify.func(job.notify.ctx, job, .url_ready);

    while (true) {
        var stream = try job.listener.accept(job.io);
        defer stream.close(job.io);
        const request = readRequest(arena, job.io, stream) catch continue;
        const target = request.target;
        if (std.mem.eql(u8, target, "/cancel")) {
            respond(job.io, stream, "200 OK", "Login cancelled.");
            return .{ .ok = false, .message = try std.fmt.allocPrint(job.gpa, "{s} login cancelled", .{job.name}) };
        }
        if (!std.mem.startsWith(u8, target, "/callback")) {
            respond(job.io, stream, "404 Not Found", "Not found.");
            continue;
        }
        const credentials = oauth.finish(&pool.client, job.gpa, arena, nowMs(job.io), flow, target) catch |err| switch (err) {
            // A stray or stale request must not end a login the user is
            // still completing.
            error.StateMismatch, error.MissingCode => {
                respond(job.io, stream, "400 Bad Request", "This sign-in link does not match the login in progress.");
                if (request.replayed) return err;
                continue;
            },
            else => {
                respond(job.io, stream, "400 Bad Request", "Sign-in failed. Return to Marlin for details.");
                return err;
            },
        };
        try oauth.save(job.gpa, job.io, job.auth_path, job.name, credentials);
        respond(job.io, stream, "200 OK", "Signed in. You can close this tab and return to Marlin.");
        return .{ .ok = true, .message = try std.fmt.allocPrint(job.gpa, "Signed in to {s}", .{job.name}) };
    }
}

const Request = struct { target: []const u8, replayed: bool };

/// The target of one GET (bounded by the reader buffer) and whether Marlin
/// replayed it from a paste.
fn readRequest(arena: std.mem.Allocator, io: Io, stream: Io.net.Stream) !Request {
    var buffer: [8192]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &buffer);
    const line = try reader.interface.takeDelimiterInclusive('\n');
    var parts = std.mem.tokenizeScalar(u8, std.mem.trim(u8, line, " \r\n"), ' ');
    const method = parts.next() orelse return error.BadRequest;
    if (!std.mem.eql(u8, method, "GET")) return error.BadRequest;
    const target = try arena.dupe(u8, parts.next() orelse return error.BadRequest);
    var replayed = false;
    while (true) {
        const header = std.mem.trim(u8, try reader.interface.takeDelimiterInclusive('\n'), " \r\n");
        if (header.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(header, replay_header ++ ":")) replayed = true;
    }
    return .{ .target = target, .replayed = replayed };
}

fn respond(io: Io, stream: Io.net.Stream, status: []const u8, text: []const u8) void {
    var buffer: [2048]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &buffer);
    writer.interface.print(
        "HTTP/1.1 {s}\r\ncontent-type: text/html; charset=utf-8\r\ncache-control: no-store\r\nconnection: close\r\ncontent-length: {d}\r\n\r\n",
        .{ status, page_prefix.len + text.len + page_suffix.len },
    ) catch return;
    writer.interface.writeAll(page_prefix) catch return;
    writer.interface.writeAll(text) catch return;
    writer.interface.writeAll(page_suffix) catch return;
    writer.interface.flush() catch {};
}

const page_prefix = "<!doctype html><meta charset=utf-8><title>Marlin</title><body style=\"font:16px system-ui;margin:4em auto;max-width:32em\"><p>";
const page_suffix = "</p></body>";

fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}
