/// Content-addressed chunks for phone-to-phone sharing (see swarm.dart).
///
/// A track is split into [kChunkSize] chunks. Each chunk is identified by
/// its SHA-256; the *chunk root* (SHA-256 over the concatenated chunk
/// hashes, published in [TrackInfo.chunkRoot] by the coordinator) lets a
/// device verify a chunk list obtained from any peer. Chunks are verified
/// one by one as they arrive, and the whole file is still checked against
/// the track id at the end.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'track_hasher.dart' show kBackgroundHashBytes;

const kChunkSize = 512 * 1024;

int chunkCount(int sizeBytes) => sizeBytes <= 0 ? 0 : (sizeBytes + kChunkSize - 1) ~/ kChunkSize;

/// Byte range [start, end) of chunk [i].
(int, int) chunkRange(int i, int sizeBytes) {
  final start = i * kChunkSize;
  final end = start + kChunkSize > sizeBytes ? sizeBytes : start + kChunkSize;
  return (start, end);
}

String chunkRootOf(List<String> hashes) => sha256.convert(utf8.encode(hashes.join())).toString();

String hashChunk(List<int> bytes) => sha256.convert(bytes).toString();

/// SHA-256 of every chunk of [file] (on a background isolate for large
/// files, see [kBackgroundHashBytes]).
Future<List<String>> chunkHashesOf(File file) async {
  final path = file.path;
  if (await file.length() >= kBackgroundHashBytes) return Isolate.run(() => _chunkHashesOfPath(path));
  return _chunkHashesOfPath(path);
}

Future<List<String>> _chunkHashesOfPath(String path) async {
  final raf = await File(path).open();
  try {
    final size = await raf.length();
    final out = <String>[];
    for (var i = 0; i < chunkCount(size); i++) {
      final (s, e) = chunkRange(i, size);
      await raf.setPosition(s);
      out.add(hashChunk(await raf.read(e - s)));
    }
    return out;
  } finally {
    await raf.close();
  }
}

/// Chunk hashes of served files, computed once per track.
class ChunkIndex {
  final Map<String, Future<List<String>>> _cache = {};

  Future<List<String>> hashesFor(String trackId, File file) =>
      _cache[trackId] ??= chunkHashesOf(file).catchError((Object e) {
        _cache.remove(trackId);
        throw e;
      });

  Future<String> rootFor(String trackId, File file) async => chunkRootOf(await hashesFor(trackId, file));
}

/// Which chunks a device has, as a bitmap.
class ChunkMap {
  final int count;
  final Uint8List bits;

  ChunkMap(this.count) : bits = Uint8List((count + 7) >> 3);
  ChunkMap.full(this.count) : bits = Uint8List((count + 7) >> 3) {
    for (var i = 0; i < count; i++) {
      set(i);
    }
  }
  ChunkMap._(this.count, this.bits);

  bool has(int i) => i >= 0 && i < count && (bits[i >> 3] & (1 << (i & 7))) != 0;
  void set(int i) => bits[i >> 3] |= 1 << (i & 7);
  int get have => Iterable<int>.generate(count).where(has).length;
  bool get complete => have == count;

  /// True when every chunk overlapping bytes [start, end) is present.
  bool covers(int start, int end, int sizeBytes) {
    if (start < 0 || end > sizeBytes || start >= end) return false;
    for (var i = start ~/ kChunkSize; i <= (end - 1) ~/ kChunkSize; i++) {
      if (!has(i)) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {'n': count, 'bits': base64Encode(bits)};

  static ChunkMap? fromJson(Object? j, int expectedCount) {
    if (j is! Map) return null;
    final n = j['n'], b = j['bits'];
    if (n != expectedCount || b is! String) return null;
    try {
      final raw = base64Decode(b);
      if (raw.length != (expectedCount + 7) >> 3) return null;
      return ChunkMap._(expectedCount, raw);
    } on FormatException {
      return null;
    }
  }
}

/// A track being assembled chunk by chunk in the track cache:
/// `<id>.swarm` (data at chunk offsets), `<id>.have` (bitmap) and
/// `<id>.chunks` (verified chunk list). Survives restarts (resume) and is
/// served to other peers while incomplete.
class PartialTrack {
  final String trackId;
  final int sizeBytes;
  final List<String> hashes;
  final File data;
  final File haveFile;
  final ChunkMap map;

  PartialTrack._(this.trackId, this.sizeBytes, this.hashes, this.data, this.haveFile, this.map);

  static File dataFile(Directory dir, String id) => File('${dir.path}/$id.swarm');
  static File _haveFile(Directory dir, String id) => File('${dir.path}/$id.have');
  static File _chunksFile(Directory dir, String id) => File('${dir.path}/$id.chunks');

  /// Opens (resuming) or creates the partial file for a verified chunk list.
  static Future<PartialTrack> open(Directory dir, String id, int sizeBytes, List<String> hashes) async {
    await dir.create(recursive: true);
    final data = dataFile(dir, id), have = _haveFile(dir, id), chunks = _chunksFile(dir, id);
    var map = ChunkMap(hashes.length);
    if (await data.exists() && await have.exists() && await chunks.exists()) {
      try {
        final saved = (jsonDecode(await chunks.readAsString()) as List).cast<String>();
        final m = ChunkMap.fromJson(jsonDecode(await have.readAsString()), hashes.length);
        if (m != null && saved.join() == hashes.join() && await data.length() == sizeBytes) map = m;
      } catch (_) {
        // Corrupt bookkeeping: start over.
      }
    }
    if (map.have == 0) {
      final raf = await data.open(mode: FileMode.write);
      await raf.truncate(sizeBytes);
      await raf.close();
      await chunks.writeAsString(jsonEncode(hashes));
    }
    final p = PartialTrack._(id, sizeBytes, hashes, data, have, map);
    await p._saveMap();
    return p;
  }

  /// Read-only view for serving chunks to peers (null if not present).
  static Future<PartialTrack?> peek(Directory dir, String id) async {
    final data = dataFile(dir, id), have = _haveFile(dir, id), chunks = _chunksFile(dir, id);
    if (!await data.exists() || !await have.exists() || !await chunks.exists()) return null;
    try {
      final hashes = (jsonDecode(await chunks.readAsString()) as List).cast<String>();
      final m = ChunkMap.fromJson(jsonDecode(await have.readAsString()), hashes.length);
      if (m == null) return null;
      return PartialTrack._(id, await data.length(), hashes, data, have, m);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveMap() => haveFile.writeAsString(jsonEncode(map.toJson()));

  Future<void> _tail = Future.value();

  /// Stores chunk [i] if it matches its hash. Returns false otherwise.
  /// Writes are serialized so the bitmap file is never written twice at once.
  Future<bool> write(int i, List<int> bytes) {
    final (s, e) = chunkRange(i, sizeBytes);
    if (i < 0 || i >= hashes.length || bytes.length != e - s || hashChunk(bytes) != hashes[i]) {
      return Future.value(false);
    }
    final done = _tail.then((_) async {
      final raf = await data.open(mode: FileMode.append);
      try {
        await raf.setPosition(s);
        await raf.writeFrom(bytes);
      } finally {
        await raf.close();
      }
      map.set(i);
      await _saveMap();
      return true;
    });
    _tail = done.then((_) {}, onError: (_) {});
    return done;
  }

  /// Removes the bookkeeping files (after completion or giving up).
  Future<void> discard({bool keepData = false}) async {
    for (final f in [haveFile, _chunksFile(data.parent, trackId), if (!keepData) data]) {
      if (await f.exists()) await f.delete();
    }
  }
}
