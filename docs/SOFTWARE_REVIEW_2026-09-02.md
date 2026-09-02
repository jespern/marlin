# Software review — 2026-09-02

Point-in-time review of Marlin at `613429d` (three commits past `v0.1.2`),
read against the author's own thesis: *a (very) fast, (very) ergonomic
multi-agent harness for people fluent in vim and unix — it does everything
you need and stays out of your way.* Method: four independent read-only
audits (TUI/vim fidelity, daemon/safety, performance evidence, test/CI/docs
hygiene), with every top-severity finding re-verified at the cited line.

The previous review (`SOFTWARE_REVIEW_2026-08-26.md`) is the baseline. Its
entire "ship, don't expand" list is closed. This review is about what
replaced those problems.

---

## Verdict

The thesis is structurally true. Daemon-native structured sessions, one
static binary, a TUI that is honestly just a client, two vendor agents
hosted as *guests* behind a wall that now exists in the type system, a
permission bridge that fails closed, and Landlock that actually shipped.
`marlin` is a real product with an installer, a tap, and a week of dogfood
commits behind it. That is not where it was on August 26.

The gap has moved. It is now between three of the four adjectives and the
evidence for them:

- **"vim-native"** — the vim *grammar* is excellent (operators, text objects,
  `f`/`t`, counts inside operators, undo units). The vim *reflexes* are wrong
  in four places a fluent user hits within a minute: `Esc` in normal mode
  enters insert, `Ctrl+D` while reading archives the session, counts leak
  across commands, and `!ls` is an unknown command.
- **"stays out of the way"** — notices never expire, the plan-proposal bar is
  a hard modal that swallows every key including tab switches, `?` help
  silently truncates on a 24-row terminal, and `/help` prints 528 bytes into
  a one-row status bar. Meanwhile nothing signals out of band: a background
  approval is a color change you must be looking at.
- **"(very) fast"** — asserted in README, the site, and MARLIN.md; measured
  nowhere. Parts are fast by construction (a genuinely good layout-cache
  design, bounded replay, three layers of flush coalescing). Parts are
  structurally slow: daemon cold start blocks `listen()` behind serial MCP
  discovery with 15 s timeouts while the client gives up at 5 s.

Plus a short list of real correctness bugs in the daemon, the largest of
which undoes the redaction invoice you just paid.

---

## What got better, specifically

Credit first, because it is substantial.

**The wall is built where it matters.** `Backend = union(enum){ native,
guest }` (`provider.zig:17`) — guest is no longer a fake dialect.
`/compact`, `/sandbox`, `/network` refuse at the protocol on guest sessions
(`daemon.zig:1740, :1324, :1371`); native→guest `/model` runs the visible
handover turn (`:1263-1281`). The Claude Code bridge is fail-closed at every
seam (`cc_approve.zig:109, :192`), and the read-only deny mode for guest
*children* (`daemon.zig:1686-1694`) is checked before approval mode, so
neither yolo nor `/permissions full` can hand a reviewer write access. That
is the exact primitive the last review said councils were blocked on.

**Every safety invoice is paid.** Capture-time redaction on tool results
(`permissions.zig:331`, applied at `loop.zig:1056/:1620/:1915`).
Protected-path refusals in read, write, edit, grep, and the grep result
filter (`files.zig:59, :162, :273`; `search.zig:51, :279, :473`),
symlink-aware. Landlock (`landlock.zig`, 313 lines) is a real ruleset with a
computed cover-set planner, canary-gated exactly like Seatbelt — the item the
last review said to schedule or drop, done properly. The `session.zig` ghost
is gone; `clients_mutex` is a field; `marlin gc` speaks the protocol.

**Rendering is engineered, not hoped.** `LayoutCache` / `TailLayoutCache` /
`StreamLayoutCache` (`layout.zig:46-225`): completed turns bake once, the
stream cache is append-only and re-wraps only the unfinished row, and
`layout_epoch` bumps on structural change, never per delta. Replay is
bounded on every path (`tail_limit=256`, 512-block / 16 MiB pages, tail
queries riding `UNIQUE(session_id, seq)`). Flushes coalesce at three layers
— 48-byte provider deltas, burst-drained socket writes, `tryEvent` frame
drain — each with a comment saying why.

**Multiplexer judgment is right.** `y`/`n` on an idle session jumps to the
session awaiting approval and *refuses to answer blind* (`tui.zig:8183`).
Approvals parked on background sessions are cached and re-armed on switch.
The FULL ACCESS badge is re-read from server truth per session so it cannot
follow you across tabs. The welcome card appears only on a truly empty idle
session and self-destructs. Voice is invisible until asked for.

**Release automation is above the solo-project bar.** Four-target matrix,
self-verified artifacts, per-asset checksums, idempotent publish, a
post-publish curl-installer smoke, Homebrew push with SHA assertions.

---

## The actual problems now

### 1. Vim reflexes that fire wrong

Grammar is the hard part and it is done well (`operatorKey`
`tui.zig:3304-3370`; `d2w`, `ct)`, `di"`, `;`/`,` direction inversion,
insert-session undo units). Reflexes are the cheap part and they are what a
vim user's hands do without thinking:

- **`Esc` in normal mode enters insert** (`tui.zig:8325`, OR'd with `i`).
  Double-Esc — the single most reflexive vim gesture — puts the cursor live;
  every following `gg`/`dd` gets typed into the prompt. `Esc` in normal
  should be a no-op that also clears pending count/operator/find.
- **`Ctrl+D` archives the session you are reading.** `isArchiveCurrentKey`
  (`:7665`) fires above the mode switch whenever the composer is empty —
  the normal state while reading — and `archiveCurrentSession` (`:4642`)
  archives any *idle* session with no confirmation. The vim/less page-down
  at `:8357` is unreachable in exactly the situation it exists for. Keep
  `Ctrl+W` (which has no reading reflex) or require the session itself to be
  empty; give `Ctrl+D` back to scrolling.
- **Counts leak.** `takeCount` is consumed by `h l w e b x ~ ;` but not by
  `j k Ctrl+D Ctrl+U G gg p o O` (`:3209`, `:8362`). `5G` then `x` deletes
  five characters. `Esc` does not clear `pending_count`.
- **`!ls` is "unknown command".** `runCommand` tokenizes on space
  (`:2304`); only `! ls` works. Every shell and vim accept `!cmd`.
- **You cannot send a message that starts with `/` or `!`** (`:2212`, after
  `trim` at `:2200`). No escape hatch. `/usr/local/lib/foo.so is missing`
  → "unknown command". For a unix audience this fires constantly; a leading
  space or `//` should mean "literal".
- **`Ctrl+P`/`Ctrl+N` are half a pair** (`:7653` vs `:7657`); `Ctrl+N`
  creates a session (`:8137`). **`Ctrl+U/W/K` destroy text without an undo
  push** (`:7676`) and there is no kill ring, so `Esc u` after a wiped draft
  says "already at oldest change".
- **The prompt shows `:` in normal mode** (`:6020`) and nothing handles `:`.
  Commands live behind `/` in insert. Cheapest honest fix: `:` in normal
  opens the command menu. **`q` quits** (`:8342`) with running background
  sessions and no word about it; in vim it starts a macro.
- **`/` is not vim search** (`:4054`): a daemon round trip to the durable
  index, block-granular hits, highlights the last line of the block, `n`/`N`
  may silently switch you to another session (`:1309`). Fine as `/search`;
  wrong as `/`.

Also: `gt` walks MRU including children while `<`/`>` and `⌥N` walk
chronological roots (`:1359` vs `:1374`) — two different N's on one screen —
and tabs show no numbers although `⌥N` is the primary jump (`:5740`).

### 2. It does not yet stay out of the way

- **Notices never expire.** `setNotice` (`tui.zig:879`) is called 253 times
  and only ever overwritten; five explicit clears in the whole file. "session
  → 3f2a" sits on the status bar until something replaces it. The `.tick`
  handler already runs; a TTL is five lines.
- **The plan-proposal bar is a modal trap** (`:8118-8133`). When a proposal is
  ready and the session idle, the handler returns unconditionally;
  `planProposalAction` maps `Enter`/`e`/`Esc`/`q` and swallows everything
  else — including `Ctrl+N`, `Ctrl+D`, `⌥1–9`, `gt`. `Esc` means *stay*, so
  the one key that should release you does nothing.
- **`?` help truncates without saying so** (`:5601`): 36 rows, 18 visible at
  24 lines, and everything from the operators row onward — the entire GLOBAL
  section — is invisible with no "… N more". `/help` is unreadable by
  construction (`:2647` into a `.wrap = .none` row at `:6424`).
- **Nothing signals out of band.** No BEL, no OSC 9/777, no title update
  anywhere in `src/client/`. For a harness whose premise is N agents working
  while you look elsewhere, a background approval being only a tab-color
  change is the biggest single gap in the multiplexer story. The transition
  is already detected (`:1918`); one `\x07` when a non-focused session
  enters `awaiting_approval` changes how the product feels.

### 3. Correctness bugs to fix this week

1. **Tool-call arguments are persisted unredacted.** `loop.zig:939` appends
   `args_json` raw; `redactSecrets` runs only on results (`:1056`). Same at
   `:1897` for Codex items. A model that writes `curl -H "Authorization:
   Bearer sk-…"` puts the literal secret into an immutable block, the FTS
   index (`store.zig:1491`), every later context assembly, and — because
   OTLP tool spans read from blocks — the trace exporter. Three lines,
   symmetrical with `:1056`; it closes the redaction story for real.
2. **`Store.gc` runs a transaction without the connection mutex.**
   `store.zig:2241` `BEGIN IMMEDIATE` with no `sqlite3_db_mutex`, while
   `appendBlock` holds it around its own transaction (`:1471-1499`, with the
   comment explaining why). `marlin gc` during a streaming turn: the turn's
   `appendBlock` gets "cannot start a transaction within a transaction" and
   the block is lost; non-transactional status/usage writes in the window
   join gc's transaction and die with its `ROLLBACK`. Take the mutex or gate
   `.gc` on `anySessionBusy()` like every other maintenance arm.
3. **The `/reboot` path skips the shutdown sequence it claims to share.**
   `Event.shutdown` and protocol `.shutdown` both `events.close` before
   `running = false` — the fix from the last review, with a comment saying
   "same sequence". `maybeFinishReboot` (`daemon.zig:3737`) flips `running`
   with no close, so `shutdownCleanup` drains a still-open queue (`:3925`)
   while client readers are alive until `:3951`. Same defect, in `!rb`, the
   daily gesture. One line — and reorder cleanup to cancel→join→drain so it
   is unconditionally correct.
4. **The Claude Code round loop is unbounded** (`loop.zig:1705`, `while
   (true)` with no `max_rounds` check; `--max-turns` bounds the subprocess,
   not the marlin loop) and the init-retry at `:1713` can double a 60-minute
   watcher deadline.
5. **Guest children fail open when `marlin_exe` is unresolvable**
   (`loop.zig:1470` → `claude_code.zig:109`, `acceptEdits` with no bridge).
   A read-only reviewer child becomes auto-accept-edits with no marlin
   involvement. A read-only child should refuse to start rather than
   degrade.
6. **`catch @panic("oom")` while formatting error strings** on turn threads
   (`tools/registry.zig:215-253`, `exec_tool.zig:43-81`, `loop.zig:2685`,
   `daemon.zig:1002`). An OOM there kills every session in the multiplexer,
   in the one place where a static string is the correct fallback.

### 4. "Fast" is a claim without a number

There is no benchmark, timer, or perf assertion in the tree except three
`EXPLAIN QUERY PLAN` tests (`store.zig:3023-3064`). `README.md:3,146`,
`site/index.html:355`, and `MARLIN.md:26` ("Debug is 5-10x slower") all
assert speed; nothing measures it. The provider telemetry
(`telemetry_rounds`: `context_load_ms`, `store_wait_ms`, `assemble_ms`)
records marlin's own overhead per round and nothing reads it.

Where it is fast by construction: the language and binary, the layout
caches, bounded replay, coalesced flushes, incremental session-catalog
deltas, first frame before replay.

Where it is structurally slow, unmeasured:

- **Daemon cold start blocks `listen()`** (`daemon.zig:501`) behind
  `extensions.Runtime.init` (`:409`): a recursive read of every skill file,
  then **serial** MCP discovery with 15 s per-request timeouts and a
  kill-respawn legacy fallback (`tools/mcp.zig:14, :123-143`) — up to ~45 s
  per server — plus an unconditional `sandbox-exec` canary (`:431`). The
  client polls 50 ms × 100 and gives up at 5 s (`attach.zig:322`). One slow
  `npx` MCP server and the first `marlin` of the day says "cannot reach
  daemon"; the second works. Discovery belongs after `listen()`, parallel,
  or both.
- **Every frame copies the entire baked transcript** into the frame arena
  (`layout.zig:1489`) and slices `view_h` rows out; a 5 000-line session is
  ~1 MB of memcpy per keystroke and per 90 ms tick. The cache saves the
  wrapping, not the copy.
- **Tail relayout is O(blocks-per-turn²)** (`layout.zig:1492-1509`): every
  new block inside a long agentic turn re-lays out the whole turn.
- **The shipped artifact is ReleaseSafe** (`release.yml:42`, `ci.yml:39`)
  while `MARLIN.md` says the daily driver is ReleaseFast. Nobody knows the
  delta.

Three measurements that turn the adjective into evidence, cheapest first:
(a) an e2e scenario timing `marlin daemon` spawn → first `hello_ok` and
attach → first `replay_done` with 0/1/5 MCP servers — ~30 lines on the
existing runner, and it makes the 5 s cliff a number; (b) a `layoutLines`
microbenchmark on the synthetic-App fixture at `tui.zig:11150` at 100/1k/10k
blocks; (c) p50/p95 of marlin overhead from the telemetry you already
collect, printed in `/diagnostics` next to provider TTFT.

### 5. The wall is a paragraph, not a boundary

- **36% of `loop.zig` is guest** (`:1379-2396` plus tests): `runCodexTurn`
  (366 lines) and `runClaudeCodeTurn`+`ccInvoke` (350) share nothing with
  each other and only `Appender`, redaction, and the steer poll with the
  native loop (~550 lines). The two guest runtimes are larger than the loop
  they live next to, in a file whose doc-comment says it is the native turn.
- **`codexToolName` (`loop.zig:1839-1858`) is the guest-tool catalogue
  ARCHITECTURE.md forbids** (`:123-125`): nine Codex item types renamed into
  Claude Code's tool vocabulary in the daemon, with `codexToolBody`
  synthesizing diff bodies, so the TUI's semantic renderer lights up. It will
  grow with every Codex item type.
- **`handleClientMsg` is a 1,146-line, 42-arm switch** (`daemon.zig:1049`).
  Five mechanical extractions (setup/otel, extensions, session config,
  guest, subscribe) leave a ~250-line dispatcher; nothing moves but text.
- **`tui.zig` is a 12k-line god object** — `App` has ~177 methods and ~150
  fields — with two section banners. The seams already exist: commands
  (~700 lines), keys, the vim engine (320 self-contained lines), setup
  wizard, picker, plan panel, matrix animation. ~2,500 lines out with no
  new abstractions. The event switch is copy-pasted between the outer loop
  and the drain loop (`:7242-7302`); `planTableWidths` exists byte-identical
  in `tui.zig:5862` and `layout.zig:885`, and `formatPlanDuration` diverges
  by one line between them (zero-duration renders `<1s` in one place and
  blank in the other); the `top` view is implemented twice with different
  bindings (`top.zig` has `A`/unarchive, the embedded one does not).
- `topSelectedIndex` (`:3578-3585`) mixes tree-ordered and unordered index
  spaces; currently repaired by `normalizeTopSelection`, one missed call
  from `x` killing a different session than the highlighted one. Picker
  Backspace pops a byte, not a codepoint (`:8096`); type `é`, delete, and a
  lone `0xC3` is matched and printed.

### 6. Tests guard the wrong default; CI has holes

- **Every e2e scenario pins `MARLIN_PERMISSIONS=0`** (`e2e_runner.zig:308`)
  and none sets it back. The default-on permissions system — a 300-line
  contract doc — has zero full-binary coverage.
- **The nightly live smoke has never run.** `ci.yml:47` gates on
  `schedule`/`workflow_dispatch`; `ci.yml:4-7` declares neither. TESTING.md
  says it runs nightly. Provider drift is undetected.
- **`release.yml` publishes without running a single test.** A tag on a red
  commit ships to Homebrew.
- **`zig build converge`** — "the load-bearing test" per TESTING.md — is in
  no workflow.
- **The seven "environment-dependent" failures are a fixable root cause,
  not weather:** three macOS Seatbelt probes fail when nested inside a
  sandboxed marlin bash (self-hosting), and four process/timing probes
  (`process_io.zig:363, :405, :461`, `bash.zig:211`) use `std.testing.tmpDir`
  with hardcoded relative `.zig-cache/tmp` paths — violating the house rule
  in `temp_dir.zig:3-5` that every other test follows. The `Makefile:16-18`
  TMPDIR workaround is fossil evidence.
- The fake provider **discards request headers** (`fake_provider_main.zig:206`)
  so no scenario can assert `Authorization`; `Check` parses with
  `ignore_unknown_fields` (`e2e_runner.zig:232`) so a typo'd assertion
  passes vacuously; `web.zig` (488 lines, a tailnet-reachable listener),
  `pipe.zig`, the TUI reconnect path, Landlock at runtime, and every guest
  end-to-end are dogfood-only.

### 7. Docs drift

- `README.md:250` still says "token-gated" — the token was removed on
  purpose; the tailnet is the boundary.
- `PROTOCOL.md` omits five client messages (`blob_get`, `cc_approval`, `gc`,
  `session_rename`, `session_set_approvals`) of 44.
- `MILESTONES.md` names a `fake_provider.zig` that does not exist, omits 26
  files including `codex.zig` (the headline of v0.1.2), lists shipped
  councils under "Next", and credits `approval.zig` with capability grants
  that `approval.zig:14` marks TODO.
- `PERMISSIONS.md:5` says protected-read refusals landed; `:41` lists them as
  Next. `fixtures/README` describes six fixture categories and an `ndjson/`
  tree that do not exist. ARCHITECTURE.md §1 describes ~4 thread kinds; the
  daemon has ~14 and `daemon.zig:4-36` is the accurate copy — point at it.
- README's architecture diagram predates Codex.

---

## What to do next

**This week, in order — small, high-leverage, mostly one-liners:**

1. Redact `tool_call` args (`loop.zig:939`, `:1897`).
2. `Store.gc`: hold the db mutex or busy-gate it.
3. `maybeFinishReboot`: `events.close`; reorder `shutdownCleanup` to
   cancel→join→drain.
4. Vim reflexes: `Esc` in normal is a no-op that clears pending state;
   counts consumed everywhere or cleared on `Esc`; `!cmd` without the space;
   a literal escape for leading `/`/`!`; give `Ctrl+D` back to scrolling
   (keep `Ctrl+W` for archive, or require the *session* to be empty).
5. Notice TTL; plan bar lets `Esc` dismiss and global keys through; `?` help
   scrolls or says "… N more"; `/help` opens the catalog panel.
6. BEL on a non-focused `awaiting_approval`.
7. CI: enable `schedule`+`workflow_dispatch`; make `release.yml` run the
   suite; flip one scenario to `MARLIN_PERMISSIONS=1`; add `converge` to the
   Linux leg; convert the four `tmpDir` tests to `temp_dir`.

**Then, before the next surface opens:**

8. Move MCP discovery behind `listen()` (and parallelize it). This is the
   one structural startup fix; everything else about "fast" is measurement.
9. The three measurements in §4, as e2e gates or `/diagnostics` lines.
10. `daemon/guest/{claude_code,codex}_turn.zig`; split `handleClientMsg`;
    extract `tui.zig`'s existing seams. Delete `codexToolName` or move it to
    the client where ARCHITECTURE.md says semantic rendering lives.
11. A docs pass on §7. Cheap, and every item is a lie someone will act on.

**Do not, until the above is boring:**

- An ex command line, registers, marks, macros. Fix the reflexes; do not
  build the rest of vim.
- A third guest. Two runtimes already outweigh the native loop; the wall has
  to be a file boundary first.
- Performance work beyond measurement. There is no number to improve yet.
- Splits, VTE, more chrome. The tab strip just became optional; that is the
  right direction.

---

## Positioning

Against Claude Code and Codex as *apps*: Marlin now hosts both as guests and
adds what neither has — durable sessions, structured approvals from a phone,
one room for the whole model fleet, `!rb` self-hosting, remote attach over
plain ssh with state-level reconnect. That is a sharp product, and the
README finally says it.

Against Claude Code as a *habit*: what will decide whether a fluent vim/unix
user stays is not another feature. It is whether their hands stop being
surprised — `Esc`, `Ctrl+D`, `!ls`, a leading `/` — and whether the tool is
quiet when they are not looking at it and loud exactly once when it needs
them. Every item on that list is under fifty lines. The architecture is
done; the manners are what is left.

---

## Follow-up (same day)

Landed on top of `613429d` in response to this review, in order:

- `57eb0fe` Close the daemon correctness gaps from the 2026-09-02 review
- `b2b1188` Fix the vim reflexes the 2026-09-02 review found firing wrong
- `45ffe9e` Teach the TUI manners: notices expire, offers are not modals, help fits, the bell rings once
- `0054b4f` Make CI guard what ships: nightly smoke, tested releases, permissions on, convergence
- `6c80ed5` Remove the cold-start cliff: readiness handshake and parallel MCP discovery
- `572062c` Make the guest wall a file boundary; dedupe the TUI's twins
- (this commit) docs pass: PROTOCOL rows for every ClientMsg, MILESTONES
  layout and status, PERMISSIONS contradiction, fixtures/README, TESTING,
  README diagram/token wording, ARCHITECTURE thread model and guest files.

Still open from §"What to do next": the `layoutLines` frame microbenchmark
and the O(total-lines) per-frame copy (measure first), `handleClientMsg`
and the remaining `tui.zig` seam extractions, `codexToolName` moving to the
client, the OOM-panic fallbacks (needs an ownership flag on `ExecOut`),
telemetry-table retention in `gc`, and the fake provider keeping request
headers. Each is scoped in its section above.
