//! TUI client: libvaxis. Modal (insert/normal), herdr-lookalike layout.
//! See docs/ARCHITECTURE.md §8 for layout, modes, keybinds, !c family.
//!
//! Not started until M2. The vaxis dependency is added to build.zig.zon then.

const std = @import("std");

// TODO(M2): vaxis init, event loop, mode state machine, ui/ modules:
//   ui/layout.zig        binary-tree splits, focus
//   ui/session_view.zig  virtual block list, streaming region, collapse
//   ui/sidebar.zig       session list + status glyphs
//   ui/input.zig         prompt box, /-commands, !-commands, history
//   ui/select.zig        mouse selection over logical text, OSC52 copy
//   ui/markdown.zig      minimal md render
// (ui/ files are created in M2 — no point stubbing renderers before the
//  data they render exists.)

test {
    std.testing.refAllDecls(@This());
}
