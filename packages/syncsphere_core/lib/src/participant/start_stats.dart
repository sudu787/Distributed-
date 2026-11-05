/// What a phone records about its own starts and steady playback, so a real
/// phone's behaviour can be turned into a simulator profile
/// (`simulation/profile_fit.dart`, Diagnostics → Export phone profile) and
/// the engines compared on *that* phone in simulation
/// (`bin/benchmark.dart --profiles`).
library;

import '../model/sync_engine.dart';

/// One start, measured at the first reliable position after it.
class StartRecord {
  final SyncEngineMode engine;

  /// Lead (µs) the start was scheduled with, and the acoustic calibration
  /// offset in force; the measured error is calibrated.
  final int leadUs;
  final int calibrationUs;

  /// Measured error (µs; negative: the audio started late).
  final int errorUs;

  /// How long the output had been silent before (null: never played, i.e.
  /// the first start after joining).
  final int? idleBeforeUs;
  final bool resync;

  const StartRecord({
    required this.engine,
    required this.leadUs,
    required this.calibrationUs,
    required this.errorUs,
    required this.idleBeforeUs,
    this.resync = false,
  });

  /// The delay from the start call to audible output this start actually
  /// had: lead − calibration − error.
  int get actualLatencyUs => leadUs - calibrationUs - errorUs;

  Map<String, Object?> toJson() => {
        'engine': engine.name,
        'leadUs': leadUs,
        'calUs': calibrationUs,
        'errorUs': errorUs,
        'idleUs': idleBeforeUs,
        if (resync) 'resync': true,
      };
}

/// Bounded log of starts and in-sync errors.
class StartStats {
  static const maxStarts = 100;
  static const maxSteady = 400;

  final List<StartRecord> starts = [];

  /// (engine, error µs) while in sync: the measurement noise.
  final List<(SyncEngineMode, int)> steadyErrors = [];

  /// Silent-probe results (µs, warm start).
  final List<int> probeLatenciesUs = [];

  void addStart(StartRecord r) {
    starts.add(r);
    if (starts.length > maxStarts) starts.removeAt(0);
  }

  void addSteady(SyncEngineMode e, int errorUs) {
    steadyErrors.add((e, errorUs));
    if (steadyErrors.length > maxSteady) steadyErrors.removeAt(0);
  }

  void addProbe(int latencyUs) {
    probeLatenciesUs.add(latencyUs);
    if (probeLatenciesUs.length > 20) probeLatenciesUs.removeAt(0);
  }
}
