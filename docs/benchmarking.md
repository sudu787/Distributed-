# Benchmarking SyncSphere

There are three kinds of numbers. Never mix them up in a report:

| Kind | Where it comes from | What it can claim |
|---|---|---|
| **Simulated ground truth** | `bin/benchmark.dart`: the real protocol and engine code running against modelled clocks, network and audio devices in virtual time | How the algorithms behave under the modelled conditions. Not hardware performance. |
| **Software-estimated (real devices)** | `rep`/`diag` messages and the diagnostics screen: player-reported position compared with the timeline through the estimated clock offset | How well devices *believe* they are aligned. Blind to unreported output latency (Bluetooth, DSP). |
| **Acoustic (real devices)** | A multichannel recording of the phones' speakers, analyzed by `tools/onset_skew.py` | What a listener actually hears, minus room acoustics. |

## 1. Simulated benchmarks (run in the cloud, no phones needed)

```bash
cd packages/syncsphere_core
dart run bin/benchmark.dart --suite quick --out ../../benchmarks/out             # ~6 s
dart run bin/benchmark.dart --suite full  --out ../../benchmarks/results/simulated --sample-every 10   # ~20 s
python3 ../../tools/analyze_samples.py ../../benchmarks/results/simulated/matrix-wifi-good-n5.samples.jsonl
```

The suite is deterministic for a given `--seed` (default 42). It covers:

- **Participant counts:** 2, 3, 5 and 10 (index 0 is the host, which also plays) × the network models `lan-ideal`,
  `wifi-good`, `wifi-typical` (asymmetric, power-save spikes, 0.5 % loss), `wifi-congested` (asymmetric, 2 % loss,
  spikes up to 250 ms) and `hotspot`.
- **Standard script:** play at 3 s, pause at 40 s, resume at 46 s, seek to 3:00 at 70 s, next track at 95 s,
  120 s total.
- **Faults:** 5 s and 20 s silent partitions; coordinator process killed.
- **Device heterogeneity:** flagship, midrange and low-end profiles (the low-end one has no rate control and
  stalls 6 times an hour).
- **Output latency:** uncalibrated vs. calibrated Bluetooth (180 ms of unreported latency).
- **Drift over 60 min:** ±100 ppm clock skew and ±80 ppm audio-clock error, with correction disabled vs. enabled.

**Metrics** (all from ground truth unless noted):

- inter-device spread (max − min acoustic error at the same instant, sampled every 50 ms), overall and in steady state
  (excluding 3 s after each timeline change)
- pairwise error and absolute error vs. the timeline
- start skew per generation
- drift in the first and last minute
- command → audible latency
- clock offset error vs. the reported uncertainty (coverage)
- recovery after a partition
- resync seeks, rate changes and stalls
- network frames and bytes

CPU and memory are not meaningful in simulation; measure them on phones (§3).

Committed results: [`benchmarks/results/simulated/summary.md`](../benchmarks/results/simulated/summary.md).
Highlights (SIMULATED):

- Steady-state spread p95 of 5–21 ms across all 20 matrix cells (2–10 devices, all five networks). This sits inside the
  50 ms target and close to the 20 ms stretch goal, *under the modelled assumptions*.
- Start skew grows with device count (p50 ≈ 8–17 ms with 2–3 devices, ≈ 21–32 ms with 10). It is dominated by the
  modelled per-start latency jitter of the audio pipeline, not by the network. Rate correction then pulls devices
  together within seconds, which is why steady-state spread is lower than start skew.
- Without drift correction, spread reaches 149 ms after 60 min. With correction, p95 is 6.6 ms.
- An uncalibrated Bluetooth device sits ~185 ms behind acoustically while software reports it in sync. A calibration
  offset fixes this (spread ≈ 4 ms).
- The reported clock uncertainty contained the true offset in ≥ 99.9 % of samples in every scenario. It is
  conservative. Actual offset error p95 ranged from 0.1 ms (`lan-ideal`) to 8.5 ms (`wifi-congested`); median
  reported uncertainty ranged from 0.7 ms to 11 ms.

## 2. Real-device protocol

Equipment:

- N Android phones (8+, minSdk 24), with the APK from the CI artifact `syncsphere-apks`
- one Wi-Fi AP (or one phone's hotspot), recorded: AP model, band and channel, distance
- for acoustic runs, an audio interface with ≥ N inputs on one sample clock, plus N small microphones (lavalier or
  measurement), *or* a stereo recorder for pairwise runs (one phone in each channel)

Preparation:

1. Install the same APK on all phones. Disable battery optimization for SyncSphere. Keep screens on, at maximum
   brightness setting so the screen does not dim. Turn off Bluetooth unless Bluetooth is what you are testing.
2. Generate the click track: `python3 tools/make_click_track.py click.wav --minutes 10`. Import it on the host (or
   all phones for `localOnly` runs). Its SHA-256 is identical everywhere.
3. Tape one microphone directly over each phone's loudspeaker grille. This makes propagation < 0.1 ms; 1 m of air
   adds 2.9 ms.

Per run:

1. Create the room on the host and join with the others. Record the device models and Android versions.
2. Start recording, press play, let it run (≥ 5 min for drift, ≥ 30 min for long-duration runs), then perform the
   script: pause, resume, seek, next.
3. On every phone, export the event log. The diagnostics screen lists recent events, and the debug build prints them
   to `adb logcat`.
4. Analyze:

```bash
python3 tools/onset_skew.py run1.wav --names host,pixel7,a14,moto --out run1.samples.jsonl
python3 tools/analyze_samples.py run1.samples.jsonl
```

Conditions to vary (one at a time): device count (2, 3, 5, 10), AP vs. hotspot, a congested channel (another device
streaming video), distance and walls, a phone walking out of range and back (recovery time), host killed (failure
reporting), low-end devices, and Bluetooth (with and without calibration).

Software-estimated companion data: run `dart run bin/syncsphere_node.dart join --host <ip> --key <key>
--report-json est.jsonl` on a laptop in the room to log offsets, uncertainty and RTT, or capture `rep` values from logcat.

Resource use on phones:

```bash
adb shell dumpsys cpuinfo | grep syncsphere
adb shell dumpsys meminfo dev.syncsphere.syncsphere
adb shell cat /proc/net/xt_qtaguid/stats      # or: adb shell dumpsys netstats detail
```

## 3. Reporting template

For every result, state:

- what kind of number it is (simulated / software-estimated / acoustic)
- the devices (model, Android version)
- the network
- duration and N
- median, p95, p99 and max spread, plus start skew
- the raw files

Keep raw recordings or JSONL next to the summary in `benchmarks/results/real/<date>-<setup>/`.

## 4. Status

- Real-device results: **none yet.** The development container has no phones and no Android SDK. CI builds the APK.
- Next concrete steps:
  1. Run §2 with 2 phones (stereo recorder) to validate the end-to-end path.
  2. Replace the simulated device profiles' start latency, jitter and position noise with measured values (the
     `started` events report the per-device start error).
  3. Rerun the simulated suite with the measured profiles.
  4. Run 3, 5 and 10 phones with a multichannel interface.
