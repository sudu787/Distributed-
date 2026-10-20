import 'dart:convert';
import 'dart:io';

/// A song or episode from an online catalog, as a direct link to the file.
/// Added with `RemoteSource.fetchToLibrary`, so in a party every phone
/// downloads it from [url] (the host is only a fallback).
class CatalogTrack {
  final String url;
  final String title;
  final String artist;
  final Duration? duration;
  final String? artUrl;

  /// Shown with the song (e.g. "via Internet Archive", a CC licence).
  final String credit;

  /// Licence or source page, if any.
  final String? infoUrl;

  /// Extra line in lists (album, date).
  final String? detail;

  const CatalogTrack({
    required this.url,
    required this.title,
    required this.artist,
    required this.credit,
    this.duration,
    this.artUrl,
    this.infoUrl,
    this.detail,
  });
}

/// A collection that holds tracks: an Internet Archive item or a podcast.
class CatalogGroup {
  final String id;
  final String title;
  final String? subtitle;
  final String? artUrl;
  const CatalogGroup({required this.id, required this.title, this.subtitle, this.artUrl});
}

class CatalogException implements Exception {
  final String message;
  const CatalogException(this.message);
  @override
  String toString() => message;
}

/// What one search returns: tracks directly, or groups to open.
class CatalogResults {
  final List<CatalogTrack> tracks;
  final List<CatalogGroup> groups;
  const CatalogResults({this.tracks = const [], this.groups = const []});
  bool get isEmpty => tracks.isEmpty && groups.isEmpty;
}

/// An online source of free music (see docs/research-next.md, "More music
/// sources").
abstract class MusicCatalog {
  /// "Internet Archive", "Podcasts", ...
  String get name;

  /// Placeholder of the search field.
  String get hint;

  /// One-line description for menus and the empty search screen.
  String get about;

  Future<CatalogResults> search(String query);

  /// Tracks of a group from [search].
  Future<List<CatalogTrack>> open(CatalogGroup group);

  void close();
}

/// Small HTTP helper shared by the catalog clients (dart:io, like the rest of
/// the app; tests point [CatalogHttp] at a local server).
class CatalogHttp {
  final String source;
  final HttpClient _http;
  CatalogHttp(this.source, {HttpClient? client}) : _http = client ?? HttpClient() {
    _http
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'SyncSphere (+https://github.com/sudu787/Distributed-)';
  }

  Future<String> getText(Uri uri, {String accept = '*/*', int maxBytes = 8 * 1024 * 1024}) async {
    try {
      final req = await _http.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, accept);
      req.maxRedirects = 10;
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw CatalogException('$source answered HTTP ${res.statusCode}.');
      }
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) throw CatalogException('$source sent too much data.');
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on CatalogException {
      rethrow;
    } on SocketException {
      throw CatalogException('No internet connection. $source needs internet on the phone that adds songs.');
    } catch (e) {
      throw CatalogException('$source failed: $e');
    }
  }

  Future<Object?> getJson(Uri uri) async {
    final text = await getText(uri, accept: 'application/json');
    try {
      return jsonDecode(text);
    } on FormatException {
      throw CatalogException('$source sent an unreadable answer.');
    }
  }

  void close() => _http.close(force: true);
}

/// "245.3", "4:05" or "1:02:03" → duration (null when unreadable).
Duration? parseClock(Object? v) {
  if (v is num) return v > 0 ? Duration(milliseconds: (v * 1000).round()) : null;
  if (v is! String || v.trim().isEmpty) return null;
  final s = v.trim();
  if (!s.contains(':')) {
    final secs = double.tryParse(s);
    return secs == null || secs <= 0 ? null : Duration(milliseconds: (secs * 1000).round());
  }
  var total = 0.0;
  for (final part in s.split(':')) {
    final n = double.tryParse(part);
    if (n == null) return null;
    total = total * 60 + n;
  }
  return total <= 0 ? null : Duration(milliseconds: (total * 1000).round());
}

/// First string of a value that may be a string or a list of strings.
String? firstString(Object? v) {
  if (v is String && v.trim().isNotEmpty) return v.trim();
  if (v is List) {
    for (final e in v) {
      if (e is String && e.trim().isNotEmpty) return e.trim();
    }
  }
  return null;
}

/// Only http(s) links are followed.
bool isWebLink(Object? v) => v is String && (v.startsWith('https://') || v.startsWith('http://'));
