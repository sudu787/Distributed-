# Android audio: Media3 investigation, timing model and limitations

Implementation: `packages/syncsphere_audio/android/src/main/kotlin/dev/syncsphere/syncsphere_audio/`.
Media3 version: **1.10.1**, pinned (Media3 1.9+ requires `minSdk 23`; the app uses 24).

## What Media3/ExoPlayer gives us

| Need | Media3 capability used | Notes and limits |
|---|---|---|
| Start a prepared stream with low and stable latency | Prepare a player paused (`playWhenReady = false`) at the start position, wait for `STATE_READY`, then call `play()` at the target instant | While paused and ready, ExoPlayer has already decoded and queued audio. The remaining latency is message passing to the playback thread, `AudioTrack.play()`, and the mixer/HAL buffers. It is device-dependent (tens to 100+ ms), so it is *learned*. |
| Execute the play call at a precise instant | Our own `HandlerThread` (`THREAD_PRIORITY_URGENT_AUDIO`) is the players' application looper. `Handler.postAtTime(target − 3 ms)` is followed by a busy-wait on `System.nanoTime()`. | `postAtTime` has millisecond resolution and a few ms of jitter. The bounded spin takes the play call to sub-millisecond precision. The actual call time is reported back (`playCalled.atNanos`). |
| Know what is audible now | `Player.getCurrentPosition()`. During playback it comes from the audio renderer clock, which `DefaultAudioSink` derives from `AudioTrack.getTimestamp()` (the frame presented at a given `nanoTime`) when available, interpolated otherwise. | Millisecond resolution, refreshed about every 10 ms. `PositionEstimator` takes 7 readings 2 ms apart, projects them forward and keeps the freshest lower bound: about 1–2 ms error (JVM unit test). During the first ~0.5–1 s after a start, timestamps may be unavailable and positions are less reliable, so the engine ignores the first 1.2 s (`settleTime`). |
| Gradual correction | `setPlaybackParameters(PlaybackParameters(speed))` with pitch 1.0 uses the Sonic time-stretcher, so pitch is preserved | Takes effect after already-buffered audio drains (~100–250 ms). Capped at ±1.5 % by default. Very tonal content may reveal stretching artifacts; lower `maxRateDelta` if audible. |
| Seamless scheduled seek or track change | Two player instances (active and standby). The standby is prepared at the target position; at the switch instant the active is paused (then released after 400 ms) and the standby started. | Two decoders exist briefly. The resume path reuses the paused player when it is already at the requested position. |
| Accurate seek positions | `DefaultExtractorsFactory.setMp3ExtractorFlags(FLAG_ENABLE_INDEX_SEEKING)` and `setConstantBitrateSeekingEnabled(true)` | Without index seeking, VBR MP3s lacking a seek table land at an estimated byte offset while reporting the requested time, a silent error of up to seconds. Index seeking scans the file once (fine for local files). |
| Do not get paused behind the room's back | `setAudioAttributes(…, handleAudioFocus = false)`, `setHandleAudioBecomingNoisy(false)` | Another app's audio will mix with ours rather than pause it. A phone call still interrupts audio at the OS level; the engine then sees a stall or position error and resyncs. |
| Stay awake | `setWakeMode(C.WAKE_MODE_LOCAL)`; the screen is kept on while in a room | Background playback needs a foreground `MediaSessionService` ([roadmap](roadmap.md)). |

APIs considered and not used (yet):

- **`AudioTrack.getTimestamp()` directly with our own decoder (MediaCodec → AudioTrack).** This gives frame-exact
  scheduling: write silence until the target frame is due. It is the strongest option for sub-5 ms alignment, but it
  means writing our own decoding, resampling and buffering pipeline. ExoPlayer already uses those timestamps
  internally, and closed-loop correction removes its start variance within seconds. Listed in the roadmap as the
  "precision backend".
- **AAudio/Oboe with `AAudioStream_getTimestamp`.** Lowest latency, but no decoder. It would sit under the same custom
  pipeline as above.
- **A custom `AudioSink` wrapper** reporting `getCurrentPositionUs` together with `nanoTime` from the playback thread.
  This would avoid the millisecond quantization, but it relies on renderer-time offsets that changed between Media3
  releases, so it was left out until it can be tested on devices.

## Clock domains on the device

```
Dart isolate monotonic (Stopwatch, µs, epoch = process start)
        │  ClockDomainBridge: bracket native reads between Dart reads, 24 samples at start,
        │  6 every 30 s; uncertainty = ½ shortest bracket (typically < 0.2 ms)
        ▼
System.nanoTime() (CLOCK_MONOTONIC) — used by Handler scheduling, ExoPlayer positions, AudioTimestamp
```

Both clocks stop in deep sleep, which does not happen while audio plays.

## Measured vs. assumed

Nothing on this page has been measured on real phones yet. The Android SDK and Google Maven were not reachable from
the development container, so the native code is compiled and unit-tested by CI only. The simulation's device
profiles (start latency 45–140 ms, jitter 6–35 ms, position noise 0.8–4 ms) are **assumptions** to be replaced by
measurements from [benchmarking.md](benchmarking.md).

## Known platform limitations

1. **Bluetooth and some USB/HDMI outputs** add latency that `AudioTrack` timestamps may not include (often 100–250 ms
   for A2DP, varying by codec and device). Software alignment cannot see it. The app warns when a Bluetooth output is
   present; **Calibrate to this spot** (room screen) measures it with a microphone, and a manual per-device offset is
   still available. Simulation shows a ~185 ms error without calibration and ~4 ms with it.
2. **Phone speaker DSP** (loudness, virtualizers) can add a few ms that differs between models. This also needs
   acoustic calibration.
3. **Start-latency variance per start** remains after learning (assumed ±6–35 ms). Rate correction removes it within
   seconds; the initial seconds of each start carry it.
4. **Devices without usable speed change** fall back to seeks above 45 ms. Every seek is audible.
5. **OEM battery optimizations** can still throttle the app with the screen off, even with the foreground service
   below. Some vendors (aggressive "app killers") need the app exempted from battery optimization by hand.

## Seeking accuracy and exact-seek copies

ExoPlayer seeks VBR MP3 through the Xing table of contents: 100 entries, each quantized to 1/256 of the file size.
On a 4-minute song one entry step is about 0.4 % of the file, so a seek can land **hundreds of milliseconds** from the
requested time while the player reports exactly the requested time. `FLAG_ENABLE_INDEX_SEEKING` does not help: Media3
uses the index only when the file has no usable seek table. Each phone lands differently, so every resume, seek,
late join or resync can put the room out of sync by an amount that no position report reveals. Acoustic calibration
cannot fix it either, because it changes with every seek. Raw ADTS AAC has no index at all.

So each phone decodes MP3 and ADTS files once (`TrackTranscoder.kt`, `MediaExtractor` + `MediaCodec`, preferring the
platform software decoder so every phone produces identical samples) into a 16-bit PCM WAV under the app cache
(`pcm/`, least-recently-used copies evicted above 2 GB), and plays that copy. WAV seeking is computed from the byte
offset and is sample-exact. Playlist tracks already on the phone are decoded in the background when a room starts
(roughly 1–4 s per song; not yet measured on phones). If decoding fails, the original file is played and a warning
is logged. FLAC, MP4/M4A and Ogg seek exactly from their own indexes and are played as they are.

## Background playback

While in a room the plugin runs `PlaybackService`, a foreground service of type `mediaPlayback` with an ongoing
notification (room name, current track, previous / play-pause / next). It keeps the process, the Dart isolate, the
sockets and the audio thread alive with the screen off. Notification buttons send *room* controls through the
coordinator (so "pause" pauses the whole room) and need control rights like any other control.

Permissions: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, and `POST_NOTIFICATIONS` (Android 13+,
requested at runtime; if denied the service still runs but its notification is hidden). It is deliberately not a
Media3 `MediaSessionService`: a media session would let headset buttons and the system "media output" panel drive the
*local* player and desynchronize this device from the room.

## Channel roles (experimental)

`RoleRenderersFactory` overrides `DefaultRenderersFactory.buildAudioSink` and puts a `ChannelMixingAudioProcessor`
in front of the default processors (Media3 still appends silence skipping and Sonic, so rate correction works).
For stereo input the 2×2 matrix is `left` `[1,1,0,0]`, `right` `[0,0,1,1]`, `mono` `[0.5,0.5,0.5,0.5]`; other channel
counts pass through unchanged. The role is fixed when a player is built, so a change takes effect with the next
segment, which the engine schedules immediately.

## Calibration recording

`MicRecorder` records mono PCM16 at 48 kHz with `AudioRecord`, from the `UNPROCESSED` source when
`PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED` is true and `VOICE_RECOGNITION` otherwise (AGC, noise suppression and
echo cancellation would smear click onsets). The first sample's time comes from `AudioRecord.getTimestamp`
(`TIMEBASE_MONOTONIC`) when available, else from the start call. That timestamp only positions the search windows:
corrections use arrival *differences* between devices, so a constant input latency cancels out. `RECORD_AUDIO` is
requested at runtime when a calibration starts; the WAV is deleted right after analysis.
