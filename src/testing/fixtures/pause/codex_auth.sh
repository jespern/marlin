#!/bin/sh
set -eu
printf 'attempt\n' >> auth-attempts
while IFS= read -r line; do
    case "$line" in
        *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *'"method":"account/read"'*)
            case "$MARLIN_AUTH_TEST_CASE" in
                *rpc) echo '{"id":2,"error":{"code":401,"message":"Session expired. Please log in again."}}' ;;
                *) echo '{"id":2,"result":{"account":{"type":"chatgpt"}}}' ;;
            esac ;;
        *'"method":"thread/start"'*) echo '{"id":3,"result":{"thread":{"id":"auth-thread"}}}' ;;
        *'"method":"turn/start"'*)
            echo '{"id":4,"result":{"turn":{"id":"auth-turn"}}}'
            echo '{"method":"error","params":{"threadId":"auth-thread","turnId":"auth-turn","willRetry":true,"error":{"message":"Bad Request","codexErrorInfo":{"responseStreamDisconnected":{"httpStatusCode":401}}}}}'
            sleep 30 ;;
    esac
done
