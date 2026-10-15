#!/usr/bin/env python3
"""Independently recompute synchronization statistics from raw sample files.

Works on both kinds of raw data SyncSphere produces:

* simulator ground truth: ``<scenario>.samples.jsonl`` lines of
  ``{"t": trueUs, "gen": g, "err": {"device-0": us, ...}}``
* real-device acoustic captures converted by ``tools/onset_skew.py`` to the
  same format (``err`` = per-device onset offset in µs).

Usage: python3 tools/analyze_samples.py FILE [FILE ...] [--steady-skip-ms 3000]

Only the Python standard library is used so the numbers can be checked on
any machine.
"""
import argparse
import json
import math
import sys


def percentile(values, p):
    if not values:
        return float("nan")
    s = sorted(values)
    rank = p * (len(s) - 1)
    lo, hi = math.floor(rank), math.ceil(rank)
    return s[lo] + (s[hi] - s[lo]) * (rank - lo)


def analyze(path, skip_us):
    spreads, steady, pairwise = [], [], []
    gen_start = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            errs = list(rec["err"].values())
            gen_start.setdefault(rec["gen"], rec["t"])
            if len(errs) < 2:
                continue
            sp = (max(errs) - min(errs)) / 1000.0
            spreads.append(sp)
            if rec["t"] - gen_start[rec["gen"]] > skip_us:
                steady.append(sp)
            for i in range(len(errs)):
                for j in range(i + 1, len(errs)):
                    pairwise.append(abs(errs[i] - errs[j]) / 1000.0)
    return spreads, steady, pairwise


def fmt(values):
    if not values:
        return "n=0"
    return "n=%d median=%.2f p95=%.2f p99=%.2f max=%.2f" % (
        len(values), percentile(values, 0.5), percentile(values, 0.95),
        percentile(values, 0.99), max(values))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--steady-skip-ms", type=float, default=3000)
    args = ap.parse_args()
    for f in args.files:
        spreads, steady, pairwise = analyze(f, args.steady_skip_ms * 1000)
        print(f)
        print("  spread (all)    ms:", fmt(spreads))
        print("  spread (steady) ms:", fmt(steady))
        print("  pairwise        ms:", fmt(pairwise))
    return 0


if __name__ == "__main__":
    sys.exit(main())
