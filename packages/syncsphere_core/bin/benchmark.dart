/// Reproducible SIMULATED benchmark suite.
///
///     dart run bin/benchmark.dart --suite quick --out ../../benchmarks/out
///     dart run bin/benchmark.dart --suite full  --out ../../benchmarks/results/simulated
///
/// Writes, per scenario, `<name>.json` (scenario + metrics) and
/// `<name>.samples.jsonl` (ground-truth error samples, subsampled), plus
/// `summary.json` and `summary.md`. Everything is deterministic for a given
/// seed. These numbers come from modelled devices and networks; they are
/// not, and must never be reported as, real hardware measurements. See
/// `docs/benchmarking.md` for the real-device procedure.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

const _controls = [
  ScheduledAction(Duration(seconds: 3), PlayAction()),
  ScheduledAction(Duration(seconds: 40), PauseAction()),
  ScheduledAction(Duration(seconds: 46), PlayAction()),
  ScheduledAction(Duration(seconds: 70), SeekAction(Duration(minutes: 3))),
  ScheduledAction(Duration(seconds: 95), NextTrackAction()),
];

List<Scenario> _suite(String name, int seed) {
  final out = <Scenario>[];
  final counts = name == 'quick' ? [2, 5] : [2, 3, 5, 10];
  final nets = name == 'quick'
      ? [NetworkCondition.wifiGood, NetworkCondition.wifiCongested]
      : NetworkCondition.all;
  for (final net in nets) {
    for (final n in counts) {
      out.add(Scenario(
        name: 'matrix-${net.name}-n$n',
        participants: n,
        network: net,
        duration: const Duration(seconds: 120),
        actions: _controls,
        seed: seed + n,
      ));
    }
  }
  out.addAll([
    Scenario(
      name: 'partition-recovery-n5',
      participants: 5,
      network: NetworkCondition.wifiTypical,
      duration: const Duration(seconds: 120),
      actions: const [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 30), PartitionAction(2, Duration(seconds: 5))),
        ScheduledAction(Duration(seconds: 60), PartitionAction(3, Duration(seconds: 20))),
      ],
      seed: seed,
    ),
    Scenario(
      name: 'coordinator-failure-n3',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: const Duration(minutes: 6),
      actions: const [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 30), KillCoordinatorAction()),
      ],
      seed: seed,
    ),
    Scenario(
      name: 'coordinator-failover-n5',
      participants: 5,
      network: NetworkCondition.wifiTypical,
      duration: const Duration(seconds: 120),
      failover: true,
      actions: const [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 30), KillCoordinatorAction()),
        ScheduledAction(Duration(seconds: 70), SeekAction(Duration(minutes: 2))),
        ScheduledAction(Duration(seconds: 90), KillCoordinatorAction()),
      ],
      seed: seed,
    ),
    Scenario(
      name: 'heterogeneous-devices-n5',
      participants: 5,
      network: NetworkCondition.wifiTypical,
      duration: const Duration(minutes: 5),
      profiles: const [DeviceAudioProfile.flagship, DeviceAudioProfile.midrange, DeviceAudioProfile.lowEnd],
      actions: _controls,
      seed: seed,
    ),
    Scenario(
      name: 'bluetooth-uncalibrated-n2',
      participants: 2,
      network: NetworkCondition.wifiGood,
      duration: const Duration(seconds: 90),
      profiles: const [DeviceAudioProfile.flagship, DeviceAudioProfile.bluetoothUncalibrated],
      seed: seed,
    ),
    Scenario(
      name: 'bluetooth-calibrated-n2',
      participants: 2,
      network: NetworkCondition.wifiGood,
      duration: const Duration(seconds: 90),
      profiles: const [DeviceAudioProfile.flagship, DeviceAudioProfile.bluetoothUncalibrated],
      outputCalibrationUs: const [0, 180000],
      seed: seed,
    ),
    Scenario(
      name: 'drift-uncorrected-n3',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(minutes: name == 'quick' ? 10 : 60),
      clockSkewPpmRange: 100,
      audioPpmRange: 80,
      // Thresholds so large that no correction ever happens: shows raw drift.
      config: const SyncConfig(
        drift: DriftConfig(
          rateEnterThreshold: Duration(seconds: 50),
          rateExitThreshold: Duration(seconds: 40),
          seekThreshold: Duration(seconds: 59),
          seekThresholdNoRate: Duration(seconds: 59),
        ),
      ),
      seed: seed,
    ),
    Scenario(
      name: 'drift-corrected-n3',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: Duration(minutes: name == 'quick' ? 10 : 60),
      clockSkewPpmRange: 100,
      audioPpmRange: 80,
      seed: seed,
    ),
  ]);
  return out;
}

Future<void> main(List<String> argv) async {
  final p = ArgParser()
    ..addOption('suite', allowed: ['quick', 'full'], defaultsTo: 'quick')
    ..addOption('out', defaultsTo: '../../benchmarks/out')
    ..addOption('seed', defaultsTo: '42')
    ..addOption('only', help: 'Run only scenarios whose name contains this')
    ..addOption('sample-every', defaultsTo: '4', help: 'Keep every Nth truth sample in the raw file');
  final a = p.parse(argv);
  final outDir = Directory(a['out'] as String)..createSync(recursive: true);
  final seed = int.parse(a['seed'] as String);
  final every = int.parse(a['sample-every'] as String);
  var scenarios = _suite(a['suite'] as String, seed);
  if (a['only'] != null) scenarios = scenarios.where((s) => s.name.contains(a['only'] as String)).toList();

  final summary = <Map<String, Object?>>[];
  for (final sc in scenarios) {
    final sw = Stopwatch()..start();
    final r = SimulationRunner(sc).run();
    final json = r.toJson()..['wallClockMs'] = sw.elapsedMilliseconds;
    File('${outDir.path}/${sc.name}.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    final raw = StringBuffer();
    for (var i = 0; i < r.samples.length; i += every) {
      final s = r.samples[i];
      raw.writeln(jsonEncode({'t': s.trueUs, 'gen': s.generation, 'err': s.errors}));
    }
    File('${outDir.path}/${sc.name}.samples.jsonl').writeAsStringSync(raw.toString());
    final m = r.metrics;
    Map<String, Object?> q(String k) => (m[k] as Map).cast<String, Object?>();
    summary.add({
      'scenario': sc.name,
      'n': sc.participants,
      'network': sc.network.name,
      'durationS': sc.duration.inSeconds,
      'spreadSteady': q('interDeviceSpreadMs_steady'),
      'spreadAll': q('interDeviceSpreadMs_all'),
      'startSkew': q('startSkewMs'),
      'driftLastMinute': q('driftSpreadLastMinuteMs'),
      'commandLatency': q('commandToAudibleLatencyMs'),
      'clockErrUs': q('clockOffsetErrorUs'),
      'clockUncUs': q('clockUncertaintyUs'),
      'coverage': m['clockUncertaintyCoverage'],
      'recovery': q('recoveryAfterPartitionMs'),
      'resyncs': m['resyncSeeks'],
      'stalls': m['bufferingStalls'],
      'bytesPerDevPerS': m['networkBytesPerDevicePerSecond'],
      'failed': (m['failedSessions'] as List).length,
      if (m['failover'] != null) 'failover': m['failover'],
    });
    stdout.writeln('${sc.name.padRight(36)} spread p50/p95/max '
        '${_f(q('interDeviceSpreadMs_steady'), 'median')}/${_f(q('interDeviceSpreadMs_steady'), 'p95')}/${_f(q('interDeviceSpreadMs_steady'), 'max')} ms  '
        'start skew p50 ${_f(q('startSkewMs'), 'median')} ms  (${sw.elapsedMilliseconds} ms wall)');
  }
  final meta = {
    'environment': 'SIMULATED — virtual time, modelled clocks/network/audio devices. NOT hardware measurements.',
    'suite': a['suite'],
    'seed': seed,
    'dart': Platform.version,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
  };
  File('${outDir.path}/summary.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({...meta, 'results': summary}));
  File('${outDir.path}/summary.md').writeAsStringSync(_markdown(meta, summary));
  stdout.writeln('\nwrote ${scenarios.length} scenarios to ${outDir.path}');
}

String _f(Map<String, Object?> m, String k) {
  final v = m[k];
  return v == null ? '–' : (v as num).toStringAsFixed(1);
}

String _markdown(Map<String, Object?> meta, List<Map<String, Object?>> rows) {
  final b = StringBuffer()
    ..writeln('# SyncSphere simulated benchmark results')
    ..writeln()
    ..writeln('> **${meta['environment']}**  ')
    ..writeln('> suite `${meta['suite']}`, seed `${meta['seed']}`, generated ${meta['generatedAt']}  ')
    ..writeln('> Spread = max − min acoustic (ground-truth) position error across devices at the same instant, '
        'sampled every 50 ms. "Steady" excludes 3 s after each timeline change.')
    ..writeln()
    ..writeln('| scenario | n | network | spread p50 | spread p95 | spread p99 | spread max | start skew p50 | start skew max | last-min p95 | cmd→audible p50 | clock err p95 (µs) | unc. coverage | recovery max | resyncs | failed |')
    ..writeln('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|');
  for (final r in rows) {
    Map<String, Object?> m(String k) => r[k] as Map<String, Object?>;
    b.writeln('| ${r['scenario']} | ${r['n']} | ${r['network']} | '
        '${_f(m('spreadSteady'), 'median')} | ${_f(m('spreadSteady'), 'p95')} | ${_f(m('spreadSteady'), 'p99')} | ${_f(m('spreadSteady'), 'max')} | '
        '${_f(m('startSkew'), 'median')} | ${_f(m('startSkew'), 'max')} | ${_f(m('driftLastMinute'), 'p95')} | '
        '${_f(m('commandLatency'), 'median')} | ${_f(m('clockErrUs'), 'p95')} | ${r['coverage'] ?? '–'} | '
        '${_f(m('recovery'), 'max')} | ${r['resyncs']} | ${r['failed']} |');
  }
  final fo = rows.where((r) => r['failover'] != null).toList();
  if (fo.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Coordinator failover (SIMULATED)')
      ..writeln()
      ..writeln('| scenario | final epoch | last promoted | promoted after kill (ms) | spread p95 / max in 15 s after promotion (ms) |')
      ..writeln('|---|---|---|---|---|');
    for (final r in fo) {
      final f = r['failover'] as Map<String, Object?>;
      final sp = f['spreadMs_15sAfterPromotion'] as Map<String, Object?>;
      b.writeln('| ${r['scenario']} | ${f['finalEpoch']} | ${f['promoted']} | ${f['promotedAfterKillMs']} | '
          '${_f(sp, 'p95')} / ${_f(sp, 'max')} |');
    }
  }
  b
    ..writeln()
    ..writeln('All times in ms unless noted. Raw per-sample data: `<scenario>.samples.jsonl`; '
        'recompute with `tools/analyze_samples.py`.');
  return b.toString();
}
