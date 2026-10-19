/// Phone-to-phone song sharing (BitTorrent-style, on the LAN).
///
/// With many phones the host's Wi-Fi uplink is the bottleneck: every guest
/// pulls the whole file from it. [SwarmDownloader] instead fetches the
/// track in 512 KiB chunks from *any* device that has them (complete or
/// partial copies), rarest chunk first, and serves what it has to others
/// while it is still downloading (see [PartialTrack] and the peer server in
/// file_server.dart). The host is only one source among others, so songs
/// also survive the host leaving.
///
/// Integrity: the chunk list is checked against [TrackInfo.chunkRoot]
/// (published by the coordinator), every chunk against its hash, and the
/// assembled file against the track id. A source that sends a bad chunk
/// twice is not used again.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/sync_config.dart';
import '../model/room_state.dart';
import '../observability/event_log.dart';
import '../protocol/auth.dart';
import 'chunks.dart';
import 'track_downloader.dart';
import 'track_hasher.dart';
import 'track_resolver.dart';

/// Another device's peer file server.
class PeerSource {
  final String deviceId;
  final Uri base;
  const PeerSource(this.deviceId, this.base);
}

/// What a device needs to fetch chunks from peers.
class PeerContext {
  final String selfId;

  /// Room-wide peer key ([RoomKey.peerKey]).
  final List<int> peerKey;

  /// Current coordinator time in ms (token expiry).
  final int Function() coordinatorNowMs;

  /// Peers to try (excluding this device and the coordinator).
  final List<PeerSource> Function() peers;

  const PeerContext({required this.selfId, required this.peerKey, required this.coordinatorNowMs, required this.peers});
}

class _Source {
  final String id; // 'host' or a device id
  final Uri base;
  final String Function(String path) sign;
  ChunkMap? have;
  int inFlight = 0;
  int bad = 0;
  int failures = 0;
  int? downUntilMs;
  int bytes = 0;
  _Source(this.id, this.base, this.sign);
  bool get banned => bad >= 2;
}

class SwarmStats {
  int bytesFromHost = 0;
  int bytesFromPeers = 0;
  int badChunks = 0;
}

class SwarmDownloader {
  final EventLog log;
  final TransferConfig config;
  final HttpClient _client;
  final int maxParallel;
  final int perSourceParallel;
  final Duration haveRefresh;

  /// Give up (caller falls back to the whole-file download) after this long
  /// without a new chunk.
  final Duration stallTimeout;

  final SwarmStats stats = SwarmStats();

  SwarmDownloader({
    required this.log,
    this.config = const TransferConfig(),
    this.maxParallel = 4,
    this.perSourceParallel = 2,
    this.haveRefresh = const Duration(seconds: 2),
    this.stallTimeout = const Duration(seconds: 30),
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    _client
      ..connectionTimeout = config.requestTimeout
      ..findProxy = (_) => 'DIRECT';
  }

  void close() => _client.close(force: true);

  /// Downloads [track] (which must have a chunk root) into [cache].
  /// Throws [TrackUnavailableException] when the swarm cannot finish it.
  Future<File> download(TrackInfo track, TrackCache cache, {TransferContext? host, required PeerContext peers}) async {
    final out = cache.fileFor(track.id);
    if (await out.exists()) return out;
    final root = track.chunkRoot;
    if (root == null) throw TrackUnavailableException('no_chunks', '${track.title} has no chunk list');
    if (track.sizeBytes <= 0 || track.sizeBytes > config.maxFileBytes) {
      throw TrackUnavailableException('too_large', '${track.title} cannot be shared in chunks');
    }
    final sources = <String, _Source>{};
    if (host != null && track.hostServes) {
      sources['host'] = _Source('host', host.baseUri, (path) {
        final exp = host.coordinatorNowMs() + config.authValidity.inMilliseconds;
        return signTransfer(host.sessionId, host.transferKey, path, exp);
      });
    }
    void refreshPeerList() {
      for (final p in peers.peers()) {
        if (p.deviceId == peers.selfId) continue;
        sources.putIfAbsent(
            p.deviceId,
            () => _Source(p.deviceId, p.base, (path) {
                  final exp = peers.coordinatorNowMs() + config.authValidity.inMilliseconds;
                  return signTransfer(peers.selfId, peers.peerKey, path, exp);
                }));
      }
    }

    refreshPeerList();
    if (sources.isEmpty) throw TrackUnavailableException('no_sources', 'nobody to fetch ${track.title} from');

    // 1. A chunk list that matches the published root (host first).
    List<String>? hashes;
    for (final s in [if (sources['host'] != null) sources['host']!, ...sources.values.where((s) => s.id != 'host')]) {
      final h = await _chunkList(s, track);
      if (h != null && chunkRootOf(h) == root && h.length == chunkCount(track.sizeBytes)) {
        hashes = h;
        break;
      }
    }
    if (hashes == null) throw TrackUnavailableException('no_chunks', 'no valid chunk list for ${track.title}');

    // 2. Assemble.
    final part = await PartialTrack.open(cache.dir, track.id, track.sizeBytes, hashes);
    final n = hashes.length;
    final inFlight = <int>{};
    final pending = <Future<void>>{};
    var lastProgress = DateTime.now();
    var lastHaveRefresh = DateTime.fromMillisecondsSinceEpoch(0);

    Future<void> fetch(int i, _Source s) async {
      s.inFlight++;
      try {
        final bytes = await _range(s, track, i);
        if (bytes == null) {
          s.failures++;
          if (s.failures >= 3) s.downUntilMs = DateTime.now().millisecondsSinceEpoch + 10000;
          return;
        }
        if (await part.write(i, bytes)) {
          s.bytes += bytes.length;
          s.failures = 0;
          if (s.id == 'host') {
            stats.bytesFromHost += bytes.length;
          } else {
            stats.bytesFromPeers += bytes.length;
          }
          lastProgress = DateTime.now();
        } else {
          s.bad++;
          stats.badChunks++;
          log.warn('swarm.bad_chunk', 'bad chunk $i of ${track.title} from ${s.id}${s.banned ? '; not using it again' : ''}');
        }
      } finally {
        s.inFlight--;
        inFlight.remove(i);
      }
    }

    while (!part.map.complete) {
      final now = DateTime.now();
      if (now.difference(lastHaveRefresh) >= haveRefresh) {
        lastHaveRefresh = now;
        refreshPeerList();
        await Future.wait([
          for (final s in sources.values)
            if (!s.banned && s.id != 'host') _refreshHave(s, track, n),
        ]);
        final h = sources['host'];
        if (h != null) h.have ??= ChunkMap.full(n);
      }
      // Rarest first among chunks we still need.
      final missing = [for (var i = 0; i < n; i++) if (!part.map.has(i) && !inFlight.contains(i)) i];
      int rarity(int i) => sources.values.where((s) => s.have?.has(i) ?? false).length;
      missing.sort((a, b) {
        final c = rarity(a).compareTo(rarity(b));
        return c != 0 ? c : a.compareTo(b);
      });
      final nowMs = now.millisecondsSinceEpoch;
      for (final i in missing) {
        if (inFlight.length >= maxParallel) break;
        final candidates = sources.values
            .where((s) =>
                !s.banned &&
                (s.downUntilMs == null || s.downUntilMs! < nowMs) &&
                s.inFlight < perSourceParallel &&
                (s.have?.has(i) ?? false))
            .toList()
          // Peers before the host (that is the point), then least loaded.
          ..sort((a, b) {
            final ah = a.id == 'host' ? 1 : 0, bh = b.id == 'host' ? 1 : 0;
            return ah != bh ? ah - bh : a.inFlight.compareTo(b.inFlight);
          });
        if (candidates.isEmpty) continue;
        inFlight.add(i);
        late Future<void> f;
        f = fetch(i, candidates.first).whenComplete(() => pending.remove(f));
        pending.add(f);
      }
      if (part.map.complete) break;
      if (DateTime.now().difference(lastProgress) > stallTimeout) {
        await Future.wait(pending);
        throw TrackUnavailableException(
            'swarm_stalled', 'no progress on ${track.title} (${part.map.have}/$n chunks); falling back');
      }
      if (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } else {
        await Future.any([...pending, Future<void>.delayed(haveRefresh)]);
      }
    }
    await Future.wait(pending);

    // 3. Verify the whole file and move it into place.
    if (await sha256OfFile(part.data) != track.id) {
      await part.discard();
      throw TrackUnavailableException('hash_mismatch', 'assembled ${track.title} does not match its id');
    }
    await part.discard(keepData: true);
    await part.data.rename(out.path);
    final peersBytes = {for (final s in sources.values) if (s.id != 'host' && s.bytes > 0) s.id: s.bytes};
    final fromPeers = peersBytes.values.fold<int>(0, (a, b) => a + b);
    log.info('swarm.done',
        'downloaded ${track.title}: ${_kib(sources['host']?.bytes ?? 0)} from the host, ${_kib(fromPeers)} from ${peersBytes.length} phone(s)',
        {'peers': peersBytes});
    unawaited(cache.evict(protect: {track.id}).catchError((Object e) {
      log.warn('transfer.evict', 'cache eviction failed: $e');
    }));
    return out;
  }

  static String _kib(int b) => '${(b / 1024).round()} KiB';

  Future<Object?> _getJson(_Source s, String path) async {
    final req = await _client.getUrl(s.base.replace(path: path)).timeout(config.requestTimeout);
    req.headers.set('x-syncsphere-auth', s.sign(path));
    final res = await req.close().timeout(config.requestTimeout);
    final body = await res.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(config.requestTimeout);
    if (res.statusCode != HttpStatus.ok) return null;
    return jsonDecode(body);
  }

  Future<List<String>?> _chunkList(_Source s, TrackInfo track) async {
    try {
      final j = await _getJson(s, '/tracks/${track.id}/chunks');
      if (j is! Map || j['size'] != track.sizeBytes) return null;
      final h = j['hashes'];
      if (h is! List || h.any((e) => e is! String || !TrackInfo.isValidTrackId(e))) return null;
      return h.cast<String>();
    } catch (e) {
      log.debug('swarm.chunks', 'no chunk list from ${s.id}: $e');
      return null;
    }
  }

  Future<void> _refreshHave(_Source s, TrackInfo track, int n) async {
    try {
      s.have = ChunkMap.fromJson(await _getJson(s, '/tracks/${track.id}/have'), n);
    } catch (_) {
      s.have = null;
    }
  }

  Future<List<int>?> _range(_Source s, TrackInfo track, int i) async {
    final (start, end) = chunkRange(i, track.sizeBytes);
    final path = '/tracks/${track.id}';
    try {
      final req = await _client.getUrl(s.base.replace(path: path)).timeout(config.requestTimeout);
      req.headers
        ..set('x-syncsphere-auth', s.sign(path))
        ..set(HttpHeaders.rangeHeader, 'bytes=$start-${end - 1}');
      final res = await req.close().timeout(config.requestTimeout);
      if (res.statusCode != HttpStatus.partialContent && !(res.statusCode == HttpStatus.ok && start == 0 && end == track.sizeBytes)) {
        await res.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final c in res.timeout(config.requestTimeout)) {
        bytes.addAll(c);
        if (bytes.length > end - start) return bytes; // fails the hash check
      }
      return bytes;
    } catch (e) {
      log.debug('swarm.fetch', 'chunk $i from ${s.id} failed: $e');
      return null;
    }
  }
}
