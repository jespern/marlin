# Observability

Marlin records operational evidence locally for every new agent turn. SQLite is
the durable source for `/diagnostics`; exporting it is optional and never sits
on the turn's critical path. GenAI spans follow the OpenTelemetry
[generative client AI span conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-spans.md).
Mirador-specific attributes and endpoints follow its live
[OTLP contract](https://otel.mirador.org/llms.txt).

## Local diagnostics

In the TUI, `/diagnostics` appends a local scrollback report with recent
provider/TTFT percentiles, failure rate, OTLP outbox health, and the latest
provider/tool waterfall. The report is display-only and is not added to the
durable conversation. The headless form prints the same operational detail:

```sh
marlin diagnostics                 # newest session
marlin diagnostics 63df            # unique session prefix
marlin diagnostics 63df --json     # automation / deeper analysis
```

The sample is bounded to 50 turns by default. Marlin stores timestamps,
outcomes, model/provider/generation identifiers, token counts, response byte
counts, and tool names/statuses. It does not duplicate prompts, completions,
tool arguments, or tool output into telemetry.

## OTLP/HTTP export (Mirador included)

Export uses the standard OpenTelemetry variables and is off unless an endpoint
is present:

From the TUI, configure any OTLP/HTTP collector without restarting:

```text
/otel set https://otel.mirador.org
OTLP headers ❯ Authorization=Bearer mir_srv_REDACTED
```

The second line is a masked input prompt, not a slash command. It accepts the
standard comma-separated `name=value` header form. The endpoint may be any
OTLP/HTTP collector; Mirador is only an example.

`/otel` and `/otel status` report whether export is active. `/otel off` disables
it. Configuration applies to the attached daemon, including a daemon reached
through `--remote`, and atomically replaces its exporter. Values are process-local,
not persisted, not added to editor history or the transcript, and headers are
never echoed back.

This control requires a daemon build that supports it; upgrading an older running
daemon requires one final `!rb`. Future endpoint or key changes do not. A later
daemon restart returns to its startup environment, so keep the standard OTEL
variables in the daemon's normal launch environment if export should remain on.

`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` may instead name the full traces URL. When
only the base endpoint is set, Marlin appends `/v1/traces`. Header names and
values use the standard comma-separated, percent-encoded form.

Completed turns enter a durable SQLite outbox. One background worker owns a
persistent HTTP pool, sends OTLP JSON, and retries failures after 30 seconds.
Exporter DNS, TLS, HTTP, or collector failures cannot fail or delay an agent
turn; pending count and the last export error appear in diagnostics. Shutdown
cancels an in-flight export before closing SQLite.

Marlin exports one INTERNAL `invoke_agent marlin` root per turn
(`gen_ai.operation.name=invoke_agent`, `gen_ai.agent.name=marlin`) carrying
turn-level rollups: `gen_ai.usage.input_tokens`/`output_tokens`, round and
tool-call counts, session kind, and outcome. Rollups on the root mean guest
turns — whose work happens inside the guest binary rather than the native
provider loop — still report usage. Each native provider round is a GenAI
CLIENT span named `chat <request-model>`; each local tool execution is an
INTERNAL span named `execute_tool <name>`, parented to the provider round that
requested it. Inference spans include the provider, requested and returned
model identifiers, streaming/TTFT, available request settings, finish reason,
token usage, server address, and low-cardinality error type. Tool spans
include the name, call id, description, and type when available. Successful
spans leave OpenTelemetry status unset; failed spans set ERROR and
`error.type`. Root attributes include `mirador.trace.tags=marlin` and a
promoted `mirador.trace.attribute.session_id`, so Mirador can search and
derive metrics without a second metrics pipeline.

## Content capture (opt-in)

By default the exporter records structure only: no `gen_ai.input.messages`,
`gen_ai.output.messages`, `gen_ai.system_instructions`,
`gen_ai.tool.definitions`, tool arguments, or tool results — and provider
error bodies never ship regardless. Tests assert the absence.

Content capture is a deliberate opt-in, using the ecosystem-standard switch:

```sh
OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=SPAN_ONLY  # daemon env
```

or at runtime, `/otel content on` (`/otel content off` reverts; `/otel status`
reports the state). Marlin records content on spans only, so `span_only`,
`span_and_event`, and `true` enable it; `event_only` and `no_content` do not.

When enabled, the invoke_agent root carries `gen_ai.input.messages` (authored
user input including steering; synthetic post-compaction context is excluded)
and `gen_ai.output.messages` (assistant prose, finish reason on the final
message) in the spec's JSON message shape. Each execute_tool span carries
`gen_ai.tool.call.arguments` and `gen_ai.tool.call.result`. Values are capped
at 32 KiB each with an explicit truncation marker. Content is joined from the
durable block log at export time — telemetry tables stay content-free, and
because tool output is secret-redacted at capture time, exported results
inherit that redaction. Toggling applies to everything still in the outbox.

## Guest telemetry pass-down

When Marlin's exporter is active, guest turns hand the same collector to the
guest binary so its telemetry lands in the same backend, nested under Marlin's
turn via W3C `TRACEPARENT` (trace ids are deterministic, so the guest's spans
join the same trace Marlin exports). Values already present in the daemon's
environment always win.

- **Claude Code** receives `CLAUDE_CODE_ENABLE_TELEMETRY=1`, OTLP exporter
  variables for traces/metrics/logs (traces-only when the configured endpoint
  is traces-specific), headers, and `TRACEPARENT`. Content flags
  (`OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES`,
  `OTEL_LOG_TOOL_DETAILS`, `OTEL_LOG_TOOL_CONTENT`) are set only when Marlin's
  own content capture is on. Note: Claude Code's telemetry includes
  `user.email` and account identifiers by default once enabled.
- **Codex** has no `OTEL_*` environment interface; Marlin passes `-c
  otel.trace_exporter=...` config overrides with per-signal URLs composed from
  the base endpoint. Codex's log events carry tool arguments and output
  previews with no redaction switch of their own, so the content-bearing log
  exporter and `otel.log_user_prompt` are enabled only under Marlin's content
  opt-in; structural trace spans flow regardless. `TRACEPARENT` is exported to
  the process environment as well.

## OpenRouter correlation

When OTLP export is enabled, every OpenRouter request carries a `trace` object.
Its trace id matches the local/OTLP Marlin turn and its parent span id is the
Marlin `chat` span. If OpenRouter Broadcast is configured to send to the same
Mirador project, the provider generation therefore lands beneath the Marlin
request rather than as an unrelated trace. OpenRouter privacy mode remains
independent; Marlin's own export is content-free.

Trace ids are deterministic from the durable session and turn ids, making a
failure reported by `marlin diagnostics --json` directly searchable in the
collector.
