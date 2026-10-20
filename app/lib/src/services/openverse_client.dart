import 'dart:io';

import 'catalogs.dart';

/// Openverse (run by WordPress): one search over openly licensed audio from
/// Jamendo, Wikimedia Commons and others. No key needed. Every result keeps
/// its Creative Commons licence, shown as the song's credit.
class OpenverseClient implements MusicCatalog {
  final Uri base;
  final CatalogHttp _http;

  OpenverseClient({Uri? base, HttpClient? client})
      : base = base ?? Uri.parse('https://api.openverse.org/v1'),
        _http = CatalogHttp('Openverse', client: client);

  @override
  String get name => 'Openverse';
  @override
  String get hint => 'Song, artist or genre';
  @override
  String get about => 'Creative Commons music from Jamendo, Wikimedia and more';

  @override
  Future<CatalogResults> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const CatalogResults();
    final body = await _http.getJson(base.replace(
      path: '${base.path}/audio/',
      queryParameters: {'q': q, 'category': 'music', 'page_size': '40'},
    ));
    final results = body is Map ? body['results'] : null;
    if (results is! List) return const CatalogResults();
    final out = <CatalogTrack>[];
    for (final r in results) {
      if (r is! Map) continue;
      final url = r['url'], title = r['title'];
      if (!isWebLink(url) || title is! String || title.trim().isEmpty) continue;
      final category = r['category'];
      if (category is String && category != 'music') continue;
      final license = r['license'], version = r['license_version'];
      final source = firstString(r['source']) ?? firstString(r['provider']);
      final licence = license is String && license.isNotEmpty
          ? (license == 'pdm' || license == 'cc0'
              ? license.toUpperCase()
              : 'CC ${license.toUpperCase()}${version is String && version.isNotEmpty ? ' $version' : ''}')
          : null;
      final dur = r['duration'];
      out.add(CatalogTrack(
        url: url as String,
        title: title.trim(),
        artist: firstString(r['creator']) ?? 'Unknown artist',
        duration: dur is num && dur > 0 ? Duration(milliseconds: dur.round()) : null,
        artUrl: isWebLink(r['thumbnail']) ? r['thumbnail'] as String : null,
        credit: [if (licence != null) licence, 'via Openverse${source == null ? '' : ' ($source)'}'].join(' · '),
        infoUrl: isWebLink(r['license_url']) ? r['license_url'] as String : null,
        detail: firstString(r['genres']),
      ));
    }
    return CatalogResults(tracks: out);
  }

  @override
  Future<List<CatalogTrack>> open(CatalogGroup group) async => const [];

  @override
  void close() => _http.close();
}
