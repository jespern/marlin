//! Game actions and their per-frame state. Digital inputs are 0 or 1; the
//! float keeps room for analog steering later, as in the original.

const std = @import("std");

pub const Action = enum(u8) {
    up,
    down,
    left,
    right,
    brake_left,
    brake_right,
    thrust,
    fire,
    change_view,
};

pub const count = @typeInfo(Action).@"enum".fields.len;

pub const State = extern struct {
    held: [count]f32 = [_]f32{0} ** count,
    pressed: [count]bool = [_]bool{false} ** count,

    pub fn state(self: *const State, action: Action) f32 {
        return self.held[@intFromEnum(action)];
    }

    pub fn isPressed(self: *const State, action: Action) bool {
        return self.pressed[@intFromEnum(action)];
    }

    pub fn set(self: *State, action: Action, down: bool) void {
        const i = @intFromEnum(action);
        if (down and self.held[i] == 0) self.pressed[i] = true;
        self.held[i] = if (down) 1 else 0;
    }

    pub fn anyHeld(self: *const State) bool {
        for (self.held) |h| {
            if (h != 0) return true;
        }
        return false;
    }

    /// Clear edge-triggered presses; call once per game step.
    pub fn endFrame(self: *State) void {
        @memset(&self.pressed, false);
    }
};
