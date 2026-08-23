//! SSE (text/event-stream) parser, shared by all dialects.
//!
//! Incremental: feed() bytes as they arrive from curl's write callback,
//! yields complete events (event:/data: pairs, multi-line data, [DONE]).
//! Must tolerate: CRLF and LF, comments (`:`), events split across arbitrary
//! chunk boundaries, and mid-stream disconnects (surface as stream_error).

const std = @import("std");

// TODO(M0). Fixture tests replay recorded streams from src/testing/fixtures/
// including chunk-boundary torture cases (split mid-escape, mid-utf8).

test {
    std.testing.refAllDecls(@This());
}
