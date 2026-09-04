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
    // pixel effects (Kitty graphics); pacman also has a cell renderer
    pacman,
    tunnel,
    metaballs,
    horizon,
    demo,

    pub fn parse(value: []const u8) ?Kind {
        inline for (std.meta.fields(Kind)) |field| {
            if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
        }
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
            .pacman => "self-playing Pac-Man (after feiss' js1k entry; Kitty graphics, or cells)",
            .tunnel => "spinning pixel tunnel (Kitty graphics)",
            .metaballs => "pixel metaballs (Kitty graphics)",
            .horizon => "synthwave horizon (Kitty graphics)",
            .demo => "24-second pixel demoscene sequence (Kitty graphics)",
        };
    }

    /// The backend an effect prefers. Pixel kinds need Kitty graphics.
    pub fn backend(self: Kind) Backend {
        return switch (self) {
            .matrix, .strings, .stars, .plasma => .cell,
            .pacman, .tunnel, .metaballs, .horizon, .demo => .pixel,
        };
    }

    /// Kinds that can also be drawn on cells (every cell kind, plus Pac-Man).
    pub fn cellCapable(self: Kind) bool {
        return self.backend() == .cell or self == .pacman;
    }

    /// Effects that only make sense opaque: pixel images cannot interleave
    /// with text, and a maze needs its whole board.
    pub fn fullScreenOnly(self: Kind) bool {
        return self.backend() == .pixel or self == .pacman;
    }

    /// What to run on cells when a pixel effect is requested on a terminal
    /// without Kitty graphics: the kind itself when it has a cell renderer,
    /// otherwise a cell sibling chosen for visual kinship.
    pub fn fallback(self: Kind) Kind {
        return switch (self) {
            .tunnel, .demo => .plasma,
            .metaballs => .plasma,
            .horizon => .stars,
            else => self,
        };
    }
};

pub const kinds = std.enums.values(Kind);

/// `matrix|strings|stars|…` for usage strings; generated so a new effect can
/// never be missing from the help.
pub const usage_list = blk: {
    var text: []const u8 = "";
    for (std.meta.fields(Kind), 0..) |field, i| {
        text = text ++ (if (i == 0) "" else "|") ++ field.name;
    }
    break :blk text;
};

test "visual effect names parse case-insensitively" {
    try std.testing.expectEqual(Kind.strings, Kind.parse("STRINGS").?);
    try std.testing.expectEqual(Kind.stars, Kind.parse("stars").?);
    try std.testing.expectEqual(Kind.tunnel, Kind.parse("Tunnel").?);
    try std.testing.expect(Kind.parse("nope") == null);
}

test "backends, fallbacks, and the generated usage list" {
    try std.testing.expectEqual(Backend.cell, Kind.matrix.backend());
    try std.testing.expectEqual(Backend.pixel, Kind.tunnel.backend());
    try std.testing.expectEqual(Backend.pixel, Kind.pacman.backend());
    try std.testing.expect(Kind.pacman.cellCapable() and Kind.matrix.cellCapable() and !Kind.tunnel.cellCapable());
    try std.testing.expectEqual(Kind.pacman, Kind.pacman.fallback());
    try std.testing.expect(Kind.pacman.fullScreenOnly());
    try std.testing.expect(!Kind.matrix.fullScreenOnly());
    try std.testing.expectEqual(Kind.plasma, Kind.tunnel.fallback());
    try std.testing.expectEqual(Kind.stars, Kind.horizon.fallback());
    try std.testing.expectEqual(Kind.matrix, Kind.matrix.fallback());
    try std.testing.expectEqualStrings("matrix|strings|stars|plasma|pacman|tunnel|metaballs|horizon|demo", usage_list);
}
