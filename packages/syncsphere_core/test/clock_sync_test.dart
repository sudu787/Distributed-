import 'dart:math';

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

/// Builds a sample for a remote clock that is [offset] µs ahead, with the
/// given one-way delays and responder processing time.
ClockSample exchange(int t1, int offset,
    {int forward = 1000, int backward = 1000, int processing = 50, double skewPpm = 0}) {
  int remote(int local) => local + offset + (local * skewPpm / 1e6).round();
  final t2 = remote(t1 + forward);
  final t3 = t2 + processing;
  // local time when responder sent: invert remote() approximately
  final sendLocal = t1 + forward + processing;
  final t4 = sendLocal + backward;
  return ClockSample(t1, t2, t3, t4);
}

void main() {
  group('ClockSample', () {
    test('standard offset/delay formulas', () {
      // remote is 5000 µs ahead, symmetric 1 ms delays, 50 µs processing.
      final s = exchange(10000, 5000);
      expect(s.offset, 5000);
      expect(s.delay, 2000);
      expect(s.lowerBound, lessThanOrEqualTo(5000));
      expect(s.upperBound, greaterThanOrEqualTo(5000));
    });

    test('asymmetry biases the midpoint by (df-db)/2 but stays in bounds', () {
      final s = exchange(0, 5000, forward: 9000, backward: 1000);
      expect(s.offset, 5000 + (9000 - 1000) / 2);
      expect(5000, inInclusiveRange(s.lowerBound, s.upperBound));
    });

    test('malformed samples are detected', () {
      expect(const ClockSample(10, 0, 0, 5).isWellFormed, isFalse);
      expect(const ClockSample(0, 10, 5, 20).isWellFormed, isFalse);
    });
  });

  group('ClockSyncEstimator', () {
    test('converges to true offset with symmetric jitter', () {
      final rnd = Random(1);
      final est = ClockSyncEstimator();
      var t = 0;
      for (var i = 0; i < 30; i++) {
        final d = 800 + rnd.nextInt(4000);
        final s = exchange(t, -123456, forward: d, backward: d);
        est.addSample(s, nowLocalMicros: s.t4);
        t += 100000;
      }
      final e = est.estimate!;
      expect(e.offsetMicros, closeTo(-123456, 50));
      // Before skew is estimated, uncertainty includes maxSkewPpm × sample age.
      expect(e.uncertaintyMicros, lessThan(1500));
      // The true offset must lie inside the reported interval.
      expect((e.offsetMicros - -123456).abs(), lessThanOrEqualTo(e.uncertaintyMicros));
    });

    test('random asymmetric delays: true offset stays within uncertainty', () {
      final rnd = Random(7);
      for (var trial = 0; trial < 50; trial++) {
        final est = ClockSyncEstimator();
        final trueOffset = rnd.nextInt(2000000) - 1000000;
        var t = rnd.nextInt(1000000);
        for (var i = 0; i < 12; i++) {
          final s = exchange(t, trueOffset,
              forward: 500 + rnd.nextInt(20000), backward: 500 + rnd.nextInt(20000));
          est.addSample(s, nowLocalMicros: s.t4);
          t += 50000;
        }
        final e = est.estimate!;
        expect((e.offsetMicros - trueOffset).abs(),
            lessThanOrEqualTo(e.uncertaintyMicros + 1),
            reason: 'trial $trial');
      }
    });

    test('interval intersection beats any single sample', () {
      // One sample with tiny forward delay, another with tiny backward delay.
      final est = ClockSyncEstimator();
      final a = exchange(0, 1000, forward: 100, backward: 10000);
      final b = exchange(20000, 1000, forward: 10000, backward: 100);
      est.addSample(a, nowLocalMicros: a.t4);
      est.addSample(b, nowLocalMicros: b.t4);
      final e = est.estimate!;
      expect(e.uncertaintyMicros, lessThan(min(a.delay, b.delay) / 2));
      expect((e.offsetMicros - 1000).abs(), lessThanOrEqualTo(e.uncertaintyMicros));
    });

    test('rejects outliers via Marzullo majority', () {
      final est = ClockSyncEstimator();
      var t = 0;
      for (var i = 0; i < 9; i++) {
        final s = exchange(t, 5000, forward: 1500, backward: 1500);
        est.addSample(s, nowLocalMicros: s.t4);
        t += 10000;
      }
      // A corrupted sample claiming a 1 s offset with a small delay.
      final bad = exchange(t, 1005000, forward: 500, backward: 500);
      est.addSample(bad, nowLocalMicros: bad.t4);
      expect(est.estimate!.offsetMicros, closeTo(5000, 1600));
    });

    test('rejects samples with excessive delay', () {
      final est = ClockSyncEstimator(
          config: const ClockSyncConfig(maxRtt: Duration(milliseconds: 100)));
      final s = exchange(0, 0, forward: 80000, backward: 80000);
      final r = est.addSample(s, nowLocalMicros: s.t4);
      expect(r.accepted, isFalse);
      expect(r.rejection, SampleRejection.delayTooLarge);
    });

    test('estimates skew and extrapolates', () {
      final rnd = Random(3);
      final est = ClockSyncEstimator();
      const skew = 80.0; // ppm
      var t = 0;
      for (var i = 0; i < 60; i++) {
        final d = 1000 + rnd.nextInt(3000);
        final s = exchange(t, 2000, forward: d, backward: d, skewPpm: skew);
        est.addSample(s, nowLocalMicros: s.t4);
        t += 1000000; // 1 s
      }
      final e = est.estimate!;
      expect(e.skewPpm, closeTo(skew, 5));
      // Extrapolate 30 s into the future.
      final future = t + 30000000;
      final truth = 2000 + future * skew / 1e6;
      expect((e.offsetAt(future) - truth).abs(), lessThan(e.uncertaintyAt(future)));
    });

    test('toLocal inverts toRemote', () {
      const e = ClockEstimate(
        referenceLocalMicros: 1000000,
        offsetMicros: 5e6,
        skewPpm: 50,
        uncertaintyMicros: 100,
        skewUncertaintyPpm: 10,
        samplesInWindow: 1,
        samplesUsed: 1,
        minDelayMicros: 0,
        newestSampleLocalMicros: 1000000,
        method: 'test',
      );
      for (final l in [0, 123456789, 99999999999]) {
        expect(e.toLocal(e.toRemote(l)), closeTo(l, 1));
      }
    });

    test('old samples age out', () {
      final est = ClockSyncEstimator(
          config: const ClockSyncConfig(maxSampleAge: Duration(seconds: 10)));
      final s = exchange(0, 0);
      est.addSample(s, nowLocalMicros: s.t4);
      final s2 = exchange(20000000, 0);
      est.addSample(s2, nowLocalMicros: s2.t4);
      expect(est.estimate!.samplesInWindow, 1);
    });
  });

  group('ClockDomainBridge', () {
    test('recovers offset between two domains', () async {
      final local = ManualClock(1000);
      const nativeOffset = 987654321;
      final bridge = ClockDomainBridge(
        local: local,
        readRemoteMicros: () async {
          local.advanceMicros(40);
          final v = local.nowMicros() + nativeOffset;
          local.advanceMicros(60);
          return v;
        },
      );
      final e = await bridge.calibrate(samples: 8);
      expect(e.offsetMicros, closeTo(nativeOffset, 60));
      expect(bridge.toLocal(bridge.toRemote(5000)), closeTo(5000, 1));
    });
  });
}
