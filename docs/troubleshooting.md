# Troubleshooting

## Discovery: "Looking for rooms…" never finds the host

1. **Same network?** Both phones must be on the same Wi-Fi (same SSID *and* band can matter with mesh systems), or the
   guests must be on the host's hotspot.
2. **Client isolation.** Guest networks, hotels, cafés and many corporate APs block device-to-device traffic. Discovery
   *and* joining fail. Use a phone hotspot instead.
3. **Broadcast filtered.** Some APs drop broadcast or multicast even without isolation. Use **Join a party → Enter address
   and code**: the host's QR icon shows the address and code.
4. **Android multicast filtering.** The app holds a `MulticastLock` while in a room, but discovery on the home screen
   may still miss beacons on some OEM builds. Pull to refresh, or join by address.
5. **Hotspot subnets.** Beacons go to `255.255.255.255` and to each interface's `/24` broadcast address. Hotspots with
   larger or randomized subnets may need address entry.
6. **Check from a laptop:** `dart run bin/syncsphere_node.dart discover` (in `packages/syncsphere_core`) lists beacons
   seen on the network.

## Joining fails

- **The invite QR code does not open the app from the camera.** Some camera apps ignore custom `syncsphere://` links.
  Use **Join a party → Scan QR code** in SyncSphere, or copy the link and use **Join a party → Paste invite link**.
- **Joining from a QR code fails with "unreachable".** The link lists every address of the host; all were tried.
  The phones are probably on different networks (guest Wi-Fi isolation, or one on mobile data).

| Message | Cause | Fix |
|---|---|---|
| Wrong join key | Typo or old key | Keys ignore case, spaces and dashes; I/L→1 and O→0 are accepted. The key changes every time a room is created. |
| Too many failed attempts | 5 wrong keys per minute from your address | Wait a minute |
| The room is full | 16 devices by default | The host can raise `maxParticipants` |
| Coordinator could not be reached | Wrong IP, host left, firewall, isolation | Check the IP and port on the host and that both devices are on the same network |
| Handshake timeout | Very slow network, or key derivation on a slow phone | Retry |

## Playback

- **Phones drift apart after pause/resume, seeking or a late join (often with MP3s).** Older builds seeked VBR MP3
  approximately; current builds decode MP3/AAC to an exact copy first (event `track.exact` / `track.decoded` in
  Diagnostics). If you see "seeks may be inexact", decoding failed on that phone: send the diagnostics report.
- **Reporting a sync problem.** On every phone open Diagnostics, tap the copy icon (top right) and send the reports
  together with what you heard (which phone was early/late, by roughly how much, after what action).
- **One phone is audibly late but diagnostics say "in sync".** It is probably Bluetooth or a speaker with DSP latency;
  software cannot see that delay. On the **Speakers** tab, stand where you listen and tap **Calibrate to this spot**,
  then fine-tune by ear: tap the phone → **Timing** (+ plays earlier, − later). You can also measure the delay
  externally (docs/benchmarking.md §2) and enter it there.
- **Calibration says a device was not heard.** Its volume was too low, it is too far away, or the room was noisy.
  Raise that device's volume, move closer, and retry. Phones without an unprocessed microphone source apply noise
  suppression that can swallow quiet clicks.
- **Calibration button is disabled.** It needs control rights in the room and a microphone (`RECORD_AUDIO` is asked
  for on first use; if you denied it, allow it in Android settings).
- **Left/right channel sounds the same as stereo.** The role applies to stereo tracks only; mono files have one
  channel. A change takes effect with the next segment, which starts within about a second.
- **A phone never starts / shows "missing track".** In *Matching local files* mode every phone needs a byte-identical
  file: same encoding, same tags. The same song from a different source has a different SHA-256. Switch the room's
  audio source to *download from host*, or import the identical file.
- **Downloads fail.** The host must keep the app open. Large files are capped at 512 MiB. Check the host's diagnostics
  events for `transfer.*` messages.
- **Repeated "resync" events.** Common causes:
  - The device has no usable rate control (low-end/OEM decoders). Seeks above 45 ms are expected there.
  - The device is stalling: CPU contention or storage. Close other apps.
  - The Wi-Fi link is so poor that clock uncertainty is large. Move closer to the AP or use 5 GHz.
- **Brief warble right after starting.** That is rate correction pulling a device into alignment (maximum ±1.5 %,
  pitch preserved). It normally settles within a few seconds. Lower `maxRateDelta` if it is audible on your material.
- **Audio stops when the screen turns off.** The app runs a foreground service while in a room (look for the
  SyncSphere notification). If audio still stops, the vendor's battery manager is killing it: disable battery
  optimization for SyncSphere. On Android 13+ the notification only shows if notifications are allowed.
- **Notification buttons do nothing.** They are room controls: listeners cannot use them unless the host grants
  control.
- **Audio pauses during a phone call.** The OS takes the audio output. When it returns, the engine detects the
  position error and resynchronizes.

## Android audio behavior notes

- `getCurrentPosition()` updates about every 10 ms in 1 ms steps. The plugin combines 7 readings to reach about 1–2 ms.
- During the first ~1 s after a start, `AudioTrack` timestamps may be unavailable; drift correction waits 1.2 s
  (`settleTime`).
- Wi-Fi power save causes 100+ ms downlink spikes. The app requests `WIFI_MODE_FULL_LOW_LATENCY` (Android 10+), which
  only works while the app is in the foreground with the screen on.
- Speed changes take effect after the already-buffered audio (~100–250 ms) has played.

## Development environment

- **Android SDK unavailable** (as in this repo's cloud development container: `dl.google.com` was blocked). Build the
  APK on GitHub Actions (`.github/workflows/ci.yml`, artifact `syncsphere-apks`), or allow `dl.google.com` in the
  environment's network settings and install the SDK.
- **Claude Code cloud sessions.** `.claude/settings.json` registers a SessionStart hook
  (`scripts/cloud-session-start.sh`) that makes sure Flutter is on `PATH` and runs `pub get` for all three packages.
  It does nothing outside the cloud environment.
- **`flutter test` on Linux fails to open SQLite.** Install `libsqlite3-dev`.
- **Run everything except Android locally:**

  ```bash
  cd packages/syncsphere_core && dart test
  cd packages/syncsphere_audio && flutter test
  cd app && flutter test
  ```
