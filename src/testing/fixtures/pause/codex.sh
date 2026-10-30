#!/bin/sh
set -eu
while IFS= read -r line; do
    case "$line" in
        *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *'"method":"account/read"'*) echo '{"id":2,"result":{"account":{"type":"chatgpt"}}}' ;;
        *'"method":"thread/start"'*)
            test ! -e guest-session
            echo pause-thread > guest-session
            echo '{"id":3,"result":{"thread":{"id":"pause-thread"}}}' ;;
        *'"method":"thread/resume"'*)
            test -e guest-session
            case "$line" in *'pause-thread'*) ;; *) exit 22 ;; esac
            echo resumed > guest-resumed
            echo '{"id":3,"result":{"thread":{"id":"pause-thread"}}}' ;;
        *'"method":"turn/start"'*)
            echo '{"id":4,"result":{"turn":{"id":"pause-turn"}}}'
            if [ -e guest-resumed ]; then
                case "$line" in *'Resume the task suspended by Marlin'*) ;; *) exit 23 ;; esac
                echo '{"method":"item/completed","params":{"item":{"id":"reply","type":"agentMessage","text":"guest resumed correctly","phase":"final_answer"}}}'
                echo '{"method":"turn/completed","params":{"threadId":"pause-thread","turn":{"id":"pause-turn","status":"completed"}}}'
            else
                printf '%s' "$$" > guest-pid
                echo '{"method":"item/started","params":{"threadId":"pause-thread","item":{"id":"park","type":"commandExecution","command":"sleep 30","status":"inProgress"}}}'
                sleep 30
                exit 24
            fi ;;
    esac
done
