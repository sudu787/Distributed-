# The sync core and its guards

The October 2026 regression ("echo from the start") came from feature work editing the code that decides *when*
audio plays. This document defines that code (the **sync core**) and the automated guards around it.

## What the sync core is

| Path (`packages/syncsphere_core/lib/src/`) | Role |
|---|---|
| `time/` | clocks, clock-offset estimation, Dart↔native clock bridge |
| `audio/` | the `AudioBackend` contract, `ModeSwitchingBackend` |
| `config/` | room policy (`SyncConfig`), per-phone `FeatureFlags` |
| `participant/playback_engine.dart` | renders the room's timeline on the backend |
| `participant/start_policy.dart` | the only place where the sync engines differ in the engine |
| `participant/start_probe.dart` | warm start's silent test start |
| `participant/start_stats.dart` | what a phone records about its starts |
| `participant/drift_controller.dart` | rate/resync correction |
| `participant/clock_prober.dart` | when clock probes are sent |

Native renderers belong to it too: `packages/syncsphere_audio/android/.../render/` (pure Kotlin, JVM-tested) and
`SyncAudioEngine.kt` / `PreciseAudioEngine.kt`.

## Rules

1. **Features use the core; they do not edit it.**
   - Playlist, sources, UI, calibration flows and the coordinator talk to the engine through `RoomState`, the
     protocol, and the `AudioBackend` / `TrackResolver` interfaces.
   - A feature that seems to need a change inside the core gets its own change, reviewed as a sync change, and
     must pass the gate below.
2. **New sync behaviour arrives as an engine, not as an edit to Classic.**
   - Add a `SyncEngineMode` and a `StartPolicy`; keep Classic's path byte-identical.
   - The host can then switch to the new engine, and back.
3. **The core imports only itself** plus `model/`, `protocol/`, `observability/`, `util/`, and two declared
   interfaces (`distribution/track_resolver.dart`, `calibration/calibration_runtime.dart`).

## Automated gate (runs on every push in CI)

| Test | Guards |
|---|---|
| `test/architecture_test.dart` | rule 3: fails on any other import into the core (it names the offending import) |
| `test/classic_golden_test.dart` | Classic is exactly the October 18 engine: simulation samples hashed against values recorded before the engine layer existed |
| `test/sync_budget_test.dart` | warm start and Precise stay within their spread budgets on phone-like devices (4 network/size combinations), and each engine keeps beating the one before it |
| `test/sync_engines_test.dart` | engine switching mid-song, fallback, Sync check, warm-start probe, the profile fitter, and the stuck-start regression |
| Kotlin `render/*Test.kt` | frame-exact starts, late-start skip, pause/seek, rates, resampling, channel roles, WAV parsing |

Before a build goes to the phones, run a **Sync check** (Speakers tab) with the engine you intend to use. Real phones
are the final word: every number above is simulated.

## Bug found by the gate

The budget sweep (80 seeded runs) found a Classic bug that predates this work. A corrective resync that overlapped a
seek replaced the backend's single standby player, so the seek's start failed. The engine waited for that start
forever, and one phone stayed far out of sync (72 s in the found case) until the next command. The engine now
re-joins the running song when a scheduled start fails or never happens (`_startFailed`). Normal runs never take
this path, so Classic's golden results are unchanged.
