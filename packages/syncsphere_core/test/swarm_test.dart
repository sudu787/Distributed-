/// Phone-to-phone sharing over loopback: chunk lists, partial copies,
/// peer tokens and the swarm downloader (including a dishonest peer).
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  final log = EventLog(clock: SystemMonotonicClock.instance);
  final room = RoomKey.derive(roomId: 'room', joinKey: 'KEY', iterations: 1);
  final hostKeys = room.sessionKeys('guest', 'cn', 'sn');
  final servers = <HttpServer>[];
  int now() => DateTime.now().millisecondsSinceEpoch;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('syncsphere_swarm'));
  tearDown(() async {
    for (final s in servers) {
      await s.close(force: true);
    }
    servers.clear();
    await tmp.delete(recursive: true);
  });

  (File, TrackInfo, List<int>) makeTrack(int size, {int seed = 1}) {
    final rnd = Random(seed);
    final bytes = List<int>.generate(size, (_) => rnd.nextInt(256));
    final f = File('${tmp.path}/src-$seed')..writeAsBytesSync(bytes);
    return (f, TrackInfo(id: sha256.convert(bytes).toString(), title: 'Song', sizeBytes: size), bytes);
  }

  Future<(HttpServer, TrackFileServer)> serve({
    File? Function(String id)? file,
    Future<PartialTrack?> Function(String id)? partial,
    bool sessionAuth = false,
  }) async {
    final idx = ChunkIndex();
    final fs = TrackFileServer(
      fileForTrack: file ?? (_) => null,
      keysForSession: (s) => sessionAuth && s == 'sess' ? hostKeys : null,
      nowMs: now,
      log: log,
      peerKey: room.peerKey,
      chunksFor: idx.hashesFor,
      partialFor: partial,
    );
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(fs.handle);
    servers.add(s);
    return (s, fs);
  }

  group('chunks', () {
    test('hashes, root, bitmap and range coverage', () async {
      final (f, _, bytes) = makeTrack(kChunkSize * 2 + 100);
      final h = await chunkHashesOf(f);
      expect(h.length, 3);
      expect(h[2], sha256.convert(bytes.sublist(kChunkSize * 2)).toString());
      expect(chunkRootOf(h), hasLength(64));
      final m = ChunkMap(3)..set(0)..set(2);
      expect(m.covers(0, kChunkSize, f.lengthSync()), isTrue);
      expect(m.covers(kChunkSize - 1, kChunkSize + 1, f.lengthSync()), isFalse);
      final back = ChunkMap.fromJson(m.toJson(), 3)!;
      expect([back.has(0), back.has(1), back.has(2)], [true, false, true]);
      expect(ChunkMap.fromJson(m.toJson(), 4), isNull);
    });

    test('a partial copy accepts only matching chunks and resumes', () async {
      final (f, t, bytes) = makeTrack(kChunkSize * 3);
      final h = await chunkHashesOf(f);
      final dir = Directory('${tmp.path}/cache');
      final p = await PartialTrack.open(dir, t.id, t.sizeBytes, h);
      expect(await p.write(1, bytes.sublist(kChunkSize, 2 * kChunkSize)), isTrue);
      expect(await p.write(0, List.filled(kChunkSize, 0)), isFalse, reason: 'wrong content');
      final again = await PartialTrack.open(dir, t.id, t.sizeBytes, h);
      expect(again.map.has(1), isTrue);
      expect(again.map.has(0), isFalse);
      expect((await PartialTrack.peek(dir, t.id))!.map.have, 1);
      final raf = await again.data.open();
      await raf.setPosition(kChunkSize);
      expect(await raf.read(16), bytes.sublist(kChunkSize, kChunkSize + 16));
      await raf.close();
    });
  });

  test('peer server: chunk list, have-map, partial ranges, peer-token auth', () async {
    final (f, t, _) = makeTrack(kChunkSize * 3);
    final h = await chunkHashesOf(f);
    final dir = Directory('${tmp.path}/peer');
    final p = await PartialTrack.open(dir, t.id, t.sizeBytes, h);
    final full = await f.readAsBytes();
    await p.write(2, full.sublist(2 * kChunkSize));
    final (srv, fs) = await serve(partial: (id) => PartialTrack.peek(dir, id));
    final client = HttpClient();
    Future<(int, String)> get(String path, {List<int>? key, String? range}) async {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:${srv.port}$path'));
      req.headers.set('x-syncsphere-auth', signTransfer('guest-2', key ?? room.peerKey(), path, now() + 60000));
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close();
      final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      return (res.statusCode, String.fromCharCodes(body.take(1000)));
    }

    expect((await get('/tracks/${t.id}/chunks')).$2, contains(h[2]));
    expect((await get('/tracks/${t.id}/have')).$2, contains('"n":3'));
    final ok = await get('/tracks/${t.id}', range: 'bytes=${2 * kChunkSize}-${3 * kChunkSize - 1}');
    expect(ok.$1, HttpStatus.partialContent);
    expect((await get('/tracks/${t.id}', range: 'bytes=0-${kChunkSize - 1}')).$1, HttpStatus.requestedRangeNotSatisfiable);
    expect((await get('/tracks/${t.id}/chunks', key: List.filled(32, 1))).$1, HttpStatus.unauthorized);
    expect((await get('/tracks/${t.id}/bogus')).$1, HttpStatus.badRequest);
    expect(fs.bytesServedFromPartial, kChunkSize);
    client.close(force: true);
  });

  test('swarm: pulls from peers (complete and partial), bans a dishonest peer, verifies the file', () async {
    final (f, base, bytes) = makeTrack(kChunkSize * 8 + 12345, seed: 3);
    final h = await chunkHashesOf(f);
    final t = base.copyWith(chunkRoot: chunkRootOf(h));
    // Host with the complete file (session auth), a phone with the complete
    // file, a phone with half the chunks, and a phone that lies.
    final (host, hostFs) = await serve(file: (id) => id == t.id ? f : null, sessionAuth: true);
    final (full, fullFs) = await serve(file: (id) => id == t.id ? f : null);
    final halfDir = Directory('${tmp.path}/half');
    final half = await PartialTrack.open(halfDir, t.id, t.sizeBytes, h);
    for (var i = 0; i < 9; i += 2) {
      final (s, e) = chunkRange(i, t.sizeBytes);
      await half.write(i, bytes.sublist(s, e));
    }
    final (halfSrv, halfFs) = await serve(partial: (id) => PartialTrack.peek(halfDir, id));
    final evilFile = File('${tmp.path}/evil')..writeAsBytesSync(List.filled(t.sizeBytes, 9));
    final (evil, _) = await serve(file: (id) => id == t.id ? evilFile : null);

    final swarm = SwarmDownloader(log: log, haveRefresh: const Duration(milliseconds: 200));
    final out = await swarm.download(
      t,
      TrackCache(Directory('${tmp.path}/me')),
      host: TransferContext(
          baseUri: Uri.parse('http://127.0.0.1:${host.port}'), sessionId: 'sess', transferKey: hostKeys.transfer, coordinatorNowMs: now),
      peers: PeerContext(
        selfId: 'me',
        peerKey: room.peerKey(),
        coordinatorNowMs: now,
        peers: () => [
          PeerSource('full', Uri.parse('http://127.0.0.1:${full.port}')),
          PeerSource('half', Uri.parse('http://127.0.0.1:${halfSrv.port}')),
          PeerSource('evil', Uri.parse('http://127.0.0.1:${evil.port}')),
        ],
      ),
    );
    expect(sha256.convert(out.readAsBytesSync()).toString(), t.id);
    expect(swarm.stats.bytesFromPeers, greaterThan(0));
    expect(hostFs.bytesServed, lessThan(t.sizeBytes), reason: 'peers carried most of the load');
    expect(fullFs.bytesServed + halfFs.bytesServed, greaterThan(t.sizeBytes ~/ 2));
    expect(swarm.stats.badChunks, inInclusiveRange(1, 3),
        reason: 'the dishonest peer is dropped after 2 bad chunks (one more request may already be in flight)');
    expect(Directory('${tmp.path}/me').listSync().map((e) => e.path).where((p) => p.endsWith('.swarm') || p.endsWith('.have')), isEmpty);
    swarm.close();
  });

  test('swarm gives up cleanly when nobody has the chunks', () async {
    final (f, base, _) = makeTrack(kChunkSize * 2, seed: 4);
    final h = await chunkHashesOf(f);
    final t = base.copyWith(chunkRoot: chunkRootOf(h));
    final listDir = Directory('${tmp.path}/list');
    await PartialTrack.open(listDir, t.id, t.sizeBytes, h); // has the list, no chunks
    final (peer, _) = await serve(partial: (id) => PartialTrack.peek(listDir, id));
    final swarm = SwarmDownloader(log: log, haveRefresh: const Duration(milliseconds: 100), stallTimeout: const Duration(seconds: 1));
    await expectLater(
      swarm.download(t, TrackCache(Directory('${tmp.path}/me')),
          peers: PeerContext(
              selfId: 'me',
              peerKey: room.peerKey(),
              coordinatorNowMs: now,
              peers: () => [PeerSource('p', Uri.parse('http://127.0.0.1:${peer.port}'))])),
      throwsA(isA<TrackUnavailableException>().having((e) => e.code, 'code', 'swarm_stalled')),
    );
    swarm.close();
  });
}
