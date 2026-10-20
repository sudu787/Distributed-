import 'dart:io';

import 'package:xml/xml.dart';

import 'catalogs.dart';

/// Podcasts: shows are found with the free iTunes Search API, episodes come
/// from the show's own RSS feed, and every phone downloads the episode from
/// the podcast's server.
class PodcastClient implements MusicCatalog {
  final Uri searchBase;
  final CatalogHttp _http;

  PodcastClient({Uri? searchBase, HttpClient? client})
      : searchBase = searchBase ?? Uri.parse('https://itunes.apple.com'),
        _http = CatalogHttp('Podcast search', client: client);

  @override
  String get name => 'Podcasts';
  @override
  String get hint => 'Podcast name or topic';
  @override
  String get about => 'Any podcast, listened to together';

  @override
  Future<CatalogResults> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const CatalogResults();
    final body = await _http.getJson(searchBase.replace(
      path: '${searchBase.path}/search',
      queryParameters: {'media': 'podcast', 'entity': 'podcast', 'term': q, 'limit': '25'},
    ));
    final results = body is Map ? body['results'] : null;
    if (results is! List) return const CatalogResults();
    return CatalogResults(groups: [
      for (final r in results)
        if (r is Map && isWebLink(r['feedUrl']))
          CatalogGroup(
            id: r['feedUrl'] as String,
            title: firstString(r['collectionName']) ?? 'Podcast',
            subtitle: firstString(r['artistName']),
            artUrl: isWebLink(r['artworkUrl600'])
                ? r['artworkUrl600'] as String
                : (isWebLink(r['artworkUrl100']) ? r['artworkUrl100'] as String : null),
          ),
    ]);
  }

  /// Episodes of the show whose feed URL is [group.id], newest first as the
  /// feed lists them (at most 200).
  @override
  Future<List<CatalogTrack>> open(CatalogGroup group) async {
    final text = await _http.getText(Uri.parse(group.id), accept: 'application/rss+xml, application/xml, text/xml');
    return parseFeed(text, show: group);
  }

  /// Parses an RSS 2.0 podcast feed (enclosures, itunes:duration, artwork).
  static List<CatalogTrack> parseFeed(String xml, {required CatalogGroup show}) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException {
      throw const CatalogException('That podcast feed could not be read.');
    }
    final channel = doc.findAllElements('channel').firstOrNull;
    if (channel == null) return const [];
    String? text(XmlElement e, String name) {
      final v = e.findElements(name).firstOrNull?.innerText.trim();
      return v == null || v.isEmpty ? null : v;
    }

    String? image(XmlElement e) {
      final href = e.findElements('itunes:image').firstOrNull?.getAttribute('href');
      if (isWebLink(href)) return href;
      final url = e.findElements('image').firstOrNull?.findElements('url').firstOrNull?.innerText.trim();
      return isWebLink(url) ? url : null;
    }

    final showTitle = text(channel, 'title') ?? show.title;
    final showArt = image(channel) ?? show.artUrl;
    final showAuthor = text(channel, 'itunes:author') ?? show.subtitle ?? showTitle;
    final out = <CatalogTrack>[];
    for (final item in channel.findElements('item')) {
      final enc = item.findElements('enclosure').firstOrNull;
      final url = enc?.getAttribute('url');
      final type = enc?.getAttribute('type') ?? '';
      if (!isWebLink(url) || (type.isNotEmpty && !type.startsWith('audio/'))) continue;
      out.add(CatalogTrack(
        url: url!,
        title: text(item, 'title') ?? 'Episode',
        artist: showAuthor,
        duration: parseClock(text(item, 'itunes:duration')),
        artUrl: image(item) ?? showArt,
        credit: showTitle,
        infoUrl: text(item, 'link'),
        detail: _date(text(item, 'pubDate')),
      ));
      if (out.length >= 200) break;
    }
    return out;
  }

  /// "Tue, 14 Oct 2026 08:00:00 GMT" → "14 Oct 2026".
  static String? _date(String? rfc822) {
    if (rfc822 == null) return null;
    final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4})').firstMatch(rfc822);
    return m == null ? null : '${m[1]} ${m[2]} ${m[3]}';
  }

  @override
  void close() => _http.close();
}
