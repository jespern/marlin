//! Bounds-checked cursor over asset bytes. The PSX data mixes big-endian
//! (track, PRM) and little-endian (TIM, CMP) fields, so both are explicit.

const std = @import("std");

pub const Error = error{UnexpectedEof};

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.pos;
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.bytes.len;
    }

    pub fn skip(self: *Reader, n: usize) Error!void {
        if (self.remaining() < n) return error.UnexpectedEof;
        self.pos += n;
    }

    pub fn u8At(self: *Reader) Error!u8 {
        if (self.remaining() < 1) return error.UnexpectedEof;
        const v = self.bytes[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn i8At(self: *Reader) Error!i8 {
        return @bitCast(try self.u8At());
    }

    pub fn u16Be(self: *Reader) Error!u16 {
        if (self.remaining() < 2) return error.UnexpectedEof;
        const v = std.mem.readInt(u16, self.bytes[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    pub fn i16Be(self: *Reader) Error!i16 {
        return @bitCast(try self.u16Be());
    }

    pub fn u32Be(self: *Reader) Error!u32 {
        if (self.remaining() < 4) return error.UnexpectedEof;
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    pub fn i32Be(self: *Reader) Error!i32 {
        return @bitCast(try self.u32Be());
    }

    pub fn u16Le(self: *Reader) Error!u16 {
        if (self.remaining() < 2) return error.UnexpectedEof;
        const v = std.mem.readInt(u16, self.bytes[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn i16Le(self: *Reader) Error!i16 {
        return @bitCast(try self.u16Le());
    }

    pub fn u32Le(self: *Reader) Error!u32 {
        if (self.remaining() < 4) return error.UnexpectedEof;
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn i32Le(self: *Reader) Error!i32 {
        return @bitCast(try self.u32Le());
    }
};

test "big and little endian reads" {
    var r = Reader.init(&.{ 0x01, 0x02, 0x03, 0x04, 0xff });
    try std.testing.expectEqual(@as(u16, 0x0102), try r.u16Be());
    try std.testing.expectEqual(@as(u16, 0x0403), try r.u16Le());
    try std.testing.expectEqual(@as(i8, -1), try r.i8At());
    try std.testing.expectError(error.UnexpectedEof, r.u8At());
}
