//! Model reasoning-effort setting shared by clients, persistence, and
//! provider adapters. `auto` means omit the provider parameter so the
//! selected model keeps its own default.

const std = @import("std");

pub const Effort = enum {
    auto,
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,

    pub const choices = [_][]const u8{
        "auto",
        "none",
        "minimal",
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
    };

    pub fn parse(value: []const u8) ?Effort {
        inline for (std.meta.fields(Effort)) |field| {
            if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn providerValue(self: Effort) ?[]const u8 {
        return if (self == .auto) null else @tagName(self);
    }
};
