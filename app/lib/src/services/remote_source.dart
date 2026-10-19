import 'dart:io';
import 'dart:math';

import 'package:syncsphere_core/syncsphere_core.dart' show TrackInfo;

import '../data/models.dart';
import 'library_service.dart';

class RemoteSourceException implements Exception {
  final String message;
  const RemoteSourceException(this.message);
  @override
  String toString() => message;
}

/// Adds songs from the internet (an open catalog such as Audius, a podcast
/// file, or a direct link to your own Navidrome/Jellyfin server) to My
/// music. The song keeps its [sourceUrl], so in a party every phone
/// downloads it from there and the host is only a fallback.
class RemoteSource {
  final LibraryService library;
  final int maxBytes;
  final HttpClient _http;

  RemoteSource({required this.library, this.maxBytes = 512 * 1024 * 1024, HttpClient? client})
      : _http = client ?? HttpClient() {
    _http
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'SyncSphere';
  }

  Future<LibraryTrack> fetchToLibrary(
    String url, {
    String? title,
    String? artist,
    String? artUrl,
    String? credit,
    void Function(int received, int? total)? onProgress,
  }) async {
    final link = url.trim();
    if (!TrackInfo.isWebUrl(link)) {
      throw const RemoteSourceException('Paste a full http:// or https:// link to an audio file.');
    }
    final uri = Uri.parse(link);
    await library.libraryDir.create(recursive: true);
    final name = uri.pathSegments.isEmpty ? 'song' : uri.pathSegments.last;
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')).toLowerCase() : '';
    final tmp = File('${library.libraryDir.path}/.incoming-${Random().nextInt(1 << 32)}${ext.length <= 6 ? ext : ''}');
    try {
      final HttpClientResponse res;
      try {
        final req = await _http.getUrl(uri);
        res = await req.close().timeout(const Duration(seconds: 20));
      } on SocketException {
        throw const RemoteSourceException('Could not reach that address. Check the link and the internet connection.');
      }
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw RemoteSourceException('The server answered HTTP ${res.statusCode}.');
      }
      final type = res.headers.contentType;
      if (type != null && (type.mimeType == 'text/html' || type.mimeType == 'application/json')) {
        await res.drain<void>();
        throw const RemoteSourceException('That link opens a web page, not an audio file. Use a direct link to the file.');
      }
      final total = res.contentLength >= 0 ? res.contentLength : null;
      if (total != null && total > maxBytes) {
        await res.drain<void>();
        throw const RemoteSourceException('That file is larger than 512 MB.');
      }
      var received = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 30))) {
          received += chunk.length;
          if (received > maxBytes) throw const RemoteSourceException('That file is larger than 512 MB.');
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      if (received == 0) throw const RemoteSourceException('The link returned an empty file.');
      return await library.import(
        tmp,
        displayName: Uri.decodeComponent(name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name),
        title: title,
        artist: artist,
        sourceUrl: link,
        artUrl: artUrl,
        credit: credit,
      );
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  void close() => _http.close(force: true);
}
