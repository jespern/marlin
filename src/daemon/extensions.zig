//! Daemon-owned M5 extension runtime.
//!
//! Exec tools, MCP tools, and skills share one provider-facing spec list and
//! one dispatch entry point. The agent loop therefore applies the same
//! approval decision to built-ins and extensions before execution.

const std = @import("std");
const Io = std.Io;

const config = @import("../core/config.zig");
const block = @import("../core/block.zig");
const hooks = @import("hooks.zig");
const permissions = @import("permissions.zig");
const skills = @import("skills.zig");
const exec_tool = @import("tools/exec_tool.zig");
const mcp = @import("tools/mcp.zig");
const registry = @import("tools/registry.zig");

pub const Spec = registry.Spec;
pub const ExecOut = registry.ExecOut;

const Exec = struct {
    spec: Spec,
    argv: []const []const u8,
    timeout_ms: u32,
};

const Mcp = struct {
    server: *mcp.Server,
    mutating: bool,
};

const HookPaths = struct {
    on_session_done: ?[]const u8 = null,
    on_approval_needed: ?[]const u8 = null,
    on_error: ?[]const u8 = null,
    on_turn_done: ?[]const u8 = null,

    fn get(self: HookPaths, kind: hooks.Kind) ?[]const u8 {
        return switch (kind) {
            .on_session_done => self.on_session_done,
            .on_approval_needed => self.on_approval_needed,
            .on_error => self.on_error,
            .on_turn_done => self.on_turn_done,
        };
    }
};

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: Io,
    arena_state: *std.heap.ArenaAllocator,
    child_environ: *std.process.Environ.Map,
    specs_list: std.ArrayList(Spec) = .empty,
    exec_tools: std.ArrayList(Exec) = .empty,
    mcp_servers: std.ArrayList(Mcp) = .empty,
    skill_index: skills.Index,
    hook_paths: HookPaths,
    hook_mutex: Io.Mutex = .init,
    hook_threads: std.ArrayList(HookHandle) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        cfg: config.Config,
        environ: *const std.process.Environ.Map,
    ) !*Runtime {
        const self = try gpa.create(Runtime);
        errdefer gpa.destroy(self);
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena_state);
        arena_state.* = .init(gpa);
        errdefer arena_state.deinit();
        const child_environ = try gpa.create(std.process.Environ.Map);
        errdefer gpa.destroy(child_environ);
        child_environ.* = try permissions.toolEnvironment(gpa, environ);
        errdefer child_environ.deinit();

        const arena = arena_state.allocator();
        const directories = try expandPaths(arena, cfg.skill_directories, environ.get("HOME"));
        const skill_index = try skills.Index.load(gpa, io, directories);
        var skill_transferred = false;
        errdefer if (!skill_transferred) {
            var owned = skill_index;
            owned.deinit();
        };

        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena_state = arena_state,
            .child_environ = child_environ,
            .skill_index = skill_index,
            .hook_paths = .{
                .on_session_done = try expandPath(arena, cfg.hooks.on_session_done, environ.get("HOME")),
                .on_approval_needed = try expandPath(arena, cfg.hooks.on_approval_needed, environ.get("HOME")),
                .on_error = try expandPath(arena, cfg.hooks.on_error, environ.get("HOME")),
                .on_turn_done = try expandPath(arena, cfg.hooks.on_turn_done, environ.get("HOME")),
            },
        };
        skill_transferred = true;
        errdefer self.deinit();

        for (cfg.exec_tools) |tool| {
            if (registry.find(tool.name) != null or self.find(tool.name) != null or
                std.mem.eql(u8, tool.name, skills.spec_name))
            {
                return error.ExtensionToolNameConflict;
            }
            const argv = try expandPaths(arena, tool.cmd, environ.get("HOME"));
            const spec = Spec{
                .name = tool.name,
                .description = tool.description,
                .schema_json = tool.schema,
                .parallel_safe = tool.parallel_safe,
                .mutating = tool.mutating,
            };
            try self.exec_tools.append(gpa, .{ .spec = spec, .argv = argv, .timeout_ms = tool.timeout_ms });
            try self.specs_list.append(gpa, spec);
        }

        for (cfg.mcp_servers) |server_cfg| {
            const argv = try expandPaths(arena, server_cfg.cmd, environ.get("HOME"));
            const server = try mcp.Server.init(gpa, io, server_cfg.name, argv, child_environ);
            var server_transferred = false;
            errdefer if (!server_transferred) server.deinit();
            server.discover() catch |err| {
                std.log.err("MCP server '{s}' discovery failed: {t}", .{ server_cfg.name, err });
                return err;
            };
            try self.mcp_servers.append(gpa, .{ .server = server, .mutating = server_cfg.mutating });
            server_transferred = true;
            for (server.tools.items) |tool| {
                if (registry.find(tool.public_name) != null or self.find(tool.public_name) != null)
                    return error.ExtensionToolNameConflict;
                try self.specs_list.append(gpa, .{
                    .name = tool.public_name,
                    .description = tool.description,
                    .schema_json = tool.schema_json,
                    .parallel_safe = false,
                    .mutating = server_cfg.mutating,
                });
            }
        }

        if (self.skill_index.items.items.len > 0) {
            if (registry.find(skills.spec_name) != null or self.find(skills.spec_name) != null)
                return error.ExtensionToolNameConflict;
            try self.specs_list.append(gpa, .{
                .name = skills.spec_name,
                .description = skills.spec_description,
                .schema_json = skills.spec_schema,
                .parallel_safe = true,
                .mutating = false,
            });
        }
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.hook_mutex.lockUncancelable(self.io);
        const threads = self.hook_threads;
        self.hook_threads = .empty;
        self.hook_mutex.unlock(self.io);
        for (threads.items) |handle| {
            handle.thread.join();
            self.gpa.destroy(handle.done);
        }
        var owned_threads = threads;
        owned_threads.deinit(self.gpa);

        for (self.mcp_servers.items) |entry| entry.server.deinit();
        self.mcp_servers.deinit(self.gpa);
        self.exec_tools.deinit(self.gpa);
        self.specs_list.deinit(self.gpa);
        self.skill_index.deinit();
        self.child_environ.deinit();
        self.gpa.destroy(self.child_environ);
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
        self.gpa.destroy(self);
    }

    pub fn specs(self: *const Runtime) []const Spec {
        return self.specs_list.items;
    }

    pub fn systemPromptSuffix(self: *const Runtime) []const u8 {
        return self.skill_index.prompt;
    }

    pub fn find(self: *const Runtime, name: []const u8) ?*const Spec {
        for (self.specs_list.items) |*spec| {
            if (std.mem.eql(u8, spec.name, name)) return spec;
        }
        return null;
    }

    /// Null means the name is not an extension and the caller should try the
    /// built-in registry. A non-null result is always caller-owned.
    pub fn dispatch(
        self: *Runtime,
        name: []const u8,
        args_json: []const u8,
        cwd: []const u8,
        cancel: ?*const std.atomic.Value(bool),
    ) ?ExecOut {
        for (self.exec_tools.items) |entry| {
            if (!std.mem.eql(u8, entry.spec.name, name)) continue;
            const result = exec_tool.run(
                self.gpa,
                self.io,
                entry.argv,
                args_json,
                cwd,
                self.child_environ,
                entry.timeout_ms,
                cancel,
            );
            return .{ .output = result.output, .status = result.status };
        }
        if (std.mem.eql(u8, name, skills.spec_name) and self.skill_index.items.items.len > 0) {
            const output = self.skill_index.loadContent(self.gpa, args_json) catch |err|
                std.fmt.allocPrint(self.gpa, "error: skill load failed: {t}", .{err}) catch @panic("oom");
            return .{
                .output = output,
                .status = if (std.mem.startsWith(u8, output, "error:")) .err else .ok,
            };
        }
        for (self.mcp_servers.items) |entry| {
            if (entry.server.findPublicTool(name)) {
                const result = entry.server.call(name, args_json);
                return .{ .output = result.output, .status = result.status };
            }
        }
        return null;
    }

    /// Queue a non-fatal hook outside the dispatcher/turn critical path.
    pub fn fireHook(self: *Runtime, kind: hooks.Kind, payload_json: []const u8) void {
        const script = self.hook_paths.get(kind) orelse return;
        const job = self.gpa.create(HookJob) catch return;
        job.* = .{
            .runtime = self,
            .kind = kind,
            .script = script,
            .payload = self.gpa.dupe(u8, payload_json) catch {
                self.gpa.destroy(job);
                return;
            },
        };

        self.hook_mutex.lockUncancelable(self.io);
        defer self.hook_mutex.unlock(self.io);
        self.reapCompletedHooks();
        self.hook_threads.ensureUnusedCapacity(self.gpa, 1) catch {
            self.gpa.free(job.payload);
            self.gpa.destroy(job);
            return;
        };
        const done = self.gpa.create(std.atomic.Value(bool)) catch {
            self.gpa.free(job.payload);
            self.gpa.destroy(job);
            return;
        };
        done.* = .init(false);
        job.done = done;
        const thread = std.Thread.spawn(.{}, HookJob.run, .{job}) catch {
            self.gpa.destroy(done);
            self.gpa.free(job.payload);
            self.gpa.destroy(job);
            return;
        };
        self.hook_threads.appendAssumeCapacity(.{ .thread = thread, .done = done });
    }

    /// Join finished threads as hooks are scheduled so a long-lived daemon
    /// retains handles only for currently active work (plus the latest job).
    /// Caller holds hook_mutex.
    fn reapCompletedHooks(self: *Runtime) void {
        var i: usize = 0;
        while (i < self.hook_threads.items.len) {
            const handle = self.hook_threads.items[i];
            if (!handle.done.load(.acquire)) {
                i += 1;
                continue;
            }
            handle.thread.join();
            self.gpa.destroy(handle.done);
            _ = self.hook_threads.orderedRemove(i);
        }
    }
};

const HookHandle = struct {
    thread: std.Thread,
    done: *std.atomic.Value(bool),
};

const HookJob = struct {
    runtime: *Runtime,
    kind: hooks.Kind,
    script: []const u8,
    payload: []u8,
    done: *std.atomic.Value(bool) = undefined,

    fn run(job: *HookJob) void {
        const runtime = job.runtime;
        defer {
            runtime.gpa.free(job.payload);
            job.done.store(true, .release);
            runtime.gpa.destroy(job);
        }
        hooks.fire(runtime.gpa, runtime.io, job.script, job.kind, job.payload, runtime.child_environ) catch |err| {
            std.log.warn("hook {s} did not complete: {t}", .{ @tagName(job.kind), err });
        };
    }
};

fn expandPaths(
    arena: std.mem.Allocator,
    paths: []const []const u8,
    home: ?[]const u8,
) ![]const []const u8 {
    const out = try arena.alloc([]const u8, paths.len);
    for (paths, 0..) |path, i| out[i] = (try expandPath(arena, path, home)).?;
    return out;
}

fn expandPath(arena: std.mem.Allocator, path: ?[]const u8, home: ?[]const u8) !?[]const u8 {
    const value = path orelse return null;
    if (!std.mem.startsWith(u8, value, "~/")) return value;
    const root = home orelse return error.NoHomeForTildePath;
    return try std.fs.path.join(arena, &.{ root, value[2..] });
}

test "runtime registers and dispatches exec tools and skills" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-extension");
    defer temp.deinit();
    const root = temp.path;
    const skill_path = try std.fs.path.join(gpa, &.{ root, "demo.md" });
    defer gpa.free(skill_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = skill_path, .data =
        \\---
        \\name: demo
        \\description: Demonstrate runtime skills
        \\---
        \\Follow the demo instructions.
    });

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");
    const cfg = config.Config{
        .skill_directories = &.{root},
        .exec_tools = &.{.{
            .name = "echo_json",
            .cmd = &.{ "sh", "-c", "cat" },
            .description = "Echo JSON",
            .schema = "{\"type\":\"object\"}",
            .mutating = false,
            .parallel_safe = true,
            .timeout_ms = 2_000,
        }},
    };
    const runtime = try Runtime.init(gpa, io, cfg, &environ);
    defer runtime.deinit();
    try std.testing.expect(runtime.find("echo_json") != null);
    try std.testing.expect(runtime.find("skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.systemPromptSuffix(), "demo: Demonstrate") != null);
    const result = runtime.dispatch("echo_json", "{\"ok\":true}", "/tmp", null).?;
    defer gpa.free(result.output);
    try std.testing.expectEqual(block.ToolStatus.ok, result.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", result.output);
}
