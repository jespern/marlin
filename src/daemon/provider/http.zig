//! HTTP layer: libcurl wrapper. THE ONLY FILE THAT KNOWS CURL.
//!
//! - streaming POST with write callback → sse.zig feed()
//! - cancellation: progress callback polls the turn's atomic cancel flag
//! - retry/backoff: exponential w/ jitter on 429/5xx/connect errors,
//!   honoring Retry-After; max attempts then stream_error{retryable:false}
//! - swap target: std.http.Client behind this same interface, someday.

const std = @import("std");

// TODO(M0): link libcurl in build.zig, easy-handle wrapper, header auth
//           (Bearer from api_key_env), timeouts (connect 10s, idle 120s).

test {
    std.testing.refAllDecls(@This());
}
