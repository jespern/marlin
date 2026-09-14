//! ask_user: present a multiple-choice question in the user's client and
//! park the turn until they answer. Execution lives in loop.zig (it needs
//! the session's question gate); this module owns only the spec, like task.

pub const spec_name = "ask_user";
pub const spec_description =
    "Ask the user a multiple-choice question, rendered as an interactive picker in their terminal. " ++
    "Use this whenever you would otherwise list options in prose and ask them to reply — do not do that. " ++
    "The turn pauses until they answer. The result is the chosen option's exact text, or the user's own " ++
    "typed words when they answer freely instead.";
pub const spec_schema =
    \\{"type":"object","properties":{"question":{"type":"string","description":"The complete question, ending in a question mark"},"options":{"type":"array","items":{"type":"string"},"minItems":2,"maxItems":9,"description":"Distinct, mutually exclusive choices. No 'Other' option — the user can always type their own answer instead."}},"required":["question","options"]}
;
