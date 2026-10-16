import 'dart:io';

import '../data/app_store.dart';

/// Extracts a file's embedded cover picture to [outPath]; false if none.
typedef ArtworkExtractor = Future<bool> Function(String uri, String outPath);

/// Album art for room tracks. Every phone reads the picture from its own
/// copy of the song (My music, or the copy downloaded from the host), so the
/// protocol carries no images. Results are cached by track id.
class ArtworkService {
  final ArtworkExtractor? extract;
  final AppStore? store;
  final Directory? artDir;
  final Directory? trackCacheDir;
  final Map<String, Future<File?>> _inflight = {};

  ArtworkService({required this.extract, required this.store, required this.artDir, required this.trackCacheDir});

  /// No artwork (tests, desktop builds): every track shows its placeholder.
  ArtworkService.disabled()
      : extract = null,
        store = null,
        artDir = null,
        trackCacheDir = null;

  bool get enabled => extract != null && artDir != null;

  File? _art(String id) => artDir == null ? null : File('${artDir!.path}/$id.jpg');
  File? _none(String id) => artDir == null ? null : File('${artDir!.path}/$id.none');

  /// The cover of [trackId], or null if it has none or the song is not on
  /// this phone yet ([mayAppearLater] tells the two apart).
  Future<File?> artFor(String trackId) => _inflight[trackId] ??= _load(trackId).whenComplete(() => _inflight.remove(trackId));

  /// True while the song is not on this phone yet, so its cover may still
  /// show up once it has been downloaded.
  Future<bool> mayAppearLater(String trackId) async {
    if (!enabled) return false;
    if (await _art(trackId)!.exists() || await _none(trackId)!.exists()) return false;
    return await _source(trackId) == null;
  }

  Future<File?> _load(String id) async {
    final ex = extract;
    if (ex == null || artDir == null) return null;
    final out = _art(id)!;
    if (await out.exists()) return out;
    final none = _none(id)!;
    if (await none.exists()) return null;
    final src = await _source(id);
    if (src == null) return null;
    await artDir!.create(recursive: true);
    bool ok;
    try {
      ok = await ex(src.uri.toString(), out.path);
    } catch (_) {
      ok = false;
    }
    if (ok && await out.exists()) return out;
    await none.create(recursive: true);
    return null;
  }

  Future<File?> _source(String id) async {
    final s = store;
    if (s != null) {
      for (final t in await s.libraryTracks()) {
        if (t.id == id) {
          final f = File(t.path);
          if (await f.exists()) return f;
        }
      }
    }
    final dir = trackCacheDir;
    if (dir != null) {
      final cached = File('${dir.path}/$id.audio');
      if (await cached.exists()) return cached;
    }
    return null;
  }
}
