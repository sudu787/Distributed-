import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:syncsphere/src/data/app_store.dart';
import 'package:syncsphere/src/data/models.dart';
import 'package:syncsphere/src/services/library_service.dart';
import 'package:syncsphere/src/services/room_service.dart';
import 'package:syncsphere/src/state/providers.dart';
import 'package:syncsphere/src/state/room_controller.dart';
import 'package:syncsphere/src/state/sync_settings.dart';
import 'package:syncsphere/src/ui/room_screen.dart';
import 'package:syncsphere/src/ui/sync_engine_view.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

const _identity = DeviceIdentity(deviceId: 'dev-me', displayName: 'My Phone');

RoomViewState _state({
  SyncEngineMode engine = SyncEngineMode.precise,
  bool host = true,
  List<SyncCheckResult> checks = const [],
  SyncEngineMode? myOverride,
}) =>
    RoomViewState(
      status: RoomStatus.active,
      info: RoomInfo(isHost: host, roomId: 'K7Q2M9', roomName: 'Living room', host: '127.0.0.1', port: 47800),
      phase: SessionPhase.joined,
      role: host ? ParticipantRole.host : ParticipantRole.controller,
      room: RoomState(
        roomId: 'K7Q2M9',
        roomName: 'Living room',
        coordinatorId: 'dev-me',
        version: 5,
        timeline: const PlaybackTimeline.idle(),
        engine: engine,
        syncChecks: checks,
        participants: [
          ParticipantSummary(
              deviceId: 'dev-me',
              displayName: 'My Phone',
              role: ParticipantRole.host,
              connection: ConnectionStatus.connected,
              engine: myOverride),
          const ParticipantSummary(
              deviceId: 'dev-k', displayName: 'Kitchen', role: ParticipantRole.listener, connection: ConnectionStatus.connected),
        ],
      ),
    );

const _classicCheck = SyncCheckResult(id: 1, engine: SyncEngineMode.classic, listener: 'dev-me', devices: [
  SyncCheckDevice(deviceId: 'dev-me', name: 'My Phone', startUs: -40000, settledUs: -3000, jitterUs: 2000),
  SyncCheckDevice(deviceId: 'dev-k', name: 'Kitchen', startUs: 40000, settledUs: 3000, jitterUs: 4000),
]);
const _preciseCheck = SyncCheckResult(id: 2, engine: SyncEngineMode.precise, listener: 'dev-me', devices: [
  SyncCheckDevice(deviceId: 'dev-me', name: 'My Phone', startUs: -1000, settledUs: -500, jitterUs: 300),
  SyncCheckDevice(deviceId: 'dev-k', name: 'Kitchen', startUs: 1000, settledUs: 500, jitterUs: 400),
]);

class _Controller extends RoomController {
  final RoomViewState initial;
  final engines = <SyncEngineMode>[];
  int checks = 0;
  _Controller(this.initial);
  @override
  RoomViewState build() => initial;
  @override
  bool get hasMicrophone => true;
  @override
  Future<String?> setSyncEngine(SyncEngineMode mode) async {
    engines.add(mode);
    return null;
  }

  @override
  Future<String?> syncCheck() async {
    checks++;
    return null;
  }
}

List<Override> _overrides(RoomViewState s, _Controller c, MemoryAppStore store, RoomService rooms) => [
      appStoreProvider.overrideWithValue(store),
      initialIdentityProvider.overrideWithValue(_identity),
      libraryServiceProvider.overrideWithValue(
          LibraryService(store: store, libraryDir: Directory.systemTemp, log: EventLog(clock: SystemMonotonicClock.instance))),
      roomServiceProvider.overrideWithValue(rooms),
      roomControllerProvider.overrideWith(() => c),
    ];

RoomService _rooms(MemoryAppStore store) =>
    RoomService(store: store, cacheDir: Directory.systemTemp, backendFactory: (l) async => NullAudioBackend(() => 0));

Future<void> _pump(WidgetTester tester, Widget child, List<Override> o) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 2600);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(overrides: o, child: MaterialApp(home: Scaffold(body: child))));
  await tester.pump();
}

void main() {
  testWidgets('speakers: the host sees the engine, can switch it and go back to Classic in one tap', (tester) async {
    final store = MemoryAppStore();
    final c = _Controller(_state());
    await _pump(tester, const SpeakersView(), _overrides(_state(), c, store, _rooms(store)));
    expect(find.text('Sync engine: Precise'), findsOneWidget);
    await tester.tap(find.text('Back to Classic'));
    await tester.pump();
    await tester.tap(find.text('Warm start'));
    await tester.pump();
    expect(c.engines, [SyncEngineMode.classic, SyncEngineMode.warm]);
  });

  testWidgets('speakers: guests see the engine but cannot change it; a fallback is shown', (tester) async {
    final store = MemoryAppStore();
    final s = _state(host: false, myOverride: SyncEngineMode.classic);
    await _pump(tester, const SpeakersView(), _overrides(s, _Controller(s), store, _rooms(store)));
    expect(find.text('Sync engine: Precise'), findsOneWidget);
    expect(find.text('Back to Classic'), findsNothing);
    expect(find.byType(SegmentedButton<SyncEngineMode>), findsNothing);
    expect(find.textContaining('This phone is using Classic'), findsOneWidget);
  });

  testWidgets('sync check: results in ms with a verdict, history marks the best engine', (tester) async {
    final store = MemoryAppStore();
    final s = _state(checks: const [_classicCheck, _preciseCheck]);
    final c = _Controller(s);
    await _pump(tester, const SpeakersView(), _overrides(s, c, store, _rooms(store)));
    expect(find.text('Last check (Precise)'), findsOneWidget);
    expect(find.text('2.0 ms · tight'), findsOneWidget); // start gap
    expect(find.text('★ Precise'), findsOneWidget);
    expect(find.text('80 ms / 6.0 ms'), findsOneWidget); // classic: start / settled gap
    await tester.tap(find.text('Check'));
    await tester.pump();
    expect(c.checks, 1);
    expect(find.text('Compare engines'), findsOneWidget);
  });

  testWidgets('settings: engine for hosted parties and the per-phone switches are saved', (tester) async {
    final store = MemoryAppStore();
    final rooms = _rooms(store);
    final s = _state();
    await _pump(tester, const SyncOptionsSheet(), _overrides(s, _Controller(s), store, rooms));
    await tester.tap(find.text('Keep the speaker awake'));
    await tester.pump();
    expect(rooms.flags.keepAwake, isFalse, reason: 'applied to the running party at once');
    expect(FeatureFlags.fromJson(jsonDecode((await store.setting(kFeatureFlagsSetting))!)).keepAwake, isFalse);
    await tester.tap(find.text('Precise'));
    await tester.pump();
    await tester.pump();
    expect(await store.setting(kHostEngineSetting), 'precise');
    expect(rooms.hostEngine, SyncEngineMode.precise);
    expect(await loadHostEngine(store), SyncEngineMode.precise);
  });
}
