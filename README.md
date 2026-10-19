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
  - **coordinator failover by succession**: if the host crashes, the first eligible guest takes over at epoch + 1,
    with the timeline translated into its clock, and playback keeps running
  - **handback**: when the original host comes back ("Rejoin your party" after a crash, or its Wi-Fi returns), the
    stand-in hands the host role back after 10 s of stable connection, without interrupting the music; a stand-in
    that leaves hands the party on instead of ending it
  - an explicit "room needs to be recreated" when no successor is available
- **Audio distribution:** tracks are identified by SHA-256. Either every phone has the file ("matching local files"),
  or the host serves it over HTTP with `Range` resume, per-session signed URLs, verification and an LRU cache.
- **Exact seeking for MP3/AAC:** each phone decodes MP3 and raw AAC files once into a cached PCM copy, because
  ExoPlayer seeks VBR MP3 only approximately (up to hundreds of ms) while reporting the requested position.
- **Listening-spot calibration:** "Calibrate to this spot" makes every phone click in turn, records them with this
  phone's microphone, and shifts each device so the sound lines up *where you are*, including Bluetooth and speaker
  delays software cannot see. Simulated (4 phones at 0.3–7 m, one on Bluetooth): spread at the listener 192 ms →
  4.6 ms median (p95 22 ms, mostly the first seconds while devices re-converge). Not yet run on phones.
- **Experimental channel roles:** each phone can play stereo, left, right or a mono mix (Media3 channel mixing).
- **Repeat (off/all/one) and shuffle**, coordinated by the room.
- **Guests can add songs:** everyone the host allows to control the music (**Guests can control** at start, or per
  phone on the Speakers tab) can add songs from their own phone; they are sent to the host and from there to everyone.
- **Phone-to-phone sharing:** songs travel between guests in verified 512 KiB chunks (rarest first, BitTorrent-style).
  With many phones the host's Wi-Fi is no longer the bottleneck, and songs survive the host leaving.
- **Open music sources:** **Search Audius** (free music from independent artists, credited) or **From a link** (your
  own Navidrome or Jellyfin server, a podcast, any direct audio link). Every phone downloads the song from the source
  itself, so sync stays sample-exact; the host is the fallback. Spotify and YouTube can't be used this way, because of
  DRM and their terms; see [research-next.md](docs/research-next.md).
- **Recent parties:** the last 5 parties are listed on the home screen. A party that is still running shows **Online**
  and rejoins with one tap (also after another phone took over as host).
- **Album art** from each song's embedded picture (colourful placeholder otherwise), and **vibration feedback** on
  controls and when the song changes (Settings → Vibration feedback).
- **Back button** asks before closing the app; in a party it offers *Keep playing in the background* or *Leave*.
- **Background playback:** a foreground media service with a notification (room name, track, previous/play/next)
  keeps the room running with the screen off.
- **QR invites:** the host shows a QR code / link containing address, port and key; guests scan it in the app,
  open it from the camera (`syncsphere://` deep link) or paste it.
- **Observability:** structured event log, per-device sync reports, a room-wide diagnostics broadcast, and a
  diagnostics screen that labels every estimate as an estimate.
- **Benchmarks:** a deterministic simulated suite (2/3/5/10 devices × 5 network models, faults, drift, heterogeneous
  devices, Bluetooth), plus stdlib-only Python tools for raw-data analysis and acoustic measurement on real phones.

Simulated highlights: steady-state inter-device spread p95 of 5–20 ms across the matrix, and 60-minute drift held to
7.0 ms p95 versus 148 ms uncorrected. These come from modelled devices and networks, not hardware; see
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

1. Install the app on 2+ phones on the same Wi-Fi or one phone's hotspot.
2. Host phone: **My music → Add** to pick songs (guests need no music; they get it from the host).
3. Host: **Host a party → Start**, then tap the **QR icon** (or **Invite** on the Speakers tab).
4. Guests: **Join a party → Scan QR code**. Nearby parties are also listed on the home screen.
5. The party has three tabs:
   - **Playing:** play/pause, seek, skip, shuffle, repeat, volume for everyone and for this phone.
   - **Queue:** the songs; the host, and guests allowed to control, add more with **Add songs**.
   - **Speakers:** every phone and its sync state. **Calibrate to this spot** lines the sound up where you stand.
     Tap a phone to set its volume, **timing** (fine-tune by ear: + plays earlier, − later) and channel.
6. Something sounds off? On the Playing tab tap **This phone sounds early or late?**. For bug reports, open
   **⋮ → Diagnostics** on each phone and tap the copy icon.

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
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Background playback service while in a room |
| `POST_NOTIFICATIONS` | Shows that service's notification (Android 13+, asked at runtime; optional) |
| `RECORD_AUDIO` | Only for "Calibrate to this spot", asked when you start one; the recording never leaves the phone |
| `CAMERA` | Only for scanning an invite QR code (from `mobile_scanner`) |

Ports:

- TCP **47800**: WebSocket `/ws` plus HTTP `/tracks/*`. If 47800 is busy, an ephemeral port is used and shown in the
  host's invite (QR icon).
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
- [Comparison with similar apps (AmpMe, SoundSeeder, Auracast, …) and a fair test plan](docs/comparison.md)
- [Research: next distributed-systems techniques, Spotify/YouTube/DRM findings, open music sources](docs/research-next.md)

## Known blockers and next steps

1. **Real-device measurements.** Run the protocol in [docs/benchmarking.md](docs/benchmarking.md) with 2 phones first,
   then 3–10. Commit raw data to `benchmarks/results/real/`.
2. **Native code on hardware.** The Kotlin plugin is compiled and unit-tested in CI only. Verify start-latency learning
   and position sampling on a few device models.
3. **Failover and handback on hardware.** Takeover, handback to the original host, hand-off and step-down are
   implemented and tested in simulation and over loopback sockets, but not on phones. It is not consensus: during a
   partition both sides keep playing until beacons cross again ([roadmap](docs/roadmap.md#coordinator-failover-milestone)).
4. **New features on hardware.** Acoustic calibration, channel roles, background playback and QR invites are
   unit-tested and simulated (calibration, roles) but have not run on phones. Calibration in particular needs
   checking against microphones with heavy built-in processing.

Only share music you are authorized to share.
