#!/bin/sh
set -eu
resumed=0
session=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --resume) resumed=1; shift; session="$1" ;;
        --session-id) shift; session="$1" ;;
    esac
    shift
done
echo '{"type":"system","subtype":"init","session_id":"pause-peer"}'
IFS= read -r input
if [ "$resumed" = 1 ]; then
    test "$session" = "$(cat guest-session)"
    case "$input" in *'Resume the task suspended by Marlin'*) ;; *) exit 20 ;; esac
    echo '{"type":"result","subtype":"success","result":"guest resumed correctly","usage":{"input_tokens":1,"output_tokens":1}}'
else
    printf '%s' "$session" > guest-session
    printf '%s' "$$" > guest-pid
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"park","name":"Bash","input":{"command":"sleep 30"}}]}}'
    sleep 30
    exit 21
fi
