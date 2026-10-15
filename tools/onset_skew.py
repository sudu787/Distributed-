#!/usr/bin/env python3
"""Measure *acoustic* inter-device skew from a multichannel recording.

Setup (docs/benchmarking.md): one microphone per phone, placed against that
phone's speaker (so acoustic propagation is < 0.1 ms), all recorded into one
multichannel WAV by a single audio interface (one sample clock). Every phone
plays the click track from tools/make_click_track.py in a SyncSphere room.

For each channel the script finds click onsets (energy-envelope threshold
crossing, refined to the first sample above 30 % of the click's peak), pairs
the onsets of every channel with those of channel 0 (the reference phone),
and reports per-click offsets in µs:

    python3 tools/onset_skew.py recording.wav --names host,phoneB,phoneC \
        --out results.samples.jsonl

The output uses the same JSONL format as the simulator's ground-truth samples
({"t": µs, "gen": 0, "err": {device: µs}}), so tools/analyze_samples.py
computes identical statistics for real and simulated runs. Results produced
this way ARE real acoustic measurements; label them with the devices,
network and room used.

Standard library only (wave, struct).
"""
import argparse
import json
import math
import struct
import sys
import wave


def read_wav(path):
    with wave.open(path, "rb") as w:
        ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width != 2:
        sys.exit("only 16-bit PCM WAV is supported (got %d-byte samples)" % width)
    samples = struct.unpack("<%dh" % (len(raw) // 2), raw)
    chans = [samples[c::ch] for c in range(ch)]
    return chans, rate


def onsets(x, rate, threshold_ratio=0.25, refractory_s=0.3, window_ms=1.0):
    """Returns onset positions (fractional sample index) of clicks in x."""
    win = max(1, int(rate * window_ms / 1000))
    # Rectified moving average envelope.
    env = [0.0] * len(x)
    acc = 0
    for i, v in enumerate(x):
        acc += abs(v)
        if i >= win:
            acc -= abs(x[i - win])
        env[i] = acc / win
    peak = max(env) if env else 0
    if peak <= 0:
        return []
    noise = sorted(env)[len(env) // 2]  # median ≈ background level
    thr = noise + threshold_ratio * (peak - noise)
    out = []
    refractory = int(refractory_s * rate)
    i = 0
    n = len(env)
    while i < n:
        if env[i] >= thr:
            # Refine: local click peak within 10 ms, then first sample whose
            # absolute value exceeds 30 % of that peak (start of the burst).
            end = min(n, i + int(0.01 * rate))
            start = max(0, i - win * 2)
            local_peak = max(abs(v) for v in x[start:end]) or 1
            j = start
            while j < end and abs(x[j]) < 0.3 * local_peak:
                j += 1
            out.append(float(j))
            i += refractory
        else:
            i += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    ap.add_argument("--names", help="comma-separated device names per channel")
    ap.add_argument("--out", help="write per-click samples as JSONL")
    ap.add_argument("--max-pair-ms", type=float, default=250.0, help="max offset to pair clicks")
    args = ap.parse_args()

    chans, rate = read_wav(args.wav)
    names = args.names.split(",") if args.names else ["ch%d" % i for i in range(len(chans))]
    if len(names) != len(chans):
        sys.exit("--names has %d entries but the file has %d channels" % (len(names), len(chans)))
    ons = [onsets(c, rate) for c in chans]
    for nm, o in zip(names, ons):
        print("%s: %d clicks detected" % (nm, len(o)))
    ref = ons[0]
    max_pair = args.max_pair_ms / 1000 * rate
    rows = []
    for k, t0 in enumerate(ref):
        err = {names[0]: 0}
        for ci in range(1, len(chans)):
            best = min(ons[ci], key=lambda t: abs(t - t0), default=None)
            if best is not None and abs(best - t0) <= max_pair:
                err[names[ci]] = int(round((best - t0) / rate * 1e6))
        if len(err) >= 2:
            rows.append({"t": int(t0 / rate * 1e6), "gen": 0, "err": err})
    if not rows:
        sys.exit("no paired clicks found; check levels and channel assignment")
    spreads = sorted((max(r["err"].values()) - min(r["err"].values())) / 1000 for r in rows)

    def pct(p):
        rank = p * (len(spreads) - 1)
        lo, hi = math.floor(rank), math.ceil(rank)
        return spreads[lo] + (spreads[hi] - spreads[lo]) * (rank - lo)

    print("paired clicks: %d" % len(rows))
    print("acoustic spread ms: median=%.2f p95=%.2f p99=%.2f max=%.2f" % (pct(0.5), pct(0.95), pct(0.99), spreads[-1]))
    for ci in range(1, len(chans)):
        vals = [r["err"][names[ci]] / 1000 for r in rows if names[ci] in r["err"]]
        if vals:
            vals.sort()
            print("  %s vs %s: median %.2f ms (range %.2f … %.2f)" % (names[ci], names[0], vals[len(vals) // 2], vals[0], vals[-1]))
    if args.out:
        with open(args.out, "w") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")
        print("wrote", args.out)


if __name__ == "__main__":
    main()
