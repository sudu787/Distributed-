#!/usr/bin/env python3
"""Generate a click-track WAV for acoustic synchronization measurements.

The track contains short 2 kHz tone bursts (default 4 ms, raised-cosine
envelope) once per second on a silent background. Import the *same file* on
every phone, play it in a SyncSphere room, and record the phones with
``tools/onset_skew.py`` (see docs/benchmarking.md).

Usage: python3 tools/make_click_track.py out.wav [--minutes 10] [--rate 48000]

Standard library only. The generated audio is original test content and free
to share.
"""
import argparse
import math
import struct
import wave


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--minutes", type=float, default=10.0)
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--burst-ms", type=float, default=4.0)
    ap.add_argument("--freq", type=float, default=2000.0)
    ap.add_argument("--interval", type=float, default=1.0)
    args = ap.parse_args()

    n = int(args.minutes * 60 * args.rate)
    burst = int(args.burst_ms / 1000 * args.rate)
    period = int(args.interval * args.rate)
    tone = []
    for i in range(burst):
        env = 0.5 - 0.5 * math.cos(2 * math.pi * i / max(1, burst - 1))
        tone.append(int(0.8 * 32767 * env * math.sin(2 * math.pi * args.freq * i / args.rate)))
    silence = b"\x00\x00" * (period - burst)
    click = struct.pack("<%dh" % burst, *tone)
    with wave.open(args.out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(args.rate)
        written = 0
        while written + period <= n:
            w.writeframes(click + silence)
            written += period
    print("wrote %s: %d clicks, %.1f min at %d Hz" % (args.out, written // period, written / args.rate / 60, args.rate))


if __name__ == "__main__":
    main()
