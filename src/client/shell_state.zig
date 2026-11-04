//! Per-session state of a shell session (`!!`), owned by its SessionView so
//! it travels with the session between tabs.
const std = @import("std");
const shell_term = @import("shell_term.zig");
const Line = @import("render.zig").Line;

pub const ShellState = struct {
    gpa: std.mem.Allocator,
    request_id: u64 = 0,
    /// Null until the daemon confirms the shell.
    shell_id: ?u64 = null,
    /// Null until the first snapshot arrives.
    emulator: ?*shell_term.Emulator = null,
    /// False while the connection is down, until reattached.
    attached: bool = true,
    /// Input typed before the shell was confirmed.
    pending: std.ArrayList(u8) = .empty,
    /// Grid size last told to the daemon.
    sent_cols: u16 = 0,
    sent_rows: u16 = 0,
    /// Transcript rows of the terminal (scrollback then screen), rebuilt
    /// when its output or the width changes.
    lines_arena: std.heap.ArenaAllocator,
    lines: []const Line = &.{},
    lines_generation: u64 = std.math.maxInt(u64),
    lines_width: usize = 0,

    pub fn create(gpa: std.mem.Allocator) !*ShellState {
        const self = try gpa.create(ShellState);
        self.* = .{ .gpa = gpa, .lines_arena = .init(gpa) };
        return self;
    }

    pub fn destroy(self: *ShellState) void {
        const gpa = self.gpa;
        if (self.emulator) |emulator| emulator.destroy();
        self.pending.deinit(gpa);
        self.lines_arena.deinit();
        gpa.destroy(self);
    }

    pub fn live(self: *const ShellState) ?*shell_term.Emulator {
        if (!self.attached) return null;
        return self.emulator;
    }
};
