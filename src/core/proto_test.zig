//! Unit tests for proto.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in proto.zig.

const std = @import("std");
const block = @import("block.zig");
const guest = @import("guest.zig");
const ReasoningEffort = @import("effort.zig").Effort;
const GuestBackend = guest.Backend;

const proto = @import("proto.zig");
const ApprovalAnswer = proto.ApprovalAnswer;
const ClientMsg = proto.ClientMsg;
const DaemonMsg = proto.DaemonMsg;
const SessionKind = proto.SessionKind;
const SessionState = proto.SessionState;
const TurnPhase = proto.TurnPhase;
const decode = proto.decode;
const encode = proto.encode;
const ensureLineLength = proto.ensureLineLength;
const guestBackend = proto.guestBackend;
const guestModelName = proto.guestModelName;
const isGuestModel = proto.isGuestModel;
const proto_version = proto.proto_version;
const readLineAllocLimit = proto.readLineAllocLimit;

test {
    std.testing.refAllDecls(proto);
}

test "round trip: client messages" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original: ClientMsg = .{ .input = .{
        .sid = 0xDEAD_BEEF_0000_1111,
        .text = "hi \"there\"\nline2",
        .request_id = 42,
    } };
    const line = try encode(gpa, original);
    defer gpa.free(line);
    try std.testing.expect(line[line.len - 1] == '\n');

    const back = try decode(ClientMsg, arena, line);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF_0000_1111), back.input.sid);
    try std.testing.expectEqualStrings("hi \"there\"\nline2", back.input.text);
    try std.testing.expectEqual(@as(u64, 42), back.input.request_id);

    const effort_msg: ClientMsg = .{ .session_set_effort = .{ .sid = 9, .effort = .xhigh } };
    const effort_line = try encode(gpa, effort_msg);
    defer gpa.free(effort_line);
    const effort_back = try decode(ClientMsg, arena, effort_line);
    try std.testing.expectEqual(ReasoningEffort.xhigh, effort_back.session_set_effort.effort);

    const plan_mode_msg: ClientMsg = .{ .session_set_plan_mode = .{ .sid = 9, .enabled = true } };
    const plan_mode_line = try encode(gpa, plan_mode_msg);
    defer gpa.free(plan_mode_line);
    const plan_mode_back = try decode(ClientMsg, arena, plan_mode_line);
    try std.testing.expect(plan_mode_back.session_set_plan_mode.enabled);

    const plan_clear_line = try encode(gpa, ClientMsg{ .plan_clear = .{ .sid = 9, .request_id = 17 } });
    defer gpa.free(plan_clear_line);
    const plan_clear_back = try decode(ClientMsg, arena, plan_clear_line);
    try std.testing.expectEqual(@as(u64, 17), plan_clear_back.plan_clear.request_id);

    const plan_accept_line = try encode(gpa, ClientMsg{ .plan_accept = .{ .sid = 9, .request_id = 18 } });
    defer gpa.free(plan_accept_line);
    const plan_accept_back = try decode(ClientMsg, arena, plan_accept_line);
    try std.testing.expectEqual(@as(u64, 18), plan_accept_back.plan_accept.request_id);

    const sandbox_msg: ClientMsg = .{ .session_set_sandbox = .{ .sid = 9, .enabled = false } };
    const sandbox_line = try encode(gpa, sandbox_msg);
    defer gpa.free(sandbox_line);
    const sandbox_back = try decode(ClientMsg, arena, sandbox_line);
    try std.testing.expect(!sandbox_back.session_set_sandbox.enabled);

    const network_msg: ClientMsg = .{ .session_set_network_filtering = .{ .sid = 9, .enabled = true } };
    const network_line = try encode(gpa, network_msg);
    defer gpa.free(network_line);
    const network_back = try decode(ClientMsg, arena, network_line);
    try std.testing.expect(network_back.session_set_network_filtering.enabled);

    const otel_line = try encode(gpa, ClientMsg{ .otel_configure = .{
        .endpoint = "https://otel.example",
        .headers = "Authorization=Bearer%20secret",
    } });
    defer gpa.free(otel_line);
    const otel_back = try decode(ClientMsg, arena, otel_line);
    try std.testing.expectEqualStrings("https://otel.example", otel_back.otel_configure.endpoint);
    try std.testing.expectEqualStrings("Authorization=Bearer%20secret", otel_back.otel_configure.headers);

    const watch_line = try encode(gpa, ClientMsg{ .session_watch = .{ .incremental = true } });
    defer gpa.free(watch_line);
    const watch_back = try decode(ClientMsg, arena, watch_line);
    try std.testing.expectEqual(
        std.meta.activeTag(ClientMsg{ .session_watch = .{} }),
        std.meta.activeTag(watch_back),
    );
    try std.testing.expect(watch_back.session_watch.incremental);

    const ui_line = try encode(gpa, ClientMsg{ .ui_set_tab_bar = .{ .enabled = false } });
    defer gpa.free(ui_line);
    const ui_back = try decode(ClientMsg, arena, ui_line);
    try std.testing.expect(!ui_back.ui_set_tab_bar.enabled);

    const screensaver_line = try encode(gpa, ClientMsg{ .ui_set_screensaver = .{
        .after_ms = 600_000,
        .effect = "strings",
    } });
    defer gpa.free(screensaver_line);
    const screensaver_back = try decode(ClientMsg, arena, screensaver_line);
    try std.testing.expectEqual(@as(u64, 600_000), screensaver_back.ui_set_screensaver.after_ms);
    try std.testing.expectEqualStrings("strings", screensaver_back.ui_set_screensaver.effect);
    const screensaver_off_line = try encode(gpa, ClientMsg{ .ui_set_screensaver = .{ .after_ms = 0 } });
    defer gpa.free(screensaver_off_line);
    const screensaver_off_back = try decode(ClientMsg, arena, screensaver_off_line);
    try std.testing.expectEqual(@as(u64, 0), screensaver_off_back.ui_set_screensaver.after_ms);
    try std.testing.expectEqualStrings("matrix", screensaver_off_back.ui_set_screensaver.effect);

    const blob_line = try encode(gpa, ClientMsg{ .blob_get = .{ .hash = "abc123" } });
    defer gpa.free(blob_line);
    const blob_back = try decode(ClientMsg, arena, blob_line);
    try std.testing.expectEqualStrings("abc123", blob_back.blob_get.hash);

    const tail_line = try encode(gpa, ClientMsg{ .sub = .{
        .sid = 7,
        .from_seq = 1,
        .tail_limit = 256,
        .before_seq = 1024,
        .replay_limit = 128,
        .replay_done = true,
    } });
    defer gpa.free(tail_line);
    const tail_back = try decode(ClientMsg, arena, tail_line);
    try std.testing.expectEqual(@as(u32, 256), tail_back.sub.tail_limit);
    try std.testing.expectEqual(@as(u64, 1024), tail_back.sub.before_seq);
    try std.testing.expectEqual(@as(u32, 128), tail_back.sub.replay_limit);
    try std.testing.expect(tail_back.sub.replay_done);

    const centered_line = try encode(gpa, ClientMsg{ .sub = .{
        .sid = 7,
        .tail_limit = 256,
        .around_seq = 42,
    } });
    defer gpa.free(centered_line);
    const centered_back = try decode(ClientMsg, arena, centered_line);
    try std.testing.expectEqual(@as(u64, 42), centered_back.sub.around_seq);

    const search_line = try encode(gpa, ClientMsg{ .search = .{
        .query = "banana launcher",
        .sid = 7,
        .limit = 20,
    } });
    defer gpa.free(search_line);
    const search_back = try decode(ClientMsg, arena, search_line);
    try std.testing.expectEqualStrings("banana launcher", search_back.search.query);
    try std.testing.expectEqual(@as(u64, 7), search_back.search.sid);

    const history_line = try encode(gpa, ClientMsg{ .input_history = .{ .sid = 7, .limit = 99 } });
    defer gpa.free(history_line);
    const history_back = try decode(ClientMsg, arena, history_line);
    try std.testing.expectEqual(@as(u64, 7), history_back.input_history.sid);
    try std.testing.expectEqual(@as(u32, 99), history_back.input_history.limit);

    const interrupt_line = try encode(gpa, ClientMsg{ .interrupt = .{ .sid = 9, .report = true } });
    defer gpa.free(interrupt_line);
    const interrupt_back = try decode(ClientMsg, arena, interrupt_line);
    try std.testing.expect(interrupt_back.interrupt.report);

    const rename_line = try encode(gpa, ClientMsg{ .session_rename = .{ .sid = 9, .title = "review web ui" } });
    defer gpa.free(rename_line);
    const rename_back = try decode(ClientMsg, arena, rename_line);
    try std.testing.expectEqual(@as(u64, 9), rename_back.session_rename.sid);
    try std.testing.expectEqualStrings("review web ui", rename_back.session_rename.title);

    const cc_line = try encode(gpa, ClientMsg{ .cc_approval = .{
        .sid = 4,
        .tool = "Bash",
        .args_json = "{\"command\":\"zig build test\"}",
    } });
    defer gpa.free(cc_line);
    const cc_back = try decode(ClientMsg, arena, cc_line);
    try std.testing.expectEqual(@as(u64, 4), cc_back.cc_approval.sid);
    try std.testing.expectEqualStrings("Bash", cc_back.cc_approval.tool);

    const cc_reply = try encode(gpa, DaemonMsg{ .cc_approval_result = .{ .sid = 4, .decision = .granted } });
    defer gpa.free(cc_reply);
    const cc_reply_back = try decode(DaemonMsg, arena, cc_reply);
    try std.testing.expectEqual(ApprovalAnswer.granted, cc_reply_back.cc_approval_result.decision);

    const gc_line = try encode(gpa, ClientMsg{ .gc = .{ .expire_before_ms = 123 } });
    defer gpa.free(gc_line);
    const gc_back = try decode(ClientMsg, arena, gc_line);
    try std.testing.expectEqual(@as(i64, 123), gc_back.gc.expire_before_ms);

    const gc_reply = try encode(gpa, DaemonMsg{ .gc_result = .{ .bytes_reclaimed = 9, .orphan_blobs = 1, .expired_blobs = 0 } });
    defer gpa.free(gc_reply);
    const gc_reply_back = try decode(DaemonMsg, arena, gc_reply);
    try std.testing.expectEqual(@as(u64, 9), gc_reply_back.gc_result.bytes_reclaimed);

    const council_line = try encode(gpa, ClientMsg{ .council_set = .{
        .name = "core",
        .models = &.{ "openrouter/x-ai/grok-4.6", "openrouter/z-ai/glm-5.3" },
    } });
    defer gpa.free(council_line);
    const council_back = try decode(ClientMsg, arena, council_line);
    try std.testing.expectEqualStrings("core", council_back.council_set.name);
    try std.testing.expectEqual(@as(usize, 2), council_back.council_set.models.len);

    const council_reply = try encode(gpa, DaemonMsg{ .council_list_result = .{
        .councils = &.{.{ .name = "core", .models = &.{"openrouter/x-ai/grok-4.6"} }},
    } });
    defer gpa.free(council_reply);
    const council_reply_back = try decode(DaemonMsg, arena, council_reply);
    try std.testing.expectEqualStrings("core", council_reply_back.council_list_result.councils[0].name);

    const plan_clear_reply = try encode(gpa, DaemonMsg{ .plan_clear_result = .{
        .sid = 9,
        .cleared = true,
        .request_id = 17,
    } });
    defer gpa.free(plan_clear_reply);
    const plan_clear_reply_back = try decode(DaemonMsg, arena, plan_clear_reply);
    try std.testing.expect(plan_clear_reply_back.plan_clear_result.cleared);
    try std.testing.expectEqual(@as(u64, 17), plan_clear_reply_back.plan_clear_result.request_id);
}

test "latest plan survives the replay marker wire" {
    const gpa = std.testing.allocator;
    const line = try encode(gpa, DaemonMsg{ .replay_done = .{
        .sid = 7,
        .plan_pinned = false,
        .plan_items = &.{
            .{ .step = "Inspect", .status = .completed, .duration_ms = 18_400 },
            .{ .step = "Implement", .status = .in_progress, .started_at_ms = 20_000 },
        },
    } });
    defer gpa.free(line);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const decoded = try decode(DaemonMsg, arena_state.allocator(), line);
    try std.testing.expectEqual(@as(u64, 7), decoded.replay_done.sid);
    try std.testing.expectEqual(@as(usize, 2), decoded.replay_done.plan_items.len);
    try std.testing.expectEqual(@as(u64, 18_400), decoded.replay_done.plan_items[0].duration_ms);
    try std.testing.expectEqual(block.PlanStatus.in_progress, decoded.replay_done.plan_items[1].status);
    try std.testing.expectEqual(@as(i64, 20_000), decoded.replay_done.plan_items[1].started_at_ms);
    try std.testing.expect(!decoded.replay_done.plan_pinned);
}

test "input attachments survive the remote-client wire" {
    const gpa = std.testing.allocator;
    const line = try encode(gpa, ClientMsg{ .input = .{
        .sid = 7,
        .text = "look",
        .request_id = 9,
        .attachments = &.{.{
            .name = "shot.png",
            .mime = "image/png",
            .data_base64 = "iVBORw0KGgo=",
        }},
    } });
    defer gpa.free(line);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const decoded = try decode(ClientMsg, arena_state.allocator(), line);
    try std.testing.expectEqual(@as(usize, 1), decoded.input.attachments.len);
    try std.testing.expectEqualStrings("shot.png", decoded.input.attachments[0].name);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", decoded.input.attachments[0].data_base64);
}

test "round trip: daemon block message with tool_result body" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msg: DaemonMsg = .{ .blk = .{ .sid = 7, .b = .{
        .id = 1,
        .session_id = 7,
        .turn_id = 2,
        .seq = 3,
        .ts = 1700000000000,
        .body = .{ .tool_result = .{ .call_id = "c1", .status = .ok, .inline_body = "out", .full_body_ref = null } },
    } } };
    const line = try encode(gpa, msg);
    defer gpa.free(line);

    const back = try decode(DaemonMsg, arena, line);
    try std.testing.expectEqual(@as(u64, 3), back.blk.b.seq);
    try std.testing.expectEqualStrings("out", back.blk.b.body.tool_result.inline_body);
}

test "round trip: interrupt diagnostics" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const line = try encode(gpa, DaemonMsg{ .interrupt_result = .{
        .sid = 7,
        .active = true,
        .already_requested = true,
        .request_count = 2,
        .pending_ms = 1500,
        .phase_ms = 4200,
        .phase = .provider,
    } });
    defer gpa.free(line);
    const back = try decode(DaemonMsg, arena_state.allocator(), line);
    try std.testing.expect(back.interrupt_result.already_requested);
    try std.testing.expectEqual(TurnPhase.provider, back.interrupt_result.phase);
    try std.testing.expectEqual(@as(u64, 4200), back.interrupt_result.phase_ms);
}

test "decode ignores unknown fields; defaults apply" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(ClientMsg, arena_state.allocator(),
        \\{"sub":{"sid":5,"future_field":true}}
    );
    try std.testing.expectEqual(@as(u64, 0), m.sub.from_seq);
    try std.testing.expectEqual(@as(u32, 0), m.sub.tail_limit);
    try std.testing.expectEqual(@as(u64, 0), m.sub.before_seq);
    try std.testing.expectEqual(@as(u32, 0), m.sub.replay_limit);
    try std.testing.expect(!m.sub.replay_done);
    try std.testing.expectEqual(@as(u64, 5), m.sub.sid);
}

test "correlation ids are additive and legacy messages default to zero" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const legacy_input = try decode(ClientMsg, arena,
        \\{"input":{"sid":5,"text":"hello"}}
    );
    try std.testing.expectEqual(@as(u64, 0), legacy_input.input.request_id);

    const legacy_create = try decode(ClientMsg, arena,
        \\{"session_create":{"cwd":"/tmp","model":"test/model"}}
    );
    try std.testing.expectEqual(@as(u64, 0), legacy_create.session_create.request_id);

    const legacy_created = try decode(DaemonMsg, arena,
        \\{"session_created":{"sid":7}}
    );
    try std.testing.expectEqual(@as(u64, 0), legacy_created.session_created.request_id);

    const legacy_err = try decode(DaemonMsg, arena,
        \\{"err":{"code":"busy","msg":"no"}}
    );
    try std.testing.expectEqual(@as(u64, 0), legacy_err.err.request_id);

    const correlated_ok = try decode(DaemonMsg, arena,
        \\{"ok":{"request_id":91}}
    );
    try std.testing.expectEqual(@as(u64, 91), correlated_ok.ok.request_id);
}

test "bounded line reader supports records larger than legacy buffers" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 300 * 1024 + 1);
    defer gpa.free(input);
    @memset(input[0 .. input.len - 1], 'x');
    input[input.len - 1] = '\n';
    var reader = std.Io.Reader.fixed(input);
    const line = try readLineAllocLimit(gpa, &reader, 512 * 1024);
    defer gpa.free(line);
    try std.testing.expectEqual(@as(usize, 300 * 1024), line.len);
    try std.testing.expect(line[0] == 'x' and line[line.len - 1] == 'x');
}

test "oversized line is rejected, drained, and followed by a valid record" {
    const gpa = std.testing.allocator;
    var reader = std.Io.Reader.fixed("123456789\n{}\n");
    try std.testing.expectError(
        error.ProtocolLineTooLong,
        readLineAllocLimit(gpa, &reader, 8),
    );
    const next = try readLineAllocLimit(gpa, &reader, 8);
    defer gpa.free(next);
    try std.testing.expectEqualStrings("{}", next);
}

test "encoded line length includes its newline" {
    try ensureLineLength(16, 16);
    try std.testing.expectError(error.ProtocolLineTooLong, ensureLineLength(17, 16));
}

test "older hello defaults network configuration state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(DaemonMsg, arena_state.allocator(),
        \\{"hello_ok":{"proto_version":1,"daemon_version":"old"}}
    );
    try std.testing.expect(!m.hello_ok.network_configured);
    try std.testing.expect(!m.hello_ok.network_filtering);
    try std.testing.expectEqual(@as(i64, 0), m.hello_ok.daemon_exe_mtime_ms);
}

test "older ui config replies default the screensaver off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const msg = try decode(DaemonMsg, arena_state.allocator(),
        \\{"ui_config_result":{"tab_bar":true,"bell":false}}
    );
    try std.testing.expectEqual(@as(u64, 0), msg.ui_config_result.screensaver_after_ms);
    try std.testing.expectEqualStrings("matrix", msg.ui_config_result.screensaver_effect);
}

test "status phase is additive and decode-compatible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const old = try decode(DaemonMsg, arena,
        \\{"status":{"sid":7,"state":"running"}}
    );
    try std.testing.expect(old.status.phase == null);

    const line = try encode(std.testing.allocator, DaemonMsg{ .status = .{
        .sid = 7,
        .state = .running,
        .phase = .provider,
    } });
    defer std.testing.allocator.free(line);
    const carried = try decode(DaemonMsg, arena, line);
    try std.testing.expectEqual(TurnPhase.provider, carried.status.phase.?);
}

test "status err_text is additive: absent from old daemons, carried when set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const old = try decode(DaemonMsg, arena,
        \\{"status":{"sid":7,"state":"err"}}
    );
    try std.testing.expect(old.status.err_text == null);

    const line = try encode(std.testing.allocator, DaemonMsg{ .status = .{
        .sid = 7,
        .state = .err,
        .err_text = "claude code error: Not logged in",
    } });
    defer std.testing.allocator.free(line);
    const carried = try decode(DaemonMsg, arena, line);
    try std.testing.expectEqualStrings("claude code error: Not logged in", carried.status.err_text.?);
}

test "model catalog pricing round trips and remains optional" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const original: DaemonMsg = .{ .model_list_result = .{
        .models = &.{"openrouter/example/model"},
        .pricing = &.{.{
            .model = "openrouter/example/model",
            .input_per_million = 3,
            .output_per_million = 15,
            .tiered = true,
        }},
    } };
    const line = try encode(gpa, original);
    defer gpa.free(line);
    const back = try decode(DaemonMsg, arena_state.allocator(), line);
    try std.testing.expectEqualStrings("openrouter/example/model", back.model_list_result.models[0]);
    try std.testing.expectEqual(@as(?f64, 3), back.model_list_result.pricing[0].input_per_million);
    try std.testing.expectEqual(@as(?f64, 15), back.model_list_result.pricing[0].output_per_million);
    try std.testing.expect(back.model_list_result.pricing[0].tiered);

    const legacy = try decode(DaemonMsg, arena_state.allocator(),
        \\{"model_list_result":{"models":["openrouter/legacy/model"]}}
    );
    try std.testing.expectEqual(@as(usize, 0), legacy.model_list_result.pricing.len);
}

test "provider setup keeps credentials client to daemon and never echoes them" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const line = try encode(gpa, ClientMsg{ .setup_apply = .{
        .sid = 7,
        .model = "acme/code-model",
        .provider_name = "acme",
        .base_url = "https://gateway.acme.test/v1",
        .api_key_env = "ACME_API_KEY",
        .credential = "secret-value",
        .replace_empty_session = true,
    } });
    defer gpa.free(line);
    const request = try decode(ClientMsg, arena_state.allocator(), line);
    try std.testing.expectEqualStrings("secret-value", request.setup_apply.credential);
    try std.testing.expect(request.setup_apply.replace_empty_session);

    const quick_status_line = try encode(gpa, ClientMsg{ .setup_status = .{ .probe_guests = false } });
    defer gpa.free(quick_status_line);
    const quick_status = try decode(ClientMsg, arena_state.allocator(), quick_status_line);
    try std.testing.expect(!quick_status.setup_status.probe_guests);

    const status_line = try encode(gpa, DaemonMsg{ .setup_status_result = .{
        .completed = false,
        .default_model = "openrouter/example/model",
        .codex_available = true,
        .codex_authenticated = false,
    } });
    defer gpa.free(status_line);
    const status = try decode(DaemonMsg, arena_state.allocator(), status_line);
    try std.testing.expect(status.setup_status_result.codex_available);
    try std.testing.expect(!status.setup_status_result.codex_authenticated);
    try std.testing.expectEqualStrings("openrouter/example/model", status.setup_status_result.default_model);

    const result_line = try encode(gpa, DaemonMsg{ .setup_result = .{
        .model = "acme/code-model",
        .session_updated = true,
    } });
    defer gpa.free(result_line);
    try std.testing.expect(std.mem.indexOf(u8, result_line, "secret-value") == null);
}

test "round trip: blob result preserves arbitrary bytes" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const original = DaemonMsg{ .blob_result = .{
        .hash = "abc123",
        .bytes = "line one\nline two\x00tail",
    } };
    const line = try encode(gpa, original);
    defer gpa.free(line);
    const back = try decode(DaemonMsg, arena_state.allocator(), line);
    try std.testing.expectEqualStrings("abc123", back.blob_result.hash);
    try std.testing.expectEqualStrings("line one\nline two\x00tail", back.blob_result.bytes);
}

test "older session-list entries default cwd" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(DaemonMsg, arena_state.allocator(),
        \\{"session_list_result":{"sessions":[{"sid":5,"title":"old","model":"m","status":"idle","created_at":1,"running":false}]}}
    );
    try std.testing.expectEqualStrings("", m.session_list_result.sessions[0].cwd);
    try std.testing.expectEqual(SessionState.idle, m.session_list_result.sessions[0].state);
    try std.testing.expectEqual(SessionKind.root, m.session_list_result.sessions[0].kind);
    try std.testing.expectEqual(@as(?u64, null), m.session_list_result.sessions[0].parent_sid);
    try std.testing.expect(!m.session_list_result.sessions[0].archived);
}

test "older session-list requests exclude archived sessions by default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(ClientMsg, arena_state.allocator(),
        \\{"session_list":{}}
    );
    try std.testing.expect(!m.session_list.include_archived);
}

test "guest model prefixes identify their delegated backend" {
    try std.testing.expect(isGuestModel("claudecode/fable"));
    try std.testing.expect(isGuestModel("claudecode/default"));
    try std.testing.expect(isGuestModel("codex/default"));
    try std.testing.expectEqual(GuestBackend.codex, guestBackend("codex/default").?);
    try std.testing.expectEqualStrings("default", guestModelName("codex/default").?);
    try std.testing.expect(!isGuestModel("openrouter/anthropic/claude-sonnet-4.5"));
    try std.testing.expect(!isGuestModel("anthropic/claude-sonnet-4-5"));
    try std.testing.expect(!isGuestModel("claudecode"));
}

test "garbage line is an error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.UnknownField,
        decode(ClientMsg, arena_state.allocator(), "{\"nope\":{}}"),
    );
}
