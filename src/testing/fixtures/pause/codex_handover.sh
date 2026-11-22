#!/bin/sh
# A Codex app-server whose turn spans a daemon handover. It parks in a
# command until the test opens `release` (a FIFO), and must be the very same
# process that finishes. A request seen twice means a replaying daemon wrote
# it again: exit 25.
set -eu
seen=''
once() {
    case " $seen " in *" $1 "*) exit 25 ;; esac
    seen="$seen $1"
}
while IFS= read -r line; do
    case "$line" in
        *'"method":"initialize"'*) once initialize; echo '{"id":1,"result":{}}' ;;
        *'"method":"account/read"'*) once account; echo '{"id":2,"result":{"account":{"type":"chatgpt"}}}' ;;
        *'"method":"thread/start"'*) once thread; echo '{"id":3,"result":{"thread":{"id":"handover-thread"}}}' ;;
        *'"method":"thread/resume"'*) exit 26 ;;
        *'"method":"turn/start"'*)
            once turn
            case "$line" in *'Resume the task suspended by Marlin'*) exit 22 ;; esac
            rm -f release
            mkfifo release
            printf '%s' "$$" > guest-pid
            echo '{"id":4,"result":{"turn":{"id":"handover-turn"}}}'
            echo '{"method":"item/started","params":{"threadId":"handover-thread","item":{"id":"park","type":"commandExecution","command":"wait for the release","status":"inProgress"}}}'
            IFS= read -r _ < release
            echo '{"method":"item/completed","params":{"threadId":"handover-thread","item":{"id":"park","type":"commandExecution","command":"wait for the release","status":"completed","exitCode":0,"aggregatedOutput":"released after the restart"}}}'
            echo '{"method":"item/completed","params":{"threadId":"handover-thread","item":{"id":"reply","type":"agentMessage","text":"guest finished across the handover","phase":"final_answer"}}}'
            echo '{"method":"turn/completed","params":{"threadId":"handover-thread","turn":{"id":"handover-turn","status":"completed"}}}' ;;
    esac
done
