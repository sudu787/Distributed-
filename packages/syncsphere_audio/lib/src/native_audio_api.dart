import 'dart:async';

import 'package:flutter/services.dart';

/// Thin, typed wrapper over the `dev.syncsphere/audio` platform channel.
/// Abstract so the backend logic can be tested with a fake.
abstract class NativeAudioApi {
  Future<int> nowNanos();
  Future<Map<String, Object?>> init();
  Future<void> prepare(int segment, String uri, int positionUs);
  Future<void> startAt(int segment, int atNanos);
  Future<void> pauseAt(int segment, int atNanos, int? seekToUs);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<Map<String, Object?>?> sample();
  Future<Map<String, Object?>> acquireNetworkLocks();
  Future<void> releaseNetworkLocks();
  Future<bool> keepScreenOn(bool on);

  /// Duration and tags of a local file via MediaMetadataRetriever.
  Future<Map<String, Object?>> probe(String uri);

  /// "stereo", "left", "right" or "mono"; applies to newly prepared segments.
  Future<void> setChannelRole(String role);

  /// Runtime permission ("microphone", "notifications" or "audio"); true if
  /// granted.
  Future<bool> requestPermission(String name);

  /// Records mono PCM16 to a WAV file starting at `System.nanoTime() ==
  /// startAtNanos`. Returns {path, sampleRate, firstSampleNanos, timestampSource}.
  Future<Map<String, Object?>> recordMic(int startAtNanos, int durationMs, int sampleRate);

  /// Foreground service + media notification for background playback.
  Future<void> startService(String title, String text, bool playing);
  Future<bool> updateService(String title, String text, bool playing);
  Future<void> stopService();

  /// Decodes [uri] into a 16-bit PCM WAV at [outPath] (sample-exact
  /// seeking). Returns {path, sampleRate, channels, durationUs, decoder}.
  Future<Map<String, Object?>> exactCopy(String uri, String outPath);

  /// Writes the embedded cover picture of [uri] as a JPEG (at most 512 px)
  /// to [outPath]. Returns false when the file has no picture.
  Future<bool> extractArtwork(String uri, String outPath);

  /// Sends the app to the background without closing it.
  Future<bool> moveToBack();

  /// Songs in the phone's music collection (MediaStore); needs the "audio"
  /// permission. Each: {uri, title, artist, album, albumId, durationMs,
  /// size, mime, name}.
  Future<List<Map<String, Object?>>> queryAudio();

  /// Copies a content:// URI to [outPath]; returns the number of bytes.
  Future<int> copyContent(String uri, String outPath);

  /// Audio shared to the app ("Share → SyncSphere") since the last call:
  /// [{uri, name, size, mime}]. A `{kind: "shared"}` event announces new
  /// shares while the app runs.
  Future<List<Map<String, Object?>>> takeSharedAudio();

  Stream<Map<String, Object?>> get events;
}

class MethodChannelAudioApi implements NativeAudioApi {
  static const _channel = MethodChannel('dev.syncsphere/audio');
  static const _events = EventChannel('dev.syncsphere/audio_events');
  Stream<Map<String, Object?>>? _eventStream;

  @override
  Future<int> nowNanos() async => (await _channel.invokeMethod<int>('nowNanos'))!;

  @override
  Future<Map<String, Object?>> init() async =>
      (await _channel.invokeMapMethod<String, Object?>('init')) ?? const {};

  @override
  Future<void> prepare(int segment, String uri, int positionUs) =>
      _channel.invokeMethod<void>('prepare', {'segment': segment, 'uri': uri, 'positionUs': positionUs});

  @override
  Future<void> startAt(int segment, int atNanos) =>
      _channel.invokeMethod<void>('startAt', {'segment': segment, 'atNanos': atNanos});

  @override
  Future<void> pauseAt(int segment, int atNanos, int? seekToUs) => _channel.invokeMethod<void>(
      'pauseAt', {'segment': segment, 'atNanos': atNanos, if (seekToUs != null) 'seekToUs': seekToUs});

  @override
  Future<void> setRate(double rate) => _channel.invokeMethod<void>('setRate', {'rate': rate});

  @override
  Future<void> setVolume(double volume) => _channel.invokeMethod<void>('setVolume', {'volume': volume});

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<Map<String, Object?>?> sample() => _channel.invokeMapMethod<String, Object?>('sample');

  @override
  Future<Map<String, Object?>> acquireNetworkLocks() async =>
      (await _channel.invokeMapMethod<String, Object?>('acquireNetworkLocks')) ?? const {};

  @override
  Future<void> releaseNetworkLocks() => _channel.invokeMethod<void>('releaseNetworkLocks');

  @override
  Future<bool> keepScreenOn(bool on) async =>
      (await _channel.invokeMethod<bool>('keepScreenOn', {'on': on})) ?? false;

  @override
  Future<Map<String, Object?>> probe(String uri) async =>
      (await _channel.invokeMapMethod<String, Object?>('probe', {'uri': uri})) ?? const {};

  @override
  Future<void> setChannelRole(String role) => _channel.invokeMethod<void>('setChannelRole', {'role': role});

  @override
  Future<bool> extractArtwork(String uri, String outPath) async =>
      (await _channel.invokeMethod<bool>('extractArtwork', {'uri': uri, 'out': outPath})) ?? false;

  @override
  Future<bool> moveToBack() async => (await _channel.invokeMethod<bool>('moveToBack')) ?? false;

  @override
  Future<List<Map<String, Object?>>> queryAudio() async => [
        for (final e in await _channel.invokeListMethod<Object?>('queryAudio') ?? const <Object?>[])
          if (e is Map) e.cast<String, Object?>()
      ];

  @override
  Future<int> copyContent(String uri, String outPath) async =>
      (await _channel.invokeMethod<int>('copyContent', {'uri': uri, 'out': outPath})) ?? 0;

  @override
  Future<List<Map<String, Object?>>> takeSharedAudio() async => [
        for (final e in await _channel.invokeListMethod<Object?>('takeSharedAudio') ?? const <Object?>[])
          if (e is Map) e.cast<String, Object?>()
      ];

  @override
  Future<bool> requestPermission(String name) async =>
      (await _channel.invokeMethod<bool>('requestPermission', {'name': name})) ?? false;

  @override
  Future<Map<String, Object?>> recordMic(int startAtNanos, int durationMs, int sampleRate) async =>
      (await _channel.invokeMapMethod<String, Object?>(
          'recordMic', {'startAtNanos': startAtNanos, 'durationMs': durationMs, 'sampleRate': sampleRate}))!;

  @override
  Future<void> startService(String title, String text, bool playing) =>
      _channel.invokeMethod<void>('startService', {'title': title, 'text': text, 'playing': playing});

  @override
  Future<bool> updateService(String title, String text, bool playing) async =>
      (await _channel.invokeMethod<bool>('updateService', {'title': title, 'text': text, 'playing': playing})) ??
      false;

  @override
  Future<void> stopService() => _channel.invokeMethod<void>('stopService');

  @override
  Future<Map<String, Object?>> exactCopy(String uri, String outPath) async =>
      (await _channel.invokeMapMethod<String, Object?>('exactCopy', {'uri': uri, 'out': outPath}))!;

  @override
  Stream<Map<String, Object?>> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .map((e) => (e as Map).cast<String, Object?>());
}
