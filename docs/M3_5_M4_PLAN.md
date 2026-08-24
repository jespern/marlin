# M3.5 → M4 planning ledger

Status: **planning only**. Do not begin implementation until the product
decisions below have been reviewed. This document turns the broad milestone
descriptions into an execution contract; `MILESTONES.md` remains the roadmap
and `WORKSPACE.md` remains the workspace-semantics source of truth.

## Current position

Treat M3 as closed for feature sequencing. Context management, compaction,
usage accounting, and self-hosting reboot exist and pass the automated gates;
normal dogfooding can continue to produce M3 polish without holding M3.5.

M3.5 is the next correctness milestone. M4 may pull forward presentation work,
but not multi-session behavior that depends on unfinished workspace states.

## Decisions already made

1. **No persistent sidebar.** Session navigation is on demand through a fuzzy
   `/sessions` picker. Normal-mode J/K switches recent sessions. Actionable
   background state appears temporarily in the status bar. Split panes, if we
   keep them, identify their session with a compact pane label.
2. **Workspace safety precedes multi-session convenience.** The daemon must
   correctly represent `waiting_workspace`, drift, snapshots, and undo before
   M4 builds richer views over session state.
3. **Feature flags preserve current behavior.** `[workspace] enabled = false`
   remains the default until the M3.5 exit matrix passes. With the flag off,
   today's approval and tool semantics must be byte-for-byte unchanged.
4. **Blocks remain truth.** Workspace events that explain behavior survive
   reconnect and reboot; transient UI state is derived from them and protocol
   status, not held only in a client.

## Prerequisite engineering work

These are enabling tasks rather than unresolved product choices:

- Land a real `~/.config/marlin/config.toml` loader. The workspace flag cannot
  currently be enabled from configuration. Use a pinned Zig 0.16-compatible
  TOML parser in strict mode so misspelled safety settings fail loudly.
- Add `waiting_workspace` to the session state contract before the session
  picker or status summary consumes it.
- Give render blocks their durable `seq` and `turn_id` before M4 attempts
  turn-level collapse, lazy scrollback, or per-pane caches.
- Split the TUI by responsibility only after those state contracts settle:
  session view/Markdown, composer, selection, session picker, and pane layout.
  The extraction must be behavior-neutral and protected by layout tests.

## M3.5 decisions to settle

### 1. Workspace identity

**Decided:** the canonicalized session `cwd` is the workspace root. Do not
silently walk upward to a Git root: Marlin supports non-repositories, and a
user who starts it in a subdirectory should not accidentally grant or snapshot
the parent tree.

The launch directory is the whole M3.5 boundary. There is no explicit root
override in this milestone; add one later only in response to a concrete need.

### 2. Snapshot coverage

**Decided:** use copy-on-write file clones as the primary snapshot engine:
`clonefile` on APFS and `FICLONE` on supporting Linux filesystems. A snapshot
walks the workspace once, records a manifest, and clones every regular file,
including ignored files. The live tree and snapshot share physical blocks
until either copy changes.

Record directories, permissions, symlink targets, and deletions in the
manifest. Exclude only `.git`, Marlin's own state, and special files such as
sockets and devices. Ordinary hard links are forbidden because an in-place
write would mutate the snapshot too.

Cloning requires source and destination on the same supporting filesystem.
When that fast path is unavailable, fall back to real/content-addressed copies
with the slower mode made visible; never silently weaken coverage. The first
snapshot remains O(number of files), so measure pathological high-inode trees
during rollout and add explicit exclusions only in response to real data.

### 3. Snapshot and drift boundaries

**Proposed:** immediately before a turn's first approved mutation, acquire the
lease, compare the working tree with the last observed tree, report external
drift, and capture the undo baseline. Refresh the observed tree after each
successful mutation and at turn completion. This distinguishes external edits
from Marlin's own earlier edits in the same turn.

Question: is per-mutation drift detection worth the extra tree scan, or should
M3.5 detect only at turn boundaries?

### 4. What `/undo` means in a shared workspace

**Proposed:** undo is workspace-global, not session-local. It targets the most
recent Marlin-authored mutating turn in that workspace and displays its owning
session/title. A session-local stack can otherwise roll backward through work
another Marlin session produced later.

Question: should `/undo` default to that latest workspace mutation, or require
the user to select a turn every time?

### 5. Undo application safety

**Proposed:** `/undo` first returns a diff preview and an expected-current-tree
token. Applying it requires explicit confirmation and compare-and-swap: if the
tree changed after preview, refuse and regenerate the preview. Undo itself is
recorded as a new workspace event; history is never erased.

### 6. Lease behavior

**Proposed:** FIFO per canonical workspace. Acquire immediately before the
first mutation and hold until the turn ends. Never hold a lease while waiting
for an approval. Read-only turns continue. Waiting turns remain steerable and
interruptible, and daemon exit releases every lease.

Question: after a long provider round, should a lease be released between tool
rounds, or is turn-level consistency worth temporarily queueing other writers?

## Proposed M3.5 build slices

1. **Configuration and contracts:** TOML loading, feature flag, typed workspace
   events, `waiting_workspace`, protocol and persistence tests.
2. **Shadow engine:** canonical workspace identity, per-file COW clone feature
   detection, manifest and metadata capture, portable copy fallback, and
   tree diff/restore primitives.
3. **Turn integration:** lazy pre-mutation snapshots, observed-tree updates,
   external drift notes, flag-off equivalence tests.
4. **Write leases:** FIFO coordinator, waiting/resume/interrupt lifecycle,
   two-session contention tests and crash/reboot release tests.
5. **Undo:** preview protocol, TUI confirmation card, CAS application, undo of
   write/edit/bash changes, and external-change refusal tests.
6. **Rollout:** opt-in dogfood, disk/latency measurements on large trees, then
   decide whether the default remains off beyond M3.5.

## M4 decisions to settle

### 1. Do we actually want splits?

No sidebar does not answer this. The useful choices are:

- one focused session plus `/sessions` only;
- at most two on-demand panes;
- arbitrary binary-tree tiling.

**Proposed:** start with one focused session and the picker, then add a maximum
of two panes only if side-by-side sessions prove useful in dogfooding. Do not
build arbitrary tiling pre-emptively.

### 2. Background-session visibility

**Proposed:** no persistent idle counts. Show `2 running`, `1 approval`, or
`1 workspace wait` only while actionable. `/sessions` always shows the complete
state, workspace, recency, and title. Selecting a session attaches immediately.

Question: should an approval in another session automatically open a prompt,
or only raise a status-bar notification until the user switches?

### 3. Session switching

**Proposed:** `/sessions` for arbitrary selection; J/K in normal mode cycles a
most-recently-used list. Switching preserves each session's scroll position,
selection, and input draft locally and survives `/reboot --build` best-effort.

### 4. Vim/normal-mode depth

**Proposed M4 boundary:** keep normal mode focused on session navigation,
scrolling, pane focus, and visual selection. Do not build a second text editor;
composer editing remains readline-style insert mode.

Question: are visual select/yank and pane navigation enough, or are motions
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
   `/sessions` picker, MRU J/K switching, actionable status summary, durable
   per-session client view state.
2. **M4b — focused terminal ergonomics:** turn-aware virtual scrollback,
   visual selection/yank, `!c`, and (only if approved above) two-pane layout.
3. **M4c — rich input:** image/path attachments and provider vision mapping.
4. **M4d — remote:** SSH protocol transport, named remotes, version-skew
   recovery. Promote or defer this slice based on an actual use case.

The M4 exit criterion should be rewritten after the split, image, and remote
questions are answered. It must describe a workflow Marlin actually replaces,
not require features kept only because an old wireframe contained them.
