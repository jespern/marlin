#!/bin/sh

if [ "${1:-}" = version ]; then
    printf 'marlin @VERSION@\n'
    exit 0
fi

exit 2
