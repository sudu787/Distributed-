/// Failure detection for the coordinator ↔ participant links.
///
/// The original detector used fixed timeouts (suspect after 3 s, fail after
/// 8 s of silence). [PhiAccrualDetector] implements the φ accrual failure
/// detector (Hayashibara et al., "The φ Accrual Failure Detector", SRDS
/// 2004; the variant used by Akka and Cassandra): it learns the distribution
/// of heartbeat inter-arrival times on *this* link and reports a suspicion
/// level φ = -log10(P(a heartbeat arrives this late or later)). φ = 1 means
/// a 10 % chance the peer is still alive, φ = 8 about 10⁻⁸.
///
/// Effect: on a steady link the silence needed to declare failure shrinks
/// towards [MembershipConfig.minFailAfter]; on a jittery link it grows (up
/// to [MembershipConfig.maxFailAfter]).
///
/// φ alone assumes roughly normal inter-arrival times. Phone Wi-Fi instead
/// has rare multi-second stalls (roaming, deep power save) between which the
/// link is perfectly regular, so φ would still call a 4 s stall a failure.
/// The detector therefore also refuses to declare failure before
/// [stallMargin] × the longest gap this link survived within the window
/// (an adaptive-timeout safety margin in the spirit of Chen, Toueg and
/// Aguilera's estimator): a link that recovered from a 4.5 s stall a few
/// minutes ago is given more than 4.5 s next time.
library;

import 'dart:math';

import '../config/sync_config.dart';

abstract class FailureDetector {
  /// A heartbeat (periodic liveness message) arrived. Its inter-arrival time
  /// is learned.
  void heartbeat(int nowUs);

  /// Any message arrived (proves liveness, but its timing is not learned:
  /// clock-probe bursts would make the link look faster than it is).
  void traffic(int nowUs);

  /// Microseconds since the last message of any kind.
  int silentUs(int nowUs);

  bool isSuspect(int nowUs);
  bool isFailed(int nowUs);

  /// Suspicion level (fixed detector: silence relative to the thresholds).
  double phi(int nowUs);

  static FailureDetector forConfig(MembershipConfig c, int nowUs) => c.detector == FailureDetectorKind.phi
      ? PhiAccrualDetector(config: c, nowUs: nowUs)
      : FixedTimeoutDetector(config: c, nowUs: nowUs);
}

/// The previous behaviour: fixed silence thresholds.
class FixedTimeoutDetector implements FailureDetector {
  final MembershipConfig config;
  int _lastUs;
  FixedTimeoutDetector({required this.config, required int nowUs}) : _lastUs = nowUs;

  @override
  void heartbeat(int nowUs) => traffic(nowUs);

  @override
  void traffic(int nowUs) {
    if (nowUs > _lastUs) _lastUs = nowUs;
  }

  @override
  int silentUs(int nowUs) => nowUs - _lastUs;

  @override
  bool isSuspect(int nowUs) => silentUs(nowUs) >= config.suspectAfter.inMicroseconds;

  @override
  bool isFailed(int nowUs) => silentUs(nowUs) >= config.failAfter.inMicroseconds;

  @override
  double phi(int nowUs) => silentUs(nowUs) / config.failAfter.inMicroseconds * config.failPhi;
}

class PhiAccrualDetector implements FailureDetector {
  final MembershipConfig config;

  /// Number of inter-arrival samples kept.
  final int windowSize;

  final List<int> _intervals = [];
  int _sum = 0;
  int _sumSquares = 0;
  int? _lastHeartbeatUs;
  int _lastTrafficUs;

  /// Failure needs at least this multiple of the longest gap in the window.
  final double stallMargin;

  PhiAccrualDetector({required this.config, required int nowUs, this.windowSize = 300, this.stallMargin = 1.25})
      : _lastTrafficUs = nowUs {
    // Seed with the nominal interval so the first seconds behave sensibly
    // (Akka does the same with its "first heartbeat estimate").
    final hb = config.heartbeatInterval.inMicroseconds;
    _add(hb - hb ~/ 4);
    _add(hb + hb ~/ 4);
  }

  int get sampleCount => _intervals.length;

  /// Longest heartbeat gap in the window (µs).
  int get maxGapUs => _intervals.isEmpty ? 0 : _intervals.reduce(max);

  double get meanUs => _intervals.isEmpty ? 0 : _sum / _intervals.length;

  double get stdDevUs {
    if (_intervals.isEmpty) return 0;
    final m = meanUs;
    final v = _sumSquares / _intervals.length - m * m;
    return v <= 0 ? 0 : sqrt(v);
  }

  void _add(int us) {
    _intervals.add(us);
    _sum += us;
    _sumSquares += us * us;
    if (_intervals.length > windowSize) {
      final old = _intervals.removeAt(0);
      _sum -= old;
      _sumSquares -= old * old;
    }
  }

  @override
  void heartbeat(int nowUs) {
    final last = _lastHeartbeatUs;
    if (last != null && nowUs > last) _add(nowUs - last);
    _lastHeartbeatUs = nowUs;
    traffic(nowUs);
  }

  @override
  void traffic(int nowUs) {
    if (nowUs > _lastTrafficUs) _lastTrafficUs = nowUs;
  }

  @override
  int silentUs(int nowUs) => nowUs - _lastTrafficUs;

  @override
  double phi(int nowUs) {
    final t = silentUs(nowUs).toDouble();
    final mean = meanUs + config.acceptablePause.inMicroseconds;
    final sd = max(stdDevUs, config.minStdDev.inMicroseconds.toDouble());
    return phiOf(t, mean, sd);
  }

  /// φ for a silence of [t] given a normal inter-arrival distribution,
  /// using the logistic approximation of the normal CDF (as in Akka).
  static double phiOf(double t, double mean, double sd) {
    final y = (t - mean) / sd;
    final e = exp(-y * (1.5976 + 0.070566 * y * y));
    final p = t > mean ? e / (1 + e) : 1 - 1 / (1 + e);
    if (p <= 0) return double.maxFinite;
    return -log(p) / ln10;
  }

  /// Silence after which [isFailed] turns true right now (for logs/tests).
  Duration failThreshold() {
    var lo = max(config.minFailAfter.inMicroseconds, (maxGapUs * stallMargin).round());
    var hi = config.maxFailAfter.inMicroseconds;
    if (lo >= hi) return config.maxFailAfter;
    if (phiOf(lo.toDouble(), meanUs + config.acceptablePause.inMicroseconds, _sd) >= config.failPhi) {
      return Duration(microseconds: lo);
    }
    while (hi - lo > 1000) {
      final mid = (lo + hi) ~/ 2;
      if (phiOf(mid.toDouble(), meanUs + config.acceptablePause.inMicroseconds, _sd) >= config.failPhi) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return Duration(microseconds: hi);
  }

  double get _sd => max(stdDevUs, config.minStdDev.inMicroseconds.toDouble());

  @override
  bool isSuspect(int nowUs) {
    final s = silentUs(nowUs);
    if (s < config.minSuspectAfter.inMicroseconds) return false;
    return s >= config.maxFailAfter.inMicroseconds || phi(nowUs) >= config.suspectPhi;
  }

  @override
  bool isFailed(int nowUs) {
    final s = silentUs(nowUs);
    if (s >= config.maxFailAfter.inMicroseconds) return true;
    if (s < config.minFailAfter.inMicroseconds || s < maxGapUs * stallMargin) return false;
    return phi(nowUs) >= config.failPhi;
  }
}
