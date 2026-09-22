//! Unit tests for codex.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in codex.zig.

const std = @import("std");
const builtin = @import("builtin");

const codex = @import("codex.zig");
const buildArgv = codex.buildArgv;
const decodeLine = codex.decodeLine;
const field = codex.field;
const strField = codex.strField;

test {
    std.testing.refAllDecls(codex);
}

test "otel overrides compose per-signal URLs and gate the content-bearing log exporter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // argv[1..2] is always the workspace-write network grant (loopback test
    // servers are ordinary dev work); overrides follow, app-server closes.
    const plain = try buildArgv(arena, null, null);
    try std.testing.expectEqual(@as(usize, 6), plain.len);
    try std.testing.expectEqualStrings("-c", plain[1]);
    try std.testing.expectEqualStrings("sandbox_workspace_write.network_access=true", plain[2]);
    try std.testing.expectEqualStrings("app-server", plain[3]);

    const structural = try buildArgv(arena, null, .{
        .base_endpoint = "https://otel.example/",
        .headers = "Authorization=Bearer%20secret",
    });
    try std.testing.expectEqual(@as(usize, 8), structural.len);
    try std.testing.expectEqualStrings("-c", structural[3]);
    try std.testing.expectEqualStrings(
        "otel.trace_exporter={ otlp-http = { endpoint = \"https://otel.example/v1/traces\", protocol = \"json\", headers = { \"Authorization\" = \"Bearer secret\" } } }",
        structural[4],
    );
    for (structural) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "log_user_prompt") == null);

    const content = try buildArgv(arena, null, .{
        .base_endpoint = "https://otel.example",
        .capture_content = true,
    });
    try std.testing.expectEqual(@as(usize, 12), content.len);
    try std.testing.expectEqualStrings(
        "otel.exporter={ otlp-http = { endpoint = \"https://otel.example/v1/logs\", protocol = \"json\" } }",
        content[6],
    );
    try std.testing.expectEqualStrings("otel.log_user_prompt=true", content[8]);

    // A traces-only collector cannot compose the logs URL: structural spans
    // still flow, the content-bearing log exporter stays off even when the
    // operator opted into content.
    const traces_only = try buildArgv(arena, null, .{
        .traces_endpoint = "https://otel.example/custom/traces",
        .capture_content = true,
    });
    try std.testing.expectEqual(@as(usize, 8), traces_only.len);
    try std.testing.expect(std.mem.indexOf(u8, traces_only[4], "custom/traces") != null);
}

test "app-server records distinguish responses, requests, and notifications" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const response = try decodeLine(arena,
        \\{"id":3,"result":{"thread":{"id":"thr_1"}}}
    );
    try std.testing.expectEqual(@as(i64, 3), response.response.id);
    try std.testing.expectEqualStrings("thr_1", strField(field(response.response.result.?, "thread").?, "id").?);

    const request = try decodeLine(arena,
        \\{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"itemId":"item-1"}}
    );
    try std.testing.expectEqualStrings("\"approval-1\"", request.request.id_json);
    try std.testing.expectEqualStrings("item-1", strField(request.request.params, "itemId").?);

    const notification = try decodeLine(arena,
        \\{"method":"item/agentMessage/delta","params":{"delta":"hello"}}
    );
    try std.testing.expectEqualStrings("hello", strField(notification.notification.params, "delta").?);
}

test "Codex catalog parses, filters, deduplicates, and sorts model ids" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"data":[
        \\  {"id":"gpt-5.3-codex","model":"gpt-5.3-codex","hidden":false,"isDefault":false},
        \\  {"id":"zeta-model","model":"zeta-model","hidden":false,"isDefault":true},
        \\  {"id":"hidden","model":"hidden","hidden":true,"isDefault":false},
        \\  {"id":"bad","model":"vendor/bad","hidden":false,"isDefault":false},
        \\  {"id":"fallback-only","hidden":false,"isDefault":false},
        \\  {"id":"duplicate","model":"zeta-model","hidden":false,"isDefault":false},
        \\  {"id":"default","model":"default","hidden":false,"isDefault":false}
        \\]}
    , .{});
    const models = try codex.parseModels(gpa, value);
    defer {
        for (models) |model| gpa.free(model.id);
        gpa.free(models);
    }

    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("codex/fallback-only", models[0].id);
    try std.testing.expectEqualStrings("codex/gpt-5.3-codex", models[1].id);
    try std.testing.expectEqualStrings("codex/zeta-model", models[2].id);
}

test "Codex catalog query uses app-server model list" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-codex-catalog");
    defer temp.deinit();
    const script =
        \\#!/bin/sh
        \\case "$*" in "-c sandbox_workspace_write.network_access=true app-server --listen stdio://") ;; *) exit 9 ;; esac
        \\[ -z "$OPENAI_API_KEY" ] || exit 7
        \\initialized=0
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize","id":1'*) echo '{"id":1,"result":{"userAgent":"fake"}}' ;;
        \\    *'"method":"initialized"'*) initialized=1 ;;
        \\    *'"method":"model/list"'*)
        \\      [ "$initialized" = 1 ] || exit 8
        \\      echo '{"id":2,"result":{"data":[{"id":"test-codex-model","model":"test-codex-model","hidden":false,"isDefault":true,"displayName":"Test Codex Model","description":"fast","defaultReasoningEffort":"medium","supportedReasoningEfforts":[]}]}}'
        \\      exit 0 ;;
        \\  esac
        \\done
        \\
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ temp.path, "fake-codex" });
    defer gpa.free(script_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(codex.binary_env, script_path);
    try env.put("PATH", "/usr/bin:/bin");
    const models = try codex.fetchModels(gpa, io, &env, null);
    defer {
        for (models) |model| gpa.free(model.id);
        gpa.free(models);
    }
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("codex/test-codex-model", models[0].id);
}

test "operator-configured Codex collectors are recognized so Marlin defers to them" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-codex-otel-config");
    defer temp.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("CODEX_HOME", temp.path);

    // No config file at all: nothing to defer to.
    try std.testing.expect(!codex.configNamesCollector(gpa, io, &env));

    const config_path = try std.fs.path.join(gpa, &.{ temp.path, "config.toml" });
    defer gpa.free(config_path);
    const Case = struct { name: []const u8, body: []const u8, expected: bool };
    const cases = [_]Case{
        .{ .name = "termalike", .expected = true, .body = "[otel]\ntrace_exporter = { otlp-http = { endpoint = \"https://otel-dev.example/v1/traces\" } }\n" },
        .{ .name = "logs-only", .body = "[otel]\nexporter = { otlp-http = { endpoint = \"https://otel.example/v1/logs\" } }\n", .expected = true },
        .{ .name = "dotted", .body = "otel.trace_exporter = { otlp-http = { endpoint = \"https://otel.example/v1/traces\" } }\n", .expected = true },
        .{ .name = "inline", .body = "otel = { trace_exporter = { otlp-http = { endpoint = \"https://otel.example/v1/traces\" } } }\n", .expected = true },
        .{ .name = "other-sections", .body = "model = \"gpt-5.3-codex\"\n[history]\npersistence = \"none\"\n", .expected = false },
        .{ .name = "commented-out", .body = "# [otel]\n# trace_exporter = {}\n", .expected = false },
        // Only `[otel]`'s own keys count: a same-named key elsewhere is not
        // an exporter, and reading it as one would silently drop Marlin's.
        .{ .name = "decoy-section", .body = "[tui]\nexporter = \"theme\"\n", .expected = false },
    };
    for (cases) |case| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = case.body });
        if (codex.configNamesCollector(gpa, io, &env) != case.expected) {
            std.debug.print("case {s} misread\n", .{case.name});
            return error.CollectorDetectionMismatch;
        }
    }
}
