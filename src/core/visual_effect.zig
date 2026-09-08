const std = @import("std");

/// Where an effect draws. Cell effects paint the terminal grid and can
/// interleave with live UI; pixel effects render an RGB framebuffer shipped
/// through the Kitty graphics protocol and are opaque by nature.
pub const Backend = enum { cell, pixel };

pub const Kind = enum {
    // cell effects
    matrix,
    strings,
    stars,
    plasma,
    // pixel effects (Kitty graphics); tetris and pacman also have cell renderers
    tetris,
    pacman,
    tunnel,
    metaballs,
    horizon,
    demo,
    daybreak,
    orb,
    /// wipEout: a playable game, not a screensaver. Manual only.
    wipeout,

    pub fn parse(value: []const u8) ?Kind {
        inline for (std.meta.fields(Kind)) |field| {
            if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
        }
        // daybreak's first name (2026-09-04), kept so a saved config still loads.
        if (std.ascii.eqlIgnoreCase(value, "shadowbox")) return .daybreak;
        return null;
    }

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn description(self: Kind) []const u8 {
        return switch (self) {
            .matrix => "falling green symbols",
            .strings => "dancing sine curves",
            .stars => "forward-flying starfield",
            .plasma => "color-cycling demoscene plasma",
            .tetris => "self-playing arcade Tetris (Kitty graphics, or cells; manual only)",
            .pacman => "self-playing Pac-Man (after feiss' js1k entry; Kitty graphics, or cells)",
            .tunnel => "spinning pixel tunnel (Kitty graphics)",
            .metaballs => "pixel metaballs (Kitty graphics)",
            .horizon => "synthwave horizon (Kitty graphics)",
            .demo => "24-second pixel demoscene sequence (Kitty graphics)",
            .daybreak => "a landscape that follows the real sun over your machine (Kitty graphics)",
            .orb => "a thinking orb: a glowing, slowly turning sphere of thousands of particles, over blurred Marlin (Kitty graphics)",
            .wipeout => "wipEout, playable (Kitty graphics; start with !wipeout)",
        };
    }

    /// The backend an effect prefers. Pixel kinds need Kitty graphics.
    pub fn backend(self: Kind) Backend {
        return switch (self) {
            .matrix, .strings, .stars, .plasma => .cell,
            .tetris, .pacman, .tunnel, .metaballs, .horizon, .demo, .daybreak, .orb, .wipeout => .pixel,
        };
    }

    /// Kinds that can also be drawn on cells (every cell kind, plus the games).
    pub fn cellCapable(self: Kind) bool {
        return self.backend() == .cell or self == .pacman or self == .tetris;
    }

    /// Effects that only make sense opaque: pixel images cannot interleave
    /// with text, and games need their whole board.
    pub fn fullScreenOnly(self: Kind) bool {
        return self.backend() == .pixel or self == .pacman or self == .tetris;
    }

    /// Manual-only effects may be named by `/animate` or `/screensaver`, but
    /// cannot become the idle timer or bare `gs` default.
    pub fn configurable(self: Kind) bool {
        return self != .tetris and self != .wipeout;
    }

    /// Games with their own command (`!wipeout`): they take the whole
    /// screen and the keyboard, so `/animate` and `/screensaver` refuse
    /// them and the usage lists leave them out.
    pub fn playable(self: Kind) bool {
        return self == .wipeout;
    }

    /// What to run on cells when a pixel effect is requested on a terminal
    /// without Kitty graphics: the kind itself when it has a cell renderer,
    /// otherwise a cell sibling chosen for visual kinship.
    pub fn fallback(self: Kind) Kind {
        return switch (self) {
            .tunnel, .demo => .plasma,
            .metaballs => .plasma,
            .horizon, .daybreak, .orb, .wipeout => .stars,
            else => self,
        };
    }
};

pub const kinds = std.enums.values(Kind);

/// `matrix|strings|stars|…` for usage strings; generated so a new effect can
/// never be missing from the help.
pub const usage_list = blk: {
    var text: []const u8 = "";
    var count: usize = 0;
    for (std.meta.fields(Kind)) |field| {
        const kind: Kind = @enumFromInt(field.value);
        if (kind.playable()) continue;
        text = text ++ (if (count == 0) "" else "|") ++ field.name;
        count += 1;
    }
    break :blk text;
};

pub const configurable_usage_list = blk: {
    var text: []const u8 = "";
    var count: usize = 0;
    for (std.meta.fields(Kind)) |field| {
        const kind: Kind = @enumFromInt(field.value);
        if (!kind.configurable() or kind.playable()) continue;
        text = text ++ (if (count == 0) "" else "|") ++ field.name;
        count += 1;
    }
    break :blk text;
};
