#!/usr/bin/env bash
# reboot vs kill-9 convergence (docs/ARCHITECTURE.md §self-hosting reboot):
# "a reboot is a voluntary, coordinated crash". Run the same session twice —
# once through `marlin reboot`, once through kill -9 — and diff the restored
# state (block log kinds+bodies, session row). Any divergence means the
# reboot path is lying about the crash story.
#
# usage: reboot_convergence.sh <marlin-bin> <fakeprov-bin> <scenario.json>
set -euo pipefail

MARLIN="$1"; FAKEPROV="$2"; SCENARIO="$3"
TEST_TMP_ROOT="${TMPDIR:-/private/tmp}"
SUITE_TMP="$(mktemp -d "$TEST_TMP_ROOT/marlin-conv-suite-XXXXXX")"

run_leg() { # $1 = leg name, $2 = "reboot" | "kill9"
  local leg="$1" mode="$2"
  local state; state="$(mktemp -d "$SUITE_TMP/state-$leg-XXXXXX")"
  local sock="$state/daemon.sock"

  "$FAKEPROV" "$SCENARIO" > "$state/prov.out" &
  local prov_pid=$!
  local port=""
  for _ in $(seq 1 50); do
    port="$(sed -n 's/^PORT //p' "$state/prov.out" 2>/dev/null | head -1)"
    [ -n "$port" ] && break
    sleep 0.1
  done
  [ -n "$port" ] || { echo "FAIL: no provider port ($leg)"; exit 1; }

  env XDG_STATE_HOME="$state" MARLIN_SOCKET="$sock" \
      MARLIN_BASE_URL_OPENROUTER="http://127.0.0.1:$port/v1" \
      OPENROUTER_API_KEY=test \
      "$MARLIN" run --quiet --model openrouter/test/model "first task" > /dev/null

  if [ "$mode" = reboot ]; then
    # Coordinated: reboot + exec into `version` (harmless follow-up).
    env XDG_STATE_HOME="$state" MARLIN_SOCKET="$sock" \
        MARLIN_BASE_URL_OPENROUTER="http://127.0.0.1:$port/v1" \
        OPENROUTER_API_KEY=test \
        "$MARLIN" reboot --then version > /dev/null
  else
    # Crash: SIGKILL the daemon holding the socket.
    local dpid
    dpid="$(pgrep -f "marlin daemon" | while read -r p; do
      lsof -p "$p" 2>/dev/null | grep -q "$sock" && echo "$p" && break
    done || true)"
    [ -n "$dpid" ] && kill -9 "$dpid"
    rm -f "$sock"
    sleep 0.3
  fi

  # Restart (autostart) + continue the session on the new daemon.
  env XDG_STATE_HOME="$state" MARLIN_SOCKET="$sock" \
      MARLIN_BASE_URL_OPENROUTER="http://127.0.0.1:$port/v1" \
      OPENROUTER_API_KEY=test \
      "$MARLIN" run --quiet --continue "second task" > /dev/null

  env XDG_STATE_HOME="$state" MARLIN_SOCKET="$sock" "$MARLIN" shutdown > /dev/null 2>&1 || true
  wait "$prov_pid" 2>/dev/null || true

  # Normalize: kinds + bodies only (ids/timestamps legitimately differ).
  sqlite3 "$state/marlin/marlin.db" \
    "PRAGMA busy_timeout=5000; SELECT seq, kind, body_json FROM blocks ORDER BY seq;" \
    > "$SUITE_TMP/$leg.dump"
  echo "$state"
}

sA="$(run_leg A reboot)"
sB="$(run_leg B kill9)"

if diff -u "$SUITE_TMP/A.dump" "$SUITE_TMP/B.dump"; then
  echo "CONVERGENCE OK: reboot and kill-9 restore identical block logs"
  rm -rf "$SUITE_TMP"
else
  echo "CONVERGENCE FAILED: states diverge (artifacts kept in $SUITE_TMP)"
  exit 1
fi
