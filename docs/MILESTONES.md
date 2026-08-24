# Module layout

```
marlin/
├── build.zig
├── build.zig.zon              # deps: libvaxis, zig-toml (sqlite/curl via system C)
├── src/
│   ├── main.zig               # arg parse → daemon | attach | run | ls | ...
│   │
│   ├── core/                  # shared by daemon & client; no I/O policy here
│   │   ├── block.zig          # BlockKind, Block, serialization (json)
│   │   ├── proto.zig          # wire message types, encode/decode, versioning
│   │   ├── config.zig         # TOML load, defaults, validation
│   │   ├── jsonx.zig          # lenient JSON repair (tool args), helpers
│   │   └── ids.zig            # session/block/turn id generation
│   │
│   ├── daemon/
│   │   ├── daemon.zig         # listener, client registry, event fan-out, main loop
│   │   ├── session.zig        # session state machine (idle/running/awaiting/...)
│   │   ├── store.zig          # SQLite: blocks, sessions, blobs, FTS; the ONLY sqlite user
│   │   ├── loop.zig           # agent turn: assemble→stream→tools→repeat; steer queue
│   │   ├── context.zig        # assembly + L0 caps + L1 prune + L2 compaction + rehydrate
│   │   ├── approval.zig       # policies, allowlists, pending-approval registry
│   │   ├── tools/
│   │   │   ├── registry.zig   # spec: name, schema, parallel_safe, policy; dispatch
│   │   │   ├── bash.zig       # subprocess, cancellation, (later: sandbox.zig)
│   │   │   ├── files.zig      # read/write/edit (fuzzy string-replace)
│   │   │   ├── search.zig     # grep (rg-or-internal), glob
│   │   │   ├── fetch.zig      # curl GET → text
│   │   │   ├── exec_tool.zig  # config-declared executable tools
│   │   │   └── mcp.zig        # MCP client, stdio transport, tool bridging
│   │   ├── provider/
│   │   │   ├── provider.zig   # iface: request(messages,tools) → event stream
│   │   │   ├── openai_compat.zig
│   │   │   ├── anthropic.zig
│   │   │   ├── sse.zig        # SSE parser (shared)
│   │   │   ├── http.zig       # libcurl wrapper, retry/backoff, cancellation
│   │   │   └── registry.zig   # model string → dialect+endpoint+key
│   │   ├── hooks.zig          # event → script runner
│   │   └── skills.zig         # index scan, frontmatter parse, skill tool
│   │
│   ├── client/
│   │   ├── attach.zig         # socket client, reconnect w/ from_seq, delta buffer
│   │   ├── tui.zig            # vaxis init, event loop, mode state machine
│   │   ├── ui/
│   │   │   ├── layout.zig     # binary-tree splits, focus
│   │   │   ├── session_view.zig  # virtual block list, streaming region, collapse
│   │   │   ├── session_picker.zig # on-demand session switcher + activity state
│   │   │   ├── input.zig      # prompt box, /-commands, !-commands, history
│   │   │   ├── select.zig     # mouse selection over logical text, OSC52 copy
│   │   │   └── markdown.zig   # minimal md render (headings, code, lists, inline)
│   │   └── headless.zig       # `marlin run`: same protocol, no UI
│   │
│   └── testing/
│       ├── fake_provider.zig  # scripted OpenAI-compat server for e2e
│       └── fixtures/          # recorded SSE streams, NDJSON transcripts
└── docs/
    ├── ARCHITECTURE.md
    ├── MILESTONES.md
    ├── PROTOCOL.md            # wire protocol reference (grows with proto.zig)
    └── REVIEW.md              # multi-model review councils (post-M4 design)
```

Dependency rules (enforce by convention, they keep the build fast and the
extraction clean):

- `core/` imports nothing from `daemon/` or `client/`.
- `client/` never imports `daemon/` — only `core/` (protocol + blocks). This is
  what keeps "the TUI is just a client" true, and makes the (v2) web client a
  sibling, not a fork.
- `daemon/store.zig` is the only file that knows SQL. `daemon/provider/http.zig`
  is the only file that knows curl.

# Milestones

Detailed decisions and proposed build slices for the current M3.5 → M4 work
live in `docs/M3_5_M4_PLAN.md`. Implementation stays paused until its open
product questions are resolved.

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
`/reboot` + `/reboot --build` (ARCHITECTURE.md §self-hosting reboot):
coordinated re-exec onto fresh binaries with full state restore — from here
marlin is developed from inside marlin. e2e: reboot vs kill-9 converge.
*Exit: a 3-hour session never hits a context error, costs behave, and you
ship a marlin change from a marlin session and `/reboot --build` into it.*

## M3.5 — workspace layer, phase 1 (docs/WORKSPACE.md)
Copy-on-write shadow snapshots (per-file reflinks with a portable copy
fallback; /undo with diff preview; drift notes when external tools edit the wc)
+ write leases (`waiting_workspace` parking). Feature-flagged `[workspace]
enabled`, DEFAULT OFF — M2 approval
semantics hold until sandbox escalations land (M4/M5).
*Exit: two marlin sessions on one repo can't clobber each other; codex
running alongside marlin is detected, absorbed, and undoable.*

## M4 — multiplexer
No persistent sidebar. Sessions live in an on-demand `/sessions` picker with
title/workspace/status, J/K switches recent sessions, and the status bar shows
only actionable background activity (for example `2 running · 1 approval`).
Splits carry a small per-pane session label. Mouse selection + OSC52, !c family,
and daemon-side register (!y/!p cross-session).
Image paste (ARCHITECTURE.md §image/asset paste): clipboard capture →
attachment upload → blob → vision content parts; kitty-protocol thumbnails
or placeholder cards.
Remote Mode B (§remote access): `marlin attach <remote>` speaking the wire
protocol over ssh, named remotes in config, skew-mismatch recovery gesture.
Primary remote path from here; ssh -t stays as fallback.
*Exit: herdr/tmux no longer wrap marlin; marlin IS the terminal you keep open,
including for the work machine from the laptop.*

## M5 — extensibility
MCP stdio client, exec tools, hooks (approval-needed → ntfy script = phone
notifications), skills. *Exit: one real MCP server + one hook in daily use.*

## M6 — hardening & v2 doors
Workspace phase 2 (docs/WORKSPACE.md): bash sandboxing (seatbelt/Landlock)
+ capability escalations through the approval gate (retires per-tool ask
prompts), worktree isolation w/ /land and /discard. `task` subagent
tool + parent/child hierarchy in the session picker, TCP listener + token auth.
Then decide: PWA client.
Multi-model review councils (docs/REVIEW.md) build on the subagent machinery
here — a review child is a specialized `task` child.

# Open questions (decide before M1, none block M0)

1. **Single binary or two?** Start single (`marlin daemon` subcommand);
   revisit if binary size or privilege separation ever matters.
2. **Autostart semantics**: `marlin` spawns daemon if absent (flock race
   handled), or explicit `marlin daemon` only? Lean: autostart, it's the
   tmux-like ergonomic.
3. **Block body schema versioning**: bump `proto_version` on breaking change
   and migrate DB, or tagged unions with forward-compat unknowns? Lean:
   version field per block, ignore-unknown on read.
4. **Zig version pin**: pick the version libvaxis tracks (they follow master
   closely); vendor deps in build.zig.zon and update deliberately.
5. **Name check**: `marlin` — verify no collision that matters to you
   (crates/brews/etc.) before publishing anything.
```
