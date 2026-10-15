/// Personalized calibration click tracks (PCM16 mono WAV).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../model/calibration_plan.dart';

/// One raised-cosine tone burst, the click shape used by both the track
/// generator and the simulator's virtual microphone.
Float64List clickWaveform({required int sampleRate, int hz = 2000, int ms = 4, double amplitude = 0.8}) {
  final n = math.max(2, (sampleRate * ms / 1000).round());
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    final env = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
    out[i] = amplitude * env * math.sin(2 * math.pi * hz * i / sampleRate);
  }
  return out;
}

/// PCM samples of device [deviceIndex]'s calibration track: silence except
/// for clicks at the device's own slot positions.
Int16List calibrationSamples(CalibrationPlan plan, int deviceIndex, {int sampleRate = 48000}) {
  if (deviceIndex < 0 || deviceIndex >= plan.order.length) {
    throw RangeError.index(deviceIndex, plan.order, 'deviceIndex');
  }
  final total = (plan.durationUs * sampleRate / 1e6).ceil();
  final pcm = Int16List(total);
  final click = clickWaveform(sampleRate: sampleRate, hz: plan.clickHz, ms: plan.clickMs);
  for (final slot in plan.slotsOf(deviceIndex)) {
    final start = (plan.slotPositionUs(slot) * sampleRate / 1e6).round();
    for (var i = 0; i < click.length && start + i < total; i++) {
      pcm[start + i] = (click[i] * 32767).round();
    }
  }
  return pcm;
}

/// Encodes mono PCM16 samples as a WAV file.
Uint8List encodeWav(Int16List pcm, {required int sampleRate}) {
  final dataBytes = pcm.length * 2;
  final b = ByteData(44 + dataBytes);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little); // PCM chunk size
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < pcm.length; i++) {
    b.setInt16(44 + i * 2, pcm[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Decodes a mono or multichannel PCM16 WAV, returning channel 0.
/// Throws [FormatException] for anything else.
({Int16List samples, int sampleRate}) decodeWav(Uint8List bytes) {
  if (bytes.length < 44) throw const FormatException('WAV too short');
  final b = ByteData.sublistView(bytes);
  String tag(int off) => String.fromCharCodes(bytes.sublist(off, off + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('not a RIFF/WAVE file');
  var off = 12;
  int? channels, rate, bits;
  while (off + 8 <= bytes.length) {
    final id = tag(off);
    final size = b.getUint32(off + 4, Endian.little);
    final body = off + 8;
    if (id == 'fmt ') {
      if (b.getUint16(body, Endian.little) != 1) throw const FormatException('only PCM WAV is supported');
      channels = b.getUint16(body + 2, Endian.little);
      rate = b.getUint32(body + 4, Endian.little);
      bits = b.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (channels == null || rate == null || bits != 16) {
        throw const FormatException('expected 16-bit PCM fmt chunk before data');
      }
      final end = math.min(bytes.length, body + size);
      final frames = (end - body) ~/ (2 * channels);
      final out = Int16List(frames);
      for (var i = 0; i < frames; i++) {
        out[i] = b.getInt16(body + i * 2 * channels, Endian.little);
      }
      return (samples: out, sampleRate: rate);
    }
    off = body + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('no data chunk');
}
