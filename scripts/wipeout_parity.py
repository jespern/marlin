#!/usr/bin/env python3
"""Compare ship trajectories from the Zig port and the reference build.

Usage:
  scripts/wipeout_parity.py zig.csv reference.csv

Both files come from the same recorded input: the Zig probe writes them
with --record-input/--ship-log, the reference harness
(~/Work/wipeout-rewrite/harness/parity) consumes the recording and writes
the same CSV layout. See docs/WIPEOUT_PORT.md, "Parity harness".
"""
import csv, math, sys

INT_COLS = {"frame", "section", "num", "flying", "mode"}


def load(path):
    rows = list(csv.DictReader(open(path)))
    return [{k: (int(v) if k in INT_COLS else float(v)) for k, v in r.items()} for r in rows]


def dist(a, b, keys):
    return math.sqrt(sum((a[k] - b[k]) ** 2 for k in keys))


def angle_err(a, b):
    return max(abs(((a[k] - b[k] + math.pi) % (2 * math.pi)) - math.pi) for k in ("ax", "ay", "az"))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    z, c = load(sys.argv[1]), load(sys.argv[2])
    n = min(len(z), len(c))
    first = {}
    worst_pos = worst_ang = 0.0
    mismatches = {k: None for k in ("section", "mode", "flying")}
    for i in range(n):
        dp = dist(z[i], c[i], ("px", "py", "pz"))
        da = angle_err(z[i], c[i])
        worst_pos, worst_ang = max(worst_pos, dp), max(worst_ang, da)
        for thr in (0.001, 0.01, 0.1, 1, 10, 100):
            if thr not in first and dp > thr:
                first[thr] = i
        for k in mismatches:
            if mismatches[k] is None and z[i][k] != c[i][k]:
                mismatches[k] = i
    print(f"frames compared: {n}")
    print(f"worst position error: {worst_pos:.4f} units, worst angle error: {worst_ang:.7f} rad")
    print("first frame over threshold:", ", ".join(f"{t}: {first.get(t)}" for t in (0.001, 0.01, 0.1, 1, 10, 100)))
    print("first mismatch:", ", ".join(f"{k}: {v}" for k, v in mismatches.items()))
    step = 600
    for start in range(0, n, step):
        seg = range(start, min(start + step, n))
        mp = max(dist(z[i], c[i], ("px", "py", "pz")) for i in seg)
        ma = max(angle_err(z[i], c[i]) for i in seg)
        print(f"  frames {start:5d}-{seg[-1]:5d}: pos err max {mp:9.4f}  angle err max {ma:.7f}  section zig {z[seg[-1]]['section']:3d} ref {c[seg[-1]]['section']:3d}")
    ok = worst_pos < 1.0 and all(v is None for v in mismatches.values())
    print("PARITY OK" if ok else "PARITY DIVERGED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
