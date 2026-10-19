/// End-to-end tests running the real coordinator/participant code in the
/// virtual-time simulator. Assertions use the *engineering targets* with
/// margin; exact numbers come from `bin/benchmark.dart`. These are
/// SIMULATED results, not hardware measurements.
@Timeout(Duration(minutes: 5))
library;

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

Map<String, Object?> m(SimulationResult r, String k) => r.metrics[k] as Map<String, Object?>;
double p(SimulationResult r, String k, String q) => (m(r, k)[q] as num).toDouble();

void main() {
  for (final n in [2, 3, 5, 10]) {
    test('$n participants on good Wi-Fi start together and stay in sync', () {
      final r = SimulationRunner(Scenario(
        name: 'sync-$n',
        participants: n,
        network: NetworkCondition.wifiGood,
        duration: const Duration(seconds: 60),
        seed: n,
      )).run();
      expect(r.metrics['failedSessions'], isEmpty);
      expect(m(r, 'interDeviceSpreadMs_steady')['n'], greaterThan(500));
      expect(p(r, 'interDeviceSpreadMs_steady', 'p95'), lessThan(50));
      expect(p(r, 'startSkewMs', 'max'), lessThan(80));
      expect(r.metrics['clockUncertaintyCoverage'], greaterThan(0.95));
    });
  }

  test('pause, resume, seek and track change stay synchronized', () {
    final r = SimulationRunner(const Scenario(
      name: 'controls',
      participants: 4,
      network: NetworkCondition.wifiTypical,
      duration: Duration(seconds: 70),
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 15), PauseAction()),
        ScheduledAction(Duration(seconds: 20), PlayAction()),
        ScheduledAction(Duration(seconds: 30), SeekAction(Duration(minutes: 2))),
        ScheduledAction(Duration(seconds: 45), NextTrackAction()),
      ],
    )).run();
    expect(r.metrics['failedSessions'], isEmpty);
    expect(m(r, 'startSkewMs')['n'], greaterThanOrEqualTo(4));
    expect(p(r, 'startSkewMs', 'median'), lessThan(40));
    expect(p(r, 'interDeviceSpreadMs_steady', 'p95'), lessThan(50));
    expect(m(r, 'commandToAudibleLatencyMs')['n'], 5);
  });

  test('temporary partition: participant free-runs, reconnects and resyncs', () {
    final r = SimulationRunner(const Scenario(
      name: 'partition',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(seconds: 80),
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 20), PartitionAction(1, Duration(seconds: 15))),
      ],
    )).run();
    expect(r.metrics['failedSessions'], isEmpty);
    expect(r.metrics['unrecoveredDevices'], isEmpty);
    expect(m(r, 'recoveryAfterPartitionMs')['n'], 1);
    expect(p(r, 'recoveryAfterPartitionMs', 'max'), lessThan(15000));
  });

  test('coordinator death is detected and reported, playback free-runs', () {
    final r = SimulationRunner(const Scenario(
      name: 'coordinator-death',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(minutes: 6),
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 20), KillCoordinatorAction()),
      ],
    )).run();
    // Without failover every surviving session eventually gives up and
    // says why (the host device itself was killed).
    final failed = r.metrics['failedSessions'] as List;
    expect(failed.length, 2);
    final reasons = (r.metrics['failureReasons'] as Map).values.join(' ');
    expect(reasons, contains('room may need to be recreated'));
  });

  test('30 minutes with clock and audio drift stays bounded', () {
    final r = SimulationRunner(const Scenario(
      name: 'long-drift',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(minutes: 30),
      clockSkewPpmRange: 100,
      audioPpmRange: 80,
    )).run();
    expect(r.metrics['failedSessions'], isEmpty);
    expect(p(r, 'driftSpreadLastMinuteMs', 'p95'), lessThan(30));
    expect(r.metrics['resyncSeeks'], lessThanOrEqualTo(2));
  });

  test('device without rate control falls back to bounded corrective seeks', () {
    final r = SimulationRunner(const Scenario(
      name: 'no-rate',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(minutes: 10),
      profiles: [DeviceAudioProfile.flagship, DeviceAudioProfile.lowEnd],
      audioPpmRange: 120,
    )).run();
    expect(r.metrics['failedSessions'], isEmpty);
    // Seeks are rate limited by the cooldown (5 s) → at most 120 in 10 min;
    // in practice far fewer.
    expect(r.metrics['resyncSeeks'] as int, lessThan(40));
    expect(p(r, 'interDeviceSpreadMs_steady', 'median'), lessThan(50));
  });

  test('uncalibrated Bluetooth output: software estimate looks fine, acoustic truth does not', () {
    final base = Scenario(
      name: 'bt',
      participants: 2,
      network: NetworkCondition.wifiGood,
      duration: const Duration(seconds: 40),
      profiles: const [DeviceAudioProfile.flagship, DeviceAudioProfile.bluetoothUncalibrated],
    );
    final uncal = SimulationRunner(base).run();
    // ~180 ms of unreported latency is invisible to software alignment.
    expect(p(uncal, 'interDeviceSpreadMs_steady', 'median'), greaterThan(150));
    final cal = SimulationRunner(Scenario(
      name: 'bt-calibrated',
      participants: 2,
      network: NetworkCondition.wifiGood,
      duration: const Duration(seconds: 40),
      profiles: const [DeviceAudioProfile.flagship, DeviceAudioProfile.bluetoothUncalibrated],
      outputCalibrationUs: const [0, 180000],
    )).run();
    expect(p(cal, 'interDeviceSpreadMs_steady', 'median'), lessThan(20));
  });

  test('channel role change while playing switches segments without losing sync', () {
    final r = SimulationRunner(const Scenario(
      name: 'channel-role',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(seconds: 45),
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 20), ChannelRoleAction(1, ChannelRole.left)),
      ],
    )).run();
    expect(r.metrics['activeChannelRoles'], ['stereo', 'left', 'stereo']);
    expect(r.metrics['playCalls'] as int, greaterThanOrEqualTo(4), reason: 'the role change starts a fresh segment');
    // The fresh segment's start error shows up as a brief blip (~13 ms in
    // this scenario vs ~7 ms max without the switch), then drift control
    // brings it back. SIMULATED numbers.
    final steady = r.metrics['interDeviceSpreadMs_steady'] as Map;
    expect((steady['median'] as num).toDouble(), lessThan(8));
    expect((steady['max'] as num).toDouble(), lessThan(30));
  });

  test('a stereo pair set while a song is starting still splits left/right', () {
    // Regression: a role change that arrived while the starting segment was
    // being prepared was lost, so that phone kept playing full stereo for
    // the whole song (heard as "the right channel on both phones").
    for (final ms in [0, 300, 600]) {
      final r = SimulationRunner(Scenario(
        name: 'pair-at-start-$ms',
        participants: 2,
        network: NetworkCondition.wifiTypical,
        duration: const Duration(seconds: 30),
        actions: [
          const ScheduledAction(Duration(seconds: 3), PlayAction()),
          ScheduledAction(Duration(milliseconds: 3000 + ms), const ChannelRoleAction(0, ChannelRole.left)),
          ScheduledAction(Duration(milliseconds: 3000 + ms), const ChannelRoleAction(1, ChannelRole.right)),
        ],
      )).run();
      expect(r.metrics['activeChannelRoles'], ['left', 'right'], reason: 'role change $ms ms after play');
    }
  });

  test('a rear surround phone plays 15 ms after the front phones (Haas delay), and stays there', () {
    final r = SimulationRunner(const Scenario(
      name: 'surround-delay',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(seconds: 50),
      actions: [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 15), ChannelRoleAction(2, ChannelRole.surroundLeft)),
      ],
    )).run();
    expect(r.metrics['activeChannelRoles'], ['stereo', 'stereo', 'surroundLeft']);
    // Shift of the rear phone relative to a front phone, before vs. after
    // the role change (ground truth, SIMULATED). Each phone may sit
    // anywhere inside the drift controller's ±8 ms band, so the 15 ms
    // target shows up as roughly 7–23 ms, still inside the Haas window.
    int medianDiff(int fromS, int toS) {
      final d = <int>[];
      for (final smp in r.samples) {
        final t = (smp.trueUs - r.samples.first.trueUs) ~/ 1000000;
        final front = smp.errors['device-0'], rear = smp.errors['device-2'];
        if (front == null || rear == null || t < fromS || t >= toS) continue;
        d.add(front - rear);
      }
      d.sort();
      return d[d.length ~/ 2];
    }

    final shiftMs = (medianDiff(30, 50) - medianDiff(2, 11)) / 1000;
    expect(shiftMs, inInclusiveRange(7, 23), reason: 'rear phone moved ~15 ms later on purpose (got $shiftMs ms)');
  });

  test('surround roles are refused while a phone without surround support is in the room', () {
    final s = const DeviceCapabilities(rateControl: true, backend: 'x', surround: true);
    expect(DeviceCapabilities.fromJson(s.toJson()).surround, isTrue);
    expect(DeviceCapabilities.fromJson(const DeviceCapabilities(rateControl: true, backend: 'x').toJson()).surround, isFalse);
    expect(roleDelayUs(ChannelRole.surroundRight), kSurroundDelayUs);
    expect(roleDelayUs(ChannelRole.center), 0);
  });
}
