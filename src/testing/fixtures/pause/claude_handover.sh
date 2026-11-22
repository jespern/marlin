#!/bin/sh
# A Claude Code turn that spans a daemon handover. It parks in a tool until
# the test opens `release` (a FIFO, so nothing polls), and must be the very
# same process that finishes: a resume would bring the suspended-task prompt.
set -eu
echo '{"type":"system","subtype":"init","session_id":"handover-peer"}'
IFS= read -r input
case "$input" in *'Resume the task suspended by Marlin'*) exit 22 ;; esac
rm -f release
mkfifo release
printf '%s' "$$" > guest-pid
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Commentary before the restart."},{"type":"tool_use","id":"park","name":"Bash","input":{"command":"wait for the release"}}]}}'
IFS= read -r _ < release
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"park","content":"released after the restart","is_error":false}]}}'
echo '{"type":"result","subtype":"success","result":"guest finished across the handover","usage":{"input_tokens":1,"output_tokens":1}}'
