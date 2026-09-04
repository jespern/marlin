//! Scoped macOS power assertion: while any session is running a turn,
//! marlind prevents IDLE system sleep — the machine will not doze off under
//! a long turn just because nobody is typing. This is the same assertion
//! NSActivityIdleSystemSleepDisabled takes, created through the IOKit C API
//! directly (no Objective-C runtime). Closing the lid still sleeps the
//! machine: forced sleep ignores every user-space assertion by design.
//!
//! Other platforms compile the same type with no-op semantics; a remote
//! marlind on a Linux box has nothing to assert.

const std = @import("std");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;

const CFStringRef = *const anyopaque;
const kCFStringEncodingUTF8: u32 = 0x0800_0100;
const kIOPMAssertionLevelOn: u32 = 255;

extern "c" fn CFStringCreateWithCString(
    alloc: ?*const anyopaque,
    c_str: [*:0]const u8,
    encoding: u32,
) ?CFStringRef;
extern "c" fn IOPMAssertionCreateWithName(
    assertion_type: CFStringRef,
    level: u32,
    name: CFStringRef,
    id: *u32,
) c_int;
extern "c" fn IOPMAssertionRelease(id: u32) c_int;

/// Static CFStrings, created once and deliberately never released; the
/// dispatcher is the only caller, so no synchronization is needed.
var assertion_type: ?CFStringRef = null;
var assertion_name: ?CFStringRef = null;

fn staticStrings() ?struct { kind: CFStringRef, name: CFStringRef } {
    if (assertion_type == null)
        assertion_type = CFStringCreateWithCString(null, "PreventUserIdleSystemSleep", kCFStringEncodingUTF8);
    if (assertion_name == null)
        assertion_name = CFStringCreateWithCString(null, "Marlin: a session turn is running", kCFStringEncodingUTF8);
    return .{
        .kind = assertion_type orelse return null,
        .name = assertion_name orelse return null,
    };
}

/// One held-or-not assertion, synced by the dispatcher after every event.
/// Shows up attributed to marlind in `pmset -g assertions` while held.
pub const SleepAssertion = struct {
    id: u32 = 0,
    held: bool = false,

    pub fn sync(self: *SleepAssertion, want_awake: bool) void {
        if (!is_macos) return;
        if (want_awake == self.held) return;
        if (want_awake) {
            const strings = staticStrings() orelse return;
            var id: u32 = 0;
            if (IOPMAssertionCreateWithName(strings.kind, kIOPMAssertionLevelOn, strings.name, &id) != 0) {
                std.log.debug("could not take the idle-sleep assertion", .{});
                return;
            }
            self.id = id;
            self.held = true;
        } else {
            _ = IOPMAssertionRelease(self.id);
            self.id = 0;
            self.held = false;
        }
    }
};
