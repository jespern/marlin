//! Durable child-session tool contract.
//!
//! Execution is daemon-owned (daemon.zig): the turn loop only advertises the
//! schema and hands the raw arguments across a typed callback. This keeps
//! session/store ownership out of the generic tool registry.

const std = @import("std");
const Effort = @import("../../core/effort.zig").Effort;

pub const spec_name = "task";
pub const spec_description =
    "Run a focused prompt in a durable read-only child session and wait for its final answer. " ++
    "The child is inspectable in the session picker and cannot create further children.";
pub const spec_schema =
    \\{"type":"object","properties":{"prompt":{"type":"string","minLength":1},"model":{"type":"string","minLength":1,"description":"Model id. Prefer a full registry id (e.g. 'litellm/fast-code' or 'openrouter/anthropic/claude-sonnet-4.5'); provider-native ids such as 'openai/gpt-5.2' inherit the parent's gateway. Omit to inherit the parent model."},"effort":{"type":"string","enum":["auto","none","minimal","low","medium","high","xhigh","max"]},"max_rounds":{"type":"integer","minimum":1,"maximum":32}},"required":["prompt"],"additionalProperties":false}
;

pub const Args = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    effort: ?Effort = null,
    max_rounds: u32 = 16,
};

pub const batch_spec_name = "task_batch";
pub const batch_spec_description =
    "Run two to eight focused prompts concurrently in durable read-only child sessions. " ++
    "Results return in input order; each child remains inspectable in the session picker.";
pub const batch_spec_schema =
    \\{"type":"object","properties":{"tasks":{"type":"array","minItems":2,"maxItems":8,"items":{"type":"object","properties":{"prompt":{"type":"string","minLength":1},"model":{"type":"string","minLength":1,"description":"Full registry id or a provider-native id that inherits the parent's gateway; omit to inherit the parent model."},"effort":{"type":"string","enum":["auto","none","minimal","low","medium","high","xhigh","max"]},"max_rounds":{"type":"integer","minimum":1,"maximum":32}},"required":["prompt"],"additionalProperties":false}}},"required":["tasks"],"additionalProperties":false}
;

pub const BatchArgs = struct {
    tasks: []const Args,
};

pub const max_batch_tasks: usize = 8;

pub const QualifyError = error{ InvalidModel, NoParentGateway, OutOfMemory };

/// Models emitted by provider APIs often omit Marlin's outer registry
/// provider. Preserve the parent's gateway while replacing its native model.
pub fn qualifyModel(gpa: std.mem.Allocator, parent_model: []const u8, requested: []const u8) QualifyError![]u8 {
    const requested_slash = std.mem.indexOfScalar(u8, requested, '/') orelse return error.InvalidModel;
    if (requested_slash == 0 or requested_slash + 1 == requested.len) return error.InvalidModel;

    const parent_slash = std.mem.indexOfScalar(u8, parent_model, '/') orelse return error.NoParentGateway;
    if (parent_slash == 0 or std.mem.indexOfScalar(u8, parent_model[parent_slash + 1 ..], '/') == null)
        return error.NoParentGateway;
    const outer = parent_model[0..parent_slash];
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ outer, requested }) catch error.OutOfMemory;
}
