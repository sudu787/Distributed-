import 'clock.dart';
import 'clock_sync.dart';
import '../config/sync_config.dart';

/// Estimates the offset between two clock domains on the *same device*, for
/// example the Dart isolate's monotonic clock and Android's
/// `System.nanoTime()` read through a platform channel.
///
/// Each probe brackets one remote read between two local reads:
/// `t1 = local; r = remote(); t4 = local`. This is a four-timestamp exchange
/// with `t2 = t3 = r`, so the same estimator (and its interval-intersection
/// outlier handling) applies. The platform-channel hop is not symmetric, but
/// the remote read is guaranteed to lie between `t1` and `t4`, so the
/// uncertainty is bounded by half the bracket width.
class ClockDomainBridge {
  final MonotonicClock local;
  final Future<int> Function() readRemoteMicros;
  final ClockSyncEstimator _estimator;

  ClockDomainBridge({
    required this.local,
    required this.readRemoteMicros,
    ClockSyncConfig config = const ClockSyncConfig(
      windowSize: 48,
      maxRtt: Duration(milliseconds: 50),
      maxSampleAge: Duration(minutes: 30),
      minSkewSpan: Duration(minutes: 2),
    ),
  }) : _estimator = ClockSyncEstimator(config: config, uncertaintyFloorMicros: 20);

  ClockEstimate? get estimate => _estimator.estimate;

  /// Takes [samples] bracketed readings. Returns the updated estimate, or
  /// throws [StateError] if no reading produced a valid sample.
  Future<ClockEstimate> calibrate({int samples = 16}) async {
    for (var i = 0; i < samples; i++) {
      final t1 = local.nowMicros();
      final r = await readRemoteMicros();
      final t4 = local.nowMicros();
      _estimator.addSample(ClockSample(t1, r, r, t4), nowLocalMicros: t4);
    }
    final e = _estimator.estimate;
    if (e == null) {
      throw StateError('clock-domain bridge: no valid samples '
          '(rejected=${_estimator.rejectedCount})');
    }
    return e;
  }

  /// Local (Dart) → remote (native) domain.
  int toRemote(int localMicros) {
    final e = estimate;
    if (e == null) throw StateError('clock-domain bridge not calibrated');
    return e.toRemote(localMicros);
  }

  /// Remote (native) → local (Dart) domain.
  int toLocal(int remoteMicros) {
    final e = estimate;
    if (e == null) throw StateError('clock-domain bridge not calibrated');
    return e.toLocal(remoteMicros);
  }
}
