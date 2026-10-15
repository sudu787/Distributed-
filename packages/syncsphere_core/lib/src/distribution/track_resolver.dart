/// How a participant turns a room track id into a playable local source.
library;

import 'dart:async';

import '../audio/audio_backend.dart';
import '../model/room_state.dart';

class TrackUnavailableException implements Exception {
  /// `missing_track`, `hash_mismatch`, `download_failed`, `too_large`.
  final String code;
  final String message;
  const TrackUnavailableException(this.code, this.message);
  @override
  String toString() => 'TrackUnavailableException($code): $message';
}

/// Credentials and endpoint for downloading from the host, available after
/// the participant authenticated.
class TransferContext {
  final Uri baseUri;
  final String sessionId;
  final List<int> transferKey;

  /// Current coordinator time in ms (download auth tokens expire in the
  /// coordinator's clock domain).
  final int Function() coordinatorNowMs;
  const TransferContext({
    required this.baseUri,
    required this.sessionId,
    required this.transferKey,
    required this.coordinatorNowMs,
  });
}

abstract class TrackResolver {
  void setTransferContext(TransferContext? ctx);

  /// Cheap local check (library index / cache), no network.
  Future<TrackAvailability> availability(TrackInfo track);

  /// Returns a verified local source, downloading from the host when the
  /// distribution mode allows. Throws [TrackUnavailableException].
  Future<TrackSource> resolve(TrackInfo track, DistributionMode mode);

  /// Best-effort background download of an upcoming track.
  Future<void> prefetch(TrackInfo track, DistributionMode mode) async {}
}

/// Resolver backed by a fixed map, with an optional artificial delay
/// modelling download/IO time. Used by tests and the simulator.
class StaticTrackResolver extends TrackResolver {
  final Map<String, Uri> local;
  final Duration Function(TrackInfo t)? fetchDelay;
  final Set<String> fetchable;
  final Set<String> _fetched = {};

  StaticTrackResolver(this.local, {this.fetchDelay, this.fetchable = const {}});

  @override
  void setTransferContext(TransferContext? ctx) {}

  @override
  Future<TrackAvailability> availability(TrackInfo t) async =>
      local.containsKey(t.id) || _fetched.contains(t.id)
          ? TrackAvailability.available
          : TrackAvailability.missing;

  @override
  Future<TrackSource> resolve(TrackInfo t, DistributionMode mode) async {
    final uri = local[t.id];
    if (uri != null && mode != DistributionMode.lanOnly) {
      return TrackSource(uri: uri, trackId: t.id);
    }
    if (mode == DistributionMode.localOnly || !fetchable.contains(t.id)) {
      throw TrackUnavailableException('missing_track', 'no local copy of ${t.title}');
    }
    if (!_fetched.contains(t.id)) {
      final d = fetchDelay?.call(t);
      if (d != null) await Future<void>.delayed(d);
      _fetched.add(t.id);
    }
    return TrackSource(uri: Uri.parse('cache:///${t.id}'), trackId: t.id);
  }
}
