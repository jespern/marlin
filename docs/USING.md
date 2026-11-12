# Using Marlin

Day-to-day details of setup, sessions, and the status line. The
[README](../README.md) has the overview.

## First run

Run `marlin` and the first screen asks where inference should run. Choose a
native provider such as OpenRouter, Vercel AI Gateway, Anthropic, LiteLLM, or
another OpenAI-compatible endpoint, or host an installed Codex or Claude Code
agent as a guest. Native API keys are entered in a masked prompt and saved by
the daemon in `~/.config/marlin/credentials` with mode 0600. Guest choices use
the vendor CLI's existing login and tell you the exact login command when the
daemon host is not authenticated.

The setup is daemon-owned, so it works the same over `marlin --remote`: keys,
config, guest binaries, and login state are checked on the machine that will
run the turn. `/setup` reopens the flow later. `marlin run` never prompts; on a
fresh unconfigured daemon it exits with an instruction to complete interactive
setup or pass an explicit model whose credentials already exist on that host.

## Sessions

Inside the TUI, `/new` starts a session, `/model` selects its agent/model,
and `/reset` archives idle sessions and opens a fresh session with the startup
screen. Running sessions, pending approvals, and their parents stay open.
Archived transcripts remain searchable.
After a completed turn sits idle for three minutes, a short recap is added to
the session scrollback. Escape keeps its normal Vim behavior. Recaps summarize the task, outcome, and
unfinished work without starting another agent turn. They use `model_compaction`
when configured, otherwise the session's native model (a configured native
default/favorite for guest sessions). If that model is unavailable, the recap
uses an excerpt labeled “Last exchange”.
`/cwd <path>` (or `/cd <path>`) changes its working directory while idle. Tab completes paths;
Up/Down select directory matches, Tab inserts the selection, and Enter uses it.
Without a selection, Enter uses the typed path. `Ctrl+S` opens the
session switcher, and `/detach` closes the client while work
continues. `marlin --remote <host>` attaches through SSH, and `marlin discover` lists
the marlins on your LAN over Bonjour with the `--remote` target for each.

## Git status line

The TUI status line shows the Git branch beside the cwd, with `↑`/`↓` commit
counts against its origin upstream (or `origin/<branch>`). It uses local remote
refs without fetching and checks metadata in the background about every five
seconds. Repository and branch detection read files directly; Git only
recomputes commit counts when relevant metadata changes. Nothing Git-related
appears outside repositories, and counts are omitted when the origin branch
is unavailable.

## What else is there

- **Durable, searchable work.** Messages, tool calls, results, plans, and
  approvals are structured blocks in SQLite. Compaction changes what the
  model sees while preserving the original transcript and full tool outputs.
  `/search <query>` searches across sessions; `!c` copies the last reply's text and `!co` the last full tool output.
- **A clear view of ongoing work.** Root tabs roll up child activity and
  approvals. The activity row distinguishes model wait, streaming, tools,
  delegation, and compaction. `/diagnostics` separates provider latency,
  time to first token, tool time, and failures.
- **Approvals you can return to.** Permission requests are protocol events.
  Attach from another terminal or use the optional phone client to answer a
  parked request. Native and guest permissions have different owners; the
  interface reports that distinction.
- **Planning and delegation.** Shift+Tab enters Plan mode. Native execution
  plans survive compaction and restart; `task` and `task_batch` create durable,
  attachable children for focused read-only work. Configured review councils
  combine model perspectives through the same delegation mechanism.
- **Terminal ergonomics.** Modal editing, `Ctrl+R` input history, transcript
  search, image attachments, and shell escapes keep routine work close.
  `!<command>` runs in the session workspace; bare `!` opens a local shell.
  Direct remote attachments refuse shell escapes; use Marlin inside SSH or
  mosh when the terminal and workspace live on another host.
  See [terminal effects](TERMINAL_EFFECTS.md) for the optional playful bits.
- **Small deployment footprint.** One native binary, daemon-owned setup and
  credentials, and SSH for remote transport. MCP servers, custom tools, and
  hooks extend it at process boundaries.
