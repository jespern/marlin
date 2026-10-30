#!/bin/sh
set -eu
printf 'attempt\n' >> auth-attempts
case "$MARLIN_AUTH_TEST_CASE" in
    *envelope)
        echo '{"type":"assistant","error":"authentication_failed","message":{"content":[{"type":"text","text":"API Error: 401 OAuth token expired"}]}}'
        sleep 30 ;;
    *stderr)
        echo 'Your session has expired. Please log in again.' >&2
        exit 1 ;;
    *)
        echo '{"type":"result","subtype":"success","is_error":true,"result":"OAuth token expired. Please obtain a new token or refresh your existing token."}' ;;
esac
