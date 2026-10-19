/// A speaker test sound: each part is on one channel only, so you can hear
/// which phone plays what. Most music puts voice, bass and drums in both
/// channels, so a left/right pair playing a song sounds much the same from
/// both phones; this does not.
///
/// One cycle (repeated):
/// 1. three low beeps (523 Hz) on the **left** channel only;
/// 2. three high beeps (784 Hz) on the **right** channel only;
/// 3. one tone (659 Hz) on both channels in phase: left, right and
///    **center** phones play it, surround phones stay silent;
/// 4. one tone (440 Hz) in anti-phase (R = −L): **surround** phones play it,
///    center phones stay silent.
///
/// The bytes are deterministic, so every phone generates the same file
/// (same SHA-256 track id).
library;

import 'dart:math';
import 'dart:typed_data';

const kSpeakerTestTitle = 'Speaker test';

Uint8List speakerTestWav({int sampleRate = 22050, int cycles = 4}) {
  final frames = <(double, double)>[];
  void silence(double s) {
    for (var i = 0; i < (s * sampleRate).round(); i++) {
      frames.add((0, 0));
    }
  }

  void tone(double hz, double s, {double left = 0, double right = 0}) {
    final n = (s * sampleRate).round();
    final fade = (0.005 * sampleRate).round();
    for (var i = 0; i < n; i++) {
      final env =
          i < fade ? 0.5 - 0.5 * cos(pi * i / fade) : (i >= n - fade ? 0.5 - 0.5 * cos(pi * (n - 1 - i) / fade) : 1.0);
      final v = 0.5 * env * sin(2 * pi * hz * i / sampleRate);
      frames.add((v * left, v * right));
    }
  }

  void beeps(double hz, {double left = 0, double right = 0}) {
    for (var k = 0; k < 3; k++) {
      tone(hz, 0.15, left: left, right: right);
      silence(0.1);
    }
  }

  for (var c = 0; c < cycles; c++) {
    beeps(523.25, left: 1);
    silence(0.6);
    beeps(783.99, right: 1);
    silence(0.6);
    tone(659.25, 0.6, left: 1, right: 1);
    silence(0.6);
    tone(440, 0.6, left: 1, right: -1);
    silence(1.0);
  }

  final dataBytes = frames.length * 4;
  final b = ByteData(44 + dataBytes);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 2, Endian.little); // stereo
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 4, Endian.little);
  b.setUint16(32, 4, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  var o = 44;
  for (final (l, r) in frames) {
    b.setInt16(o, (l * 32767).round(), Endian.little);
    b.setInt16(o + 2, (r * 32767).round(), Endian.little);
    o += 4;
  }
  return b.buffer.asUint8List();
}
