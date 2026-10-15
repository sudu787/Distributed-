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
  Stream<Map<String, Object?>> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .map((e) => (e as Map).cast<String, Object?>());
}
