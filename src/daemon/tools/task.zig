//! Durable child-session tool contract.
//!
//! Execution is daemon-owned (daemon.zig): the turn loop only advertises the
//! schema and hands the raw arguments across a typed callback. This keeps
//! session/store ownership out of the generic tool registry.

const Effort = @import("../../core/effort.zig").Effort;

pub const spec_name = "task";
pub const spec_description =
    "Run a focused prompt in a durable read-only child session and wait for its final answer. " ++
    "The child is inspectable in the session picker and cannot create further children.";
pub const spec_schema =
    \\{"type":"object","properties":{"prompt":{"type":"string","minLength":1},"model":{"type":"string","minLength":1,"description":"Registry-form model id: 'openrouter/<vendor>/<model>' (e.g. 'openrouter/anthropic/claude-sonnet-4.5'). Omit to inherit this session's model — do NOT guess bare model names."},"effort":{"type":"string","enum":["auto","none","minimal","low","medium","high","xhigh","max"]},"max_rounds":{"type":"integer","minimum":1,"maximum":32}},"required":["prompt"],"additionalProperties":false}
;

pub const Args = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    effort: ?Effort = null,
    max_rounds: u32 = 16,
};
