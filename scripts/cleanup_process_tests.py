#!/usr/bin/env python3
"""Inspect or remove orphaned Marlin escapee-test loops; dry-run by default."""

import argparse
from dataclasses import dataclass
import os
import re
import signal
import subprocess
import sys
import time


LEGACY_SCRIPT = (
    "set -m\n"
    "(trap '' TERM; while :; do sleep 1; done) &\n"
    "printf '%s' \"$!\" > \"$1\"\n"
    "wait -- "
)
FIXTURE_PATH = re.compile(r"/[^\s]+/marlin-process-io-escapee-[0-9a-f]+/escapee\.pid")
SLEEP = re.compile(r"(?:/[^\s]*/)?sleep 1")


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    pgid: int
    uid: int
    started: str
    command: str


def parse_snapshot(output):
    processes = {}
    for line in output.splitlines():
        fields = line.split(None, 9)
        if len(fields) != 10:
            raise ValueError("Incomplete process listing; refusing cleanup")
        pid, ppid, pgid, uid = map(int, fields[:4])
        processes[pid] = Process(
            pid, ppid, pgid, uid, " ".join(fields[4:9]),
            fields[9].replace("\\012", "\n"),
        )
    return processes


def snapshot():
    result = subprocess.run(
        ["/bin/ps", "-ww", "-axo", "pid=,ppid=,pgid=,uid=,lstart=,args="],
        capture_output=True, text=True, check=True, timeout=10,
        env={**os.environ, "LC_ALL": "C"},
    )
    return parse_snapshot(result.stdout)


def is_leftover(process, uid):
    if process.uid != uid or process.ppid != 1 or process.pid <= 1:
        return False
    if process.pgid != process.pid:
        return False
    command = re.sub(r"^(?:/[^\s]*/)?bash -c ", "", process.command, count=1)
    if command == process.command or not command.startswith(LEGACY_SCRIPT):
        return False
    return FIXTURE_PATH.fullmatch(command[len(LEGACY_SCRIPT):]) is not None


def safe_group(original, current, uid):
    process = current.get(original.pid)
    # Start time and full command protect against a PID being recycled
    # between the initial list and this immediately-before-kill snapshot.
    if process != original or not is_leftover(process, uid):
        return False
    for member in current.values():
        if member.pgid != process.pgid or member.pid == process.pid:
            continue
        if (member.uid != uid or member.ppid != process.pid
                or SLEEP.fullmatch(member.command) is None):
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="kill verified leftover groups")
    args = parser.parse_args()
    uid = os.getuid()
    candidates = [p for p in snapshot().values() if is_leftover(p, uid)]
    for process in candidates:
        print(f"PID {process.pid}, started {process.started}: orphaned escapee-test loop")
    print(f"Found {len(candidates)} orphaned test loops.")
    if not args.apply:
        print("Dry run. Add --apply to remove these loops and their sleep children.")
        return 0

    killed = []
    refused = []
    for process in candidates:
        current = snapshot()
        if process.pid not in current:
            continue
        if not safe_group(process, current, uid):
            refused.append(process.pid)
            continue
        try:
            # These exact fixtures deliberately ignore SIGTERM.
            os.killpg(process.pgid, signal.SIGKILL)
        except ProcessLookupError:
            continue
        killed.append(process)

    deadline = time.monotonic() + 3
    while True:
        remaining = snapshot()
        survivors = [p.pid for p in killed if any(q.pgid == p.pgid for q in remaining.values())]
        if not survivors or time.monotonic() >= deadline:
            break
        time.sleep(0.05)
    print(f"Terminated {len(killed)} test groups; {len(survivors)} still visible.")
    if refused:
        print(f"Skipped changed or unexpected groups: {refused}", file=sys.stderr)
    if survivors:
        print(f"Still visible: {survivors}", file=sys.stderr)
    return 1 if refused or survivors else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Cleanup stopped: {error}. Run from a terminal with process access.", file=sys.stderr)
        sys.exit(1)
