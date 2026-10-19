/// Sample-exact seeking for formats whose players seek approximately.
///
/// ExoPlayer (and Android's MediaExtractor) seek VBR MP3 through the Xing
/// table of contents: 100 entries, each quantized to 1/256 of the file. On a
/// 4-minute song a seek can land hundreds of milliseconds from the requested
/// time while the player still *reports* the requested time. Every device
/// lands differently, so after a resume, seek, late join or resync the room
/// is out of sync by an amount no position report shows (and acoustic
/// calibration cannot fix, because it changes with every seek). Raw ADTS AAC
/// has no index at all.
///
/// [ConvertingTrackResolver] lets the platform decode such files once into
/// a format with exact seeking (PCM WAV on Android) and plays that copy.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../audio/audio_backend.dart';
import '../model/room_state.dart';
import '../observability/event_log.dart';
import 'swarm.dart' show PeerContext;
import 'track_resolver.dart';

/// Whether a file starting with [head] (its first bytes) is MPEG audio
/// (MP3, possibly behind an ID3v2 tag) or ADTS AAC, i.e. a format whose
/// seeking is approximate.
bool needsExactSeekCopy(List<int> head) {
  if (head.length >= 3 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) return true; // "ID3"
  // MPEG audio / ADTS frame sync: 11 (MPEG) or 12 (ADTS) set bits.
  return head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0;
}

/// Produces an exact-seek copy of [source], or null to play it as is.
typedef SourceConverter = Future<Uri?> Function(TrackInfo track, TrackSource source);

/// Wraps a resolver and converts what it returns (see library doc).
/// Conversion failures fall back to the original source.
class ConvertingTrackResolver extends TrackResolver {
  final TrackResolver inner;
  final SourceConverter convert;
  final EventLog log;
  final Map<String, Future<TrackSource>> _inFlight = {};
  final Map<String, TrackSource> _done = {};

  ConvertingTrackResolver({required this.inner, required this.convert, required this.log});

  @override
  void setTransferContext(TransferContext? ctx) => inner.setTransferContext(ctx);

  @override
  void setPeerContext(PeerContext? ctx) => inner.setPeerContext(ctx);

  @override
  Future<TrackAvailability> availability(TrackInfo track) => inner.availability(track);

  @override
  Future<TrackSource> resolve(TrackInfo track, DistributionMode mode) async {
    final src = await inner.resolve(track, mode);
    final done = _done[track.id];
    if (done != null && await File.fromUri(done.uri).exists()) return done;
    // Note: the callback must not return the removed future (see
    // TrackDownloader), or whenComplete would wait on itself.
    return _inFlight[track.id] ??= _convert(track, src).whenComplete(() {
      _inFlight.remove(track.id);
    });
  }

  Future<TrackSource> _convert(TrackInfo track, TrackSource src) async {
    final sw = Stopwatch()..start();
    try {
      final uri = await convert(track, src);
      if (uri == null) return src;
      final out = TrackSource(uri: uri, trackId: track.id);
      _done[track.id] = out;
      log.info('track.exact', 'exact-seek copy of "${track.title}" ready (${sw.elapsedMilliseconds} ms)');
      return out;
    } catch (e) {
      log.warn('track.exact', 'could not make an exact-seek copy of "${track.title}"; seeks may be inexact: $e');
      return src;
    }
  }

  @override
  Future<void> prefetch(TrackInfo track, DistributionMode mode) async {
    await inner.prefetch(track, mode);
    if (await inner.availability(track) == TrackAvailability.available) {
      await resolve(track, mode);
    }
  }

  /// Converts every playlist track that is already on this device, one at a
  /// time, so playback does not wait for decoding later. Never downloads.
  Future<void> warm(List<TrackInfo> tracks, DistributionMode mode) async {
    for (final t in tracks) {
      if (_done.containsKey(t.id)) continue;
      try {
        if (await inner.availability(t) == TrackAvailability.available) await resolve(t, mode);
      } catch (e) {
        log.debug('track.exact', 'warm-up skipped "${t.title}": $e');
      }
    }
  }
}

/// Reads the first [n] bytes of a local file (empty if unreadable).
Future<Uint8List> readFileHead(File f, [int n = 16]) async {
  try {
    final raf = await f.open();
    try {
      return await raf.read(n);
    } finally {
      await raf.close();
    }
  } on FileSystemException {
    return Uint8List(0);
  }
}
