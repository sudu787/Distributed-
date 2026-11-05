import 'package:fake_async/fake_async.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

import 'coordinator_test.dart' show Fixture;

RoomState _state({SyncEngineMode engine = SyncEngineMode.classic, List<SyncCheckResult> checks = const []}) =>
    RoomState(
      roomId: 'r',
      roomName: 'Room',
      coordinatorId: 'c',
      version: 3,
      timeline: const PlaybackTimeline.idle(),
      engine: engine,
      syncChecks: checks,
    );

Scenario _scenario(SyncEngineMode engine,
        {int seed = 1, List<ScheduledAction>? actions, Duration duration = const Duration(seconds: 60)}) =>
    Scenario(
      name: 'engines-${engine.name}',
      participants: 3,
      network: NetworkCondition.wifiTypical,
      duration: duration,
      profiles: const [DeviceAudioProfile.phoneFlagship, DeviceAudioProfile.phoneMidrange],
      engine: engine,
      seed: seed,
      actions: actions ??
          const [
            ScheduledAction(Duration(seconds: 3), PlayAction()),
            ScheduledAction(Duration(seconds: 25), PauseAction()),
            ScheduledAction(Duration(seconds: 32), PlayAction()),
            ScheduledAction(Duration(seconds: 45), NextTrackAction()),
          ],
    );

double _metric(SimulationResult r, String key, String field) => ((r.metrics[key] as Map)[field] as num).toDouble();

void main() {
  group('wire format', () {
    test('engine names parse; unknown and missing values are Classic', () {
      expect(SyncEngineMode.parse('precise'), SyncEngineMode.precise);
      expect(SyncEngineMode.parse('warp-drive'), SyncEngineMode.classic);
      expect(SyncEngineMode.parse(null), SyncEngineMode.classic);
    });

    test('room state carries the engine and sync checks; old states read as Classic', () {
      const check = SyncCheckResult(id: 4, engine: SyncEngineMode.warm, listener: 'a', devices: [
        SyncCheckDevice(deviceId: 'a', name: 'A', startUs: -3000, settledUs: 0, jitterUs: 900),
        SyncCheckDevice(deviceId: 'b', name: 'B', startUs: 41000, settledUs: 2000, jitterUs: 1500),
        SyncCheckDevice(deviceId: 'c', name: 'C'),
      ]);
      final s = _state(engine: SyncEngineMode.precise, checks: [check]);
      final back = RoomState.fromJson(s.toJson());
      expect(back.engine, SyncEngineMode.precise);
      expect(back.syncChecks.single.startSpreadUs, 44000);
      expect(back.syncChecks.single.settledSpreadUs, 2000);
      expect(back.syncChecks.single.devices[2].heard, isFalse);
      expect(back.syncChecks.single.ok, isTrue);

      final classic = _state().toJson();
      expect(classic.containsKey('eng'), isFalse, reason: 'Classic rooms send exactly what the old build sent');
      expect(classic.containsKey('checks'), isFalse);
      expect(RoomState.fromJson({...classic, 'eng': 'something-new'}).engine, SyncEngineMode.classic);
    });

    test('a sync report names the engine only when it deviates', () {
      SyncReportMsg roundTrip(SyncReportMsg m) => SyncReportMsg.read(Reader(m.toBody(), 'rep'));
      SyncReportMsg report(SyncEngineMode? e) => SyncReportMsg(
          generation: 1,
          coordTimeUs: 5,
          positionUs: 6,
          expectedUs: 6,
          errorUs: 0,
          rate: 1,
          bufferedUs: 0,
          offsetUs: 0,
          uncertaintyUs: 0,
          rttP95Us: 0,
          mode: CorrectionMode.inSync,
          playerState: 'ready',
          engine: e);
      expect(roundTrip(report(null)).engine, isNull);
      expect(roundTrip(report(SyncEngineMode.classic)).engine, SyncEngineMode.classic);
      expect(report(null).toBody().containsKey('eng'), isFalse);
    });

    test('feature flags tolerate missing and malformed values', () {
      expect(FeatureFlags.fromJson(null), const FeatureFlags());
      expect(FeatureFlags.fromJson({'keepAwake': false, 'startProbe': 'yes'}),
          const FeatureFlags(keepAwake: false));
      const f = FeatureFlags(channelRoles: false, preciseFallback: false);
      expect(FeatureFlags.fromJson(f.toJson()), f);
    });

    test('sync check plans are measure-only and have their own track id', () {
      const cal = CalibrationPlan(id: 3, listener: 'a', order: ['a', 'b']);
      const check = CalibrationPlan.syncCheck(id: 3, listener: 'a', order: ['a', 'b']);
      expect(check.trackId, isNot(cal.trackId));
      expect(CalibrationPlan.fromJson(check.toJson()).measureOnly, isTrue);
      expect(CalibrationPlan.fromJson(cal.toJson()).trackId, cal.trackId, reason: 'calibration ids unchanged');
      expect(check.leadInUs, 1000000);
    });
  });

  group('start policies', () {
    test('classic learns 60 % of each start error and rejects implausible ones', () {
      final p = ClassicStartPolicy(50000);
      expect(p.learn(-10000), isTrue); // started 10 ms late → start earlier
      expect(p.leadUs, 56000);
      expect(p.learn(800000), isFalse);
      expect(p.leadUs, 56000);
      expect(p.startCallAt(1000000), 944000);
    });

    test('each engine keeps its own learned lead; calibration shifts all of them', () {
      final all = StartPolicy.forAllEngines(classicLeadUs: 80000, learned: {'precise': 2000});
      expect(all[SyncEngineMode.warm]!.leadUs, 80000, reason: 'warm starts from the classic value');
      expect(all[SyncEngineMode.precise]!.leadUs, 2000);
      for (final p in all.values) {
        p.onCalibrationChanged(-30000);
      }
      expect(all[SyncEngineMode.classic]!.leadUs, 50000);
      expect(all[SyncEngineMode.precise]!.leadUs, -28000);
    });

    test('precise uses tight drift settings and rejects errors a working renderer cannot have', () {
      final p = PreciseStartPolicy(0);
      const room = DriftConfig();
      final d = p.drift(room);
      expect(d.maxRateDelta, lessThan(room.maxRateDelta));
      expect(d.settleTime, lessThan(room.settleTime));
      expect(d.reportIntervalIdle, room.reportIntervalIdle);
      expect(p.learn(300000), isFalse);
      expect(p.learn(-4000), isTrue);
      expect(p.leadUs, 2000);
      expect(ClassicStartPolicy(0).drift(room), same(room), reason: 'classic is unchanged');
    });
  });

  group('coordinator', () {
    test('only the host chooses the engine', () {
      fakeAsync((fa) {
        final f = Fixture(fa, defaultRole: ParticipantRole.controller);
        final (host, _) = f.join('host-device');
        final (guest, _) = f.join('phone-1');
        guest.send(const ControlMsg(requestId: 1, action: ControlAction.setSyncEngine, baseVersion: 0, mode: 'precise'));
        host.send(const ControlMsg(requestId: 2, action: ControlAction.setSyncEngine, baseVersion: 0, mode: 'bogus'));
        fa.elapse(const Duration(milliseconds: 10));
        expect(guest.last<ControlAckMsg>()!.error, ControlError.unauthorized);
        expect(host.last<ControlAckMsg>()!.error, ControlError.invalid);
        host.send(const ControlMsg(requestId: 3, action: ControlAction.setSyncEngine, baseVersion: 0, mode: 'warm'));
        fa.elapse(const Duration(milliseconds: 10));
        expect(host.last<ControlAckMsg>()!.accepted, isTrue);
        expect(f.coord.state.engine, SyncEngineMode.warm);
        expect(guest.last<StateMsg>()!.state.engine, SyncEngineMode.warm);
      });
    });

    test('a sync check needs a microphone and is busy-blocked like calibration', () {
      fakeAsync((fa) {
        final f = Fixture(fa, defaultRole: ParticipantRole.controller);
        final (a, _) = f.join('host-device'); // no microphone capability
        a.send(ControlMsg(requestId: 1, action: ControlAction.syncCheck, baseVersion: f.coord.state.version));
        fa.elapse(const Duration(milliseconds: 10));
        expect(a.last<ControlAckMsg>()!.error, ControlError.invalid);
        expect(f.coord.state.calibration, isNull);
      });
    });
  });

  group('sync check analysis', () {
    test('start and settled offsets are relative to the median phone', () {
      const plan = CalibrationPlan.syncCheck(id: 1, listener: 'a', order: ['a', 'b', 'c']);
      // Slot r·3 + k belongs to phone k. Phone b starts 60 ms late, then
      // converges; phone c is never heard.
      final arrivals = {
        'a': {for (var r = 0; r < 6; r++) r * 3: 1000},
        'b': {0 * 3 + 1: 61000, 1 * 3 + 1: 30000, 3 * 3 + 1: 2000, 4 * 3 + 1: 1000, 5 * 3 + 1: 3000},
      };
      final res = summarizeSyncCheck(
          id: 1, plan: plan, engine: SyncEngineMode.classic, arrivalsBySlot: arrivals, nameOf: (id) => id.toUpperCase());
      final b = res.devices.firstWhere((d) => d.deviceId == 'b');
      expect(res.startSpreadUs, 60000);
      expect(res.settledSpreadUs, 1000);
      expect(b.jitterUs, 2000);
      expect(b.name, 'B');
      expect(res.devices.firstWhere((d) => d.deviceId == 'c').heard, isFalse);
    });
  });

  group('phone profiles', profileFitTests);

  group('simulated engines (phone-like model, SIMULATED)', () {
    test('Classic rooms stay on Classic, with the cold starts the phone-like model adds', () {
      // (classic_golden_test.dart pins Classic's exact behaviour.)
      final r = SimulationRunner(_scenario(SyncEngineMode.classic)).run();
      expect(r.metrics['engines'], everyElement('classic'));
      expect(r.metrics['coldStarts'], greaterThan(0), reason: 'the phone-like model has standby');
    });

    test('warm start removes cold starts and tightens the start', () {
      for (final seed in [1, 2]) {
        final classic = SimulationRunner(_scenario(SyncEngineMode.classic, seed: seed)).run();
        final warm = SimulationRunner(_scenario(SyncEngineMode.warm, seed: seed)).run();
        expect(warm.metrics['coldStarts'], 0);
        expect(warm.metrics['engines'], everyElement('warm'));
        expect(_metric(warm, 'interDeviceSpreadMs_first3s', 'p95'),
            lessThan(_metric(classic, 'interDeviceSpreadMs_first3s', 'p95')));
        expect(_metric(warm, 'interDeviceSpreadMs_steady', 'p95'), lessThan(30));
      }
    });

    test('precise starts every phone on the same frame', () {
      final r = SimulationRunner(_scenario(SyncEngineMode.precise)).run();
      expect(r.metrics['engines'], everyElement('precise'));
      expect(_metric(r, 'interDeviceSpreadMs_first3s', 'p95'), lessThan(10));
      expect(_metric(r, 'interDeviceSpreadMs_steady', 'p95'), lessThan(10));
      expect(r.metrics['failedSessions'], isEmpty);
    });

    test('switching engines while playing re-joins the running song on the new engine', () {
      final r = SimulationRunner(_scenario(SyncEngineMode.classic,
          duration: const Duration(seconds: 50),
          actions: const [
            ScheduledAction(Duration(seconds: 3), PlayAction()),
            ScheduledAction(Duration(seconds: 15), SetEngineAction(SyncEngineMode.precise)),
            ScheduledAction(Duration(seconds: 30), SetEngineAction(SyncEngineMode.warm)),
          ])).run();
      expect(r.metrics['engines'], everyElement('warm'));
      final last = r.samples.where((s) => s.trueUs - r.samples.last.trueUs > -8000000).toList();
      expect(last.every((s) => s.errors.length == 3), isTrue, reason: 'all phones audible after the switches');
      expect(last.map((s) => s.spread!).reduce((a, b) => a > b ? a : b), lessThan(40000));
    });

    test('a failing engine falls back to Classic on that phone only, and the room sees it', () {
      final r = SimulationRunner(Scenario(
        name: 'fallback',
        participants: 3,
        network: NetworkCondition.wifiGood,
        duration: const Duration(seconds: 40),
        profiles: const [DeviceAudioProfile.phoneFlagship],
        engine: SyncEngineMode.precise,
        actions: const [
          ScheduledAction(Duration(seconds: 3), PlayAction()),
          ScheduledAction(Duration(seconds: 12), EngineFailureAction(2)),
        ],
      )).run();
      expect(r.metrics['engines'], ['precise', 'precise', 'classic']);
      final tail = r.samples.where((s) => s.trueUs - r.samples.last.trueUs > -5000000);
      expect(tail.every((s) => s.errors.containsKey('device-2')), isTrue, reason: 'the fallen-back phone plays again');
      expect(r.metrics['engineOverrides'], {'device-2': 'classic'});
    });

    test('a start the backend cannot perform re-joins instead of leaving the phone stuck', () {
      // Found by the budget sweep: a resync overlapping a seek replaced the
      // backend's single standby player, the start failed, and the engine
      // waited for it forever (one phone 72 s behind until the next command).
      final r = SimulationRunner(const Scenario(
        name: 'stuck-start',
        participants: 5,
        network: NetworkCondition.wifiTypical,
        duration: Duration(seconds: 110),
        profiles: [DeviceAudioProfile.phoneFlagship, DeviceAudioProfile.phoneMidrange, DeviceAudioProfile.phoneLowEnd],
        actions: [
          ScheduledAction(Duration(seconds: 3), PlayAction()),
          ScheduledAction(Duration(seconds: 30), PauseAction()),
          ScheduledAction(Duration(seconds: 38), PlayAction()),
          ScheduledAction(Duration(seconds: 60), SeekAction(Duration(minutes: 2))),
          ScheduledAction(Duration(seconds: 80), NextTrackAction()),
        ],
        seed: 33,
      )).run();
      expect(_metric(r, 'interDeviceSpreadMs_steady', 'max'), lessThan(1000));
    });

    test('a sync check measures what the listener hears, per engine', () {
      SimulationResult run(SyncEngineMode e) => SimulationRunner(Scenario(
            name: 'check-${e.name}',
            participants: 3,
            network: NetworkCondition.wifiGood,
            duration: const Duration(seconds: 40),
            profiles: const [DeviceAudioProfile.phoneFlagship, DeviceAudioProfile.phoneMidrange],
            engine: e,
            listenerIndex: 0,
            distancesM: const [0.5],
            actions: const [ScheduledAction(Duration(seconds: 6), SyncCheckAction())],
          )).run();
      final classic = (run(SyncEngineMode.classic).metrics['syncChecks'] as List).single as Map;
      final precise = (run(SyncEngineMode.precise).metrics['syncChecks'] as List).single as Map;
      expect(classic['engine'], 'classic');
      expect(precise['settledSpreadMs'], lessThan(8));
      expect(precise['startSpreadMs'], lessThan(classic['startSpreadMs'] as num));
    });
  });
}

void profileFitTests() {
  test('a phone profile fitted from a simulated phone recovers its start delay and cold starts', () {
    // The fitter only sees what a real phone would record about itself.
    final r = SimulationRunner(Scenario(
      name: 'fit',
      participants: 2,
      network: NetworkCondition.wifiGood,
      duration: const Duration(minutes: 3),
      profiles: const [DeviceAudioProfile.phoneMidrange],
      seed: 5,
      actions: [
        // Warm starts: seeks while playing...
        const ScheduledAction(Duration(seconds: 3), PlayAction()),
        for (var i = 1; i <= 8; i++)
          ScheduledAction(Duration(seconds: 3 + i * 8), SeekAction(Duration(seconds: 60 + i * 30))),
        // ...cold starts: resume after 8 s of silence.
        for (var i = 0; i < 5; i++) ...[
          ScheduledAction(Duration(seconds: 80 + i * 18), const PauseAction()),
          ScheduledAction(Duration(seconds: 88 + i * 18), const PlayAction()),
        ],
      ],
    )).run();
    final fit = r.metrics['fittedProfiles'] as List;
    final p = DeviceAudioProfile.fromJson((fit[1] as Map)['profile'] as Map<String, Object?>);
    const truth = DeviceAudioProfile.phoneMidrange;
    expect((fit[1] as Map)['basis'], containsPair('warmStarts', greaterThanOrEqualTo(6)));
    expect((p.startLatencyMeanUs - truth.startLatencyMeanUs).abs(), lessThan(10000));
    expect(p.positionNoiseUs, lessThan(8000));
    expect(p.standbyAfterUs, greaterThan(0), reason: 'cold starts are detected');
    expect((p.coldStartExtraMeanUs - truth.coldStartExtraMeanUs).abs(), lessThan(50000));
  });
}
