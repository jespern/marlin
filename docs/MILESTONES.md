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
│   │   ├── approval.zig       # policies, capability grants, pending approvals
│   │   ├── permissions.zig    # capability/path policy + child secret boundary
│   │   ├── sandbox.zig        # runtime-verified Seatbelt/Landlock adapters
│   │   ├── tools/
│   │   │   ├── registry.zig   # spec: name, schema, parallel_safe, policy; dispatch
│   │   │   ├── bash.zig       # subprocess, cancellation, (later: sandbox.zig)
│   │   │   ├── files.zig      # read/write/edit (fuzzy string-replace)
│   │   │   ├── search.zig     # grep (rg → system grep → native), glob
│   │   │   ├── fetch.zig      # curl GET → text
│   │   │   ├── exec_tool.zig  # config-declared executable tools
│   │   │   └── mcp.zig        # MCP client, stdio transport, tool bridging
│   │   ├── provider/
│   │   │   ├── provider.zig   # iface: request(messages,tools) → event stream
│   │   │   ├── openai_compat.zig
│   │   │   ├── anthropic.zig
│   │   │   ├── sse.zig        # SSE parser (shared)
│   │   │   ├── http.zig       # pooled libcurl wrapper, streaming, cancellation
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
`/reboot` + `/reboot --build` (ARCHITECTURE.md §self-hosting reboot):
coordinated re-exec onto fresh binaries with full state restore — from here
marlin is developed from inside marlin. e2e: reboot vs kill-9 converge.
*Exit: a 3-hour session never hits a context error, costs behave, and you
ship a marlin change from a marlin session and `/reboot --build` into it.*

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
No persistent sidebar. Sessions live in an on-demand `/sessions` picker with
title/workspace/status, J/K switches recent sessions, and the status bar shows
only actionable background activity (for example `2 running · 1 approval`).
Session switching preserves each session's view and draft. Mouse selection +
OSC52 and the `!c` family finish the focused terminal workflow. Two-pane
splits, image input, cross-session registers, and remote attach are candidate
slices, not exit requirements; decide them in `docs/M4_PLAN.md` before work
starts.
*Exit: several local sessions can run and be revisited from one full-width
Marlin UI without losing their place or hiding actionable background state.*

## M5 — extensibility
**Status: implemented and automated (2026-08-24); daily-use proof remains.**
Owned TOML configuration, MCP stdio client (current protocol plus legacy
fallback), exec tools, non-blocking hooks (approval/turn/session/error), and
on-demand skills. All extension tools use the provider schema list and the
same approval gate as built-ins. *Exit: one real MCP server + one hook in daily
use; the fake-provider/stdio E2E gates prove mechanics, not operational value.*

## M6 — hardening & v2 doors
**Status: active; single-child vertical slice verified (2026-08-24).** Durable
read-only `task` children now have parent/child hierarchy, dispatcher-owned
creation, cancellation cascade, round budgets, structured results, and
session-picker visibility. Next: parallel-safe execution and multi-child
ordering; then multi-model review councils (docs/REVIEW.md) as specialized
read-only task fan-out. TCP listener/token auth is a retained v2 door to
schedule only for a concrete
remote-client need. Then decide: PWA client. Execution plan: `docs/M6_PLAN.md`.

## Later — workspace recovery & isolation (formerly M4.5)
Copy-on-write snapshots with portable fallback, `/undo` preview, external
drift notes, write leases/parking, then worktree isolation with `/land` and
`/discard`. Kept as one ordered track so phase 2 does not precede phase 1.
Feature-flagged `[workspace] enabled`, DEFAULT OFF.
*Exit: concurrent Marlin sessions cannot silently clobber one another, external
writes remain recoverable, and isolated work lands only through reviewed merge.*

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
