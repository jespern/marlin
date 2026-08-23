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
│   │   │   ├── sidebar.zig    # session list + status glyphs
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
    └── PROTOCOL.md            # wire protocol reference (grows with proto.zig)
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

## M3 — context engine done right
L0 caps + L1 pruning + L2 compaction w/ headroom trigger + rehydration +
usage accounting in status bar. Fixture tests for the cascade.
*Exit: a 3-hour session never hits a context error and costs behave.*

## M4 — multiplexer
Sidebar, splits, J/K session switching, status glyphs (running/idle/approval),
mouse selection + OSC52, !c family, daemon-side register (!y/!p cross-session).
*Exit: herdr/tmux no longer wrap marlin; marlin IS the terminal you keep open.*

## M5 — extensibility
MCP stdio client, exec tools, hooks (approval-needed → ntfy script = phone
notifications), skills. *Exit: one real MCP server + one hook in daily use.*

## M6 — hardening & v2 doors
bash sandboxing (seatbelt/Landlock), allowlist promotion UX, `task` subagent
tool + nested sidebar, TCP listener + token auth. Then decide: PWA client.

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
