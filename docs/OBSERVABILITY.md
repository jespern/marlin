# Observability

Marlin records operational evidence locally for every new agent turn. SQLite is
the durable source for `/diagnostics`; exporting it is optional and never sits
on the turn's critical path. Mirador-specific attributes and endpoints follow
its live [OTLP contract](https://otel.mirador.org/llms.txt).

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

```sh
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.mirador.org
export OTEL_EXPORTER_OTLP_HEADERS='Authorization=Bearer%20mir_srv_REDACTED'
marlin otel reload
```

`marlin otel reload` sends the invoking client's standard OTEL variables to the
already-running attached daemon and atomically replaces its exporter. No daemon
restart is required, the values are not persisted, and headers are never echoed
back. `marlin otel status` reports whether export is active; `marlin otel off`
disables it. With `--remote <host>`, the local values travel through the existing
SSH pipe to that host's daemon.

This live control requires a daemon build that supports it; upgrading an older
running daemon still requires one final `!rb`. Future endpoint or key changes do
not. A later daemon restart returns to its startup environment, so keep the OTEL
variables in the daemon's normal launch environment if export should remain on.

`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` may instead name the full traces URL. When
only the base endpoint is set, Marlin appends `/v1/traces`. Header names and
values use the standard comma-separated, percent-encoded form.

Completed turns enter a durable SQLite outbox. One background worker owns a
persistent HTTP pool, sends OTLP JSON, and retries failures after 30 seconds.
Exporter DNS, TLS, HTTP, or collector failures cannot fail or delay an agent
turn; pending count and the last export error appear in diagnostics. Shutdown
cancels an in-flight export before closing SQLite.

Marlin exports one `marlin.turn` root span, `chat` client spans for provider
rounds, and `execute_tool <name>` spans. Root attributes include
`mirador.trace.tags=marlin` and a promoted
`mirador.trace.attribute.session_id`, so Mirador can search and derive metrics
without a second metrics pipeline.

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
