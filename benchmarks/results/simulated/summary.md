# SyncSphere simulated benchmark results

> **SIMULATED — virtual time, modelled clocks/network/audio devices. NOT hardware measurements.**  
> suite `full`, seed `42`, generated 2026-10-15T18:18:32.328147Z  
> Spread = max − min acoustic (ground-truth) position error across devices at the same instant, sampled every 50 ms. "Steady" excludes 3 s after each timeline change.

| scenario | n | network | spread p50 | spread p95 | spread p99 | spread max | start skew p50 | start skew max | last-min p95 | cmd→audible p50 | clock err p95 (µs) | unc. coverage | recovery max | resyncs | failed |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| matrix-lan-ideal-n2 | 2 | lan-ideal | 3.3 | 5.0 | 19.3 | 26.9 | 8.5 | 29.8 | 5.0 | 360.0 | 92.0 | 1.0 | – | 0 | 0 |
| matrix-lan-ideal-n3 | 3 | lan-ideal | 3.8 | 14.1 | 17.5 | 24.0 | 12.0 | 27.6 | 14.1 | 340.0 | 144.0 | 1.0 | – | 0 | 0 |
| matrix-lan-ideal-n5 | 5 | lan-ideal | 5.7 | 14.5 | 37.0 | 50.5 | 17.0 | 56.7 | 13.7 | 340.0 | 179.0 | 1.0 | – | 0 | 0 |
| matrix-lan-ideal-n10 | 10 | lan-ideal | 12.1 | 16.5 | 23.6 | 32.5 | 23.9 | 37.2 | 22.2 | 360.0 | 143.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n2 | 2 | wifi-good | 4.7 | 11.2 | 19.0 | 26.6 | 18.5 | 29.5 | 17.9 | 360.0 | 457.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n3 | 3 | wifi-good | 3.9 | 14.4 | 17.6 | 24.2 | 15.6 | 27.7 | 14.4 | 320.0 | 527.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n5 | 5 | wifi-good | 5.3 | 14.3 | 36.5 | 50.0 | 16.7 | 56.8 | 13.2 | 360.0 | 443.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-good-n10 | 10 | wifi-good | 11.1 | 15.0 | 23.8 | 32.5 | 23.5 | 37.5 | 18.2 | 360.0 | 615.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n2 | 2 | wifi-typical | 3.7 | 11.2 | 18.2 | 25.9 | 17.7 | 30.7 | 18.3 | 420.0 | 1509.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n3 | 3 | wifi-typical | 2.6 | 13.0 | 16.2 | 22.8 | 15.6 | 26.6 | 13.1 | 340.0 | 1302.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n5 | 5 | wifi-typical | 7.6 | 14.2 | 35.5 | 48.9 | 22.6 | 55.9 | 22.4 | 400.0 | 1091.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-typical-n10 | 10 | wifi-typical | 12.0 | 18.0 | 29.5 | 35.5 | 30.5 | 38.0 | 22.9 | 820.0 | 1423.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n2 | 2 | wifi-congested | 3.2 | 12.9 | 24.3 | 30.1 | 16.4 | 32.2 | 25.9 | 400.0 | 5424.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n3 | 3 | wifi-congested | 6.2 | 9.2 | 16.7 | 20.2 | 18.5 | 25.3 | 12.6 | 500.0 | 7776.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n5 | 5 | wifi-congested | 9.1 | 15.9 | 32.1 | 46.4 | 20.8 | 53.3 | 18.6 | 680.0 | 5922.0 | 1.0 | – | 0 | 0 |
| matrix-wifi-congested-n10 | 10 | wifi-congested | 15.9 | 17.5 | 26.4 | 32.9 | 23.4 | 37.5 | 27.4 | 800.0 | 7196.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n2 | 2 | hotspot | 4.2 | 5.8 | 18.8 | 26.3 | 8.7 | 31.1 | 5.8 | 400.0 | 1997.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n3 | 3 | hotspot | 7.2 | 11.2 | 17.8 | 21.9 | 20.9 | 26.0 | 18.8 | 360.0 | 2158.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n5 | 5 | hotspot | 8.6 | 16.3 | 38.0 | 51.6 | 24.0 | 57.1 | 27.2 | 500.0 | 1622.0 | 1.0 | – | 0 | 0 |
| matrix-hotspot-n10 | 10 | hotspot | 11.7 | 16.6 | 24.8 | 33.3 | 22.3 | 38.0 | 22.1 | 560.0 | 1888.0 | 1.0 | – | 0 | 0 |
| partition-recovery-n5 | 5 | wifi-typical | 8.8 | 10.1 | 20.1 | 28.6 | 31.4 | 31.4 | 8.8 | 640.0 | 1323.0 | 1.0 | 50.0 | 0 | 0 |
| coordinator-failure-n3 | 3 | wifi-good | 6.9 | 6.9 | 6.9 | 6.9 | 8.6 | 8.6 | 8.6 | 600.0 | 826.0 | 1.0 | – | 0 | 2 |
| coordinator-failover-n5 | 5 | wifi-typical | 4.5 | 10.1 | 20.7 | 28.6 | 19.2 | 31.4 | 7.1 | 560.0 | 1649.0 | 1.0 | – | 0 | 0 |
| failover-failback-n3 | 3 | wifi-typical | 5.9 | 8.5 | 8.6 | 8.7 | 13.8 | 19.5 | 8.6 | 520.0 | 1812.0 | 1.0 | – | 0 | 0 |
| heterogeneous-devices-n5 | 5 | wifi-typical | 16.6 | 21.8 | 28.6 | 45.2 | 23.6 | 47.4 | 10.3 | 700.0 | 1261.0 | 0.9992 | – | 0 | 0 |
| bluetooth-uncalibrated-n2 | 2 | wifi-good | 185.9 | 187.1 | 187.2 | 187.2 | 4.9 | 4.9 | 186.8 | 600.0 | 597.0 | 1.0 | – | 1 | 0 |
| bluetooth-calibrated-n2 | 2 | wifi-good | 3.4 | 4.7 | 4.8 | 4.8 | 4.9 | 4.9 | 3.9 | 600.0 | 614.0 | 1.0 | – | 0 | 0 |
| listening-spot-uncalibrated-n4 | 4 | wifi-good | 185.7 | 186.2 | 186.2 | 186.2 | 10.7 | 10.7 | 186.2 | 600.0 | 624.0 | 1.0 | – | 1 | 0 |
| listening-spot-calibrated-n4 | 4 | wifi-good | 17.6 | 20.9 | 29.1 | 31.3 | 22.6 | 34.5 | 34.5 | 580.0 | 647.0 | 1.0 | – | 1 | 0 |
| channel-role-switch-n3 | 3 | wifi-good | 6.0 | 17.6 | 19.2 | 19.2 | 8.6 | 8.6 | 16.9 | 600.0 | 643.0 | 1.0 | – | 0 | 0 |
| drift-uncorrected-n3 | 3 | wifi-good | 83.3 | 152.8 | 160.2 | 163.3 | 6.8 | 8.5 | 157.5 | 600.0 | 258.0 | 1.0 | – | 0 | 0 |
| drift-corrected-n3 | 3 | wifi-good | 4.2 | 7.6 | 9.1 | 16.2 | 13.1 | 17.8 | 7.4 | 600.0 | 270.0 | 1.0 | – | 0 | 0 |

## Coordinator failover (SIMULATED)

| scenario | final epoch | final coordinator | last promoted | promoted after kill (ms) | spread p95 / max in 15 s after promotion (ms) | handed back to | spread p95 / max in 15 s after handback (ms) |
|---|---|---|---|---|---|---|---|
| coordinator-failover-n5 | 3 | device-2 | device-2 | 2014 | 4.1 / 4.1 | – | – |
| failover-failback-n3 | 3 | device-0 | device-1 | 2045 | 2.7 / 2.7 | device-0 | 6.0 / 6.0 |

## Listening-spot calibration (SIMULATED)

What reaches the listener (acoustic propagation at 343 m/s included). The main table's spread is the devices' *output* spread, which calibration deliberately increases: nearer speakers are delayed so every sound arrives at the listening spot together.

| scenario | spread at listener p50 | p95 | max |
|---|---|---|---|
| listening-spot-uncalibrated-n4 | 190.7 | 191.1 | 191.2 |
| listening-spot-calibrated-n4 | 4.2 | 10.9 | 21.4 |

All times in ms unless noted. Raw per-sample data: `<scenario>.samples.jsonl`; recompute with `tools/analyze_samples.py`.
