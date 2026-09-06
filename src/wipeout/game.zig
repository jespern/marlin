//! The game as a whole: title screen, main menu and race setup, the race
//! with its pause and results menus, championship progression with lives
//! and points, best-times tables and the hall of fame. Plain data; the
//! caller loads circuits on request and hands in the loaded track.

const std = @import("std");
const math = @import("math.zig");
const defs = @import("defs.zig");
const input = @import("input.zig");
const render = @import("render.zig");
const object = @import("object.zig");
const ui_mod = @import("ui.zig");
const hud_mod = @import("hud.zig");
const menu_mod = @import("menu.zig");
const save_mod = @import("save.zig");
const race_mod = @import("race.zig");
const track_mod = @import("track.zig");
const scene_mod = @import("scene.zig");
const Rng = @import("rng.zig").Rng;
const Vec2 = math.Vec2;
const Vec2i = math.Vec2i;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Rgba = math.Rgba;
const Menu = menu_mod.Menu;
const Anchor = ui_mod.Anchor;

pub const Scene = enum(u8) { title, main_menu, race };
pub const RaceType = enum(u8) { championship, single, time_trial };

const Action = enum(u16) {
    none = 0,
    start_game,
    options,
    quit,
    quit_confirm,
    class_select,
    type_select,
    team_select,
    pilot_select,
    circuit_select,
    opt_video,
    opt_game,
    opt_best_times,
    toggle_roll,
    toggle_shake,
    toggle_crt,
    toggle_difficulty,
    best_times_tab,
    pause_continue,
    pause_restart,
    pause_quit,
    restart_confirm,
    ingame_quit_confirm,
    stats_continue,
    points_continue,
    championship_continue,
    qualify_confirm,
    restart_or_quit,
    game_over_continue,
    scroll_continue,
    hall_of_fame_continue,
};

const PageKind = enum(u16) {
    plain = 0,
    main,
    options,
    race_class,
    race_type,
    team,
    pilot,
    circuit,
    best_times,
    best_times_view,
    race_stats,
    race_points,
    championship_points,
    hall_of_fame,
    text_scroll,
};

const OptionSet = enum(u16) { off_on, roll, shake, difficulty };

const opts_off_on = [_][]const u8{ "OFF", "ON" };
const opts_roll = [_][]const u8{ "0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100" };
const opts_shake = [_][]const u8{ "DISABLED", "REDUCED", "FULL" };
const opts_difficulty = [_][]const u8{ "EASY", "NORMAL", "HARD" };

fn optionText(set: u16, index: i32) []const u8 {
    const kind: OptionSet = @enumFromInt(set);
    const i: usize = @intCast(@max(index, 0));
    return switch (kind) {
        .off_on => opts_off_on[@min(i, opts_off_on.len - 1)],
        .roll => opts_roll[@min(i, opts_roll.len - 1)],
        .shake => opts_shake[@min(i, opts_shake.len - 1)],
        .difficulty => opts_difficulty[@min(i, opts_difficulty.len - 1)],
    };
}

pub const PilotPoints = extern struct { pilot: u8, _pad: [3]u8 = .{ 0, 0, 0 }, points: i32 };

pub const Result = extern struct {
    position: i32 = 0,
    race_time: f32 = 0,
    best_lap: f32 = 0,
    new_lap_record: u8 = 0,
    new_race_record: u8 = 0,
    _pad: u16 = 0,
};

const HallOfFame = extern struct {
    name: [4]u8 = .{ 0, 0, 0, 0 },
    time: f32 = 0,
    char_index: i32 = 0,
};

const ScrollKind = enum(u8) { venom, venom_all, rapier, rapier_all };

/// Assets the menus draw with; loaded once by the host.
pub const MenuAssets = struct {
    background: u16,
    title: u16,
    track_images: object.TextureList,
    class_models: []object.Object,
    team_models: []object.Object,
    pilot_models: []object.Object,
    option_models: []object.Object,
    misc_models: []object.Object,
    controller_models: []object.Object,
    portraits: [defs.num_pilots]object.TextureList,

    pub fn deinit(self: *MenuAssets, gpa: std.mem.Allocator) void {
        object.free(gpa, self.class_models);
        object.free(gpa, self.team_models);
        object.free(gpa, self.pilot_models);
        object.free(gpa, self.option_models);
        object.free(gpa, self.misc_models);
        object.free(gpa, self.controller_models);
    }
};

pub fn loadMenuAssets(gpa: std.mem.Allocator, assets: *const @import("assets.zig").Assets, r: *render.Renderer) !MenuAssets {
    const image = @import("image.zig");
    const bg_data = try assets.load("wipeout/textures/wipeout1.tim");
    defer gpa.free(bg_data);
    const bg = try image.decodeTim(gpa, bg_data, false);
    defer bg.deinit(gpa);
    const background = try r.createTexture(bg.width, bg.height, bg.pixels);

    const title_data = try assets.load("wipeout/textures/wiptitle.tim");
    defer gpa.free(title_data);
    const ti = try image.decodeTim(gpa, title_data, false);
    defer ti.deinit(gpa);
    const title = try r.createTexture(ti.width, ti.height, ti.pixels);

    const track_images = try scene_mod.loadCompressedTextures(gpa, assets, r, "wipeout/textures", "track.cmp");
    const class_models = try scene_mod.loadModel(gpa, assets, r, "wipeout/common", "leeg.cmp", "leeg.prm");
    errdefer object.free(gpa, class_models);
    const team_data = try assets.load("wipeout/common/teams.prm");
    defer gpa.free(team_data);
    const team_models = try object.load(gpa, team_data, .{ .start = 0, .len = 0 });
    errdefer object.free(gpa, team_models);
    const pilot_models = try scene_mod.loadModel(gpa, assets, r, "wipeout/common", "pilot.cmp", "pilot.prm");
    errdefer object.free(gpa, pilot_models);
    const option_models = try scene_mod.loadModel(gpa, assets, r, "wipeout/common", "alopt.cmp", "alopt.prm");
    errdefer object.free(gpa, option_models);
    const misc_models = try scene_mod.loadModel(gpa, assets, r, "wipeout/common", "msdos.cmp", "msdos.prm");
    errdefer object.free(gpa, misc_models);
    const controller_models = try scene_mod.loadModel(gpa, assets, r, "wipeout/common", "pad1.cmp", "pad1.prm");
    errdefer object.free(gpa, controller_models);

    var portraits: [defs.num_pilots]object.TextureList = undefined;
    for (defs.pilot_portraits, 0..) |path, i| {
        const dir = std.fs.path.dirname(path) orelse "";
        const name = std.fs.path.basename(path);
        portraits[i] = try scene_mod.loadCompressedTextures(gpa, assets, r, dir, name);
    }

    return .{
        .background = background,
        .title = title,
        .track_images = track_images,
        .class_models = class_models,
        .team_models = team_models,
        .pilot_models = pilot_models,
        .option_models = option_models,
        .misc_models = misc_models,
        .controller_models = controller_models,
        .portraits = portraits,
    };
}

pub const UpdateContext = struct {
    input: *const input.State,
    rng: *Rng,
    tick: f64,
    /// The loaded circuit, if any, and its PSX track number.
    track: ?*track_mod.Track,
    track_number: u8,
    assets: *const race_mod.Assets,
};

pub const DrawContext = struct {
    renderer: *render.Renderer,
    ui: *const ui_mod.Ui,
    hud: *const hud_mod.Hud,
    track: ?*track_mod.Track,
    scenery: ?*scene_mod.Scene,
    assets: *race_mod.Assets,
    menu_assets: *MenuAssets,
    dt: f32,
    autopilot: bool,
};

pub const State = extern struct {
    scene: Scene,
    race_class: u8,
    race_type: RaceType,
    team: u8,
    pilot: u8,
    circuit: u8,
    /// Race is initialised and running (or finished) on the loaded track.
    race_active: u8,
    /// Waiting for the host to load the wanted circuit.
    race_pending: u8,
    paused: u8,
    menu_active: u8,
    result_recorded: u8,
    save_dirty: u8,
    /// Skip the grid intro when starting races (the host's `nointro`).
    skip_intro: u8,
    lives: i32,
    scene_time: f32,
    championship: [defs.num_pilots]PilotPoints,
    race_points: [defs.num_pilots]PilotPoints,
    /// Finishing order of the last race; the next championship grid.
    grid_order: [defs.num_pilots]u8,
    result: Result,
    hall: HallOfFame,
    scroll_kind: ScrollKind,
    best_class: u8,
    best_circuit: u8,
    best_tab: u8,
    save: save_mod.SaveData,
    menu: Menu,
    race: race_mod.Race,

    pub fn init(save: save_mod.SaveData) State {
        var s = std.mem.zeroes(State);
        s.save = save;
        s.scene = .title;
        s.race_type = .single;
        s.lives = defs.num_lives;
        s.menu.reset();
        for (&s.grid_order, 0..) |*g, i| g.* = @intCast(i);
        return s;
    }

    pub fn difficulty(self: *const State) race_mod.Difficulty {
        return @enumFromInt(@min(self.save.difficulty, 2));
    }

    pub fn crtEnabled(self: *const State) bool {
        return self.save.crt != 0;
    }

    /// The circuit the host should have loaded for the current scene.
    pub fn wantedTrack(self: *const State) ?u8 {
        if (self.scene != .race) return null;
        return defs.trackNumber(self.circuit, @enumFromInt(self.race_class));
    }

    pub fn inRace(self: *const State) bool {
        return self.scene == .race and self.race_active != 0;
    }

    pub fn playerShip(self: *State) ?*@import("ship.zig").Ship {
        if (!self.inRace()) return null;
        return self.race.playerShip();
    }

    /// Skip the menus straight into a race (the `!wipeout <track>` form).
    pub fn startRaceDirect(self: *State, track_number: u8, pilot: u8, time_trial: bool) void {
        for (defs.circuit_tracks, 0..) |pair, c| {
            for (pair, 0..) |t, class| {
                if (t == track_number) {
                    self.circuit = @intCast(c);
                    self.race_class = @intCast(class);
                }
            }
        }
        self.pilot = pilot;
        self.team = pilot / 2;
        self.race_type = if (time_trial) .time_trial else .single;
        self.startRace();
    }

    fn startRace(self: *State) void {
        self.menu.reset();
        self.scene = .race;
        self.race_active = 0;
        self.race_pending = 1;
        self.paused = 0;
        self.menu_active = 0;
        self.result_recorded = 0;
        self.scene_time = 0;
    }

    pub fn goToMainMenu(self: *State) void {
        self.scene = .main_menu;
        self.race_active = 0;
        self.race_pending = 0;
        self.menu_active = 0;
        self.scene_time = 0;
        self.menu.reset();
        self.pageMain();
    }

    // -- update ---------------------------------------------------------------

    pub fn update(self: *State, ctx: UpdateContext) void {
        const dt: f32 = @floatCast(ctx.tick);
        self.scene_time += dt;
        switch (self.scene) {
            .title => {
                if (ctx.input.isPressed(.menu_select) or ctx.input.isPressed(.menu_start)) self.goToMainMenu();
            },
            .main_menu => {
                if (self.menu.depth() == 0) self.pageMain();
                self.handleMenu(ctx);
            },
            .race => self.updateRace(ctx),
        }
    }

    fn updateRace(self: *State, ctx: UpdateContext) void {
        const dt: f32 = @floatCast(ctx.tick);
        if (self.race_pending != 0) {
            const track = ctx.track orelse return;
            if (ctx.track_number != self.wantedTrack().?) return;
            self.race = race_mod.Race.init(track, .{
                .track = ctx.track_number,
                .pilot = self.pilot,
                .class = @enumFromInt(self.race_class),
                .race_type = if (self.race_type == .time_trial) .time_trial else .single,
                .difficulty = self.difficulty(),
                .intro = self.skip_intro == 0,
                .grid = if (self.race_type == .championship) self.grid_order else null,
            }, ctx.rng, ctx.assets.particle_textures.start);
            self.race.camera.internal_roll = @as(f32, @floatFromInt(self.save.internal_roll)) * 0.1;
            self.race.camera.screen_shake = @as(f32, @floatFromInt(self.save.screen_shake)) * 0.5;
            self.race_pending = 0;
            self.race_active = 1;
            self.result_recorded = 0;
            self.paused = 0;
            self.menu_active = 0;
            for (&self.race_points, 0..) |*p, i| p.* = .{ .pilot = @intCast(i), .points = 0 };
        }
        const track = ctx.track orelse return;

        if (self.menu_active != 0) {
            // Results menus run over a live scene; the pause menu freezes it.
            if (self.paused == 0) self.race.update(track, ctx.input, ctx.rng, ctx.tick, ctx.assets);
            self.handleMenu(ctx);
            return;
        }

        if (ctx.input.isPressed(.menu_start) and !self.race.playerShipConst().finished()) {
            self.paused = 1;
            self.menu_active = 1;
            self.pausePage();
            return;
        }

        self.race.update(track, ctx.input, ctx.rng, ctx.tick, ctx.assets);
        _ = dt;

        if (self.race.playerShipConst().finished() and self.result_recorded == 0) self.raceEnd();
    }

    /// The original's race_end: results, records, championship points.
    fn raceEnd(self: *State) void {
        self.result_recorded = 1;
        const player = self.race.playerShipConst();
        self.result.position = player.position_rank;
        self.result.race_time = player.raceTime();
        self.result.best_lap = player.bestLap();
        self.result.new_lap_record = 0;
        self.result.new_race_record = 0;

        const tab: save_mod.Tab = if (self.race_type == .time_trial) .time_trial else .race;
        const table = self.save.table(self.race_class, self.circuit, tab);
        if (self.result.best_lap > 0 and self.result.best_lap < table.lap_record) {
            table.lap_record = self.result.best_lap;
            self.result.new_lap_record = 1;
            self.save_dirty = 1;
        }
        for (table.entries) |entry| {
            if (self.result.race_time < entry.time) {
                self.result.new_race_record = 1;
                break;
            }
        }

        if (self.race_type == .championship) {
            self.grid_order = self.race.ranks;
            for (self.race.ranks, 0..) |pilot, i| {
                self.race_points[i] = .{ .pilot = pilot, .points = defs.race_points_for_rank[i] };
                for (&self.championship) |*c| {
                    if (c.pilot == pilot) c.points += defs.race_points_for_rank[i];
                }
            }
            // Sort the table by points, best first.
            var i: usize = 1;
            while (i < self.championship.len) : (i += 1) {
                const item = self.championship[i];
                var j = i;
                while (j > 0 and self.championship[j - 1].points < item.points) : (j -= 1) self.championship[j] = self.championship[j - 1];
                self.championship[j] = item;
            }
        }

        self.menu_active = 1;
        self.menu.reset();
        self.raceStatsPage();
    }

    fn resetChampionship(self: *State) void {
        for (&self.championship, 0..) |*c, i| c.* = .{ .pilot = @intCast(i), .points = 0 };
        for (&self.grid_order, 0..) |*g, i| g.* = @intCast(i);
        self.lives = defs.num_lives;
    }

    fn restartRace(self: *State) void {
        if (self.race_type == .championship) {
            self.lives -= 1;
            if (self.lives == 0) {
                self.menu.reset();
                _ = self.menu.push("GAME OVER", 0).addButton(1, "", @intFromEnum(Action.game_over_continue));
                self.menu_active = 1;
                self.paused = 0;
                return;
            }
        }
        self.startRace();
    }

    fn raceNext(self: *State) void {
        const next: u8 = self.circuit + 1;
        const limit: u8 = if (self.save.has_bonus_circuits != 0) defs.num_circuits else defs.num_non_bonus_circuits;
        if (next >= limit) {
            if (self.race_class == 1) {
                if (self.save.has_bonus_circuits != 0) {
                    self.scroll_kind = .rapier_all;
                } else {
                    self.save.has_bonus_circuits = 1;
                    self.scroll_kind = .rapier;
                }
            } else {
                self.save.has_rapier_class = 1;
                self.scroll_kind = if (self.save.has_bonus_circuits != 0) .venom_all else .venom;
            }
            self.save_dirty = 1;
            self.menu.reset();
            const page = self.menu.push("", @intFromEnum(PageKind.text_scroll));
            _ = page.addButton(1, "", @intFromEnum(Action.scroll_continue));
            self.scene_time = 0;
            self.menu_active = 1;
        } else {
            self.circuit = next;
            self.startRace();
        }
    }

    // -- menu actions ------------------------------------------------------------

    fn handleMenu(self: *State, ctx: UpdateContext) void {
        // Pages with their own input (best times viewer, hall of fame).
        if (self.menu.current()) |page| {
            switch (@as(PageKind, @enumFromInt(page.kind))) {
                .best_times_view => self.bestTimesInput(ctx.input),
                .hall_of_fame => {
                    if (self.hallOfFameInput(ctx.input)) return;
                },
                else => {},
            }
        }
        const event = self.menu.update(ctx.input);
        switch (event) {
            .none, .back => {
                if (event == .back and self.scene == .race and self.menu.depth() <= 1 and self.paused != 0) {
                    // Backing out of the pause menu continues.
                    self.paused = 0;
                    self.menu_active = 0;
                }
            },
            .select => |sel| self.applyAction(@enumFromInt(sel.action), sel.data),
        }
    }

    fn applyAction(self: *State, action: Action, data: i32) void {
        switch (action) {
            .none => {},
            .start_game => self.pageRaceClass(),
            .options => self.pageOptions(),
            .quit => _ = self.menu.confirm("ARE YOU SURE YOU", "WANT TO QUIT", "YES", "NO", @intFromEnum(Action.quit_confirm)),
            .quit_confirm => if (data != 0) {
                // Quitting returns to the title; the host decides what
                // leaving the game altogether means.
                self.scene = .title;
                self.scene_time = 0;
                self.menu.reset();
            } else self.menu.pop(),
            .class_select => {
                if (data == 1 and self.save.has_rapier_class == 0) return;
                self.race_class = @intCast(data);
                self.pageRaceType();
            },
            .type_select => {
                self.race_type = @enumFromInt(@as(u8, @intCast(data)));
                self.pageTeam();
            },
            .team_select => {
                self.team = @intCast(data);
                self.pagePilot();
            },
            .pilot_select => {
                self.pilot = @intCast(data);
                if (self.race_type != .championship) {
                    self.pageCircuit();
                } else {
                    self.circuit = 0;
                    self.resetChampionship();
                    self.startRace();
                }
            },
            .circuit_select => {
                self.circuit = @intCast(data);
                self.startRace();
            },
            .opt_video => self.pageVideo(),
            .opt_game => self.pageGame(),
            .opt_best_times => self.pageBestTimes(),
            .toggle_roll => {
                self.save.internal_roll = @intCast(data);
                self.save_dirty = 1;
            },
            .toggle_shake => {
                self.save.screen_shake = @intCast(data);
                self.save_dirty = 1;
            },
            .toggle_crt => {
                self.save.crt = @intCast(data);
                self.save_dirty = 1;
            },
            .toggle_difficulty => {
                self.save.difficulty = @intCast(data);
                self.save_dirty = 1;
            },
            .best_times_tab => {
                self.best_tab = @intCast(data);
                self.best_class = 0;
                self.best_circuit = 0;
                const page = self.menu.push(if (data == 0) "BEST TIME TRIAL TIMES" else "BEST RACE TIMES", @intFromEnum(PageKind.best_times_view));
                page.layout |= menu_mod.Layout.fixed;
                page.title_anchor = Anchor.top | Anchor.center;
                page.title_pos = Vec2i.init(0, 30);
            },
            .pause_continue => {
                self.paused = 0;
                self.menu_active = 0;
            },
            .pause_restart => _ = self.menu.confirm("ARE YOU SURE YOU", "WANT TO RESTART", "YES", "NO", @intFromEnum(Action.restart_confirm)),
            .pause_quit => _ = self.menu.confirm("ARE YOU SURE YOU", "WANT TO QUIT", "YES", "NO", @intFromEnum(Action.ingame_quit_confirm)),
            .restart_confirm => if (data != 0) self.restartRace() else self.menu.pop(),
            .ingame_quit_confirm => if (data != 0) self.goToMainMenu() else self.menu.pop(),
            .stats_continue => {
                if (self.race_type == .championship) {
                    if (self.result.position <= defs.qualifying_rank) {
                        self.racePointsPage();
                    } else {
                        const page = self.menu.confirm("CONTINUE QUALIFYING OR QUIT", "", "QUALIFY", "QUIT", @intFromEnum(Action.qualify_confirm));
                        page.index = 0;
                    }
                } else if (self.result.new_race_record != 0) {
                    self.hallOfFamePage();
                } else {
                    _ = self.menu.confirm("", "RESTART RACE", "RESTART", "QUIT", @intFromEnum(Action.restart_or_quit));
                }
            },
            .qualify_confirm => if (data != 0) self.restartRace() else self.goToMainMenu(),
            .points_continue => {
                if (self.race_type == .championship) {
                    self.championshipPage();
                } else if (self.result.new_race_record != 0) {
                    self.hallOfFamePage();
                } else {
                    _ = self.menu.confirm("", "RESTART RACE", "RESTART", "QUIT", @intFromEnum(Action.restart_or_quit));
                }
            },
            .championship_continue => {
                if (self.result.new_race_record != 0) {
                    self.hallOfFamePage();
                } else {
                    self.raceNext();
                }
            },
            .restart_or_quit => if (data != 0) self.restartRace() else self.goToMainMenu(),
            .game_over_continue => self.goToMainMenu(),
            .scroll_continue => self.goToMainMenu(),
            .hall_of_fame_continue => {},
        }
    }

    // -- main menu pages ---------------------------------------------------------

    fn fixedTopPage(self: *State, title: []const u8, kind: PageKind) *menu_mod.Page {
        const page = self.menu.push(title, @intFromEnum(kind));
        page.layout |= menu_mod.Layout.fixed;
        page.title_pos = Vec2i.init(0, 30);
        page.title_anchor = Anchor.top | Anchor.center;
        page.items_pos = Vec2i.init(0, -110);
        page.items_anchor = Anchor.bottom | Anchor.center;
        return page;
    }

    fn pageMain(self: *State) void {
        const page = self.fixedTopPage("OPTIONS", .main);
        _ = page.addButton(0, "START GAME", @intFromEnum(Action.start_game));
        _ = page.addButton(1, "OPTIONS", @intFromEnum(Action.options));
        _ = page.addButton(2, "QUIT", @intFromEnum(Action.quit));
    }

    fn pageOptions(self: *State) void {
        const page = self.fixedTopPage("OPTIONS", .options);
        _ = page.addButton(0, "GAME", @intFromEnum(Action.opt_game));
        _ = page.addButton(1, "VIDEO", @intFromEnum(Action.opt_video));
        _ = page.addButton(3, "BEST TIMES", @intFromEnum(Action.opt_best_times));
    }

    fn optionsListPage(self: *State, title: []const u8, items_y: i32) *menu_mod.Page {
        const page = self.menu.push(title, 0);
        page.layout = menu_mod.Layout.vertical | menu_mod.Layout.fixed;
        // The original spans the full 320 px; a small inset keeps the
        // block off the terminal image's edge.
        page.title_pos = Vec2i.init(-148, -100);
        page.title_anchor = Anchor.middle | Anchor.center;
        page.items_pos = Vec2i.init(-148, items_y);
        page.block_width = 296;
        page.items_anchor = Anchor.middle | Anchor.center;
        return page;
    }

    fn pageVideo(self: *State) void {
        const page = self.optionsListPage("VIDEO OPTIONS", -60);
        page.addToggle(self.save.internal_roll, "INTERNAL VIEW ROLL", @intFromEnum(OptionSet.roll), opts_roll.len, @intFromEnum(Action.toggle_roll));
        page.addToggle(self.save.screen_shake, "SCREEN SHAKE", @intFromEnum(OptionSet.shake), opts_shake.len, @intFromEnum(Action.toggle_shake));
        page.addToggle(self.save.crt, "CRT EFFECT", @intFromEnum(OptionSet.off_on), opts_off_on.len, @intFromEnum(Action.toggle_crt));
    }

    fn pageGame(self: *State) void {
        const page = self.optionsListPage("GAME OPTIONS", -80);
        page.addToggle(self.save.difficulty, "OPPONENTS", @intFromEnum(OptionSet.difficulty), opts_difficulty.len, @intFromEnum(Action.toggle_difficulty));
    }

    fn pageBestTimes(self: *State) void {
        const page = self.fixedTopPage("VIEW BEST TIMES", .best_times);
        _ = page.addButton(0, "TIME TRIAL TIMES", @intFromEnum(Action.best_times_tab));
        _ = page.addButton(1, "RACE TIMES", @intFromEnum(Action.best_times_tab));
    }

    fn pageRaceClass(self: *State) void {
        const page = self.fixedTopPage("SELECT RACING CLASS", .race_class);
        for (defs.race_class_names, 0..) |name, i| _ = page.addButton(@intCast(i), name, @intFromEnum(Action.class_select));
    }

    fn pageRaceType(self: *State) void {
        const page = self.fixedTopPage("SELECT RACE TYPE", .race_type);
        for (defs.race_type_names, 0..) |name, i| _ = page.addButton(@intCast(i), name, @intFromEnum(Action.type_select));
    }

    fn pageTeam(self: *State) void {
        const page = self.fixedTopPage("SELECT YOUR TEAM", .team);
        for (defs.team_names, 0..) |name, i| _ = page.addButton(@intCast(i), name, @intFromEnum(Action.team_select));
    }

    fn pagePilot(self: *State) void {
        const page = self.fixedTopPage("CHOOSE YOUR PILOT", .pilot);
        for (defs.team_pilots[self.team]) |pilot| _ = page.addButton(pilot, defs.pilot_names[pilot], @intFromEnum(Action.pilot_select));
    }

    fn pageCircuit(self: *State) void {
        const page = self.fixedTopPage("SELECT RACING CIRCUIT", .circuit);
        page.items_pos = Vec2i.init(0, -100);
        for (defs.circuit_names, 0..) |name, i| {
            if (defs.circuit_is_bonus[i] and self.save.has_bonus_circuits == 0) continue;
            _ = page.addButton(@intCast(i), name, @intFromEnum(Action.circuit_select));
        }
    }

    // -- in-game pages -----------------------------------------------------------

    fn pausePage(self: *State) void {
        self.menu.reset();
        const page = self.menu.push("PAUSED", 0);
        _ = page.addButton(0, "CONTINUE", @intFromEnum(Action.pause_continue));
        _ = page.addButton(0, "RESTART", @intFromEnum(Action.pause_restart));
        _ = page.addButton(0, "QUIT", @intFromEnum(Action.pause_quit));
    }

    fn resultsPage(self: *State, title: []const u8, kind: PageKind, action: Action) void {
        const page = self.menu.push(title, @intFromEnum(kind));
        page.layout |= menu_mod.Layout.fixed;
        page.title_anchor = Anchor.middle | Anchor.center;
        page.title_pos = Vec2i.init(0, -100);
        _ = page.addButton(1, "", @intFromEnum(action));
    }

    fn raceStatsPage(self: *State) void {
        const title: []const u8 = if (self.race_type == .time_trial) "" else if (self.result.position <= defs.qualifying_rank) "CONGRATULATIONS" else "FAILED TO QUALIFY";
        self.resultsPage(title, .race_stats, .stats_continue);
    }

    fn racePointsPage(self: *State) void {
        self.resultsPage("RACE POINTS", .race_points, .points_continue);
    }

    fn championshipPage(self: *State) void {
        self.resultsPage("CHAMPIONSHIP TABLE", .championship_points, .championship_continue);
    }

    /// Test hook: pretend the last race set a record of `time` seconds
    /// and open the name entry over whatever is on screen.
    pub fn debugHallOfFame(self: *State, time: f32) void {
        self.result.race_time = time;
        self.result.new_race_record = 1;
        self.menu_active = 1;
        self.hallOfFamePage();
    }

    fn hallOfFamePage(self: *State) void {
        self.menu.reset();
        self.resultsPage("HALL OF FAME", .hall_of_fame, .hall_of_fame_continue);
        self.hall = .{ .time = self.result.race_time, .name = self.save.highscores_name, .char_index = 0 };
    }

    const hs_charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    /// Name entry. Returns true when the entry completed and the menu
    /// moved on, so the generic update must not also run this step.
    fn hallOfFameInput(self: *State, in: *const input.State) bool {
        const len = std.mem.indexOfScalar(u8, &self.hall.name, 0) orelse 3;
        var first: i32 = 0;
        var last: i32 = 38;
        if (len == 0) last = 37 else if (len == 3) first = 36;
        if (in.isPressed(.menu_up)) self.hall.char_index += 1;
        if (in.isPressed(.menu_down)) self.hall.char_index -= 1;
        self.hall.char_index = menu_mod.wrap(self.hall.char_index, first, last);

        const pressed = in.isPressed(.menu_select) or in.isPressed(.menu_start);
        if (!pressed) return false;
        if (self.hall.char_index == 36) {
            if (len > 0) self.hall.name[len - 1] = 0;
            return true;
        }
        if (self.hall.char_index == 37) {
            self.commitHallOfFame();
            return true;
        }
        if (len < 3) {
            self.hall.name[len] = hs_charset[@intCast(self.hall.char_index)];
            if (len + 1 < 4) self.hall.name[len + 1] = 0;
        }
        return true;
    }

    fn commitHallOfFame(self: *State) void {
        self.save.highscores_name = self.hall.name;
        const tab: save_mod.Tab = if (self.race_type == .time_trial) .time_trial else .race;
        const table = self.save.table(self.race_class, self.circuit, tab);
        var i: usize = 0;
        while (i < save_mod.num_highscores) : (i += 1) {
            if (self.hall.time < table.entries[i].time) {
                var j: usize = save_mod.num_highscores - 1;
                while (j > i) : (j -= 1) table.entries[j] = table.entries[j - 1];
                table.entries[i] = .{ .name = self.hall.name, .time = self.hall.time };
                break;
            }
        }
        self.save_dirty = 1;
        if (self.race_type == .championship) {
            self.raceNext();
        } else {
            self.menu.reset();
            _ = self.menu.confirm("", "RESTART RACE", "RESTART", "QUIT", @intFromEnum(Action.restart_or_quit));
        }
    }

    fn bestTimesInput(self: *State, in: *const input.State) void {
        if (in.isPressed(.menu_up)) self.best_class = @intCast(menu_mod.wrap(@as(i32, self.best_class) - 1, 0, 2));
        if (in.isPressed(.menu_down)) self.best_class = @intCast(menu_mod.wrap(@as(i32, self.best_class) + 1, 0, 2));
        if (in.isPressed(.menu_left)) self.best_circuit = @intCast(menu_mod.wrap(@as(i32, self.best_circuit) - 1, 0, defs.num_circuits));
        if (in.isPressed(.menu_right)) self.best_circuit = @intCast(menu_mod.wrap(@as(i32, self.best_circuit) + 1, 0, defs.num_circuits));
    }

    // -- drawing -------------------------------------------------------------

    fn blink(self: *const State) bool {
        return @mod(self.scene_time, 1.0 / 15.0) < 1.0 / 30.0;
    }

    pub fn draw(self: *State, ctx: DrawContext) void {
        const r = ctx.renderer;
        switch (self.scene) {
            .title => {
                r.framePrepare();
                r.setView2d();
                r.setCullBackface(false);
                r.push2d(Vec2i.init(0, 0), ctx.ui.screen, Rgba.white, ctx.menu_assets.title);
                ctx.ui.drawTextCentered(r, "PRESS ENTER", ctx.ui.pos(Anchor.bottom | Anchor.center, Vec2i.init(0, -40)), .px8, ui_mod.color_default);
                r.setCullBackface(true);
            },
            .main_menu => {
                r.framePrepare();
                r.setView2d();
                r.setCullBackface(false);
                r.push2d(Vec2i.init(0, 0), ctx.ui.screen, Rgba.white, ctx.menu_assets.background);
                r.setCullBackface(true);
                self.drawPageContent(ctx);
                self.menu.draw(r, ctx.ui, self.blink(), optionText);
            },
            .race => self.drawRace(ctx),
        }
    }

    fn drawRace(self: *State, ctx: DrawContext) void {
        const r = ctx.renderer;
        r.framePrepare();
        if (self.race_active == 0) return;
        const track = ctx.track orelse return;
        const camera = &self.race.camera;
        r.setView(camera.position, camera.angle);
        r.setScreenPosition(camera.shake);
        const forward = camera.forward();
        r.setCullBackface(false);
        if (ctx.scenery) |scenery| scenery.draw(r, camera.position, forward);
        track.draw(r, camera.position, forward);
        r.setCullBackface(true);
        self.race.draw(r, track, ctx.assets, if (self.paused != 0) 0 else ctx.dt);

        const player = self.race.playerShipConst();
        if (player.flags.racing) {
            ctx.hud.draw(r, ctx.ui, player, .{
                .show_position = self.race.race_type != .time_trial,
                .autopilot = ctx.autopilot,
                .weapon_icons = ctx.assets.weapon_icons,
                .reticle = ctx.assets.reticle,
                .target_position = if (player.weapon_target >= 0) self.race.ships[@intCast(player.weapon_target)].position else null,
            });
        }
        if (self.menu_active != 0) {
            r.setView2d();
            r.setCullBackface(false);
            const is_scroll = if (self.menu.current()) |p| p.kind == @intFromEnum(PageKind.text_scroll) else false;
            if (!is_scroll) r.push2d(Vec2i.init(0, 0), ctx.ui.screen, Rgba.init(0, 0, 0, 128), r.no_texture);
            r.setCullBackface(true);
            self.drawPageContent(ctx);
            self.menu.draw(r, ctx.ui, self.blink(), optionText);
        }
    }

    /// A rotating menu model, as the original's draw_model.
    fn drawModel(r: *render.Renderer, models: []object.Object, index: usize, offset: Vec2, pos: Vec3, rotation: f32) void {
        if (index >= models.len) return;
        r.setView(Vec3.zero, Vec3.init(0, -math.pi, -math.pi));
        r.setScreenPosition(offset);
        var mat = Mat4.identity;
        mat.setTranslation(pos);
        mat.setYawPitchRoll(Vec3.init(0, rotation, math.pi));
        models[index].draw(r, &mat);
        r.setScreenPosition(Vec2.init(0, 0));
    }

    fn drawPageContent(self: *State, ctx: DrawContext) void {
        const r = ctx.renderer;
        const ui = ctx.ui;
        const page = self.menu.current() orelse return;
        const kind: PageKind = @enumFromInt(page.kind);
        const selected: i32 = if (page.entries_len > 0) page.entries[@intCast(page.index)].data else 0;
        const t = self.scene_time;
        const ma = ctx.menu_assets;
        switch (kind) {
            .plain => {},
            .main => switch (selected) {
                0 => drawModel(r, ctx.assets.ships.objects, defs.pilotToModel(0), Vec2.init(0, -0.1), Vec3.init(0, 0, -700), t),
                1 => drawModel(r, ma.misc_models, 3, Vec2.init(0, -0.2), Vec3.init(0, 0, -700), t),
                else => drawModel(r, ma.misc_models, 1, Vec2.init(0, -0.2), Vec3.init(0, 0, -700), t),
            },
            .options => switch (selected) {
                0 => drawModel(r, ma.controller_models, 0, Vec2.init(0, -0.1), Vec3.init(0, 0, -6000), t),
                1 => drawModel(r, ctx.assets.droid, 0, Vec2.init(0, -0.2), Vec3.init(0, 0, -700), t),
                else => drawModel(r, ma.option_models, 0, Vec2.init(0, -0.2), Vec3.init(0, 0, -400), t),
            },
            .race_class => {
                drawModel(r, ma.class_models, @intCast(@max(selected, 0)), Vec2.init(0, -0.2), Vec3.init(0, 0, -350), t);
                if (selected == 1 and self.save.has_rapier_class == 0) {
                    r.setView2d();
                    ui.drawTextCentered(r, "NOT AVAILABLE", ui.pos(page.items_anchor, Vec2i.init(page.items_pos.x, page.items_pos.y + 32)), .px12, ui_mod.color_accent);
                }
            },
            .race_type => switch (selected) {
                0 => drawModel(r, ma.misc_models, 0, Vec2.init(0, -0.2), Vec3.init(0, 0, -400), t),
                1 => drawModel(r, ma.misc_models, 2, Vec2.init(0, -0.2), Vec3.init(0, 0, -400), t),
                else => drawModel(r, ma.option_models, 0, Vec2.init(0, -0.2), Vec3.init(0, 0, -400), t),
            },
            .team => {
                const team: usize = @intCast(@max(selected, 0));
                drawModel(r, ma.team_models, (team + 3) % 4, Vec2.init(0, -0.2), Vec3.init(0, 0, -10000), t);
                const pilots = defs.team_pilots[@min(team, 3)];
                drawModel(r, ctx.assets.ships.objects, defs.pilotToModel(pilots[0]), Vec2.init(0, -0.3), Vec3.init(-700, -800, -1300), t * 1.1);
                drawModel(r, ctx.assets.ships.objects, defs.pilotToModel(pilots[1]), Vec2.init(0, -0.3), Vec3.init(700, -800, -1300), t * 1.2);
            },
            .pilot => {
                const pilot: usize = @intCast(@min(@max(selected, 0), defs.num_pilots - 1));
                drawModel(r, ma.pilot_models, defs.pilot_logo_model[pilot], Vec2.init(0, -0.2), Vec3.init(0, 0, -10000), t);
            },
            .circuit => {
                r.setView2d();
                const size = Vec2i.init(128, 74);
                const pos = ui.pos(Anchor.middle | Anchor.center, Vec2i.init(-@divTrunc(size.x, 2), -25 - @divTrunc(size.y, 2)));
                if (ma.track_images.resolve(@intCast(@max(selected, 0)))) |texture| {
                    r.push2d(pos, ui.scaled(size), Rgba.white, texture);
                } else |_| {}
            },
            .best_times => drawModel(r, ma.option_models, 0, Vec2.init(0, -0.2), Vec3.init(0, 0, -400), t),
            .best_times_view => self.drawBestTimes(ctx),
            .race_stats => self.drawRaceStats(ctx),
            .race_points => self.drawPointsTable(ctx, "RACE POINTS", &self.race_points),
            .championship_points => self.drawPointsTable(ctx, "CHAMPIONSHIP TABLE", &self.championship),
            .hall_of_fame => self.drawHallOfFame(ctx),
            .text_scroll => self.drawScroll(ctx),
        }
    }

    fn drawBestTimes(self: *State, ctx: DrawContext) void {
        const r = ctx.renderer;
        const ui = ctx.ui;
        r.setView2d();
        const anchor = Anchor.middle | Anchor.center;
        var pos = Vec2i.init(0, -70);
        ui.drawTextCentered(r, defs.race_class_names[self.best_class], ui.pos(anchor, pos), .px12, ui_mod.color_default);
        pos.y += 16;
        ui.drawTextCentered(r, defs.circuit_names[self.best_circuit], ui.pos(anchor, pos), .px12, ui_mod.color_accent);
        var entry_pos = Vec2i.init(pos.x - 110, pos.y + 24);
        const table = self.save.tableConst(self.best_class, self.best_circuit, @enumFromInt(self.best_tab));
        for (table.entries) |entry| {
            ui.drawText(r, std.mem.sliceTo(&entry.name, 0), ui.pos(anchor, entry_pos), .px16, ui_mod.color_default);
            ui.drawTime(r, entry.time, ui.pos(anchor, Vec2i.init(entry_pos.x + 110, entry_pos.y)), .px16, ui_mod.color_default);
            entry_pos.y += 24;
        }
        const lap_pos = Vec2i.init(entry_pos.x - 40, entry_pos.y + 8);
        ui.drawText(r, "LAP RECORD", ui.pos(anchor, lap_pos), .px12, ui_mod.color_accent);
        ui.drawTime(r, table.lap_record, ui.pos(anchor, Vec2i.init(lap_pos.x + 180, lap_pos.y - 4)), .px16, ui_mod.color_default);
    }

    fn drawRaceStats(self: *State, ctx: DrawContext) void {
        const r = ctx.renderer;
        const ui = ctx.ui;
        r.setView2d();
        const anchor = Anchor.middle | Anchor.center;
        var pos = Vec2i.init(-140, -100 + 32);
        if (self.race_type != .time_trial) {
            const image_pos = ui.pos(anchor, Vec2i.init(pos.x + 180, pos.y));
            const portraits = ctx.menu_assets.portraits[self.pilot];
            if (portraits.resolve(if (self.result.position <= defs.qualifying_rank) 1 else 0)) |texture| {
                r.push2d(image_pos, ui.scaled(r.textureSize(texture)), Rgba.init(0, 0, 0, 128), r.no_texture);
                ui.drawImage(r, image_pos, texture);
            } else |_| {}
            ui.drawText(r, "RACE POSITION", ui.pos(anchor, pos), .px8, ui_mod.color_accent);
            ui.drawNumber(r, self.result.position, ui.pos(anchor, Vec2i.init(pos.x + ui_mod.Ui.textWidth("RACE POSITION", .px8) + 8, pos.y)), .px8, ui_mod.color_default);
        }
        pos.y += 32;
        ui.drawText(r, "RACE STATISTICS", ui.pos(anchor, pos), .px8, ui_mod.color_accent);
        pos.y += 16;
        const player = self.race.playerShipConst();
        var i: usize = 0;
        while (i < defs.num_laps) : (i += 1) {
            ui.drawText(r, "LAP", ui.pos(anchor, Vec2i.init(pos.x + 8, pos.y)), .px8, ui_mod.color_accent);
            ui.drawNumber(r, @intCast(i + 1), ui.pos(anchor, Vec2i.init(pos.x + 50, pos.y)), .px8, ui_mod.color_accent);
            ui.drawTime(r, player.lap_times[i], ui.pos(anchor, Vec2i.init(pos.x + 72, pos.y)), .px8, ui_mod.color_default);
            pos.y += 12;
        }
        pos.y += 32;
        ui.drawText(r, "RACE TIME", ui.pos(anchor, pos), .px8, ui_mod.color_accent);
        pos.y += 12;
        ui.drawTime(r, self.result.race_time, ui.pos(anchor, Vec2i.init(pos.x + 8, pos.y)), .px8, ui_mod.color_default);
        pos.y += 12;
        ui.drawText(r, "BEST LAP", ui.pos(anchor, pos), .px8, ui_mod.color_accent);
        pos.y += 12;
        ui.drawTime(r, self.result.best_lap, ui.pos(anchor, Vec2i.init(pos.x + 8, pos.y)), .px8, ui_mod.color_default);
    }

    fn drawPointsTable(self: *State, ctx: DrawContext, title: []const u8, table: *const [defs.num_pilots]PilotPoints) void {
        _ = title;
        const r = ctx.renderer;
        const ui = ctx.ui;
        r.setView2d();
        const anchor = Anchor.middle | Anchor.center;
        var pos = Vec2i.init(-140, -100 + 32);
        ui.drawText(r, "PILOT NAME", ui.pos(anchor, pos), .px8, ui_mod.color_accent);
        ui.drawText(r, "POINTS", ui.pos(anchor, Vec2i.init(pos.x + 222, pos.y)), .px8, ui_mod.color_accent);
        pos.y += 24;
        for (table) |row| {
            const color = if (row.pilot == self.pilot) ui_mod.color_accent else ui_mod.color_default;
            ui.drawText(r, defs.pilot_names[row.pilot], ui.pos(anchor, pos), .px8, color);
            var buf: [12]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{row.points}) catch "0";
            const w = ui_mod.Ui.textWidth(text, .px8);
            ui.drawText(r, text, ui.pos(anchor, Vec2i.init(pos.x + 280 - w, pos.y)), .px8, color);
            pos.y += 12;
        }
    }

    fn drawHallOfFame(self: *State, ctx: DrawContext) void {
        const r = ctx.renderer;
        const ui = ctx.ui;
        r.setView2d();
        const anchor = Anchor.middle | Anchor.center;
        var pos = Vec2i.init(-120, -100 + 48);
        const tab: save_mod.Tab = if (self.race_type == .time_trial) .time_trial else .race;
        const table = self.save.tableConst(self.race_class, self.circuit, tab);
        var shown_new = false;
        var j: usize = 0;
        var i: usize = 0;
        while (i < save_mod.num_highscores) : (i += 1) {
            if (!shown_new and self.hall.time < table.entries[j].time) {
                self.drawNameEntry(ctx, anchor, pos);
                ui.drawTime(r, self.hall.time, ui.pos(anchor, Vec2i.init(pos.x + 120, pos.y)), .px16, ui_mod.color_default);
                shown_new = true;
            } else {
                ui.drawText(r, std.mem.sliceTo(&table.entries[j].name, 0), ui.pos(anchor, pos), .px16, ui_mod.color_default);
                ui.drawTime(r, table.entries[j].time, ui.pos(anchor, Vec2i.init(pos.x + 120, pos.y)), .px16, ui_mod.color_default);
                j += 1;
            }
            pos.y += 24;
        }
    }

    fn drawNameEntry(self: *State, ctx: DrawContext, anchor: u8, pos: Vec2i) void {
        const r = ctx.renderer;
        const ui = ctx.ui;
        const name = std.mem.sliceTo(&self.hall.name, 0);
        const width = ui_mod.Ui.textWidth(name, .px16);
        const c_pos = ui.pos(anchor, Vec2i.init(pos.x + width, pos.y));
        if (self.hall.char_index == 36) {
            ui.drawIcon(r, .del, c_pos, ui_mod.color_accent);
        } else if (self.hall.char_index == 37) {
            ui.drawIcon(r, .end, c_pos, ui_mod.color_accent);
        } else {
            const ch = [1]u8{hs_charset[@intCast(std.math.clamp(self.hall.char_index, 0, 35))]};
            ui.drawText(r, &ch, c_pos, .px16, ui_mod.color_accent);
        }
        ui.drawText(r, name, ui.pos(anchor, pos), .px16, ui_mod.color_accent);
    }

    const scroll_venom = [_][]const u8{ "#CHAMPION", "YOU HAVE WON THE VENOM CLASS", "CHAMPIONSHIP", "", "THE RAPIER CLASS IS NOW OPEN", "", "FASTER SHIPS AND", "TOUGHER OPPONENTS AWAIT" };
    const scroll_venom_all = [_][]const u8{ "#CHAMPION", "YOU HAVE WON THE VENOM CLASS", "CHAMPIONSHIP ON EVERY CIRCUIT", "", "THE RAPIER CLASS AWAITS" };
    const scroll_rapier = [_][]const u8{ "#RAPIER CHAMPION", "YOU HAVE WON THE RAPIER CLASS", "CHAMPIONSHIP", "", "A BONUS CIRCUIT IS NOW OPEN", "", "FIRESTAR" };
    const scroll_rapier_all = [_][]const u8{ "#LEGEND", "YOU HAVE WON EVERY CHAMPIONSHIP", "ON EVERY CIRCUIT", "", "THERE IS NOTHING LEFT TO PROVE", "", "THANK YOU FOR PLAYING" };

    fn drawScroll(self: *State, ctx: DrawContext) void {
        const r = ctx.renderer;
        const ui = ctx.ui;
        r.setView2d();
        const lines: []const []const u8 = switch (self.scroll_kind) {
            .venom => &scroll_venom,
            .venom_all => &scroll_venom_all,
            .rapier => &scroll_rapier,
            .rapier_all => &scroll_rapier_all,
        };
        const speed: f32 = 32;
        var pos = Vec2i.init(@divTrunc(ui.screen.x, 2), ui.screen.y - @as(i32, @intFromFloat(self.scene_time * speed)));
        for (lines) |line| {
            if (line.len > 0 and line[0] == '#') {
                pos.y += 48;
                ui.drawTextCentered(r, line[1..], pos, .px16, ui_mod.color_accent);
                pos.y += 32;
            } else {
                ui.drawTextCentered(r, line, pos, .px8, ui_mod.color_default);
                pos.y += 12;
            }
        }
    }
};

test "state starts on the title and enters the main menu on select" {
    var s = State.init(save_mod.defaults);
    try std.testing.expectEqual(Scene.title, s.scene);
    var in = input.State{};
    in.set(.menu_start, true);
    var rng = Rng.seed(1);
    var assets: race_mod.Assets = undefined;
    s.update(.{ .input = &in, .rng = &rng, .tick = 1.0 / 60.0, .track = null, .track_number = 0, .assets = &assets });
    try std.testing.expectEqual(Scene.main_menu, s.scene);
    try std.testing.expectEqual(@as(usize, 1), s.menu.depth());
}

fn press(s: *State, action: input.Action) void {
    var in = input.State{};
    in.set(action, true);
    var rng = Rng.seed(1);
    var assets: race_mod.Assets = undefined;
    s.update(.{ .input = &in, .rng = &rng, .tick = 1.0 / 60.0, .track = null, .track_number = 0, .assets = &assets });
}

test "menu walk: venom, single race, Auricom, Arian Tetsuo, Karbonis" {
    var s = State.init(save_mod.defaults);
    press(&s, .menu_start);
    press(&s, .menu_select); // START GAME
    press(&s, .menu_select); // VENOM CLASS
    press(&s, .menu_down);
    press(&s, .menu_select); // SINGLE RACE
    press(&s, .menu_down);
    press(&s, .menu_select); // AURICOM
    press(&s, .menu_down);
    press(&s, .menu_select); // second pilot of the team
    press(&s, .menu_down);
    press(&s, .menu_select); // KARBONIS V
    try std.testing.expectEqual(Scene.race, s.scene);
    try std.testing.expectEqual(@as(u8, 1), s.race_pending);
    try std.testing.expectEqual(RaceType.single, s.race_type);
    try std.testing.expectEqual(defs.team_pilots[1][1], s.pilot);
    try std.testing.expectEqual(@as(?u8, 4), s.wantedTrack());
}

test "rapier class is refused until unlocked" {
    var s = State.init(save_mod.defaults);
    s.save.has_rapier_class = 0;
    press(&s, .menu_start);
    press(&s, .menu_select);
    press(&s, .menu_down);
    press(&s, .menu_select); // RAPIER CLASS: not available
    try std.testing.expectEqual(@as(usize, 2), s.menu.depth());
    s.save.has_rapier_class = 1;
    press(&s, .menu_select);
    try std.testing.expectEqual(@as(usize, 3), s.menu.depth());
    try std.testing.expectEqual(@as(u8, 1), s.race_class);
}

test "championship awards points and orders the table" {
    var s = State.init(save_mod.defaults);
    s.race_type = .championship;
    s.circuit = 0;
    s.resetChampionship();
    s.race = std.mem.zeroes(race_mod.Race);
    s.race.player = 3;
    s.race.ranks = .{ 5, 3, 0, 1, 2, 4, 6, 7 };
    s.race.ships[3].position_rank = 2;
    s.race.ships[3].lap = defs.num_laps;
    s.race.ships[3].lap_times = .{ 60, 61, 62 };
    s.raceEnd();
    try std.testing.expectEqual(@as(i32, 2), s.result.position);
    try std.testing.expectEqual(@as(u8, 5), s.championship[0].pilot);
    try std.testing.expectEqual(@as(i32, 9), s.championship[0].points);
    try std.testing.expectEqual(@as(u8, 3), s.championship[1].pilot);
    try std.testing.expectEqual(@as(i32, 7), s.championship[1].points);
    try std.testing.expectEqual(s.race.ranks, s.grid_order);
    try std.testing.expectEqual(@as(u8, 1), s.menu_active);
}

test "hall of fame entry inserts the name in time order" {
    var s = State.init(save_mod.defaults);
    s.race_type = .single;
    s.race_class = 0;
    s.circuit = 2;
    s.debugHallOfFame(100);
    // Type "ZZ" then END: Z is char 25, END is 37.
    s.hall.char_index = 25;
    var in = input.State{};
    in.set(.menu_select, true);
    try std.testing.expect(s.hallOfFameInput(&in));
    try std.testing.expect(s.hallOfFameInput(&in));
    s.hall.char_index = 37;
    try std.testing.expect(s.hallOfFameInput(&in));
    const table = s.save.tableConst(0, 2, .race);
    try std.testing.expectEqualStrings("ZZ", std.mem.sliceTo(&table.entries[0].name, 0));
    try std.testing.expectEqual(@as(f32, 100), table.entries[0].time);
    try std.testing.expectEqualStrings("ZZ", std.mem.sliceTo(&s.save.highscores_name, 0));
    try std.testing.expectEqual(@as(u8, 1), s.save_dirty);
}

test "winning the last circuit unlocks and shows the scroller" {
    var s = State.init(save_mod.defaults);
    s.save.has_rapier_class = 0;
    s.save.has_bonus_circuits = 0;
    s.race_type = .championship;
    s.race_class = 0;
    s.circuit = defs.num_non_bonus_circuits - 1;
    s.raceNext();
    try std.testing.expectEqual(@as(u8, 1), s.save.has_rapier_class);
    try std.testing.expectEqual(ScrollKind.venom, s.scroll_kind);
    try std.testing.expectEqual(@intFromEnum(PageKind.text_scroll), s.menu.current().?.kind);
    press(&s, .menu_select);
    try std.testing.expectEqual(Scene.main_menu, s.scene);

    // Mid-championship the next circuit simply starts.
    s.race_type = .championship;
    s.circuit = 0;
    s.raceNext();
    try std.testing.expectEqual(@as(u8, 1), s.circuit);
    try std.testing.expectEqual(Scene.race, s.scene);
    try std.testing.expectEqual(@as(u8, 1), s.race_pending);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(State);
}
