/// Songs with a public source URL (open catalogs, own music servers): every
/// device downloads from the source first and falls back to the host.
@Timeout(Duration(minutes: 1))
library;

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late HttpServer source, host;
  late TrackFileServer files;
  late List<int> bytes;
  late String id;
  var sourceBody = <int>[];
  var sourceHits = 0;
  final log = EventLog(clock: SystemMonotonicClock.instance);
  final keys = RoomKey.derive(roomId: 'r', joinKey: 'K', iterations: 1).sessionKeys('dev-1', 'cn', 'sn');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('syncsphere_src');
    final rnd = Random(5);
    bytes = List<int>.generate(300000, (_) => rnd.nextInt(256));
    id = sha256.convert(bytes).toString();
    sourceBody = bytes;
    sourceHits = 0;
    final hosted = File('${tmp.path}/hosted')..writeAsBytesSync(bytes);
    source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source.listen((req) async {
      if (req.uri.path == '/stream') {
        // Catalog-style stable URL redirecting to a content node.
        await req.response.redirect(Uri.parse('http://127.0.0.1:${source.port}/node/song.mp3'));
        return;
      }
      if (req.uri.path == '/node/song.mp3') {
        sourceHits++;
        req.response.headers.contentType = ContentType('audio', 'mpeg');
        req.response.add(sourceBody);
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    files = TrackFileServer(
      fileForTrack: (t) => t == id ? hosted : null,
      keysForSession: (s) => s == 'sess' ? keys : null,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      log: log,
    );
    host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host.listen(files.handle);
  });
  tearDown(() async {
    await source.close(force: true);
    await host.close(force: true);
    await tmp.delete(recursive: true);
  });

  TrackInfo track(String path, {bool serves = true}) => TrackInfo(
      id: id, title: 'Song', sizeBytes: bytes.length, hostServes: serves, sourceUrl: 'http://127.0.0.1:${source.port}$path');
  TransferContext ctx() => TransferContext(
      baseUri: Uri.parse('http://127.0.0.1:${host.port}'),
      sessionId: 'sess',
      transferKey: keys.transfer,
      coordinatorNowMs: () => DateTime.now().millisecondsSinceEpoch);

  test('downloads from the source (following redirects); the host is not used', () async {
    final d = TrackDownloader(log: log);
    final out = await d.download(track('/stream'), ctx(), TrackCache(Directory('${tmp.path}/c')));
    expect(sha256.convert(out.readAsBytesSync()).toString(), id);
    expect(sourceHits, 1);
    expect(files.bytesServed, 0);
    expect(d.bytesFromSources, bytes.length);
    d.close();
  });

  test('works without a host connection when the source is reachable', () async {
    final d = TrackDownloader(log: log);
    final out = await d.download(track('/stream', serves: false), null, TrackCache(Directory('${tmp.path}/c')));
    expect(out.lengthSync(), bytes.length);
    d.close();
  });

  test('falls back to the host when the source is missing or returns other content', () async {
    final d = TrackDownloader(log: log);
    final out = await d.download(track('/gone'), ctx(), TrackCache(Directory('${tmp.path}/c1')));
    expect(sha256.convert(out.readAsBytesSync()).toString(), id);
    expect(files.bytesServed, bytes.length);

    sourceBody = List<int>.filled(bytes.length, 7); // the catalog changed the file
    final out2 = await d.download(track('/stream'), ctx(), TrackCache(Directory('${tmp.path}/c2')));
    expect(sha256.convert(out2.readAsBytesSync()).toString(), id);
    expect(files.bytesServed, 2 * bytes.length);
    d.close();
  });

  test('no source and no host: a clear error', () async {
    final d = TrackDownloader(log: log);
    await expectLater(d.download(track('/gone', serves: false), null, TrackCache(Directory('${tmp.path}/c'))),
        throwsA(isA<TrackUnavailableException>().having((e) => e.code, 'code', 'missing_track')));
    d.close();
  });

  test('TrackInfo carries source, cover and credit; only http(s) URLs are accepted', () {
    final t = TrackInfo(
        id: 'a' * 64,
        title: 'X',
        sizeBytes: 1,
        sourceUrl: 'https://api.audius.co/v1/tracks/abc/stream?app_name=SyncSphere',
        artUrl: 'https://img.example/480.jpg',
        credit: 'via Audius');
    final back = TrackInfo.fromJson(t.toJson());
    expect(back.sourceUrl, t.sourceUrl);
    expect(back.artUrl, t.artUrl);
    expect(back.credit, 'via Audius');
    expect(back.copyWith(availableCount: 2).sourceUrl, t.sourceUrl);
    for (final bad in ['file:///etc/passwd', 'content://x/y', 'javascript:alert(1)', 'http://']) {
      expect(() => TrackInfo.fromJson({...t.toJson(), 'src': bad}), throwsA(anything), reason: bad);
    }
  });
}
