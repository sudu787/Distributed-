# Roadmap and research directions

Status words: **done**, **partial**, **designed** (written down, not implemented), **idea**.

## Near term (to reach a validated release)

The coordinator failover milestone below is done in software; the items in this table remain.

| Item | Status | Next step |
|---|---|---|
| Real-device validation with 2 → 10 phones | designed ([benchmarking.md](benchmarking.md)) | Run the acoustic protocol and commit raw data |
| Replace the simulated device profiles with measured ones | designed | Use the `started` events' `startErrorUs` and position noise from logcat |
| Background playback (foreground `MediaSessionService`, notification controls) | idea | Move the player thread into the service; keep the WifiLock while playing |
| Long, QR-shareable join keys (130-bit) | partial (`generateJoinKey(length: 26)` exists) | QR display and scan |
| mDNS/DNS-SD advertisement in addition to the UDP beacon | idea | Android `NsdManager` via the plugin |

## Coordinator failover milestone

**Status: done (succession-based), with limitations below.** Implemented in
`packages/syncsphere_core/lib/src/participant/failover.dart` and `ParticipantSession`. Tests:

- simulation: host killed, then the successor killed too (chained), 4–5 devices
- real sockets: an app-level host crash over loopback

Without a `FailoverDelegate`, sessions keep the older behavior: report "room needs to be recreated". The app enables
failover for guests. This is **succession, not consensus-based leader election**.

### Succession protocol (implemented)

1. **Candidates.** Guests advertise a failover port (`caps.fport`). The coordinator combines it with the address it
   sees them connect from, and publishes `canHost` plus `ep` in every participant summary. The succession order is
   the admission order among connected candidates, excluding the coordinator. Every member derives it from the last
   `state` it received.
2. **Detection.** The link drops (immediately on a crash, or after 8 s of silence). After `failoverAfter` (2 s) the
   session stops retrying the old coordinator.
3. **Promotion.** The successor:
   1. creates a coordinator with the same room id and key, and `epoch = oldEpoch + 1`;
   2. restores the last state;
   3. translates the timeline into its own clock domain: `anchorLocal = estimate.toLocal(anchorCoord)`. The error
      equals its current offset uncertainty, typically 1–5 ms; drift correction absorbs it;
   4. drops any pending segment;
   5. keeps `generation`, so devices that are already playing do not restart;
   6. starts beaconing with the new epoch.
4. **Rejoin.** The others connect to candidate 0's endpoint. After 3 failed attempts they move to the next
   candidate, and promote themselves if they are next. They re-authenticate with the same key and accept the state
   because `epoch` is higher. Their engines keep the active segment, since its generation is unchanged, while the
   session discards clock samples from the old instance and re-estimates against the new one.
5. **Split brain.** If the old coordinator returns, or two candidates promote during a partition, members follow the
   highest `(epoch, coordinatorId)`. A coordinator that sees a higher epoch in a beacon steps down: it redirects its members
   to the higher-epoch coordinator (`redirect`, no `bye`) and joins it as a guest. This is not consensus: during a partition two sides can play independently, and they converge
   when it heals. A Raft-style elected leader would stop the minority side from playing; that trade-off was judged
   wrong for a music app.
6. **Measured in simulation** (`coordinator-failover-n5`, two consecutive host deaths): promotion about 2 s after
   the kill, inter-device spread ≤ 8 ms in the 15 s after promotion, and no session failures. Real devices: not yet.

Limitations:

- The successor serves only tracks in its own library. With LAN delivery, guests may lack a track it does not have.
- The successor needs its failover port (47800) to be free.
- An intentional "end party" by the original host (`bye`) ends the room for everyone, by design.

### Handback to the original host (implemented)

Distributed-systems building blocks used ([protocol §7](protocol.md#handback-to-the-original-host-and-planned-transfers)):

| Principle | Where |
|---|---|
| Epoch as a fencing token (like a Raft term): every coordinator change increments it; lower epochs are ignored | state, `redirect`, `handover` |
| Priority-based succession without election messages (Bully-style): `pref` first, then admission order, computed by everyone from the same replicated state | `successionOrder` |
| Heartbeat failure detection | membership timeouts, 2 s `failoverAfter` |
| Preferred-leader rebalancing with hysteresis (like Kafka's preferred replica election): hand back only after 10 s of uninterrupted connection; exponential backoff after a failed attempt | `RoomCoordinator._maybeHandback` |
| Planned leadership transfer (like Raft's leadership transfer): the new leader confirms it is serving before the old one redirects followers and steps down; state is transferred, timeline translated, generation kept, so playback never restarts | `handover` / `handover.ack` / `redirect` |
| Split-brain resolution by step-down: a lower-epoch coordinator that learns of a higher epoch redirects its members and joins it | `RoomCoordinator.stepDown`, beacons |
| Graceful leave: a stand-in coordinator hands off instead of closing | `RoomCoordinator.handOff` |

Measured in simulation (`failover-failback-n3`, 3 phones, wifi-typical): takeover about 2 s after the host is killed,
handback about 10.5 s after the host rejoins, inter-device spread ≤ 6 ms in the 15 s after the handback, no session
failures. Also tested over real sockets (app test: crash → takeover → rejoin → handback → control via the original
host; and a stand-in host leaving hands off). Real phones: not yet.

## Precision backend (sub-5 ms target)

**idea.** Replace ExoPlayer's black-box start with a custom pipeline: `MediaExtractor`/`MediaCodec` → PCM, then
AAudio (or `AudioTrack`) in a mode where `getTimestamp` maps frame index to `nanoTime`. Write silence until the frame
whose presentation time equals the target, which gives frame-accurate starts (about 0.02 ms at 48 kHz) and lets
resampling replace speed changes. Expected benefit: start skew limited by clock estimation instead of pipeline
jitter. Cost: an owned decoder and resampler, plus format coverage.

## Acoustic calibration

| Item | Status |
|---|---|
| Per-device calibration offset applied to the reported position | **done** (engine, UI field, kept by the room via `setCalibration`, persisted) |
| Offline acoustic skew measurement with an external multichannel recorder | **done** (`tools/onset_skew.py`, `tools/make_click_track.py`) |
| **"Calibrate to this spot"**: every device plays a personal click track in turn as a scheduled segment; the listener's microphone finds each onset; the coordinator removes each device's own software error at the click times and updates every member's offset ([protocol §5.1](protocol.md#51-acoustic-calibration)) | **implemented**: core, coordinator, Android recorder (`AudioRecord`, UNPROCESSED source when available), UI. Simulated with a virtual microphone (propagation, noise, 18 ms input timestamp error): spread at the listener 192 ms → 4.6 ms median, p95 22 ms (mostly the first seconds after music resumes), SIMULATED (`listening-spot-*-n4`). **Not yet run on phones.** |
| Repeat calibrations from several spots and optimize for an area instead of a point | idea |
| Bluetooth latency estimation via `AudioManager`/codec info | idea (unreliable across devices) |

Digital alignment is not the same as what a listener hears. Sound needs about 2.9 ms per metre. Phones 3 m apart
cannot all be aligned for every listener position; "calibrate to this spot" optimizes for one listening position by
delaying the nearer speakers by `(d_far − d_near) / 343 m/s`, which makes other positions *worse* by up to the same
amount.

## Experimental spatialized playback

**idea**, not a prerequisite, and not "Dolby Atmos" or professional surround. Possible steps:

1. **Channel roles** — **implemented (experimental)**: `stereo`, `left`, `right` or `mono` per device, carried in the
   participant summary (`ch`). On Android a Media3 `ChannelMixingAudioProcessor` in a custom audio sink routes one
   source channel to all outputs. A role change while playing switches to a freshly prepared segment at a scheduled
   instant (SIMULATED: a brief ~13 ms blip, then back in sync). Not yet listened to on hardware.
2. **Per-device delay trims** for a chosen listening position: done via acoustic calibration above. Gain trims: idea.
3. **Placement UI.** Drag devices on a floor plan; compute delays from distances.
4. Limits to state honestly: phone speakers have very limited bass and differing frequency responses, phase
   interference between unsynchronized speakers produces comb filtering below roughly 1 kHz, and any device-to-device
   error beyond a few milliseconds blurs stereo imaging. Validate with measurements before advertising anything.

## Adaptive synchronization

| Item | Status |
|---|---|
| Adaptive clock-probe interval (fast while uncertain, slow when stable) | **done** |
| Adaptive drift report interval (0.5 s correcting, 2 s in sync) | **done** |
| Lead time from measured RTT, latency and uncertainty | **done** |
| Kalman filter combining clock offset and audio-clock drift | idea |
| UDP clock probes (avoid TCP head-of-line blocking) | idea |

## Platforms

iOS backend (AVAudioEngine with `AVAudioTime` host-time scheduling), desktop backends: **idea**. The core already runs
on any Dart VM, and the CLI can join rooms headlessly today.
