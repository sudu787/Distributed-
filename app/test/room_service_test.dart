// Real-socket test of the app's room orchestration: one device hosts, one
// joins over loopback, the joiner downloads the track from the host, and
// playback starts on both (null audio backend; no Android needed).
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncsphere/src/data/app_store.dart';
import 'package:syncsphere/src/data/models.dart';
import 'package:syncsphere/src/data/sqflite_store.dart';
import 'package:syncsphere/src/services/library_service.dart';
import 'package:syncsphere/src/services/room_service.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('syncsphere_app_test'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<File> audioFile(String name, int seed) async {
    final rnd = Random(seed);
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(List<int>.generate(200 * 1024, (_) => rnd.nextInt(256)));
    return f;
  }

  test('SQLite store persists identity, library and history', () async {
    sqfliteFfiInit();
    final path = '${tmp.path}/t.db';
    var store = await SqfliteAppStore.open(path, factory: databaseFactoryFfi);
    final id = await store.loadIdentity(defaultName: 'Phone');
    expect(isValidDeviceId(id.deviceId), isTrue);
    await store.saveIdentity(id.copyWith(displayName: 'Kitchen', startLatencyUs: 61000));
    await store.upsertTrack(LibraryTrack(
        id: 'a' * 64, path: '/x.mp3', title: 'X', sizeBytes: 10, addedAt: DateTime(2026)));
    await store.addRoomHistory(RoomHistoryEntry(
        roomId: 'R1', roomName: 'Party', host: 'h', port: 1, hosted: false, at: DateTime(2026)));
    await store.close();
    store = await SqfliteAppStore.open(path, factory: databaseFactoryFfi);
    final again = await store.loadIdentity(defaultName: 'ignored');
    expect(again.deviceId, id.deviceId);
    expect(again.displayName, 'Kitchen');
    expect(again.startLatencyUs, 61000);
    expect((await store.libraryTracks()).single.title, 'X');
    expect((await store.roomHistory()).single.roomName, 'Party');
    await store.close();
  });

  test('library import deduplicates by content hash', () async {
    final store = MemoryAppStore();
    final lib = LibraryService(
        store: store, libraryDir: Directory('${tmp.path}/lib'), log: EventLog(clock: SystemMonotonicClock.instance));
    final f = await audioFile('song.mp3', 1);
    final a = await lib.import(f);
    final copy = await f.copy('${tmp.path}/renamed.mp3');
    final b = await lib.import(copy);
    expect(a.id, b.id);
    expect((await lib.list()).length, 1);
  });

  test('host and join over loopback; joiner downloads and both play', () async {
    final clock = SystemMonotonicClock.instance;
    Future<RoomKey> fastKdf(String r, String k, int i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i);

    final hostStore = MemoryAppStore();
    final hostLib = LibraryService(store: hostStore, libraryDir: Directory('${tmp.path}/hostlib'), log: EventLog(clock: clock));
    final track = await hostLib.import(await audioFile('track.mp3', 7));
    final hostSvc = RoomService(
      store: hostStore,
      cacheDir: Directory('${tmp.path}/hostcache'),
      backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
      keyDeriver: fastKdf,
      kdfIterations: 50,
    );
    final hostId = await hostStore.loadIdentity(defaultName: 'Host');
    final info = await hostSvc.host(
        identity: hostId, roomName: 'Test room', tracks: [track], port: 0, openControl: true);
    expect(info.joinKey, isNotNull);
    expect(hostSvc.session!.role, ParticipantRole.host);

    final guestStore = MemoryAppStore();
    final guestSvc = RoomService(
      store: guestStore,
      cacheDir: Directory('${tmp.path}/guestcache'),
      backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
      keyDeriver: fastKdf,
      kdfIterations: 50,
    );
    final guestId = await guestStore.loadIdentity(defaultName: 'Guest');

    // Wrong key first: must fail cleanly and leave no session behind.
    await expectLater(
        guestSvc.join(identity: guestId, host: '127.0.0.1', port: info.port, joinKey: 'WRONGKEY'),
        throwsA(isA<SessionFailure>()));
    expect(guestSvc.inRoom, isFalse);

    final joined = await guestSvc.join(identity: guestId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    expect(joined.roomName, 'Test room');
    expect(guestSvc.session!.role, ParticipantRole.controller);

    final ack = await guestSvc.session!.control(ControlAction.play);
    expect(ack.accepted, isTrue);
    final coord = hostSvc.coordinator!;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final g = coord.state.timeline.generation;
      if (coord.state.timeline.isPlaying &&
          hostSvc.session!.engine.status.activeGeneration == g &&
          guestSvc.session!.engine.status.activeGeneration == g) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(guestSvc.session!.engine.status.activeGeneration, coord.state.timeline.generation);
    expect(File('${tmp.path}/guestcache/tracks/${track.id}.audio').existsSync(), isTrue);

    await guestSvc.leave();
    final history = await guestStore.roomHistory();
    expect(history.single.roomName, 'Test room');
    await hostSvc.leave();
    expect(hostSvc.inRoom, isFalse);
  });

  test('host crash: first guest takes over as coordinator, the other follows, audio continues', () async {
    final clock = SystemMonotonicClock.instance;
    Future<RoomKey> fastKdf(String r, String k, int i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i);
    Future<(RoomService, DeviceIdentity)> device(String name, {List<LibraryTrack> tracks = const []}) async {
      final store = MemoryAppStore();
      for (final t in tracks) {
        await store.upsertTrack(t);
      }
      final svc = RoomService(
        store: store,
        cacheDir: Directory('${tmp.path}/cache-$name'),
        backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
        keyDeriver: fastKdf,
        kdfIterations: 50,
      );
      return (svc, await store.loadIdentity(defaultName: name));
    }

    final hostLib = LibraryService(store: MemoryAppStore(), libraryDir: Directory('${tmp.path}/lib'), log: EventLog(clock: clock));
    final track = await hostLib.import(await audioFile('t.mp3', 3));
    final (host, hostId) = await device('host', tracks: [track]);
    final (a, aId) = await device('a', tracks: [track]);
    final (b, bId) = await device('b', tracks: [track]);
    final info = await host.host(identity: hostId, roomName: 'Crashy', tracks: [track], port: 0, openControl: true);
    await a.join(identity: aId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    await b.join(identity: bId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    expect((await b.session!.control(ControlAction.play)).accepted, isTrue);

    Future<void> waitFor(bool Function() cond, String what, {int seconds = 20}) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!cond()) {
        if (DateTime.now().isAfter(deadline)) {
          // Enough context to diagnose a CI-only failure.
          final c = a.coordinator ?? host.coordinator;
          final dump = StringBuffer('timed out waiting for $what\n')
            ..writeln('coordinator: ${c?.state.timeline} pending=${c?.state.pending?.generation}')
            ..writeln('a: ${a.session?.phase} engine g${a.session?.engine.status.activeGeneration}')
            ..writeln('b: ${b.session?.phase} engine g${b.session?.engine.status.activeGeneration}');
          for (final (name, svc) in [('a', a), ('b', b)]) {
            dump.writeln('--- $name events');
            for (final e in svc.log.recent(limit: 40).reversed) {
              dump.writeln(e);
            }
          }
          fail(dump.toString());
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    await waitFor(() {
      final g = host.coordinator?.state.timeline;
      return g != null && g.isPlaying && a.session!.engine.status.activeGeneration == g.generation &&
          b.session!.engine.status.activeGeneration == g.generation;
    }, 'synchronized start');
    final gen = host.coordinator!.state.timeline.generation;

    await host.crashForTesting();
    await waitFor(() => a.promotedByFailover, 'promotion of guest a');
    await waitFor(() => b.session!.state?.coordinatorEpoch == 2 && b.session!.isLive, 'guest b following the successor');
    expect(a.coordinator!.state.coordinatorEpoch, 2);
    expect(a.coordinator!.state.timeline.generation, gen, reason: 'same timeline, no restart');
    expect(a.session!.engine.status.activeGeneration, gen);
    expect(b.session!.engine.status.activeGeneration, gen);
    expect(a.info!.isHost, isTrue);
    // The successor accepts control and schedules new segments.
    expect((await b.session!.control(ControlAction.seek, positionUs: 30000000)).accepted, isTrue);
    await waitFor(() => b.session!.engine.status.activeGeneration == a.coordinator!.state.timeline.generation &&
        a.coordinator!.state.timeline.generation > gen, 'seek on successor');

    await b.leave();
    await a.leave();
  });

  test('platform hooks: notification commands control the room, now-playing follows, calibration persists', () async {
    final clock = SystemMonotonicClock.instance;
    final store = MemoryAppStore();
    final lib = LibraryService(store: store, libraryDir: Directory('${tmp.path}/lib'), log: EventLog(clock: clock));
    final track = await lib.import(await audioFile('n.mp3', 5));
    final hooks = _RecordingHooks();
    final svc = RoomService(
      store: store,
      cacheDir: Directory('${tmp.path}/cache'),
      backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
      keyDeriver: (r, k, i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i),
      kdfIterations: 50,
      hooks: hooks,
    );
    final id = await store.loadIdentity(defaultName: 'Host');
    await svc.host(identity: id, roomName: 'Hooked', tracks: [track], port: 0);
    expect(hooks.entered, ['Hooked']);

    Future<void> waitFor(bool Function() cond, String what) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!cond()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    hooks.cmd.add('play');
    await waitFor(() => svc.coordinator!.state.timeline.isPlaying, 'play from notification');
    await waitFor(() => hooks.shown.any((n) => n.playing && n.text.contains(track.title)), 'now-playing update');
    hooks.cmd.add('pause');
    await waitFor(() => svc.coordinator!.state.timeline.status == PlaybackStatus.paused, 'pause from notification');
    expect(hooks.shown.last.playing, isFalse);
    expect(hooks.shown.last.roomName, 'Hooked');

    // Manual calibration goes through the room, and is saved on leave.
    final ack = await svc.session!.control(ControlAction.setCalibration, offsetUs: -30000);
    expect(ack.accepted, isTrue);
    await waitFor(() => svc.session!.engine.outputCalibrationUs == -30000, 'calibration applied');
    await svc.leave();
    expect(hooks.left, 1);
    expect((await store.loadIdentity(defaultName: 'x')).outputCalibrationUs, -30000);
  });
}

class _RecordingHooks extends PlatformHooks {
  final cmd = StreamController<String>.broadcast();
  final entered = <String>[];
  final shown = <({String roomName, String text, bool playing})>[];
  var left = 0;

  @override
  Future<void> enterRoom(String roomName) async => entered.add(roomName);

  @override
  Future<void> leaveRoom() async => left++;

  @override
  Future<void> nowPlaying({required String roomName, required String text, required bool playing}) async =>
      shown.add((roomName: roomName, text: text, playing: playing));

  @override
  Stream<String> get commands => cmd.stream;
}
