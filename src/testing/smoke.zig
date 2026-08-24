//! Live smoke tests: drives the real marlin binary against real OpenRouter.
//! Needs OPENROUTER_API_KEY. Uses a cheap model; a full run costs ~a cent.
//! Run manually or CI-nightly — NEVER in the inner loop.
//!
//! Usage: smoke <marlin-bin>   (zig build smoke)

const std = @import("std");
const Io = std.Io;

const model = "openrouter/google/gemini-2.5-flash";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.log.err("usage: smoke <marlin-bin>", .{});
        return 2;
    }
    const marlin_bin = args[1];

    if (init.environ_map.get("OPENROUTER_API_KEY") == null) {
        print(io, "smoke: OPENROUTER_API_KEY not set — skipping (not a failure)\n", .{});
        return 0;
    }

    // Isolated state dir so smoke never touches the real session DB.
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const state_dir = try std.fmt.allocPrint(arena, "/tmp/marlin-smoke-{x}", .{
        std.mem.readInt(u64, &rand_bytes, .little),
    });
    try Io.Dir.cwd().createDirPath(io, state_dir);
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    var env = std.process.Environ.Map.init(arena);
    var src_it = init.environ_map.array_hash_map.iterator();
    while (src_it.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.*);
    try env.put("XDG_STATE_HOME", state_dir);

    var failures: u32 = 0;

    // 1. Plain completion.
    failures += try check(gpa, io, .{
        .name = "completion",
        .argv = &.{ marlin_bin, "run", "--quiet", "--model", model, "Reply with exactly the word: pelican" },
        .env = &env,
        .stdout_contains = "pelican",
    });

    // 2. Tool round trip.
    failures += try check(gpa, io, .{
        .name = "tool-roundtrip",
        .argv = &.{ marlin_bin, "run", "--quiet", "--model", model, "Run `echo smoke-marker-9271` with the bash tool and tell me what it printed." },
        .env = &env,
        .stdout_contains = "smoke-marker-9271",
    });

    // 3. Session continue.
    failures += try check(gpa, io, .{
        .name = "continue-setup",
        .argv = &.{ marlin_bin, "run", "--quiet", "--model", model, "Remember this codeword: zanzibar. Just acknowledge." },
        .env = &env,
        .stdout_contains = "",
    });
    failures += try check(gpa, io, .{
        .name = "continue-recall",
        .argv = &.{ marlin_bin, "run", "--quiet", "--continue", "--model", model, "What was the codeword? Reply with just the word." },
        .env = &env,
        .stdout_contains = "zanzibar",
    });

    if (failures > 0) {
        print(io, "\nsmoke: {d} test(s) FAILED\n", .{failures});
        return 1;
    }
    print(io, "\nsmoke: all passed\n", .{});
    return 0;
}

const Check = struct {
    name: []const u8,
    argv: []const []const u8,
    env: *std.process.Environ.Map,
    stdout_contains: []const u8,
};

fn check(gpa: std.mem.Allocator, io: Io, c: Check) !u32 {
    print(io, "smoke {s} ... ", .{c.name});
    const res = std.process.run(gpa, io, .{
        .argv = c.argv,
        .environ_map = c.env,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |e| {
        print(io, "SPAWN FAILED: {t}\n", .{e});
        return 1;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const ok_exit = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok_exit) {
        print(io, "FAILED (exit)\n  stderr: {s}\n", .{res.stderr[0..@min(res.stderr.len, 1000)]});
        return 1;
    }
    if (c.stdout_contains.len > 0 and std.mem.indexOf(u8, res.stdout, c.stdout_contains) == null) {
        print(io, "FAILED (output)\n  want: {s}\n  got: {s}\n", .{ c.stdout_contains, res.stdout[0..@min(res.stdout.len, 1000)] });
        return 1;
    }
    print(io, "ok\n", .{});
    return 0;
}

fn print(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}
