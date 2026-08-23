//! Skills: markdown files w/ YAML frontmatter in ~/.config/marlin/skills/.
//! Index (name + one-line description) is injected into the system prompt;
//! the `skill` tool loads full content on demand. Compatible with the
//! emerging cross-tool skills convention. (docs/ARCHITECTURE.md §7)

const std = @import("std");

// TODO(M5): directory scan, frontmatter parse (name/description), index
// string builder (stable ordering — it's part of the cached system prompt!),
// skill tool registration.

test {
    std.testing.refAllDecls(@This());
}
