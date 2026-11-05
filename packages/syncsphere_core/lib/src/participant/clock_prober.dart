/// When a participant sends clock probes: a quick burst after (re)joining,
/// then a fast or slow steady pace depending on whether the estimate is
/// already tight. Split out of `ParticipantSession`, which sends the
/// requests and feeds the answers to the estimator.
library;

import 'dart:async';

import '../config/sync_config.dart';
import '../protocol/messages.dart';
import '../time/clock.dart';
import '../time/clock_sync.dart';

class ClockProber {
  final MonotonicClock clock;
  final ClockSyncConfig Function() config;
  final ClockEstimate? Function() estimate;

  /// Whether the link is up (probes are skipped while it is not).
  final bool Function() active;
  final void Function(ClockRequestMsg m) send;

  Timer? _timer;
  int _id = 0;
  int _burstRemaining = 0;
  final Map<int, int> _outstanding = {};

  ClockProber(
      {required this.clock, required this.config, required this.estimate, required this.active, required this.send});

  /// Starts probing with a fresh burst.
  void start() {
    _burstRemaining = config().burstSamples;
    _schedule(Duration.zero);
  }

  void stop() {
    _timer?.cancel();
    _outstanding.clear();
  }

  /// The send time of probe [id] if it is outstanding and matches [t1]
  /// (null: unknown, duplicate or tampered response).
  int? answered(int id, int t1) {
    final sent = _outstanding.remove(id);
    return sent == null || sent != t1 ? null : sent;
  }

  /// Forgets probes older than the probe timeout.
  void expire() {
    final timeout = config().probeTimeout.inMicroseconds;
    final now = clock.nowMicros();
    _outstanding.removeWhere((_, t1) => now - t1 > timeout);
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      if (!active()) return;
      final id = ++_id;
      final t1 = clock.nowMicros();
      final c = config();
      _outstanding[id] = t1;
      send(ClockRequestMsg(id, t1));
      Duration next;
      if (_burstRemaining > 0) {
        _burstRemaining--;
        next = c.burstSpacing;
      } else {
        final e = estimate();
        final stable = e != null && e.uncertaintyMicros <= c.stableUncertainty.inMicroseconds && e.samplesInWindow >= 8;
        next = stable ? c.slowInterval : c.fastInterval;
      }
      _schedule(next);
    });
  }
}
