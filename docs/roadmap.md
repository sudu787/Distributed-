# Roadmap and research directions

Status words: **done**, **partial**, **designed** (written down, not implemented), **idea**.

## Near term (to reach a validated release)

| Item | Status | Next step |
|---|---|---|
| Real-device validation with 2 → 10 phones | designed ([benchmarking.md](benchmarking.md)) | Run the acoustic protocol and commit raw data |
| Replace the simulated device profiles with measured ones | designed | Use the `started` events' `startErrorUs` and position noise from logcat |
| Background playback (foreground `MediaSessionService`, notification controls) | idea | Move the player thread into the service; keep the WifiLock while playing |
| Long, QR-shareable join keys (130-bit) | partial (`generateJoinKey(length: 26)` exists) | QR display and scan |
| mDNS/DNS-SD advertisement in addition to the UDP beacon | idea | Android `NsdManager` via the plugin |

## Coordinator failover milestone

Current behavior is detection plus an explicit "room needs to be recreated" message (tested). The design below is
**not implemented**, and SyncSphere does not claim leader election.

### Succession protocol (designed)

1. **Candidates.** The coordinator includes `canHost` in each participant summary. A device sets it when it can
   serve audio, meaning it has every playlist track (`avail = available` for all of them). The succession order is
   the order of admission among connected `canHost` devices. It is published in every `state`, so all members hold
   the same list (up to the latest version they received).
2. **Detection.** A participant suspects the coordinator after 3 s and fails it after 8 s, as today. After `failAfter`
   plus a stagger of `rank × 2 s`, the first live candidate in the list it last saw promotes itself.
3. **Promotion.** The successor:
   1. creates a coordinator with the same room id and key, and `epoch = oldEpoch + 1`;
   2. restores the last state;
   3. translates the timeline into its own clock domain: `anchorLocal = estimate.toLocal(anchorCoord)`. The error
      equals its current offset uncertainty, typically 1–5 ms; drift correction absorbs it;
   4. drops any pending segment;
   5. keeps `generation`, so devices that are already playing do not restart;
   6. starts beaconing with the new epoch.
4. **Rejoin.** The other participants try the successor's address. To make this possible, participant summaries need
   to carry the address the device would listen on if promoted. They re-authenticate with the same key and accept the
   state because `epoch` is higher. Their engines keep the active segment, since its generation is unchanged, and
   re-estimate the clock against the new instance.
5. **Split brain.** If the old coordinator returns, or two candidates promote during a partition, members follow the
   highest `(epoch, coordinatorId)`. A coordinator that sees a higher epoch in a beacon shuts down and tells its members
   (`bye{superseded}`). This is not consensus: during a partition two sides can play independently, and they converge
   when it heals. A Raft-style elected leader would stop the minority side from playing; that trade-off was judged
   wrong for a music app.
6. **Tests to write.** Simulator scenarios already include `KillCoordinatorAction`. Add assertions that playback
   continues with less than 50 ms of disturbance and that exactly one coordinator holds the highest epoch after
   healing.

## Precision backend (sub-5 ms target)

**idea.** Replace ExoPlayer's black-box start with a custom pipeline: `MediaExtractor`/`MediaCodec` → PCM, then
AAudio (or `AudioTrack`) in a mode where `getTimestamp` maps frame index to `nanoTime`. Write silence until the frame
whose presentation time equals the target, which gives frame-accurate starts (about 0.02 ms at 48 kHz) and lets
resampling replace speed changes. Expected benefit: start skew limited by clock estimation instead of pipeline
jitter. Cost: an owned decoder and resampler, plus format coverage.

## Acoustic calibration

| Item | Status |
|---|---|
| Per-device calibration offset applied to the reported position | **done** (engine, UI field, persisted) |
| Offline acoustic skew measurement with an external multichannel recorder | **done** (`tools/onset_skew.py`, `tools/make_click_track.py`) |
| In-app calibration: the host plays a click train and each phone records it with its own microphone, cross-correlates, and solves for its own output latency (subtracting propagation, assuming known distance or co-location) | designed |
| Bluetooth latency estimation via `AudioManager`/codec info | idea (unreliable across devices) |

Digital alignment is not the same as what a listener hears. Sound needs about 2.9 ms per metre. Phones 3 m apart
cannot all be aligned for every listener position; alignment can be optimized for one listening spot, by delaying
the nearer speakers by `(d_far − d_near) / 343 m/s`.

## Experimental spatialized playback

**idea**, not a prerequisite, and not "Dolby Atmos" or professional surround. Possible steps:

1. **Channel roles.** Assign L, R or mono-sum per device: a downmix in the native pipeline, with the role carried in
   the participant summary.
2. **Per-device gain and delay trims** from the calibration above, for a chosen listening position.
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
