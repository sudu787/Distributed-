/// One [AudioBackend] made of two: the platform player ([classic], which
/// also runs warm start) and an optional precise renderer ([precise]).
/// Exactly one delegate is active; [useEngine] switches, and a failing
/// precise renderer falls back to [classic] on its own (when
/// [FeatureFlags.preciseFallback] allows), telling the playback engine with
/// [AudioEventKind.engineFallback].
///
/// Delegate contract: [classic] supports classic (and usually warm);
/// [precise] is started with `useEngine(precise)` and released with
/// `useEngine(classic)`, which returns classic.
library;

import 'dart:async';

import '../config/feature_flags.dart';
import '../model/room_state.dart' show ChannelRole;
import '../model/sync_engine.dart';
import 'audio_backend.dart';

class ModeSwitchingBackend implements AudioBackend {
  final AudioBackend classic;
  final AudioBackend? precise;
  final StreamController<AudioBackendEvent> _events = StreamController.broadcast(sync: true);
  final List<StreamSubscription<AudioBackendEvent>> _subs = [];

  late AudioBackend _current = classic;
  SyncEngineMode _requested = SyncEngineMode.classic;
  FeatureFlags _flags = const FeatureFlags();

  ModeSwitchingBackend({required this.classic, this.precise}) {
    _subs.add(classic.events.listen((e) {
      if (identical(_current, classic)) _events.add(e);
    }));
    final p = precise;
    if (p != null) {
      _subs.add(p.events.listen((e) {
        if (!identical(_current, p)) return;
        if (e.kind == AudioEventKind.engineFallback) {
          _onPreciseFailed(e);
        } else {
          _events.add(e);
        }
      }));
    }
  }

  /// The delegate currently rendering.
  AudioBackend get current => _current;

  /// The engine the playback engine asked for (it may run another after a
  /// fallback). Lets track conversion prepare for it in advance.
  SyncEngineMode get requested => _requested;

  @override
  AudioCapabilities get capabilities => _current.capabilities;

  @override
  Set<SyncEngineMode> get supportedEngines => {
        ...classic.supportedEngines,
        if (precise != null) SyncEngineMode.precise,
      };

  @override
  Future<SyncEngineMode> useEngine(SyncEngineMode mode, FeatureFlags flags) async {
    _requested = mode;
    _flags = flags;
    final p = precise;
    if (mode == SyncEngineMode.precise && p != null) {
      await classic.useEngine(SyncEngineMode.classic, flags);
      try {
        if (await p.useEngine(SyncEngineMode.precise, flags) == SyncEngineMode.precise) {
          _current = p;
          return SyncEngineMode.precise;
        }
        if (!flags.preciseFallback) throw const AudioBackendException('engine_unavailable', 'precise renderer unavailable');
      } on AudioBackendException {
        if (!flags.preciseFallback) rethrow;
      }
      _current = classic;
      return SyncEngineMode.classic;
    }
    if (identical(_current, p)) await p!.useEngine(SyncEngineMode.classic, flags);
    _current = classic;
    return classic.useEngine(mode == SyncEngineMode.precise ? SyncEngineMode.classic : mode, flags);
  }

  void _onPreciseFailed(AudioBackendEvent e) {
    if (!_flags.preciseFallback) {
      _events.add(AudioBackendEvent(AudioEventKind.error, e.segmentId, e.atLocalUs, 'precise renderer failed: ${e.message}'));
      return;
    }
    _current = classic;
    unawaited(classic.useEngine(SyncEngineMode.classic, _flags).catchError((Object _) => SyncEngineMode.classic));
    _events.add(e);
  }

  @override
  Future<void> prepare({required int segmentId, required TrackSource source, required int positionUs}) =>
      _current.prepare(segmentId: segmentId, source: source, positionUs: positionUs);

  @override
  Future<void> startAt({required int segmentId, required int atLocalUs}) =>
      _current.startAt(segmentId: segmentId, atLocalUs: atLocalUs);

  @override
  Future<void> pauseAt({required int segmentId, required int atLocalUs, int? thenSeekToUs}) =>
      _current.pauseAt(segmentId: segmentId, atLocalUs: atLocalUs, thenSeekToUs: thenSeekToUs);

  @override
  Future<void> setRate(double rate) => _current.setRate(rate);

  // Volume and channel role are room settings: both delegates keep them, so
  // a switch or fallback does not lose them.
  @override
  Future<void> setVolume(double volume) async {
    await classic.setVolume(volume);
    await precise?.setVolume(volume);
  }

  @override
  Future<void> setChannelRole(ChannelRole role) async {
    await classic.setChannelRole(role);
    await precise?.setChannelRole(role);
  }

  @override
  Future<void> stop() => _current.stop();

  @override
  Future<PositionSample?> samplePosition() => _current.samplePosition();

  @override
  Stream<AudioBackendEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await precise?.dispose();
    await classic.dispose();
    await _events.close();
  }
}
