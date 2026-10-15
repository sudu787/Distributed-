# SyncSphere simulated benchmark results

> **SIMULATED — virtual time, modelled clocks/network/audio devices. NOT hardware measurements.**  
> suite `full`, seed `42`, generated 2026-10-15T16:05:24.924490Z  
> Spread = max − min acoustic (ground-truth) position error across devices at the same instant, sampled every 50 ms. "Steady" excludes 3 s after each timeline change.

| scenario | n | network | spread p50 | spread p95 | spread p99 | spread max | start skew p50 | start skew max | last-min p95 | cmd→audible p50 | clock err p95 (µs) | unc. coverage | recovery max | resyncs | failed |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| matrix-lan-ideal-n2 | 2 | lan-ideal | 2.5 | 6.8 | 16.5 | 20.9 | 2.7 | 23.2 | 21.0 | 360.0 | 110.0 | 1.0 | – | 0 | 0 |
| matrix-lan-ideal-n3 | 3 | lan-ideal | 6.5 | 10.2 | 15.4 | 17.0 | 12.9 | 18.6 | 16.9 | 320.0 | 94.0 | 1.0 | – | 0 | 0 |
| matrix-lan-ideal-n5 | 5 | lan-ideal | 10.0 | 14.0 | 20.5 | 28.5 | 14.2 | 33.6 | 14.0 | 300.0 | 164.0 | 1.0 | – | 0 | 0 |
| matrix-lan-ideal-n10 | 10 | lan-ideal | 9.4 | 16.5 | 22.4 | 26.3 | 27.5 | 30.1 | 24.4 | 360.0 | 137.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n2 | 2 | wifi-good | 0.3 | 5.2 | 9.6 | 11.6 | 8.9 | 13.4 | 11.0 | 360.0 | 374.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n3 | 3 | wifi-good | 6.9 | 12.7 | 17.0 | 21.1 | 18.6 | 23.0 | 21.4 | 320.0 | 667.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n5 | 5 | wifi-good | 10.2 | 14.8 | 20.4 | 28.3 | 13.7 | 33.8 | 14.8 | 320.0 | 573.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n10 | 10 | wifi-good | 11.7 | 16.6 | 24.1 | 27.7 | 29.9 | 31.8 | 28.0 | 360.0 | 554.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n2 | 2 | wifi-typical | 1.3 | 5.8 | 10.3 | 12.4 | 9.7 | 15.1 | 11.7 | 360.0 | 1039.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n3 | 3 | wifi-typical | 5.9 | 9.9 | 14.9 | 16.7 | 12.3 | 18.3 | 16.9 | 340.0 | 1299.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n5 | 5 | wifi-typical | 5.2 | 12.8 | 23.0 | 31.0 | 14.3 | 34.4 | 12.8 | 400.0 | 1147.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n10 | 10 | wifi-typical | 12.1 | 19.1 | 28.3 | 38.2 | 29.2 | 42.9 | 39.1 | 480.0 | 1400.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n2 | 2 | wifi-congested | 3.8 | 10.9 | 15.2 | 18.1 | 16.0 | 20.1 | 18.4 | 380.0 | 4812.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n3 | 3 | wifi-congested | 7.8 | 11.5 | 16.3 | 18.7 | 15.2 | 21.1 | 17.4 | 400.0 | 8532.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n5 | 5 | wifi-congested | 7.8 | 17.5 | 32.0 | 40.4 | 14.5 | 43.1 | 17.5 | 540.0 | 7038.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n10 | 10 | wifi-congested | 13.6 | 19.6 | 28.2 | 35.6 | 32.8 | 39.9 | 30.2 | 760.0 | 6633.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n2 | 2 | hotspot | 1.9 | 9.1 | 17.4 | 21.8 | 10.3 | 24.3 | 22.2 | 380.0 | 1796.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n3 | 3 | hotspot | 6.2 | 9.7 | 14.6 | 16.4 | 13.1 | 18.4 | 16.6 | 380.0 | 1778.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n5 | 5 | hotspot | 9.1 | 17.0 | 23.6 | 31.6 | 18.4 | 34.9 | 18.1 | 500.0 | 1758.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n10 | 10 | hotspot | 9.8 | 18.2 | 26.1 | 32.4 | 26.8 | 36.0 | 23.9 | 440.0 | 2031.0 | 1.0 | – | 0 | 0 |
| partition-recovery-n5 | 5 | wifi-typical | 8.6 | 10.3 | 16.4 | 23.8 | 27.4 | 27.4 | 8.6 | 640.0 | 1373.0 | 1.0 | 50.0 | 0 | 0 |
| coordinator-failure-n3 | 3 | wifi-good | 8.1 | 16.8 | 23.3 | 24.9 | 28.5 | 28.5 | 28.4 | 620.0 | 951.0 | 1.0 | – | 0 | 2 |
| coordinator-failover-n5 | 5 | wifi-typical | 8.5 | 11.0 | 17.9 | 23.8 | 24.3 | 27.4 | 19.5 | 500.0 | 1819.0 | 1.0 | – | 0 | 0 |
| heterogeneous-devices-n5 | 5 | wifi-typical | 17.1 | 47.3 | 50.0 | 56.9 | 35.1 | 57.8 | 20.2 | 700.0 | 1236.0 | 1.0 | – | 0 | 0 |
| bluetooth-uncalibrated-n2 | 2 | wifi-good | 186.4 | 187.6 | 187.7 | 187.7 | 5.1 | 5.1 | 187.2 | 600.0 | 724.0 | 1.0 | – | 1 | 0 |
| bluetooth-calibrated-n2 | 2 | wifi-good | 3.6 | 4.9 | 5.0 | 5.0 | 5.1 | 5.1 | 4.2 | 600.0 | 614.0 | 1.0 | – | 0 | 0 |
| listening-spot-uncalibrated-n4 | 4 | wifi-good | 186.8 | 187.2 | 187.2 | 187.2 | 7.3 | 7.3 | 187.2 | 600.0 | 630.0 | 1.0 | – | 1 | 0 |
| listening-spot-calibrated-n4 | 4 | wifi-good | 18.4 | 25.5 | 42.2 | 46.6 | 32.7 | 58.3 | 56.6 | 620.0 | 621.0 | 1.0 | – | 1 | 0 |
| channel-role-switch-n3 | 3 | wifi-good | 7.0 | 11.9 | 21.2 | 24.9 | 28.5 | 28.5 | 26.2 | 620.0 | 762.0 | 1.0 | – | 0 | 0 |
| drift-uncorrected-n3 | 3 | wifi-good | 64.7 | 134.2 | 145.2 | 148.3 | 18.4 | 28.3 | 148.0 | 620.0 | 258.0 | 1.0 | – | 0 | 0 |
| drift-corrected-n3 | 3 | wifi-good | 3.7 | 7.0 | 9.0 | 24.6 | 18.9 | 28.3 | 5.8 | 620.0 | 267.0 | 1.0 | – | 0 | 0 |

## Coordinator failover (SIMULATED)

| scenario | final epoch | last promoted | promoted after kill (ms) | spread p95 / max in 15 s after promotion (ms) |
|---|---|---|---|---|
| coordinator-failover-n5 | 3 | device-4 | 2015 | 9.0 / 9.1 |

## Listening-spot calibration (SIMULATED)

What reaches the listener (acoustic propagation at 343 m/s included). The main table's spread is the devices' *output* spread, which calibration deliberately increases: nearer speakers are delayed so every sound arrives at the listening spot together.

| scenario | spread at listener p50 | p95 | max |
|---|---|---|---|
| listening-spot-uncalibrated-n4 | 191.7 | 192.2 | 192.2 |
| listening-spot-calibrated-n4 | 4.6 | 22.0 | 43.1 |

All times in ms unless noted. Raw per-sample data: `<scenario>.samples.jsonl`; recompute with `tools/analyze_samples.py`.
