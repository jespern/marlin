//! marlind: the daemon. Owns all state — sessions, agent loops, the store,
//! provider connections, tool execution, MCP clients, hooks.
//!
//! Main loop: poll/kqueue over the listener + connected clients; agent turns
//! run on their own threads and push events through an MPSC queue that this
//! thread drains, persists, and fans out to subscribed clients.
//! See docs/ARCHITECTURE.md §1 (process/concurrency model).

const std = @import("std");
const Io = std.Io;

pub const socket_dir_env = "XDG_RUNTIME_DIR";
pub const socket_name = "marlin/daemon.sock";

// TODO(M1):
//   - unix socket listener (0600), flock+pidfile for single-instance
//   - client registry: hello handshake, per-client subscription set
//   - event fan-out: agent MPSC queue → persist block → broadcast to subs
//   - session lifecycle: create/kill/rename/list
//   - autostart handshake: `marlin` spawns `marlin daemon` if socket dead

pub fn serveStub(io: Io) !void {
    var buf: [256]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    try w.interface.print("marlind: not implemented yet (M1) — see docs/MILESTONES.md\n", .{});
    try w.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
}
