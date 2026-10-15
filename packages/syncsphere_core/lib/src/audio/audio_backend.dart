/// Contract between the platform-independent playback engine and a concrete
/// audio renderer (Android Media3/ExoPlayer, the simulator, a null sink).
///
/// ## Time
/// All times crossing this interface are in the *engine's local monotonic
/// clock domain* (µs). A backend whose native clock differs (e.g. Android
/// `System.nanoTime()`) converts with a `ClockDomainBridge`.
///
/// ## Segments
/// The engine identifies each prepared stream by a locally unique
/// `segmentId`. A backend keeps at most one *active* segment (playing or
/// paused) and one *standby* segment (prepared, buffered, paused). Starting
/// the standby segment atomically replaces the active one, which allows a
/// scheduled seek or track change without an audible re-buffering gap.
///
/// ## What "start" means
/// Three moments must not be confused:
///   1. command receipt — the participant learns the target time;
///   2. play call — the backend asks the platform player to start
///      ([AudioBackendEvent.playCalled]);
///   3. audible output — the first frame leaves the DAC. Only estimated,
///      from the platform's audio timestamps via [PositionSample].
/// The engine schedules (2) early by a learned start-latency so that (3)
/// lands on the target time, and corrects the remainder with drift control.
library;

import 'dart:async';

import '../model/room_state.dart' show ChannelRole;

/// Where to read audio from.
class TrackSource {
  /// `file:///...` path on the device, or `content://` on Android.
  final Uri uri;
  final String trackId;
  const TrackSource({required this.uri, required this.trackId});
}

class AudioCapabilities {
  /// Backend name for diagnostics (e.g. `media3-exoplayer`).
  final String backend;

  /// Can change playback speed (with pitch preserved) while playing.
  final bool rateControl;
  final double minRate;
  final double maxRate;

  /// Native output latency hint (µs) if the platform exposes one.
  final int? outputLatencyHintUs;

  const AudioCapabilities({
    required this.backend,
    required this.rateControl,
    this.minRate = 1.0,
    this.maxRate = 1.0,
    this.outputLatencyHintUs,
  });
}

/// One measurement of the rendered position.
class PositionSample {
  final int segmentId;

  /// Track position (µs) estimated to be *at the output* at [atLocalUs].
  final int positionUs;

  /// Local monotonic time the position refers to.
  final int atLocalUs;
  final bool playing;
  final int bufferedUs;
  final double rate;

  /// Backend player state, e.g. `ready`, `buffering`, `ended`.
  final String state;

  /// True when the position is derived from hardware audio timestamps
  /// rather than an interpolated/estimated clock.
  final bool fromAudioTimestamp;

  const PositionSample({
    required this.segmentId,
    required this.positionUs,
    required this.atLocalUs,
    required this.playing,
    this.bufferedUs = 0,
    this.rate = 1.0,
    this.state = 'ready',
    this.fromAudioTimestamp = false,
  });
}

enum AudioEventKind { playCalled, paused, stalled, resumedAfterStall, ended, error }

class AudioBackendEvent {
  final AudioEventKind kind;
  final int segmentId;

  /// Local monotonic time of the event (for `playCalled`: when the native
  /// play call actually executed).
  final int atLocalUs;
  final String? message;
  const AudioBackendEvent(this.kind, this.segmentId, this.atLocalUs, [this.message]);
}

class AudioBackendException implements Exception {
  /// `decode_error`, `source_error`, `not_prepared`, ...
  final String code;
  final String message;
  const AudioBackendException(this.code, this.message);
  @override
  String toString() => 'AudioBackendException($code): $message';
}

abstract class AudioBackend {
  AudioCapabilities get capabilities;

  /// Prepares [source] as the standby segment, positioned at [positionUs],
  /// paused and buffered. Completes when a start would be low-latency.
  /// Throws [AudioBackendException] on failure.
  Future<void> prepare({
    required int segmentId,
    required TrackSource source,
    required int positionUs,
  });

  /// Schedules the play call for [segmentId] at local time [atLocalUs]. The
  /// segment must be the prepared standby or the paused active segment.
  /// If [atLocalUs] is in the past the play call happens immediately.
  Future<void> startAt({required int segmentId, required int atLocalUs});

  /// Schedules a pause of the active segment at [atLocalUs], then seeks it
  /// to [thenSeekToUs] (if given) so a later resume is already positioned.
  Future<void> pauseAt({required int segmentId, required int atLocalUs, int? thenSeekToUs});

  /// Sets playback rate of the active segment (ignored if unsupported).
  Future<void> setRate(double rate);

  Future<void> setVolume(double volume);

  /// Experimental distributed stereo: which source channel(s) this device
  /// renders. Backends may apply it immediately or from the next prepared
  /// segment.
  Future<void> setChannelRole(ChannelRole role);

  /// Stops and releases all segments.
  Future<void> stop();

  /// Measures the active segment's rendered position, or null if nothing
  /// is active.
  Future<PositionSample?> samplePosition();

  Stream<AudioBackendEvent> get events;

  Future<void> dispose();
}

/// Backend that renders nothing but follows the timeline perfectly, for
/// headless coordinators and protocol tests.
class NullAudioBackend implements AudioBackend {
  final int Function() nowLocalUs;
  final StreamController<AudioBackendEvent> _events = StreamController.broadcast();
  int? _active;
  int _activePos = 0;
  int? _startLocal;
  bool _playing = false;
  final Map<int, int> _prepared = {};

  NullAudioBackend(this.nowLocalUs);

  @override
  AudioCapabilities get capabilities =>
      const AudioCapabilities(backend: 'null', rateControl: true, minRate: 0.5, maxRate: 2);

  @override
  Future<void> prepare({required int segmentId, required TrackSource source, required int positionUs}) async {
    _prepared[segmentId] = positionUs;
  }

  @override
  Future<void> startAt({required int segmentId, required int atLocalUs}) async {
    final delay = atLocalUs - nowLocalUs();
    Timer(Duration(microseconds: delay < 0 ? 0 : delay), () {
      if (_prepared.containsKey(segmentId)) {
        _activePos = _prepared.remove(segmentId)!;
      }
      _active = segmentId;
      _startLocal = nowLocalUs();
      _playing = true;
      _events.add(AudioBackendEvent(AudioEventKind.playCalled, segmentId, _startLocal!));
    });
  }

  @override
  Future<void> pauseAt({required int segmentId, required int atLocalUs, int? thenSeekToUs}) async {
    final delay = atLocalUs - nowLocalUs();
    Timer(Duration(microseconds: delay < 0 ? 0 : delay), () {
      if (_active != segmentId || !_playing) return;
      _activePos = thenSeekToUs ?? _activePos + (nowLocalUs() - _startLocal!);
      _playing = false;
      _events.add(AudioBackendEvent(AudioEventKind.paused, segmentId, nowLocalUs()));
    });
  }

  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setChannelRole(ChannelRole role) async {}

  @override
  Future<void> stop() async {
    _active = null;
    _playing = false;
    _prepared.clear();
  }

  @override
  Future<PositionSample?> samplePosition() async {
    final a = _active;
    if (a == null) return null;
    final now = nowLocalUs();
    return PositionSample(
      segmentId: a,
      positionUs: _playing ? _activePos + (now - _startLocal!) : _activePos,
      atLocalUs: now,
      playing: _playing,
    );
  }

  @override
  Stream<AudioBackendEvent> get events => _events.stream;

  @override
  Future<void> dispose() => _events.close();
}
