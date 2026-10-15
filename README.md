# SyncSphere

**Synchronized multi-phone music playback over a local network.** Every phone in a room decodes and plays the same
track itself. The phones form one sound system, without internet access, cloud servers or streaming services.

The hard part, and the focus of this project, is keeping independent devices aligned despite unknown clock offsets,
asymmetric Wi-Fi delay, device-specific audio latency, clock drift and failures. SyncSphere does this with a
coordinator-owned **playback timeline** scheduled in the future, NTP-style clock estimation with honest uncertainty
bounds, natively scheduled play calls, and closed-loop drift correction.

> **Status (October 2026).** The core protocol and algorithms are implemented and tested (unit tests, real-socket
> integration tests, and a virtual-time simulator with ground truth). The Flutter app and the Android Media3 plugin are
> implemented. The APK is built by CI, because the development container could not reach the Android SDK.
> **Nothing has been measured on real phones yet.** Every quantitative result in this repository is either simulated
> or a unit test, and is labelled as such. See [docs/benchmarking.md](docs/benchmarking.md) for the real-device
> procedure.

## What works

- **Rooms:** create a room on one phone; others find it by UDP discovery or join by address. Joining needs a join key
  (HMAC challenge-response, PBKDF2-derived key, per-frame MACs, replay protection).
- **Synchronized start:** a readiness barrier makes sure every phone has the track prepared. The coordinator then picks
  a start time far enough ahead, sized from *measured* round-trip, latency and clock-uncertainty figures. Each phone
  converts that time into its own clock and fires the native `ExoPlayer.play()` early by its learned output latency.
- **Pause, resume, seek, previous/next, auto-advance:** all are versioned, scheduled timeline changes. Seeks and track
  changes use a pre-buffered standby player.
- **Drift correction:** stays idle inside ±8 ms; above that, pitch-preserving rate trim (±1.5 %) with hysteresis; only
  for large errors, a controlled resync with a cooldown.
- **Fault handling:**
  - heartbeats, with suspect/failed detection on both sides
  - reconnection with exponential backoff
  - playback that continues on the last timeline while disconnected
  - rejection of stale, duplicate and reordered messages
  - role-based control authorization and per-address rate limits
  - an explicit "room needs to be recreated" when the coordinator is gone
- **Audio distribution:** tracks are identified by SHA-256. Either every phone has the file ("matching local files"),
  or the host serves it over HTTP with `Range` resume, per-session signed URLs, verification and an LRU cache.
- **Observability:** structured event log, per-device sync reports, a room-wide diagnostics broadcast, and a
  diagnostics screen that labels every estimate as an estimate.
- **Benchmarks:** a deterministic simulated suite (2/3/5/10 devices × 5 network models, faults, drift, heterogeneous
  devices, Bluetooth), plus stdlib-only Python tools for raw-data analysis and acoustic measurement on real phones.

Simulated highlights: steady-state inter-device spread p95 of 5–21 ms across the matrix, and 60-minute drift held to
6.6 ms p95 versus 149 ms uncorrected. These come from modelled devices and networks, not hardware; see
[benchmarks/results/simulated/summary.md](benchmarks/results/simulated/summary.md).

## Repository layout

| Path | What |
|---|---|
| [`packages/syncsphere_core`](packages/syncsphere_core) | Pure Dart: protocol, clock sync, coordinator, participant engine, drift control, distribution, discovery, simulator, CLI tools |
| [`packages/syncsphere_audio`](packages/syncsphere_audio) | Flutter plugin: Kotlin Media3 engine plus the Dart `AudioBackend` |
| [`app`](app) | Flutter app (Riverpod, sqflite): Home, Room, Player and Diagnostics screens |
| [`docs`](docs) | Architecture, protocol, state machines, Android audio, benchmarking, threat model, roadmap, troubleshooting |
| [`benchmarks/results`](benchmarks/results) | Committed raw and summary benchmark data (simulated, labelled) |
| [`tools`](tools) | `analyze_samples.py`, `onset_skew.py`, `make_click_track.py` (Python stdlib only) |

## Requirements

- Flutter **3.47.5** (Dart 3.13.4). CI pins this version.
- To build the APK: Android SDK with platform 36, and JDK 17+ (CI uses Temurin 21). Gradle and AGP come from the
  Flutter template (AGP 9.1, Gradle 9.3.1).
- Phones: Android 7.0+ (API 24), all on the same Wi-Fi or one phone's hotspot.

## Build and run

```bash
# Core: tests and simulated benchmarks (no Flutter or Android needed, only the Dart SDK)
cd packages/syncsphere_core
dart pub get
dart test
dart run bin/benchmark.dart --suite quick --out ../../benchmarks/out

# Plugin (Dart side) and app tests
cd ../syncsphere_audio && flutter pub get && flutter test
cd ../../app && flutter pub get && flutter test     # needs libsqlite3 on Linux

# Android APK (needs the Android SDK)
cd app
flutter build apk --release        # debug-signed; for sideloading tests
flutter install                    # or: adb install build/app/outputs/flutter-apk/app-release.apk
```

**No Android SDK locally?** Every push runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml). It builds
`app-debug.apk` and `app-release.apk` and uploads them as the `syncsphere-apks` artifact on the workflow run page.
Download that artifact and install it with `adb install` or a file manager.

### Using the app

1. Install the app on 2+ phones on the same Wi-Fi or hotspot.
2. On every phone, **Import** the same audio files. Identical files match by content. Alternatively, import only on the
   host and choose *"Local file, else download from host"*.
3. Host: **Create room**. The room screen shows the join key and the host address.
4. Others: tap the room under **Nearby rooms** (or **Join by address**) and enter the key.
5. Open **Player** and press play. All phones start together at a scheduled instant.
6. **Diagnostics** shows clock offsets ± uncertainty, estimated playback error, correction mode and recent events per
   device.

### Headless node (laptop as coordinator or probe)

```bash
cd packages/syncsphere_core
dart run bin/syncsphere_node.dart host --name "Living room" --track ~/Music/a.mp3 --open-control
dart run bin/syncsphere_node.dart join --host 192.168.1.20 --key ABCD-1234 --play --report-json est.jsonl
dart run bin/syncsphere_node.dart discover
```

The headless node follows the timeline but plays no sound. It can act as a dedicated coordinator or log
software-estimated sync data during real-device benchmarks.

## Permissions and network configuration

| Permission | Why |
|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE` | Local control channel (WebSocket), track delivery (HTTP), discovery (UDP) |
| `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` | `MulticastLock` so broadcast discovery packets get through |
| `WAKE_LOCK` | ExoPlayer wake mode, and a low-latency `WifiLock` while in a room |

Ports:

- TCP **47800**: WebSocket `/ws` plus HTTP `/tracks/*`. If 47800 is busy, an ephemeral port is used and shown on the
  room screen.
- UDP **47801**: discovery beacons.

All traffic stays on the LAN. No cleartext traffic leaves the device for the internet, because there is none.

## Documentation

- [Architecture](docs/architecture.md): components, data flow, sequence diagrams, clock sync, scheduling, drift,
  risks, milestones
- [Protocol specification and message schemas](docs/protocol.md)
- [State machines and sequences](docs/state-machines.md)
- [Android audio investigation and limitations](docs/android-audio.md)
- [Benchmarking: simulated and real-device procedure](docs/benchmarking.md)
- [Threat model, security and limitations](docs/threat-model.md)
- [Roadmap: failover, precision backend, calibration, spatial audio](docs/roadmap.md)
- [Troubleshooting: discovery and Android audio](docs/troubleshooting.md)

## Known blockers and next steps

1. **Real-device measurements.** Run the protocol in [docs/benchmarking.md](docs/benchmarking.md) with 2 phones first,
   then 3–10. Commit raw data to `benchmarks/results/real/`.
2. **Native code on hardware.** The Kotlin plugin is compiled and unit-tested in CI only. Verify start-latency learning
   and position sampling on a few device models.
3. **Coordinator failover.** Designed ([roadmap](docs/roadmap.md#coordinator-failover-milestone)), not implemented.
   Today the room reports that it must be recreated.
4. **Background playback** via a foreground media service.

Only share music you are authorized to share.
