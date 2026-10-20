import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/app_store.dart';
import '../data/models.dart';

/// Reads duration/tags of a local file (MediaMetadataRetriever on Android).
typedef TrackProber = Future<Map<String, Object?>> Function(String uri);

/// Imports audio files into the app's private library directory, keyed by
/// content hash, so the same song imported on two phones gets the same id.
class LibraryService {
  final AppStore store;
  final Directory libraryDir;
  final TrackProber? prober;
  final EventLog log;

  LibraryService({required this.store, required this.libraryDir, this.prober, required this.log});

  Future<List<LibraryTrack>> list() async {
    final tracks = await store.libraryTracks();
    final present = <LibraryTrack>[];
    for (final t in tracks) {
      if (await File(t.path).exists()) {
        present.add(t);
      } else {
        log.warn('library.missing', 'library file vanished: ${t.title}');
        await store.deleteTrack(t.id);
      }
    }
    return present;
  }

  /// Copies [source] into the library, hashes it and records metadata.
  /// Importing an identical file twice yields the same track.
  Future<LibraryTrack> import(File source, {String? displayName}) async {
    await libraryDir.create(recursive: true);
    final ext = p.extension(source.path).toLowerCase();
    final tmp = File(p.join(libraryDir.path, '.import-${newId(6)}$ext'));
    await source.copy(tmp.path);
    try {
      final hash = await sha256OfFile(tmp);
      final dest = File(p.join(libraryDir.path, '$hash$ext'));
      if (await dest.exists()) {
        await tmp.delete();
      } else {
        await tmp.rename(dest.path);
      }
      final size = await dest.length();
      Map<String, Object?> meta = const {};
      if (prober != null) {
        try {
          meta = await prober!(dest.uri.toString());
        } catch (e) {
          log.warn('library.probe', 'could not read metadata of ${p.basename(source.path)}: $e');
        }
      }
      final name = displayName ?? p.basenameWithoutExtension(source.path);
      final durMs = meta['durationMs'];
      final track = LibraryTrack(
        id: hash,
        path: dest.path,
        title: _nonEmpty(meta['title']) ?? name,
        artist: _nonEmpty(meta['artist']),
        album: _nonEmpty(meta['album']),
        sizeBytes: size,
        durationUs: durMs is num ? durMs.toInt() * 1000 : null,
        mimeType: _nonEmpty(meta['mimeType']),
        addedAt: DateTime.now(),
      );
      await store.upsertTrack(track);
      log.info('library.import', 'imported "${track.title}"', {'sha256': hash.substring(0, 12), 'bytes': size});
      return track;
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  Future<void> remove(LibraryTrack t) async {
    await store.deleteTrack(t.id);
    final f = File(t.path);
    if (await f.exists()) await f.delete();
  }

  static String? _nonEmpty(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
}
