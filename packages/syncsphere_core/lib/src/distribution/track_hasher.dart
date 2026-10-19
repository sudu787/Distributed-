/// Content identity for audio files.
///
/// A track's id is the SHA-256 of its exact bytes. Metadata and file size
/// are used only as a cheap *preliminary* filter (two files with different
/// sizes cannot match); equality is decided by the hash alone.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Files at least this large are hashed on a background isolate, so the
/// main isolate (clock sync, drift control) is not held up.
const kBackgroundHashBytes = 2 * 1024 * 1024;

/// SHA-256 of [file], streamed (never loaded into memory). Large files are
/// hashed on a background isolate.
Future<String> sha256OfFile(File file) async {
  final path = file.path;
  if (await file.length() >= kBackgroundHashBytes) return Isolate.run(() => _sha256OfPath(path));
  return _sha256OfPath(path);
}

Future<String> _sha256OfPath(String path) async {
  final file = File(path);
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return out.value.toString();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Cached hash entry, invalidated when size or modification time change.
class HashCacheEntry {
  final String path;
  final int size;
  final int modifiedMs;
  final String sha256;
  const HashCacheEntry(this.path, this.size, this.modifiedMs, this.sha256);
}

/// Hashes files, reusing previous results for unchanged files. The app
/// persists entries in SQLite; tests use the in-memory map.
class TrackHasher {
  final Map<String, HashCacheEntry> _cache = {};

  void seed(Iterable<HashCacheEntry> entries) {
    for (final e in entries) {
      _cache[e.path] = e;
    }
  }

  Iterable<HashCacheEntry> get entries => _cache.values;

  Future<HashCacheEntry> hash(File f) async {
    final stat = await f.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('not a file', f.path);
    }
    final mtime = stat.modified.millisecondsSinceEpoch;
    final cached = _cache[f.path];
    if (cached != null && cached.size == stat.size && cached.modifiedMs == mtime) {
      return cached;
    }
    final h = await sha256OfFile(f);
    final e = HashCacheEntry(f.path, stat.size, mtime, h);
    _cache[f.path] = e;
    return e;
  }
}
