/// Virtual-time simulation of a SyncSphere room.
///
/// Runs the *real* [RoomCoordinator], [ParticipantSession] and
/// [PlaybackEngine] code over a [MemoryNetwork] with modelled impairments,
/// per-device clocks with offset and skew, and [SimulatedAudioBackend]s,
/// all under `fake_async`, so an hour of playback takes seconds.
///
/// Because the simulator knows the true time and each device's acoustic
/// output, it reports ground-truth inter-device skew alongside what the
/// software itself estimates. All results are labelled SIMULATED and must
/// never be presented as hardware measurements.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';

import '../config/sync_config.dart';
import '../coordinator/room_coordinator.dart';
import '../distribution/track_resolver.dart';
import '../model/room_state.dart';
import '../observability/event_log.dart';
import '../observability/stats.dart';
import '../participant/participant_session.dart';
import '../protocol/messages.dart';
import '../time/clock.dart';
import '../transport/memory_transport.dart';
import 'sim_audio_backend.dart';

/// Named network conditions (per-direction delay models).
class NetworkCondition {
  final String name;
  final LinkProfile uplink;
  final LinkProfile downlink;
  const NetworkCondition(this.name, this.uplink, this.downlink);

  static const lanIdeal = NetworkCondition(
    'lan-ideal',
    LinkProfile(base: Duration(microseconds: 600), jitterMean: Duration(microseconds: 200)),
    LinkProfile(base: Duration(microseconds: 600), jitterMean: Duration(microseconds: 200)),
  );
  static const wifiGood = NetworkCondition(
    'wifi-good',
    LinkProfile(base: Duration(milliseconds: 2), jitterMean: Duration(milliseconds: 2), spikeRate: 0.01, spike: Duration(milliseconds: 30)),
    LinkProfile(base: Duration(milliseconds: 2), jitterMean: Duration(milliseconds: 2), spikeRate: 0.01, spike: Duration(milliseconds: 30)),
  );
  static const wifiTypical = NetworkCondition(
    'wifi-typical',
    LinkProfile(base: Duration(milliseconds: 3), jitterMean: Duration(milliseconds: 5), lossRate: 0.005, spikeRate: 0.02, spike: Duration(milliseconds: 60)),
    // Downlink suffers from phone Wi-Fi power-save buffering: asymmetric.
    LinkProfile(base: Duration(milliseconds: 4), jitterMean: Duration(milliseconds: 8), lossRate: 0.005, spikeRate: 0.04, spike: Duration(milliseconds: 100)),
  );
  static const wifiCongested = NetworkCondition(
    'wifi-congested',
    LinkProfile(base: Duration(milliseconds: 5), jitterMean: Duration(milliseconds: 15), lossRate: 0.02, spikeRate: 0.05, spike: Duration(milliseconds: 150)),
    LinkProfile(base: Duration(milliseconds: 12), jitterMean: Duration(milliseconds: 25), lossRate: 0.02, spikeRate: 0.08, spike: Duration(milliseconds: 250)),
  );
  static const hotspot = NetworkCondition(
    'hotspot',
    LinkProfile(base: Duration(milliseconds: 4), jitterMean: Duration(milliseconds: 6), lossRate: 0.01, spikeRate: 0.03, spike: Duration(milliseconds: 120)),
    LinkProfile(base: Duration(milliseconds: 6), jitterMean: Duration(milliseconds: 9), lossRate: 0.01, spikeRate: 0.05, spike: Duration(milliseconds: 150)),
  );

  static const all = [lanIdeal, wifiGood, wifiTypical, wifiCongested, hotspot];

  static NetworkCondition byName(String n) =>
      all.firstWhere((c) => c.name == n, orElse: () => throw ArgumentError('unknown network $n'));
}

sealed class SimAction {
  const SimAction();
  String get label;
}

class PlayAction extends SimAction {
  const PlayAction();
  @override
  String get label => 'play';
}

class PauseAction extends SimAction {
  const PauseAction();
  @override
  String get label => 'pause';
}

class SeekAction extends SimAction {
  final Duration position;
  const SeekAction(this.position);
  @override
  String get label => 'seek(${position.inSeconds}s)';
}

class NextTrackAction extends SimAction {
  const NextTrackAction();
  @override
  String get label => 'next';
}

/// Silently partitions one participant's link (no FIN; detected by timeout).
class PartitionAction extends SimAction {
  final int participant;
  final Duration duration;
  const PartitionAction(this.participant, this.duration);
  @override
  String get label => 'partition(p$participant, ${duration.inSeconds}s)';
}

/// Kills the coordinator process; participants must detect and report it.
class KillCoordinatorAction extends SimAction {
  const KillCoordinatorAction();
  @override
  String get label => 'kill-coordinator';
}

class ScheduledAction {
  final Duration at;
  final SimAction action;
  const ScheduledAction(this.at, this.action);
}

class Scenario {
  final String name;
  final int participants; // including the host device
  final NetworkCondition network;
  final Duration duration;
  final List<ScheduledAction> actions;

  /// Device profiles, cycled over participants (index 0 = host).
  final List<DeviceAudioProfile> profiles;
  final double clockSkewPpmRange;
  final double audioPpmRange;
  final SyncConfig config;
  final int seed;
  final int trackCount;
  final Duration trackDuration;

  /// Per-participant acoustic calibration (µs), cycled like [profiles].
  final List<int> outputCalibrationUs;

  const Scenario({
    required this.name,
    required this.participants,
    required this.network,
    required this.duration,
    this.actions = const [ScheduledAction(Duration(seconds: 3), PlayAction())],
    this.profiles = const [DeviceAudioProfile.flagship, DeviceAudioProfile.midrange],
    this.clockSkewPpmRange = 50,
    this.audioPpmRange = 30,
    this.config = const SyncConfig(),
    this.seed = 1,
    this.trackCount = 3,
    this.trackDuration = const Duration(minutes: 30),
    this.outputCalibrationUs = const [0],
  });

  Map<String, Object?> toJson() => {
        'name': name,
        'participants': participants,
        'network': network.name,
        'durationS': duration.inSeconds,
        'actions': [for (final a in actions) '${a.at.inMilliseconds}ms:${a.action.label}'],
        'profiles': [for (final p in profiles) p.name],
        'clockSkewPpmRange': clockSkewPpmRange,
        'audioPpmRange': audioPpmRange,
        'seed': seed,
      };
}

class _SimDevice {
  final int index;
  final String id;
  final DerivedClock clock;
  final SimulatedAudioBackend backend;
  final Link link;
  final ParticipantSession session;
  final EventLog log;
  _SimDevice(this.index, this.id, this.clock, this.backend, this.link, this.session, this.log);
}

/// One ground-truth sample of the room at a true instant.
class TruthSample {
  final int trueUs;
  final int generation;

  /// Acoustic error per audible device vs. the timeline (µs).
  final Map<String, int> errors;
  TruthSample(this.trueUs, this.generation, this.errors);

  int? get spread => errors.length < 2
      ? null
      : errors.values.reduce(max) - errors.values.reduce(min);
}

class SimulationResult {
  final Scenario scenario;
  final Map<String, Object?> metrics;
  final List<TruthSample> samples;
  final List<Map<String, Object?>> events;
  SimulationResult(this.scenario, this.metrics, this.samples, this.events);

  Map<String, Object?> toJson() => {
        'environment': 'SIMULATED (virtual time; modelled clocks, network and audio devices; not hardware)',
        'scenario': scenario.toJson(),
        'metrics': metrics,
      };

  String samplesJsonLines() => samples
      .map((s) => jsonEncode({'t': s.trueUs, 'gen': s.generation, 'err': s.errors}))
      .join('\n');
}

class SimulationRunner {
  final Scenario scenario;
  final bool verbose;
  SimulationRunner(this.scenario, {this.verbose = false});

  SimulationResult run() {
    late SimulationResult result;
    FakeAsync().run((fa) {
      result = _run(fa);
    });
    return result;
  }

  SimulationResult _run(FakeAsync fa) {
    final sc = scenario;
    final rnd = Random(sc.seed);
    const epoch = 1000000000; // keep timestamps positive
    int trueNow() => fa.elapsed.inMicroseconds + epoch;
    final trueClock = _FnClock(trueNow);
    final net = MemoryNetwork(clock: trueClock, random: Random(sc.seed + 1));

    double uniform(double range) => (rnd.nextDouble() * 2 - 1) * range;

    // Tracks (ids are fake but well-formed SHA-256 strings).
    final tracks = [
      for (var i = 0; i < sc.trackCount; i++)
        TrackInfo(
          id: i.toRadixString(16).padLeft(2, '0') * 32,
          title: 'Track ${i + 1}',
          durationUs: sc.trackDuration.inMicroseconds,
          sizeBytes: 5000000,
        )
    ];
    final localFiles = {for (final t in tracks) t.id: Uri.parse('sim:///${t.id}')};

    // Host device clock doubles as the coordinator clock.
    final hostClock = DerivedClock(
        referenceMicros: trueNow, offsetMicros: rnd.nextInt(1 << 30), skewPpm: uniform(sc.clockSkewPpmRange));
    final coordLog = EventLog(clock: hostClock, source: 'coordinator');
    final coordinator = RoomCoordinator(
      options: CoordinatorOptions(
        roomId: 'sim-room',
        roomName: sc.name,
        coordinatorId: 'device-0',
        joinKey: 'SIMKEY01',
        kdfIterations: 10,
        config: sc.config,
        defaultRole: ParticipantRole.controller,
      ),
      clock: hostClock,
      log: coordLog,
    );
    coordinator.setPlaylist(tracks);
    coordinator.serve(net.listen('coordinator'));
    coordinator.start();

    final devices = <_SimDevice>[];
    for (var i = 0; i < sc.participants; i++) {
      final id = 'device-$i';
      final clk = i == 0
          ? hostClock
          : DerivedClock(
              referenceMicros: trueNow,
              offsetMicros: rnd.nextInt(1 << 30),
              skewPpm: uniform(sc.clockSkewPpmRange));
      final profile = sc.profiles[i % sc.profiles.length].withClockPpm(uniform(sc.audioPpmRange));
      final backend = SimulatedAudioBackend(
          profile: profile, trueNowUs: trueNow, localClock: clk, random: Random(sc.seed * 100 + i));
      final link = i == 0
          ? Link(
              uplink: const LinkProfile(base: Duration(microseconds: 80)),
              downlink: const LinkProfile(base: Duration(microseconds: 80)))
          : Link(uplink: sc.network.uplink, downlink: sc.network.downlink);
      final log = EventLog(clock: clk, source: id);
      final session = ParticipantSession(
        options: ParticipantOptions(
          deviceId: id,
          displayName: 'Device $i',
          joinKey: 'SIMKEY01',
          outputCalibrationUs: sc.outputCalibrationUs[i % sc.outputCalibrationUs.length],
        ),
        connector: net.connector(id, 'coordinator', link),
        clock: clk,
        backend: backend,
        resolver: StaticTrackResolver(localFiles),
        log: log,
        random: Random(sc.seed * 1000 + i),
      );
      if (verbose) {
        log.printer = (src, e) {
          // ignore: avoid_print
          if (e.level.index >= EventLevel.info.index) print('$src $e');
        };
      }
      devices.add(_SimDevice(i, id, clk, backend, link, session, log));
    }
    if (verbose) {
      coordLog.printer = (src, e) {
        // ignore: avoid_print
        if (e.level.index >= EventLevel.info.index) print('$src $e');
      };
    }

    // Record every playing timeline and the true time it was published.
    final timelines = <int, (PlaybackTimeline, int)>{};
    final tlSub = coordinator.stateStream.listen((st) {
      final tl = st.timeline;
      if (tl.isPlaying && !timelines.containsKey(tl.generation)) {
        timelines[tl.generation] = (tl, trueNow());
      }
    });

    for (final d in devices) {
      unawaited(d.session.start().catchError((Object e) {
        d.log.error('sim', 'session failed: $e');
      }));
      fa.elapse(const Duration(milliseconds: 200));
    }

    // ---------------------------------------------------- measurement
    final samples = <TruthSample>[];
    final clockErr = SampleStats();
    final clockUnc = SampleStats();
    var clockCovered = 0, clockTotal = 0;
    final commandLatency = SampleStats();
    final simEvents = <Map<String, Object?>>[];
    var coordinatorKilled = false;
    final partitionHeal = <String, int>{};
    final recovery = SampleStats();

    void logEvent(String what, [Map<String, Object?> data = const {}]) {
      simEvents.add({'trueMs': (trueNow() - epoch) ~/ 1000, 'event': what, ...data});
    }

    final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (coordinatorKilled) return;
      final tl = coordinator.state.timeline;
      final t = trueNow();
      if (tl.isPlaying) {
        final coordNow = hostClock.nowMicros();
        final expected = tl.expectedPositionAt(coordNow);
        final errs = <String, int>{};
        for (final d in devices) {
          final seg = d.backend.activeSegment;
          if (seg == null) continue;
          final eng = d.session.engine.status;
          if (eng.activeGeneration != tl.generation) continue;
          final pos = d.backend.acousticPositionAt(t);
          if (pos == null) continue;
          errs[d.id] = pos - expected;
        }
        if (errs.isNotEmpty && coordNow >= tl.anchorCoordUs) {
          samples.add(TruthSample(t, tl.generation, errs));
        }
      }
    });

    final clockSampler = Timer.periodic(const Duration(seconds: 1), (_) {
      if (coordinatorKilled) return;
      for (final d in devices.skip(1)) {
        final e = d.session.estimate;
        if (e == null) continue;
        final localNow = d.clock.nowMicros();
        final trueOffset = hostClock.nowMicros() - localNow;
        final err = (e.offsetAt(localNow) - trueOffset).abs();
        final unc = e.uncertaintyAt(localNow);
        clockErr.add(err);
        clockUnc.add(unc);
        clockTotal++;
        if (err <= unc) clockCovered++;
      }
    });

    // Track "all devices rendering the new generation" for command latency.
    int? pendingCommandAt;
    int? pendingCommandGen;
    final latencyWatcher = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (pendingCommandAt == null) return;
      final tl = coordinator.state.timeline;
      if (tl.generation < (pendingCommandGen ?? 0)) return;
      final t = trueNow();
      final allAudible = devices.every((d) {
        if (!d.session.isLive) return true;
        return d.session.engine.status.activeGeneration == tl.generation &&
            d.backend.acousticPositionAt(t) != null;
      });
      if (allAudible || tl.status != PlaybackStatus.playing) {
        commandLatency.add((t - pendingCommandAt!) / 1000);
        pendingCommandAt = null;
      }
    });

    // Recovery watcher for partitioned devices: time from heal until the
    // device is audible on the current generation with |error| < 20 ms.
    final recoveryWatcher = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (partitionHeal.isEmpty || samples.isEmpty) return;
      final last = samples.last;
      for (final id in partitionHeal.keys.toList()) {
        final e = last.errors[id];
        final others = last.errors.entries.where((x) => x.key != id).map((x) => x.value).toList();
        if (e == null || others.isEmpty) continue;
        others.sort();
        final ref = others[others.length ~/ 2];
        if ((e - ref).abs() < 20000) {
          recovery.add((trueNow() - partitionHeal[id]!) / 1000);
          logEvent('recovered', {'device': id, 'ms': (trueNow() - partitionHeal[id]!) ~/ 1000});
          partitionHeal.remove(id);
        }
      }
    });

    final host = devices.first.session;
    void control(ControlAction a, {int? pos}) {
      pendingCommandAt = trueNow();
      pendingCommandGen = coordinator.state.timeline.generation + 1;
      unawaited(host.control(a, positionUs: pos).then((ack) {
        if (!ack.accepted) logEvent('control-rejected', {'action': a.name, 'error': ack.error});
      }));
    }

    final actions = List.of(sc.actions)..sort((a, b) => a.at.compareTo(b.at));
    final start = fa.elapsed;
    for (final a in actions) {
      final wait = a.at - (fa.elapsed - start);
      if (wait > Duration.zero) fa.elapse(wait);
      logEvent('action', {'action': a.action.label});
      switch (a.action) {
        case PlayAction():
          control(ControlAction.play);
        case PauseAction():
          control(ControlAction.pause);
        case SeekAction(:final position):
          control(ControlAction.seek, pos: position.inMicroseconds);
        case NextTrackAction():
          control(ControlAction.next);
        case PartitionAction(:final participant, :final duration):
          final d = devices[participant];
          d.link.partition();
          Timer(duration, () {
            d.link.heal();
            partitionHeal[d.id] = trueNow();
            logEvent('heal', {'device': d.id});
          });
        case KillCoordinatorAction():
          coordinatorKilled = true;
          net.killServer('coordinator');
          unawaited(coordinator.close(reason: 'killed'));
      }
    }
    final remaining = sc.duration - (fa.elapsed - start);
    if (remaining > Duration.zero) fa.elapse(remaining);

    sampler.cancel();
    unawaited(tlSub.cancel());
    clockSampler.cancel();
    latencyWatcher.cancel();
    recoveryWatcher.cancel();

    // ------------------------------------------------------- metrics
    final spread = SampleStats();
    final spreadSteady = SampleStats();
    final absErr = SampleStats();
    final pairwise = SampleStats();
    // Exclude 3 s after every generation change for "steady state".
    final genStart = <int, int>{};
    for (final s in samples) {
      genStart.putIfAbsent(s.generation, () => s.trueUs);
    }
    for (final s in samples) {
      final sp = s.spread;
      final vals = s.errors.values.toList();
      for (final v in vals) {
        absErr.add(v.abs() / 1000);
      }
      for (var i = 0; i < vals.length; i++) {
        for (var j = i + 1; j < vals.length; j++) {
          pairwise.add((vals[i] - vals[j]).abs() / 1000);
        }
      }
      if (sp != null) {
        spread.add(sp / 1000);
        if (s.trueUs - genStart[s.generation]! > 3000000) spreadSteady.add(sp / 1000);
      }
    }

    // Start skew from ground truth: for each playing generation, take each
    // device's first output start after the timeline was published (and
    // before the next one) and compare it with the true time the timeline
    // says that position should be audible.
    final startSkews = SampleStats();
    final startErrors = SampleStats();
    final gens = timelines.keys.toList()..sort();
    for (var gi = 0; gi < gens.length; gi++) {
      final (tl, published) = timelines[gens[gi]]!;
      final until = gi + 1 < gens.length ? timelines[gens[gi + 1]]!.$2 : 1 << 62;
      final errs = <int>[];
      for (final d in devices) {
        for (final (_, outTrue, pos) in d.backend.outputStarts) {
          if (outTrue < published || outTrue >= until) continue;
          final expectedTrue = hostClock.toReference(tl.coordTimeForPosition(pos));
          errs.add(outTrue - expectedTrue);
          break;
        }
      }
      startErrors.addAll(errs.map((e) => e.abs() / 1000));
      if (errs.length >= 2) startSkews.add((errs.reduce(max) - errs.reduce(min)) / 1000);
    }

    var resyncs = 0, rateChanges = 0, stalls = 0, playCalls = 0;
    for (final d in devices) {
      resyncs += d.session.engine.drift.seekCount;
      rateChanges += d.backend.rateChanges;
      stalls += d.backend.stallCount;
      playCalls += d.backend.playCalls;
    }

    // Drift: mean |error| in the first vs last minute of steady playback.
    final driftFirst = SampleStats(), driftLast = SampleStats();
    if (samples.isNotEmpty) {
      final t0 = samples.first.trueUs, t1 = samples.last.trueUs;
      for (final s in samples) {
        final sp = s.spread;
        if (sp == null) continue;
        if (s.trueUs - t0 < 60000000 && s.trueUs - t0 > 5000000) driftFirst.add(sp / 1000);
        if (t1 - s.trueUs < 60000000) driftLast.add(sp / 1000);
      }
    }

    final failedSessions = devices.where((d) => d.session.phase == SessionPhase.failed).map((d) => d.id).toList();
    final metrics = <String, Object?>{
      'interDeviceSpreadMs_all': spread.summary(),
      'interDeviceSpreadMs_steady': spreadSteady.summary(),
      'pairwiseErrorMs': pairwise.summary(),
      'absErrorVsTimelineMs': absErr.summary(),
      'startSkewMs': startSkews.summary(),
      'startErrorMs': startErrors.summary(),
      'driftSpreadFirstMinuteMs': driftFirst.summary(),
      'driftSpreadLastMinuteMs': driftLast.summary(),
      'commandToAudibleLatencyMs': commandLatency.summary(),
      'clockOffsetErrorUs': clockErr.summary(decimals: 0),
      'clockUncertaintyUs': clockUnc.summary(decimals: 0),
      'clockUncertaintyCoverage': clockTotal == 0 ? null : double.parse((clockCovered / clockTotal).toStringAsFixed(4)),
      'recoveryAfterPartitionMs': recovery.summary(),
      'unrecoveredDevices': partitionHeal.keys.toList(),
      'resyncSeeks': resyncs,
      'rateChanges': rateChanges,
      'bufferingStalls': stalls,
      'playCalls': playCalls,
      'networkFrames': net.framesSent,
      'networkBytes': net.bytesSent,
      'networkBytesPerDevicePerSecond': sc.participants == 0
          ? 0
          : (net.bytesSent / sc.participants / max(1, sc.duration.inSeconds)).round(),
      'failedSessions': failedSessions,
      'failureReasons': {for (final d in devices) if (d.session.lastFailure != null) d.id: d.session.lastFailure},
      'coordinatorWarnings': coordLog.events.where((e) => e.level.index >= EventLevel.warn.index).length,
    };

    // Tear down inside fake time.
    for (final d in devices) {
      unawaited(d.session.close());
    }
    if (!coordinatorKilled) unawaited(coordinator.close());
    fa.elapse(const Duration(seconds: 1));
    fa.flushMicrotasks();

    return SimulationResult(sc, metrics, samples, simEvents);
  }

}

class _FnClock implements MonotonicClock {
  final int Function() f;
  _FnClock(this.f);
  @override
  int nowMicros() => f();
}

