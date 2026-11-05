/// Fits a simulator [DeviceAudioProfile] to what a real phone recorded
/// about itself ([StartStats]): the bridge from phones back into the
/// simulator (step 5 of docs/sync-improvement-plan.md).
library;

import 'dart:math';

import '../model/sync_engine.dart';
import '../participant/start_stats.dart';
import 'sim_audio_backend.dart';

double _mean(List<num> v) => v.isEmpty ? 0 : v.fold<double>(0, (a, b) => a + b) / v.length;

double _std(List<num> v) {
  if (v.length < 2) return 0;
  final m = _mean(v);
  return sqrt(v.fold<double>(0, (a, x) => a + (x - m) * (x - m)) / (v.length - 1));
}

/// A uniform distribution with standard deviation s has half-width s·√3.
int _halfWidth(List<num> v) => (_std(v) * sqrt(3)).round();

/// Turns a phone's [StartStats] into a simulator profile. Starts after at
/// least [standbyUs] of silence count as cold. Values the data cannot show
/// keep the defaults (the audio clock error, for one, is not visible in
/// these statistics); the result says how much data it rests on.
({DeviceAudioProfile profile, Map<String, Object?> basis}) fitDeviceProfile({
  required String name,
  required StartStats stats,
  required bool rateControl,
  required int prepareUs,
  int? acousticOffsetUs,
  int standbyUs = 3000000,
}) {
  final exo = stats.starts.where((s) => s.engine != SyncEngineMode.precise).toList();
  // Warm start keeps the output awake, so only Classic starts can be cold.
  bool isCold(StartRecord s) =>
      s.engine == SyncEngineMode.classic && (s.idleBeforeUs == null || s.idleBeforeUs! >= standbyUs);
  final warm = [
    for (final s in exo)
      if (!isCold(s)) s.actualLatencyUs,
    ...stats.probeLatenciesUs,
  ];
  final cold = [
    for (final s in exo)
      if (isCold(s)) s.actualLatencyUs
  ];
  final base = warm.isNotEmpty ? warm : cold;
  final warmMean = _mean(base);
  final coldExtra = warm.isNotEmpty && cold.isNotEmpty ? max(0, (_mean(cold) - warmMean).round()) : 0;
  final precise = [for (final s in stats.starts) if (s.engine == SyncEngineMode.precise) s.errorUs];
  final steadyExo = [for (final (e, v) in stats.steadyErrors) if (e != SyncEngineMode.precise) v];
  final steadyPrecise = [for (final (e, v) in stats.steadyErrors) if (e == SyncEngineMode.precise) v];
  const d = DeviceAudioProfile(name: '');
  final profile = DeviceAudioProfile(
    name: name,
    startLatencyMeanUs: base.isEmpty ? d.startLatencyMeanUs : max(1000, warmMean.round()),
    startLatencyJitterUs: base.length < 2 ? d.startLatencyJitterUs : _halfWidth(base),
    positionNoiseUs: steadyExo.length < 5 ? d.positionNoiseUs : _std(steadyExo).round(),
    positionBiasUs: acousticOffsetUs ?? 0,
    prepareMeanUs: prepareUs,
    rateControl: rateControl,
    standbyAfterUs: coldExtra > 10000 ? standbyUs : 0,
    coldStartExtraMeanUs: coldExtra > 10000 ? coldExtra : 0,
    coldStartExtraJitterUs: coldExtra > 10000 && cold.length >= 2 ? _halfWidth(cold) : 0,
    preciseStartErrorUs: precise.length < 2 ? d.preciseStartErrorUs : max(100, _halfWidth(precise)),
    timestampNoiseUs: steadyPrecise.length < 5 ? d.timestampNoiseUs : max(50, _std(steadyPrecise).round()),
  );
  return (
    profile: profile,
    basis: {
      'warmStarts': warm.length,
      'coldStarts': cold.length,
      'preciseStarts': precise.length,
      'steadySamples': stats.steadyErrors.length,
      'probes': stats.probeLatenciesUs.length,
    },
  );
}
