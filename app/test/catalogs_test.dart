// Free online catalogs (Openverse, Internet Archive, podcasts) against a
// local fake server and the redirect chain of real hosts (the browser UI is in
// catalog_browser_test.dart: widget tests replace HttpClient for the whole file).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncsphere/src/data/app_store.dart';
import 'package:syncsphere/src/services/archive_client.dart';
import 'package:syncsphere/src/services/catalogs.dart';
import 'package:syncsphere/src/services/library_service.dart';
import 'package:syncsphere/src/services/openverse_client.dart';
import 'package:syncsphere/src/services/podcast_client.dart';
import 'package:syncsphere/src/services/remote_source.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

String _feed(int port) => '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>Night Signals</title>
    <itunes:author>Mira Cole</itunes:author>
    <itunes:image href="https://img.example/show.jpg"/>
    <item>
      <title>Episode 3: Echoes</title>
      <pubDate>Tue, 14 Oct 2026 08:00:00 GMT</pubDate>
      <itunes:duration>1:02:03</itunes:duration>
      <enclosure url="http://127.0.0.1:$port/ep3.mp3" type="audio/mpeg" length="1000"/>
    </item>
    <item>
      <title>Trailer (video)</title>
      <enclosure url="http://127.0.0.1:$port/trailer.mp4" type="video/mp4"/>
    </item>
    <item><title>No file</title></item>
    <item>
      <title>Episode 2 &amp; friends</title>
      <itunes:duration>245</itunes:duration>
      <itunes:image href="https://img.example/ep2.jpg"/>
      <enclosure url="http://127.0.0.1:$port/ep2.mp3" type="audio/mpeg"/>
    </item>
  </channel>
</rss>''';

void main() {
  late HttpServer server;
  late Directory tmp;
  final requests = <Uri>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('syncsphere_catalogs');
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req.uri);
      final res = req.response;
      final path = req.uri.path;
      if (path.startsWith('/r/')) {
        final n = int.parse(path.substring(3));
        res.redirect(Uri.parse('http://127.0.0.1:${server.port}${n <= 1 ? '/song.mp3' : '/r/${n - 1}'}'));
        return;
      }
      switch (path) {
        case '/v1/audio/':
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'result_count': 3,
            'results': [
              {
                'id': 'a1',
                'title': 'Sunrise Theme',
                'creator': 'Lumen',
                'url': 'https://cdn.example/sunrise.mp3',
                'license': 'by-sa',
                'license_version': '3.0',
                'license_url': 'https://creativecommons.org/licenses/by-sa/3.0/',
                'source': 'jamendo',
                'category': 'music',
                'duration': 183000,
                'thumbnail': 'https://api.example/thumb/a1',
                'genres': ['ambient'],
              },
              {'id': 'a2', 'title': 'No file', 'creator': 'X'},
              {'id': 'a3', 'title': 'Door slam', 'url': 'https://cdn.example/door.wav', 'category': 'sound_effect'},
            ],
          }));
        case '/advancedsearch.php':
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'response': {
              'docs': [
                {'identifier': 'gd1977-05-08', 'title': 'Grateful Dead Live at Barton Hall', 'creator': ['Grateful Dead'], 'year': '1977'},
                {'title': 'missing id'},
              ]
            }
          }));
        case '/metadata/gd1977-05-08':
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'metadata': {'title': 'Barton Hall', 'creator': 'Grateful Dead'},
            'files': [
              {'name': 'gd77-05-08d1t02.flac', 'source': 'original', 'track': '2', 'title': 'Jack Straw', 'length': '05:11'},
              {'name': 'gd77-05-08d1t02.mp3', 'source': 'derivative', 'track': '2', 'title': 'Jack Straw', 'length': '311.2'},
              {'name': 'gd77-05-08d1t01.ogg', 'source': 'derivative', 'track': '1', 'title': 'Minglewood Blues'},
              {'name': 'disc 2/Scarlet Begonias.mp3', 'track': '3/10'},
              {'name': 'gd77-05-08_sample.mp3'},
              {'name': 'gd77-05-08_meta.xml'},
            ],
          }));
        case '/search':
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'resultCount': 2,
            'results': [
              {
                'collectionName': 'Night Signals',
                'artistName': 'Mira Cole',
                'feedUrl': 'http://127.0.0.1:${server.port}/feed.xml',
                'artworkUrl600': 'https://img.example/600.jpg',
              },
              {'collectionName': 'No feed'},
            ],
          }));
        case '/feed.xml':
          res.headers.contentType = ContentType('application', 'rss+xml');
          res.write(_feed(server.port));
        case '/song.mp3':
          res.headers.contentType = ContentType('audio', 'mpeg');
          res.add(List<int>.generate(20000, (i) => i % 251));
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

  Uri local([String path = '']) => Uri.parse('http://127.0.0.1:${server.port}$path');

  test('Openverse: music with a file only; the licence becomes the credit', () async {
    final c = OpenverseClient(base: local('/v1'));
    final r = await c.search('sunrise');
    expect(r.groups, isEmpty);
    final t = r.tracks.single;
    expect(t.title, 'Sunrise Theme');
    expect(t.artist, 'Lumen');
    expect(t.url, 'https://cdn.example/sunrise.mp3');
    expect(t.duration, const Duration(seconds: 183));
    expect(t.credit, 'CC BY-SA 3.0 · via Openverse (jamendo)');
    expect(t.infoUrl, 'https://creativecommons.org/licenses/by-sa/3.0/');
    expect(requests.last.queryParameters, containsPair('category', 'music'));
    expect((await c.search('  ')).isEmpty, isTrue);
    c.close();
  });

  test('Internet Archive: items, then one file per song (MP3 preferred) in track order', () async {
    final c = ArchiveClient(base: local());
    final r = await c.search('grateful dead');
    final item = r.groups.single;
    expect(item.title, 'Grateful Dead Live at Barton Hall');
    expect(item.subtitle, 'Grateful Dead · 1977');
    expect(requests.last.queryParameters['q'], '(grateful dead) AND mediatype:(audio)');
    expect(requests.last.queryParametersAll['fl[]'], containsAll(['identifier', 'title']));

    final tracks = await c.open(item);
    expect(tracks.map((t) => t.title), ['Minglewood Blues', 'Jack Straw', 'Scarlet Begonias']);
    expect(tracks[1].url, local('/download/gd1977-05-08/gd77-05-08d1t02.mp3').toString());
    expect(tracks[1].duration, const Duration(milliseconds: 311200));
    expect(tracks[2].url, local('/download/gd1977-05-08/disc%202/Scarlet%20Begonias.mp3').toString());
    expect(tracks.first.artist, 'Grateful Dead');
    expect(tracks.first.credit, 'via Internet Archive');
    c.close();
  });

  test('Podcasts: iTunes finds the show, the RSS feed lists audio episodes', () async {
    final c = PodcastClient(searchBase: local());
    final r = await c.search('night signals');
    final show = r.groups.single;
    expect(show.title, 'Night Signals');
    expect(requests.last.queryParameters, containsPair('media', 'podcast'));

    final eps = await c.open(show);
    expect(eps.map((e) => e.title), ['Episode 3: Echoes', 'Episode 2 & friends']);
    expect(eps.first.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(eps.first.detail, '14 Oct 2026');
    expect(eps.first.artUrl, 'https://img.example/show.jpg');
    expect(eps.first.artist, 'Mira Cole');
    expect(eps.first.credit, 'Night Signals');
    expect(eps.last.duration, const Duration(seconds: 245));
    expect(eps.last.artUrl, 'https://img.example/ep2.jpg');
    expect(() => PodcastClient.parseFeed('<not xml', show: show), throwsA(isA<CatalogException>()));
    c.close();
  });

  test('clock parsing and unreachable catalogs', () async {
    expect(parseClock('04:05'), const Duration(minutes: 4, seconds: 5));
    expect(parseClock('1:00:00'), const Duration(hours: 1));
    expect(parseClock('abc'), isNull);
    expect(parseClock(0), isNull);
    final dead = OpenverseClient(base: Uri.parse('http://127.0.0.1:1/v1'));
    await expectLater(dead.search('x'), throwsA(isA<CatalogException>()));
    dead.close();
  });

  test('downloads follow long redirect chains (archive.org, podcast CDNs)', () async {
    final store = MemoryAppStore();
    final lib = LibraryService(store: store, libraryDir: Directory('${tmp.path}/lib'), log: EventLog(clock: SystemMonotonicClock.instance));
    final remote = RemoteSource(library: lib);
    final t = await remote.fetchToLibrary(local('/r/7').toString(), title: 'Deep link', credit: 'via Internet Archive');
    expect(t.title, 'Deep link');
    expect(t.sizeBytes, 20000);
    remote.close();
  });
}
