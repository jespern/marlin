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
const plan = @import("plan.zig");

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

/// Route conventional subprocess scratch/cache state into the sandbox's
/// existing writable temporary root. A command-local `VAR=value command`
/// assignment still wins in bash; inherited host cache paths cannot be used
/// because they sit outside the kernel write boundary.
pub fn configureSandboxEnvironment(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    temp_root: []const u8,
) !void {
    const cache_root = try std.fs.path.join(gpa, &.{ temp_root, "cache" });
    defer gpa.free(cache_root);
    try Io.Dir.cwd().createDirPath(io, cache_root);
    try environ.put("TMPDIR", temp_root);
    try environ.put("XDG_CACHE_HOME", cache_root);
}

/// The built-in tool set (M2-complete, pi-minimalist).
pub const specs = [_]Spec{
    .{ .name = bash.spec_name, .description = bash.spec_description, .schema_json = bash.spec_schema, .parallel_safe = false, .mutating = true },
    .{ .name = files.read_spec_name, .description = files.read_spec_description, .schema_json = files.read_spec_schema, .parallel_safe = true, .mutating = false },
    .{ .name = files.write_spec_name, .description = files.write_spec_description, .schema_json = files.write_spec_schema, .parallel_safe = false, .mutating = true },
    .{ .name = files.edit_spec_name, .description = files.edit_spec_description, .schema_json = files.edit_spec_schema, .parallel_safe = false, .mutating = true },
    .{ .name = search.grep_spec_name, .description = search.grep_spec_description, .schema_json = search.grep_spec_schema, .parallel_safe = true, .mutating = false },
    .{ .name = search.glob_spec_name, .description = search.glob_spec_description, .schema_json = search.glob_spec_schema, .parallel_safe = true, .mutating = false },
    .{ .name = fetch_tool.spec_name, .description = fetch_tool.spec_description, .schema_json = fetch_tool.spec_schema, .parallel_safe = true, .mutating = false },
    .{ .name = plan.spec_name, .description = plan.spec_description, .schema_json = plan.spec_schema, .parallel_safe = false, .mutating = false },
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
    payload_bytes: ?u64 = null,
    media: []MediaOutput = &.{},
    plan_items: ?[]block.PlanItem = null,

    pub fn deinit(self: ExecOut, gpa: std.mem.Allocator) void {
        gpa.free(self.output);
        for (self.media) |item| item.deinit(gpa);
        if (self.media.len > 0) gpa.free(self.media);
        if (self.plan_items) |items| {
            for (items) |item| gpa.free(@constCast(item.step));
            gpa.free(items);
        }
    }
};

pub const MediaOutput = struct {
    bytes: []u8,
    mime: []u8,
    name: []u8,

    pub fn deinit(self: MediaOutput, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        gpa.free(self.mime);
        gpa.free(self.name);
    }
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
    if (has_child_environ and sandbox_options.backend != .unavailable) {
        const temp_root = sandbox_options.temp_root orelse {
            return .{ .output = gpa.dupe(u8, "error: sandbox temp root unavailable") catch @panic("oom"), .status = .err };
        };
        configureSandboxEnvironment(gpa, io, &child_environ, temp_root) catch |e| {
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
        var payload_bytes: u64 = 0;
        var result = cancellableTextResult(fetch_tool.fetch(gpa, io, source_environ, parsed.value, policy, cancel, &payload_bytes), gpa);
        if (result.status == .ok) result.payload_bytes = payload_bytes;
        return result;
    }
    if (std.mem.eql(u8, name, plan.spec_name)) {
        const result = plan.run(gpa, args_json);
        return .{
            .output = result.output,
            .status = result.status,
            .plan_items = result.items,
        };
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
