//! The `build_options` module: see buildOptions in build.zig.

const std = @import("std");
const release = @import("release");

pub const version = if (release.release_version.len > 0) release.release_version else dev: {
    const commit = std.mem.trim(u8, @embedFile("commit"), " \t\r\n");
    break :dev if (commit.len > 0) "0.0.0-dev+" ++ commit else "0.0.0-dev";
};
