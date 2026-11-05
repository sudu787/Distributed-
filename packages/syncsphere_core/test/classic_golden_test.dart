/// Classic must stay exactly the October 18 engine: these simulations were
/// recorded with the October 18 code (commit 5c83c86) before the engine
/// layer existed, and every ground-truth sample must still be identical.
/// If this fails, a change reached the Classic path; that is a regression
/// even if the numbers look better.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:syncsphere_core/syncsphere_core.dart';
import 'package:test/test.dart';

const _controls = [
  ScheduledAction(Duration(seconds: 3), PlayAction()),
  ScheduledAction(Duration(seconds: 40), PauseAction()),
  ScheduledAction(Duration(seconds: 46), PlayAction()),
  ScheduledAction(Duration(seconds: 70), SeekAction(Duration(minutes: 3))),
  ScheduledAction(Duration(seconds: 95), NextTrackAction()),
];

/// Same hashing as `bin/benchmark.dart` writes `*.samples.jsonl` (every 4th
/// sample, one JSON object per line).
String _samplesHash(SimulationResult r) {
  final raw = StringBuffer();
  for (var i = 0; i < r.samples.length; i += 4) {
    final s = r.samples[i];
    raw.writeln(jsonEncode({'t': s.trueUs, 'gen': s.generation, 'err': s.errors}));
  }
  return sha256.convert(utf8.encode(raw.toString())).toString();
}

void main() {
  test('Classic: Wi-Fi good, 2 phones, play/pause/seek/next (quick suite, seed 42)', () {
    final r = SimulationRunner(const Scenario(
      name: 'matrix-wifi-good-n2',
      participants: 2,
      network: NetworkCondition.wifiGood,
      duration: Duration(seconds: 120),
      actions: _controls,
      seed: 44,
    )).run();
    expect(_samplesHash(r), '462330a693f0078bb08f343d02008f7e42cb920147c63bf87c04b1628edf9f2c');
  });

  test('Classic: 5 mixed phones incl. one without rate control (quick suite, seed 42)', () {
    final r = SimulationRunner(const Scenario(
      name: 'heterogeneous-devices-n5',
      participants: 5,
      network: NetworkCondition.wifiTypical,
      duration: Duration(minutes: 5),
      profiles: [DeviceAudioProfile.flagship, DeviceAudioProfile.midrange, DeviceAudioProfile.lowEnd],
      actions: _controls,
      seed: 42,
    )).run();
    expect(_samplesHash(r), '0ece15ecb68ded027b33277b4b4e43b100cd9cabc8c694e38b30c131c31b6059');
  });
}
