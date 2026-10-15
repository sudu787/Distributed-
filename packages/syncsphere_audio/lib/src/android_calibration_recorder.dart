import 'dart:io';

import 'package:flutter/services.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import 'native_audio_api.dart';

/// [CalibrationRecorder] using Android's AudioRecord (see MicRecorder.kt).
///
/// Times cross the channel as `System.nanoTime()`; [bridge] converts them to
/// and from the Dart monotonic clock the calibration analysis works in.
class AndroidCalibrationRecorder implements CalibrationRecorder {
  final NativeAudioApi api;
  final ClockDomainBridge bridge;
  final int sampleRate;
  final EventLog? log;

  AndroidCalibrationRecorder({required this.api, required this.bridge, this.sampleRate = 48000, this.log});

  @override
  Future<AudioRecording> record({required int startAtLocalUs, required int durationUs}) async {
    if (!await api.requestPermission('microphone')) {
      throw const CalibrationRecorderException('microphone permission denied');
    }
    final Map<String, Object?> info;
    try {
      info = await api.recordMic(bridge.toRemote(startAtLocalUs) * 1000, (durationUs / 1000).ceil(), sampleRate);
    } on PlatformException catch (e) {
      throw CalibrationRecorderException(e.message ?? e.code);
    }
    final file = File(info['path']! as String);
    try {
      final wav = decodeWav(await file.readAsBytes());
      final first = bridge.toLocal((info['firstSampleNanos']! as num).toInt() ~/ 1000);
      log?.info('calibration.mic', 'recorded ${wav.samples.length} samples @ ${wav.sampleRate} Hz',
          {'timestamp': info['timestampSource']});
      return AudioRecording(samples: wav.samples, sampleRate: wav.sampleRate, firstSampleLocalUs: first);
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

class CalibrationRecorderException implements Exception {
  final String message;
  const CalibrationRecorderException(this.message);
  @override
  String toString() => message;
}
