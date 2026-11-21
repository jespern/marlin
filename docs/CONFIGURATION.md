# Providers, MCP servers, and limits

## MCP servers

MCP is daemon-owned rather than a client-side plugin shim. Stdio servers are
discovered independently, so one broken server is reported as unavailable
without taking down Marlin or hiding healthy servers. Manage the durable config
from either client surface:

```sh
marlin mcp add playwright -- npx @playwright/mcp
marlin mcp list
marlin mcp restart playwright
marlin mcp remove playwright
```

The TUI equivalents are `/mcp`, `/mcp add`, `/mcp restart`, `/mcp remove`, and
`/mcp reload`. Tool read/write policy follows MCP annotations with exact
`readonly_tools` and `mutating_tools` config overrides. Image results are stored
as transcript media and sent back to vision-capable providers.

A server that says its tools changed (`notifications/tools/list_changed`) has
them listed again without a restart: Marlin subscribes with
`subscriptions/listen` on 2026-07-28 servers, reads older stdio servers'
unasked notices as they come, and holds an older HTTP server's GET stream when
its `initialize` offers `tools.listChanged`. Running turns keep the list they
started with; the new one applies once no turn is running.

### Remote servers and sign-in

A server with a URL instead of a command speaks Streamable HTTP (MCP
2026-07-28, falling back to 2025-11-25 sessions for older servers):

```sh
marlin mcp add linear https://mcp.linear.app/mcp
```

```toml
[[mcp]]
name = "linear"
url = "https://mcp.linear.app/mcp"   # HTTPS, or plain HTTP to this machine only
headers = ["X-Team: core"]           # optional extra request headers
```

A server that wants OAuth shows as `needs login` in `/mcp`. `/mcp login
<name>` (or `marlin mcp login <name>`) finds the server's authorization
server, registers Marlin as a native client, and posts a sign-in link. After
you approve, the browser returns to a listener on the daemon's `127.0.0.1`.
When that machine is not the one running your browser (over SSH, say), the
browser's redirect fails; copy the address it tried to open and run
`/mcp login <name> <that-url>` to finish. Tokens live in
`~/.config/marlin/mcp-auth.json` (mode 0600), bound to the server's URL, and
refresh on their own. `/mcp logout <name>` deletes them.

Local servers can carry extra environment: `env = ["KEY=value"]`.

### Plugin servers

Plugins installed with `/plugin install` may ship MCP servers, in `.mcp.json`
or `mcpServers` in `plugin.json`, as Claude Code plugins do. They register as
`plugin_<plugin>_<server>`, so their tools carry Claude Code's names
(`mcp__plugin_<plugin>_<server>__<tool>`), and `${CLAUDE_PLUGIN_ROOT}`,
`${CLAUDE_PLUGIN_DATA}`, `${VAR}` and `${VAR:-default}` expand. Local (stdio)
and Streamable HTTP servers are supported; SSE, WebSocket, and bundled
(`.mcpb`) servers are refused at install. A configured server with the same
name wins over a plugin's.

These servers serve native Marlin sessions. Claude Code and Codex guests keep
their own MCP configuration.

### Marlin as an MCP server

Marlin also serves MCP itself, for your assistants outside it (Robin, say):
`POST /mcp` on the web companion, so at `http://127.0.0.1:8377/mcp` on the
machine and through the same reverse proxy as the phone
(`https://marlin.example.com/mcp`). It speaks Streamable HTTP, MCP 2026-07-28,
and 2025-11-25 (and the two before) for older clients, without sessions.

Every request needs a bearer token, loopback included. Make one per assistant,
with the scopes it needs:

```sh
marlin mcp token new robin read,act   # prints the token once, on stdout
marlin mcp token                      # list: id, name, scopes
marlin mcp token revoke robin         # by name or id; open streams close
```

`/mcp token`, `/mcp token new <name> [scopes]` and `/mcp token revoke` do the
same in the TUI, including over `--remote`; the new token appears once in a
note of that view. Only a SHA-256 of each token is kept, in
`$XDG_STATE_HOME/marlin/web/mcp_tokens.json` (mode 0600). Send it as
`Authorization: Bearer <token>`.

| Scope | Tools |
| --- | --- |
| `read` | `sessions`, `read_session`, `wait_for_session`, `attention`, the `marlin://attention` resource, `subscriptions/listen` |
| `act` | `message_session`, `approve`, `answer` |

A token lists only the tools it may call; calling another answers `403` with
`WWW-Authenticate: Bearer error="insufficient_scope"`. A token holds only its
own scopes, so a reader and an actor can be separate tokens.

`attention` is the log of moments a session needed you: an approval or
question waiting (with the id to answer it), a turn finished or failed (with
its last reply or error), and a waiting one resolved, however it was
answered. Each has a growing `seq`; pass the last you saw as `after` to catch
up, or `last` for the newest few. The newest 1,000 are kept across restarts.
A 2026-07-28 client opens `subscriptions/listen` for `marlin://attention` and
gets `notifications/resources/updated` each time the log grows. Marlin's own
phone notifications are unchanged.

`message_session` arrives marked as from the token's name. `approve`
(`allow` or `deny`) and `answer` act as you would from the approval bar or the
picker, and fail when that prompt is no longer waiting.

## Provider routing

Model ids are `provider/model`. Marlin strips the first component before
sending the request, so `vercel/anthropic/claude-sonnet-4` sends
`anthropic/claude-sonnet-4` to Vercel AI Gateway.

The built-in native routes are:

- `openrouter/<model>` with `OPENROUTER_API_KEY`
- `vercel/<model>` with `AI_GATEWAY_API_KEY`
- `litellm/<model>` at `http://127.0.0.1:4000/v1`, optionally with
  `LITELLM_API_KEY`
- `anthropic/<model>` with `ANTHROPIC_API_KEY`
- `local/<model>` with `MARLIN_LOCAL_BASE_URL` and the optional
  `MARLIN_LOCAL_API_KEY`

Any other OpenAI Chat Completions-compatible router or direct endpoint is a
small config entry:

```toml
[providers.requesty]
base_url = "https://router.requesty.ai/v1"
api_key_env = "REQUESTY_API_KEY"

[model]
favorites = ["requesty/openai/gpt-5", "litellm/fast-code"]
```

`base_url` stops at the API root; Marlin appends `/chat/completions`. The
credential field names an environment variable and never contains the secret.
Use `api_key_env = "NONE"` for an intentionally keyless endpoint. Provider
config takes effect the next time the daemon starts. Configured favorites stay
available in the model picker alongside the fetched OpenRouter catalog. Key
variable names must end in `_API_KEY`, `_TOKEN`, or `_SECRET` so Marlin's tool
boundary strips and redacts them automatically.

## Guest runtime limits

Use `/runtime 12h` in a session to allow an overnight Claude Code or Codex run,
or `/runtime off` to disable its deadline. `/runtime` shows the current setting;
`/runtime default` restores the configured default. Tab completes common values.
The override persists with that session and applies immediately to a running guest.

Durations use `s`, `m`, or `h`. The allowance is measured from the current guest
invocation's start, excluding time waiting for your approval or answer; changing
it does not restart the clock. Lowering it below elapsed runtime ends the run.
Interrupt and daemon shutdown still stop the guest when the deadline is off.
This setting covers guest execution, not native model requests or bash timeouts.

The default is four hours. Set a different default in
`~/.config/marlin/config.toml` on the daemon host, then restart the daemon:

```toml
[guest]
max_runtime = "12h" # or "off"; omitted defaults to "4h"
```

## Restart handover

`/reboot` (and `!rb`, and `/reboot` on the phone) restarts Marlin without
dropping anyone: the running daemon starts its successor, passes it the
listening socket and every running `!!` shell, moves each connected terminal
and phone across, and exits only once each has arrived on the new one. A
client that does not come back in time (a laptop asleep, a phone offline)
stops being waited for after a minute; it reconnects normally when it returns.

```toml
[reboot]
handover_wait = "60s" # how long the old daemon waits for moved clients
```

## Context management today

Marlin implements a three-stage structural cascade:

1. Tool output is capped before it enters model context; the complete output
   remains available in the SQLite blob store.
2. Once context crosses a soft threshold, old inline tool results are replaced
   with short stubs while a recent-output window is protected.
3. Near the model's context limit, Marlin writes an LLM-generated continuation
   summary, preserves a recent tail, and rehydrates windows from recently
   written files plus a continuation note.

That is useful layered context management, but it is not yet a claim of mature
semantic "microcompaction." Fixture tests cover the mechanics and boundary
invariants; long-running quality and cost behavior still need M3 burn-in.
