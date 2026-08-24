//! Scripted OpenAI-compatible fake provider (docs/ARCHITECTURE.md §11).
//!
//! A tiny localhost HTTP/1.1 server that replays a scenario file: an ordered
//! list of steps, each matching the expected request and scripting the
//! response (SSE stream or HTTP error). The binary under test is the REAL
//! marlin binary pointed here via MARLIN_BASE_URL_OPENROUTER. No mocks live
//! inside marlin itself — we fake the network peer, nothing else.
//!
//! Contract with the runner (src/testing/e2e_runner.zig):
//!   - args: <scenario.json>
//!   - picks a free port (random + retry), prints "PORT <n>\n" on stdout
//!     when listening, then serves exactly scenario.steps.len requests.
//!   - each request is validated against the step's `expect_contains`
//!     substrings; mismatch → prints "FAIL ..." and exits 3.
//!   - exits 0 after the last step; exits 2 on internal errors.
//!
//! Scenario JSON:
//!   {
//!     "steps": [
//!       {
//!         "expect_contains": ["\"model\":\"test/model\"", "hello"],
//!         "status": 200,                  // default 200
//!         "sse": ["{...chunk json...}", "[DONE]"],   // for status 200
//!         "body": "{\"error\":...}",      // for error statuses
//!         "delay_ms_between_events": 0
//!       }
//!     ]
//!   }

const std = @import("std");
const Io = std.Io;

pub const Step = struct {
    expect_contains: []const []const u8 = &.{},
    expect_not_contains: []const []const u8 = &.{},
    status: u16 = 200,
    sse: []const []const u8 = &.{},
    body: []const u8 = "",
    delay_ms_between_events: u32 = 0,
};

pub const Scenario = struct {
    steps: []const Step,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.log.err("usage: marlin-fakeprov <scenario.json>", .{});
        return 2;
    }

    // Load scenario.
    const scenario_bytes = Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(4 * 1024 * 1024)) catch |e| {
        std.log.err("cannot read scenario '{s}': {t}", .{ args[1], e });
        return 2;
    };
    const scenario = std.json.parseFromSliceLeaky(Scenario, arena, scenario_bytes, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        std.log.err("bad scenario json: {t}", .{e});
        return 2;
    };

    // Listen on a free port: random attempts, then announce.
    var prng = std.Random.DefaultPrng.init(seedFromTime(io));
    const rand = prng.random();
    var server: Io.net.Server = undefined;
    var port: u16 = 0;
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        if (attempt > 50) {
            std.log.err("no free port found", .{});
            return 2;
        }
        port = 20000 + rand.uintLessThan(u16, 40000);
        const addr = Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        server = addr.listen(io, .{ .reuse_address = true }) catch continue;
        break;
    }
    defer server.deinit(io);

    try stdoutPrint(io, "PORT {d}\n", .{port});

    // Serve exactly one request per step, sequentially.
    for (scenario.steps, 0..) |step, step_idx| {
        var stream = server.accept(io) catch |e| {
            std.log.err("accept failed: {t}", .{e});
            return 2;
        };
        defer stream.close(io);

        const req = readRequest(gpa, io, &stream) catch |e| {
            std.log.err("step {d}: bad request: {t}", .{ step_idx, e });
            return 2;
        };
        defer gpa.free(req.body);

        // Validate expectations against the request body.
        for (step.expect_contains) |needle| {
            if (std.mem.indexOf(u8, req.body, needle) == null) {
                try stdoutPrint(io, "FAIL step {d}: request body missing {f}\nBODY: {s}\n", .{
                    step_idx, std.json.fmt(needle, .{}), req.body[0..@min(req.body.len, 4000)],
                });
                return 3;
            }
        }
        for (step.expect_not_contains) |needle| {
            if (std.mem.indexOf(u8, req.body, needle) != null) {
                try stdoutPrint(io, "FAIL step {d}: request body unexpectedly contains {f}\nBODY: {s}\n", .{
                    step_idx, std.json.fmt(needle, .{}), req.body[0..@min(req.body.len, 4000)],
                });
                return 3;
            }
        }

        // Respond.
        var wbuf: [8192]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(stream, io, &wbuf);
        const w = &writer.interface;

        if (step.status == 200 and step.body.len > 0) {
            // Plain JSON response (e.g. the /models catalog).
            try w.print(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
                .{ step.body.len, step.body },
            );
            try w.flush();
        } else if (step.status == 200) {
            try w.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n");
            try w.flush();
            for (step.sse) |event_data| {
                try w.print("data: {s}\n\n", .{event_data});
                try w.flush();
                if (step.delay_ms_between_events > 0) {
                    sleepMs(io, step.delay_ms_between_events);
                }
            }
        } else {
            try w.print(
                "HTTP/1.1 {d} Error\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
                .{ step.status, step.body.len, step.body },
            );
            try w.flush();
        }
    }
    return 0;
}

const Request = struct { body: []u8 };

/// Minimal HTTP/1.1 request reader: headers until CRLFCRLF, then
/// Content-Length bytes of body.
fn readRequest(gpa: std.mem.Allocator, io: Io, stream: *Io.net.Stream) !Request {
    var rbuf: [64 * 1024]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream.*, io, &rbuf);
    const r = &reader.interface;

    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    // Read until blank line.
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch return error.BadRequest;
        try head.appendSlice(gpa, line);
        if (head.items.len > 256 * 1024) return error.HeadersTooLarge;
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
    }

    // Content-Length (case-insensitive scan).
    var content_length: usize = 0;
    var it = std.mem.splitScalar(u8, head.items, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        if (l.len > 15 and std.ascii.eqlIgnoreCase(l[0..15], "content-length:")) {
            const v = std.mem.trim(u8, l[15..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }
    if (content_length > 32 * 1024 * 1024) return error.BodyTooLarge;

    const body = try gpa.alloc(u8, content_length);
    errdefer gpa.free(body);
    var got: usize = 0;
    while (got < content_length) {
        const chunk = r.take(@min(content_length - got, 4096)) catch return error.BadRequest;
        @memcpy(body[got .. got + chunk.len], chunk);
        got += chunk.len;
    }
    return .{ .body = body };
}

fn seedFromTime(io: Io) u64 {
    const ts = Io.Timestamp.now(io, .real);
    return @truncate(@as(u128, @bitCast(@as(i128, ts.nanoseconds))));
}

fn sleepMs(io: Io, ms: u32) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn stdoutPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
