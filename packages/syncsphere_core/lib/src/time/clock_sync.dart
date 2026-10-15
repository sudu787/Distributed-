/// NTP-inspired clock-offset estimation between two monotonic clock domains.
///
/// ## Four-timestamp exchange
///
/// The *initiator* (here: a participant) sends a probe at local time `t1`.
/// The *responder* (the coordinator) stamps receipt `t2` and reply `t3` with
/// its own clock. The initiator stamps receipt `t4`. Then
///
///     offset θ = ((t2 - t1) + (t3 - t4)) / 2      (responder − initiator)
///     delay  δ = (t4 - t1) - (t3 - t2)
///
/// This is the standard formula; the roles of the specification's
/// "coordinator"/"participant" are mirrored because the participant is the
/// party that needs the offset to schedule audio. The sign convention is
/// always *responder minus initiator*.
///
/// ## Why asymmetry limits accuracy
///
/// With forward delay `df ≥ 0` and backward delay `db ≥ 0`, the true offset
/// is `θ_true = θ − (df − db) / 2`. The exchange cannot observe `df − db`,
/// so a single sample only proves that
///
///     θ_true ∈ [t3 − t4, t2 − t1]     (width = δ, midpoint = θ)
///
/// Wi-Fi is frequently asymmetric (power-save buffering of downlink frames,
/// contention, retransmissions), so the midpoint can be wrong by up to δ/2.
/// No amount of averaging removes a *systematic* asymmetry; it only shrinks
/// random error.
///
/// ## Estimator
///
/// 1. Each valid sample contributes the hard interval above.
/// 2. Intervals are projected to a common reference time using the
///    estimated relative clock skew, and widened by the skew uncertainty
///    times their age.
/// 3. Marzullo's algorithm finds the region consistent with the largest
///    number of samples; samples outside it are outliers. Intersecting
///    intervals from different samples (one with a small forward delay,
///    another with a small backward delay) can bound the offset more tightly
///    than any single minimum-RTT sample.
/// 4. The estimate is the midpoint of that region and the reported
///    uncertainty its half-width (never below a resolution floor).
/// 5. Relative skew (oscillator frequency error, typically ±10–100 ppm) is
///    estimated by a weighted least-squares fit over the minimum-delay
///    sample in each time bucket.
library;

import 'dart:math' as math;

import '../config/sync_config.dart';

/// One four-timestamp exchange. `t1`/`t4` are in the initiator's clock,
/// `t2`/`t3` in the responder's clock, all in microseconds.
class ClockSample {
  final int t1;
  final int t2;
  final int t3;
  final int t4;

  const ClockSample(this.t1, this.t2, this.t3, this.t4);

  /// Round-trip network delay excluding responder processing time.
  int get delay => (t4 - t1) - (t3 - t2);

  /// Offset estimate (responder − initiator).
  double get offset => ((t2 - t1) + (t3 - t4)) / 2.0;

  /// Hard lower/upper bounds on the true offset (assuming delays ≥ 0).
  int get lowerBound => t3 - t4;
  int get upperBound => t2 - t1;

  /// Initiator-local time this sample describes.
  int get localTime => t1 + (t4 - t1) ~/ 2;

  bool get isWellFormed => t4 >= t1 && t3 >= t2 && delay >= 0;

  @override
  String toString() => 'ClockSample(θ=${offset.toStringAsFixed(1)}µs, '
      'δ=$delay µs, at=$localTime)';
}

/// Why a sample was not accepted.
enum SampleRejection { malformed, delayTooLarge, stale }

/// Result of offering a sample to the estimator.
class SampleResult {
  final bool accepted;
  final SampleRejection? rejection;
  const SampleResult.accepted()
      : accepted = true,
        rejection = null;
  const SampleResult.rejected(SampleRejection r)
      : accepted = false,
        rejection = r;
}

/// A snapshot of the current offset estimate, projectable to any local time.
class ClockEstimate {
  /// Local time at which [offsetMicros] and [uncertaintyMicros] apply.
  final int referenceLocalMicros;

  /// Estimated (remote − local) at the reference time.
  final double offsetMicros;

  /// Estimated relative frequency error of the remote clock, in ppm.
  final double skewPpm;

  /// Half-width of the interval that should contain the true offset at the
  /// reference time.
  final double uncertaintyMicros;

  /// How much the uncertainty grows per second of extrapolation, in ppm.
  final double skewUncertaintyPpm;

  final int samplesInWindow;
  final int samplesUsed;
  final int minDelayMicros;

  /// Local time of the newest sample, for sample-age reporting.
  final int newestSampleLocalMicros;

  /// Short label of the method that produced this estimate.
  final String method;

  const ClockEstimate({
    required this.referenceLocalMicros,
    required this.offsetMicros,
    required this.skewPpm,
    required this.uncertaintyMicros,
    required this.skewUncertaintyPpm,
    required this.samplesInWindow,
    required this.samplesUsed,
    required this.minDelayMicros,
    required this.newestSampleLocalMicros,
    required this.method,
  });

  /// The estimate used by the coordinator for its own clock: exact.
  const ClockEstimate.identity()
      : referenceLocalMicros = 0,
        offsetMicros = 0,
        skewPpm = 0,
        uncertaintyMicros = 0,
        skewUncertaintyPpm = 0,
        samplesInWindow = 0,
        samplesUsed = 0,
        minDelayMicros = 0,
        newestSampleLocalMicros = 0,
        method = 'identity';

  bool get isIdentity => method == 'identity';

  double offsetAt(int localMicros) =>
      offsetMicros + skewPpm * 1e-6 * (localMicros - referenceLocalMicros);

  double uncertaintyAt(int localMicros) =>
      uncertaintyMicros +
      skewUncertaintyPpm * 1e-6 * (localMicros - referenceLocalMicros).abs();

  /// Converts a local monotonic timestamp into the remote clock domain.
  int toRemote(int localMicros) => localMicros + offsetAt(localMicros).round();

  /// Converts a remote timestamp into the local domain (exact inverse of
  /// [toRemote]: solves `r = l + o + s·(l − ref)` for `l`).
  int toLocal(int remoteMicros) {
    final s = skewPpm * 1e-6;
    return ((remoteMicros - offsetMicros + s * referenceLocalMicros) / (1 + s))
        .round();
  }

  int sampleAgeMicros(int localNow) => localNow - newestSampleLocalMicros;

  Map<String, Object?> toJson() => {
        'offsetUs': offsetMicros.round(),
        'skewPpm': double.parse(skewPpm.toStringAsFixed(3)),
        'uncertaintyUs': uncertaintyMicros.round(),
        'samples': samplesInWindow,
        'used': samplesUsed,
        'minDelayUs': minDelayMicros,
        'method': method,
      };
}

/// Sliding-window clock-offset estimator. Pure and deterministic: feed it
/// samples, read [estimate]. Not thread-safe (Dart isolates are
/// single-threaded).
class ClockSyncEstimator {
  final ClockSyncConfig config;

  /// Lower bound on reported uncertainty: timestamp resolution plus
  /// scheduling noise of reading the clock in the message handler.
  final int uncertaintyFloorMicros;

  final List<ClockSample> _samples = [];
  ClockEstimate? _estimate;
  int _rejected = 0;
  int _accepted = 0;

  ClockSyncEstimator({
    this.config = const ClockSyncConfig(),
    this.uncertaintyFloorMicros = 50,
  });

  ClockEstimate? get estimate => _estimate;
  int get acceptedCount => _accepted;
  int get rejectedCount => _rejected;
  List<ClockSample> get samples => List.unmodifiable(_samples);

  /// Recent round-trip delays (µs), oldest first.
  List<int> get recentDelays => [for (final s in _samples) s.delay];

  /// Delay percentile over the window, e.g. `delayPercentile(0.95)`.
  int delayPercentile(double p) {
    if (_samples.isEmpty) return 0;
    final d = recentDelays..sort();
    final idx = ((d.length - 1) * p).round().clamp(0, d.length - 1);
    return d[idx];
  }

  void reset() {
    _samples.clear();
    _estimate = null;
  }

  SampleResult addSample(ClockSample s, {required int nowLocalMicros}) {
    if (!s.isWellFormed) {
      _rejected++;
      return const SampleResult.rejected(SampleRejection.malformed);
    }
    if (s.delay > config.maxRtt.inMicroseconds) {
      _rejected++;
      return const SampleResult.rejected(SampleRejection.delayTooLarge);
    }
    if (nowLocalMicros - s.localTime > config.maxSampleAge.inMicroseconds) {
      _rejected++;
      return const SampleResult.rejected(SampleRejection.stale);
    }
    _samples.add(s);
    _samples.sort((a, b) => a.localTime.compareTo(b.localTime));
    _prune(nowLocalMicros);
    _accepted++;
    _recompute();
    return const SampleResult.accepted();
  }

  void _prune(int now) {
    final maxAge = config.maxSampleAge.inMicroseconds;
    _samples.removeWhere((s) => now - s.localTime > maxAge);
    while (_samples.length > config.windowSize) {
      _samples.removeAt(0);
    }
  }

  void _recompute() {
    if (_samples.isEmpty) {
      _estimate = null;
      return;
    }
    final skew = _estimateSkew();
    final ref = _samples.last.localTime;
    final skewPpm = skew?.ppm ?? 0.0;
    final skewUnc = skew?.uncertaintyPpm ?? config.maxSkewPpm;

    // Project each sample's hard interval to the reference time.
    final intervals = <_Interval>[];
    for (final s in _samples) {
      final dt = ref - s.localTime;
      final shift = skewPpm * 1e-6 * dt;
      final widen = skewUnc * 1e-6 * dt.abs();
      intervals.add(_Interval(
        s.lowerBound + shift - widen,
        s.upperBound + shift + widen,
      ));
    }

    final m = _marzullo(intervals);
    var minDelay = _samples.first.delay;
    for (final s in _samples) {
      if (s.delay < minDelay) minDelay = s.delay;
    }

    double offset;
    double unc;
    String method;
    int used;
    final majority = (intervals.length + 1) ~/ 2;
    if (m != null && m.count >= majority) {
      offset = (m.lo + m.hi) / 2;
      unc = (m.hi - m.lo) / 2;
      used = m.count;
      method = skew == null ? 'marzullo' : 'marzullo+skew';
    } else {
      // No majority agreement (should only happen with corrupted
      // timestamps): fall back to the minimum-delay sample.
      final best = _samples.reduce((a, b) => a.delay <= b.delay ? a : b);
      final dt = ref - best.localTime;
      offset = best.offset + skewPpm * 1e-6 * dt;
      unc = best.delay / 2 + skewUnc * 1e-6 * dt.abs();
      used = 1;
      method = 'min-delay-fallback';
    }
    if (unc < uncertaintyFloorMicros) unc = uncertaintyFloorMicros.toDouble();

    _estimate = ClockEstimate(
      referenceLocalMicros: ref,
      offsetMicros: offset,
      skewPpm: skewPpm,
      uncertaintyMicros: unc,
      skewUncertaintyPpm: skewUnc,
      samplesInWindow: _samples.length,
      samplesUsed: used,
      minDelayMicros: minDelay,
      newestSampleLocalMicros: ref,
      method: method,
    );
  }

  /// Weighted least squares of offset vs. local time over the minimum-delay
  /// sample of each time bucket. Returns null until enough data spans enough
  /// time for the slope to be meaningful.
  _Skew? _estimateSkew() {
    if (_samples.length < config.minSkewSamples) return null;
    final t0 = _samples.first.localTime;
    final span = _samples.last.localTime - t0;
    if (span < config.minSkewSpan.inMicroseconds) return null;

    const buckets = 8;
    final best = List<ClockSample?>.filled(buckets, null);
    for (final s in _samples) {
      final b = ((s.localTime - t0) * buckets ~/ (span + 1)).clamp(0, buckets - 1);
      final cur = best[b];
      if (cur == null || s.delay < cur.delay) best[b] = s;
    }
    final pts = best.whereType<ClockSample>().toList();
    if (pts.length < 4) return null;

    double sw = 0, sx = 0, sy = 0;
    final ws = <double>[];
    for (final p in pts) {
      final w = 1.0 / math.pow(p.delay / 2.0 + uncertaintyFloorMicros, 2);
      ws.add(w);
      sw += w;
      sx += w * (p.localTime - t0);
      sy += w * p.offset;
    }
    final mx = sx / sw, my = sy / sw;
    double sxx = 0, sxy = 0;
    for (var i = 0; i < pts.length; i++) {
      final dx = (pts[i].localTime - t0) - mx;
      sxx += ws[i] * dx * dx;
      sxy += ws[i] * dx * (pts[i].offset - my);
    }
    if (sxx <= 0) return null;
    final slope = sxy / sxx; // µs per µs
    var ppm = slope * 1e6;

    // Standard error of the slope from weighted residuals.
    double rss = 0;
    for (var i = 0; i < pts.length; i++) {
      final dx = (pts[i].localTime - t0) - mx;
      final r = pts[i].offset - (my + slope * dx);
      rss += ws[i] * r * r;
    }
    final dof = pts.length - 2;
    final se = dof > 0 ? math.sqrt(rss / dof / sxx) * 1e6 : config.maxSkewPpm;

    if (ppm.abs() > config.maxSkewPpm) {
      ppm = ppm.sign * config.maxSkewPpm;
    }
    final unc = math.max(config.residualSkewPpm, 2 * se);
    return _Skew(ppm, math.min(unc, config.maxSkewPpm));
  }
}

class _Skew {
  final double ppm;
  final double uncertaintyPpm;
  _Skew(this.ppm, this.uncertaintyPpm);
}

class _Interval {
  final double lo;
  final double hi;
  _Interval(this.lo, this.hi);
}

class _MarzulloResult {
  final double lo;
  final double hi;
  final int count;
  _MarzulloResult(this.lo, this.hi, this.count);
}

/// Marzullo's algorithm: the smallest interval contained in the largest
/// number of input intervals. Ties at an endpoint count as overlapping.
_MarzulloResult? _marzullo(List<_Interval> intervals) {
  if (intervals.isEmpty) return null;
  final edges = <(double, int)>[];
  for (final iv in intervals) {
    edges.add((iv.lo, -1)); // start
    edges.add((iv.hi, 1)); // end
  }
  // Starts sort before ends at equal values so touching intervals overlap.
  edges.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  var best = 0, cnt = 0;
  double bestLo = 0, bestHi = 0;
  for (var i = 0; i < edges.length; i++) {
    cnt -= edges[i].$2;
    if (cnt > best && i + 1 < edges.length) {
      best = cnt;
      bestLo = edges[i].$1;
      bestHi = edges[i + 1].$1;
    }
  }
  if (best == 0) return null;
  return _MarzulloResult(bestLo, bestHi, best);
}
