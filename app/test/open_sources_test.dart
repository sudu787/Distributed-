// Open music sources: Audius client, link import, and a party where every
// phone downloads a linked song from its source instead of the host.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncsphere/src/data/app_store.dart';
import 'package:syncsphere/src/services/audius_client.dart';
import 'package:syncsphere/src/services/library_service.dart';
import 'package:syncsphere/src/services/remote_source.dart';
import 'package:syncsphere/src/services/room_service.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late List<int> song;
  var songHits = 0;
  final requests = <Uri>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('syncsphere_sources');
    final rnd = Random(11);
    song = List<int>.generate(150 * 1024, (_) => rnd.nextInt(256));
    songHits = 0;
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req.uri);
      final res = req.response;
      switch (req.uri.path) {
        case '/v1/tracks/search':
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'data': [
              {
                'id': 'D7KyD',
                'title': 'Blue Hour',
                'duration': 215,
                'is_streamable': true,
                'user': {'name': 'Nova'},
                'artwork': {'150x150': 'https://img.example/150.jpg', '480x480': 'https://img.example/480.jpg'},
              },
              {'id': 'Gated', 'title': 'Premium only', 'is_streamable': false, 'user': {'name': 'X'}},
              {'title': 'no id'},
            ]
          }));
        case '/v1/tracks/D7KyD/stream':
          res.redirect(Uri.parse('http://127.0.0.1:${server.port}/node/blue-hour.mp3'));
          return;
        case '/node/blue-hour.mp3':
          songHits++;
          res.headers.contentType = ContentType('audio', 'mpeg');
          res.add(song);
        case '/page':
          res.headers.contentType = ContentType.html;
          res.write('<html>not audio</html>');
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  AudiusClient audius() => AudiusClient(base: Uri.parse('http://127.0.0.1:${server.port}/v1'));
  LibraryService lib(MemoryAppStore store, String name) =>
      LibraryService(store: store, libraryDir: Directory('${tmp.path}/$name'), log: EventLog(clock: SystemMonotonicClock.instance));

  test('Audius search keeps streamable tracks and builds a stable stream URL', () async {
    final a = audius();
    final r = await a.search('blue');
    expect(r.map((t) => t.title), ['Blue Hour']);
    expect(r.single.artist, 'Nova');
    expect(r.single.duration, const Duration(seconds: 215));
    expect(r.single.artUrl, 'https://img.example/480.jpg');
    expect(requests.last.queryParameters, containsPair('app_name', 'SyncSphere'));
    expect(requests.last.queryParameters, containsPair('query', 'blue'));
    expect(a.streamUrl('D7KyD'), 'http://127.0.0.1:${server.port}/v1/tracks/D7KyD/stream?app_name=SyncSphere');
    expect(await a.search('   '), isEmpty);
    a.close();
  });

  test('links are imported with their source; web pages and bad links are refused', () async {
    final store = MemoryAppStore();
    final remote = RemoteSource(library: lib(store, 'lib'));
    final a = audius();
    final progress = <int>[];
    final t = await remote.fetchToLibrary(a.streamUrl('D7KyD'),
        title: 'Blue Hour', artist: 'Nova', artUrl: 'https://img.example/480.jpg', credit: 'via Audius',
        onProgress: (got, _) => progress.add(got));
    expect(t.id, await sha256OfFile(File('${tmp.path}/song.bin')..writeAsBytesSync(song)));
    expect(t.title, 'Blue Hour');
    expect(t.sourceUrl, a.streamUrl('D7KyD'));
    expect(t.toTrackInfo().credit, 'via Audius');
    expect(progress.last, song.length);
    expect((await store.libraryTracks()).single.artUrl, 'https://img.example/480.jpg');
    expect(Directory('${tmp.path}/lib').listSync().where((e) => e.path.contains('.incoming')), isEmpty);

    await expectLater(remote.fetchToLibrary('http://127.0.0.1:${server.port}/page'),
        throwsA(isA<RemoteSourceException>().having((e) => e.message, 'message', contains('web page'))));
    await expectLater(remote.fetchToLibrary('http://127.0.0.1:${server.port}/missing.mp3'),
        throwsA(isA<RemoteSourceException>().having((e) => e.message, 'message', contains('404'))));
    await expectLater(remote.fetchToLibrary('file:///etc/passwd'), throwsA(isA<RemoteSourceException>()));
    remote.close();
    a.close();
  });

  test('in a party every phone downloads a linked song from its source, not from the host', () async {
    final clock = SystemMonotonicClock.instance;
    Future<RoomKey> fastKdf(String r, String k, int i) async => RoomKey.derive(roomId: r, joinKey: k, iterations: i);
    RoomService svc(MemoryAppStore store, String name) => RoomService(
          store: store,
          cacheDir: Directory('${tmp.path}/cache-$name'),
          backendFactory: (log) async => NullAudioBackend(clock.nowMicros),
          keyDeriver: fastKdf,
          kdfIterations: 50,
          watchForNewerCoordinator: false,
        );
    final hostStore = MemoryAppStore();
    final remote = RemoteSource(library: lib(hostStore, 'hostlib'));
    final a = audius();
    final t = await remote.fetchToLibrary(a.streamUrl('D7KyD'), title: 'Blue Hour', artist: 'Nova', credit: 'via Audius');
    expect(songHits, 1);
    final host = svc(hostStore, 'host');
    final info = await host.host(
        identity: await hostStore.loadIdentity(defaultName: 'Host'), roomName: 'Open', tracks: [t], port: 0, openControl: true);
    expect(host.coordinator!.state.playlist.single.sourceUrl, a.streamUrl('D7KyD'));
    final guestStore = MemoryAppStore();
    final guest = svc(guestStore, 'guest');
    await guest.join(
        identity: await guestStore.loadIdentity(defaultName: 'Guest'), host: '127.0.0.1', port: info.port, joinKey: info.joinKey!);
    expect((await guest.session!.control(ControlAction.play)).accepted, isTrue);
    final file = File('${tmp.path}/cache-guest/tracks/${t.id}.audio');
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!file.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(file.existsSync(), isTrue);
    expect(songHits, 2, reason: 'the guest fetched it from the source');
    expect(guest.log.recent(limit: 300, categoryPrefix: 'transfer.source').map((e) => e.message).join('\n'),
        contains('from its source'));
    await guest.leave();
    await host.leave();
    remote.close();
    a.close();
  });
}
