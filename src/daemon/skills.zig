//! Agent Skills: bounded discovery of SKILL.md bundles, a compact catalog,
//! and full instructions plus resource paths on activation.
const std = @import("std");
const Io = std.Io;
const yaml = @cImport({
    @cDefine("YAML_DECLARE_STATIC", "1");
    @cInclude("yaml.h");
});

pub const spec_name = "skill";
pub const spec_description = "Load the full instructions and resource directory for one available skill by name.";
pub const spec_schema =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Skill name from the system-prompt index"}},"required":["name"]}
;

pub const Skill = struct {
    name: []u8,
    description: []u8,
    content: []u8,
    frontmatter: []u8,
    path: []u8,

    fn deinit(self: *Skill, gpa: std.mem.Allocator) void {
        inline for (std.meta.fields(Skill)) |field| gpa.free(@field(self, field.name));
    }

    fn clone(self: Skill, gpa: std.mem.Allocator) !Skill {
        var copy: Skill = undefined;
        var initialized: usize = 0;
        errdefer inline for (std.meta.fields(Skill), 0..) |field, i| {
            if (i < initialized) gpa.free(@field(copy, field.name));
        };
        inline for (std.meta.fields(Skill)) |field| {
            @field(copy, field.name) = try gpa.dupe(u8, @field(self, field.name));
            initialized += 1;
        }
        return copy;
    }
};

pub const Index = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Skill) = .empty,
    prompt: []u8,
    schema_json: []u8,
    plugin_root: ?[]u8 = null,

    /// Directory order is precedence order: the first skill with a name wins.
    pub fn load(gpa: std.mem.Allocator, io: Io, directories: []const []const u8) !Index {
        var self = try empty(gpa);
        errdefer self.deinit();
        var scan = Scan{ .index = &self, .io = io };
        defer scan.deinit();
        for (directories) |directory| try scan.directory(directory, 0);
        try self.finish();
        return self;
    }

    /// Project catalogs are turn-local: concurrent sessions in different
    /// directories never change one another's available skills.
    pub fn forProject(self: *const Index, io: Io, cwd: []const u8) !Index {
        const native = try std.fs.path.join(self.gpa, &.{ cwd, ".marlin", "skills" });
        defer self.gpa.free(native);
        const shared = try std.fs.path.join(self.gpa, &.{ cwd, ".agents", "skills" });
        defer self.gpa.free(shared);
        var result = try Index.load(self.gpa, io, &.{ native, shared });
        errdefer result.deinit();
        try result.merge(self, null);
        if (self.plugin_root) |root| try @import("plugins.zig").loadSkills(&result, io, root);
        try result.finish();
        return result;
    }

    pub fn merge(self: *Index, other: *const Index, namespace: ?[]const u8) !void {
        for (other.items.items) |skill| {
            const name = if (namespace) |prefix|
                try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ prefix, skill.name })
            else
                try self.gpa.dupe(u8, skill.name);
            defer self.gpa.free(name);
            if (self.get(name)) |existing| {
                if (!std.mem.eql(u8, existing.path, skill.path))
                    std.log.warn("skill '{s}' at {s} shadows {s}", .{ name, existing.path, skill.path });
                continue;
            }
            var copy = try skill.clone(self.gpa);
            errdefer copy.deinit(self.gpa);
            const owned_name = try self.gpa.dupe(u8, name);
            self.gpa.free(copy.name);
            copy.name = owned_name;
            try self.items.append(self.gpa, copy);
        }
    }

    fn empty(gpa: std.mem.Allocator) !Index {
        const prompt = try gpa.dupe(u8, "");
        errdefer gpa.free(prompt);
        return .{ .gpa = gpa, .prompt = prompt, .schema_json = try gpa.dupe(u8, spec_schema) };
    }

    fn finish(self: *Index) !void {
        std.mem.sort(Skill, self.items.items, {}, lessThan);
        const prompt = try self.buildPrompt();
        errdefer self.gpa.free(prompt);
        const names = try self.gpa.alloc([]const u8, self.items.items.len);
        defer self.gpa.free(names);
        for (self.items.items, names) |skill, *name| name.* = skill.name;
        const schema = try std.json.Stringify.valueAlloc(self.gpa, .{
            .type = "object",
            .properties = .{ .name = .{ .type = "string", .@"enum" = names } },
            .required = [_][]const u8{"name"},
        }, .{});
        self.gpa.free(self.prompt);
        self.gpa.free(self.schema_json);
        self.prompt = prompt;
        self.schema_json = schema;
    }

    pub fn deinit(self: *Index) void {
        for (self.items.items) |*skill| skill.deinit(self.gpa);
        self.items.deinit(self.gpa);
        self.gpa.free(self.prompt);
        self.gpa.free(self.schema_json);
        if (self.plugin_root) |root| self.gpa.free(root);
    }

    pub fn get(self: *const Index, name: []const u8) ?*const Skill {
        for (self.items.items) |*skill| {
            if (std.mem.eql(u8, skill.name, name)) return skill;
        }
        return null;
    }

    pub fn spec(self: *const Index) @import("tools/registry.zig").Spec {
        return .{ .name = spec_name, .description = spec_description, .schema_json = self.schema_json, .parallel_safe = true, .mutating = false };
    }

    pub fn loadContent(self: *const Index, gpa: std.mem.Allocator, args_json: []const u8) ![]u8 {
        const Args = struct { name: []const u8 };
        const parsed = std.json.parseFromSlice(Args, gpa, args_json, .{ .ignore_unknown_fields = true }) catch
            return gpa.dupe(u8, "error: skill arguments must contain a string 'name'");
        defer parsed.deinit();
        const skill = self.get(parsed.value.name) orelse
            return std.fmt.allocPrint(gpa, "error: unknown skill '{s}'", .{parsed.value.name});
        // Model-driven activation must not substitute shell variables in
        // instructions. Argument templates are only a slash-command feature.
        return wrap(gpa, skill, skill.content);
    }

    pub fn renderInvocation(self: *const Index, gpa: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]u8 {
        const skill = self.get(name) orelse return error.UnknownSkill;
        const rendered = try renderArguments(gpa, skill.content, arguments);
        defer gpa.free(rendered);
        return wrap(gpa, skill, rendered);
    }

    fn wrap(gpa: std.mem.Allocator, skill: *const Skill, content: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "Skill: {s}\nSource: {s}\nBase directory for relative skill resources: {s}\n" ++
            "Resolve relative references, scripts and assets against this directory; read resources as needed. " ++
            "Skill metadata does not grant tool permissions; normal approval rules apply.\n\n---\n{s}---\n{s}", .{ skill.name, skill.path, std.fs.path.dirname(skill.path) orelse ".", skill.frontmatter, content });
    }

    fn buildPrompt(self: *const Index) ![]u8 {
        if (self.items.items.len == 0) return self.gpa.dupe(u8, "");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.appendSlice(self.gpa,
            \\
            \\AVAILABLE SKILLS
            \\When a task matches a skill's description, load it with the `skill` tool before proceeding.
            \\Load referenced resources only as needed, relative to the returned skill directory.
            \\If earlier skill instructions were compacted away, load the skill again before using it.
        );
        for (self.items.items) |skill| {
            try out.print(self.gpa, "\n- {s}: ", .{skill.name});
            // Multiline YAML descriptions stay one catalog entry.
            for (skill.description) |ch| try out.append(self.gpa, if (std.ascii.isWhitespace(ch)) ' ' else ch);
        }
        try out.append(self.gpa, '\n');
        return out.toOwnedSlice(self.gpa);
    }
};

const Scan = struct {
    index: *Index,
    io: Io,
    visited: std.StringHashMapUnmanaged([:0]u8) = .empty,
    remaining_entries: usize = 10000,

    fn deinit(self: *Scan) void {
        var paths = self.visited.valueIterator();
        while (paths.next()) |path| self.index.gpa.free(path.*);
        self.visited.deinit(self.index.gpa);
    }

    fn directory(self: *Scan, path: []const u8, depth: usize) anyerror!void {
        if (depth > 6 or self.visited.count() >= 2000 or self.remaining_entries == 0) return;
        const gpa = self.index.gpa;
        var dir = Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => {
                std.log.warn("cannot scan skills at {s}: {t}", .{ path, err });
                return;
            },
        };
        defer dir.close(self.io);
        const canonical = try Io.Dir.cwd().realPathFileAlloc(self.io, path, gpa);
        if (self.visited.contains(canonical)) {
            gpa.free(canonical);
            return;
        }
        self.visited.put(gpa, canonical, canonical) catch |err| {
            gpa.free(canonical);
            return err;
        };
        // A bundle is a leaf. References/assets inside it are never skills,
        // even if a bundled document has frontmatter or is named SKILL.md.
        const skill_path = try std.fs.path.join(gpa, &.{ canonical, "SKILL.md" });
        defer gpa.free(skill_path);
        if (try self.file(skill_path)) return;

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| gpa.free(name);
            names.deinit(gpa);
        }
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (self.remaining_entries == 0) break;
            self.remaining_entries -= 1;
            if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, "node_modules") or
                std.mem.eql(u8, entry.name, "__pycache__")) continue;
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);
            try names.append(gpa, name);
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |name| {
            const child = try std.fs.path.join(gpa, &.{ canonical, name });
            defer gpa.free(child);
            // Preserve old flat-file installs at a configured root. Files
            // elsewhere must be SKILL.md, not arbitrary Markdown resources.
            if (depth == 0 and std.mem.endsWith(u8, name, ".md") and !std.mem.eql(u8, name, "README.md")) {
                _ = try self.file(child);
            } else try self.directory(child, depth + 1);
        }
    }

    /// Returns true if the file exists, even when its metadata is invalid.
    fn file(self: *Scan, path: []const u8) !bool {
        const gpa = self.index.gpa;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound, error.IsDir => return false,
            error.OutOfMemory => return err,
            else => {
                std.log.warn("cannot load skill {s}: {t}", .{ path, err });
                return true;
            },
        };
        defer gpa.free(bytes);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const parsed = parseFrontmatter(arena_state.allocator(), bytes) catch |err| {
            if (err == error.OutOfMemory) return err;
            std.log.warn("skipping skill {s}: {t}", .{ path, err });
            return true;
        };
        if (self.index.get(parsed.name)) |existing| {
            if (!std.mem.eql(u8, path, existing.path))
                std.log.warn("skill '{s}' at {s} shadows {s}", .{ parsed.name, existing.path, path });
            return true;
        }
        if (std.mem.eql(u8, std.fs.path.basename(path), "SKILL.md") and
            !std.mem.eql(u8, parsed.name, std.fs.path.basename(std.fs.path.dirname(path).?)))
            std.log.warn("skill name '{s}' does not match its directory: {s}", .{ parsed.name, path });
        const borrowed = Skill{ .name = @constCast(parsed.name), .description = @constCast(parsed.description), .content = @constCast(parsed.content), .frontmatter = @constCast(parsed.frontmatter), .path = @constCast(path) };
        var skill = try borrowed.clone(gpa);
        errdefer skill.deinit(gpa);
        try self.index.items.append(gpa, skill);
        return true;
    }
};

/// Substitute arguments once, never treating user arguments as templates or
/// executing shell snippets from a skill. Positional arguments are zero-based.
pub fn renderArguments(gpa: std.mem.Allocator, content: []const u8, arguments: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var positional: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var started = false;
    var arg_i: usize = 0;
    while (arg_i < arguments.len) : (arg_i += 1) {
        const ch = arguments[arg_i];
        if (ch == '\\' and quote != '\'' and arg_i + 1 < arguments.len) {
            arg_i += 1;
            try word.append(arena, arguments[arg_i]);
            started = true;
        } else if (quote) |q| {
            if (ch == q) quote = null else try word.append(arena, ch);
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
            started = true;
        } else if (std.ascii.isWhitespace(ch)) {
            if (started) try positional.append(arena, try arena.dupe(u8, word.items));
            word.clearRetainingCapacity();
            started = false;
        } else {
            try word.append(arena, ch);
            started = true;
        }
    }
    if (started) try positional.append(arena, word.items);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var substituted = false;
    var i: usize = 0;
    while (i < content.len) {
        var end = i;
        var replacement: ?[]const u8 = null;
        if (std.mem.startsWith(u8, content[i..], "$ARGUMENTS")) {
            end = i + "$ARGUMENTS".len;
            if (end < content.len and content[end] == '[') {
                const digits_start = end + 1;
                end = digits_start;
                while (end < content.len and std.ascii.isDigit(content[end])) : (end += 1) {}
                if (end > digits_start and end < content.len and content[end] == ']') {
                    const n = std.fmt.parseInt(usize, content[digits_start..end], 10) catch std.math.maxInt(usize);
                    replacement = if (n < positional.items.len) positional.items[n] else "";
                    end += 1;
                }
            } else if (end == content.len or (!std.ascii.isAlphanumeric(content[end]) and content[end] != '_')) {
                replacement = arguments;
            }
        } else if (content[i] == '$') {
            end = i + 1;
            while (end < content.len and std.ascii.isDigit(content[end])) : (end += 1) {}
            if (end > i + 1) {
                const n = std.fmt.parseInt(usize, content[i + 1 .. end], 10) catch std.math.maxInt(usize);
                replacement = if (n < positional.items.len) positional.items[n] else "";
            }
        }
        if (replacement) |value| {
            if (out.items.len + value.len > 1024 * 1024) return error.SkillTooLarge;
            try out.appendSlice(gpa, value);
            substituted = true;
            i = end;
        } else {
            if (out.items.len == 1024 * 1024) return error.SkillTooLarge;
            try out.append(gpa, content[i]);
            i += 1;
        }
    }
    if (!substituted and arguments.len > 0) {
        if (out.items.len + arguments.len + 13 > 1024 * 1024) return error.SkillTooLarge;
        try out.print(gpa, "\n\nARGUMENTS: {s}", .{arguments});
    }
    return out.toOwnedSlice(gpa);
}

pub const ParsedFrontmatter = struct {
    name: []const u8,
    description: []const u8,
    content: []const u8,
    frontmatter: []const u8,
};

/// Names/descriptions are allocated in the caller's arena. The body and raw
/// metadata borrow bytes. LibYAML handles quoting, block scalars, Unicode,
/// comments and nested/flow mappings without evaluating tags or constructors.
pub fn parseFrontmatter(arena: std.mem.Allocator, bytes: []const u8) !ParsedFrontmatter {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = lines.next() orelse return error.MissingFrontmatter;
    const first_text = if (std.mem.startsWith(u8, first, "\xef\xbb\xbf")) first[3..] else first;
    if (!std.mem.eql(u8, std.mem.trim(u8, first_text, " \t\r"), "---")) return error.MissingFrontmatter;
    const yaml_start = first.len + 1;
    var consumed = yaml_start;
    var yaml_end: ?usize = null;
    var content_start: usize = bytes.len;
    while (lines.next()) |raw_line| {
        if (consumed - yaml_start > 64 * 1024) return error.FrontmatterTooLarge;
        // An indented --- can be part of a literal scalar, never a delimiter.
        if (std.mem.eql(u8, std.mem.trimEnd(u8, raw_line, " \t\r"), "---")) {
            yaml_end = consumed;
            content_start = @min(consumed + raw_line.len + 1, bytes.len);
            break;
        }
        consumed += raw_line.len + 1;
    }
    const frontmatter = bytes[yaml_start .. yaml_end orelse return error.UnclosedFrontmatter];
    if (frontmatter.len > 64 * 1024) return error.FrontmatterTooLarge;
    var parser: yaml.yaml_parser_t = undefined;
    if (yaml.yaml_parser_initialize(&parser) == 0) return error.OutOfMemory;
    defer yaml.yaml_parser_delete(&parser);
    yaml.yaml_parser_set_input_string(&parser, frontmatter.ptr, frontmatter.len);
    var doc: yaml.yaml_document_t = undefined;
    if (yaml.yaml_parser_load(&parser, &doc) == 0) return error.InvalidYaml;
    defer yaml.yaml_document_delete(&doc);
    const root = yaml.yaml_document_get_root_node(&doc);
    if (root == null or root.*.type != yaml.YAML_MAPPING_NODE) return error.InvalidSkillMetadata;
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var pair = root.*.data.mapping.pairs.start;
    while (pair != root.*.data.mapping.pairs.top) : (pair += 1) {
        const key = try yamlScalar(&doc, pair.*.key);
        const entry = try seen.getOrPut(arena, key);
        if (entry.found_existing) return error.DuplicateMetadataKey;
        const value_id = pair.*.value;
        if (std.mem.eql(u8, key, "name")) {
            name = try arena.dupe(u8, try yamlScalar(&doc, value_id));
        } else if (std.mem.eql(u8, key, "description")) {
            description = try arena.dupe(u8, try yamlScalar(&doc, value_id));
        } else if (std.mem.eql(u8, key, "license") or std.mem.eql(u8, key, "compatibility") or std.mem.eql(u8, key, "allowed-tools")) {
            _ = try yamlScalar(&doc, value_id);
        } else if (std.mem.eql(u8, key, "metadata")) {
            const node = yaml.yaml_document_get_node(&doc, value_id);
            if (node == null or node.*.type != yaml.YAML_MAPPING_NODE) return error.InvalidSkillMetadata;
            var meta = node.*.data.mapping.pairs.start;
            while (meta != node.*.data.mapping.pairs.top) : (meta += 1) {
                _ = try yamlScalar(&doc, meta.*.key);
                _ = try yamlScalar(&doc, meta.*.value);
            }
        }
    }
    // Reject extra YAML documents/trailing syntax instead of silently using
    // the first mapping. Aliases stay graph references, never expanded trees.
    var extra: yaml.yaml_document_t = undefined;
    if (yaml.yaml_parser_load(&parser, &extra) == 0) return error.InvalidYaml;
    defer yaml.yaml_document_delete(&extra);
    if (yaml.yaml_document_get_root_node(&extra) != null) return error.InvalidYaml;
    const n = name orelse return error.MissingSkillName;
    const d = description orelse return error.MissingSkillDescription;
    if (std.mem.trim(u8, n, " \t\r\n").len == 0 or std.mem.trim(u8, d, " \t\r\n").len == 0) return error.EmptySkillMetadata;
    for (n) |ch| if (std.ascii.isWhitespace(ch) or std.ascii.isControl(ch) or ch == '/' or ch == '\\') return error.InvalidSkillName;
    // Follow the integration guide's lenient-reader recommendation. Load
    // usable third-party names instead of enforcing authoring conventions.
    if (n.len > 64 or n[0] == '-' or n[n.len - 1] == '-' or std.mem.indexOf(u8, n, "--") != null)
        std.log.warn("skill name outside Agent Skills naming conventions: {s}", .{n});
    if (d.len > 1024) std.log.warn("skill '{s}' description exceeds the recommended limit", .{n});
    return .{ .name = n, .description = d, .frontmatter = frontmatter, .content = bytes[content_start..] };
}

fn yamlScalar(doc: *yaml.yaml_document_t, id: c_int) ![]const u8 {
    const node = yaml.yaml_document_get_node(doc, id);
    if (node == null or node.*.type != yaml.YAML_SCALAR_NODE) return error.InvalidSkillMetadata;
    return node.*.data.scalar.value[0..node.*.data.scalar.length];
}

fn lessThan(_: void, a: Skill, b: Skill) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}
