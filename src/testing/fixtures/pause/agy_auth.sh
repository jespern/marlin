#!/bin/sh
# An `agy acp` with no sign-in: ACP's "authentication required" on the
# session. Each start is counted, so a retry shows.
set -eu
printf 'attempt\n' >> auth-attempts
while IFS= read -r line; do
    id=$(printf '%s\n' "$line" | sed -n 's/^{"jsonrpc":"2.0","id":\([0-9]*\),.*/\1/p')
    case "$line" in
        *'"method":"initialize"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1}}" ;;
        *'"method":"session/new"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32000,\"message\":\"Authentication required\"}}" ;;
    esac
done
