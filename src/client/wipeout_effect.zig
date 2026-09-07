//! wipEout as a client-side game: a `wipeout.session.Session` (assets,
//! circuit, state machine, clock) plus the terminal key mapping. The game
//! object lives on the App, not on the effect engine, so hiding the effect
//! keeps the game exactly where it was; `!wipeout` resumes it. Only the
//! engine's framebuffer and the terminal-side image are recreated.

const std = @import("std");
const vaxis = @import("vaxis");
const wipeout = @import("../wipeout/root.zig");
const Io = std.Io;

pub const snapshot = wipeout.snapshot;
pub const parzlib = wipeout.parzlib;
pub const Session = wipeout.session.Session;
pub const Options = wipeout.session.StartOptions;

// ------------------------------------------------------ the !wipeout line --
//
// `!wipeout [circuit] [pilot] [venom|rapier] [easy|normal|hard] [trial]
// [nointro] [crt|nocrt] [new]`: circuits and pilots by name, any unique
// prefix, any order; `trackN`/`pilotN` keep the raw PSX numbering for the
// parity tooling. Naming a circuit or pilot starts a fresh race (`explicit`);
// a bare `!wipeout` resumes the saved one.

const defs = wipeout.defs;

/// One short word per circuit, the first word of the arcade name.
pub const circuit_keys = [defs.num_circuits][]const u8{ "altima", "karbonis", "terramax", "korodera", "arridos", "silverstream", "firestar" };
/// One short word per pilot: the surname where it is unique, else the
/// first name (the Tetsuo twins).
pub const pilot_keys = [defs.num_pilots][]const u8{ "dekka", "chang", "arial", "anastasia", "solaar", "arian", "sofia", "jackson" };
const team_keys = [_]struct { key: []const u8, team: u8 }{
    .{ .key = "ag", .team = 0 },    .{ .key = "agsystems", .team = 0 }, .{ .key = "auricom", .team = 1 },
    .{ .key = "qirex", .team = 2 }, .{ .key = "feisar", .team = 3 },
};

pub const Parsed = union(enum) {
    ok: Options,
    /// Why the line was refused; a slice of the caller's buffer or a literal.
    invalid: []const u8,
};

const Match = union(enum) { one: u8, none, ambiguous };

fn prefixIgnoreCase(word: []const u8, candidate: []const u8) bool {
    return word.len > 0 and word.len <= candidate.len and std.ascii.eqlIgnoreCase(word, candidate[0..word.len]);
}

/// A circuit by unique prefix of its key ("terr" → TERRAMAX).
pub fn matchCircuit(word: []const u8) Match {
    var found: ?u8 = null;
    for (circuit_keys, 0..) |key, i| {
        if (prefixIgnoreCase(word, key)) {
            if (found != null) return .ambiguous;
            found = @intCast(i);
        }
    }
    return if (found) |c| .{ .one = c } else .none;
}

/// A pilot by unique prefix of any word of their name, or a team name
/// (its first pilot). "tetsuo" is ambiguous; "arial" and "arian" are not.
pub fn matchPilot(word: []const u8) Match {
    var found: ?u8 = null;
    for (defs.pilot_names, 0..) |name, i| {
        var words = std.mem.splitScalar(u8, name, ' ');
        var hit = false;
        while (words.next()) |w| hit = hit or prefixIgnoreCase(word, w);
        if (hit) {
            if (found != null and found.? != i) return .ambiguous;
            found = @intCast(i);
        }
    }
    if (found) |p| return .{ .one = p };
    for (team_keys) |t| {
        if (prefixIgnoreCase(word, t.key)) {
            const pilot = defs.team_pilots[t.team][0];
            if (found != null and found.? != pilot) return .ambiguous;
            found = pilot;
        }
    }
    return if (found) |p| .{ .one = p } else .none;
}

fn numberAfter(word: []const u8, prefix: []const u8) ?u8 {
    if (!prefixIgnoreCase(prefix, word) or word.len <= prefix.len) return null;
    return std.fmt.parseUnsigned(u8, word[prefix.len..], 10) catch null;
}

pub fn parseLaunchArgs(args: []const []const u8, buf: []u8) Parsed {
    var options = Options{};
    var circuit: ?u8 = null;
    var raw_track: ?u8 = null;
    for (args) |arg| {
        const flag = struct {
            fn is(a: []const u8, name: []const u8) bool {
                return std.ascii.eqlIgnoreCase(a, name);
            }
        };
        if (flag.is(arg, "rapier")) {
            options.rapier = true;
            options.explicit = true;
        } else if (flag.is(arg, "venom")) {
            options.rapier = false;
            options.explicit = true;
        } else if (flag.is(arg, "nointro")) {
            options.intro = false;
        } else if (flag.is(arg, "intro")) {
            options.intro = true;
        } else if (flag.is(arg, "crt")) {
            options.crt = true;
        } else if (flag.is(arg, "nocrt")) {
            options.crt = false;
        } else if (flag.is(arg, "new")) {
            options.explicit = true;
        } else if (flag.is(arg, "trial")) {
            options.time_trial = true;
            options.explicit = true;
        } else if (flag.is(arg, "race")) {
            options.time_trial = false;
            options.explicit = true;
        } else if (flag.is(arg, "easy")) {
            options.difficulty = .easy;
            options.explicit = true;
        } else if (flag.is(arg, "normal")) {
            options.difficulty = .normal;
            options.explicit = true;
        } else if (flag.is(arg, "hard")) {
            options.difficulty = .hard;
            options.explicit = true;
        } else if (numberAfter(arg, "track")) |n| {
            if (n < 1 or n > 14) return .{ .invalid = "PSX track numbers run 1-14" };
            raw_track = n;
            options.explicit = true;
        } else if (numberAfter(arg, "pilot")) |n| {
            if (n > 7) return .{ .invalid = "pilot numbers run 0-7" };
            options.pilot = n;
            options.explicit = true;
        } else if (std.fmt.parseUnsigned(u8, arg, 10)) |n| {
            if (n < 1 or n > defs.num_circuits) return .{ .invalid = "circuits are 1-7 (trackN for a PSX track number)" };
            circuit = n - 1;
            options.explicit = true;
        } else |_| switch (matchCircuit(arg)) {
            .one => |c| {
                circuit = c;
                options.explicit = true;
            },
            .ambiguous => return .{ .invalid = std.fmt.bufPrint(buf, "'{s}' could be several circuits: {s}", .{ arg, circuitList(circuitMatches(arg)) }) catch "ambiguous circuit" },
            .none => switch (matchPilot(arg)) {
                .one => |p| {
                    options.pilot = p;
                    options.explicit = true;
                },
                .ambiguous => return .{ .invalid = std.fmt.bufPrint(buf, "'{s}' could be several pilots; try a surname (dekka chang arial anastasia solaar arian sofia jackson)", .{arg}) catch "ambiguous pilot" },
                .none => return .{ .invalid = std.fmt.bufPrint(buf, "unknown word '{s}' · circuits: altima karbonis terramax korodera arridos silverstream firestar · pilots: dekka chang arial anastasia solaar arian sofia jackson · teams: ag auricom qirex feisar", .{arg}) catch "unknown word" },
            },
        }
    }
    if (raw_track) |t| {
        options.track = t;
    } else if (circuit) |c| {
        options.track = defs.trackNumber(c, if (options.rapier) .rapier else .venom);
    }
    return .{ .ok = options };
}

fn circuitMatches(word: []const u8) u8 {
    var mask: u8 = 0;
    for (circuit_keys, 0..) |key, i| {
        if (prefixIgnoreCase(word, key)) mask |= @as(u8, 1) << @intCast(i);
    }
    return mask;
}

/// The keys in a bit mask, space separated, for messages.
fn circuitList(mask: u8) []const u8 {
    // Only pairs occur in practice (a: altima/arridos, k: karbonis/korodera).
    if (mask == 0b0000001 | 0b0010000) return "altima arridos";
    if (mask == 0b0000010 | 0b0001000) return "karbonis korodera";
    return "see `!wipeout ` suggestions";
}

pub const Candidate = struct { word: []const u8, description: []const u8 };

/// What could come next on a `!wipeout` line: with nothing chosen yet the
/// seven circuits; once a circuit is named, the pilots and the flags;
/// always filtered by the word being typed. Circuits first because that is
/// the question people have.
pub fn launchCandidates(tokens: []const []const u8, partial: []const u8, out: []Candidate) []Candidate {
    var has_circuit = false;
    var has_pilot = false;
    var has_class = false;
    var has_difficulty = false;
    var has_mode = false;
    for (tokens) |t| {
        if (std.ascii.eqlIgnoreCase(t, "venom") or std.ascii.eqlIgnoreCase(t, "rapier")) {
            has_class = true;
        } else if (std.ascii.eqlIgnoreCase(t, "easy") or std.ascii.eqlIgnoreCase(t, "normal") or std.ascii.eqlIgnoreCase(t, "hard")) {
            has_difficulty = true;
        } else if (std.ascii.eqlIgnoreCase(t, "trial") or std.ascii.eqlIgnoreCase(t, "race")) {
            has_mode = true;
        } else if (numberAfter(t, "track") != null or (std.fmt.parseUnsigned(u8, t, 10) catch null) != null or matchCircuit(t) == .one) {
            has_circuit = true;
        } else if (numberAfter(t, "pilot") != null or matchPilot(t) == .one) {
            has_pilot = true;
        }
    }
    var n: usize = 0;
    const push = struct {
        fn add(list: []Candidate, count: *usize, word: []const u8, description: []const u8, typed: []const u8) void {
            if (count.* >= list.len) return;
            if (typed.len > 0 and !prefixIgnoreCase(typed, word)) return;
            list[count.*] = .{ .word = word, .description = description };
            count.* += 1;
        }
    };
    if (!has_circuit) {
        const circuit_descriptions = [defs.num_circuits][]const u8{
            "ALTIMA VII · circuit 1",
            "KARBONIS V · circuit 2",
            "TERRAMAX · circuit 3",
            "KORODERA · circuit 4",
            "ARRIDOS IV · circuit 5",
            "SILVERSTREAM · circuit 6",
            "FIRESTAR · circuit 7 (bonus)",
        };
        for (circuit_keys, circuit_descriptions) |key, d| push.add(out, &n, key, d, partial);
        if (partial.len == 0) return out[0..n]; // the first question, on its own
    }
    if (!has_pilot) {
        const pilot_descriptions = [defs.num_pilots][]const u8{
            "JOHN DEKKA · AG SYSTEMS",
            "DANIEL CHANG · AG SYSTEMS",
            "ARIAL TETSUO · AURICOM",
            "ANASTASIA CHEROVOSKI · AURICOM",
            "KEL SOLAAR · QIREX",
            "ARIAN TETSUO · QIREX",
            "SOFIA DE LA RENTE · FEISAR",
            "PAUL JACKSON · FEISAR",
        };
        for (pilot_keys, pilot_descriptions) |key, d| push.add(out, &n, key, d, partial);
    }
    if (!has_class) {
        push.add(out, &n, "venom", "Venom class (the default)", partial);
        push.add(out, &n, "rapier", "Rapier class: the faster layout and ships", partial);
    }
    if (!has_difficulty) {
        push.add(out, &n, "easy", "gentler opponents", partial);
        push.add(out, &n, "normal", "the original's opponents", partial);
        push.add(out, &n, "hard", "relentless opponents", partial);
    }
    if (!has_mode) {
        push.add(out, &n, "trial", "time trial: no opponents", partial);
        push.add(out, &n, "race", "single race (the default)", partial);
    }
    push.add(out, &n, "nointro", "skip the grid countdown", partial);
    push.add(out, &n, "crt", "CRT pass on", partial);
    push.add(out, &n, "nocrt", "CRT pass off", partial);
    push.add(out, &n, "new", "start fresh instead of resuming", partial);
    return out[0..n];
}

/// "TERRAMAX · RAPIER CLASS · ARIAL TETSUO[ · TIME TRIAL]" for the launch notice.
pub fn describeSelection(options: Options, buf: []u8) []const u8 {
    var circuit_name: []const u8 = "";
    for (defs.circuit_tracks, 0..) |tracks, i| {
        if (tracks[0] == options.track or tracks[1] == options.track) circuit_name = defs.circuit_names[i];
    }
    const class_name = defs.race_class_names[if (options.rapier) 1 else 0];
    const pilot_name = defs.pilot_names[@min(options.pilot, defs.num_pilots - 1)];
    return std.fmt.bufPrint(buf, "{s} · {s} · {s}{s}", .{
        circuit_name,
        class_name,
        pilot_name,
        if (options.time_trial) " · TIME TRIAL" else "",
    }) catch circuit_name;
}
pub const OutputSize = wipeout.session.OutputSize;
pub const render_width = wipeout.session.render_width;
pub const render_height = wipeout.session.render_height;
pub const step_seconds = wipeout.session.step_seconds;

pub const Game = struct {
    session: *Session,
    gpa: std.mem.Allocator,

    pub fn create(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, options: Options) !*Game {
        const self = try gpa.create(Game);
        errdefer gpa.destroy(self);
        self.* = .{ .session = try Session.create(gpa, io, environ, options), .gpa = gpa };
        return self;
    }

    pub fn destroy(self: *Game) void {
        self.session.destroy();
        self.gpa.destroy(self);
    }

    /// Capture the game for `snapshot.write`.
    pub fn snapshot(self: *const Game) wipeout.snapshot.Snapshot {
        const s = self.session;
        return .{
            .autopilot = 0,
            .steps = s.steps,
            .state = s.state,
            .rng = s.rng,
        };
    }

    /// Rebuild a game from a snapshot: assets reload, state is copied in.
    pub fn restore(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, snap: *const wipeout.snapshot.Snapshot) !*Game {
        const self = try create(gpa, io, environ, .{});
        errdefer self.destroy();
        try self.session.restoreState(&snap.state, snap.rng, snap.steps, false);
        return self;
    }

    pub fn matches(self: *const Game, options: Options) bool {
        return self.session.matches(options);
    }

    pub fn resume_(self: *Game) void {
        self.session.autopilot = false;
        self.session.resume_();
    }

    pub fn pause(self: *Game) void {
        self.session.pause();
    }

    pub fn releaseKeys(self: *Game) void {
        self.session.input = .{};
        self.session.autopilot = false;
    }

    pub fn tick(self: *Game) void {
        self.session.tick();
    }

    pub fn outputSize(self: *const Game) OutputSize {
        return self.session.outputSize();
    }

    pub fn render(self: *Game, rgb: []u8, out_w: usize, out_h: usize) void {
        self.session.render(rgb, out_w, out_h);
    }

    pub fn toggleCrt(self: *Game) void {
        self.session.toggleCrt();
    }

    /// Map a terminal key to game actions. Arrows steer and pitch and move
    /// the menu cursor; `x` or space thrusts and selects; `z`/`c` are the
    /// airbrakes; `v` toggles the view; `f` fires; Enter starts and pauses;
    /// Backspace returns a race to the main menu or goes back one menu page.
    pub fn actionsForKey(key: vaxis.Key) [2]?wipeout.input.Action {
        return switch (key.codepoint) {
            vaxis.Key.left => .{ .left, .menu_left },
            vaxis.Key.right => .{ .right, .menu_right },
            vaxis.Key.up => .{ .up, .menu_up },
            vaxis.Key.down => .{ .down, .menu_down },
            'x', 'X', vaxis.Key.space => .{ .thrust, .menu_select },
            'w', 'W' => .{ .thrust, null },
            'z', 'Z' => .{ .brake_left, null },
            'c', 'C' => .{ .brake_right, null },
            'a', 'A' => .{ .left, .menu_left },
            'd', 'D' => .{ .right, .menu_right },
            'v', 'V' => .{ .change_view, null },
            'f', 'F' => .{ .fire, null },
            vaxis.Key.enter => .{ .menu_start, null },
            vaxis.Key.backspace => .{ .menu_back, null },
            else => .{ null, null },
        };
    }

    pub fn setKey(self: *Game, key: vaxis.Key, down: bool) bool {
        if (key.codepoint == 'p' or key.codepoint == 'P') {
            if (down) self.toggleCrt();
            return true;
        }
        if (down and key.codepoint == vaxis.Key.backspace and self.session.state.scene == .race) {
            self.session.state.goToMainMenu();
            self.releaseKeys();
            return true;
        }
        const actions = actionsForKey(key);
        if (actions[0] == null) return false;
        for (actions) |maybe| {
            if (maybe) |action| self.session.input.set(action, down);
        }
        return true;
    }
};

/// Where the asset bundle lands: `<data root>/wo.pak`. Caller frees.
pub fn bundleDestination(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const root = try wipeout.assets.defaultRoot(gpa, environ);
    defer gpa.free(root);
    return wipeout.assets.bundlePath(gpa, root);
}

pub const bundleUrl = wipeout.assets.bundleUrl;
