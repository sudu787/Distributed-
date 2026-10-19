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

  test('recent parties: one entry per party, newest 5, join key kept; v1 databases upgrade', () async {
    sqfliteFfiInit();
    final path = '${tmp.path}/old.db';
    // A database written by the previous app version (schema v1).
    final old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE device_config (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
            await db.execute('CREATE TABLE library_tracks (id TEXT PRIMARY KEY, path TEXT NOT NULL, title TEXT NOT NULL, '
                'artist TEXT, album TEXT, size INTEGER NOT NULL, duration_us INTEGER, mime TEXT, added_at INTEGER NOT NULL)');
            await db.execute('CREATE TABLE room_history (room_id TEXT NOT NULL, room_name TEXT NOT NULL, host TEXT NOT NULL, '
                'port INTEGER NOT NULL, hosted INTEGER NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (room_id, at))');
          },
        ));
    for (var i = 0; i < 2; i++) {
      await old.insert('room_history',
          {'room_id': 'OLD', 'room_name': 'Old party', 'host': 'h', 'port': 1, 'hosted': 0, 'at': 1000 + i});
    }
    await old.close();

    for (final store in <AppStore>[await SqfliteAppStore.open(path, factory: databaseFactoryFfi), MemoryAppStore()]) {
      final before = await store.roomHistory();
      if (store is SqfliteAppStore) {
        expect(before.single.roomId, 'OLD', reason: 'duplicates from v1 are shown once');
        expect(before.single.joinKey, isNull);
      }
      for (var i = 0; i < 7; i++) {
        await store.addRoomHistory(RoomHistoryEntry(
            roomId: 'R$i', roomName: 'Party $i', host: 'h', port: 1, hosted: false, at: DateTime(2026, 1, 1 + i), joinKey: 'KEY$i'));
      }
      // Joining party 2 again moves it to the top instead of adding a row.
      await store.addRoomHistory(RoomHistoryEntry(
          roomId: 'R2', roomName: 'Party 2', host: 'h2', port: 2, hosted: false, at: DateTime(2026, 2), joinKey: 'KEY2'));
      final h = await store.roomHistory();
      expect(h.map((e) => e.roomId), ['R2', 'R6', 'R5', 'R4', 'R3']);
      expect(h.first.joinKey, 'KEY2');
      expect(h.first.host, 'h2');
      await store.removeRoomHistory('R5');
      expect((await store.roomHistory()).map((e) => e.roomId), ['R2', 'R6', 'R4', 'R3']);
      // v3: songs keep where they came from.
      await store.upsertTrack(LibraryTrack(
          id: 'b' * 64,
          path: '/y.mp3',
          title: 'Y',
          sizeBytes: 3,
          addedAt: DateTime(2026),
          sourceUrl: 'https://api.audius.co/v1/tracks/abc/stream?app_name=SyncSphere',
          artUrl: 'https://img.example/480.jpg',
          credit: 'via Audius'));
      final y = (await store.libraryTracks()).firstWhere((t) => t.id == 'b' * 64);
      expect(y.sourceUrl, contains('audius'));
      expect(y.toTrackInfo().credit, 'via Audius');
      await store.saveSetting('haptics', '0');
      expect(await store.setting('haptics'), '0');
      await store.close();
    }
  });

  test('a guest allowed to control adds songs from their phone; the host and others get them', () async {
    final clock = SystemMonotonicClock.instance;
    Future<RoomKey> fastKdf(String r, String k, int i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i);
    Future<(RoomService, DeviceIdentity, MemoryAppStore)> device(String name) async {
      final store = MemoryAppStore();
      final svc = RoomService(
        store: store,
        cacheDir: Directory('${tmp.path}/cache-$name'),
        backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
        keyDeriver: fastKdf,
        kdfIterations: 50,
        watchForNewerCoordinator: false,
      );
      return (svc, await store.loadIdentity(defaultName: name), store);
    }

    final (host, hostId, hostStore) = await device('host');
    final hostLib = LibraryService(store: hostStore, libraryDir: Directory('${tmp.path}/hostlib'), log: EventLog(clock: clock));
    final first = await hostLib.import(await audioFile('first.mp3', 1));
    final info = await host.host(identity: hostId, roomName: 'Upload party', tracks: [first], port: 0);
    final (guest, guestId, guestStore) = await device('guest');
    final (other, otherId, _) = await device('other');
    await guest.join(identity: guestId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    await other.join(identity: otherId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);

    final guestLib = LibraryService(store: guestStore, libraryDir: Directory('${tmp.path}/guestlib'), log: EventLog(clock: clock));
    final song = await guestLib.import(await audioFile('guest-song.mp3', 42));

    // Listeners cannot add songs.
    expect(await guest.addTracks([song]), ControlError.unauthorized);
    expect(host.coordinator!.state.trackById(song.id), isNull);

    final promote = await host.session!.control(ControlAction.setRole,
        targetDevice: guestId.deviceId, role: ParticipantRole.controller);
    expect(promote.accepted, isTrue);
    final roleDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (guest.session!.role != ParticipantRole.controller && DateTime.now().isBefore(roleDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final progress = <(int, int)>[];
    expect(await guest.addTracks([song], onProgress: (d, t) => progress.add((d, t))), isNull);
    expect(progress.last, (1, 1));
    final added = host.coordinator!.state.trackById(song.id)!;
    expect(added.hostServes, isTrue);
    expect(added.title, 'guest-song');
    expect(File('${tmp.path}/cache-host/tracks/${song.id}.audio').existsSync(), isTrue);
    // Adding the same song again is a no-op.
    expect(await guest.addTracks([song]), isNull);
    expect(host.coordinator!.state.playlist.where((t) => t.id == song.id).length, 1);

    // The guest's song plays on every phone: the third phone downloads it from the host.
    expect((await guest.session!.control(ControlAction.setTrack, trackId: song.id)).accepted, isTrue);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    final coord = host.coordinator!;
    bool allPlaying() {
      final g = coord.state.timeline.generation;
      return coord.state.timeline.isPlaying &&
          coord.state.timeline.trackId == song.id &&
          [host, guest, other].every((d) => d.session!.engine.status.activeGeneration == g);
    }

    while (!allPlaying() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(allPlaying(), isTrue);
    expect(File('${tmp.path}/cache-other/tracks/${song.id}.audio').existsSync(), isTrue);

    await other.leave();
    await guest.leave();
    await host.leave();
  });

  test('phone-to-phone sharing: a late guest gets the song from another guest, not only the host', () async {
    final clock = SystemMonotonicClock.instance;
    Future<RoomKey> fastKdf(String r, String k, int i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i);
    Future<(RoomService, DeviceIdentity, MemoryAppStore)> device(String name) async {
      final store = MemoryAppStore();
      final svc = RoomService(
        store: store,
        cacheDir: Directory('${tmp.path}/cache-$name'),
        backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
        keyDeriver: fastKdf,
        kdfIterations: 50,
        watchForNewerCoordinator: false,
      );
      return (svc, await store.loadIdentity(defaultName: name), store);
    }

    final (host, hostId, hostStore) = await device('host');
    final rnd = Random(77);
    final big = File('${tmp.path}/big.mp3')..writeAsBytesSync(List<int>.generate(3 * 1024 * 1024 + 4321, (_) => rnd.nextInt(256)));
    final song = await LibraryService(store: hostStore, libraryDir: Directory('${tmp.path}/hostlib'), log: EventLog(clock: clock))
        .import(big);
    final info = await host.host(identity: hostId, roomName: 'Share', tracks: [song], port: 0, openControl: true);
    // The coordinator publishes the chunk root in the background.
    final rootDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (host.coordinator!.state.playlist.single.chunkRoot == null && DateTime.now().isBefore(rootDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(host.coordinator!.state.playlist.single.chunkRoot, isNotNull);

    final (first, firstId, _) = await device('first');
    await first.join(identity: firstId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    Future<void> waitFile(String name) async {
      final f = File('${tmp.path}/cache-$name/tracks/${song.id}.audio');
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!f.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(f.existsSync(), isTrue, reason: '$name has the song');
    }

    expect((await first.session!.control(ControlAction.play)).accepted, isTrue);
    await waitFile('first');
    expect(host.coordinator!.state.participants.firstWhere((p) => p.deviceId == firstId.deviceId).peer, isNotNull);

    final (late, lateId, _) = await device('late');
    // Joins while the song plays: it must fetch it now.
    await late.join(identity: lateId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    await waitFile('late');
    final done = late.log.recent(limit: 500, categoryPrefix: 'swarm.done').map((e) => e.message).join('\n');
    expect(done, contains('from 1 phone(s)'), reason: done);
    expect(first.bytesSharedWithPeers, greaterThan(0));

    await late.leave();
    await first.leave();
    await host.leave();
  });

  test('chunk roots are computed only for the songs about to play, not the whole library', () async {
    final clock = SystemMonotonicClock.instance;
    final store = MemoryAppStore();
    final lib = LibraryService(store: store, libraryDir: Directory('${tmp.path}/rootlib'), log: EventLog(clock: clock));
    final songs = [for (var i = 0; i < 4; i++) await lib.import(await audioFile('r$i.mp3', 100 + i))];
    final svc = RoomService(
      store: store,
      cacheDir: Directory('${tmp.path}/rootcache'),
      backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
      keyDeriver: (r, k, i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i),
      kdfIterations: 50,
      watchForNewerCoordinator: false,
    );
    await svc.host(identity: await store.loadIdentity(defaultName: 'H'), roomName: 'Roots', tracks: songs, port: 0, openControl: true);
    Future<void> waitRoots(Set<int> expected) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      Set<int> have() => {
            for (var i = 0; i < songs.length; i++)
              if (svc.coordinator!.state.playlist[i].chunkRoot != null) i,
          };
      while (!have().containsAll(expected) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(have(), expected);
    }

    // Nothing playing yet: only the first song is prepared.
    await waitRoots({0});
    expect((await svc.session!.control(ControlAction.setTrack, trackId: songs[2].id)).accepted, isTrue);
    // Now the current song (2) and the next one (3) as well.
    await waitRoots({0, 2, 3});
    await svc.leave();
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

  test('3 phones: host crashes, next phone hosts, host rejoins and gets the role back (real sockets)', () async {
    final clock = SystemMonotonicClock.instance;
    Future<RoomKey> fastKdf(String r, String k, int i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i);
    final hostStore = MemoryAppStore();
    Future<(RoomService, DeviceIdentity)> device(String name, int port, {AppStore? store, List<LibraryTrack> tracks = const []}) async {
      final st = store ?? MemoryAppStore();
      for (final t in tracks) {
        await st.upsertTrack(t);
      }
      final svc = RoomService(
        store: st,
        cacheDir: Directory('${tmp.path}/fb-cache-$name'),
        backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
        keyDeriver: fastKdf,
        kdfIterations: 50,
        failoverPort: port,
        watchForNewerCoordinator: false,
        handbackPolicy: const HandbackPolicy(stableFor: Duration(seconds: 2)),
      );
      return (svc, await st.loadIdentity(defaultName: name));
    }

    Future<void> waitFor(bool Function() cond, String what, {int seconds = 25}) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!cond()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    final lib = LibraryService(store: MemoryAppStore(), libraryDir: Directory('${tmp.path}/fb-lib'), log: EventLog(clock: clock));
    final track = await lib.import(await audioFile('fb.mp3', 9));
    var (host, hostId) = await device('host', 47921, store: hostStore, tracks: [track]);
    final (b, bId) = await device('b', 47922, tracks: [track]);
    final (c, cId) = await device('c', 47923, tracks: [track]);
    final info = await host.host(identity: hostId, roomName: 'Comeback', tracks: [track], port: 0, openControl: true);
    expect((await hostStore.hostedRoom())!.roomId, info.roomId, reason: 'remembered for rejoining');
    await b.join(identity: bId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    await c.join(identity: cId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    expect((await c.session!.control(ControlAction.play)).accepted, isTrue);
    await waitFor(() {
      final g = host.coordinator?.state.timeline;
      return g != null && g.isPlaying && b.session!.engine.status.activeGeneration == g.generation &&
          c.session!.engine.status.activeGeneration == g.generation;
    }, 'synchronized start');
    final gen = host.coordinator!.state.timeline.generation;

    // The host phone dies (app crash): the next phone takes over.
    await host.crashForTesting();
    await waitFor(() => b.coordinator != null && c.session!.state?.coordinatorEpoch == 2 && c.session!.isLive, 'takeover by b');
    expect(b.info!.isHost, isTrue);

    // The host app restarts (same identity and saved party) and rejoins.
    (host, _) = await device('host', 47921, store: hostStore, tracks: [track]);
    final saved = (await hostStore.hostedRoom())!;
    await host.join(identity: hostId, host: '127.0.0.1', port: 47922, joinKey: saved.joinKey, roomId: saved.roomId);
    await waitFor(
        () => host.coordinator != null &&
            b.coordinator == null &&
            b.session!.state?.coordinatorEpoch == 3 &&
            c.session!.state?.coordinatorEpoch == 3 &&
            b.session!.isLive &&
            c.session!.isLive &&
            host.session!.isLive &&
            host.session!.state?.coordinatorEpoch == 3,
        'handback to the original host');
    expect(host.info!.isHost, isTrue);
    expect(b.info!.isHost, isFalse);
    expect(host.coordinator!.state.coordinatorId, hostId.deviceId);
    expect(host.coordinator!.state.timeline.generation, gen, reason: 'same timeline: music never restarted');
    expect(c.session!.engine.status.activeGeneration, gen);
    final roles = {for (final p in host.coordinator!.state.participants) p.deviceId: p.role};
    expect(roles[hostId.deviceId], ParticipantRole.host);

    // Control works through the original host again.
    expect((await c.session!.control(ControlAction.seek, positionUs: 20000000)).accepted, isTrue);
    await waitFor(() => c.session!.engine.status.activeGeneration == host.coordinator!.state.timeline.generation &&
        host.coordinator!.state.timeline.generation > gen, 'seek after handback');

    await c.leave();
    await b.leave();
    await host.leave();
    expect(await hostStore.hostedRoom(), isNull, reason: 'ending the party on purpose forgets it');
  });

  test('a temporary host that leaves hands the party on instead of ending it', () async {
    final clock = SystemMonotonicClock.instance;
    Future<RoomKey> fastKdf(String r, String k, int i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i);
    Future<(RoomService, DeviceIdentity)> device(String name, int port, List<LibraryTrack> tracks) async {
      final st = MemoryAppStore();
      for (final t in tracks) {
        await st.upsertTrack(t);
      }
      final svc = RoomService(
        store: st,
        cacheDir: Directory('${tmp.path}/ho-cache-$name'),
        backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
        keyDeriver: fastKdf,
        kdfIterations: 50,
        failoverPort: port,
        watchForNewerCoordinator: false,
      );
      return (svc, await st.loadIdentity(defaultName: name));
    }

    Future<void> waitFor(bool Function() cond, String what) async {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!cond()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    final lib = LibraryService(store: MemoryAppStore(), libraryDir: Directory('${tmp.path}/ho-lib'), log: EventLog(clock: clock));
    final track = await lib.import(await audioFile('ho.mp3', 11));
    final (host, hostId) = await device('host', 47931, [track]);
    final (b, bId) = await device('b', 47932, [track]);
    final (c, cId) = await device('c', 47933, [track]);
    final info = await host.host(identity: hostId, roomName: 'Relay', tracks: [track], port: 0, openControl: true);
    await b.join(identity: bId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    await c.join(identity: cId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    await host.crashForTesting();
    await waitFor(() => b.coordinator != null && c.session!.state?.coordinatorEpoch == 2 && c.session!.isLive, 'takeover by b');

    final bLog = b.log;
    await b.leave(); // temporary host leaves: c takes over (epoch 3), party continues
    try {
      await waitFor(() => c.coordinator != null && c.session!.isLive && c.session!.state?.coordinatorEpoch == 3, 'hand-off to c');
    } catch (_) {
      String dump(EventLog l) => l.recent(limit: 80, minLevel: EventLevel.info).map((e) => '  $e').join('\n');
      // ignore: avoid_print
      print('--- b\n${dump(bLog)}\n--- c (phase ${c.session?.phase}, epoch ${c.session?.state?.coordinatorEpoch})\n${dump(c.log)}');
      rethrow;
    }
    expect(c.session!.phase, isNot(SessionPhase.failed));
    await c.leave();
  });

  test('host ends the party: guests stop for good (no failover) and can be told why', () async {
    final clock = SystemMonotonicClock.instance;
    Future<RoomKey> fastKdf(String r, String k, int i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i);
    Future<(RoomService, DeviceIdentity)> device(String name, int port, List<LibraryTrack> tracks) async {
      final st = MemoryAppStore();
      for (final t in tracks) {
        await st.upsertTrack(t);
      }
      final svc = RoomService(
        store: st,
        cacheDir: Directory('${tmp.path}/end-cache-$name'),
        backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
        keyDeriver: fastKdf,
        kdfIterations: 50,
        failoverPort: port,
        watchForNewerCoordinator: false,
      );
      return (svc, await st.loadIdentity(defaultName: name));
    }

    final lib = LibraryService(store: MemoryAppStore(), libraryDir: Directory('${tmp.path}/end-lib'), log: EventLog(clock: clock));
    final track = await lib.import(await audioFile('end.mp3', 13));
    final (host, hostId) = await device('host', 47941, [track]);
    final (b, bId) = await device('b', 47942, [track]);
    final (c, cId) = await device('c', 47943, [track]);
    final info = await host.host(identity: hostId, roomName: 'Over', tracks: [track], port: 0, openControl: true);
    await b.join(identity: bId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    await c.join(identity: cId, host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    expect((await c.session!.control(ControlAction.play)).accepted, isTrue);
    await Future<void>.delayed(const Duration(seconds: 1));

    await host.leave(); // "End party"
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!(b.session!.phase == SessionPhase.failed && c.session!.phase == SessionPhase.failed)) {
      if (DateTime.now().isAfter(deadline)) fail('guests did not learn that the party ended');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(b.session!.lastFailure, startsWith(RejectCode.roomClosed));
    // Wait past the failover delay: nobody may take over an ended party.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(b.coordinator, isNull);
    expect(c.coordinator, isNull);
    await b.leave(endParty: false);
    await c.leave(endParty: false);
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
