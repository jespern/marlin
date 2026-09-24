const std = @import("std");

pub const Action = enum { list, marketplace_add, marketplace_update, marketplace_remove, install, uninstall };
pub const Command = struct { action: Action, argument: []const u8 = "" };
pub const usage = "/plugin [list|marketplace add <repo>|marketplace update <name>|marketplace remove <name>|install <plugin>@<marketplace>|uninstall <plugin>@<marketplace>]";

pub fn parse(args: []const []const u8) ?Command {
    if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "list"))) return .{ .action = .list };
    if (args.len == 2) {
        if (std.mem.eql(u8, args[0], "install")) return .{ .action = .install, .argument = args[1] };
        if (std.mem.eql(u8, args[0], "uninstall")) return .{ .action = .uninstall, .argument = args[1] };
        if (std.mem.eql(u8, args[0], "marketplace") and std.mem.eql(u8, args[1], "list")) return .{ .action = .list };
    }
    if (args.len == 3 and std.mem.eql(u8, args[0], "marketplace")) {
        if (std.mem.eql(u8, args[1], "add")) return .{ .action = .marketplace_add, .argument = args[2] };
        if (std.mem.eql(u8, args[1], "update")) return .{ .action = .marketplace_update, .argument = args[2] };
        if (std.mem.eql(u8, args[1], "remove")) return .{ .action = .marketplace_remove, .argument = args[2] };
    }
    return null;
}
