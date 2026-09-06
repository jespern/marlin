//! Persistent player data: options, unlocks and the best-times tables,
//! kept separately from race snapshots at
//! `$XDG_STATE_HOME/marlin/wipeout-save.bin`. Defaults are the original's
//! factory tables.

const std = @import("std");
const Io = std.Io;

pub const magic: u32 = 0x5750_5356; // "WPSV"
pub const version: u32 = 1;
pub const num_highscores = 5;
pub const num_circuits = 7;
pub const num_classes = 2;
pub const num_tabs = 2;

pub const Tab = enum(u8) { time_trial = 0, race = 1 };

pub const Entry = extern struct {
    name: [4]u8,
    time: f32,
};

pub const Highscores = extern struct {
    entries: [num_highscores]Entry,
    lap_record: f32,
};

pub const SaveData = extern struct {
    magic: u32 = magic,
    version: u32 = version,
    size: u32 = @sizeOf(SaveData),
    /// Cockpit roll as tenths (0-10).
    internal_roll: u8 = 6,
    /// 0 disabled, 1 reduced, 2 full.
    screen_shake: u8 = 2,
    crt: u8 = 0,
    difficulty: u8 = 1,
    has_rapier_class: u8 = 1,
    has_bonus_circuits: u8 = 1,
    _pad: [2]u8 = .{ 0, 0 },
    highscores_name: [4]u8 = .{ 0, 0, 0, 0 },
    highscores: [num_classes][num_circuits][num_tabs]Highscores,

    pub fn valid(self: *const SaveData) bool {
        return self.magic == magic and self.version == version and self.size == @sizeOf(SaveData);
    }

    pub fn table(self: *SaveData, class: u8, circuit: u8, tab: Tab) *Highscores {
        return &self.highscores[class][circuit][@intFromEnum(tab)];
    }

    pub fn tableConst(self: *const SaveData, class: u8, circuit: u8, tab: Tab) *const Highscores {
        return &self.highscores[class][circuit][@intFromEnum(tab)];
    }
};

fn e(name: *const [3]u8, time: f32) Entry {
    return .{ .name = .{ name[0], name[1], name[2], 0 }, .time = time };
}

fn e2(name: *const [2]u8, time: f32) Entry {
    return .{ .name = .{ name[0], name[1], 0, 0 }, .time = time };
}

fn hs(lap: f32, entries: [num_highscores]Entry) Highscores {
    return .{ .entries = entries, .lap_record = lap };
}

/// The factory tables, per class, per circuit, race tab then time-trial
/// tab (the original stores them in that order under indices 1 and 0).
pub const defaults: SaveData = blk: {
    var d = SaveData{ .highscores = undefined };
    const R = @intFromEnum(Tab.race);
    const T = @intFromEnum(Tab.time_trial);
    // Venom
    d.highscores[0][0][R] = hs(85.83, .{ e("WIP", 254.50), e("EOU", 271.17), e("TPC", 289.50), e("NOT", 294.50), e("PSX", 314.50) });
    d.highscores[0][0][T] = hs(85.83, .{ e("MVE", 254.50), e("ALM", 271.17), e("POL", 289.50), e("NIK", 294.50), e("DAR", 314.50) });
    d.highscores[0][1][R] = hs(55.33, .{ e("AJY", 159.33), e("AJS", 172.67), e("DLS", 191.00), e("MAK", 207.67), e("JED", 219.33) });
    d.highscores[0][1][T] = hs(55.33, .{ e("DAR", 159.33), e("STU", 172.67), e("MOC", 191.00), e("DOM", 207.67), e("NIK", 219.33) });
    d.highscores[0][2][R] = hs(57.5, .{ e2("JD", 171.00), e("AJC", 189.33), e("MSA", 202.67), e2("SD", 219.33), e("TIM", 232.67) });
    d.highscores[0][2][T] = hs(57.5, .{ e("PHO", 171.00), e("ENI", 189.33), e2("XR", 202.67), e("ISI", 219.33), e2("NG", 232.67) });
    d.highscores[0][3][R] = hs(85.17, .{ e("POL", 251.33), e("DAR", 263.00), e("JAS", 283.00), e("ROB", 294.67), e("DJR", 314.82) });
    d.highscores[0][3][T] = hs(85.17, .{ e("DOM", 251.33), e("DJR", 263.00), e("MPI", 283.00), e("GOC", 294.67), e("SUE", 314.82) });
    d.highscores[0][4][R] = hs(80.17, .{ e("NIK", 236.17), e("SAL", 253.17), e("DOM", 262.33), e2("LG", 282.67), e("LNK", 298.17) });
    d.highscores[0][4][T] = hs(80.17, .{ e("NIK", 236.17), e("ROB", 253.17), e2("AM", 262.33), e("JAS", 282.67), e("DAR", 298.17) });
    d.highscores[0][5][R] = hs(61.67, .{ e("HAN", 182.33), e("PER", 196.33), e("FEC", 214.83), e("TPI", 228.83), e("ZZA", 244.33) });
    d.highscores[0][5][T] = hs(61.67, .{ e2("FC", 182.33), e("SUE", 196.33), e("ROB", 214.83), e("JEN", 228.83), e2("NT", 244.33) });
    d.highscores[0][6][R] = hs(63.83, .{ e("CAN", 195.40), e("WEH", 209.23), e("AVE", 227.90), e("ABO", 239.90), e("NUS", 240.73) });
    d.highscores[0][6][T] = hs(63.83, .{ e("DJR", 195.40), e("NIK", 209.23), e("JAS", 227.90), e("NCW", 239.90), e("LOU", 240.73) });
    // Rapier
    d.highscores[1][0][R] = hs(69.50, .{ e("AJY", 200.67), e("DLS", 213.50), e("AJS", 228.67), e("MAK", 247.67), e("JED", 263.00) });
    d.highscores[1][0][T] = hs(69.50, .{ e("NCW", 200.67), e("LEE", 213.50), e("STU", 228.67), e("JAS", 247.67), e("ROB", 263.00) });
    d.highscores[1][1][R] = hs(47.33, .{ e("BOR", 134.58), e("ING", 147.00), e("HIS", 162.25), e("COR", 183.08), e2("ES", 198.25) });
    d.highscores[1][1][T] = hs(47.33, .{ e("NIK", 134.58), e("POL", 147.00), e("DAR", 162.25), e("STU", 183.08), e("ROB", 198.25) });
    d.highscores[1][2][R] = hs(47.83, .{ e("AJS", 142.08), e("DLS", 159.42), e("MAK", 178.08), e("JED", 190.25), e("AJY", 206.58) });
    d.highscores[1][2][T] = hs(47.83, .{ e("POL", 142.08), e("JIM", 159.42), e("TIM", 178.08), e("MOC", 190.25), e2("PC", 206.58) });
    d.highscores[1][3][R] = hs(76.75, .{ e("DLS", 224.17), e("DJR", 237.00), e("LEE", 257.50), e("MOC", 272.83), e("MPI", 285.17) });
    d.highscores[1][3][T] = hs(76.75, .{ e("TIM", 224.17), e("JIM", 237.00), e("NIK", 257.50), e("JAS", 272.83), e2("LG", 285.17) });
    d.highscores[1][4][R] = hs(65.75, .{ e("MAK", 191.00), e("STU", 203.67), e("JAS", 221.83), e("ROB", 239.00), e("DOM", 254.50) });
    d.highscores[1][4][T] = hs(65.75, .{ e2("LG", 191.00), e("LOU", 203.67), e("JIM", 221.83), e("HAN", 239.00), e2("NT", 254.50) });
    d.highscores[1][5][R] = hs(59.23, .{ e("JED", 156.67), e("NCW", 170.33), e("LOU", 188.83), e("DAR", 201.00), e("POL", 221.50) });
    d.highscores[1][5][T] = hs(59.23, .{ e("STU", 156.67), e("DAV", 170.33), e("DOM", 188.83), e("MOR", 201.00), e("GAN", 221.50) });
    d.highscores[1][6][R] = hs(55.00, .{ e2("PC", 162.42), e("POL", 179.58), e("DAR", 194.75), e("DAR", 208.92), e("MSC", 224.58) });
    d.highscores[1][6][T] = hs(55.00, .{ e("THA", 162.42), e("NKS", 179.58), e("FOR", 194.75), e("PLA", 208.92), e("YIN", 224.58) });
    break :blk d;
};

pub fn defaultPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("XDG_STATE_HOME")) |state| {
        if (state.len > 0) return std.fs.path.join(gpa, &.{ state, "marlin", "wipeout-save.bin" });
    }
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "marlin", "wipeout-save.bin" });
}

pub fn write(io: Io, path: []const u8, data: *const SaveData) !void {
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.asBytes(data) });
}

/// Defaults when missing or from another layout.
pub fn read(io: Io, gpa: std.mem.Allocator, path: []const u8) SaveData {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(@sizeOf(SaveData) + 16)) catch return defaults;
    defer gpa.free(bytes);
    if (bytes.len != @sizeOf(SaveData)) return defaults;
    var data: SaveData = undefined;
    @memcpy(std.mem.asBytes(&data), bytes);
    return if (data.valid()) data else defaults;
}

test "defaults are valid and ordered" {
    try std.testing.expect(defaults.valid());
    const t = defaults.tableConst(0, 2, .race);
    try std.testing.expect(t.entries[0].time < t.entries[4].time);
    try std.testing.expectEqualStrings("JD", std.mem.sliceTo(&t.entries[0].name, 0));
}
