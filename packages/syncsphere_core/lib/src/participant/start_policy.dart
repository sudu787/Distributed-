/// How a phone turns "track position P must be audible at local time T"
/// into a backend start call, and what it learns from the first
/// measurement after a start. This is the only place where the sync engines
/// (`SyncEngineMode`) differ inside the playback engine.
///
/// Every policy keeps its own learned value, so switching engines never
/// mixes their numbers (an ExoPlayer start latency of 80 ms means nothing to
/// the precise renderer, which places the first sample itself).
library;

import '../config/sync_config.dart';
import '../model/sync_engine.dart';

abstract class StartPolicy {
  StartPolicy(this.leadUs);

  SyncEngineMode get mode;

  /// How long (µs) before the target audible time the backend start is
  /// scheduled. Learned; includes the acoustic calibration offset (a phone
  /// that sounds late must start earlier).
  int leadUs;

  static const int minLeadUs = -500000;
  static const int maxLeadUs = 1000000;

  /// Local time of the backend start call for audible time [targetOutLocalUs].
  int startCallAt(int targetOutLocalUs) => targetOutLocalUs - leadUs;

  /// Drift-control parameters for this engine, derived from the room's.
  DriftConfig drift(DriftConfig room);

  /// Learns from the first error measured after a start (µs; negative: the
  /// audio started late). Returns false if the value was implausible.
  bool learn(int errorUs);

  /// The room changed this phone's calibration offset by [deltaUs]: a phone
  /// that must sound Δ earlier starts Δ earlier.
  void onCalibrationChanged(int deltaUs) => leadUs = (leadUs + deltaUs).clamp(minLeadUs, maxLeadUs);

  /// One policy per engine. [classicLeadUs] is the learned ExoPlayer start
  /// latency (persisted across parties); [learned] holds the other engines'
  /// values by name.
  static Map<SyncEngineMode, StartPolicy> forAllEngines({
    required int classicLeadUs,
    Map<String, int> learned = const {},
    int outputCalibrationUs = 0,
  }) =>
      {
        SyncEngineMode.classic: ClassicStartPolicy(classicLeadUs),
        SyncEngineMode.warm: WarmStartPolicy(learned[SyncEngineMode.warm.name] ?? classicLeadUs),
        SyncEngineMode.precise:
            PreciseStartPolicy(learned[SyncEngineMode.precise.name] ?? outputCalibrationUs),
      };
}

/// The October 18 behaviour: ExoPlayer's `play()` is called early by the
/// learned play-call → audible delay; 60 % of each start's error is learned.
class ClassicStartPolicy extends StartPolicy {
  ClassicStartPolicy(super.leadUs);

  @override
  SyncEngineMode get mode => SyncEngineMode.classic;

  @override
  DriftConfig drift(DriftConfig room) => room;

  @override
  bool learn(int errorUs) {
    if (errorUs.abs() > 500000) return false; // implausible; something else is wrong
    // Negative values are allowed: an uncalibrated device whose reported
    // position runs ahead of its sound (Bluetooth) learns to play "late".
    leadUs = (leadUs - 0.6 * errorUs).round().clamp(StartPolicy.minLeadUs, StartPolicy.maxLeadUs);
    return true;
  }
}

/// Same start rule as Classic. What differs is around it: the output is
/// kept awake (so the delay stays the same from start to start) and the
/// delay is measured with a silent test start before the first song.
class WarmStartPolicy extends ClassicStartPolicy {
  WarmStartPolicy(super.leadUs);

  @override
  SyncEngineMode get mode => SyncEngineMode.warm;
}

/// The precise renderer schedules the *audible* frame itself, so the lead
/// is only the calibration offset plus a small learned residual (timestamp
/// bias of the device). Measurements are exact, so drift control can use a
/// small deadband, gentle rates (the renderer resamples without pitch
/// correction) and short settle times.
class PreciseStartPolicy extends StartPolicy {
  PreciseStartPolicy(super.leadUs);

  @override
  SyncEngineMode get mode => SyncEngineMode.precise;

  @override
  DriftConfig drift(DriftConfig room) => room.forPreciseRenderer();

  @override
  bool learn(int errorUs) {
    if (errorUs.abs() > 200000) return false; // a renderer this far off is broken, not biased
    leadUs = (leadUs - 0.5 * errorUs).round().clamp(StartPolicy.minLeadUs, StartPolicy.maxLeadUs);
    return true;
  }
}
