import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  const s = 1000000;
  const cfg = MembershipConfig();

  PhiAccrualDetector steady({int beats = 60, int jitterUs = 0}) {
    final d = PhiAccrualDetector(config: cfg, nowUs: 0);
    var t = 0;
    for (var i = 0; i < beats; i++) {
      t += s + (i.isEven ? jitterUs : -jitterUs);
      d.heartbeat(t);
    }
    return d;
  }

  test('phi grows with silence and is ~0 right after a heartbeat', () {
    final d = steady();
    final last = 60 * s;
    expect(d.phi(last), lessThan(0.5));
    expect(d.phi(last + 2 * s), greaterThan(d.phi(last + s)));
    expect(d.phi(last + 3 * s), greaterThan(cfg.failPhi));
  });

  test('steady link: declared failed at the 4 s floor instead of the fixed 8 s', () {
    final d = steady();
    final last = 60 * s;
    expect(d.isFailed(last + 3900000), isFalse, reason: 'never before minFailAfter');
    expect(d.isFailed(last + 4100000), isTrue);
    final fixed = FixedTimeoutDetector(config: cfg, nowUs: last);
    expect(fixed.isFailed(last + 7900000), isFalse);
    expect(fixed.isFailed(last + 8100000), isTrue);
  });

  test('jittery link: the threshold moves out', () {
    final calm = steady();
    final jittery = steady(jitterUs: 700000);
    expect(jittery.failThreshold(), greaterThan(calm.failThreshold()));
    expect(calm.failThreshold(), cfg.minFailAfter);
  });

  test('a link that survived a 5 s stall gets more than 5 s next time', () {
    final d = steady();
    var t = 60 * s;
    t += 5 * s; // stall: heartbeats held, then delivered in a burst
    d.heartbeat(t);
    for (var i = 0; i < 4; i++) {
      t += 1000;
      d.heartbeat(t);
    }
    for (var i = 0; i < 30; i++) {
      t += s;
      d.heartbeat(t);
    }
    expect(d.maxGapUs, greaterThanOrEqualTo(5 * s));
    expect(d.isFailed(t + 6 * s), isFalse);
    expect(d.isFailed(t + 6300000), isTrue);
  });

  test('never later than maxFailAfter, never suspect before minSuspectAfter', () {
    final d = steady(jitterUs: 900000);
    final last = d.silentUs(0) * -1; // last traffic time
    expect(d.isSuspect(last + 1900000), isFalse);
    expect(d.isFailed(last + cfg.maxFailAfter.inMicroseconds), isTrue);
  });

  test('any traffic proves liveness; only heartbeats are learned', () {
    final d = steady();
    final n = d.sampleCount;
    d.traffic(60 * s + 3 * s);
    expect(d.sampleCount, n);
    expect(d.isFailed(60 * s + 5 * s), isFalse);
  });

  test('config round trip and hostile values are clamped', () {
    const c = MembershipConfig(detector: FailureDetectorKind.fixed, failPhi: 9, minFailAfter: Duration(seconds: 5));
    final back = MembershipConfig.fromJson(c.toJson());
    expect(back.detector, FailureDetectorKind.fixed);
    expect(back.failPhi, 9);
    expect(back.minFailAfter, const Duration(seconds: 5));
    final hostile = MembershipConfig.fromJson({'detector': 'nope', 'failPhi': 1e9, 'minStdDevMs': 0});
    expect(hostile.detector, FailureDetectorKind.phi);
    expect(hostile.failPhi, 50);
    expect(hostile.minStdDev, const Duration(milliseconds: 10));
  });

  test('membership sweep uses the phi detector', () {
    final m = MembershipManager(cfg);
    final keys = RoomKey.derive(roomId: 'r', joinKey: 'K', iterations: 1).sessionKeys('dev-1', 'a', 'b');
    final member = m.admit(
        deviceId: 'dev-1',
        displayName: 'P',
        defaultRole: ParticipantRole.listener,
        caps: const DeviceCapabilities(rateControl: true, backend: 'test'),
        sessionId: 's',
        keys: keys,
        nowUs: 0)!;
    var t = 0;
    for (var i = 0; i < 30; i++) {
      t += s;
      m.touch(member, t);
      m.heartbeat(member, t);
    }
    expect(m.sweep(t + 3 * s).changed, isTrue, reason: 'suspect after ~2.5 s of silence');
    expect(member.connection, ConnectionStatus.suspect);
    expect(m.sweep(t + 4200000).failed, [member]);
  });
}
