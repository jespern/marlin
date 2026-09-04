const std = @import("std");

pub const Kind = enum {
    matrix,
    strings,
    stars,
    plasma,

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
        };
    }
};

pub const kinds = std.enums.values(Kind);

test "visual effect names parse case-insensitively" {
    try std.testing.expectEqual(Kind.strings, Kind.parse("STRINGS").?);
    try std.testing.expectEqual(Kind.stars, Kind.parse("stars").?);
    try std.testing.expect(Kind.parse("tunnel") == null);
}
