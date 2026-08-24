//! `marlin run "task"` — headless one-shot session. Doubles as the eval
//! harness (docs/ARCHITECTURE.md §11): create session, run to completion,
//! print result to stdout, exit nonzero on failure.
//!
//! M0 NOTE: no daemon exists yet, so this drives daemon/loop.zig in-process.
//! From M1 it becomes a true protocol client and the in-process path dies.
//!
//! Flags:
//!   --continue        reuse the most recent session
//!   --model <m>       override the model (registry string)
//!   --quiet           suppress streaming; print only the final text

const std = @import("std");
const Io = std.Io;

const config = @import("../core/config.zig");
const store_mod = @import("../daemon/store.zig");
const loop = @import("../daemon/loop.zig");
const ids = @import("../core/ids.zig");
const registry = @import("../daemon/provider/registry.zig");
const http = @import("../daemon/provider/http.zig");

pub const Flags = struct {
    continue_last: bool = false,
    model: ?[]const u8 = null,
    quiet: bool = false,
    task: ?[]const u8 = null,
};

pub fn parseFlags(args: []const [:0]const u8) !Flags {
    var f = Flags{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--continue")) {
            f.continue_last = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            f.quiet = true;
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModelArg;
            f.model = args[i];
        } else if (f.task == null) {
            f.task = a;
        } else {
            return error.UnexpectedArg;
        }
    }
    return f;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) !u8 {
    const flags = parseFlags(args) catch {
        try eprint(io, "usage: marlin run [--continue] [--model <m>] [--quiet] \"task\"\n", .{});
        return 2;
    };
    const task = flags.task orelse {
        try eprint(io, "marlin run: missing task text\n", .{});
        return 2;
    };

    const cfg = config.defaults();
    const model_str = flags.model orelse cfg.model_default;

    // Resolve provider endpoint + credentials.
    const ep = registry.resolve(gpa, environ, model_str) catch |e| switch (e) {
        error.MissingApiKey => {
            try eprint(io, "marlin: OPENROUTER_API_KEY is not set\n", .{});
            return 1;
        },
        error.MissingBaseUrl => {
            try eprint(io, "marlin: MARLIN_LOCAL_BASE_URL is not set for local/ models\n", .{});
            return 1;
        },
        error.UnknownProvider => {
            try eprint(io, "marlin: unknown provider in model '{s}'\n", .{model_str});
            return 1;
        },
        else => return e,
    };
    defer ep.deinit(gpa);

    http.globalInit();
    defer http.globalDeinit();

    // Open store.
    const db_path = try store_mod.defaultDbPath(gpa, io, environ);
    defer gpa.free(db_path);
    var store = try store_mod.Store.open(gpa, db_path);
    defer store.close();

    // Session: new or continued.
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    var session_id: u64 = undefined;
    if (flags.continue_last) {
        session_id = (try store.lastSession()) orelse {
            try eprint(io, "marlin: no session to continue\n", .{});
            return 1;
        };
    } else {
        session_id = ids.next(io);
        try store.createSession(session_id, nowMs(io), cwd, model_str);
    }

    // Delta/tool progress sinks.
    var sink = Sink{ .io = io, .quiet = flags.quiet };

    const result = loop.runTurn(gpa, io, &store, .{
        .session_id = session_id,
        .cwd = cwd,
        .endpoint = .{ .url = ep.url, .bearer = ep.bearer, .model = ep.model },
        .cfg = cfg,
        .on_delta = Sink.onDelta,
        .on_delta_ctx = &sink,
        .on_tool = Sink.onTool,
    }, task) catch |e| switch (e) {
        error.ProviderError => {
            try eprint(io, "\nmarlin: provider error (see session log)\n", .{});
            return 1;
        },
        error.TooManyRounds => {
            try eprint(io, "\nmarlin: gave up after too many tool rounds\n", .{});
            return 1;
        },
        else => return e,
    };
    defer gpa.free(result.text);

    if (flags.quiet) {
        try print(io, "{s}\n", .{result.text});
    } else {
        // Streaming already printed the text; add the summary line.
        try print(io, "\n\n[{d} round(s), {d} in / {d} out tokens, session {d}]\n", .{
            result.rounds, result.tokens_in, result.tokens_out, session_id,
        });
    }
    return 0;
}

const Sink = struct {
    io: Io,
    quiet: bool,
    printed_any: bool = false,

    fn onDelta(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        if (self.quiet) return;
        self.printed_any = true;
        print(self.io, "{s}", .{text}) catch {};
    }

    fn onTool(ctx: ?*anyopaque, name: []const u8, phase: loop.ToolPhase) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        if (self.quiet) return;
        switch (phase) {
            .start => print(self.io, "\n[tool: {s} ...", .{name}) catch {},
            .done => print(self.io, " done]\n", .{}) catch {},
        }
    }
};

fn print(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn eprint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

test "flag parsing" {
    const args = [_][:0]const u8{ "--continue", "--model", "openrouter/x", "do stuff" };
    const f = try parseFlags(&args);
    try std.testing.expect(f.continue_last);
    try std.testing.expectEqualStrings("openrouter/x", f.model.?);
    try std.testing.expectEqualStrings("do stuff", f.task.?);
}
