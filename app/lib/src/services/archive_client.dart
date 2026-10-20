import 'dart:io';

import 'catalogs.dart';

/// Internet Archive (archive.org): free audio collections, live concerts,
/// old-time radio and public-domain recordings. Search returns items; an
/// item's audio files are streamed from archive.org by every phone.
class ArchiveClient implements MusicCatalog {
  final Uri base;
  final CatalogHttp _http;

  ArchiveClient({Uri? base, HttpClient? client})
      : base = base ?? Uri.parse('https://archive.org'),
        _http = CatalogHttp('Internet Archive', client: client);

  static const _audioExt = ['.mp3', '.ogg', '.m4a', '.flac'];

  @override
  String get name => 'Internet Archive';
  @override
  String get hint => 'Artist, album or collection';
  @override
  String get about => 'Free concerts, albums and old recordings';

  Uri _u(String path, [Map<String, Object>? query]) =>
      base.replace(path: '${base.path}$path', queryParameters: query);

  @override
  Future<CatalogResults> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const CatalogResults();
    final body = await _http.getJson(_u('/advancedsearch.php', {
      'q': '($q) AND mediatype:(audio)',
      'fl[]': ['identifier', 'title', 'creator', 'year'],
      'rows': '50',
      'page': '1',
      'output': 'json',
    }));
    final docs = body is Map && body['response'] is Map ? (body['response'] as Map)['docs'] : null;
    if (docs is! List) return const CatalogResults();
    final groups = <CatalogGroup>[];
    for (final d in docs) {
      if (d is! Map) continue;
      final id = d['identifier'];
      if (id is! String || id.isEmpty) continue;
      final creator = firstString(d['creator']);
      final year = d['year'];
      groups.add(CatalogGroup(
        id: id,
        title: firstString(d['title']) ?? id,
        subtitle: [if (creator != null) creator, if (year != null) '$year'].join(' · '),
        artUrl: _u('/services/img/${Uri.encodeComponent(id)}').toString(),
      ));
    }
    return CatalogResults(groups: groups);
  }

  /// Audio files of an item, one per song: MP3 preferred (smaller, plays
  /// everywhere), then Ogg, M4A, FLAC; in track order.
  @override
  Future<List<CatalogTrack>> open(CatalogGroup group) async {
    final body = await _http.getJson(_u('/metadata/${Uri.encodeComponent(group.id)}'));
    if (body is! Map) return const [];
    final files = body['files'];
    if (files is! List) return const [];
    final meta = body['metadata'] is Map ? body['metadata'] as Map : const {};
    final itemCreator = firstString(meta['creator']);
    final best = <String, Map<Object?, Object?>>{};
    int rank(String name) => _audioExt.indexWhere((e) => name.toLowerCase().endsWith(e));
    for (final f in files) {
      if (f is! Map<Object?, Object?>) continue;
      final name = f['name'];
      if (name is! String || rank(name) < 0) continue;
      if (name.toLowerCase().contains('_sample')) continue;
      final stem = name.substring(0, name.lastIndexOf('.'));
      final cur = best[stem];
      if (cur == null || rank(name) < rank(cur['name'] as String)) best[stem] = f;
    }
    int trackNo(Map<Object?, Object?> f) => int.tryParse('${f['track'] ?? ''}'.split('/').first) ?? 1 << 20;
    final picked = best.values.toList()
      ..sort((a, b) {
        final c = trackNo(a).compareTo(trackNo(b));
        return c != 0 ? c : (a['name'] as String).compareTo(b['name'] as String);
      });
    return [
      for (final f in picked.take(200))
        CatalogTrack(
          url: _u('/download/${Uri.encodeComponent(group.id)}/'
                  '${(f['name'] as String).split('/').map(Uri.encodeComponent).join('/')}')
              .toString(),
          title: firstString(f['title']) ?? _stemTitle(f['name'] as String),
          artist: firstString(f['creator']) ?? firstString(f['artist']) ?? itemCreator ?? 'Unknown artist',
          duration: parseClock(f['length']),
          artUrl: group.artUrl,
          credit: 'via Internet Archive',
          infoUrl: _u('/details/${Uri.encodeComponent(group.id)}').toString(),
          detail: firstString(f['album']) ?? group.title,
        ),
    ];
  }

  static String _stemTitle(String name) {
    final base = name.split('/').last;
    final stem = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
    return stem.replaceAll('_', ' ');
  }

  @override
  void close() => _http.close();
}
