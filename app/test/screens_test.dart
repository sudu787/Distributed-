import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:syncsphere/src/data/app_store.dart';
import 'package:syncsphere/src/data/models.dart';
import 'package:syncsphere/src/services/library_service.dart';
import 'package:syncsphere/src/services/network_info.dart';
import 'package:syncsphere/src/services/room_service.dart';
import 'package:syncsphere/src/state/providers.dart';
import 'package:syncsphere/src/state/room_controller.dart';
import 'package:syncsphere/src/ui/diagnostics_screen.dart';
import 'package:syncsphere/src/ui/home_screen.dart';
import 'package:syncsphere/src/ui/player_screen.dart';
import 'package:syncsphere/src/ui/room_screen.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'dart:io';

const _identity = DeviceIdentity(deviceId: 'dev-me', displayName: 'My Phone');

final _track = TrackInfo(id: 'a' * 64, title: 'Blue Hour', artist: 'Test Artist', durationUs: 200000000, sizeBytes: 1, availableCount: 1);

RoomViewState _roomState({ParticipantRole role = ParticipantRole.host, bool live = true}) => RoomViewState(
      status: RoomStatus.active,
      info: const RoomInfo(isHost: true, roomId: 'K7Q2M9', roomName: 'Living room', joinKey: 'ABCD2345', host: '127.0.0.1', port: 47800),
      phase: live ? SessionPhase.joined : SessionPhase.reconnecting,
      role: role,
      room: RoomState(
        roomId: 'K7Q2M9',
        roomName: 'Living room',
        coordinatorId: 'dev-me',
        version: 5,
        timeline: PlaybackTimeline(
            generation: 2, trackId: _track.id, status: PlaybackStatus.playing, anchorPositionUs: 0, anchorCoordUs: 0),
        playlist: [_track],
        participants: const [
          ParticipantSummary(
              deviceId: 'dev-me', displayName: 'My Phone', role: ParticipantRole.host, connection: ConnectionStatus.connected,
              currentTrack: TrackAvailability.available),
          ParticipantSummary(
              deviceId: 'dev-other', displayName: 'Kitchen', role: ParticipantRole.listener, connection: ConnectionStatus.connected,
              currentTrack: TrackAvailability.fetching),
        ],
      ),
      diagnostics: const DiagnosticsMsg([
        ParticipantDiagnostics(deviceId: 'dev-me', errorUs: 1200, uncertaintyUs: 300, offsetUs: 0, mode: CorrectionMode.inSync, lastReportAgeMs: 400, playerState: 'ready', backend: 'media3-exoplayer'),
        ParticipantDiagnostics(deviceId: 'dev-other', errorUs: -14800, uncertaintyUs: 2100, offsetUs: 51234567, mode: CorrectionMode.rateCorrecting, rate: 1.0037, lastReportAgeMs: 700, playerState: 'ready', backend: 'media3-exoplayer'),
      ], maxPairwiseErrorUs: 16000),
      engine: const EngineStatus(mode: CorrectionMode.inSync, lastErrorUs: 1200, startLatencyUs: 52000, playerState: 'ready', activeGeneration: 2),
    );

class _FakeRoomController extends RoomController {
  final RoomViewState initial;
  final List<ControlAction> sent = [];
  _FakeRoomController(this.initial);
  @override
  RoomViewState build() => initial;
  @override
  Future<String?> control(ControlAction action,
      {int? positionUs, String? trackId, double? value, String? targetDevice, ParticipantRole? role}) async {
    sent.add(action);
    return null;
  }

  @override
  int? expectedPositionUs() => 65000000;
}

List<Override> _overrides(RoomViewState state, {_FakeRoomController? controller}) {
  final store = MemoryAppStore();
  return [
    appStoreProvider.overrideWithValue(store),
    initialIdentityProvider.overrideWithValue(_identity),
    libraryServiceProvider.overrideWithValue(
        LibraryService(store: store, libraryDir: Directory.systemTemp, log: EventLog(clock: SystemMonotonicClock.instance))),
    roomServiceProvider.overrideWithValue(RoomService(
        store: store, cacheDir: Directory.systemTemp, backendFactory: (l) async => NullAudioBackend(() => 0))),
    networkSummaryProvider.overrideWith((ref) async => const NetworkSummary(['192.168.1.20'], ['wlan0'])),
    discoveryProvider.overrideWith((ref) => Stream.value(const [
          RoomBeacon(roomId: 'R2D2C3', roomName: 'Garden party', coordinatorId: 'x', coordinatorEpoch: 1, port: 47800, host: '192.168.1.30', participants: 3),
        ])),
    roomControllerProvider.overrideWith(() => controller ?? _FakeRoomController(state)),
  ];
}

Widget _wrap(Widget child, List<Override> overrides) =>
    ProviderScope(overrides: overrides, child: MaterialApp(home: child));

/// Phone-shaped, tall viewport so lazily built list items are on screen.
void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 2400);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('home screen shows actions, nearby rooms and empty library', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const HomeScreen(), _overrides(const RoomViewState())));
    await tester.pumpAndSettle();
    expect(find.text('Create room'), findsOneWidget);
    expect(find.text('Join by address'), findsOneWidget);
    expect(find.text('Garden party'), findsOneWidget);
    expect(find.textContaining('192.168.1.20'), findsOneWidget);
    expect(find.text('No tracks yet'), findsOneWidget);
  });

  testWidgets('room screen shows key, devices with health and availability', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const RoomScreen(), _overrides(_roomState())));
    await tester.pump();
    expect(find.text('ABCD-2345'), findsOneWidget);
    expect(find.text('K7Q2M9'), findsOneWidget);
    expect(find.textContaining('Kitchen'), findsOneWidget);
    expect(find.textContaining('downloading'), findsOneWidget);
    expect(find.textContaining('(est.)'), findsWidgets);
    expect(find.text('Blue Hour'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('player sends controls when allowed', (tester) async {
    _phone(tester);
    final ctl = _FakeRoomController(_roomState());
    await tester.pumpWidget(_wrap(const PlayerScreen(), _overrides(_roomState(), controller: ctl)));
    await tester.pump();
    expect(find.text('Blue Hour'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget); // expected position 65 s
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(ctl.sent, [ControlAction.pause]);
  });

  testWidgets('player disables controls for listeners', (tester) async {
    _phone(tester);
    final listener = _FakeRoomController(_roomState(role: ParticipantRole.listener));
    await tester.pumpWidget(_wrap(const PlayerScreen(), _overrides(_roomState(role: ParticipantRole.listener), controller: listener)));
    await tester.pump();
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(listener.sent, isEmpty);
    expect(find.textContaining('You are a listener'), findsOneWidget);
  });

  testWidgets('player shows reconnecting state when the coordinator is lost', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const PlayerScreen(), _overrides(_roomState(live: false))));
    await tester.pump();
    expect(find.textContaining('Reconnecting'), findsOneWidget);
    expect(find.textContaining('disabled while disconnected'), findsOneWidget);
  });

  testWidgets('diagnostics labels estimates and lists participants', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const DiagnosticsScreen(), _overrides(_roomState())));
    await tester.pump();
    expect(find.textContaining('software estimates'), findsOneWidget);
    expect(find.text('dev-other'), findsOneWidget);
    expect(find.textContaining('-14.8 ms (est.)'), findsOneWidget);
    expect(find.textContaining('adjusting rate'), findsWidgets);
  });
}
