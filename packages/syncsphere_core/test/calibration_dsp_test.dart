import 'dart:math';
import 'dart:typed_data';

import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

/// Synthesizes what a microphone would record: each device's clicks arrive
/// late by [lateMs] (output latency + propagation), attenuated, with noise.
AudioRecording synthRecording(CalibrationPlan plan, List<double> lateMs,
    {int rate = 16000, int recStartUs = -200000, double noise = 300, List<double>? gains, int seed = 1}) {
  final rnd = Random(seed);
  final n = ((plan.durationUs - recStartUs + 500000) * rate / 1e6).round();
  final buf = Float64List(n);
  final click = clickWaveform(sampleRate: rate, hz: plan.clickHz, ms: plan.clickMs);
  for (var slot = 0; slot < plan.slotCount; slot++) {
    final k = plan.deviceIndexOfSlot(slot);
    final arrivalUs = plan.slotPositionUs(slot) + lateMs[k] * 1000 - recStartUs;
    final start = (arrivalUs * rate / 1e6).round();
    final g = gains?[k] ?? 1.0;
    for (var i = 0; i < click.length; i++) {
      if (start + i < n) buf[start + i] += click[i] * 20000 * g;
    }
    // A weaker room reflection 7 ms later must not move the onset.
    for (var i = 0; i < click.length; i++) {
      final j = start + (0.007 * rate).round() + i;
      if (j < n) buf[j] += click[i] * 6000 * g;
    }
  }
  final pcm = Int16List(n);
  for (var i = 0; i < n; i++) {
    final u1 = 1 - rnd.nextDouble(), u2 = rnd.nextDouble();
    final gauss = sqrt(-2 * log(u1)) * cos(2 * pi * u2);
    pcm[i] = (buf[i] + gauss * noise).round().clamp(-32768, 32767);
  }
  return AudioRecording(samples: pcm, sampleRate: rate, firstSampleLocalUs: recStartUs);
}

void main() {
  const plan = CalibrationPlan(id: 7, listener: 'dev-a', order: ['dev-a', 'dev-b', 'dev-c', 'dev-d']);

  test('plan geometry and stable track id', () {
    expect(plan.slotCount, 12);
    expect(plan.slotsOf(1).toList(), [1, 5, 9]);
    expect(plan.deviceIndexOfSlot(9), 1);
    expect(TrackInfo.isValidTrackId(plan.trackId), isTrue);
    expect(plan.trackId, const CalibrationPlan(id: 7, listener: 'dev-a', order: ['x']).trackId);
    final back = CalibrationPlan.fromJson(plan.toJson());
    expect(back.order, plan.order);
    expect(back.durationUs, plan.durationUs);
  });

  test('click track contains clicks only in the device own slots, WAV round trip', () {
    const rate = 8000;
    final pcm = calibrationSamples(plan, 2, sampleRate: rate);
    bool loudAt(int slot) {
      final i = (plan.slotPositionUs(slot) * rate / 1e6).round();
      return pcm.sublist(i, i + 32).any((v) => v.abs() > 1000);
    }

    expect(plan.slotsOf(2).every(loudAt), isTrue);
    expect([0, 1, 3, 4, 5, 7].any(loudAt), isFalse);
    final wav = encodeWav(pcm, sampleRate: rate);
    final back = decodeWav(wav);
    expect(back.sampleRate, rate);
    expect(back.samples, pcm);
    expect(() => decodeWav(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });

  test('recovers relative device delays to within a fraction of a millisecond', () {
    final late = [12.0, 3.5, 190.0, 47.25]; // device c is a Bluetooth speaker
    final rec = synthRecording(plan, late, gains: [1.0, 0.4, 0.7, 0.25]);
    final out = analyzeCalibration(
      rec: rec,
      plan: plan,
      coordToLocal: (c) => c, // recorder clock == coordinator clock here
      anchorCoordUs: 0,
      anchorPositionUs: 0,
    );
    expect(out.undetected, isEmpty);
    final sortedLate = List.of(late)..sort();
    final median = (sortedLate[1] + sortedLate[2]) / 2;
    for (var k = 0; k < 4; k++) {
      final expected = (late[k] - median) * 1000;
      expect(out.corrections[plan.order[k]]!, closeTo(expected, 400), reason: plan.order[k]);
    }
  });

  test('a common recording offset or a wrong recorder timestamp does not change corrections', () {
    final late = [10.0, 30.0, 20.0, 0.0];
    CalibrationOutcome run(int recorderTimestampErrorUs) => analyzeCalibration(
          rec: synthRecording(plan, late),
          plan: plan,
          coordToLocal: (c) => c + recorderTimestampErrorUs,
          anchorCoordUs: 0,
          anchorPositionUs: 0,
        );
    final a = run(0).corrections, b = run(40000).corrections;
    for (final id in plan.order) {
      expect(b[id]!, closeTo(a[id]!, 200));
    }
  });

  test('a silent device is reported as undetected, others still calibrate', () {
    final rec = synthRecording(plan, [5, 5, 5, 5], gains: [1, 1, 0, 1]);
    final out = analyzeCalibration(
        rec: rec, plan: plan, coordToLocal: (c) => c, anchorCoordUs: 0, anchorPositionUs: 0);
    expect(out.undetected, ['dev-c']);
    expect(out.corrections.length, 3);
  });
}
