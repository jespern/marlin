# Module layout

```
marlin/
├── build.zig
├── build.zig.zon              # deps: libvaxis, regex; vendored SQLite for releases
├── src/
│   ├── main.zig               # entry; test import block (every file must be reachable)
│   ├── cli.zig                # arg parse → daemon | attach | run | ls | top | ... | --remote
│   │
│   ├── core/                  # shared by daemon & client; no I/O policy here
│   │   ├── block.zig          # BlockKind, Block, serialization (json)
│   │   ├── proto.zig          # wire message types, encode/decode, versioning
│   │   ├── guest.zig          # guest namespace (claudecode/, codex/) parsing
│   │   ├── config.zig         # TOML load, defaults, validation, surgical edits
│   │   ├── config_toml.zig    # the focused TOML decoder
│   │   ├── credentials.zig    # 0600 credential file, config dir resolution
│   │   ├── effort.zig         # reasoning effort enum
│   │   ├── jsonx.zig          # lenient JSON repair (tool args), helpers
│   │   ├── ids.zig            # session/block/turn id generation
│   │   ├── session_handle.zig # short stable session handles
│   │   ├── queue.zig          # MPSC event queue
│   │   └── telemetry.zig      # stable OTLP trace/span id formatting
│   │
│   ├── daemon/
│   │   ├── daemon.zig         # listener, client registry, event fan-out, dispatcher;
│   │   │                      #   owns the live Session structs; NORMATIVE thread inventory
│   │   ├── store.zig          # SQLite: blocks, sessions, blobs, telemetry; the ONLY sqlite user
│   │   ├── loop.zig           # NATIVE agent turn: assemble→stream→tools→repeat; steer queue
│   │   ├── guest/             # guest turns behind a compiler-enforced wall
│   │   │   ├── claude_code_turn.zig  # `claude -p` stream-json host
│   │   │   ├── codex_turn.zig        # `codex app-server` JSON-RPC host
│   │   │   └── shared.zig            # delegate error detail, watcher, stderr drain
│   │   ├── context.zig        # assembly + L0 caps + L1 prune + L2 compaction + rehydrate
│   │   ├── approval.zig       # approval policy + gate (once/session grants: TODO M3.5)
│   │   ├── permissions.zig    # protected paths, secret redaction, tool environment
│   │   ├── sandbox.zig        # runtime-verified Seatbelt/Landlock selection + canary
│   │   ├── landlock.zig       # Linux ruleset planner + `marlin landlock_exec`
│   │   ├── process_io.zig     # subprocess run/cancel/kill with process-tree sweeps
│   │   ├── shell_network.zig  # bash destination screening
│   │   ├── network_policy.zig # DNS blocklists / allow / deny for marlin-owned tools
│   │   ├── extensions.zig     # exec tools, MCP servers (parallel discovery), hooks, skills
│   │   ├── otel.zig           # asynchronous OTLP/HTTP outbox drain
│   │   ├── hooks.zig          # event → script runner
│   │   ├── skills.zig         # index scan, frontmatter parse, skill tool
│   │   ├── tools/
│   │   │   ├── registry.zig   # spec: name, schema, parallel_safe, policy; dispatch
│   │   │   ├── bash.zig       # subprocess, cancellation, sandbox wrapper
│   │   │   ├── files.zig      # read/write/edit (fuzzy string-replace), protected-path refusals
│   │   │   ├── search.zig     # grep (rg → system grep → native), glob
│   │   │   ├── fetch.zig      # bounded std.http GET → readable text
│   │   │   ├── exec_tool.zig  # config-declared executable tools
│   │   │   ├── task.zig       # task / task_batch child sessions
│   │   │   ├── plan.zig       # plan_update durable execution plans
│   │   │   └── mcp.zig        # MCP client, stdio transport, tool bridging
│   │   └── provider/
│   │       ├── provider.zig   # Backend = native(Dialect) | guest(Guest); iface
│   │       ├── registry.zig   # model string → backend, base URL, credential env
│   │       ├── openai_compat.zig
│   │       ├── anthropic.zig
│   │       ├── claude_code.zig # guest adapter: argv, session uuid, stream-json decode
│   │       ├── codex.zig       # guest adapter: app-server JSON-RPC decode
│   │       ├── sse.zig        # SSE parser (shared)
│   │       └── http.zig       # pooled std.http transport, streaming, cancellation
│   │
│   ├── client/
│   │   ├── attach.zig         # socket/ssh transports, autostart handshake, hello
│   │   ├── pipe.zig           # `marlin _pipe`: stdio↔daemon.sock bridge (remote far end)
│   │   ├── tui.zig            # App + SessionView, event loop, daemon protocol, draw, tabs
│   │   ├── commands.zig       # / and ! command table, completion, command handlers
│   │   ├── keys.zig           # key/mouse dispatch, vim operators (VimState), copy-mode keys
│   │   ├── setup.zig          # /setup provider onboarding wizard (SetupState)
│   │   ├── search.zig         # Ctrl+R history search, /search transcripts, hit jump
│   │   ├── render.zig         # terminal lines, palette, syntax, wrapping
│   │   ├── markdown.zig       # inline/block Markdown, tables, panels, callouts
│   │   ├── layout.zig         # transcript view, caches, tool folding, diffs, plan table
│   │   ├── editor.zig         # composer editing + vim ops
│   │   ├── top.zig            # `marlin top` live hierarchy view
│   │   ├── media.zig          # image paste/path attachments
│   │   ├── voice.zig          # optional local push-to-talk dictation
│   │   ├── self_build.zig / remote_rebuild.zig  # `!rb` source rebuilds
│   │   ├── cc_approve.zig     # Claude Code permission bridge (MCP stdio)
│   │   ├── web.zig            # `marlin web`: localhost HTTP/SSE bridge, tailnet-fronted
│   │   └── headless.zig       # `marlin run` and the scripting subcommands
│   │
│   └── testing/
│       ├── e2e_runner.zig     # scenario runner (fake provider, MCP/hook fixtures)
│       ├── fake_provider_main.zig  # scripted OpenAI-compat server for e2e
│       ├── fixture_tests.zig  # recorded SSE replay at several chunk sizes
│       ├── reboot_convergence.sh   # reboot vs kill-9 restore identical state
│       ├── scenarios/         # 23 e2e scenario files
│       └── fixtures/          # recorded SSE streams, local_testing model
└── docs/
    ├── ARCHITECTURE.md
    ├── MILESTONES.md
    ├── PROTOCOL.md            # wire protocol reference (grows with proto.zig)
    ├── PERMISSIONS.md         # the M3.5 permissions/secret-boundary contract
    ├── TESTING.md, OBSERVABILITY.md, WORKSPACE.md
    ├── REVIEW.md              # multi-model review councils (shipped)
    └── SOFTWARE_REVIEW_*.md   # dated point-in-time reviews
```

Dependency rules (enforce by convention, they keep the build fast and the
extraction clean):

- `core/` imports nothing from `daemon/` or `client/`.
- `client/` never imports `daemon/` — only `core/` (protocol + blocks). This is
  what keeps "the TUI is just a client" true, and makes the (v2) web client a
  sibling, not a fork.
- `daemon/store.zig` is the only file that knows SQL. HTTP transport is isolated
  in `daemon/provider/http.zig`.

# Milestones

The active M3.5 permissions contract lives in `docs/PERMISSIONS.md`. M4 and
deferred M4.5 decisions live in `docs/M4_PLAN.md`.

Each milestone ends with something you use daily; cut scope inside a milestone,
never the ordering. (Rough sizing assumes nights-and-weekends pace.)

## M0 — walking skeleton (the loop, no daemon)
`marlin run "list files here"` → OpenRouter, streaming to stdout, bash+read
tools (auto-approve), one session written to SQLite, resumable with
`marlin run --continue`. Proves: SSE, tool loop, store, provider iface.
*Exit: you use it for real one-shot questions.*

## M1 — daemon + protocol + headless client
Split into marlind + `marlin run` as a protocol client. Multiple concurrent
sessions, `marlin ls`, attach/reattach with from_seq replay, interrupt.
*Exit: two terminals watching the same live session; kill client, session
survives.*

## M2 — TUI v1 (single pane)
vaxis client: session view w/ virtual scrollback, streaming region, input box,
insert/normal modes, /model /new /compact(manual stub), Ctrl+C interrupt,
steer-while-running. Full tool set (write/edit/grep/glob/fetch) + approval
prompts inline. *Exit: marlin replaces your daily driver for some real tasks.*

## M3 — context engine + self-hosting
L0 caps + L1 pruning + L2 compaction w/ headroom trigger + rehydration +
usage accounting in status bar. Fixture tests for the cascade.
`/reboot` + scoped `!rb` source rebuilds (attached/client/both;
ARCHITECTURE.md §self-hosting reboot): coordinated re-exec onto fresh binaries
with full state restore — from here marlin is developed from inside marlin.
e2e: reboot vs kill-9 converge. *Exit: a 3-hour session never hits a context
error, costs behave, and you ship a marlin change from a marlin session and
`!rb` into it.*

## M3.5 — permissions and secret boundary
Capability-scoped approvals (once or session), scrubbed tool-process
environments, protected-path enforcement, exact-value capture redaction, and
platform shell sandboxes. Existing per-tool approval behavior remains the
fallback when sandbox verification fails; a verified sandbox makes operations
inside the exact session workspace automatic. The Later workspace track adds
recovery, not write authority.
*Exit: provider secrets cannot enter tool output, protected reads and outside
writes are enforceably blocked, and escalation cards name the exact capability
and scope being granted.*

## M4 — multiplexer
**Status: implemented and verified (2026-08-24).**
No persistent sidebar. Unarchived root sessions live in a permanent clickable
top tab strip; `/sessions` remains the fuzzy hierarchy picker, while `/top` or
`Ctrl+S` opens a live full-screen hierarchy with switching and lifecycle actions.
The standalone `marlin top` provides the same operational overview outside an
attached session. `gt`/`gT` switch recent sessions. Child activity rolls up to
its root tab and the status bar shows only actionable background totals. Session switching preserves each
session's view and draft. Mouse selection + OSC52 and the `!c` family finish
the focused terminal workflow. Two-pane
splits and cross-session registers are candidate slices, not exit
requirements; decide them in `docs/M4_PLAN.md` before work starts (the
split design and cost review lives in `docs/PANES_PLAN.md`). Remote
attach shipped as `marlin --remote <host>` (ARCHITECTURE.md, Mode B). The post-M4 rich-input slice now supplies remote-safe clipboard/path
image attachments and provider vision mapping.
*Exit: several local sessions can run and be revisited from one full-width
Marlin UI without losing their place or hiding actionable background state.*

## M5 — extensibility
**Status: productized and automated (2026-08-25); daily-use proof remains.**
Owned TOML configuration, MCP stdio client (current protocol plus legacy
fallback), isolated per-server health, daemon-owned add/remove/restart/reload,
per-tool read/write policy, durable image results, exec tools, non-blocking
hooks (approval/turn/session/error), and on-demand skills. All extension tools
use the provider schema list and the same approval gate as built-ins.
*Exit: one real MCP server + one hook in daily
use; the fake-provider/stdio E2E gates prove mechanics, not operational value.*

## M6 — hardening & v2 doors
**Status: active; bounded child fan-out verified (2026-08-25).** Durable
read-only `task` and `task_batch` children now have parent/child hierarchy,
dispatcher-owned creation, cancellation cascade, round budgets, ordered
structured results, an eight-child concurrency ceiling, and session-picker
visibility. Multi-model review councils (docs/REVIEW.md) shipped as
specialized read-only task fan-out (`/council`, `/review`, durable
`[[council]]`). The remote door is decided and shipped (docs/M6_PLAN.md
M6c): ssh for terminals, the tailnet for the phone PWA, no marlin-owned
TCP listener or bearer tokens. Remaining M6 hardening is measurement and
shape, per the dated software reviews.

## Later — workspace recovery & isolation (formerly M4.5)
Copy-on-write snapshots with portable fallback, `/undo` preview, external
drift notes, write leases/parking, then worktree isolation with `/land` and
`/discard`. Kept as one ordered track so phase 2 does not precede phase 1.
Feature-flagged `[workspace] enabled`, DEFAULT OFF.
*Exit: concurrent Marlin sessions cannot silently clobber one another, external
writes remain recoverable, and isolated work lands only through reviewed merge.*

# Former open questions — all decided in code

Kept as a decision record; none of these are open.

1. **Single binary or two?** DECIDED: single binary, `marlin daemon`
   subcommand.
2. **Autostart semantics**: DECIDED: autostart on first `marlin` invocation.
   An advisory exclusive instance lock serializes concurrent autostarts before
   either process can replace the Unix socket.
3. **Block body schema versioning**: DECIDED: store schema migrations at
   daemon boot + `proto_version` handshake rejection; block bodies are
   std.json tagged unions.
4. **Zig version pin**: DECIDED: track the Zig version libvaxis follows
   (0.16-dev line); deps vendored via build.zig.zon.
5. **Name check**: DECIDED: shipping as `marlin`.
```
