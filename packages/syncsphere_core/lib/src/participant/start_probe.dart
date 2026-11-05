/// Warm start's silent test start: while the room is idle, play a silent
/// clip through the normal ExoPlayer path, wait until the reported position
/// is trustworthy (ExoPlayer smooths it for ~2 s after a start), and read
/// off how long the play call took to become audible. The first real start
/// then uses this measured delay instead of a platform guess.
///
/// The probe owns the backend while it runs; the playback engine starts one
/// only when nothing else is prepared or playing, and [cancel]s it the
/// moment the room needs the player.
library;

import 'dart:async';

import '../audio/audio_backend.dart';
import '../observability/event_log.dart';
import '../time/clock.dart';

class StartProbe {
  final AudioBackend backend;
  final MonotonicClock clock;
  final EventLog log;

  /// Wait after the play call before sampling the position.
  final Duration settle;

  bool _cancelled = false;
  Future<void>? _stopping;

  StartProbe({required this.backend, required this.clock, required this.log, required this.settle});

  bool get cancelled => _cancelled;

  /// Plays [source] as segment [segmentId] and returns the play-call →
  /// audible delay (µs), or null if cancelled or implausible. Always stops
  /// the backend before returning.
  Future<int?> run({required int segmentId, required TrackSource source}) async {
    int? calledAt;
    final sub = backend.events.listen((e) {
      if (e.segmentId == segmentId && e.kind == AudioEventKind.playCalled) calledAt = e.atLocalUs;
    });
    try {
      await backend.prepare(segmentId: segmentId, source: source, positionUs: 0);
      if (_cancelled) return null;
      final planned = clock.nowMicros() + 150000;
      await backend.startAt(segmentId: segmentId, atLocalUs: planned);
      await Future<void>.delayed(Duration(microseconds: planned - clock.nowMicros()) + settle);
      if (_cancelled) return null;
      final sample = await backend.samplePosition();
      if (_cancelled || sample == null || sample.segmentId != segmentId || !sample.playing) return null;
      final audibleFromUs = sample.atLocalUs - (sample.positionUs / sample.rate).round();
      final latency = audibleFromUs - (calledAt ?? planned);
      if (latency < -200000 || latency > 1000000) {
        log.warn('engine.probe', 'implausible probe result ${latency ~/ 1000} ms; ignored');
        return null;
      }
      return latency;
    } finally {
      await sub.cancel();
      await (_stopping ??= backend.stop());
    }
  }

  /// Stops the probe now (the room needs the player).
  Future<void> cancel() {
    _cancelled = true;
    return _stopping ??= backend.stop();
  }
}
