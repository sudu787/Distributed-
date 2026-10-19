/// Participant-side LAN delivery: resumable, verified downloads into a
/// bounded local cache, and a resolver combining the local library with the
/// cache.
///
/// Normal playback never streams from the network: a track is downloaded
/// completely and its SHA-256 verified *before* the participant reports
/// `ready`, so Wi-Fi hiccups during playback cannot cause underruns.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../audio/audio_backend.dart';
import '../config/sync_config.dart';
import '../model/room_state.dart';
import '../observability/event_log.dart';
import '../protocol/auth.dart';
import 'track_hasher.dart';
import 'swarm.dart';
import 'track_resolver.dart';

class TrackCache {
  final Directory dir;
  final int maxBytes;
  TrackCache(this.dir, {this.maxBytes = 2 * 1024 * 1024 * 1024});

  File fileFor(String id) => File('${dir.path}/$id.audio');
  File partFor(String id) => File('${dir.path}/$id.part');

  Future<bool> has(String id) => fileFor(id).exists();

  /// Deletes least-recently-modified cached tracks until under [maxBytes],
  /// never touching [protect].
  Future<void> evict({Set<String> protect = const {}}) async {
    if (!await dir.exists()) return;
    final files = <File, FileStat>{};
    var total = 0;
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.audio')) {
        final st = await e.stat();
        files[e] = st;
        total += st.size;
      }
    }
    if (total <= maxBytes) return;
    final order = files.entries.toList()..sort((a, b) => a.value.modified.compareTo(b.value.modified));
    for (final e in order) {
      if (total <= maxBytes) break;
      final id = e.key.uri.pathSegments.last.split('.').first;
      if (protect.contains(id)) continue;
      await e.key.delete();
      total -= e.value.size;
    }
  }
}

class TrackDownloader {
  final TransferConfig config;
  final EventLog log;
  final HttpClient _client;
  int bytesDownloaded = 0;

  /// Internet client for [TrackInfo.sourceUrl] downloads (honours the
  /// environment's proxy settings, follows up to 5 redirects).
  final HttpClient _web;
  int bytesFromSources = 0;

  TrackDownloader({required this.log, this.config = const TransferConfig(), HttpClient? client, HttpClient? webClient})
      : _client = client ?? HttpClient(),
        _web = webClient ?? HttpClient() {
    _client.connectionTimeout = config.requestTimeout;
    _client.findProxy = (_) => 'DIRECT'; // LAN traffic must never use a proxy
    _web
      ..connectionTimeout = config.requestTimeout
      ..userAgent = 'SyncSphere';
  }

  /// Downloads [track] into [cache] (resuming a partial file), verifies its
  /// hash and returns the final file. Throws [TrackUnavailableException].
  ///
  /// A track with a [TrackInfo.sourceUrl] is fetched from that source first;
  /// the host ([ctx]) is the fallback (or the only route without a source).
  Future<File> download(TrackInfo track, TransferContext? ctx, TrackCache cache,
      {void Function(int received, int total)? onProgress}) async {
    final out = cache.fileFor(track.id);
    if (await out.exists()) return out;
    if (track.sizeBytes > config.maxFileBytes) {
      throw TrackUnavailableException('too_large', '${track.title} exceeds the transfer limit');
    }
    await cache.dir.create(recursive: true);
    final src = track.sourceUrl;
    if (src != null) {
      final f = await _fromSource(track, Uri.parse(src), cache, onProgress);
      if (f != null) return f;
    }
    if (ctx == null || !track.hostServes) {
      throw TrackUnavailableException('missing_track', 'no route to "${track.title}" (source failed, host does not serve it)');
    }
    final part = cache.partFor(track.id);
    final path = '/tracks/${track.id}';
    final uri = ctx.baseUri.replace(path: path);
    var attempt = 0;
    var restartedAfterMismatch = false;
    while (true) {
      attempt++;
      try {
        final have = await part.exists() ? await part.length() : 0;
        if (have < track.sizeBytes || track.sizeBytes == 0) {
          await _fetch(uri, path, ctx, part, have, track, onProgress);
        }
        final hash = await sha256OfFile(part);
        if (hash != track.id) {
          await part.delete();
          if (!restartedAfterMismatch) {
            restartedAfterMismatch = true;
            log.warn('transfer.mismatch', 'hash mismatch for ${track.title}; restarting download');
            continue;
          }
          throw TrackUnavailableException('hash_mismatch', 'downloaded ${track.title} does not match its id');
        }
        await part.rename(out.path);
        log.info('transfer.done', 'downloaded ${track.title} (${track.sizeBytes} bytes)');
        unawaited(cache.evict(protect: {track.id}).catchError((Object e) {
          log.warn('transfer.evict', 'cache eviction failed: $e');
        }));
        return out;
      } on TrackUnavailableException {
        rethrow;
      } catch (e) {
        if (attempt > config.maxDownloadRetries) {
          throw TrackUnavailableException('download_failed', 'download of ${track.title} failed: $e');
        }
        final delay = Duration(milliseconds: min(500 * pow(2, attempt - 1).toInt(), 8000));
        log.warn('transfer.retry', 'download attempt $attempt for ${track.title} failed ($e); retrying in ${delay.inMilliseconds} ms');
        await Future<void>.delayed(delay);
      }
    }
  }

  /// Downloads [track] from its public source and verifies the hash.
  /// Returns null (after logging) when that fails, so the caller can fall
  /// back to the host.
  Future<File?> _fromSource(TrackInfo track, Uri uri, TrackCache cache, void Function(int, int)? onProgress) async {
    final part = File('${cache.dir.path}/${track.id}.src.part');
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final req = await _web.getUrl(uri).timeout(config.requestTimeout);
        final res = await req.close().timeout(config.requestTimeout);
        if (res.statusCode != HttpStatus.ok) {
          await res.drain<void>();
          throw HttpException('HTTP ${res.statusCode}');
        }
        var received = 0;
        final sink = part.openWrite();
        try {
          await for (final chunk in res.timeout(config.requestTimeout)) {
            received += chunk.length;
            if (received > config.maxFileBytes || (track.sizeBytes > 0 && received > track.sizeBytes)) {
              throw TrackUnavailableException('too_large', 'source sent more data than expected');
            }
            sink.add(chunk);
            onProgress?.call(received, track.sizeBytes);
          }
        } finally {
          await sink.close();
        }
        if (await sha256OfFile(part) != track.id) {
          await part.delete();
          log.warn('transfer.source', '${track.title}: the source returned different content (changed or wrong file); using the host');
          return null;
        }
        final out = cache.fileFor(track.id);
        await part.rename(out.path);
        bytesFromSources += received;
        log.info('transfer.source', 'downloaded ${track.title} from its source (${uri.host})');
        unawaited(cache.evict(protect: {track.id}).catchError((Object e) {
          log.warn('transfer.evict', 'cache eviction failed: $e');
        }));
        return out;
      } catch (e) {
        if (await part.exists()) await part.delete();
        log.warn('transfer.source', 'source download of ${track.title} failed (attempt $attempt): $e');
        if (e is TrackUnavailableException) return null;
        if (attempt < 2) await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return null;
  }

  Future<void> _fetch(Uri uri, String path, TransferContext ctx, File part, int offset, TrackInfo track,
      void Function(int, int)? onProgress) async {
    final req = await _client.getUrl(uri).timeout(config.requestTimeout);
    final expiry = ctx.coordinatorNowMs() + config.authValidity.inMilliseconds;
    req.headers.set('x-syncsphere-auth', signTransfer(ctx.sessionId, ctx.transferKey, path, expiry));
    if (offset > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    final res = await req.close().timeout(config.requestTimeout);
    IOSink sink;
    var received = offset;
    if (res.statusCode == HttpStatus.partialContent && offset > 0) {
      sink = part.openWrite(mode: FileMode.append);
    } else if (res.statusCode == HttpStatus.ok) {
      sink = part.openWrite(mode: FileMode.write);
      received = 0;
    } else if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      await res.drain<void>();
      await part.delete(); // inconsistent partial file: start over
      throw HttpException('range not satisfiable; restarting');
    } else {
      final body = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      throw HttpException('HTTP ${res.statusCode}: ${body.length > 100 ? body.substring(0, 100) : body}');
    }
    try {
      await for (final chunk in res.timeout(config.requestTimeout)) {
        received += chunk.length;
        if (received > config.maxFileBytes || (track.sizeBytes > 0 && received > track.sizeBytes)) {
          throw TrackUnavailableException('too_large', 'server sent more data than expected');
        }
        sink.add(chunk);
        bytesDownloaded += chunk.length;
        onProgress?.call(received, track.sizeBytes);
      }
    } finally {
      await sink.close();
    }
  }

  void close() {
    _client.close(force: true);
    _web.close(force: true);
  }
}

/// Resolver used by the app and the CLI: local library first, then cache,
/// then LAN download (when the room's distribution mode allows).
class LibraryTrackResolver extends TrackResolver {
  /// Verified local files by track id (from the device's library index).
  final Map<String, File> library;
  final TrackCache cache;
  final TrackDownloader downloader;
  final EventLog log;

  /// Phone-to-phone sharing (null: whole-file downloads from the host).
  final SwarmDownloader? swarm;
  TransferContext? _ctx;
  PeerContext? _peers;
  final Map<String, Future<File>> _inFlight = {};

  LibraryTrackResolver({
    required this.library,
    required this.cache,
    required this.downloader,
    required this.log,
    this.swarm,
  });

  @override
  void setTransferContext(TransferContext? ctx) => _ctx = ctx;

  @override
  void setPeerContext(PeerContext? ctx) => _peers = ctx;

  bool _canSwarm(TrackInfo t) => swarm != null && _peers != null && t.chunkRoot != null && t.sourceUrl == null;

  Future<File> _fetch(TrackInfo track, TransferContext? ctx) async {
    if (_canSwarm(track)) {
      try {
        return await swarm!.download(track, cache, host: ctx, peers: _peers!);
      } on TrackUnavailableException catch (e) {
        log.warn('swarm.fallback', 'sharing ${track.title} between phones failed (${e.message}); downloading from the host');
      }
    }
    return downloader.download(track, ctx, cache);
  }

  @override
  Future<TrackAvailability> availability(TrackInfo track) async {
    final f = library[track.id];
    if (f != null && await f.exists()) {
      // Preliminary check only; identity was established by hashing at import.
      return await f.length() == track.sizeBytes ? TrackAvailability.available : TrackAvailability.mismatch;
    }
    if (await cache.has(track.id)) return TrackAvailability.available;
    if (_inFlight.containsKey(track.id)) return TrackAvailability.fetching;
    return TrackAvailability.missing;
  }

  @override
  Future<TrackSource> resolve(TrackInfo track, DistributionMode mode) async {
    if (mode != DistributionMode.lanOnly) {
      final f = library[track.id];
      if (f != null && await f.exists() && await f.length() == track.sizeBytes) {
        return TrackSource(uri: f.uri, trackId: track.id);
      }
    }
    final cached = cache.fileFor(track.id);
    if (await cached.exists()) {
      await cached.setLastModified(DateTime.now()); // LRU touch
      return TrackSource(uri: cached.uri, trackId: track.id);
    }
    if (mode == DistributionMode.localOnly) {
      throw TrackUnavailableException('missing_track', 'no local copy of "${track.title}" (local-files mode)');
    }
    final hasSource = track.sourceUrl != null || _canSwarm(track);
    if (!track.hostServes && !hasSource) {
      throw TrackUnavailableException('missing_track', 'host does not serve "${track.title}"');
    }
    final ctx = _ctx;
    if (ctx == null && !hasSource) {
      throw TrackUnavailableException('missing_track', 'no LAN transfer context yet');
    }
    // Note: the callback must not return the removed future, or
    // whenComplete would wait on itself.
    final fut = _inFlight[track.id] ??= _fetch(track, ctx).whenComplete(() {
      _inFlight.remove(track.id);
    });
    final file = await fut;
    return TrackSource(uri: file.uri, trackId: track.id);
  }

  @override
  Future<void> prefetch(TrackInfo track, DistributionMode mode) async {
    if (mode == DistributionMode.localOnly) return;
    try {
      await resolve(track, mode);
    } on TrackUnavailableException catch (e) {
      log.debug('transfer.prefetch', 'prefetch of ${track.title} skipped: ${e.code}');
    }
  }
}
