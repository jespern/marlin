//! Stand-in for Ghostty's src/font/main.zig: only the parts of the font
//! package that the sprite font refers to.
pub const Metrics = @import("Metrics.zig");
pub const sprite = @import("sprite.zig");
pub const Sprite = sprite.Sprite;
