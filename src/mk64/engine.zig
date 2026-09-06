//! Mario class tables from data/kart_attributes.c; 200cc is custom tuning.
const std = @import("std");
pub const Class = enum {
    cc50,
    cc100,
    cc150,
    cc200,
    pub fn next(self: Class) Class {
        return @enumFromInt((@as(u8, @intFromEnum(self)) + 1) % 4);
    }
    pub fn label(self: Class) []const u8 {
        return switch (self) {
            .cc50 => "50CC",
            .cc100 => "100CC",
            .cc150 => "150CC",
            .cc200 => "200CC*",
        };
    }
    pub fn file(self: Class) []const u8 {
        return switch (self) {
            .cc50 => "luigi-50cc-v1.ghost",
            .cc100 => "luigi-100cc-v1.ghost",
            .cc150 => "luigi-150cc-v1.ghost",
            .cc200 => "luigi-200cc-v1.ghost",
        };
    }
    pub fn top(self: Class) f32 {
        return switch (self) {
            .cc50 => 290,
            .cc100 => 310,
            .cc150 => 320,
            .cc200 => 370,
        };
    }
    pub fn lateral(self: Class) f32 {
        return switch (self) {
            .cc50, .cc100 => 28,
            .cc150, .cc200 => 35,
        };
    }
    pub fn drag(self: Class) f32 {
        return switch (self) {
            .cc50 => -10,
            .cc100 => -15,
            .cc150, .cc200 => -20,
        };
    }
};
test "class cycle and original Mario tuning" {
    try std.testing.expectEqual(Class.cc50, Class.cc200.next());
    try std.testing.expectEqual(@as(f32, 320), Class.cc150.top());
    try std.testing.expect(!std.mem.eql(u8, Class.cc100.file(), Class.cc200.file()));
}
