/// Reproducible SIMULATED benchmark suite.
///
///     dart run bin/benchmark.dart --suite quick --out ../../benchmarks/out
///     dart run bin/benchmark.dart --suite full  --out ../../benchmarks/results/simulated
///     dart run bin/benchmark.dart --suite engines --out ../../benchmarks/out/engines
///     dart run bin/benchmark.dart --suite engines --profiles phones.json
///
/// `engines` compares the three sync engines on phone-like devices (output
/// standby, ExoPlayer report smoothing). `--profiles` replaces those
/// modelled phones with profiles exported from real phones (Diagnostics →
/// Export phone profile; a single export, a list of them, or diagnostics
/// reports that contain one).
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

/// Play, pause long enough for the output to sleep, resume, seek, next.
const _engineControls = [
  ScheduledAction(Duration(seconds: 3), PlayAction()),
  ScheduledAction(Duration(seconds: 30), PauseAction()),
  ScheduledAction(Duration(seconds: 38), PlayAction()),
  ScheduledAction(Duration(seconds: 60), SeekAction(Duration(minutes: 2))),
  ScheduledAction(Duration(seconds: 80), NextTrackAction()),
];

List<Scenario> _engineSuite(int seed, List<DeviceAudioProfile>? measured) {
  final profiles = measured ??
      const [DeviceAudioProfile.phoneFlagship, DeviceAudioProfile.phoneMidrange, DeviceAudioProfile.phoneLowEnd];
  final set = measured == null ? 'phones' : 'measured';
  return [
    for (final engine in SyncEngineMode.values)
      for (final net in [NetworkCondition.wifiGood, NetworkCondition.wifiTypical])
        for (final n in [3, 5])
          Scenario(
            name: 'engines-${engine.name}-$set-${net.name}-n$n',
            participants: n,
            network: net,
            duration: const Duration(seconds: 110),
            profiles: profiles,
            engine: engine,
            actions: _engineControls,
            seed: seed + n,
          ),
  ];
}

/// Profiles from a file written by Diagnostics → Export phone profile.
List<DeviceAudioProfile> _loadProfiles(String path) {
  final Object? json = jsonDecode(File(path).readAsStringSync());
  final items = json is List ? json : [json];
  final out = <DeviceAudioProfile>[];
  for (final it in items) {
    if (it is! Map) continue;
    final m = it.cast<String, Object?>();
    final p = m['phoneProfile'] ?? m['profile'] ?? m;
    if (p is Map) out.add(DeviceAudioProfile.fromJson(p.cast<String, Object?>()));
  }
  if (out.isEmpty) throw FormatException('no phone profiles in $path');
  return out;
}

List<Scenario> _suite(String name, int seed, {List<DeviceAudioProfile>? measured}) {
  if (name == 'engines') return _engineSuite(seed, measured);
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
    // Host dies, the next phone takes over, the host comes back and gets the
    // role back after 10 s of stable connection (planned handover).
    Scenario(
      name: 'failover-failback-n3',
      participants: 3,
      network: NetworkCondition.wifiTypical,
      duration: const Duration(seconds: 100),
      failover: true,
      actions: const [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 25), KillCoordinatorAction()),
        ScheduledAction(Duration(seconds: 45), ReviveCoordinatorAction()),
        ScheduledAction(Duration(seconds: 80), SeekAction(Duration(minutes: 2))),
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
    // "Calibrate to this spot": listener at 0.3 m, others at 2–7 m, one on
    // uncalibrated Bluetooth. listenerSpreadMs_steady is what reaches the
    // listener's ears (propagation included), from the music after
    // calibration only.
    for (final calibrate in [false, true])
      Scenario(
        name: 'listening-spot-${calibrate ? 'calibrated' : 'uncalibrated'}-n4',
        participants: 4,
        network: NetworkCondition.wifiGood,
        duration: const Duration(seconds: 70),
        profiles: const [
          DeviceAudioProfile.flagship,
          DeviceAudioProfile.bluetoothUncalibrated,
          DeviceAudioProfile.midrange,
          DeviceAudioProfile.flagship,
        ],
        listenerIndex: 0,
        distancesM: const [0.3, 2.0, 4.5, 7.0],
        actions: [
          if (calibrate) const ScheduledAction(Duration(seconds: 3), CalibrateAction()),
          const ScheduledAction(Duration(seconds: 35), PlayAction()),
        ],
        seed: seed,
      ),
    Scenario(
      name: 'channel-role-switch-n3',
      participants: 3,
      network: NetworkCondition.wifiGood,
      duration: const Duration(seconds: 60),
      actions: const [
        ScheduledAction(Duration(seconds: 3), PlayAction()),
        ScheduledAction(Duration(seconds: 20), ChannelRoleAction(1, ChannelRole.left)),
        ScheduledAction(Duration(seconds: 35), ChannelRoleAction(2, ChannelRole.right)),
      ],
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
    ..addOption('suite', allowed: ['quick', 'full', 'engines'], defaultsTo: 'quick')
    ..addOption('profiles', help: 'engines suite: phone profiles exported from real phones (JSON)')
    ..addOption('out', defaultsTo: '../../benchmarks/out')
    ..addOption('seed', defaultsTo: '42')
    ..addOption('only', help: 'Run only scenarios whose name contains this')
    ..addOption('sample-every', defaultsTo: '4', help: 'Keep every Nth truth sample in the raw file');
  final a = p.parse(argv);
  final outDir = Directory(a['out'] as String)..createSync(recursive: true);
  final seed = int.parse(a['seed'] as String);
  final every = int.parse(a['sample-every'] as String);
  final measured = a['profiles'] == null ? null : _loadProfiles(a['profiles'] as String);
  var scenarios = _suite(a['suite'] as String, seed, measured: measured);
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
      'spreadFirst3s': q('interDeviceSpreadMs_first3s'),
      'engine': sc.engine.name,
      'coldStarts': m['coldStarts'],
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
      if (m['listenerSpreadMs_steady'] != null) 'listenerSpread': q('listenerSpreadMs_steady'),
    });
    stdout.writeln('${sc.name.padRight(36)} spread p50/p95/max '
        '${_f(q('interDeviceSpreadMs_steady'), 'median')}/${_f(q('interDeviceSpreadMs_steady'), 'p95')}/${_f(q('interDeviceSpreadMs_steady'), 'max')} ms  '
        'start skew p50 ${_f(q('startSkewMs'), 'median')} ms  (${sw.elapsedMilliseconds} ms wall)');
  }
  final meta = {
    'environment': 'SIMULATED — virtual time, modelled clocks/network/audio devices. NOT hardware measurements.',
    'suite': a['suite'],
    if (measured != null) 'profiles': [for (final p in measured) p.name],
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
  final eng = rows.where((r) => (r['scenario'] as String).startsWith('engines-')).toList();
  if (eng.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Sync engines (SIMULATED)')
      ..writeln()
      ..writeln('First 3 s = the spread right after each start, resume, seek and track change (where an echo is '
          'heard); steady = afterwards. Cold starts = starts that found the speaker output asleep.')
      ..writeln()
      ..writeln('| scenario | engine | first 3 s p50 | first 3 s p95 | steady p95 | start skew p50 | start skew max | cold starts | resyncs |')
      ..writeln('|---|---|---|---|---|---|---|---|---|');
    for (final r in eng) {
      Map<String, Object?> m(String k) => r[k] as Map<String, Object?>;
      b.writeln('| ${r['scenario']} | ${r['engine']} | ${_f(m('spreadFirst3s'), 'median')} | ${_f(m('spreadFirst3s'), 'p95')} | '
          '${_f(m('spreadSteady'), 'p95')} | ${_f(m('startSkew'), 'median')} | ${_f(m('startSkew'), 'max')} | '
          '${r['coldStarts']} | ${r['resyncs']} |');
    }
  }
  final fo = rows.where((r) => r['failover'] != null).toList();
  if (fo.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Coordinator failover (SIMULATED)')
      ..writeln()
      ..writeln('| scenario | final epoch | final coordinator | last promoted | promoted after kill (ms) | spread p95 / max in 15 s after promotion (ms) | handed back to | spread p95 / max in 15 s after handback (ms) |')
      ..writeln('|---|---|---|---|---|---|---|---|');
    for (final r in fo) {
      final f = r['failover'] as Map<String, Object?>;
      final sp = f['spreadMs_15sAfterPromotion'] as Map<String, Object?>;
      final hb = f['spreadMs_15sAfterHandback'] as Map<String, Object?>?;
      b.writeln('| ${r['scenario']} | ${f['finalEpoch']} | ${f['finalCoordinator']} | ${f['promoted']} | ${f['promotedAfterKillMs']} | '
          '${_f(sp, 'p95')} / ${_f(sp, 'max')} | ${f['handbackDevice'] ?? '–'} | '
          '${hb == null ? '–' : '${_f(hb, 'p95')} / ${_f(hb, 'max')}'} |');
    }
  }
  final ls = rows.where((r) => r['listenerSpread'] != null).toList();
  if (ls.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Listening-spot calibration (SIMULATED)')
      ..writeln()
      ..writeln('What reaches the listener (acoustic propagation at 343 m/s included). The main table\'s spread is '
          'the devices\' *output* spread, which calibration deliberately increases: nearer speakers are delayed so '
          'every sound arrives at the listening spot together.')
      ..writeln()
      ..writeln('| scenario | spread at listener p50 | p95 | max |')
      ..writeln('|---|---|---|---|');
    for (final r in ls) {
      final l = r['listenerSpread'] as Map<String, Object?>;
      b.writeln('| ${r['scenario']} | ${_f(l, 'median')} | ${_f(l, 'p95')} | ${_f(l, 'max')} |');
    }
  }
  b
    ..writeln()
    ..writeln('All times in ms unless noted. Raw per-sample data: `<scenario>.samples.jsonl`; '
        'recompute with `tools/analyze_samples.py`.');
  return b.toString();
}
