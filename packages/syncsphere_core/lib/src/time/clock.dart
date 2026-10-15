/// Clock abstractions.
///
/// All scheduling and elapsed-time logic in SyncSphere uses a *monotonic*
/// clock expressed in integer microseconds. Wall-clock time is used only for
/// human-readable logs. Each device has its own monotonic clock with an
/// arbitrary epoch, so timestamps from different devices are never compared
/// directly: they are converted through a [ClockEstimate]
/// (see `clock_sync.dart`).
library;

/// A monotonic time source in microseconds. The epoch is arbitrary but fixed
/// for the lifetime of the instance.
abstract class MonotonicClock {
  int nowMicros();
}

/// Production clock backed by a [Stopwatch] (CLOCK_MONOTONIC on Linux and
/// Android in the Dart VM). Its epoch is the moment the process first touched
/// the clock, so it must be bridged explicitly to any native clock domain.
class SystemMonotonicClock implements MonotonicClock {
  SystemMonotonicClock._();

  static final SystemMonotonicClock instance = SystemMonotonicClock._();
  static final Stopwatch _sw = Stopwatch()..start();

  @override
  int nowMicros() => _sw.elapsedMicroseconds;
}

/// Manually driven clock for unit tests.
class ManualClock implements MonotonicClock {
  int _now;
  ManualClock([this._now = 0]);

  @override
  int nowMicros() => _now;

  void advance(Duration d) => _now += d.inMicroseconds;
  void advanceMicros(int us) => _now += us;
  void set(int us) => _now = us;
}

/// A clock derived from a reference time source with a fixed offset and a
/// constant frequency error. Used by the simulator to model a device's
/// imperfect oscillator: `local = offset + reference * (1 + skewPpm / 1e6)`.
class DerivedClock implements MonotonicClock {
  final int Function() referenceMicros;
  final int offsetMicros;
  final double skewPpm;

  DerivedClock({
    required this.referenceMicros,
    required this.offsetMicros,
    this.skewPpm = 0,
  });

  @override
  int nowMicros() {
    final ref = referenceMicros();
    return offsetMicros + ref + (ref * skewPpm / 1e6).round();
  }

  /// Inverse mapping, used by the simulator for ground-truth metrics.
  int toReference(int localMicros) =>
      ((localMicros - offsetMicros) / (1 + skewPpm / 1e6)).round();
}
