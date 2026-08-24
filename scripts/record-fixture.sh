#!/usr/bin/env bash
# Record a real OpenRouter SSE stream into a fixture file.
# Usage: scripts/record-fixture.sh <output-name> [model] [prompt-json-file]
# Requires OPENROUTER_API_KEY. Scrub anything sensitive before committing.
set -euo pipefail

OUT="${1:?usage: record-fixture.sh <output-name> [model]}"
MODEL="${2:-google/gemini-2.5-flash}"
DIR="$(cd "$(dirname "$0")/.." && pwd)/src/testing/fixtures/sse"
mkdir -p "$DIR"

BODY=$(cat <<EOF
{
  "model": "$MODEL",
  "stream": true,
  "stream_options": {"include_usage": true},
  "messages": [{"role": "user", "content": "Reply with exactly: fixture test"}],
  "tools": [{"type":"function","function":{"name":"bash","description":"run a command","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}]
}
EOF
)

curl -sN https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" > "$DIR/$OUT.sse"

echo "recorded → $DIR/$OUT.sse ($(wc -c < "$DIR/$OUT.sse") bytes)"
echo "review for sensitive content before committing!"
