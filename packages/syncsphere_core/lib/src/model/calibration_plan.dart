/// Acoustic room calibration ("calibrate to this spot").
///
/// One device (the *listener*) records with its microphone while every
/// device plays a personalized click track as an ordinary synchronized
/// timeline segment: device *k* clicks only in slots `r·N + k` (round *r*,
/// *N* devices), so every click in the recording has a known owner and a
/// known timeline position. The listener measures each click's arrival
/// relative to its scheduled time. Arrival differences between devices are
/// exactly what a person at the listener's position hears: they include
/// unreported output latency (Bluetooth, DSP) *and* acoustic propagation.
/// Only differences are used, so the recorder's own latency cancels.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../protocol/reader.dart';

class CalibrationPlan {
  final int id;

  /// Device recording the clicks.
  final String listener;

  /// Devices in slot order.
  final List<String> order;

  /// Silence before the first click, long enough for drift correction to
  /// settle after the synchronized start.
  final int leadInUs;

  /// Spacing between consecutive slots.
  final int intervalUs;
  final int rounds;
  final int clickHz;
  final int clickMs;

  const CalibrationPlan({
    required this.id,
    required this.listener,
    required this.order,
    this.leadInUs = 6000000,
    this.intervalUs = 600000,
    this.rounds = 3,
    this.clickHz = 2000,
    this.clickMs = 4,
  });

  /// Deterministic, well-formed track id for the calibration segment.
  String get trackId => sha256.convert(utf8.encode('syncsphere-calibration-v1|$id|$listener')).toString();

  int get slotCount => rounds * order.length;

  /// Track duration including a one-second tail.
  int get durationUs => leadInUs + slotCount * intervalUs + 1000000;

  /// Track position of slot [slot] (round-major).
  int slotPositionUs(int slot) => leadInUs + slot * intervalUs;

  /// Slots belonging to device index [k].
  Iterable<int> slotsOf(int k) sync* {
    for (var r = 0; r < rounds; r++) {
      yield r * order.length + k;
    }
  }

  int deviceIndexOfSlot(int slot) => slot % order.length;

  Map<String, Object?> toJson() => {
        'id': id,
        'listener': listener,
        'order': order,
        'leadUs': leadInUs,
        'ivUs': intervalUs,
        'rounds': rounds,
        'hz': clickHz,
        'ms': clickMs,
      };

  factory CalibrationPlan.fromJson(Map<String, Object?> j) {
    final r = Reader(j, 'calibration');
    return CalibrationPlan(
      id: r.integer('id', min: 0),
      listener: r.string('listener', maxLength: 64),
      order: r.stringList('order', maxLength: 64, maxItemLength: 64),
      leadInUs: r.integer('leadUs', min: 1000000, max: 30000000),
      intervalUs: r.integer('ivUs', min: 200000, max: 3000000),
      rounds: r.integer('rounds', min: 1, max: 10),
      clickHz: r.integer('hz', min: 200, max: 8000),
      clickMs: r.integer('ms', min: 1, max: 50),
    );
  }
}
