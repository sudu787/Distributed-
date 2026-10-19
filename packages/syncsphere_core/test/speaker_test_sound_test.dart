import 'dart:typed_data';

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

void main() {
  test('speaker test sound: valid WAV, left part left-only, right part right-only, anti-phase part R = -L', () {
    const rate = 22050;
    final wav = speakerTestWav(sampleRate: rate, cycles: 1);
    final b = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(b.getUint16(22, Endian.little), 2);
    expect(b.getUint32(24, Endian.little), rate);
    expect(b.getUint32(40, Endian.little), wav.length - 44);
    (int, int) frame(double s) {
      final o = 44 + (s * rate).round() * 4;
      return (b.getInt16(o, Endian.little), b.getInt16(o + 2, Endian.little));
    }

    // Left beeps: 0–0.75 s; right beeps start at 1.35 s; in phase at
    // 2.7 s; anti-phase at 3.9 s (see the layout in channel_test.dart).
    var leftEnergy = 0, leakR = 0;
    for (var s = 0.01; s < 0.14; s += 0.001) {
      final (l, r) = frame(s);
      leftEnergy += l.abs();
      leakR += r.abs();
    }
    expect(leftEnergy, greaterThan(100000));
    expect(leakR, 0);
    var rightEnergy = 0, leakL = 0;
    for (var s = 1.36; s < 1.49; s += 0.001) {
      final (l, r) = frame(s);
      rightEnergy += r.abs();
      leakL += l.abs();
    }
    expect(rightEnergy, greaterThan(100000));
    expect(leakL, 0);
    for (var s = 2.71; s < 3.2; s += 0.01) {
      final (l, r) = frame(s);
      expect(r, l);
    }
    for (var s = 3.91; s < 4.4; s += 0.01) {
      final (l, r) = frame(s);
      expect(r, -l);
    }
  });

  test('every phone generates the same bytes (same track id)', () {
    expect(speakerTestWav(), speakerTestWav());
  });
}
