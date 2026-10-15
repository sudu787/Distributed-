import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import 'android_calibration_recorder.dart';
import 'native_audio_api.dart';

/// [AudioBackend] backed by Media3/ExoPlayer on Android.
///
/// The engine works in the Dart isolate's monotonic clock (µs); the native
/// side schedules in `System.nanoTime()`. Both are CLOCK_MONOTONIC on
/// Android but with different epochs, so a [ClockDomainBridge] estimates the
/// offset by bracketing native reads between Dart reads (sub-millisecond
/// uncertainty, re-calibrated periodically).
class Media3AudioBackend implements AudioBackend {
  final NativeAudioApi api;
  final MonotonicClock clock;
  final EventLog? log;
  late final ClockDomainBridge bridge;
  AudioCapabilities _caps = const AudioCapabilities(backend: 'media3-exoplayer', rateControl: true);
  Map<String, Object?> deviceInfo = const {};
  final StreamController<AudioBackendEvent> _events = StreamController.broadcast();
  final StreamController<String> _commands = StreamController.broadcast();
  StreamSubscription<Map<String, Object?>>? _nativeSub;
  Timer? _recalibrate;

  Media3AudioBackend({NativeAudioApi? api, MonotonicClock? clock, this.log})
      : api = api ?? MethodChannelAudioApi(),
        clock = clock ?? SystemMonotonicClock.instance {
    bridge = ClockDomainBridge(
      local: this.clock,
      readRemoteMicros: () async => (await this.api.nowNanos()) ~/ 1000,
    );
  }

  /// Must be awaited before use.
  Future<void> initialize() async {
    deviceInfo = await api.init();
    final hint = deviceInfo['outputLatencyHintUs'];
    _caps = AudioCapabilities(
      backend: (deviceInfo['backend'] as String?) ?? 'media3-exoplayer',
      rateControl: (deviceInfo['rateControl'] as bool?) ?? true,
      minRate: (deviceInfo['minRate'] as num?)?.toDouble() ?? 0.5,
      maxRate: (deviceInfo['maxRate'] as num?)?.toDouble() ?? 2.0,
      outputLatencyHintUs: hint is num ? hint.toInt() : null,
    );
    final e = await bridge.calibrate(samples: 24);
    log?.info('audio.bridge', 'Dart↔native clock bridge: ±${e.uncertaintyMicros.round()} µs',
        {'offsetUs': e.offsetMicros.round(), 'uncertaintyUs': e.uncertaintyMicros.round()});
    _nativeSub = api.events.listen(_onNativeEvent, onError: (Object e) {
      log?.error('audio.events', 'native event stream error: $e');
    });
    _recalibrate = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        await bridge.calibrate(samples: 6);
      } catch (e) {
        log?.warn('audio.bridge', 'recalibration failed: $e');
      }
    });
  }

  int _toNativeNanos(int localUs) => bridge.toRemote(localUs) * 1000;
  int _toLocalUs(int nativeNanos) => bridge.toLocal(nativeNanos ~/ 1000);

  void _onNativeEvent(Map<String, Object?> e) {
    if (e['kind'] == 'command') {
      final cmd = e['message'];
      if (cmd is String) _commands.add(cmd);
      return;
    }
    final kind = switch (e['kind']) {
      'playCalled' => AudioEventKind.playCalled,
      'paused' => AudioEventKind.paused,
      'stalled' => AudioEventKind.stalled,
      'resumedAfterStall' => AudioEventKind.resumedAfterStall,
      'ended' => AudioEventKind.ended,
      'error' => AudioEventKind.error,
      _ => null,
    };
    if (kind == null) return;
    final at = e['atNanos'];
    _events.add(AudioBackendEvent(
      kind,
      (e['segment'] as num?)?.toInt() ?? -1,
      at is num ? _toLocalUs(at.toInt()) : clock.nowMicros(),
      e['message'] as String?,
    ));
  }

  @override
  AudioCapabilities get capabilities => _caps;

  @override
  Future<void> prepare({required int segmentId, required TrackSource source, required int positionUs}) async {
    try {
      await api.prepare(segmentId, source.uri.toString(), positionUs);
    } on PlatformException catch (e) {
      final msg = e.message ?? e.code;
      throw AudioBackendException(msg.startsWith('decode_error') ? 'decode_error' : 'prepare_error', msg);
    }
  }

  @override
  Future<void> startAt({required int segmentId, required int atLocalUs}) =>
      api.startAt(segmentId, _toNativeNanos(atLocalUs));

  @override
  Future<void> pauseAt({required int segmentId, required int atLocalUs, int? thenSeekToUs}) =>
      api.pauseAt(segmentId, _toNativeNanos(atLocalUs), thenSeekToUs);

  @override
  Future<void> setRate(double rate) => api.setRate(rate.clamp(_caps.minRate, _caps.maxRate));

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
      fromAudioTimestamp: true,
    );
  }

  @override
  Stream<AudioBackendEvent> get events => _events.stream;

  /// Notification button presses ("play", "pause", "next", "previous").
  Stream<String> get notificationCommands => _commands.stream;

  /// Converter for [ConvertingTrackResolver]: decodes MP3 / ADTS AAC files
  /// into PCM WAV copies under [dir] (sample-exact seeking), keeping at most
  /// [maxCacheBytes] of copies (least recently used are deleted first).
  SourceConverter exactSeekConverter(Directory dir, {int maxCacheBytes = 2 * 1024 * 1024 * 1024}) =>
      (track, src) async {
        if (src.uri.scheme != 'file') return null;
        if (!needsExactSeekCopy(await readFileHead(File.fromUri(src.uri)))) return null;
        final out = File('${dir.path}/${track.id}.wav');
        if (await out.exists()) {
          await out.setLastModified(DateTime.now());
          return out.uri;
        }
        await dir.create(recursive: true);
        await _evict(dir, maxCacheBytes);
        try {
          final info = await api.exactCopy(src.uri.toString(), out.path);
          log?.info('track.decoded', 'decoded "${track.title}" to PCM for exact seeking',
              {'decoder': info['decoder'], 'sampleRate': info['sampleRate'], 'channels': info['channels']});
        } on PlatformException catch (e) {
          throw StateError(e.message ?? e.code);
        }
        return out.uri;
      };

  static Future<void> _evict(Directory dir, int maxBytes) async {
    final files = <File, FileStat>{};
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.wav')) files[e] = await e.stat();
    }
    var total = files.values.fold<int>(0, (a, s) => a + s.size);
    final oldest = files.keys.toList()..sort((a, b) => files[a]!.modified.compareTo(files[b]!.modified));
    for (final f in oldest) {
      if (total <= maxBytes) break;
      total -= files[f]!.size;
      try {
        await f.delete();
      } on FileSystemException {
        // In use or already gone.
      }
    }
  }

  /// Microphone recorder for acoustic calibration, sharing this backend's
  /// clock bridge.
  CalibrationRecorder calibrationRecorder({int sampleRate = 48000}) =>
      AndroidCalibrationRecorder(api: api, bridge: bridge, sampleRate: sampleRate, log: log);

  @override
  Future<void> dispose() async {
    _recalibrate?.cancel();
    await _nativeSub?.cancel();
    await api.stop();
    await _events.close();
    await _commands.close();
  }
}
