#!/bin/sh
# An `agy acp` whose prompt spans a daemon handover. It parks in a command
# until the test opens `release` (a FIFO), and must be the very same process
# that finishes. A request seen twice means a replaying daemon wrote it
# again: exit 25.
set -eu
seen=''
once() {
    case " $seen " in *" $1 "*) exit 25 ;; esac
    seen="$seen $1"
}
while IFS= read -r line; do
    id=$(printf '%s\n' "$line" | sed -n 's/^{"jsonrpc":"2.0","id":\([0-9]*\),.*/\1/p')
    case "$line" in
        *'"method":"initialize"'*) once initialize; echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1}}" ;;
        *'"method":"session/new"'*) once session; echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"handover-session\"}}" ;;
        *'"method":"session/resume"'*) exit 26 ;;
        *'"method":"session/prompt"'*)
            once prompt
            case "$line" in *'Resume the task suspended by Marlin'*) exit 22 ;; esac
            rm -f release
            mkfifo release
            printf '%s' "$$" > guest-pid
            echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"handover-session","update":{"sessionUpdate":"tool_call","toolCallId":"park","status":"in_progress","kind":"execute","title":"wait for the release","rawInput":{"CommandLine":"wait for the release"}}}}'
            IFS= read -r _ < release
            echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"handover-session","update":{"sessionUpdate":"tool_call_update","toolCallId":"park","status":"completed","content":[{"type":"content","content":{"type":"text","text":"released after the restart"}}]}}}'
            echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"handover-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"guest finished "}}}}'
            echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"handover-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"across the handover"}}}}'
            echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\",\"usage\":{\"inputTokens\":10,\"outputTokens\":5}}}" ;;
    esac
done
