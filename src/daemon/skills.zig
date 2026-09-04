//! Skills: markdown files w/ YAML frontmatter in ~/.config/marlin/skills/.
//! Index (name + one-line description) is injected into the system prompt;
//! the `skill` tool loads full content on demand. Compatible with the
//! emerging cross-tool skills convention. (docs/ARCHITECTURE.md §7)

const std = @import("std");
const Io = std.Io;

pub const spec_name = "skill";
pub const spec_description = "Load the full instructions for one available skill by name.";
pub const spec_schema =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Skill name from the system-prompt index"}},"required":["name"]}
;

pub const Skill = struct {
    name: []u8,
    description: []u8,
    content: []u8,
    path: []u8,

    fn deinit(self: *Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
        gpa.free(self.content);
        gpa.free(self.path);
    }
};

pub const Index = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Skill) = .empty,
    prompt: []u8,

    pub fn load(
        gpa: std.mem.Allocator,
        io: Io,
        directories: []const []const u8,
    ) !Index {
        var self = Index{ .gpa = gpa, .prompt = try gpa.dupe(u8, "") };
        errdefer self.deinit();
        for (directories) |directory| try self.scanDir(io, directory);
        std.mem.sort(Skill, self.items.items, {}, lessThan);
        var i: usize = 1;
        while (i < self.items.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.items.items[i - 1].name, self.items.items[i].name))
                return error.DuplicateSkill;
        }
        gpa.free(self.prompt);
        self.prompt = try self.buildPrompt();
        return self;
    }

    pub fn deinit(self: *Index) void {
        for (self.items.items) |*skill| skill.deinit(self.gpa);
        self.items.deinit(self.gpa);
        self.gpa.free(self.prompt);
    }

    pub fn get(self: *const Index, name: []const u8) ?*const Skill {
        for (self.items.items) |*skill| {
            if (std.mem.eql(u8, skill.name, name)) return skill;
        }
        return null;
    }

    pub fn loadContent(self: *const Index, gpa: std.mem.Allocator, args_json: []const u8) ![]u8 {
        const Args = struct { name: []const u8 };
        const parsed = std.json.parseFromSlice(Args, gpa, args_json, .{ .ignore_unknown_fields = true }) catch
            return gpa.dupe(u8, "error: skill arguments must contain a string 'name'");
        defer parsed.deinit();
        const skill = self.get(parsed.value.name) orelse
            return std.fmt.allocPrint(gpa, "error: unknown skill '{s}'", .{parsed.value.name});
        return gpa.dupe(u8, skill.content);
    }

    fn scanDir(self: *Index, io: Io, directory: []const u8) !void {
        var dir = Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        var walker = try dir.walk(self.gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
            const full_path = try std.fs.path.join(self.gpa, &.{ directory, entry.path });
            defer self.gpa.free(full_path);
            const bytes = Io.Dir.cwd().readFileAlloc(io, full_path, self.gpa, .limited(1024 * 1024)) catch continue;
            defer self.gpa.free(bytes);
            const parsed = parseFrontmatter(bytes) catch continue;
            try self.items.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, parsed.name),
                .description = try self.gpa.dupe(u8, parsed.description),
                .content = try self.gpa.dupe(u8, parsed.content),
                .path = try self.gpa.dupe(u8, full_path),
            });
        }
    }

    fn buildPrompt(self: *const Index) ![]u8 {
        if (self.items.items.len == 0) return self.gpa.dupe(u8, "");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.appendSlice(self.gpa,
            \\
            \\AVAILABLE SKILLS
            \\Load a skill with the `skill` tool when its instructions apply:
        );
        for (self.items.items) |skill| {
            try out.print(self.gpa, "\n- {s}: {s}", .{ skill.name, skill.description });
        }
        try out.append(self.gpa, '\n');
        return out.toOwnedSlice(self.gpa);
    }
};

const ParsedFrontmatter = struct {
    name: []const u8,
    description: []const u8,
    content: []const u8,
};

fn parseFrontmatter(bytes: []const u8) !ParsedFrontmatter {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = lines.next() orelse return error.MissingFrontmatter;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \t\r"), "---")) return error.MissingFrontmatter;

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var content_start: ?usize = null;
    var consumed: usize = first.len + 1;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            content_start = @min(consumed + raw_line.len + 1, bytes.len);
            break;
        }
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const value = yamlScalar(std.mem.trim(u8, line[colon + 1 ..], " \t"));
            if (std.mem.eql(u8, key, "name")) name = value;
            if (std.mem.eql(u8, key, "description")) description = value;
        }
        consumed += raw_line.len + 1;
    }
    const n = name orelse return error.MissingSkillName;
    const d = description orelse return error.MissingSkillDescription;
    if (n.len == 0 or d.len == 0) return error.EmptySkillMetadata;
    return .{ .name = n, .description = d, .content = bytes[content_start orelse return error.UnclosedFrontmatter ..] };
}

fn yamlScalar(value: []const u8) []const u8 {
    if (value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn lessThan(_: void, a: Skill, b: Skill) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}
