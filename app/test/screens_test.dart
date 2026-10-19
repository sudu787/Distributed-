import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:syncsphere/src/data/app_store.dart';
import 'package:syncsphere/src/data/models.dart';
import 'package:syncsphere/src/services/library_service.dart';
import 'package:syncsphere/src/services/network_info.dart';
import 'package:syncsphere/src/services/room_service.dart';
import 'package:syncsphere/src/state/providers.dart';
import 'package:syncsphere/src/state/room_controller.dart';
import 'package:syncsphere/src/services/audius_client.dart';
import 'package:syncsphere/src/ui/add_music.dart';
import 'package:syncsphere/src/ui/diagnostics_screen.dart';
import 'package:syncsphere/src/ui/home_screen.dart';
import 'package:syncsphere/src/ui/player_screen.dart';
import 'package:syncsphere/src/ui/queue_view.dart';
import 'package:syncsphere/src/ui/widgets.dart';
import 'package:syncsphere/src/ui/room_screen.dart';
import 'package:syncsphere/src/ui/speaker_layout.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'dart:io';
import 'dart:math';

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
      {int? positionUs,
      String? trackId,
      double? value,
      String? targetDevice,
      ParticipantRole? role,
      String? mode,
      int? offsetUs}) async {
    sent.add(action);
    return null;
  }

  @override
  int? expectedPositionUs() => 65000000;

  final List<String> rejoined = [];
  @override
  Future<void> joinRecentParty(RoomHistoryEntry entry, String joinKey, {RoomBeacon? beacon}) async =>
      rejoined.add('${entry.roomId}@${beacon?.host ?? entry.host}:$joinKey');

  @override
  Future<JoinLink?> joinLink() async =>
      JoinLink(hosts: ['192.168.1.20'], port: 47800, joinKey: 'ABCD2345', roomId: 'K7Q2M9');
}

List<Override> _overrides(RoomViewState state, {_FakeRoomController? controller, MemoryAppStore? appStore}) {
  final store = appStore ?? MemoryAppStore();
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

class _FakeAudius extends AudiusClient {
  @override
  Future<List<AudiusTrack>> search(String query, {int limit = 25}) async => const [
        AudiusTrack(id: 'D7KyD', title: 'Night Drive', artist: 'Nova', duration: Duration(seconds: 215)),
        AudiusTrack(id: 'X1', title: 'Sunrise', artist: 'Mira'),
      ];
}

Widget _wrap(Widget child, List<Override> overrides) =>
    ProviderScope(key: UniqueKey(), overrides: overrides, child: MaterialApp(home: child));

/// Phone-shaped, tall viewport so lazily built list items are on screen.
void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 2400);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('home screen: host/join actions, nearby parties, empty library', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const HomeScreen(), _overrides(const RoomViewState())));
    await tester.pumpAndSettle();
    expect(find.text('Host a party'), findsOneWidget);
    expect(find.text('Join a party'), findsOneWidget);
    expect(find.text('Garden party'), findsOneWidget);
    expect(find.text('No songs yet'), findsOneWidget);
    await tester.tap(find.text('Join a party'));
    await tester.pumpAndSettle();
    expect(find.text('Scan QR code'), findsOneWidget);
    expect(find.text('Enter address and code'), findsOneWidget);
  });

  testWidgets('home: recent parties show which are online and rejoin with one tap', (tester) async {
    _phone(tester);
    final store = MemoryAppStore();
    await store.addRoomHistory(RoomHistoryEntry(
        roomId: 'R2D2C3', roomName: 'Last Friday', host: '192.168.1.9', port: 47800, hosted: false, at: DateTime(2026, 10, 10), joinKey: 'KEYKEY12'));
    await store.addRoomHistory(RoomHistoryEntry(
        roomId: 'OLD123', roomName: 'Old party', host: '192.168.1.40', port: 47800, hosted: false, at: DateTime(2026, 9, 1), joinKey: 'OLDKEY12'));
    final ctl = _FakeRoomController(const RoomViewState());
    await tester.pumpWidget(_wrap(const HomeScreen(), _overrides(const RoomViewState(), controller: ctl, appStore: store)));
    await tester.pumpAndSettle();
    expect(find.text('Recent parties'), findsOneWidget);
    expect(find.text('Online · 3 phones'), findsOneWidget);
    expect(find.textContaining('not found nearby'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Join'));
    await tester.pumpAndSettle();
    // Joins at the address the party announces now, with the saved code.
    expect(ctl.rejoined, ['R2D2C3@192.168.1.30:KEYKEY12']);
    await tester.tap(find.text('Try'));
    await tester.pumpAndSettle();
    expect(ctl.rejoined.last, 'OLD123@192.168.1.40:OLDKEY12');
  });

  testWidgets('back button asks before leaving the app or the party', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const HomeScreen(), _overrides(const RoomViewState())));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Exit SyncSphere?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Host a party'), findsOneWidget);

    await tester.pumpWidget(_wrap(const RoomScreen(), _overrides(_roomState())));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Keep playing in the background'), findsOneWidget);
    expect(find.text('Stops the music on every phone'), findsOneWidget);
  });

  testWidgets('queue: guests allowed to control can add songs; listeners cannot', (tester) async {
    _phone(tester);
    RoomViewState guest(ParticipantRole role) => _roomState(role: role).copyWith(
        info: const RoomInfo(isHost: false, roomId: 'K7Q2M9', roomName: 'Living room', host: '192.168.1.20', port: 47800));
    await tester.pumpWidget(_wrap(const Scaffold(body: QueueView()), _overrides(guest(ParticipantRole.controller))));
    await tester.pumpAndSettle();
    expect(find.text('Add songs'), findsOneWidget);
    expect(find.byType(TrackArt), findsOneWidget);
    await tester.tap(find.text('Add songs'));
    await tester.pumpAndSettle();
    expect(find.text('From this phone…'), findsOneWidget);

    await tester.pumpWidget(_wrap(const Scaffold(body: QueueView()), _overrides(guest(ParticipantRole.listener))));
    await tester.pumpAndSettle();
    expect(find.text('Add songs'), findsNothing);
    expect(find.textContaining('can pick or add songs'), findsOneWidget);
  });

  testWidgets('add songs: Audius search and links are offered; Audius results are listed', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const Scaffold(body: QueueView()), _overrides(_roomState())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add songs'));
    await tester.pumpAndSettle();
    expect(find.text('Search Audius'), findsOneWidget);
    expect(find.text('From a link'), findsOneWidget);

    await tester.pumpWidget(_wrap(
        const AudiusSearchScreen(), [..._overrides(const RoomViewState()), audiusClientProvider.overrideWithValue(_FakeAudius())]));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'night');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('Night Drive'), findsOneWidget);
    expect(find.text('Nova · 3:35'), findsOneWidget);
    expect(find.text('Sunrise'), findsOneWidget);
    expect(find.textContaining('artists are credited'), findsOneWidget);
  });

  testWidgets('speakers: layout shows which phone is left and right; stereo pair and identify', (tester) async {
    _phone(tester);
    final base = _roomState();
    final room = base.room!;
    RoomState withChannels(ChannelRole mine, ChannelRole other, {IdentifyRequest? identify}) => RoomState(
          roomId: room.roomId,
          roomName: room.roomName,
          coordinatorId: room.coordinatorId,
          version: room.version + 1,
          timeline: room.timeline,
          playlist: room.playlist,
          identify: identify,
          participants: [
            for (final p in room.participants)
              ParticipantSummary(
                deviceId: p.deviceId,
                displayName: p.displayName,
                role: p.role,
                connection: p.connection,
                currentTrack: p.currentTrack,
                channel: p.deviceId == 'dev-me' ? mine : other,
              ),
          ],
        );
    final ctl = _FakeRoomController(base.copyWith(room: withChannels(ChannelRole.left, ChannelRole.right)));
    await tester.pumpWidget(_wrap(const RoomScreen(), _overrides(base, controller: ctl)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('This phone plays the LEFT channel'), findsOneWidget);
    await tester.tap(find.text('Speakers'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Speaker layout'), findsOneWidget);
    expect(find.text('L'), findsWidgets);
    expect(find.text('R'), findsWidgets);
    expect(find.text('Swap L/R'), findsOneWidget);
    expect(find.text('Test sound'), findsOneWidget);
    await tester.tap(find.text('Kitchen').first);
    await tester.pump();
    expect(ctl.sent, contains(ControlAction.identify));

    // The coordinator asks this phone to identify itself: full-screen LEFT.
    ctl.state = ctl.state.copyWith(
        room: withChannels(ChannelRole.left, ChannelRole.right,
            identify: const IdentifyRequest(deviceId: 'dev-me', seq: 1, untilUs: 1 << 40)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('LEFT'), findsOneWidget);
    expect(find.text('This phone plays the left channel'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('LEFT'), findsNothing, reason: 'closes by itself');
  });

  testWidgets('surround setup assigns positions; surround roles appear on the map', (tester) async {
    _phone(tester);
    final ctl = _FakeRoomController(_roomState());
    await tester.pumpWidget(_wrap(const Scaffold(body: SurroundSetupSheet()), _overrides(_roomState(), controller: ctl)));
    await tester.pump();
    expect(find.text('Center (in front of you)'), findsOneWidget);
    // Kitchen becomes the surround-left phone.
    final kitchenChips = find.widgetWithText(ChoiceChip, 'Kitchen');
    await tester.tap(kitchenChips.at(3));
    await tester.pump();
    await tester.tap(find.text('Use this layout'));
    await tester.pump();
    expect(ctl.sent, contains(ControlAction.setChannelRole));
    expect(roleAngle(ChannelRole.surroundLeft), -110);
    expect(roleStyle(ChannelRole.center).short, 'C');
  });

  testWidgets('surround measurement: pick the front phones and a left phone; roles and volume trims follow',
      (tester) async {
    _phone(tester);
    final base = _roomState();
    final room = base.room!;
    // True room (listener facing +y); the measurement only knows distances,
    // so the published layout is rotated, mirrored and shifted.
    final truth = {
      'dev-me': (0.0, 0.0),
      'fl': (-1.0, 1.732),
      'fr': (1.0, 1.732),
      'bl': (-1.691, -0.616),
      'br': (1.691, -0.616),
    };
    const a = 70 * pi / 180;
    final layout = SpeakerLayout(
      id: 3,
      listener: 'dev-me',
      positions: {
        for (final e in truth.entries)
          e.key: (-(e.value.$1 * cos(a) - e.value.$2 * sin(a)) + 1, e.value.$1 * sin(a) + e.value.$2 * cos(a) - 2),
      },
      levelsDb: const {'dev-me': -3, 'fl': -20, 'fr': -24, 'bl': -18, 'br': -19},
      residualM: 0.02,
    );
    final names = {'dev-me': 'My Phone', 'fl': 'Front L', 'fr': 'Front R', 'bl': 'Back L', 'br': 'Back R'};
    final state = base.copyWith(
      room: RoomState(
        roomId: room.roomId,
        roomName: room.roomName,
        coordinatorId: room.coordinatorId,
        version: room.version + 1,
        timeline: room.timeline,
        playlist: room.playlist,
        layout: layout,
        participants: [
          for (final e in names.entries)
            ParticipantSummary(
                deviceId: e.key,
                displayName: e.value,
                role: e.key == 'dev-me' ? ParticipantRole.host : ParticipantRole.listener,
                connection: ConnectionStatus.connected),
        ],
      ),
    );
    final ctl = _FakeRoomController(state);
    await tester.pumpWidget(_wrap(Scaffold(body: SurroundOrientSheet(layout: layout)), _overrides(state, controller: ctl)));
    await tester.pump();
    expect(find.textContaining('Found 4 phones'), findsOneWidget);
    expect(find.text('Use this layout'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'Front L').at(0));
    await tester.tap(find.widgetWithText(FilterChip, 'Front R').at(0));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'Front L').at(1));
    await tester.pump();
    for (final badge in ['L', 'R', 'SL', 'SR']) {
      expect(find.text(badge), findsWidgets, reason: badge);
    }
    expect(find.text('30° left, 2.0 m · volume -4 dB'), findsOneWidget);
    expect(find.text('30° right, 2.0 m'), findsOneWidget);
    expect(find.textContaining('110° right, 1.8 m · volume -8 dB'), findsOneWidget);
    await tester.tap(find.text('Use this layout'));
    await tester.pump();
    expect(ctl.sent.where((x) => x == ControlAction.setChannelRole).length, 4);
    // Trims down to the quietest front phone (Front R); rears 3 dB lower.
    expect(ctl.sent.where((x) => x == ControlAction.deviceVolume).length, 3);
  });

  testWidgets('queue shows upload progress', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const Scaffold(body: QueueView()),
        _overrides(_roomState(role: ParticipantRole.controller).copyWith(
            info: const RoomInfo(isHost: false, roomId: 'K7Q2M9', roomName: 'Living room', host: 'h', port: 1),
            adding: (1, 3)))));
    await tester.pump();
    expect(find.text('Sending songs to the host… 2 of 3'), findsOneWidget);
  });

  testWidgets('room: three tabs with player, queue and speakers', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const RoomScreen(), _overrides(_roomState())));
    await tester.pump();
    expect(find.text('Living room'), findsOneWidget);
    expect(find.textContaining('2 phones · In sync'), findsOneWidget);
    expect(find.text('Blue Hour'), findsOneWidget); // Playing tab

    await tester.tap(find.text('Queue'));
    await tester.pump();
    expect(find.text('Blue Hour'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.text('Speakers'));
    await tester.pump();
    expect(find.descendant(of: find.byType(ListTile), matching: find.textContaining('Kitchen')), findsOneWidget);
    expect(find.textContaining('downloading song'), findsOneWidget);
    expect(find.text('Calibrate to this spot'), findsOneWidget);
    expect(find.textContaining('cannot record audio'), findsOneWidget);
  });

  testWidgets('host invite shows QR code and typed code', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const RoomScreen(), _overrides(_roomState())));
    await tester.pump();
    await tester.tap(find.byTooltip('Invite'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('ABCD-2345'), findsOneWidget);
    expect(find.textContaining('Anyone with this code can join'), findsOneWidget);
  });

  testWidgets('device sheet: channel and timing fine-tune for another phone', (tester) async {
    _phone(tester);
    final ctl = _FakeRoomController(_roomState());
    await tester.pumpWidget(_wrap(const RoomScreen(), _overrides(_roomState(), controller: ctl)));
    await tester.pump();
    await tester.tap(find.text('Speakers'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'Kitchen'));
    await tester.pumpAndSettle();
    expect(find.text('No adjustment'), findsOneWidget);
    await tester.tap(find.text('Left'));
    await tester.tap(find.byTooltip('Play 5 ms earlier'));
    await tester.pump();
    expect(ctl.sent, [ControlAction.setChannelRole, ControlAction.setCalibration]);
  });

  testWidgets('player sends controls when allowed', (tester) async {
    _phone(tester);
    final ctl = _FakeRoomController(_roomState());
    await tester.pumpWidget(_wrap(const Scaffold(body: NowPlayingView()), _overrides(_roomState(), controller: ctl)));
    await tester.pump();
    expect(find.text('Blue Hour'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget); // expected position 65 s
    await tester.tap(find.byTooltip('Pause'));
    await tester.tap(find.byTooltip('Shuffle off'));
    await tester.tap(find.byTooltip('Repeat off'));
    await tester.pump();
    expect(ctl.sent, [ControlAction.pause, ControlAction.setShuffle, ControlAction.setRepeat]);
  });

  testWidgets('player: "sounds early or late" opens this phone\'s timing', (tester) async {
    _phone(tester);
    final ctl = _FakeRoomController(_roomState());
    await tester.pumpWidget(_wrap(const Scaffold(body: NowPlayingView()), _overrides(_roomState(), controller: ctl)));
    await tester.pump();
    await tester.tap(find.text('This phone sounds early or late?'));
    await tester.pumpAndSettle();
    expect(find.text('My Phone (this phone)'), findsOneWidget);
    await tester.tap(find.byTooltip('Play 5 ms later'));
    await tester.pumpAndSettle();
    // Saved for this phone (sent to the room too when connected).
    final container = ProviderScope.containerOf(tester.element(find.byType(NowPlayingView)));
    expect(container.read(identityProvider).outputCalibrationUs, -5000);
  });

  testWidgets('player disables controls for listeners', (tester) async {
    _phone(tester);
    final listener = _FakeRoomController(_roomState(role: ParticipantRole.listener));
    await tester.pumpWidget(_wrap(const Scaffold(body: NowPlayingView()),
        _overrides(_roomState(role: ParticipantRole.listener), controller: listener)));
    await tester.pump();
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(listener.sent, isEmpty);
    expect(find.textContaining('You are a listener'), findsOneWidget);
  });

  testWidgets('player shows reconnecting state when the coordinator is lost', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const Scaffold(body: NowPlayingView()), _overrides(_roomState(live: false))));
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

  testWidgets('diagnostics copies a JSON report', (tester) async {
    _phone(tester);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(_wrap(const DiagnosticsScreen(), _overrides(_roomState())));
    await tester.pump();
    await tester.tap(find.byTooltip('Copy diagnostics report'));
    await tester.pump();
    final report = jsonDecode(copied!) as Map<String, Object?>;
    expect(report['kind'], 'syncsphere-diagnostics-v1');
    expect((report['room'] as Map)['name'], isNotNull);
    expect(copied, isNot(contains('ABCD2345')), reason: 'no join key in reports');
  });

  testWidgets('home offers "Rejoin your party" when the party this phone created is still running', (tester) async {
    _phone(tester);
    final store = MemoryAppStore();
    await store.saveHostedRoom(HostedRoom(roomId: 'R2D2C3', roomName: 'Garden party', joinKey: 'ABCD2345', startedAt: DateTime(2026)));
    await tester.pumpWidget(_wrap(const HomeScreen(), _overrides(const RoomViewState(), appStore: store)));
    await tester.pumpAndSettle();
    expect(find.text('Rejoin your party'), findsOneWidget);
    expect(find.textContaining('host again'), findsOneWidget);
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(find.text('Rejoin your party'), findsNothing);
  });

  testWidgets('host can add songs from the phone during a party', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_wrap(const RoomScreen(), _overrides(_roomState())));
    await tester.pump();
    await tester.tap(find.text('Queue'));
    await tester.pump();
    await tester.tap(find.text('Add songs'));
    await tester.pumpAndSettle();
    expect(find.text('From this phone…'), findsOneWidget);
    expect(find.text('From My music'), findsOneWidget);
  });
}
