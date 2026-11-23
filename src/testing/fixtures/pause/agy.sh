#!/bin/sh
# An `agy acp` whose first prompt parks in a command until Marlin pauses it;
# after the restart its session is resumed and the prompt asks to go on.
set -eu
while IFS= read -r line; do
    id=$(printf '%s\n' "$line" | sed -n 's/^{"jsonrpc":"2.0","id":\([0-9]*\),.*/\1/p')
    case "$line" in
        *'"method":"initialize"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1}}" ;;
        *'"method":"session/new"'*)
            test ! -e guest-session
            echo pause-session > guest-session
            echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"pause-session\"}}" ;;
        *'"method":"session/resume"'*)
            test -e guest-session
            case "$line" in *'pause-session'*) ;; *) exit 22 ;; esac
            echo resumed > guest-resumed
            echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{}}" ;;
        *'"method":"session/prompt"'*)
            if [ -e guest-resumed ]; then
                case "$line" in *'Resume the task suspended by Marlin'*) ;; *) exit 23 ;; esac
                echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"pause-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"guest resumed correctly"}}}}'
                echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
            else
                printf '%s' "$$" > guest-pid
                echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"pause-session","update":{"sessionUpdate":"tool_call","toolCallId":"park","status":"in_progress","kind":"execute","title":"sleep 30","rawInput":{"CommandLine":"sleep 30"}}}}'
                sleep 30
                exit 24
            fi ;;
    esac
done
