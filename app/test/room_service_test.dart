// Real-socket test of the app's room orchestration: one device hosts, one
// joins over loopback, the joiner downloads the track from the host, and
// playback starts on both (null audio backend; no Android needed).
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
}
