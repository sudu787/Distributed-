# Sync engines, the Sync check, and rollback

SyncSphere can start and track playback in three ways. The **host** picks one for the whole party (Speakers tab or
Settings → Sync engine). **Classic is the default**: it is the October 18 build's behaviour, unchanged. The other two
are opt-in until the Sync check shows on your phones that they are better.

| Engine | How a song starts | How sync is measured | Risk |
|---|---|---|---|
| **Classic** | ExoPlayer's `play()` is called early by a learned start delay | ExoPlayer's (smoothed) position | the known-good baseline |
| **Warm start** | Same as Classic, but the speaker output is kept awake between songs, and each phone measures its start delay with a silent test start before the first song | as Classic | low: same player, plus a silent track |
| **Precise** | The app's own PCM renderer places the first sample on the exact output frame of the target time; a late start skips ahead and is still aligned | `AudioTrack.getTimestamp`: which frame the speaker is playing | new code: untested on real phones; falls back to Classic automatically |

## Why the start was the weak point

Android puts an idle speaker output into *standby*. The first start after a pause wakes it, which takes tens to
hundreds of milliseconds, and the delay differs from start to start and from phone to phone. Classic schedules
`play()` with one learned delay, so after every pause or first song the phones start apart. It learns the error only
after 2.5 s and corrects it slowly (±1.5 % speed), which you hear as an echo at the start.

- **Warm start** removes the standby wake-up by keeping the output awake.
- **Precise** removes the guesswork altogether: it does not *call* play early, it *writes* the first sample at the
  right frame.

Simulated on phone-like devices (`bin/benchmark.dart --suite engines`; modelled, **not measured**):

| | spread in the first 3 s, p95 | spread afterwards, p95 |
|---|---|---|
| Classic | 97–114 ms | 69–163 ms |
| Warm start | 39–44 ms | 24–31 ms |
| Precise | 2–3 ms | 2–3 ms |

The Precise model is idealised (timestamp error ±0.5–2 ms); real phones will be worse, and only the Sync check can
tell by how much. Full table: [benchmarks/results/simulated/engines/summary.md](../benchmarks/results/simulated/engines/summary.md).

## Sync check: measure instead of guessing

**Speakers tab → Sync check → Check.** Every phone clicks in turn through its normal playback path (the same path a
song takes), starting one second after the start. This phone's microphone records the clicks. The result says, in
milliseconds, how far apart the phones sound **where you stand**:

- **Gap at the start**: the first click of each phone. This is the echo-at-the-start measurement.
- **Gap once settled**: the median of the later clicks.
- **Per phone**: the start and settled offset relative to the middle phone (positive = heard later).
- **Verdict**: ≤ 10 ms "tight", ≤ 30 ms "slight echo", more is "clear echo".

**Compare engines** (host) runs the check once with each engine, keeps the results side by side (★ marks the best)
and returns to the engine you were using. Pick the best with one tap.

The check changes nothing (unlike *Calibrate to this spot*, which shifts each phone's timing).

## Switches on each phone (Settings → Sync engine)

| Switch | Default | Turn off when |
|---|---|---|
| Keep the speaker awake | on | battery matters more than warm start's tight starts |
| Silent test start | on | you suspect the test start misbehaves (warm start then learns from songs, like Classic) |
| Fall back to Classic | on | debugging the Precise engine (otherwise a failing renderer goes silent and reports why) |
| Left/right speaker roles | on | the experimental channel roles misbehave (this phone then plays full stereo) |

Changes apply immediately, even in a running party.

## Rollback

There are three levels, from fastest to most complete.

1. **One tap, in the party.** Host: Speakers tab → **Back to Classic** (or Settings → Sync engine → Classic). Every
   phone switches at once and re-joins the running song. Classic is the October 18 code path; the test
   `classic_golden_test.dart` proves it still produces bit-identical simulation results.
2. **Automatic, per phone.** If the Precise renderer cannot start or fails while playing (no audio output, write
   errors), that phone falls back to Classic by itself and keeps playing. The Speakers tab shows "This phone is
   using Classic …", and the host sees which phones fell back.
3. **Older build.** The work is in separate commits on `claude/syncsphere-music-sync-1zfnjc`:

   | Commit | Part |
   |---|---|
   | `9e34457` | core: engines, Sync check, simulator, guards |
   | `885834b` | Android renderer and keep-awake |
   | `d5bed9a` | app UI |
   | the docs commit that follows them | documentation and CI |

   - `git revert <commit>` removes one part (revert the later ones first);
   - `git checkout 5c83c86` is the plain October 18 build (with the stable signing key), and its APK is the
     `syncsphere-apks` artifact of CI run 39460112442.

   Installing it over this build keeps your library and calibration, because there are no database changes: new
   settings live in the existing key–value table, and new room-state fields are optional (older phones in the same
   party ignore them and run Classic).

## Feed real phones back into the simulator

**Diagnostics → science icon (Export phone profile)** copies this phone's measured behaviour as JSON:
- start delays, split into warm and cold;
- cold-start extra delay;
- measurement noise;
- its offset in the last Sync check.

Save the exports of all phones in one file (a JSON list), then:

```bash
cd packages/syncsphere_core
dart run bin/benchmark.dart --suite engines --profiles phones.json --out ../../benchmarks/out/measured
```

This runs the engine comparison on models of *your* phones. The copied Diagnostics report also contains the profile
(`phoneProfile`).
