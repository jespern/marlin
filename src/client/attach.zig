//! Socket client shared by TUI and headless: connect, handshake, reconnect
//! with from_seq resume, delta buffering.
//!
//! DEPENDENCY RULE: client/ imports only core/ (never daemon/). This is what
//! keeps "the TUI is just a client" true and makes the future web client a
//! sibling, not a fork.

const std = @import("std");
const proto = @import("../core/proto.zig");

// TODO(M1): unix socket connect, NDJSON read/write loops, per-session
//           last-seen-seq tracking, autostart-daemon-if-absent handshake.

test {
    std.testing.refAllDecls(@This());
}
