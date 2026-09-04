//! Provider onboarding for the TUI (`/setup`): the provider list, the
//! client-side draft of credential/base URL/model answers, and the App
//! methods that drive the wizard against the daemon's setup_status /
//! setup_apply messages. Split out of tui.zig; everything here operates on
//! a `*tui.App` and the methods are re-exposed there.

const std = @import("std");
const proto = @import("../core/proto.zig");
const tui = @import("tui.zig");
const App = tui.App;
const PickerKind = tui.PickerKind;

pub const SetupProvider = enum { openrouter, codex, claude_code, vercel, anthropic, litellm, local, custom };

pub const SetupPrompt = enum { none, credential, base_url, model, provider_name };

pub const setup_provider_items = [_][]const u8{
    "OpenRouter · native · one key, many models",
    "Codex · guest · ChatGPT login",
    "Claude Code · guest · Claude login",
    "Vercel AI Gateway · native",
    "Anthropic API · native",
    "LiteLLM · local gateway",
    "Local · OpenAI-compatible server",
    "Custom · OpenAI-compatible endpoint",
};

pub const SetupReadiness = struct {
    completed: bool = false,
    codex_available: bool = false,
    codex_authenticated: bool = false,
    claude_code_available: bool = false,
    claude_code_authenticated: bool = false,
    openrouter_ready: bool = false,
    vercel_ready: bool = false,
    anthropic_ready: bool = false,
    litellm_ready: bool = false,
    local_ready: bool = false,

    pub fn fromWire(status: proto.SetupStatus) SetupReadiness {
        return .{
            .completed = status.completed,
            .codex_available = status.codex_available,
            .codex_authenticated = status.codex_authenticated,
            .claude_code_available = status.claude_code_available,
            .claude_code_authenticated = status.claude_code_authenticated,
            .openrouter_ready = status.openrouter_ready,
            .vercel_ready = status.vercel_ready,
            .anthropic_ready = status.anthropic_ready,
            .litellm_ready = status.litellm_ready,
            .local_ready = status.local_ready,
        };
    }
};

pub fn validSetupProviderName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }
    return !std.mem.eql(u8, name, "codex") and !std.mem.eql(u8, name, "claudecode");
}

pub fn clearSetupDraft(self: *App) void {
    if (self.setup.prompt != .none) self.view.editor.clearSensitive();
    self.setup.prompt = .none;
    self.setup.provider = null;
    self.setup.provider_name.clearRetainingCapacity();
    self.setup.base_url.clearRetainingCapacity();
    self.setup.api_key_env.clearRetainingCapacity();
    if (self.setup.credential.items.len > 0) @memset(self.setup.credential.items, 0);
    self.setup.credential.clearRetainingCapacity();
}

pub fn requestSetup(self: *App, required: bool) void {
    if (self.setup.status_pending or self.setup.apply_pending) return;
    self.setup.required = self.setup.required or required;
    if (required) self.setup.replace_empty_session = true;
    self.setup.status_pending = true;
    self.conn.send(.{ .setup_status = .{} }) catch {
        self.setup.status_pending = false;
        self.setNotice("could not query provider setup", .{});
    };
}

pub fn beginSetup(self: *App, required: bool) void {
    self.clearSetupDraft();
    self.setup.required = self.setup.required or required;
    if (required) self.setup.replace_empty_session = true;
    self.openPicker(.setup_provider);
    self.setNotice("choose how Marlin should run models · keys are saved by the daemon host", .{});
}

pub fn applySetupStatus(self: *App, status: proto.SetupStatus) void {
    self.setup.readiness = .fromWire(status);
    if (!self.setup.status_pending) return;
    self.setup.status_pending = false;
    self.beginSetup(self.setup.required);
}

pub fn setupProviderFromItem(item: []const u8) ?SetupProvider {
    for (setup_provider_items, 0..) |candidate, index| {
        if (std.mem.eql(u8, item, candidate)) return @enumFromInt(index);
    }
    return null;
}

pub fn setupProviderReady(self: *const App, provider: SetupProvider) bool {
    return switch (provider) {
        .openrouter => self.setup.readiness.openrouter_ready,
        .codex => self.setup.readiness.codex_authenticated,
        .claude_code => self.setup.readiness.claude_code_authenticated,
        .vercel => self.setup.readiness.vercel_ready,
        .anthropic => self.setup.readiness.anthropic_ready,
        .litellm => self.setup.readiness.litellm_ready,
        .local => self.setup.readiness.local_ready,
        .custom => false,
    };
}

pub fn setupProviderNote(self: *const App, item: []const u8) []const u8 {
    const provider = setupProviderFromItem(item) orelse return "";
    if (self.setupProviderReady(provider)) return switch (provider) {
        .codex, .claude_code => "  ✓ signed in",
        .local => "  ✓ configured",
        else => "  ✓ key found",
    };
    return switch (provider) {
        .codex => if (self.setup.readiness.codex_available) "  · login needed" else "  · not installed",
        .claude_code => if (self.setup.readiness.claude_code_available) "  · login needed" else "  · not installed",
        .custom => "",
        else => "  · setup needed",
    };
}

pub fn setSetupBuffer(self: *App, buffer: *std.ArrayList(u8), value: []const u8) bool {
    buffer.clearRetainingCapacity();
    buffer.appendSlice(self.gpa, value) catch {
        self.setNotice("could not continue provider setup", .{});
        return false;
    };
    return true;
}

pub fn startSetupPrompt(self: *App, prompt: SetupPrompt, initial: []const u8, notice: []const u8) void {
    self.picker = null;
    self.picker_filter.clearRetainingCapacity();
    self.setup.prompt = prompt;
    self.mode = .insert;
    self.view.editor.replaceText(initial);
    self.setNotice("{s}", .{notice});
}

pub fn setupProviderChosen(self: *App, item: []const u8) void {
    const provider = setupProviderFromItem(item) orelse return;
    self.clearSetupDraft();
    self.setup.provider = provider;
    switch (provider) {
        .codex => {
            if (!self.setup.readiness.codex_available) {
                self.openPicker(.setup_provider);
                self.setNotice("Codex is not installed on the daemon host · install it, then retry /setup", .{});
                return;
            }
            if (!self.setup.readiness.codex_authenticated) {
                self.openPicker(.setup_provider);
                self.setNotice("Codex guest needs a ChatGPT session · run `codex login` on the daemon host, then /setup", .{});
                return;
            }
            self.finishSetup("codex/default");
        },
        .claude_code => {
            if (!self.setup.readiness.claude_code_available) {
                self.openPicker(.setup_provider);
                self.setNotice("Claude Code is not installed on the daemon host · install it, then retry /setup", .{});
                return;
            }
            if (!self.setup.readiness.claude_code_authenticated) {
                self.openPicker(.setup_provider);
                self.setNotice("Claude Code needs a login · run `claude auth login` on the daemon host, then /setup", .{});
                return;
            }
            self.finishSetup("claudecode/default");
        },
        .openrouter => {
            if (!self.setSetupBuffer(&self.setup.provider_name, "openrouter")) return;
            if (!self.setSetupBuffer(&self.setup.base_url, "https://openrouter.ai/api/v1")) return;
            if (!self.setSetupBuffer(&self.setup.api_key_env, "OPENROUTER_API_KEY")) return;
            if (self.setup.readiness.openrouter_ready)
                self.startSetupPrompt(.model, "openrouter/anthropic/claude-sonnet-4.5", "choose a registry model id · Enter accepts the suggested model")
            else
                self.startSetupPrompt(.credential, "", "paste an OpenRouter API key · input is masked · Esc goes back");
        },
        .vercel => {
            if (!self.setSetupBuffer(&self.setup.provider_name, "vercel")) return;
            if (!self.setSetupBuffer(&self.setup.base_url, "https://ai-gateway.vercel.sh/v1")) return;
            if (!self.setSetupBuffer(&self.setup.api_key_env, "AI_GATEWAY_API_KEY")) return;
            if (self.setup.readiness.vercel_ready)
                self.startSetupPrompt(.model, "vercel/anthropic/claude-sonnet-4.5", "choose a Vercel gateway model id · Enter accepts the suggestion")
            else
                self.startSetupPrompt(.credential, "", "paste a Vercel AI Gateway API key · input is masked · Esc goes back");
        },
        .anthropic => {
            if (!self.setSetupBuffer(&self.setup.provider_name, "anthropic")) return;
            if (!self.setSetupBuffer(&self.setup.base_url, "https://api.anthropic.com/v1")) return;
            if (!self.setSetupBuffer(&self.setup.api_key_env, "ANTHROPIC_API_KEY")) return;
            if (self.setup.readiness.anthropic_ready)
                self.startSetupPrompt(.model, "anthropic/claude-sonnet-4-5", "choose an Anthropic model id · Enter accepts the suggestion")
            else
                self.startSetupPrompt(.credential, "", "paste an Anthropic API key · input is masked · Esc goes back");
        },
        .litellm => {
            if (!self.setSetupBuffer(&self.setup.provider_name, "litellm")) return;
            if (!self.setSetupBuffer(&self.setup.api_key_env, "LITELLM_API_KEY")) return;
            self.startSetupPrompt(.base_url, "http://127.0.0.1:4000/v1", "LiteLLM base URL · Enter accepts the local default");
        },
        .local => {
            if (!self.setSetupBuffer(&self.setup.provider_name, "local")) return;
            if (!self.setSetupBuffer(&self.setup.api_key_env, "MARLIN_LOCAL_API_KEY")) return;
            self.startSetupPrompt(.base_url, "http://127.0.0.1:11434/v1", "OpenAI-compatible base URL · edit the suggested local address if needed");
        },
        .custom => self.startSetupPrompt(.provider_name, "", "short provider name, for example acme · model ids will use acme/…"),
    }
}

pub fn setupCredentialRequired(self: *const App) bool {
    return switch (self.setup.provider orelse return false) {
        .openrouter, .vercel, .anthropic => true,
        else => false,
    };
}

pub fn setupModelSuggestion(self: *const App) []const u8 {
    return switch (self.setup.provider orelse return "") {
        .openrouter => "openrouter/anthropic/claude-sonnet-4.5",
        .vercel => "vercel/anthropic/claude-sonnet-4.5",
        .anthropic => "anthropic/claude-sonnet-4-5",
        .litellm => "litellm/",
        .local => "local/",
        .custom => "",
        .codex, .claude_code => "",
    };
}

pub fn submitSetupPrompt(self: *App, raw: []const u8) void {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    switch (self.setup.prompt) {
        .none => {},
        .provider_name => {
            if (!validSetupProviderName(value)) {
                self.setNotice("provider name must use letters, digits, - or _", .{});
                return;
            }
            if (!self.setSetupBuffer(&self.setup.provider_name, value)) return;
            var env_name: [96]u8 = undefined;
            if (value.len + "_API_KEY".len > env_name.len) {
                self.setNotice("provider name is too long", .{});
                return;
            }
            for (value, 0..) |byte, i| env_name[i] = if (byte == '-') '_' else std.ascii.toUpper(byte);
            @memcpy(env_name[value.len..][0.."_API_KEY".len], "_API_KEY");
            if (!self.setSetupBuffer(&self.setup.api_key_env, env_name[0 .. value.len + "_API_KEY".len])) return;
            self.startSetupPrompt(.base_url, "https://", "OpenAI-compatible base URL, including /v1 when your provider requires it");
        },
        .base_url => {
            if (!(std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://"))) {
                self.setNotice("base URL must start with http:// or https://", .{});
                return;
            }
            if (!self.setSetupBuffer(&self.setup.base_url, value)) return;
            self.startSetupPrompt(.credential, "", "API key (optional for local gateways) · Enter skips · input is masked");
        },
        .credential => {
            if (self.setupCredentialRequired() and value.len < 8) {
                self.setNotice("that does not look like an API key · Esc goes back", .{});
                return;
            }
            if (!self.setSetupBuffer(&self.setup.credential, value)) return;
            if (value.len == 0 and self.setup.provider != .openrouter and self.setup.provider != .vercel and self.setup.provider != .anthropic) {
                if (!self.setSetupBuffer(&self.setup.api_key_env, "NONE")) return;
            }
            const suggestion = if (self.setup.provider == .custom)
                std.fmt.allocPrint(self.gpa, "{s}/", .{self.setup.provider_name.items}) catch return
            else
                self.gpa.dupe(u8, self.setupModelSuggestion()) catch return;
            defer self.gpa.free(suggestion);
            self.startSetupPrompt(.model, suggestion, "finish the model id in provider/model form");
        },
        .model => {
            const slash = std.mem.indexOfScalar(u8, value, '/') orelse {
                self.setNotice("model must use provider/model form", .{});
                return;
            };
            if (slash == 0 or slash + 1 == value.len) {
                self.setNotice("model id needs a name after provider/", .{});
                return;
            }
            const expected = self.setup.provider_name.items;
            if (expected.len > 0 and !std.mem.eql(u8, value[0..slash], expected)) {
                self.setNotice("model id must start with {s}/", .{expected});
                return;
            }
            self.finishSetup(value);
        },
    }
}

pub fn finishSetup(self: *App, model: []const u8) void {
    if (self.setup.apply_pending) return;
    const configured_provider = self.setup.provider_name.items;
    self.conn.sendSensitive(.{ .setup_apply = .{
        .sid = self.view.sid,
        .model = model,
        .provider_name = configured_provider,
        .base_url = self.setup.base_url.items,
        .api_key_env = self.setup.api_key_env.items,
        .credential = self.setup.credential.items,
        .replace_empty_session = self.setup.replace_empty_session,
    } }) catch {
        self.setNotice("could not send provider setup to the daemon", .{});
        return;
    };
    if (self.setup.credential.items.len > 0) @memset(self.setup.credential.items, 0);
    self.setup.credential.clearRetainingCapacity();
    self.view.editor.clearSensitive();
    self.setup.prompt = .none;
    self.picker = null;
    self.setup.apply_pending = true;
    self.setNotice("activating provider setup on the daemon host…", .{});
}

pub fn applySetupResult(self: *App, result: @FieldType(proto.DaemonMsg, "setup_result")) void {
    self.setup.apply_pending = false;
    self.setup.readiness.completed = true;
    self.setup.required = false;
    self.setup.replace_empty_session = false;
    if (result.session_updated) {
        self.setModelStr(result.model);
        self.setNotice("ready · {s} · /setup changes provider later", .{result.model});
    } else if (!std.mem.eql(u8, self.view.model.items, result.model)) {
        self.applyModel(result.model);
    } else {
        self.setNotice("provider setup saved · {s}", .{result.model});
    }
    self.clearSetupDraft();
}
