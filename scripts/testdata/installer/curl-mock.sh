#!/bin/sh

set -eu

url=
destination=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            destination=$2
            shift 2
            ;;
        -*) shift ;;
        *)
            url=$1
            shift
            ;;
    esac
done

[ -n "$url" ]
[ -n "$destination" ]
if [ -n "${MARLIN_MOCK_URL_LOG:-}" ]; then
    printf '%s\n' "$url" >> "$MARLIN_MOCK_URL_LOG"
fi
cp "${MARLIN_MOCK_RELEASE_DIR:?}/${url##*/}" "$destination"
