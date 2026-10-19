/// Finds calibration clicks in a microphone recording and turns their
/// arrival times into per-device calibration corrections.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../model/calibration_plan.dart';

/// A mono microphone recording with the local monotonic time (µs) of its
/// first sample. The timestamp only needs to be roughly right (tens of ms):
/// it locates the search windows; the result uses arrival *differences*.
class AudioRecording {
  final Int16List samples;
  final int sampleRate;
  final int firstSampleLocalUs;
  const AudioRecording({required this.samples, required this.sampleRate, required this.firstSampleLocalUs});

  int get durationUs => (samples.length * 1e6 / sampleRate).round();
}

class DeviceCalibration {
  final String deviceId;

  /// Arrival minus scheduled time per detected click, keyed by slot (µs,
  /// common recorder offset included).
  final Map<int, int> arrivalsBySlot;

  List<int> get arrivalsUs => arrivalsBySlot.values.toList();

  /// Correction to add to the device's calibration offset (µs). Positive:
  /// the device sounds late at the listener and must play earlier.
  final int? correctionUs;
  final int expectedClicks;

  /// Median click peak level in the recording (dBFS), null if not heard.
  final double? levelDb;

  const DeviceCalibration({
    required this.deviceId,
    required this.arrivalsBySlot,
    required this.correctionUs,
    required this.expectedClicks,
    this.levelDb,
  });

  bool get detected => correctionUs != null;

  /// Spread of the per-click arrivals (max − min), a consistency indicator.
  int get spreadUs => arrivalsUs.length < 2 ? 0 : arrivalsUs.reduce(math.max) - arrivalsUs.reduce(math.min);
}

class CalibrationOutcome {
  final List<DeviceCalibration> devices;
  const CalibrationOutcome(this.devices);

  Map<String, int> get corrections => {
        for (final d in devices)
          if (d.correctionUs != null) d.deviceId: d.correctionUs!
      };

  List<String> get undetected => [for (final d in devices) if (!d.detected) d.deviceId];
}

/// Analyzes [rec] for [plan]'s clicks.
///
/// [coordToLocal] converts coordinator time to the recorder's local clock;
/// the calibration segment started rendering track position
/// [anchorPositionUs] at coordinator time [anchorCoordUs].
CalibrationOutcome analyzeCalibration({
  required AudioRecording rec,
  required CalibrationPlan plan,
  required int Function(int coordUs) coordToLocal,
  required int anchorCoordUs,
  required int anchorPositionUs,
  double minSnr = 6.0,
}) {
  final rate = rec.sampleRate;
  final env = _envelope(rec.samples, math.max(1, rate ~/ 1000));
  final halfWindowUs = math.min(plan.intervalUs ~/ 2 - 30000, 280000);
  final halfWindow = (halfWindowUs * rate / 1e6).round();

  final perDevice = List.generate(plan.order.length, (_) => <int, int>{});
  final levels = List.generate(plan.order.length, (_) => <double>[]);
  for (var slot = 0; slot < plan.slotCount; slot++) {
    final coordT = anchorCoordUs + plan.slotPositionUs(slot) - anchorPositionUs;
    final localT = coordToLocal(coordT);
    final expected = ((localT - rec.firstSampleLocalUs) * rate / 1e6).round();
    final lo = expected - halfWindow, hi = expected + halfWindow;
    if (lo < 0 || hi >= rec.samples.length) continue;
    final onset = _detectOnset(rec.samples, env, lo, hi, rate, minSnr);
    if (onset == null) continue;
    perDevice[plan.deviceIndexOfSlot(slot)][slot] = ((onset - expected) * 1e6 / rate).round();
    var peak = 1;
    final end = math.min(rec.samples.length, onset + (plan.clickMs * 2 * rate / 1000).ceil() + 1);
    for (var i = onset; i < end; i++) {
      peak = math.max(peak, rec.samples[i].abs());
    }
    levels[plan.deviceIndexOfSlot(slot)].add(20 * math.log(peak / 32768) / math.ln10);
  }

  final needed = (plan.rounds + 1) ~/ 2;
  final medians = <int?>[
    for (final a in perDevice) a.length >= needed ? _median(a.values.toList()) : null,
  ];
  final present = medians.whereType<int>().toList();
  final reference = present.isEmpty ? 0 : _median(present);
  return CalibrationOutcome([
    for (var k = 0; k < plan.order.length; k++)
      DeviceCalibration(
        deviceId: plan.order[k],
        arrivalsBySlot: perDevice[k],
        correctionUs: medians[k] == null ? null : medians[k]! - reference,
        expectedClicks: plan.rounds,
        levelDb: levels[k].isEmpty ? null : (levels[k]..sort())[levels[k].length ~/ 2],
      ),
  ]);
}

/// Moving average of |x| over [win] samples.
Float64List _envelope(Int16List x, int win) {
  final out = Float64List(x.length);
  var acc = 0;
  for (var i = 0; i < x.length; i++) {
    acc += x[i].abs();
    if (i >= win) acc -= x[i - win].abs();
    out[i] = acc / win;
  }
  return out;
}

/// First-arrival onset (sample index) of the click in [lo, hi], or null if
/// nothing rises clearly above the window's background level.
int? _detectOnset(Int16List x, Float64List env, int lo, int hi, int rate, double minSnr) {
  var peak = 0.0;
  var peakAt = lo;
  for (var i = lo; i <= hi; i++) {
    if (env[i] > peak) {
      peak = env[i];
      peakAt = i;
    }
  }
  // Background: median envelope of the window (the click is a tiny part).
  final sorted = Float64List.sublistView(env, lo, hi + 1).toList()..sort();
  final noise = sorted[sorted.length ~/ 2];
  if (peak < minSnr * math.max(noise, 1.0)) return null;
  final thr = noise + 0.3 * (peak - noise);
  var cross = peakAt;
  for (var i = lo; i <= peakAt; i++) {
    if (env[i] >= thr) {
      cross = i;
      break;
    }
  }
  // Refine to the first sample exceeding 30 % of the local waveform peak:
  // the start of the burst rather than the smoothed envelope's rise.
  final win = math.max(1, rate ~/ 1000);
  final start = math.max(lo, cross - 2 * win);
  final end = math.min(hi, cross + rate ~/ 100);
  var local = 1;
  for (var i = start; i <= end; i++) {
    if (x[i].abs() > local) local = x[i].abs();
  }
  for (var i = start; i <= end; i++) {
    if (x[i].abs() >= 0.3 * local) return i;
  }
  return cross;
}

/// Combines raw per-click arrivals with each device's own software-estimated
/// playback error at the click time (from its sync reports) into
/// corrections. A device that is still converging (e.g. +120 ms ahead in
/// software at the click) sounds early by that amount; adding it back
/// leaves only the static offset: unreported output latency plus acoustic
/// propagation. Corrections are relative to the median device.
Map<String, int> combineCalibration({
  required CalibrationPlan plan,
  required Map<String, Map<int, int>> arrivalsBySlot,
  required int Function(String deviceId, int slot) softwareErrorAt,
}) {
  final needed = (plan.rounds + 1) ~/ 2;
  final staticOffset = <String, int>{};
  arrivalsBySlot.forEach((id, slots) {
    if (slots.length < needed) return;
    staticOffset[id] = _median([for (final e in slots.entries) e.value + softwareErrorAt(id, e.key)]);
  });
  if (staticOffset.isEmpty) return const {};
  final ref = _median(staticOffset.values.toList());
  return {for (final e in staticOffset.entries) e.key: e.value - ref};
}

int _median(List<int> v) {
  final s = List.of(v)..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : ((s[n ~/ 2 - 1] + s[n ~/ 2]) / 2).round();
}
