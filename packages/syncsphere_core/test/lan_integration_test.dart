/// Integration tests over real sockets on the loopback interface:
/// WebSocket control channel, HTTP track delivery with Range/resume,
/// authorisation, hash verification and UDP beacon parsing.
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('syncsphere_test'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<(File, TrackInfo)> makeTrack(String name, int size, {int seed = 1}) async {
    final rnd = Random(seed);
    final bytes = List<int>.generate(size, (_) => rnd.nextInt(256));
    final f = File('${tmp.path}/$name')..writeAsBytesSync(bytes);
    final id = sha256.convert(bytes).toString();
    return (f, TrackInfo(id: id, title: name, sizeBytes: size, durationUs: 120000000));
  }

  group('parseByteRange', () {
    test('valid forms', () {
      expect(parseByteRange('bytes=0-99', 1000), (0, 99));
      expect(parseByteRange('bytes=500-', 1000), (500, 999));
      expect(parseByteRange('bytes=-100', 1000), (900, 999));
      expect(parseByteRange('bytes=900-5000', 1000), (900, 999));
    });
    test('invalid forms', () {
      for (final h in ['bytes=1000-', 'bytes=5-1', 'items=0-1', 'bytes=0-1,5-6', 'bytes=-0', 'bytes=x-']) {
        expect(parseByteRange(h, 1000), isNull, reason: h);
      }
    });
  });

  group('hashing', () {
    test('streaming SHA-256 matches and cache invalidates on change', () async {
      final (f, t) = await makeTrack('a.mp3', 300000);
      final h = TrackHasher();
      expect((await h.hash(f)).sha256, t.id);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      f.writeAsBytesSync([1, 2, 3], mode: FileMode.append);
      expect((await h.hash(f)).sha256, isNot(t.id));
    });
  });

  group('LAN file delivery', () {
    late HttpServer server;
    late TrackFileServer files;
    final log = EventLog(clock: SystemMonotonicClock.instance);
    final roomKey = RoomKey.derive(roomId: 'r', joinKey: 'K', iterations: 1);
    final keys = roomKey.sessionKeys('dev-1', 'cn', 'sn');
    final served = <String, File>{};

    setUp(() async {
      files = TrackFileServer(
        fileForTrack: (id) => served[id],
        keysForSession: (s) => s == 'sess-1' ? keys : null,
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
        log: log,
        config: const TransferConfig(maxConcurrentPerSession: 1),
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(files.handle);
    });
    tearDown(() async => server.close(force: true));

    TransferContext ctx({String session = 'sess-1', List<int>? key}) => TransferContext(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
          sessionId: session,
          transferKey: key ?? keys.transfer,
          coordinatorNowMs: () => DateTime.now().millisecondsSinceEpoch,
        );

    test('rejects unauthenticated and forged requests', () async {
      final (f, t) = await makeTrack('a', 1000);
      served[t.id] = f;
      final client = HttpClient();
      final r1 = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/tracks/${t.id}'))).close();
      expect(r1.statusCode, 401);
      await r1.drain<void>();
      final d = TrackDownloader(log: log, config: const TransferConfig(maxDownloadRetries: 0));
      final cache = TrackCache(Directory('${tmp.path}/cache'));
      final forged = ctx(key: List.filled(32, 7));
      await expectLater(d.download(t, forged, cache), throwsA(isA<TrackUnavailableException>()));
      // Path traversal style ids never reach the filesystem.
      final r2 = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/tracks/..%2F..%2Fetc%2Fpasswd'))).close();
      expect(r2.statusCode, 400);
      await r2.drain<void>();
      client.close();
      d.close();
    });

    test('downloads, verifies and caches', () async {
      final (f, t) = await makeTrack('b', 2 * 1024 * 1024);
      served[t.id] = f;
      final d = TrackDownloader(log: log);
      final cache = TrackCache(Directory('${tmp.path}/cache'));
      final out = await d.download(t, ctx(), cache);
      expect(sha256.convert(out.readAsBytesSync()).toString(), t.id);
      expect(await cache.has(t.id), isTrue);
      expect(files.bytesServed, t.sizeBytes);
      // Second call is served from cache.
      await d.download(t, ctx(), cache);
      expect(files.bytesServed, t.sizeBytes);
      d.close();
    });

    test('resumes a partial download with a Range request', () async {
      final (f, t) = await makeTrack('c', 1024 * 1024, seed: 9);
      served[t.id] = f;
      final cache = TrackCache(Directory('${tmp.path}/cache'));
      await cache.dir.create(recursive: true);
      final bytes = f.readAsBytesSync();
      cache.partFor(t.id).writeAsBytesSync(bytes.sublist(0, 400000));
      final d = TrackDownloader(log: log);
      final out = await d.download(t, ctx(), cache);
      expect(sha256.convert(out.readAsBytesSync()).toString(), t.id);
      expect(files.bytesServed, t.sizeBytes - 400000);
      d.close();
    });

    test('detects corrupted content via hash', () async {
      final (f, t) = await makeTrack('d', 50000, seed: 3);
      final (other, _) = await makeTrack('e', 50000, seed: 4);
      served[t.id] = other; // host serves the wrong bytes under t's id
      final d = TrackDownloader(log: log, config: const TransferConfig(maxDownloadRetries: 0));
      await expectLater(
          d.download(t, ctx(), TrackCache(Directory('${tmp.path}/cache'))),
          throwsA(isA<TrackUnavailableException>().having((e) => e.code, 'code', 'hash_mismatch')));
      d.close();
      expect(f.existsSync(), isTrue);
    });

    test('library resolver respects distribution modes', () async {
      final (f, t) = await makeTrack('g', 10000, seed: 5);
      served[t.id] = f;
      final r = LibraryTrackResolver(
        library: {},
        cache: TrackCache(Directory('${tmp.path}/cache')),
        downloader: TrackDownloader(log: log),
        log: log,
      )..setTransferContext(ctx());
      expect(await r.availability(t), TrackAvailability.missing);
      await expectLater(r.resolve(t, DistributionMode.localOnly),
          throwsA(isA<TrackUnavailableException>().having((e) => e.code, 'code', 'missing_track')));
      final src = await r.resolve(t, DistributionMode.auto);
      expect(File.fromUri(src.uri).existsSync(), isTrue);
      expect(await r.availability(t), TrackAvailability.available);
    });
  });

  group('discovery', () {
    test('beacon round trip and rejection of junk', () {
      const b = RoomBeacon(roomId: 'room-1', roomName: 'Party', coordinatorId: 'h', coordinatorEpoch: 2, port: 47800);
      final back = RoomBeacon.decode(b.encode(), '10.0.0.5', DateTime(2026))!;
      expect(back.roomName, 'Party');
      expect(back.host, '10.0.0.5');
      expect(back.coordinatorEpoch, 2);
      expect(RoomBeacon.decode(utf8.encode('{"app":"other"}'), 'h', DateTime(2026)), isNull);
      expect(RoomBeacon.decode([0xff, 0xfe], 'h', DateTime(2026)), isNull);
      expect(RoomBeacon.decode(utf8.encode('{"app":"syncsphere","port":99999,"room":"x","name":"n","coord":"c"}'), 'h', DateTime(2026)), isNull);
    });

    test('listener receives beacons over loopback UDP', () async {
      final disc = RoomDiscovery(port: 0 + 47901);
      await disc.start();
      final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      const b = RoomBeacon(roomId: 'room-x', roomName: 'Loop', coordinatorId: 'h', coordinatorEpoch: 1, port: 1234);
      final got = disc.rooms.first;
      sock.send(b.encode(), InternetAddress.loopbackIPv4, 47901);
      final rooms = await got.timeout(const Duration(seconds: 3));
      expect(rooms.single.roomId, 'room-x');
      expect(rooms.single.host, '127.0.0.1');
      sock.close();
      await disc.stop();
    });
  });

  test('end-to-end over WebSockets: join, LAN download, scheduled start, reconnect', () async {
    final clock = SystemMonotonicClock.instance;
    final (f, t) = await makeTrack('song.mp3', 256 * 1024, seed: 11);
    final log = EventLog(clock: clock, source: 'coord');
    final coord = RoomCoordinator(
      options: const CoordinatorOptions(
        roomId: 'ws-room',
        roomName: 'WS',
        coordinatorId: 'host-dev',
        joinKey: 'ABCD1234',
        kdfIterations: 100,
        defaultRole: ParticipantRole.controller,
      ),
      clock: clock,
      log: log,
    );
    coord.setPlaylist([t]);
    final files = TrackFileServer(
      fileForTrack: (id) => id == t.id ? f : null,
      keysForSession: coord.transferKeysForSession,
      nowMs: () => clock.nowMicros() ~/ 1000,
      log: log,
    );
    final server = await WebSocketServer.bind(address: InternetAddress.loopbackIPv4, httpHandler: files.handle);
    coord.serve(server);
    coord.start();

    ParticipantSession make(String id, Map<String, File> library) => ParticipantSession(
          options: ParticipantOptions(
            deviceId: id,
            displayName: id,
            joinKey: 'abcd-1234',
            transferBase: Uri.parse('http://127.0.0.1:${server.port}'),
          ),
          connector: webSocketConnector('127.0.0.1', server.port),
          clock: clock,
          backend: NullAudioBackend(clock.nowMicros),
          resolver: LibraryTrackResolver(
            library: library,
            cache: TrackCache(Directory('${tmp.path}/cache-$id')),
            downloader: TrackDownloader(log: log),
            log: log,
          ),
        );

    final host = make('host-dev', {t.id: f});
    final phone = make('phone-1', {}); // must download over the LAN
    await host.start();
    await phone.start();
    expect(host.role, ParticipantRole.host);
    expect(phone.role, ParticipantRole.controller);

    // Wrong key is a fatal, reported failure.
    final intruder = ParticipantSession(
      options: const ParticipantOptions(deviceId: 'intruder', displayName: 'x', joinKey: 'WRONGKEY'),
      connector: webSocketConnector('127.0.0.1', server.port),
      clock: clock,
      backend: NullAudioBackend(clock.nowMicros),
      resolver: StaticTrackResolver({}),
    );
    await expectLater(intruder.start(), throwsA(isA<SessionFailure>().having((e) => e.code, 'code', 'auth_failed')));
    await intruder.close();

    final ack = await phone.control(ControlAction.play);
    expect(ack.accepted, isTrue);
    // Wait until the coordinator has scheduled a start and both play.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (coord.state.timeline.isPlaying &&
          host.engine.status.activeGeneration == coord.state.timeline.generation &&
          phone.engine.status.activeGeneration == coord.state.timeline.generation) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(coord.state.timeline.isPlaying, isTrue);
    expect(phone.engine.status.activeGeneration, coord.state.timeline.generation);
    expect(coord.state.participant('phone-1')!.currentTrack, TrackAvailability.available);
    expect(files.bytesServed, t.sizeBytes);

    // Positions on both devices agree with the timeline (null backend is
    // ideal, so this checks clock conversion + scheduling over real sockets).
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final hp = (await host.backend.samplePosition())!;
    final pp = (await phone.backend.samplePosition())!;
    final tl = coord.state.timeline;
    int err(PositionSample s, ParticipantSession sess) =>
        s.positionUs - tl.expectedPositionAt(sess.estimate!.toRemote(s.atLocalUs));
    expect(err(hp, host).abs(), lessThan(15000));
    expect(err(pp, phone).abs(), lessThan(15000));

    // A stale control (old base version) after a newer change is refused.
    final staleBase = phone.state!.version;
    await host.control(ControlAction.seek, positionUs: 10000000);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(phone.state!.version, greaterThan(staleBase));

    // Graceful leave updates membership.
    await phone.leave();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(coord.state.participant('phone-1'), isNull);

    await host.close();
    await coord.close();
    await server.close();
  });
}
