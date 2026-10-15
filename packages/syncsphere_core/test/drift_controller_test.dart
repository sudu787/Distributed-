import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  const cfg = DriftConfig();

  DriftDecision feed(DriftController c, double errMs, int nowMs, {double uncMs = 1}) =>
      c.onMeasurement(errorUs: errMs * 1000, uncertaintyUs: uncMs * 1000, nowUs: nowMs * 1000);

  test('waits for enough samples before acting', () {
    final c = DriftController(cfg, rateSupported: true);
    expect(feed(c, 100, 0).newRate, isNull);
    expect(feed(c, 100, 500).newRate, isNull);
    expect(c.mode, CorrectionMode.waiting);
  });

  test('small error: stays in sync, no rate change', () {
    final c = DriftController(cfg, rateSupported: true);
    for (var i = 0; i < 10; i++) {
      final d = feed(c, 3, i * 500);
      expect(d.newRate, isNull);
      expect(d.resync, isFalse);
    }
    expect(c.mode, CorrectionMode.inSync);
  });

  test('moderate error: proportional rate correction with sign', () {
    final c = DriftController(cfg, rateSupported: true);
    DriftDecision? last;
    for (var i = 0; i < 3; i++) {
      last = feed(c, 40, i * 500); // 40 ms ahead
    }
    expect(c.mode, CorrectionMode.rateCorrecting);
    expect(last!.newRate, lessThan(1.0)); // ahead → slow down
    expect(last.newRate, closeTo(1 - 0.040 / 4, 0.0006));

    final c2 = DriftController(cfg, rateSupported: true);
    for (var i = 0; i < 3; i++) {
      last = feed(c2, -40, i * 500);
    }
    expect(c2.rate, greaterThan(1.0));
  });

  test('rate is clamped to maxRateDelta', () {
    final c = DriftController(cfg, rateSupported: true);
    for (var i = 0; i < 3; i++) {
      feed(c, 200, i * 500);
    }
    expect(c.rate, closeTo(1 - cfg.maxRateDelta, 1e-9));
  });

  test('hysteresis: needs to drop below exit threshold to leave correction', () {
    final c = DriftController(cfg, rateSupported: true);
    for (var i = 0; i < 3; i++) {
      feed(c, 20, i * 500);
    }
    expect(c.mode, CorrectionMode.rateCorrecting);
    // Between exit (3 ms) and enter (8 ms): remain correcting.
    for (var i = 3; i < 8; i++) {
      feed(c, 5, i * 500);
    }
    expect(c.mode, CorrectionMode.rateCorrecting);
    for (var i = 8; i < 13; i++) {
      feed(c, 1, i * 500);
    }
    expect(c.mode, CorrectionMode.inSync);
    expect(c.rate, 1.0);
  });

  test('large error: resync only after confirmations, then cooldown', () {
    final c = DriftController(cfg, rateSupported: true);
    var resyncs = 0;
    for (var i = 0; i < 4; i++) {
      if (feed(c, 600, i * 500).resync) resyncs++;
    }
    expect(resyncs, 1);
    expect(c.mode, CorrectionMode.resyncing);
    // While resyncing measurements are ignored.
    expect(feed(c, 600, 2500).resync, isFalse);
    c.reset();
    // Within the cooldown no second seek even if error persists.
    for (var i = 0; i < 6; i++) {
      expect(feed(c, 600, 3000 + i * 100).resync, isFalse);
    }
    // After cooldown it may seek again.
    var later = false;
    for (var i = 0; i < 6; i++) {
      later |= feed(c, 600, 9000 + i * 500).resync;
    }
    expect(later, isTrue);
  });

  test('single outlier does not trigger seek (median filter)', () {
    final c = DriftController(cfg, rateSupported: true);
    for (var i = 0; i < 5; i++) {
      feed(c, 1, i * 500);
    }
    expect(feed(c, 5000, 3000).resync, isFalse);
    expect(feed(c, 2, 3500).resync, isFalse);
    expect(c.seekCount, 0);
  });

  test('clock uncertainty suppresses unjustified seeks', () {
    final c = DriftController(cfg, rateSupported: true);
    var resync = false;
    for (var i = 0; i < 6; i++) {
      resync |= feed(c, 300, i * 500, uncMs: 200).resync;
    }
    expect(resync, isFalse);
  });

  test('without rate control uses the lower seek threshold', () {
    final c = DriftController(cfg, rateSupported: false);
    var resync = false;
    for (var i = 0; i < 4; i++) {
      final d = feed(c, 60, i * 500);
      expect(d.newRate, isNull);
      resync |= d.resync;
    }
    expect(resync, isTrue);
  });
}
