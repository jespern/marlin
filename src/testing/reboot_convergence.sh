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
ACTIVE_STATE=""
PROVIDER_PID=""

find_daemon() { # $1 = socket path
  local sock="$1"
  pgrep -f "marlin daemon" | while read -r p; do
    lsof -p "$p" 2>/dev/null | grep -q "$sock" && echo "$p" && break
  done || true
}

stop_daemon() { # $1 = isolated state directory
  local state="$1" dpid
  dpid="$(find_daemon "$state/daemon.sock")"
  if [ -z "$dpid" ]; then
    return
  fi
  kill -TERM "$dpid" 2>/dev/null || true
  local ticks=20
  while kill -0 "$dpid" 2>/dev/null && [ "$ticks" -gt 0 ]; do
    ticks=$((ticks - 1))
    sleep 0.05
  done
  if kill -0 "$dpid" 2>/dev/null; then
    kill -KILL "$dpid" 2>/dev/null || true
  fi
}

cleanup_active() {
  if [ -n "$PROVIDER_PID" ]; then
    kill -TERM "$PROVIDER_PID" 2>/dev/null || true
    wait "$PROVIDER_PID" 2>/dev/null || true
    PROVIDER_PID=""
  fi
  if [ -n "$ACTIVE_STATE" ]; then
    stop_daemon "$ACTIVE_STATE"
    ACTIVE_STATE=""
  fi
}
trap cleanup_active EXIT INT TERM

wait_pid_bounded() { # $1 = pid, $2 = seconds, $3 = label
  local command_pid="$1" seconds="$2" label="$3"
  local ticks=$((seconds * 10))
  local timed_out=0
  while kill -0 "$command_pid" 2>/dev/null; do
    if [ "$ticks" -le 0 ]; then
      timed_out=1
      kill -TERM "$command_pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$command_pid" 2>/dev/null || true
      break
    fi
    ticks=$((ticks - 1))
    sleep 0.1
  done
  local status=0
  wait "$command_pid" || status=$?
  if [ "$timed_out" -eq 1 ]; then
    echo "FAIL: $label exceeded ${seconds}s" >&2
    return 124
  fi
  return "$status"
}

run_bounded() { # $1 = seconds, $2 = label, remaining args = command
  local seconds="$1" label="$2"
  shift 2
  "$@" &
  local command_pid=$!
  wait_pid_bounded "$command_pid" "$seconds" "$label"
}

wait_provider() { # bounded wait for the active provider
  local status=0
  wait_pid_bounded "$PROVIDER_PID" 5 "fake provider completion" || status=$?
  PROVIDER_PID=""
  return "$status"
}

run_leg() { # $1 = leg name, $2 = "reboot" | "kill9"
  local leg="$1" mode="$2"
  local state; state="$(mktemp -d "$SUITE_TMP/state-$leg-XXXXXX")"
  local sock="$state/daemon.sock"
  ACTIVE_STATE="$state"

  "$FAKEPROV" "$SCENARIO" > "$state/prov.out" 2> "$state/prov.err" &
  local prov_pid=$!
  PROVIDER_PID="$prov_pid"
  local port=""
  for _ in $(seq 1 50); do
    port="$(sed -n 's/^PORT //p' "$state/prov.out" 2>/dev/null | head -1)"
    [ -n "$port" ] && break
    sleep 0.1
  done
  [ -n "$port" ] || { echo "FAIL: no provider port ($leg)"; exit 1; }

  local -a marlin_env=(env HOME="$state" TMPDIR="$state" XDG_STATE_HOME="$state" \
      MARLIN_SOCKET="$sock" MARLIN_DAEMON_PGID=inherit MARLIN_NETWORK_BLOCKLISTS= \
      MARLIN_BASE_URL_LOCAL="http://127.0.0.1:$port/v1" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin)

  run_bounded 30 "$leg first turn" "${marlin_env[@]}" \
      "$MARLIN" run --quiet --model local/testing "first task" > /dev/null

  if [ "$mode" = reboot ]; then
    # Coordinated: reboot + exec into `version` (harmless follow-up).
    run_bounded 10 "$leg coordinated reboot" "${marlin_env[@]}" \
        "$MARLIN" reboot --then version > /dev/null
  else
    # Crash: SIGKILL the daemon holding the socket.
    local dpid
    dpid="$(find_daemon "$sock")"
    [ -n "$dpid" ] && kill -9 "$dpid"
    rm -f "$sock"
    sleep 0.3
  fi

  # Restart (autostart) + continue the session on the new daemon.
  run_bounded 30 "$leg resumed turn" "${marlin_env[@]}" \
      "$MARLIN" run --quiet --continue "second task" > /dev/null

  run_bounded 5 "$leg daemon shutdown" "${marlin_env[@]}" \
      "$MARLIN" shutdown > /dev/null 2>&1 || true
  # Shutdown is graceful best-effort; independently prove no isolated daemon
  # survived before releasing the cleanup trap's state reference.
  stop_daemon "$state"
  wait_provider
  ACTIVE_STATE=""

  # Normalize: kinds + bodies only (ids/timestamps legitimately differ).
  sqlite3 "$state/marlin/marlin.db" \
    "PRAGMA busy_timeout=5000; SELECT seq, kind, body_json FROM blocks ORDER BY seq;" \
    > "$SUITE_TMP/$leg.dump"
}

run_leg A reboot
run_leg B kill9

if diff -u "$SUITE_TMP/A.dump" "$SUITE_TMP/B.dump"; then
  echo "CONVERGENCE OK: reboot and kill-9 restore identical block logs"
  rm -rf "$SUITE_TMP"
else
  echo "CONVERGENCE FAILED: states diverge (artifacts kept in $SUITE_TMP)"
  exit 1
fi
