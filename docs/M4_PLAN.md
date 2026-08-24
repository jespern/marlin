# M4 → M4.5 planning ledger

Status: **planning only**. Do not begin implementation until the open M4
product decisions below have been reviewed. `MILESTONES.md` remains the
roadmap; this document is the execution contract for the next two milestones.

## Current position

Treat M3 as closed for feature sequencing. Context management, compaction,
usage accounting, and self-hosting reboot exist and pass the automated gates;
normal dogfooding can continue to produce M3 polish without holding M4.

M4 is now the next milestone: focused multi-session terminal UX without
persistent chrome. Workspace snapshots, drift, undo, and write leases are
explicitly deferred to M4.5. Their design is recorded below but is not a gate
for M4 and should be reopened using evidence from multi-session dogfooding.

## Decisions already made

1. **No persistent sidebar.** Session navigation is on demand through a fuzzy
   `/sessions` picker. Normal-mode J/K switches recent sessions. Actionable
   background state appears temporarily in the status bar. Split panes, if we
   keep them, identify their session with a compact pane label.
2. **Workspace safety is deferred, not half-built.** M4 does not implement
   snapshots, drift detection, `/undo`, `waiting_workspace`, or write leases.
   Existing per-tool approval behavior remains unchanged and the workspace
   feature flag stays off.
3. **Blocks remain truth.** Durable session events survive reconnect and
   reboot. Transient UI state is derived from blocks and protocol status, not
   held only in a client.
4. **No speculative multiplexer complexity.** Start with the smallest session
   workflow that improves daily use; add panes or registers only after their
   value is demonstrated.

## M4 prerequisite engineering

These are enabling tasks rather than product features:

- Add a daemon-level session-status watch so the client can report actionable
  background sessions without attaching to every block stream.
- Give render blocks their durable `seq` and `turn_id` before implementing
  turn-level collapse, lazy scrollback, or per-session caches.
- Store view state by session: scroll position, selection, and input draft.
- Split the TUI by responsibility after those state contracts settle: session
  view/Markdown, composer, selection, session picker, and optional pane layout.
  Extraction must be behavior-neutral and protected by layout tests.

## M4 decisions to settle

### 1. Do we actually want splits?

No sidebar does not answer this. The useful choices are:

- one focused session plus `/sessions` only;
- at most two on-demand panes;
- arbitrary binary-tree tiling.

**Proposed:** ship one focused session and the picker first. Preserve a pane
abstraction internally, but do not expose splits until side-by-side sessions
prove useful in dogfooding. If they do, add a maximum of two panes; do not build
arbitrary tiling pre-emptively.

### 2. Background-session visibility

**Proposed:** no persistent idle counts. Show `2 running`, `1 approval`, or a
similar summary only while actionable. `/sessions` always shows complete state,
workspace, recency, and title. Selecting a session attaches immediately.

Question: should an approval in another session automatically open a prompt,
or only raise a status-bar notification until the user switches?

### 3. Session switching

**Proposed:** `/sessions` for arbitrary selection; J/K in normal mode cycles a
most-recently-used list. Switching preserves each session's scroll position,
selection, and input draft locally and survives `/reboot --build` best-effort.

### 4. Vim/normal-mode depth

**Proposed M4 boundary:** keep normal mode focused on session navigation,
scrolling, pane focus if panes land, and visual selection. Do not build a second
text editor; composer editing remains readline-style insert mode.

Question: are visual select/yank and session navigation enough, or are motions
such as word/block jumps important to the desired workflow?

### 5. Copy and registers

**Proposed:** finish `!c` first because it exposes already-stored full tool
results. Add daemon-side `!y`/`!p` only if cross-session text transfer is
actually common after the session picker lands.

### 6. Image paste

Question: is clipboard/path image input part of core M4, or should it be a
separate M4.x slice after session navigation? It requires attachment protocol,
blob lifecycle, provider multipart mapping, and a placeholder/thumbnail UI.

### 7. Remote mode

Question: is attaching to a work machine from a laptop a near-term real use
case? If not, move remote attach out of M4. It is largely independent and
should not delay local session UX.

## Proposed M4 build slices

1. **M4a — sessions without chrome:** session-status watch protocol,
   `/sessions` picker, MRU J/K switching, actionable status summary, and durable
   per-session client view state.
2. **M4b — focused terminal ergonomics:** turn-aware virtual scrollback,
   visual selection/yank, `!c`, and only the interaction work approved above.
3. **M4c — rich input:** image/path attachments and provider vision mapping,
   if retained in M4.
4. **M4d — remote:** SSH protocol transport, named remotes, and version-skew
   recovery, only if retained in M4.

The M4 exit criterion must be rewritten after the split, image, and remote
questions are answered. It should describe a workflow Marlin actually
replaces, not require features kept only because an old wireframe contained
them.

## Deferred M4.5 — workspace safety

This milestone is intentionally parked until M4 multi-session use tells us
where collisions, recovery, and latency hurt in practice. No M4 implementation
depends on it.

Two tentative decisions are worth retaining for that later review:

1. **Workspace identity:** exactly the canonicalized session launch directory;
   never silently expand to a parent Git root. No explicit override initially.
2. **Snapshot direction:** COW-first per-file clones (`clonefile` on APFS,
   `FICLONE` on supporting Linux filesystems), complete regular-file coverage
   including ignored files, a metadata manifest, and an honest portable copy
   fallback. Never use hard links for snapshots.

The following questions are deliberately unresolved until M4.5 planning:

- when full snapshots and drift checks run;
- how arbitrary shell writes and external writers are attributed;
- whether `/undo` defaults to the latest workspace mutation or a picker;
- how preview/CAS confirmation works;
- how long a write lease is held;
- retention, GC, fallback latency, and high-inode-tree behavior.

A likely implementation shape, subject to that later review, is configuration
and contracts → snapshot engine → turn integration and drift → write leases →
undo → opt-in rollout. `[workspace] enabled = false` remains the default until
the complete safety matrix passes.
