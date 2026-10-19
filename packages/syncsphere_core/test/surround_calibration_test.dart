/// Surround calibration with every phone's microphone, end to end in the
/// simulator: two-way ranging between phones, MDS layout, orientation from
/// the front/left phones and role suggestions. Simulated room, not hardware.
library;

import 'dart:math';

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

(double, double) at(double azimuthDeg, double r) => (r * sin(azimuthDeg * pi / 180), r * cos(azimuthDeg * pi / 180));

void main() {
  test('simulated 5.0 room: positions, angles and roles are recovered', () {
    final sc = Scenario(
      name: 'surround-calibration',
      participants: 6,
      network: NetworkCondition.wifiGood,
      duration: const Duration(seconds: 40),
      profiles: const [DeviceAudioProfile.flagship, DeviceAudioProfile.midrange],
      listenerIndex: 0,
      // Listener at the seat; C, L, R at 2 m; SL, SR at 1.8 m (ITU angles).
      positionsM: [(0, 0), at(0, 2), at(-30, 2), at(30, 2), at(-110, 1.8), at(110, 1.8)],
      frontIndex: 1,
      leftIndex: 2,
      actions: const [ScheduledAction(Duration(seconds: 3), CalibrateAction(surround: true))],
    );
    final m = SimulationRunner(sc).run().metrics;
    final s = m['surroundCalibration'] as Map;
    expect(s['measured'], isTrue, reason: '$s');
    expect(s['phones'], 6);
    expect(((s['distanceErrorCm'] as Map)['max'] as num), lessThan(20));
    expect(((s['azimuthErrorDeg'] as Map)['max'] as num), lessThan(10));
    expect(s['roles'], {
      'device-1': 'center',
      'device-2': 'left',
      'device-3': 'right',
      'device-4': 'surroundLeft',
      'device-5': 'surroundRight',
    });
    expect(m['failedSessions'], isEmpty);
  });

  test('a phone whose owner did not allow measurement is left out, the rest is measured', () {
    final sc = Scenario(
      name: 'surround-decline',
      participants: 5,
      network: NetworkCondition.wifiGood,
      duration: const Duration(seconds: 40),
      listenerIndex: 0,
      positionsM: [(0, 0), at(-30, 2), at(30, 2), at(-110, 1.8), at(110, 1.8)],
      declineRemoteRecording: const {4},
      actions: const [ScheduledAction(Duration(seconds: 3), CalibrateAction(surround: true))],
    );
    final r = SimulationRunner(sc).run();
    final s = r.metrics['surroundCalibration'] as Map;
    expect(s['measured'], isTrue);
    expect(s['phones'], 4, reason: 'device-4 declined; the other four are placed');
  });

  test('surround calibration needs a second microphone', () {
    final sc = Scenario(
      name: 'surround-one-phone',
      participants: 1,
      network: NetworkCondition.wifiGood,
      duration: const Duration(seconds: 10),
      listenerIndex: 0,
      positionsM: const [(0, 0)],
      actions: const [ScheduledAction(Duration(seconds: 3), CalibrateAction(surround: true))],
    );
    final r = SimulationRunner(sc).run();
    expect((r.metrics['surroundCalibration'] as Map)['measured'], isFalse);
  });
}
