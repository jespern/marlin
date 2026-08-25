//! Tool registry (docs/ARCHITECTURE.md §7).
//!
//! A tool spec: name, JSON schema, parallel_safe, mutating. Sources: built-ins
//! (this dir; complete as of M2), exec tools (M5), MCP servers (M5). Dispatch
//! is uniform; the approval gate applies identically regardless of source —
//! it lives in the loop, driven by Spec.mutating + session policy.

const std = @import("std");
const Io = std.Io;

const block = @import("../../core/block.zig");
const permissions = @import("../permissions.zig");
const sandbox = @import("../sandbox.zig");
const network_policy = @import("../network_policy.zig");
const shell_network = @import("../shell_network.zig");
const bash = @import("bash.zig");
const files = @import("files.zig");
const search = @import("search.zig");
const fetch_tool = @import("fetch.zig");
const task = @import("task.zig");

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema for arguments, as a raw JSON string.
    schema_json: []const u8,
    /// Read-only tools may execute concurrently within a turn.
    parallel_safe: bool,
    /// Whether the tool mutates state (drives the default approval policy).
    mutating: bool,
};

/// The built-in tool set (M2-complete, pi-minimalist).
pub const specs = [_]Spec{
    .{ .name = bash.spec_name, .description = bash.spec_description, .schema_json = bash.spec_schema, .parallel_safe = false, .mutating = true },
    .{ .name = files.read_spec_name, .description = files.read_spec_description, .schema_json = files.read_spec_schema, .parallel_safe = true, .mutating = false },
    .{ .name = files.write_spec_name, .description = files.write_spec_description, .schema_json = files.write_spec_schema, .parallel_safe = false, .mutating = true },
    .{ .name = files.edit_spec_name, .description = files.edit_spec_description, .schema_json = files.edit_spec_schema, .parallel_safe = false, .mutating = true },
    .{ .name = search.grep_spec_name, .description = search.grep_spec_description, .schema_json = search.grep_spec_schema, .parallel_safe = true, .mutating = false },
    .{ .name = search.glob_spec_name, .description = search.glob_spec_description, .schema_json = search.glob_spec_schema, .parallel_safe = true, .mutating = false },
    .{ .name = fetch_tool.spec_name, .description = fetch_tool.spec_description, .schema_json = fetch_tool.spec_schema, .parallel_safe = true, .mutating = false },
    // Execution crosses back to the daemon dispatcher through RunOpts.on_task;
    // generic dispatch intentionally has no session/store access.
    .{ .name = task.spec_name, .description = task.spec_description, .schema_json = task.spec_schema, .parallel_safe = false, .mutating = false },
    .{ .name = task.batch_spec_name, .description = task.batch_spec_description, .schema_json = task.batch_spec_schema, .parallel_safe = false, .mutating = false },
};

pub fn find(name: []const u8) ?*const Spec {
    for (&specs) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

pub const ExecOut = struct {
    output: []u8,
    status: block.ToolStatus,
};

/// Execute a tool by name with raw (repaired) JSON args. Unknown tools and
/// argument parse failures are returned as error-text results — tool errors
/// are data the model reacts to, never harness crashes.
pub fn dispatch(
    gpa: std.mem.Allocator,
    io: Io,
    name: []const u8,
    args_json: []const u8,
    cwd: []const u8,
    source_environ: ?*const std.process.Environ.Map,
    sandbox_options: sandbox.Options,
    policy: ?*const network_policy.Policy,
    cancel: ?*std.atomic.Value(bool),
) ExecOut {
    // bash and the rg-backed grep path are the current tool subprocesses.
    // Build their environment here so new subprocess-backed tools have one
    // obvious boundary to reuse.
    var child_environ: std.process.Environ.Map = undefined;
    var has_child_environ = false;
    defer if (has_child_environ) child_environ.deinit();
    if (source_environ != null and
        (std.mem.eql(u8, name, bash.spec_name) or std.mem.eql(u8, name, search.grep_spec_name)))
    {
        child_environ = permissions.toolEnvironment(gpa, source_environ.?) catch |e| {
            return .{ .output = errText(gpa, e), .status = .err };
        };
        has_child_environ = true;
    }
    if (has_child_environ and sandbox_options.backend == .seatbelt) {
        const temp_root = sandbox_options.temp_root orelse {
            return .{ .output = gpa.dupe(u8, "error: sandbox temp root unavailable") catch @panic("oom"), .status = .err };
        };
        child_environ.put("TMPDIR", temp_root) catch |e| {
            return .{ .output = errText(gpa, e), .status = .err };
        };
    }
    const child_environ_ptr: ?*const std.process.Environ.Map = if (has_child_environ) &child_environ else null;

    if (std.mem.eql(u8, name, bash.spec_name)) {
        const parsed = parseArgs(bash.Args, gpa, args_json) orelse return argError(gpa, args_json);
        defer parsed.deinit();
        if (policy) |active| {
            var blocked = shell_network.inspect(gpa, parsed.value.command, active) catch |e| {
                return .{ .output = errText(gpa, e), .status = .err };
            };
            if (blocked) |*denied| {
                defer denied.deinit(gpa);
                const output = std.fmt.allocPrint(
                    gpa,
                    "error: network policy blocked bash command '{s}' from connecting to '{s}' via {s} (matched {s}); shell command was not run",
                    .{ denied.tool, denied.host, denied.source, denied.domain },
                ) catch @panic("oom");
                return .{ .output = output, .status = .denied };
            }
        }
        const r = bash.run(gpa, io, parsed.value, cwd, child_environ_ptr, sandbox_options, cancel) catch |e| {
            if (e == error.Cancelled) return .{
                .output = gpa.dupe(u8, "command interrupted by user") catch @panic("oom"),
                .status = .interrupted,
            };
            return .{ .output = errText(gpa, e), .status = .err };
        };
        if (r.exit_code != 0) {
            const with_code = std.fmt.allocPrint(gpa, "{s}\n[exit code: {d}]", .{ r.output, r.exit_code }) catch
                return .{ .output = r.output, .status = .err };
            gpa.free(r.output);
            return .{ .output = with_code, .status = .err };
        }
        return .{ .output = r.output, .status = .ok };
    }
    if (std.mem.eql(u8, name, files.read_spec_name)) {
        const parsed = parseArgs(files.ReadArgs, gpa, args_json) orelse return argError(gpa, args_json);
        defer parsed.deinit();
        return cancellableTextResult(files.readFileCancelable(gpa, io, parsed.value, cwd, cancel), gpa);
    }
    if (std.mem.eql(u8, name, files.write_spec_name)) {
        const parsed = parseArgs(files.WriteArgs, gpa, args_json) orelse return argError(gpa, args_json);
        defer parsed.deinit();
        return cancellableTextResult(files.writeFileCancelable(gpa, io, parsed.value, cwd, cancel), gpa);
    }
    if (std.mem.eql(u8, name, files.edit_spec_name)) {
        const parsed = parseArgs(files.EditArgs, gpa, args_json) orelse return argError(gpa, args_json);
        defer parsed.deinit();
        return cancellableTextResult(files.editFileCancelable(gpa, io, parsed.value, cwd, cancel), gpa);
    }
    if (std.mem.eql(u8, name, search.grep_spec_name)) {
        const parsed = parseArgs(search.GrepArgs, gpa, args_json) orelse return argError(gpa, args_json);
        defer parsed.deinit();
        return cancellableTextResult(search.grep(gpa, io, parsed.value, cwd, child_environ_ptr, cancel), gpa);
    }
    if (std.mem.eql(u8, name, search.glob_spec_name)) {
        const parsed = parseArgs(search.GlobArgs, gpa, args_json) orelse return argError(gpa, args_json);
        defer parsed.deinit();
        return cancellableTextResult(search.glob(gpa, io, parsed.value, cwd, cancel), gpa);
    }
    if (std.mem.eql(u8, name, fetch_tool.spec_name)) {
        const parsed = parseArgs(fetch_tool.Args, gpa, args_json) orelse return argError(gpa, args_json);
        defer parsed.deinit();
        return cancellableTextResult(fetch_tool.fetch(gpa, io, source_environ, parsed.value, policy, cancel), gpa);
    }
    const msg = std.fmt.allocPrint(gpa, "error: unknown tool '{s}'", .{name}) catch @panic("oom");
    return .{ .output = msg, .status = .err };
}

fn parseArgs(comptime T: type, gpa: std.mem.Allocator, args_json: []const u8) ?std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, args_json, .{ .ignore_unknown_fields = true }) catch null;
}

/// Convention: tool fns return `![]u8` where the text itself carries
/// "error: ..." for model-visible failures.
fn textResult(out_or_err: anyerror![]u8, gpa: std.mem.Allocator) ExecOut {
    const out = out_or_err catch |e| return .{ .output = errText(gpa, e), .status = .err };
    const is_err = std.mem.startsWith(u8, out, "error:");
    return .{ .output = out, .status = if (is_err) .err else .ok };
}

fn cancellableTextResult(out_or_err: anyerror![]u8, gpa: std.mem.Allocator) ExecOut {
    const out = out_or_err catch |e| {
        if (e == error.Cancelled) return .{
            .output = gpa.dupe(u8, "tool interrupted by user") catch @panic("oom"),
            .status = .interrupted,
        };
        return .{ .output = errText(gpa, e), .status = .err };
    };
    const is_err = std.mem.startsWith(u8, out, "error:");
    return .{ .output = out, .status = if (is_err) .err else .ok };
}

fn argError(gpa: std.mem.Allocator, args_json: []const u8) ExecOut {
    const msg = std.fmt.allocPrint(
        gpa,
        "error: could not parse tool arguments as JSON. Got: {s}\nRe-issue the call with valid JSON matching the schema.",
        .{args_json[0..@min(args_json.len, 500)]},
    ) catch @panic("oom");
    return .{ .output = msg, .status = .err };
}

fn errText(gpa: std.mem.Allocator, e: anyerror) []u8 {
    return std.fmt.allocPrint(gpa, "error: {t}", .{e}) catch @panic("oom");
}

// ---------------------------------------------------------------- tests --

test "find: all specs resolvable, unknown is null" {
    for (&specs) |*s| {
        try std.testing.expect(find(s.name) != null);
    }
    try std.testing.expect(find("nope") == null);
    try std.testing.expect(find("bash").?.mutating);
    try std.testing.expect(!find("read_file").?.mutating);
    try std.testing.expect(find("grep").?.parallel_safe);
    try std.testing.expect(!find("task").?.parallel_safe);
}

test "dispatch: unknown tool returns error text, not crash" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const r = dispatch(gpa, io, "bogus", "{}", "/tmp", null, .{}, null, null);
    defer gpa.free(r.output);
    try std.testing.expectEqual(block.ToolStatus.err, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "unknown tool") != null);
}

test "dispatch: bad args json returns error text" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const r = dispatch(gpa, io, "read_file", "{not json", "/tmp", null, .{}, null, null);
    defer gpa.free(r.output);
    try std.testing.expectEqual(block.ToolStatus.err, r.status);
}

test "dispatch: file tools observe a turn already cancelled" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var cancel: std.atomic.Value(bool) = .init(true);
    const r = dispatch(
        gpa,
        threaded.io(),
        "read_file",
        "{\"path\":\"never-opened\"}",
        "/tmp",
        null,
        .{},
        null,
        &cancel,
    );
    defer gpa.free(r.output);
    try std.testing.expectEqual(block.ToolStatus.interrupted, r.status);
}

test "dispatch: bash policy denies atomically and null policy bypasses screening" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var policy = network_policy.Policy.init(gpa, io, &environ, .{ .deny = "blocked.test" });
    defer policy.deinit();

    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-network-dispatch");
    defer temp.deinit();
    const cwd = temp.path;

    const denied = dispatch(
        gpa,
        io,
        "bash",
        \\{"command":"printf touched > marker; curl https://sub.blocked.test/upload"}
    ,
        cwd,
        null,
        .{},
        &policy,
        null,
    );
    defer gpa.free(denied.output);
    try std.testing.expectEqual(block.ToolStatus.denied, denied.status);
    try std.testing.expect(std.mem.indexOf(u8, denied.output, "sub.blocked.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.output, "shell command was not run") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.output, "explicit deny") != null);

    const marker = try std.fs.path.join(gpa, &.{ cwd, "marker" });
    defer gpa.free(marker);
    try std.testing.expect(Io.Dir.cwd().statFile(io, marker, .{}) catch null == null);

    // This defines a local shell function, so the disabled-policy path proves
    // the dispatch behavior without making a real network connection.
    const bypassed = dispatch(
        gpa,
        io,
        "bash",
        \\{"command":"curl() { printf bypassed; }; curl https://sub.blocked.test/upload"}
    ,
        cwd,
        null,
        .{},
        null,
        null,
    );
    defer gpa.free(bypassed.output);
    try std.testing.expectEqual(block.ToolStatus.ok, bypassed.status);
    try std.testing.expectEqualStrings("bypassed", bypassed.output);
}

test "dispatch: tool subprocess cannot see provider credentials" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var source_environ = std.process.Environ.Map.init(gpa);
    defer source_environ.deinit();
    try source_environ.put("OPENROUTER_API_KEY", "must-not-cross-boundary");
    try source_environ.put("PUBLIC_VALUE", "visible");

    const r = dispatch(
        gpa,
        io,
        "bash",
        \\{"command":"printf '%s|%s' \"${OPENROUTER_API_KEY-unset}\" \"$PUBLIC_VALUE\""}
    ,
        "/tmp",
        &source_environ,
        .{},
        null,
        null,
    );
    defer gpa.free(r.output);

    try std.testing.expectEqual(block.ToolStatus.ok, r.status);
    try std.testing.expectEqualStrings("unset|visible", r.output);
}

test "dispatch: cancelled subprocess and walker tools are reported as interrupted" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var cancel = std.atomic.Value(bool).init(true);

    const r = dispatch(
        gpa,
        threaded.io(),
        "bash",
        \\{"command":"sleep 30"}
    ,
        "/tmp",
        null,
        .{},
        null,
        &cancel,
    );
    defer gpa.free(r.output);
    try std.testing.expectEqual(block.ToolStatus.interrupted, r.status);
    try std.testing.expectEqualStrings("command interrupted by user", r.output);

    const globbed = dispatch(
        gpa,
        threaded.io(),
        "glob",
        \\{"pattern":"*.zig"}
    ,
        "/tmp",
        null,
        .{},
        null,
        &cancel,
    );
    defer gpa.free(globbed.output);
    try std.testing.expectEqual(block.ToolStatus.interrupted, globbed.status);
    try std.testing.expectEqualStrings("tool interrupted by user", globbed.output);
}

test {
    std.testing.refAllDecls(@This());
}
