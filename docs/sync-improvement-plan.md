# Sync improvement plan (steps 1–5)

Status: **implemented** (November 2026). This plan was written before the implementation; the outcome is at the end.
Base: commit `5c83c86`, the rollback to the Oct 18 build (`001dae0`). Real-phone report: *"echo from the start"*, even
after calibration.

## Why

The network half of SyncSphere (clock sync, scheduled timelines, failover) is solid. The weak part sits between the
play call and the speaker:

1. **Open-loop start.** `SyncAudioEngine.kt` calls `ExoPlayer.play()` at *target − learned latency*. The true
   play→sound delay varies with every call:
   - Android puts an idle output into *standby*, and waking it costs tens to hundreds of ms;
   - every segment is a new ExoPlayer with a new `AudioTrack`;
   - the first start uses only a heuristic hint.

   The error is only seen after `latencyLearnDelay` (2.5 s) and then corrected at ±1.5 % rate (≈ 7 s for 100 ms).
   That is an echo at the start.
2. **Indirect measurement.** Positions come from `player.currentPosition`, ExoPlayer's smoothed estimate, not from
   the speaker.
3. **No real-phone measurement**, so regressions are found by ear, late.
4. **Features edit sync code directly**: the last regression came from feature work inside
   `playback_engine.dart` and the Kotlin audio path.
5. **The simulator is optimistic.** It does not model cold starts or ExoPlayer's report smoothing, so it said
   5–20 ms while the phones echoed.

## Ground rules

- **Classic stays exactly the Oct 18 behaviour.** Everything new is behind a switch. Classic is the default until
  the Sync check shows on real phones that a new engine is better.
- **Rollback at three levels:**
  - runtime (one tap back to *Classic*);
  - automatic (a failing new engine falls back to Classic on that phone);
  - git (each step is its own commit, so `git revert` removes one step; the full rollback target is `5c83c86`).
- **No database or protocol breaks:**
  - DB schema stays v2, so an older APK can still be installed over this one;
  - new `RoomState` fields are optional, so older phones ignore them;
  - unknown engine names parse as Classic.
- **Testable core, thin glue:**
  - every decision and every piece of math lives in pure Dart or pure Kotlin with unit tests;
  - Android-specific code only moves bytes to `AudioTrack`.
- **Nothing is pushed before** these pass locally:
  - analyze and tests for core, plugin and app;
  - the simulated comparison;
  - JVM tests of the Kotlin core.

  Simulated numbers are labelled *simulated*.

## Engine modes (the switch)

`SyncEngineMode { classic, warm, precise }` is host-controlled and part of `RoomState` (`eng`), so the whole party
uses one engine. Each mode's start rule lives in one place, `participant/start_policy.dart`:

| Mode | Start | Measurement | Drift config |
|---|---|---|---|
| `classic` | play call at target − learned latency (unchanged) | ExoPlayer position | unchanged |
| `warm` | same, but the output never sleeps, and latency is primed by a silent test start | ExoPlayer position | unchanged |
| `precise` | the renderer places the first sample at the target frame | `AudioTrack.getTimestamp` (speaker frame) | tight (small deadband, ≤0.3 % rate) |

## Step 1: Sync check and feature flags

- **Measurement:**
  - `CalibrationPlan` gets `measureOnly` (JSON `mo`).
  - `ControlAction.syncCheck` starts a plan with clicks right after the start: lead-in 1 s, 6 rounds.
  - The same machinery serves acoustic calibration (personalised click tracks through the normal playback path, so
    it measures exactly the song-start path) and the Sync check.
- **Result:** the coordinator turns the listener's arrivals into a `SyncCheckResult` and changes nothing else.
  - Per phone: offset at the *start* (round 1) and when *settled* (median of the last half), plus jitter.
  - Room-wide: start and settled spreads, and the engine mode used.
  - The last 6 results are kept in `RoomState.checks`, so every phone sees them.
- **App:**
  - Diagnostics → **Sync check** (results table in ms);
  - **Compare engines**, which runs the check once per engine and highlights the best;
  - Settings → **Sync engine** (host), with a one-tap **Back to Classic**.
- **Flags:**
  - local `FeatureFlags` (core, JSON) stored with `AppStore.saveSetting`;
  - `keepAwake`, `startProbe` (sub-features of warm, so they can be bisected on phones);
  - `preciseFallback` (automatic fallback, on by default);
  - `channelRoles` (the existing experimental L/R feature).

## Step 2: Warm start (ExoPlayer, low risk)

- **Keep-awake:** a silent `AudioTrack` (same attributes as ExoPlayer, so the same output) plays from the first
  prepare until 2 minutes without playback. The output never enters standby, which removes the main source of
  start-latency variance.
- **Start probe:** when the room is idle (no pending start, not playing), the engine plays a 3 s silent WAV through
  the normal path and measures the play→output delay after the same 2.5 s learning delay. The first real start is
  then scheduled with a measured latency instead of a guess.
  - The probe is cancelled the moment the room needs the player.
  - It never replaces a prepared standby.
- **Dart:** `WarmStartPolicy`, plus `AudioBackend` keep-awake control through the optional
  `SyncModeAwareBackend` interface.
- **Native:** `KeepAwake.kt`.

## Step 3: Precise engine (own PCM renderer)

**Pure Kotlin core, unit-tested on the JVM:**

| File | Contents |
|---|---|
| `render/WavPcm.kt` | WAV parsing (16-bit PCM, any channel count) and a frame source |
| `render/OutputClock.kt` | speaker-frame ↔ nanoTime mapping from `AudioTimestamp`, with sanity checks and a head-position fallback |
| `render/ContentMap.kt` | which content frame was written at which output frame, so positions are exact even across rate changes |
| `render/Resampler.kt` | cubic Hermite, fractional step = (inRate / outRate) · rate |
| `render/RenderCore.kt` | the whole writer, below |

`RenderCore` handles:
- the silence ↔ content switch at the exact frame;
- a late start that skips content so it stays aligned;
- pause at a frame, then seek;
- 3 ms fades, volume ramps, channel roles, mono→stereo, end-of-track.

**Android glue:** `PreciseAudioEngine.kt` runs one `AudioTrack` (device sample rate, stereo PCM16, always running
while in use) and a writer thread at `URGENT_AUDIO` priority that feeds `RenderCore` and polls timestamps.

**Plugin:**
- own `MethodChannel` `dev.syncsphere/precise_audio`;
- events tagged `engine: precise`;
- `setEngine` selects the engine;
- a failure (no `AudioTrack`, bad file) reports `fallback`.

**Dart:**
- `PreciseAudioBackend` (capability `schedulesOutput: true`);
- `ModeSwitchingBackend` (one active delegate; switching stops the old one, and the engine re-joins the running
  timeline);
- in precise mode the converter decodes *every* non-PCM16-WAV track to WAV (existing `TrackTranscoder`).

**Engine:** `PreciseStartPolicy`:
- schedules the audible time directly;
- learns only a small residual (`preciseOffsetUs`, kept apart from the ExoPlayer latency);
- uses the tight drift config;
- settle and learn delays are about 300 ms instead of 1.2 s and 2.5 s.

## Step 4: Sync-core boundary and smaller files

- **Sync core:** `time/`, `audio/`, `config/`, `participant/{playback_engine,drift_controller,start_policy}`, plus
  timeline models. `test/architecture_test.dart` fails if a core file imports a feature module (`coordinator/`,
  `discovery/`, `simulation/`, app code), with an explicit allow-list for the two interfaces the engine needs (track
  resolver, calibration track factory).
- **Sync regression gate:** `test/sync_regression_test.dart` runs fixed-seed simulations for each mode and fails if
  start skew or steady spread exceed budgets (Classic must also not get worse than today).
- **`room_coordinator.dart` (1416 lines):**
  - calibration and Sync check move to `coordinator/calibration_coordinator.dart`;
  - play order, shuffle and neighbours move to `coordinator/play_order.dart`.
- **`participant_session.dart`:** the clock-probe scheduling moves to `participant/clock_prober.dart`.
- **Docs:** `docs/sync-core.md` describes the boundary and the gate.

## Step 5: A simulator that matches phones

- **`DeviceAudioProfile`:**
  - cold start: `standbyAfterUs` and `coldStartExtraMeanUs` / `JitterUs`;
  - per-new-player jitter;
  - ExoPlayer report smoothing (`earlyReportErrorUs` decaying over `reportSettleUs`);
  - `timestampNoiseUs` for precise.
- **`SimulatedAudioBackend`** implements all three modes: classic and warm through the ExoPlayer model,
  precise through a frame-exact renderer model.
- **Real numbers in:**
  - the engine keeps per-start statistics (cold or warm, latency used, measured error);
  - Diagnostics → **Export phone profile** turns them, plus the last Sync check, into `DeviceAudioProfile` JSON;
  - `dart run bin/benchmark.dart --suite engines --profiles phones.json` compares the three engines on those phones.
- **Benchmark:** new `engines` suite (2/3/5 phones × Wi-Fi models, first start, track change, seek), labelled
  SIMULATED.

## Order of work

1. **Base:**
   - `SyncEngineMode` and the `RoomState` field;
   - `ControlAction.setSyncEngine`;
   - `FeatureFlags`;
   - `StartPolicy` extraction (Classic unchanged; proven by the existing tests and an identical simulation result
     before and after).
2. **Step 5 simulator realism:** needed to measure steps 2–3. Record the Classic baseline numbers.
3. **Step 2 warm**, with tests and simulation.
4. **Step 3 precise:** Kotlin core and JVM tests first, then glue, Dart backends, engine policy and simulation.
5. **Step 1:** Sync check (coordinator and app UI), flags UI, profile export.
6. **Step 4:** split files, architecture test, regression gate.
7. Docs, full local verification, commits (one per step), push, CI until green.

## Verification

- **Core:** `dart analyze --fatal-infos && dart test`, which includes:
  - start-policy tests and JSON round trips (old-format compatibility);
  - the coordinator Sync check flow;
  - the simulation regression gate;
  - the architecture test.
- **Plugin:** `flutter analyze && flutter test` (fake native API: backend routing, fallback, event filtering).
- **App:** `flutter analyze && flutter test` (Settings engine switch, Diagnostics Sync check table).
- **Kotlin:** pure core compiled and tested locally with `kotlinc` from Maven Central, and the Android glue
  compiled against the Robolectric `android-all` jar where possible. In CI, `:syncsphere_audio:testDebugUnitTest`
  and the APK build.
- **Simulation:** `bin/benchmark.dart --suite engines` before and after each step; results go to `docs/` as
  SIMULATED.
- **On the phones (by the user):**
  - install over the current app;
  - Diagnostics → Compare engines;
  - pick the best;
  - if anything is wrong, Settings → Back to Classic.

## Outcome

All five steps are implemented; Classic stays the default.

**Guide:** [sync-engines.md](sync-engines.md) covers using the engines and rolling back. **Guards:**
[sync-core.md](sync-core.md).

**Tests, all run locally before pushing:**

| Suite | Result |
|---|---|
| Core | 152 tests, including the Classic golden test, the architecture test, the budget gate and the engine scenarios |
| Plugin (Dart) | 12 |
| App | 31 |
| Kotlin (JVM) | 21: 18 renderer-core tests plus the existing position-estimator tests |

Native glue was compiled against the Android API.

**Simulation (phone-like devices; modelled, not measured), p95 of the spread:**

| Engine | First 3 s | Afterwards |
|---|---|---|
| Classic | 97–114 ms | 69–163 ms |
| Warm start | 39–44 ms | 24–31 ms |
| Precise | 2–3 ms | 2–3 ms |

**Bug found on the way:** a resync overlapping a seek could leave a phone stuck far out of sync (72 s in the found
case). This was a Classic bug too. It is fixed without changing Classic's normal behaviour (see sync-core.md).

**Not done:**
- Nothing has run on real phones yet.
- Precise's model is idealised.
- The next step is the **Sync check** on the phones, then **Compare engines**, then choosing the default engine from
  real numbers.
