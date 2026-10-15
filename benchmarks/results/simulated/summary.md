# SyncSphere simulated benchmark results

> **SIMULATED — virtual time, modelled clocks/network/audio devices. NOT hardware measurements.**  
> suite `full`, seed `42`, generated 2026-10-15T06:58:03.733334Z  
> Spread = max − min acoustic (ground-truth) position error across devices at the same instant, sampled every 50 ms. "Steady" excludes 3 s after each timeline change.

| scenario | n | network | spread p50 | spread p95 | spread p99 | spread max | start skew p50 | start skew max | last-min p95 | cmd→audible p50 | clock err p95 (µs) | unc. coverage | recovery max | resyncs | failed |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| matrix-lan-ideal-n2 | 2 | lan-ideal | 1.5 | 8.7 | 16.7 | 21.1 | 10.5 | 23.4 | 21.2 | 360.0 | 110.0 | 1.0 | – | 0 | 0 |
| matrix-lan-ideal-n3 | 3 | lan-ideal | 6.1 | 10.0 | 14.9 | 17.0 | 12.9 | 18.6 | 15.9 | 320.0 | 107.0 | 1.0 | – | 0 | 0 |
| matrix-lan-ideal-n5 | 5 | lan-ideal | 7.9 | 11.2 | 20.5 | 28.5 | 13.3 | 33.6 | 11.2 | 320.0 | 158.0 | 1.0 | – | 0 | 0 |
| matrix-lan-ideal-n10 | 10 | lan-ideal | 10.5 | 17.9 | 25.6 | 29.7 | 31.6 | 35.0 | 29.2 | 340.0 | 143.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n2 | 2 | wifi-good | 0.5 | 5.4 | 10.8 | 13.8 | 9.3 | 15.9 | 11.6 | 360.0 | 369.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n3 | 3 | wifi-good | 6.0 | 9.6 | 14.8 | 17.0 | 13.2 | 18.6 | 15.8 | 320.0 | 776.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n5 | 5 | wifi-good | 8.8 | 13.9 | 21.5 | 28.3 | 19.9 | 33.8 | 22.4 | 360.0 | 500.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n10 | 10 | wifi-good | 11.7 | 18.4 | 24.8 | 30.0 | 29.1 | 35.2 | 27.6 | 380.0 | 620.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n2 | 2 | wifi-typical | 1.3 | 5.6 | 10.8 | 14.3 | 9.4 | 16.3 | 11.4 | 360.0 | 1007.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n3 | 3 | wifi-typical | 6.0 | 9.6 | 14.3 | 16.0 | 12.6 | 17.8 | 15.6 | 400.0 | 1315.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n5 | 5 | wifi-typical | 4.3 | 11.8 | 23.0 | 31.0 | 14.1 | 34.4 | 11.8 | 400.0 | 1073.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n10 | 10 | wifi-typical | 10.9 | 14.9 | 21.0 | 27.4 | 21.2 | 30.7 | 21.6 | 540.0 | 1416.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n2 | 2 | wifi-congested | 3.4 | 11.8 | 16.8 | 20.0 | 17.3 | 22.1 | 20.4 | 380.0 | 4672.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n3 | 3 | wifi-congested | 8.3 | 11.5 | 16.5 | 18.7 | 15.2 | 21.1 | 18.0 | 400.0 | 8540.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n5 | 5 | wifi-congested | 11.3 | 16.9 | 32.7 | 40.4 | 20.6 | 43.1 | 19.8 | 560.0 | 6658.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n10 | 10 | wifi-congested | 13.2 | 20.9 | 26.7 | 31.1 | 30.7 | 35.1 | 27.5 | 720.0 | 6694.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n2 | 2 | hotspot | 2.4 | 9.4 | 17.2 | 21.6 | 8.1 | 24.1 | 22.0 | 380.0 | 2347.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n3 | 3 | hotspot | 6.2 | 9.6 | 14.3 | 15.7 | 13.2 | 17.6 | 15.8 | 380.0 | 1784.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n5 | 5 | hotspot | 10.7 | 13.9 | 23.6 | 31.6 | 19.8 | 34.9 | 19.3 | 620.0 | 1982.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n10 | 10 | hotspot | 9.1 | 16.6 | 25.8 | 29.8 | 31.1 | 34.0 | 28.3 | 500.0 | 2443.0 | 0.9991 | – | 0 | 0 |
| partition-recovery-n5 | 5 | wifi-typical | 8.6 | 10.3 | 16.4 | 23.8 | 27.4 | 27.4 | 8.6 | 640.0 | 1454.0 | 1.0 | 50.0 | 0 | 0 |
| coordinator-failure-n3 | 3 | wifi-good | 8.1 | 16.8 | 23.3 | 24.9 | 28.5 | 28.5 | 28.4 | 620.0 | 947.0 | 1.0 | – | 0 | 2 |
| coordinator-failover-n5 | 5 | wifi-typical | 4.5 | 11.0 | 17.6 | 23.8 | 23.9 | 27.4 | 18.8 | 500.0 | 1859.0 | 1.0 | – | 0 | 0 |
| heterogeneous-devices-n5 | 5 | wifi-typical | 28.8 | 47.3 | 50.0 | 56.9 | 36.5 | 57.8 | 30.9 | 780.0 | 1371.0 | 1.0 | – | 0 | 0 |
| bluetooth-uncalibrated-n2 | 2 | wifi-good | 184.9 | 186.1 | 186.2 | 186.2 | 5.1 | 5.1 | 185.9 | 600.0 | 622.0 | 1.0 | – | 0 | 0 |
| bluetooth-calibrated-n2 | 2 | wifi-good | 3.6 | 4.9 | 5.0 | 5.0 | 5.1 | 5.1 | 4.2 | 600.0 | 654.0 | 1.0 | – | 0 | 0 |
| drift-uncorrected-n3 | 3 | wifi-good | 65.2 | 134.7 | 146.2 | 149.3 | 19.1 | 28.3 | 149.0 | 620.0 | 258.0 | 1.0 | – | 0 | 0 |
| drift-corrected-n3 | 3 | wifi-good | 3.7 | 6.6 | 7.7 | 24.6 | 18.3 | 28.3 | 5.9 | 620.0 | 248.0 | 1.0 | – | 0 | 0 |

## Coordinator failover (SIMULATED)

| scenario | final epoch | last promoted | promoted after kill (ms) | spread p95 / max in 15 s after promotion (ms) |
|---|---|---|---|---|
| coordinator-failover-n5 | 3 | device-4 | 2015 | 7.8 / 7.8 |

All times in ms unless noted. Raw per-sample data: `<scenario>.samples.jsonl`; recompute with `tools/analyze_samples.py`.
