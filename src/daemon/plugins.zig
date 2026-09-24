//! Skill-only Claude marketplace importer. Registry writes switch immutable
//! snapshots atomically; running turns can keep reading their old resources.
const std = @import("std");
const Io = std.Io;
const skills = @import("skills.zig");
const process_io = @import("process_io.zig");
pub const Command = @import("../core/plugin_command.zig").Command;

const Marketplace = struct { name: []const u8, source: []const u8, snapshot: []const u8 };
const Installed = struct { name: []const u8, marketplace: []const u8, snapshot: []const u8, path: []const u8, version: []const u8 };
const State = struct { version: u32 = 1, marketplaces: []Marketplace = &.{}, installed: []Installed = &.{} };
const Catalog = struct { name: []const u8, entries: []std.json.Value };
const Plugin = struct { name: []const u8, path: []const u8, version: []const u8 };

pub fn rootPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const config_dir = try @import("../core/credentials.zig").configDir(gpa, environ);
    defer gpa.free(config_dir);
    return std.fs.path.join(gpa, &.{ config_dir, "plugins" });
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

fn relativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\\\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn readJson(arena: std.mem.Allocator, io: Io, path: []const u8) !std.json.Value {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .allocate = .alloc_always });
}

fn string(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const value = obj.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn readState(arena: std.mem.Allocator, io: Io, root: []const u8) !State {
    const path = try std.fs.path.join(arena, &.{ root, "registry.json" });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const state = try std.json.parseFromSliceLeaky(State, arena, bytes, .{ .allocate = .alloc_always });
    if (state.version != 1 or state.marketplaces.len > 100 or state.installed.len > 500) return error.InvalidPluginRegistry;
    for (state.marketplaces) |market| if (!validName(market.name) or !validName(market.snapshot)) return error.InvalidPluginRegistry;
    for (state.installed) |entry| {
        if (!validName(entry.name) or !validName(entry.marketplace) or !validName(entry.snapshot) or !relativePath(entry.path)) return error.InvalidPluginRegistry;
    }
    return state;
}

fn saveState(arena: std.mem.Allocator, io: Io, root: []const u8, state: State) !void {
    const path = try std.fs.path.join(arena, &.{ root, "registry.json" });
    const bytes = try std.json.Stringify.valueAlloc(arena, state, .{ .whitespace = .indent_2 });
    var file = try Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    try file.replace(io);
}

fn inside(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/');
}

fn contained(arena: std.mem.Allocator, io: Io, root: []const u8, relative: []const u8) ![]const u8 {
    if (!relativePath(relative)) return error.UnsafePluginPath;
    const canonical_root = try Io.Dir.cwd().realPathFileAlloc(io, root, arena);
    const path = try Io.Dir.cwd().realPathFileAlloc(io, try std.fs.path.join(arena, &.{ root, relative }), arena);
    if (!inside(canonical_root, path)) return error.UnsafePluginPath;
    return path;
}

fn catalog(arena: std.mem.Allocator, io: Io, checkout: []const u8) !Catalog {
    const manifest_path = try contained(arena, io, checkout, ".claude-plugin/marketplace.json");
    const manifest = try readJson(arena, io, manifest_path);
    const name = string(manifest, "name") orelse return error.InvalidMarketplace;
    if (!validName(name)) return error.InvalidMarketplace;
    const entries = manifest.object.get("plugins") orelse return error.InvalidMarketplace;
    if (entries != .array or entries.array.items.len > 500) return error.InvalidMarketplace;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (entries.array.items) |entry| {
        const entry_name = string(entry, "name") orelse return error.InvalidMarketplace;
        if (!validName(entry_name)) return error.InvalidMarketplace;
        const slot = try seen.getOrPut(arena, entry_name);
        if (slot.found_existing) return error.DuplicatePluginName;
    }
    return .{ .name = name, .entries = entries.array.items };
}

fn skillOnlyManifest(manifest: std.json.Value) !void {
    if (manifest != .object) return error.InvalidPluginManifest;
    // Explicitly reject semantic features we don't implement, including
    // custom paths, rather than accepting a partially installed plugin.
    var it = manifest.object.iterator();
    while (it.next()) |entry| {
        const allowed = [_][]const u8{ "name", "version", "description", "author", "homepage", "repository", "license", "keywords", "source", "category", "tags" };
        for (allowed) |key| {
            if (std.mem.eql(u8, key, entry.key_ptr.*)) break;
        } else return error.UnsupportedPluginComponent;
    }
}

fn inspectPlugin(arena: std.mem.Allocator, io: Io, checkout: []const u8, cat: Catalog, name: []const u8) !Plugin {
    const entry = for (cat.entries) |candidate| {
        if (std.mem.eql(u8, string(candidate, "name").?, name)) break candidate;
    } else return error.UnknownPlugin;
    try skillOnlyManifest(entry);
    const relative = string(entry, "source") orelse return error.UnsupportedPluginSource;
    const path = try contained(arena, io, checkout, relative);
    const manifest = try readJson(arena, io, try contained(arena, io, path, ".claude-plugin/plugin.json"));
    try skillOnlyManifest(manifest);
    if (!std.mem.eql(u8, string(manifest, "name") orelse return error.InvalidPluginManifest, name)) return error.PluginNameMismatch;
    const version = string(manifest, "version") orelse string(entry, "version") orelse "unversioned";
    // Check conventional components even when omitted from plugin.json.
    const unsupported = [_][]const u8{ "hooks", "agents", "commands", ".mcp.json", ".lsp.json", "settings.json", "output-styles", "scripts", "bin" };
    for (unsupported) |component| {
        const target = try std.fs.path.join(arena, &.{ path, component });
        Io.Dir.cwd().access(io, target, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return error.UnsupportedPluginComponent;
    }
    const skill_dir = try contained(arena, io, path, "skills");
    // Every resource must stay in the plugin, including symlink targets.
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var entries: usize = 0;
    while (try walker.next(io)) |file| {
        entries += 1;
        if (entries > 10000) return error.PluginTooLarge;
        if (file.kind == .sym_link) _ = try contained(arena, io, path, file.path);
        if (file.kind != .file and file.kind != .directory and file.kind != .sym_link) return error.UnsupportedPluginComponent;
    }
    var index = try skills.Index.load(arena, io, &.{skill_dir});
    defer index.deinit();
    if (index.items.items.len == 0) return error.NoUsableSkills;
    return .{ .name = name, .path = relative, .version = version };
}

fn sourceUrl(arena: std.mem.Allocator, source: []const u8, cwd: []const u8) ![]const u8 {
    if (source.len == 0 or std.mem.indexOfAny(u8, source, "\r\n\x00") != null or source[0] == '-') return error.InvalidMarketplaceSource;
    if (std.fs.path.isAbsolute(source)) return arena.dupe(u8, source);
    if (std.mem.startsWith(u8, source, "./") or std.mem.startsWith(u8, source, "../"))
        return std.fs.path.resolve(arena, &.{ cwd, source });
    if (std.mem.startsWith(u8, source, "https://") and std.mem.indexOfScalar(u8, source, '@') == null) return arena.dupe(u8, source);
    if (std.mem.startsWith(u8, source, "git@") and std.mem.indexOfScalar(u8, source, ':') != null) return arena.dupe(u8, source);
    var parts = std.mem.splitScalar(u8, source, '/');
    const owner = parts.next() orelse return error.InvalidMarketplaceSource;
    const repo = parts.next() orelse return error.InvalidMarketplaceSource;
    if (parts.next() != null or !validName(owner) or repo.len == 0 or repo[0] == '.') return error.InvalidMarketplaceSource;
    for (repo) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return error.InvalidMarketplaceSource;
    return std.fmt.allocPrint(arena, "https://github.com/{s}/{s}.git", .{ owner, repo });
}

const Manager = struct {
    arena: std.mem.Allocator,
    io: Io,
    root: []const u8,
    environ: *const std.process.Environ.Map,
    cancel: ?*const std.atomic.Value(bool),
    detail: ?[]const u8 = null,

    fn checkout(self: *Manager, source: []const u8) ![]const u8 {
        var random: [16]u8 = undefined;
        self.io.random(&random);
        const id = try std.fmt.allocPrint(self.arena, "{x}", .{random});
        const path = try std.fs.path.join(self.arena, &.{ self.root, "snapshots", id });
        try Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(path).?);
        errdefer Io.Dir.cwd().deleteTree(self.io, path) catch {};
        var env = try self.environ.clone(self.arena);
        defer env.deinit();
        for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES" }) |key| _ = env.swapRemove(key);
        try env.put("GIT_TERMINAL_PROMPT", "0");
        const result = try process_io.run(self.arena, self.io, .{
            .argv = &.{ "git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "clone", "--depth", "1", "--no-local", "--no-recurse-submodules", "--", source, path },
            .environ_map = &env,
            .timeout_ms = 60_000,
            .cancel = self.cancel,
            .stdout_limit = 64 * 1024,
            .stderr_limit = 64 * 1024,
        });
        if (result.timed_out) return error.GitTimedOut;
        if (result.term != .exited or result.term.exited != 0) {
            self.detail = std.mem.trim(u8, result.stderr, " \t\r\n");
            return error.GitFailed;
        }
        return id;
    }

    fn execute(self: *Manager, command: Command, cwd: []const u8) ![]const u8 {
        const a = self.arena;
        var state = try readState(a, self.io, self.root);
        const arg = command.argument;
        switch (command.action) {
            .list => {
                var out: std.ArrayList(u8) = .empty;
                for (state.marketplaces) |market| try out.print(a, "Marketplace {s} — {s}\n", .{ market.name, market.source });
                for (state.installed) |entry| try out.print(a, "Installed {s}@{s} ({s}) — /{s}:<skill>\n", .{ entry.name, entry.marketplace, entry.version, entry.name });
                if (out.items.len == 0) try out.appendSlice(a, "No plugins or marketplaces. Use /plugin marketplace add <owner/repo>.");
                return out.toOwnedSlice(a);
            },
            .marketplace_add, .marketplace_update => {
                var current: ?usize = null;
                const source = if (command.action == .marketplace_update) blk: {
                    for (state.marketplaces, 0..) |market, i| if (std.mem.eql(u8, market.name, arg)) {
                        current = i;
                        break :blk market.source;
                    };
                    return error.UnknownMarketplace;
                } else try sourceUrl(a, arg, cwd);
                const snapshot = try self.checkout(source);
                const path = try std.fs.path.join(a, &.{ self.root, "snapshots", snapshot });
                errdefer Io.Dir.cwd().deleteTree(self.io, path) catch {};
                const cat = try catalog(a, self.io, path);
                if (current) |i| {
                    if (!std.mem.eql(u8, cat.name, state.marketplaces[i].name)) return error.MarketplaceNameChanged;
                } else {
                    for (state.marketplaces) |market| if (std.mem.eql(u8, market.name, cat.name)) return error.MarketplaceAlreadyExists;
                    if (state.marketplaces.len >= 100) return error.TooManyMarketplaces;
                }
                for (state.installed) |*entry| {
                    if (!std.mem.eql(u8, entry.marketplace, cat.name)) continue;
                    const plugin = try inspectPlugin(a, self.io, path, cat, entry.name);
                    entry.snapshot = snapshot;
                    entry.path = plugin.path;
                    entry.version = plugin.version;
                }
                const market = Marketplace{ .name = cat.name, .source = source, .snapshot = snapshot };
                if (current) |i| state.marketplaces[i] = market else {
                    const extended = try a.alloc(Marketplace, state.marketplaces.len + 1);
                    @memcpy(extended[0..state.marketplaces.len], state.marketplaces);
                    extended[state.marketplaces.len] = market;
                    state.marketplaces = extended;
                }
                try saveState(a, self.io, self.root, state);
                var out: std.ArrayList(u8) = .empty;
                try out.print(a, "{s} marketplace {s}. Available plugins:", .{ if (current == null) "Added" else "Updated", cat.name });
                for (cat.entries) |entry| try out.print(a, "\n  {s}@{s}", .{ string(entry, "name").?, cat.name });
                return out.toOwnedSlice(a);
            },
            .marketplace_remove => {
                for (state.installed) |entry| if (std.mem.eql(u8, entry.marketplace, arg)) return error.MarketplaceInUse;
                for (state.marketplaces, 0..) |market, i| if (std.mem.eql(u8, market.name, arg)) {
                    std.mem.copyForwards(Marketplace, state.marketplaces[i..], state.marketplaces[i + 1 ..]);
                    state.marketplaces = state.marketplaces[0 .. state.marketplaces.len - 1];
                    try saveState(a, self.io, self.root, state);
                    return std.fmt.allocPrint(a, "Removed marketplace {s}.", .{arg});
                };
                return error.UnknownMarketplace;
            },
            .install, .uninstall => {
                const at = std.mem.indexOfScalar(u8, arg, '@') orelse return error.ExpectedPluginAtMarketplace;
                const name = arg[0..at];
                const market_name = arg[at + 1 ..];
                if (!validName(name) or !validName(market_name)) return error.ExpectedPluginAtMarketplace;
                for (state.installed, 0..) |entry, i| {
                    if (!std.mem.eql(u8, entry.name, name)) continue;
                    if (!std.mem.eql(u8, entry.marketplace, market_name)) return error.PluginNamespaceConflict;
                    if (command.action == .install) return std.fmt.allocPrint(a, "{s} is already installed.", .{arg});
                    std.mem.copyForwards(Installed, state.installed[i..], state.installed[i + 1 ..]);
                    state.installed = state.installed[0 .. state.installed.len - 1];
                    try saveState(a, self.io, self.root, state);
                    return std.fmt.allocPrint(a, "Uninstalled {s}. New turns will no longer see its skills.", .{arg});
                }
                if (command.action == .uninstall) return error.PluginNotInstalled;
                if (state.installed.len >= 500) return error.TooManyPlugins;
                const market = for (state.marketplaces) |market| {
                    if (std.mem.eql(u8, market.name, market_name)) break market;
                } else return error.UnknownMarketplace;
                const path = try std.fs.path.join(a, &.{ self.root, "snapshots", market.snapshot });
                const cat = try catalog(a, self.io, path);
                const plugin = try inspectPlugin(a, self.io, path, cat, name);
                const extended = try a.alloc(Installed, state.installed.len + 1);
                @memcpy(extended[0..state.installed.len], state.installed);
                extended[state.installed.len] = .{ .name = name, .marketplace = market_name, .snapshot = market.snapshot, .path = plugin.path, .version = plugin.version };
                state.installed = extended;
                try saveState(a, self.io, self.root, state);
                return std.fmt.allocPrint(a, "Installed {s} ({s}). Invoke /{s}:<skill>; native agents discover its skills on the next turn.", .{ arg, plugin.version, name });
            },
        }
    }
};

pub const Result = struct { ok: bool, message: []u8 };

pub fn run(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, root: []const u8, cwd: []const u8, command: Command, cancel: ?*const std.atomic.Value(bool)) !Result {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var manager = Manager{ .arena = a, .io = io, .root = root, .environ = environ, .cancel = cancel };
    const message = manager.execute(command, cwd) catch |err| {
        const why = switch (err) {
            error.UnsupportedPluginComponent => "Only skill-only plugins with the standard skills/ layout are supported; hooks, MCP/LSP servers, agents, commands and custom manifest components are not installed.",
            error.UnsupportedPluginSource => "Only plugin sources that are relative paths inside the marketplace repository are supported.",
            error.MarketplaceInUse => "Uninstall this marketplace's plugins before removing it.",
            error.PluginNamespaceConflict => "A plugin with this name is installed from another marketplace; uninstall it first.",
            error.GitFailed => manager.detail orelse "Git failed; check repository access and your Git credentials.",
            else => @errorName(err),
        };
        return .{ .ok = false, .message = try std.fmt.allocPrint(gpa, "Plugin command failed: {s}", .{why}) };
    };
    return .{ .ok = true, .message = try gpa.dupe(u8, message) };
}

pub fn loadSkills(index: *skills.Index, io: Io, root: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(index.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const state = try readState(a, io, root);
    for (state.installed) |entry| {
        const checkout = try std.fs.path.join(a, &.{ root, "snapshots", entry.snapshot });
        const plugin = try contained(a, io, checkout, entry.path);
        const directory = try contained(a, io, plugin, "skills");
        var loaded = try skills.Index.load(index.gpa, io, &.{directory});
        defer loaded.deinit();
        try index.merge(&loaded, entry.name);
    }
}
