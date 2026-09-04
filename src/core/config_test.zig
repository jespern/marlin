//! Unit tests for config.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in config.zig.

const std = @import("std");
const Io = std.Io;
const Effort = @import("effort.zig").Effort;
const credentials = @import("credentials.zig");
const toml = @import("config_toml.zig");
const visual_effect = @import("visual_effect.zig");
const ExecTool = toml.ExecTool;
const McpServer = toml.McpServer;
const Council = toml.Council;
const Provider = toml.Provider;
const Hooks = toml.Hooks;
const Policy = toml.Policy;

const config = @import("config.zig");
const addMcpServerText = config.addMcpServerText;
const applyDocument = config.applyDocument;
const defaults = config.defaults;
const formatDuration = config.formatDuration;
const fromEnviron = config.fromEnviron;
const load = config.load;
const networkPolicyConfigured = config.networkPolicyConfigured;
const parseDurationMs = config.parseDurationMs;
const removeCouncilText = config.removeCouncilText;
const removeMcpServerText = config.removeMcpServerText;
const removeSectionText = config.removeSectionText;
const setCouncilText = config.setCouncilText;
const setProviderSetup = config.setProviderSetup;
const setScalarText = config.setScalarText;
const setUiScreensaver = config.setUiScreensaver;
const starter_config = config.starter_config;
const validate = config.validate;
const validateScreensaverEffect = config.validateScreensaverEffect;

test {
    std.testing.refAllDecls(config);
}

test "screensaver durations are strict and canonical" {
    try std.testing.expectEqual(@as(u64, 0), try parseDurationMs("off"));
    try std.testing.expectEqual(@as(u64, 30_000), try parseDurationMs("30s"));
    try std.testing.expectEqual(@as(u64, 600_000), try parseDurationMs("10m"));
    try std.testing.expectEqual(@as(u64, 3_600_000), try parseDurationMs("1h"));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs("10"));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs("0m"));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs("999999999999999999h"));

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("off", try formatDuration(&buf, 0));
    try std.testing.expectEqualStrings("10m", try formatDuration(&buf, 600_000));
    try std.testing.expectError(error.InvalidDuration, formatDuration(&buf, 1));
    try validateScreensaverEffect("matrix");
    try validateScreensaverEffect("strings");
    try validateScreensaverEffect("stars");
    try validateScreensaverEffect("plasma");
    try validateScreensaverEffect("pacman");
    try validateScreensaverEffect("tunnel");
    try std.testing.expectError(error.InvalidScreensaverEffect, validateScreensaverEffect("disco"));
}

test "web ui stays off unless deliberately enabled" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();

    try std.testing.expect(!defaults().web_enabled);
    try std.testing.expect(!fromEnviron(&environ).web_enabled);
    try environ.put("MARLIN_WEB", "1");
    try std.testing.expect(fromEnviron(&environ).web_enabled);
    try environ.put("MARLIN_WEB", "0");
    try std.testing.expect(!fromEnviron(&environ).web_enabled);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try toml.parse(arena_state.allocator(), "[web]\nenabled = true\n");
    var cfg = defaults();
    applyDocument(&cfg, doc);
    try std.testing.expect(cfg.web_enabled);
}

test "defaults are sane" {
    const c = defaults();
    try std.testing.expectEqual(Effort.auto, c.effort_default);
    try std.testing.expectEqualStrings("throughput", c.openrouter_sort.?);
    try std.testing.expect(c.output_headroom_tokens > 0);
    try std.testing.expect(c.prune_protect_tokens > c.prune_min_reclaim_tokens);
    try std.testing.expect(c.permissions_enabled);
    try std.testing.expect(!c.workspace_enabled);
    try std.testing.expectEqual(@as(u64, 0), c.ui_screensaver_after_ms);
    try std.testing.expectEqualStrings("matrix", c.ui_screensaver_effect);
}

test "configured providers validate without storing secret material" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = try toml.parse(arena,
        \\[providers.acme]
        \\base_url = "https://gateway.acme.test/v1"
        \\api_key_env = "ACME_API_KEY"
        \\[providers.litellm]
        \\api_key_env = "NONE"
    );
    var cfg = defaults();
    applyDocument(&cfg, doc);
    try validate(std.testing.allocator, cfg);
    try std.testing.expectEqual(@as(usize, 2), cfg.providers.len);
    try std.testing.expectEqualStrings("ACME_API_KEY", cfg.providers[0].api_key_env.?);

    const missing = try toml.parse(arena, "[providers.acme]\napi_key_env = \"ACME_API_KEY\"\n");
    var missing_cfg = defaults();
    applyDocument(&missing_cfg, missing);
    try std.testing.expectError(error.ProviderMissingBaseUrl, validate(std.testing.allocator, missing_cfg));

    const ambiguous_key = try toml.parse(arena, "[providers.acme]\nbase_url = \"https://gateway.acme.test/v1\"\n");
    var ambiguous_key_cfg = defaults();
    applyDocument(&ambiguous_key_cfg, ambiguous_key);
    try std.testing.expectError(error.ProviderMissingApiKeyEnv, validate(std.testing.allocator, ambiguous_key_cfg));

    const unprotected_name = try toml.parse(
        arena,
        "[providers.acme]\nbase_url = \"https://gateway.acme.test/v1\"\napi_key_env = \"ACME_CREDENTIAL\"\n",
    );
    var unprotected_cfg = defaults();
    applyDocument(&unprotected_cfg, unprotected_name);
    try std.testing.expectError(error.InvalidProviderApiKeyEnv, validate(std.testing.allocator, unprotected_cfg));
}

test "MARLIN_PERMISSIONS opts out of capability permissions" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();

    try std.testing.expect(fromEnviron(&environ).permissions_enabled);
    try environ.put("MARLIN_PERMISSIONS", "0");
    try std.testing.expect(!fromEnviron(&environ).permissions_enabled);
    try environ.put("MARLIN_PERMISSIONS", "1");
    try std.testing.expect(fromEnviron(&environ).permissions_enabled);
    try environ.put("MARLIN_PERMISSIONS", "true");
    try std.testing.expect(fromEnviron(&environ).permissions_enabled);
}

test "network policy environment bridge is opt-in" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();

    try std.testing.expect(fromEnviron(&environ).network_blocklists == null);
    try environ.put("MARLIN_NETWORK_BLOCKLISTS", "hagezi-tif-mini");
    try environ.put("MARLIN_NETWORK_ALLOW", "safe.example");
    try environ.put("MARLIN_NETWORK_DENY", "blocked.example");
    const cfg = fromEnviron(&environ);
    try std.testing.expectEqualStrings("hagezi-tif-mini", cfg.network_blocklists.?);
    try std.testing.expectEqualStrings("safe.example", cfg.network_allow.?);
    try std.testing.expectEqualStrings("blocked.example", cfg.network_deny.?);
}

test "missing config creates sparse network starter without replacing existing files" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-config-starter");
    defer temp.deinit();
    const root = temp.path;

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", root);

    var loaded = try load(gpa, io, &environ);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("hagezi-tif-mini", loaded.value.network_blocklists.?);
    try std.testing.expect(networkPolicyConfigured(loaded.value));

    const path = try std.fs.path.join(gpa, &.{ root, "marlin", "config.toml" });
    defer gpa.free(path);
    const created = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
    defer gpa.free(created);
    try std.testing.expectEqualStrings(starter_config, created);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "[network]\ndeny = \"preserved.example\"\n" });
    var reloaded = try load(gpa, io, &environ);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("preserved.example", reloaded.value.network_deny.?);
    try std.testing.expect(reloaded.value.network_blocklists == null);
}

test "load reads XDG config and environment wins" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-config");
    defer temp.deinit();
    const root = temp.path;
    const dir = try std.fs.path.join(gpa, &.{ root, "marlin" });
    defer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "config.toml" });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\[model]
        \\default = "local/test"
        \\[approval]
        \\default_mutating = "deny"
        \\[permissions]
        \\enabled = true
        \\[network]
        \\blocklists = "hagezi-tif-mini"
        \\allow = "safe.example"
        \\deny = "from-config.example"
        \\[[tools.exec]]
        \\name = "echo_json"
        \\cmd = ["sh", "-c", "cat"]
        \\schema = '{"type":"object"}'
    });

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", root);
    try environ.put("MARLIN_PERMISSIONS", "0");
    var loaded = try load(gpa, io, &environ);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("local/test", loaded.value.model_default);
    try std.testing.expectEqual(Policy.deny, loaded.value.mutating_tools_policy);
    try std.testing.expect(!loaded.value.permissions_enabled);
    try std.testing.expectEqualStrings("hagezi-tif-mini", loaded.value.network_blocklists.?);
    try std.testing.expectEqualStrings("safe.example", loaded.value.network_allow.?);
    try std.testing.expectEqualStrings("from-config.example", loaded.value.network_deny.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.exec_tools.len);
    try std.testing.expectEqualStrings("echo_json", loaded.value.exec_tools[0].name);
}

test "MCP config edits round-trip escaped commands and preserve other tables" {
    const gpa = std.testing.allocator;
    const original =
        \\[model]
        \\default = "local/test"
        \\[[mcp]]
        \\name = "keep"
        \\cmd = ["keep-server"]
        \\[network]
        \\deny = "blocked.example"
    ;
    const added = try addMcpServerText(gpa, original, "new-server", &.{ "server path", "--label=\"quoted\"", "line\nbreak" });
    defer gpa.free(added);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try toml.parse(arena_state.allocator(), added);
    try std.testing.expectEqual(@as(usize, 2), doc.mcp_servers.len);
    try std.testing.expectEqualStrings("server path", doc.mcp_servers[1].cmd[0]);
    try std.testing.expectEqualStrings("--label=\"quoted\"", doc.mcp_servers[1].cmd[1]);
    try std.testing.expectEqualStrings("line\nbreak", doc.mcp_servers[1].cmd[2]);
    try std.testing.expectError(error.DuplicateMcpServer, addMcpServerText(gpa, added, "new-server", &.{"nope"}));

    const removed = try removeMcpServerText(gpa, added, "keep");
    defer gpa.free(removed);
    var removed_arena = std.heap.ArenaAllocator.init(gpa);
    defer removed_arena.deinit();
    const after = try toml.parse(removed_arena.allocator(), removed);
    try std.testing.expectEqual(@as(usize, 1), after.mcp_servers.len);
    try std.testing.expectEqualStrings("new-server", after.mcp_servers[0].name);
    try std.testing.expectEqualStrings("blocked.example", after.network_deny.?);
    try std.testing.expectError(error.UnknownMcpServer, removeMcpServerText(gpa, removed, "missing"));
}

test "council config text edits: set replaces, remove deletes, garbage rejected" {
    const gpa = std.testing.allocator;
    const base = "[model]\ndefault = \"openrouter/x\"\n";

    const one = try setCouncilText(gpa, base, "core", &.{ "openrouter/a/b", "openrouter/c/d" });
    defer gpa.free(one);
    try std.testing.expect(std.mem.indexOf(u8, one, "[[council]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"openrouter/a/b\", \"openrouter/c/d\"") != null);

    // set again = replace, not duplicate
    const two = try setCouncilText(gpa, one, "core", &.{"openrouter/e/f"});
    defer gpa.free(two);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, two, "[[council]]"));
    try std.testing.expect(std.mem.indexOf(u8, two, "openrouter/e/f") != null);
    try std.testing.expect(std.mem.indexOf(u8, two, "openrouter/a/b") == null);

    const removed = try removeCouncilText(gpa, two, "core");
    defer gpa.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "[[council]]") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "default = ") != null);

    try std.testing.expectError(error.UnknownCouncil, removeCouncilText(gpa, base, "nope"));
    try std.testing.expectError(error.CouncilBadModel, setCouncilText(gpa, base, "bad", &.{"notamodel"}));
    try std.testing.expectError(error.CouncilMissingModels, setCouncilText(gpa, base, "bad", &.{}));
}

test "ui scalar edits: replace in place, insert into section, append section" {
    const gpa = std.testing.allocator;

    // No [ui] section: appended, other tables untouched byte-for-byte.
    const base = "[model]\ndefault = \"openrouter/x\"\n";
    const appended = try setScalarText(gpa, base, "ui", "tab_bar", "false");
    defer gpa.free(appended);
    try std.testing.expect(std.mem.startsWith(u8, appended, base));
    try std.testing.expect(std.mem.indexOf(u8, appended, "[ui]\ntab_bar = false\n") != null);

    // Existing key: replaced in place, once.
    const replaced = try setScalarText(gpa, appended, "ui", "tab_bar", "true");
    defer gpa.free(replaced);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replaced, "tab_bar"));
    try std.testing.expect(std.mem.indexOf(u8, replaced, "tab_bar = true") != null);

    // Existing section without the key, followed by another section: the key
    // lands inside [ui], not at the file end.
    const sandwich = "[ui]\n# chrome prefs\n[web]\nenabled = true\n";
    const inserted = try setScalarText(gpa, sandwich, "ui", "tab_bar", "false");
    defer gpa.free(inserted);
    const ui_at = std.mem.indexOf(u8, inserted, "[ui]").?;
    const key_at = std.mem.indexOf(u8, inserted, "tab_bar = false").?;
    const web_at = std.mem.indexOf(u8, inserted, "[web]").?;
    try std.testing.expect(ui_at < key_at and key_at < web_at);
    try std.testing.expect(std.mem.indexOf(u8, inserted, "# chrome prefs") != null);

    const screensaver = try setScalarText(gpa, inserted, "ui", "screensaver_after", "\"10m\"");
    defer gpa.free(screensaver);
    try std.testing.expect(std.mem.indexOf(u8, screensaver, "screensaver_after = \"10m\"") != null);
}

test "invalid screensaver effect rejects the loaded config" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-invalid-saver");
    defer temp.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", temp.path);
    const path = try std.fs.path.join(gpa, &.{ temp.path, "marlin", "config.toml" });
    defer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "[ui]\nscreensaver_effect = \"disco\"\n" });
    try std.testing.expectError(error.InvalidScreensaverEffect, load(gpa, io, &environ));
}

test "screensaver timeout and effect persist and reload atomically" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-screensaver-config");
    defer temp.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", temp.path);

    var initial = try load(gpa, io, &environ);
    try std.testing.expectEqual(@as(u64, 0), initial.value.ui_screensaver_after_ms);
    initial.deinit();

    try setUiScreensaver(gpa, io, &environ, "10m", "strings");
    var enabled = try load(gpa, io, &environ);
    try std.testing.expectEqual(@as(u64, 600_000), enabled.value.ui_screensaver_after_ms);
    try std.testing.expectEqualStrings("strings", enabled.value.ui_screensaver_effect);
    enabled.deinit();

    try setUiScreensaver(gpa, io, &environ, "off", "plasma");
    var disabled = try load(gpa, io, &environ);
    defer disabled.deinit();
    try std.testing.expectEqual(@as(u64, 0), disabled.value.ui_screensaver_after_ms);
    try std.testing.expectEqualStrings("plasma", disabled.value.ui_screensaver_effect);
}

test "provider setup persists completion, default model, and custom endpoint atomically" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-provider-setup");
    defer temp.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", temp.path);

    var initial = try load(gpa, io, &environ);
    try std.testing.expect(!initial.value.setup_completed);
    initial.deinit();

    try setProviderSetup(
        gpa,
        io,
        &environ,
        "acme/code-model",
        "acme",
        "https://gateway.acme.test/v1",
        "ACME_API_KEY",
    );
    var loaded = try load(gpa, io, &environ);
    defer loaded.deinit();
    try std.testing.expect(loaded.value.setup_completed);
    try std.testing.expectEqualStrings("acme/code-model", loaded.value.model_default);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.providers.len);
    try std.testing.expectEqualStrings("https://gateway.acme.test/v1", loaded.value.providers[0].base_url.?);
    try std.testing.expectEqualStrings("ACME_API_KEY", loaded.value.providers[0].api_key_env.?);
}

test "voice section: parse, whole-section replace, removal helper" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try toml.parse(arena_state.allocator(),
        \\[voice]
        \\enabled = true
        \\engine = "whisper-turbo"
        \\mode = "toggle"
        \\model = "/data/ggml-large-v3-turbo.bin"
        \\stt_bin = "/opt/homebrew/bin/whisper-cli"
        \\
        \\[web]
        \\enabled = true
        \\
    );
    try std.testing.expect(doc.voice_enabled.?);
    try std.testing.expectEqualStrings("whisper-turbo", doc.voice_engine.?);
    try std.testing.expectEqualStrings("toggle", doc.voice_mode.?);

    const base = "[voice]\nenabled = false\nengine = \"x\"\n\n[web]\nenabled = true\n";
    const removed = try removeSectionText(gpa, base, "[voice]");
    defer gpa.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "[voice]") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "[web]") != null);

    const untouched = try removeSectionText(gpa, "[web]\nenabled = true\n", "[voice]");
    defer gpa.free(untouched);
    try std.testing.expectEqualStrings("[web]\nenabled = true\n", untouched);
}
