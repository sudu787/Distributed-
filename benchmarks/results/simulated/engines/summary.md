# SyncSphere simulated benchmark results

> **SIMULATED — virtual time, modelled clocks/network/audio devices. NOT hardware measurements.**  
> suite `engines`, seed `42`, generated 2026-11-05T12:58:10.909643Z  
> Spread = max − min acoustic (ground-truth) position error across devices at the same instant, sampled every 50 ms. "Steady" excludes 3 s after each timeline change.

| scenario | n | network | spread p50 | spread p95 | spread p99 | spread max | start skew p50 | start skew max | last-min p95 | cmd→audible p50 | clock err p95 (µs) | unc. coverage | recovery max | resyncs | failed |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| engines-classic-phones-wifi-good-n3 | 3 | wifi-good | 36.4 | 69.0 | 95.9 | 108.5 | 53.5 | 97.3 | 88.4 | 680.0 | 686.0 | 1.0 | – | 2 | 0 |
| engines-classic-phones-wifi-good-n5 | 5 | wifi-good | 25.2 | 158.0 | 207.5 | 220.2 | 85.6 | 112.5 | 57.5 | 700.0 | 577.0 | 1.0 | – | 5 | 0 |
| engines-classic-phones-wifi-typical-n3 | 3 | wifi-typical | 35.9 | 71.4 | 95.3 | 107.8 | 40.2 | 105.2 | 96.0 | 780.0 | 1308.0 | 1.0 | – | 2 | 0 |
| engines-classic-phones-wifi-typical-n5 | 5 | wifi-typical | 25.0 | 163.0 | 212.8 | 225.4 | 91.9 | 113.2 | 69.0 | 720.0 | 1188.0 | 1.0 | – | 5 | 0 |
| engines-warm-phones-wifi-good-n3 | 3 | wifi-good | 7.7 | 31.2 | 31.3 | 37.7 | 23.1 | 39.8 | 31.2 | 640.0 | 569.0 | 1.0 | – | 0 | 0 |
| engines-warm-phones-wifi-good-n5 | 5 | wifi-good | 22.1 | 25.1 | 28.1 | 36.4 | 23.9 | 43.5 | 25.1 | 600.0 | 597.0 | 1.0 | – | 0 | 0 |
| engines-warm-phones-wifi-typical-n3 | 3 | wifi-typical | 7.1 | 30.4 | 30.5 | 36.3 | 23.0 | 38.7 | 30.4 | 700.0 | 1027.0 | 1.0 | – | 0 | 0 |
| engines-warm-phones-wifi-typical-n5 | 5 | wifi-typical | 19.5 | 23.8 | 32.6 | 41.0 | 30.3 | 44.0 | 33.0 | 640.0 | 1268.0 | 1.0 | – | 0 | 0 |
| engines-precise-phones-wifi-good-n3 | 3 | wifi-good | 1.3 | 2.1 | 2.3 | 2.4 | 1.4 | 2.5 | 2.1 | 660.0 | 478.0 | 1.0 | – | 0 | 0 |
| engines-precise-phones-wifi-good-n5 | 5 | wifi-good | 1.6 | 2.8 | 2.9 | 2.9 | 1.6 | 2.1 | 2.8 | 680.0 | 555.0 | 1.0 | – | 0 | 0 |
| engines-precise-phones-wifi-typical-n3 | 3 | wifi-typical | 1.4 | 2.3 | 2.4 | 2.5 | 1.4 | 2.6 | 1.9 | 680.0 | 1023.0 | 1.0 | – | 0 | 0 |
| engines-precise-phones-wifi-typical-n5 | 5 | wifi-typical | 1.8 | 2.2 | 2.2 | 2.3 | 1.7 | 1.9 | 2.2 | 760.0 | 1268.0 | 1.0 | – | 0 | 0 |

## Sync engines (SIMULATED)

First 3 s = the spread right after each start, resume, seek and track change (where an echo is heard); steady = afterwards. Cold starts = starts that found the speaker output asleep.

| scenario | engine | first 3 s p50 | first 3 s p95 | steady p95 | start skew p50 | start skew max | cold starts | resyncs |
|---|---|---|---|---|---|---|---|---|
| engines-classic-phones-wifi-good-n3 | classic | 49.3 | 97.2 | 69.0 | 53.5 | 97.3 | 6 | 2 |
| engines-classic-phones-wifi-good-n5 | classic | 65.8 | 113.1 | 158.0 | 85.6 | 112.5 | 10 | 5 |
| engines-classic-phones-wifi-typical-n3 | classic | 30.4 | 105.2 | 71.4 | 40.2 | 105.2 | 6 | 2 |
| engines-classic-phones-wifi-typical-n5 | classic | 77.5 | 113.5 | 163.0 | 91.9 | 113.2 | 10 | 5 |
| engines-warm-phones-wifi-good-n3 | warm | 23.1 | 39.8 | 31.2 | 23.1 | 39.8 | 0 | 0 |
| engines-warm-phones-wifi-good-n5 | warm | 22.8 | 43.5 | 25.1 | 23.9 | 43.5 | 0 | 0 |
| engines-warm-phones-wifi-typical-n3 | warm | 23.0 | 38.7 | 30.4 | 23.0 | 38.7 | 0 | 0 |
| engines-warm-phones-wifi-typical-n5 | warm | 24.8 | 44.0 | 23.8 | 30.3 | 44.0 | 0 | 0 |
| engines-precise-phones-wifi-good-n3 | precise | 1.4 | 2.5 | 2.1 | 1.4 | 2.5 | 0 | 0 |
| engines-precise-phones-wifi-good-n5 | precise | 1.5 | 2.2 | 2.8 | 1.6 | 2.1 | 0 | 0 |
| engines-precise-phones-wifi-typical-n3 | precise | 1.4 | 2.6 | 2.3 | 1.4 | 2.6 | 0 | 0 |
| engines-precise-phones-wifi-typical-n5 | precise | 1.7 | 1.9 | 2.2 | 1.7 | 1.9 | 0 | 0 |

All times in ms unless noted. Raw per-sample data: `<scenario>.samples.jsonl`; recompute with `tools/analyze_samples.py`.
