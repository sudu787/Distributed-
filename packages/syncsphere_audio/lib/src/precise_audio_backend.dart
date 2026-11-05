import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import 'native_audio_api.dart';

/// [AudioBackend] for the precise engine: the app's own PCM renderer
/// (`PreciseAudioEngine.kt`). `startAt` times are *audible* times, and
/// positions come from the speaker's frame timestamps.
///
/// It shares the ExoPlayer backend's [ClockDomainBridge] (both native sides
/// use `System.nanoTime()`) and its event stream (events tagged
/// `engine: precise` are this backend's). It plays only 16-bit PCM WAV; a
/// source in another format is decoded with [convert] first (normally the
/// track resolver has done that already).
///
/// Used through [ModeSwitchingBackend]: `useEngine(precise)` starts the
/// output, `useEngine(classic)` releases it.
class PreciseAudioBackend implements AudioBackend {
  final PreciseNativeApi api;
  final Stream<Map<String, Object?>> nativeEvents;
  final ClockDomainBridge bridge;
  final MonotonicClock clock;
  final SourceConverter? convert;
  final EventLog? log;
  final StreamController<AudioBackendEvent> _events = StreamController.broadcast();
  StreamSubscription<Map<String, Object?>>? _sub;
  bool _running = false;
  int _outRate = 48000;

  PreciseAudioBackend({
    required this.api,
    required this.nativeEvents,
    required this.bridge,
    required this.clock,
    this.convert,
    this.log,
  }) {
    _sub = nativeEvents.listen(_onNativeEvent);
  }

  int _toNativeNanos(int localUs) => bridge.toRemote(localUs) * 1000;
  int _toLocalUs(int nativeNanos) => bridge.toLocal(nativeNanos ~/ 1000);

  void _onNativeEvent(Map<String, Object?> e) {
    if (e['engine'] != 'precise') return;
    final kind = switch (e['kind']) {
      'playCalled' => AudioEventKind.playCalled,
      'paused' => AudioEventKind.paused,
      'ended' => AudioEventKind.ended,
      'error' => AudioEventKind.error,
      'engineFallback' => AudioEventKind.engineFallback,
      _ => null,
    };
    if (kind == null) return;
    if (kind == AudioEventKind.engineFallback) _running = false;
    final at = e['atNanos'];
    _events.add(AudioBackendEvent(
      kind,
      (e['segment'] as num?)?.toInt() ?? -1,
      at is num && at.toInt() > 0 ? _toLocalUs(at.toInt()) : clock.nowMicros(),
      e['message'] as String?,
    ));
  }

  @override
  AudioCapabilities get capabilities => AudioCapabilities(
        backend: 'precise-renderer@${_outRate}Hz',
        rateControl: true,
        minRate: 0.9,
        maxRate: 1.1,
        schedulesOutput: true,
      );

  @override
  Set<SyncEngineMode> get supportedEngines => const {SyncEngineMode.precise};

  @override
  Future<SyncEngineMode> useEngine(SyncEngineMode mode, FeatureFlags flags) async {
    if (mode != SyncEngineMode.precise) {
      if (_running) await api.release();
      _running = false;
      return SyncEngineMode.classic;
    }
    if (_running) {
      await api.stop();
      return SyncEngineMode.precise;
    }
    final r = await api.start();
    final err = r['error'];
    if (err is String) {
      log?.warn('audio.precise', err);
      throw AudioBackendException('engine_unavailable', err);
    }
    _outRate = (r['outRate'] as num?)?.toInt() ?? _outRate;
    _running = true;
    log?.info('audio.precise', 'precise renderer running at $_outRate Hz');
    return SyncEngineMode.precise;
  }

  @override
  Future<void> prepare({required int segmentId, required TrackSource source, required int positionUs}) async {
    var uri = source.uri;
    if (uri.scheme != 'file') {
      throw AudioBackendException('decode_error', 'the precise engine plays local files only ($uri)');
    }
    if (!isPlayablePcmWav(await readFileHead(File.fromUri(uri), 512))) {
      final c = convert;
      final out = c == null ? null : await c(TrackInfo(id: source.trackId, title: source.trackId, sizeBytes: 0), source);
      if (out == null) throw const AudioBackendException('decode_error', 'not a 16-bit PCM WAV and no decoder');
      uri = out;
    }
    try {
      await api.prepare(segmentId, uri.toString(), positionUs);
    } on PlatformException catch (e) {
      throw AudioBackendException('decode_error', e.message ?? e.code);
    }
  }

  @override
  Future<void> startAt({required int segmentId, required int atLocalUs}) =>
      api.startAt(segmentId, _toNativeNanos(atLocalUs));

  @override
  Future<void> pauseAt({required int segmentId, required int atLocalUs, int? thenSeekToUs}) =>
      api.pauseAt(segmentId, _toNativeNanos(atLocalUs), thenSeekToUs);

  @override
  Future<void> setRate(double rate) => api.setRate(rate.clamp(0.9, 1.1));

  @override
  Future<void> setVolume(double volume) => api.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<void> setChannelRole(ChannelRole role) => api.setChannelRole(role.name);

  @override
  Future<void> stop() => api.stop();

  @override
  Future<PositionSample?> samplePosition() async {
    final m = await api.sample();
    if (m == null) return null;
    return PositionSample(
      segmentId: (m['segment'] as num).toInt(),
      positionUs: (m['positionUs'] as num).toInt(),
      atLocalUs: _toLocalUs((m['atNanos'] as num).toInt()),
      playing: m['playing'] as bool? ?? false,
      bufferedUs: (m['bufferedUs'] as num?)?.toInt() ?? 0,
      rate: (m['rate'] as num?)?.toDouble() ?? 1.0,
      state: m['state'] as String? ?? 'unknown',
      fromAudioTimestamp: m['fromTimestamp'] as bool? ?? false,
    );
  }

  @override
  Stream<AudioBackendEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    if (_running) await api.release();
    _running = false;
    await _events.close();
  }
}
