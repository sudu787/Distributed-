import 'dart:convert';
import 'dart:io';

/// One streamable song from the Audius catalog.
class AudiusTrack {
  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String? artUrl;
  const AudiusTrack({required this.id, required this.title, required this.artist, this.duration, this.artUrl});
}

class AudiusException implements Exception {
  final String message;
  const AudiusException(this.message);
  @override
  String toString() => message;
}

/// Minimal client for the public Audius REST API (free; artists must be
/// credited). Search returns streamable tracks; [streamUrl] is the stable
/// URL every phone downloads the song from.
class AudiusClient {
  static const appName = 'SyncSphere';
  final Uri base;
  final String? apiKey;
  final HttpClient _http;

  AudiusClient({Uri? base, this.apiKey, HttpClient? client})
      : base = base ?? Uri.parse('https://api.audius.co/v1'),
        _http = client ?? HttpClient() {
    _http
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = appName;
  }

  Uri _endpoint(String path, [Map<String, String> query = const {}]) => base.replace(
        path: '${base.path}$path',
        queryParameters: {...query, 'app_name': appName},
      );

  /// Stable stream URL (redirects to a content node) for [trackId].
  String streamUrl(String trackId) => _endpoint('/tracks/${Uri.encodeComponent(trackId)}/stream').toString();

  Future<List<AudiusTrack>> search(String query, {int limit = 25}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final Object? body;
    try {
      final req = await _http.getUrl(_endpoint('/tracks/search', {'query': q, 'limit': '$limit'}));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (apiKey != null) req.headers.set('x-api-key', apiKey!);
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != HttpStatus.ok) throw AudiusException('Audius search failed (HTTP ${res.statusCode}).');
      body = jsonDecode(text);
    } on AudiusException {
      rethrow;
    } on SocketException {
      throw const AudiusException('No internet connection. Audius needs internet on the phone that adds songs.');
    } catch (e) {
      throw AudiusException('Audius search failed: $e');
    }
    final data = body is Map ? body['data'] : null;
    if (data is! List) return const [];
    final out = <AudiusTrack>[];
    for (final t in data) {
      if (t is! Map) continue;
      if (t['is_streamable'] == false) continue;
      final id = t['id'], title = t['title'];
      if (id is! String || title is! String || id.isEmpty) continue;
      final user = t['user'];
      final artist = user is Map && user['name'] is String ? user['name'] as String : 'Unknown artist';
      final dur = t['duration'];
      final art = t['artwork'];
      String? artUrl;
      if (art is Map) {
        final a = art['480x480'] ?? art['150x150'] ?? art['1000x1000'];
        if (a is String && a.startsWith('https://')) artUrl = a;
      }
      out.add(AudiusTrack(
        id: id,
        title: title,
        artist: artist,
        duration: dur is num ? Duration(seconds: dur.round()) : null,
        artUrl: artUrl,
      ));
    }
    return out;
  }

  void close() => _http.close(force: true);
}
