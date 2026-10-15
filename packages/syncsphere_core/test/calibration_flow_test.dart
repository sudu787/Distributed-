/// Acoustic room calibration: protocol rules (raw coordinator) and the full
/// loop in the simulator with a virtual microphone (SIMULATED).
@Timeout(Duration(minutes: 3))
library;

import 'package:fake_async/fake_async.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

import 'coordinator_test.dart' show Fixture;

void main() {
  test('result message round trip and validation', () {
    final c = FrameCodec(), s = FrameCodec();
    final keys = RoomKey.derive(roomId: 'r', joinKey: 'k', iterations: 1).sessionKeys('d', 'a', 'b');
    c.activate(sendKey: keys.clientToServer, recvKey: keys.serverToClient);
    s.activate(sendKey: keys.serverToClient, recvKey: keys.clientToServer);
    final m = s.decode(c.encode(const CalibrationResultMsg(calibrationId: 3, arrivals: {
      'dev-a': {0: 1200, 4: 1300},
      'dev-b': {1: -5000},
    }, undetected: ['dev-c']))) as CalibrationResultMsg;
    expect(m.arrivals['dev-a']![4], 1300);
    expect(m.undetected, ['dev-c']);
    expect(
        () => s.decode(c.encode(const UnknownMessage('cal.res', {
              'id': 1,
              'arr': {'x': {'notaslot': 1}}
            }))),
        throwsA(isA<ProtocolException>()));
  });

  test('combine: software error during the clicks is removed from the measurement', () {
    const plan = CalibrationPlan(id: 1, listener: 'a', order: ['a', 'b']);
    // b's sound arrives 120 ms after a's, but b was 80 ms *ahead* in software
    // at the time (still converging), so its static offset is 200 ms.
    final out = combineCalibration(
      plan: plan,
      arrivalsBySlot: {
        'a': {0: 0, 2: 0, 4: 0},
        'b': {1: 120000, 3: 120000, 5: 120000},
      },
      softwareErrorAt: (id, slot) => id == 'b' ? 80000 : 0,
    );
    expect(out['b']! - out['a']!, 200000);
  });

  test('coordinator: calibrate needs a microphone, blocks playback controls while running', () {
    fakeAsync((fa) {
      final f = Fixture(fa, defaultRole: ParticipantRole.controller);
      final (a, _) = f.join('host-device'); // raw client: no microphone capability
      a.send(ControlMsg(requestId: 1, action: ControlAction.calibrate, baseVersion: f.coord.state.version));
      fa.elapse(const Duration(milliseconds: 10));
      expect(a.last<ControlAckMsg>()!.error, ControlError.invalid);
      expect(f.coord.state.calibration, isNull);
    });
  });

  test('simulated room: calibrating to the listener removes Bluetooth and distance offsets', () {
    Scenario sc({required bool calibrate}) => Scenario(
          name: calibrate ? 'calibrated' : 'uncalibrated',
          participants: 4,
          network: NetworkCondition.wifiGood,
          duration: const Duration(seconds: 70),
          profiles: const [
            DeviceAudioProfile.flagship,
            DeviceAudioProfile.bluetoothUncalibrated,
            DeviceAudioProfile.midrange,
            DeviceAudioProfile.flagship,
          ],
          listenerIndex: 0,
          distancesM: const [0.3, 2.0, 4.5, 7.0],
          actions: [
            if (calibrate) const ScheduledAction(Duration(seconds: 3), CalibrateAction()),
            const ScheduledAction(Duration(seconds: 35), PlayAction()),
          ],
        );
    final before = SimulationRunner(sc(calibrate: false)).run();
    final after = SimulationRunner(sc(calibrate: true)).run();
    double med(SimulationResult r) => ((r.metrics['listenerSpreadMs_steady'] as Map)['median'] as num).toDouble();
    expect(med(before), greaterThan(150));
    expect(med(after), lessThan(12));
    expect(after.metrics['failedSessions'], isEmpty);
  });
}
