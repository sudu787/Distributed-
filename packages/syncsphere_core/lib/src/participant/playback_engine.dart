/// Participant playback engine: renders the coordinator's timeline on the
/// local audio backend.
///
/// Inputs: authoritative [RoomState] snapshots (already version-filtered by
/// the session), the current clock estimate (coordinator − local), and
/// backend events. Outputs: backend operations, plus `ready`, sync reports,
/// playback events and availability messages to the coordinator.
///
/// Every asynchronous step re-checks that the generation it was started for
/// is still current, so a slow prepare or a delayed message can never start
/// an old segment.
library;

import 'dart:async';
import 'dart:math';

import '../audio/audio_backend.dart';
import '../calibration/calibration_runtime.dart';
import '../config/feature_flags.dart';
import '../config/sync_config.dart';
import '../distribution/track_resolver.dart';
import '../model/room_state.dart';
import '../observability/event_log.dart';
import '../protocol/messages.dart';
import '../time/clock.dart';
import '../time/clock_sync.dart';
import 'drift_controller.dart';
import 'start_policy.dart';
import 'start_probe.dart';
import 'start_stats.dart';

enum SegmentStatus { preparing, prepared, scheduled, playing, pausing, paused }

class _Segment {
  final int id;
  int generation;
  final String trackId;
  final int positionUs;
  SegmentStatus status;

  /// Local time the first frame should be audible (target).
  int? targetOutLocalUs;

  /// Local time the play call was planned / actually executed.
  int? playCallPlannedUs;
  int? playCallActualUs;
  bool firstMeasurementDone = false;
  final bool isResync;

  /// When audio was last heard before this segment was activated (its
  /// target time if it replaced a playing segment; null: never).
  int? audibleBeforeUs;

  /// Position gained (+) or lost (−) through playback-rate corrections
  /// since the start, so start-latency learning can subtract it.
  double rateCorrectionUs = 0;
  double _rate = 1.0;
  int? _rateSinceUs;

  void noteRate(int nowUs, double rate) {
    rateCorrectionAt(nowUs);
    _rate = rate;
    _rateSinceUs = nowUs;
  }

  double rateCorrectionAt(int nowUs) {
    final since = _rateSinceUs;
    if (since != null && nowUs > since) {
      rateCorrectionUs += (_rate - 1.0) * (nowUs - since);
      _rateSinceUs = nowUs;
    }
    return rateCorrectionUs;
  }

  _Segment(this.id, this.generation, this.trackId, this.positionUs, this.status, {this.isResync = false});
}

/// Snapshot for UIs.
class EngineStatus {
  final CorrectionMode mode;
  final int? lastErrorUs;
  final double rate;
  final int startLatencyUs;
  final String playerState;
  final int? activeGeneration;
  final String? activeTrackId;
  final int? positionUs;
  final String? lastError;
  final bool buffering;

  /// The sync engine this phone is running.
  final SyncEngineMode engine;
  const EngineStatus({
    required this.mode,
    this.lastErrorUs,
    this.rate = 1.0,
    this.startLatencyUs = 0,
    this.playerState = 'idle',
    this.activeGeneration,
    this.activeTrackId,
    this.positionUs,
    this.lastError,
    this.buffering = false,
    this.engine = SyncEngineMode.classic,
  });
}

/// Clock information the engine reads (owned by the session).
abstract class ClockSource {
  ClockEstimate? get estimate;
  int get rttP95Us;
}

class PlaybackEngine {
  final AudioBackend backend;
  final TrackResolver resolver;
  final MonotonicClock clock;
  final ClockSource clockSource;
  final EventLog log;
  final String deviceId;
  final void Function(Message m) send;
  SyncConfig config;

  late DriftController _drift;
  RoomState? _state;
  int _segSeq = 0;
  _Segment? _active;
  _Segment? _standby;
  int? _preparingPendingGen;
  int? _readySentGen;
  bool _lateJoinInFlight = false;
  int _lateJoinAttempts = 0;
  Timer? _driftTimer;
  Timer? _reconcileTimer;
  StreamSubscription<AudioBackendEvent>? _eventSub;
  bool _connected = false;
  int? _disconnectedAtUs;
  bool _awaitingRejoin = false;
  int? _lastErrorUs;
  String? _lastError;
  String _playerState = 'idle';
  int? _lastPositionUs;
  bool _buffering = false;
  String _playlistSignature = '';
  final Map<String, TrackAvailability> _reportedAvailability = {};
  int _lastReportAtUs = 0;
  bool _disposed = false;
  ChannelRole _channel = ChannelRole.stereo;

  /// Start rule and learned lead per sync engine (see start_policy.dart).
  final Map<SyncEngineMode, StartPolicy> _policies;
  StartPolicy _policy;

  /// Engine the room asked for (the backend may run another after a
  /// fallback); [_engineSwitch] counts selections so a slow one that was
  /// overtaken is ignored.
  SyncEngineMode _requestedEngine = SyncEngineMode.classic;
  int _engineSwitch = 0;
  bool _switchingEngine = false;

  /// Per-phone feature switches.
  FeatureFlags _flags;

  /// Per-device acoustic calibration (µs): how much later sound leaves the
  /// speaker than the backend's reported position implies (e.g. Bluetooth
  /// or DSP latency the platform does not report). Measured with an
  /// external microphone / test tone; 0 when uncalibrated.
  int outputCalibrationUs;

  /// Source of personalized click tracks during room calibration.
  final CalibrationTrackFactory? calibrationTracks;

  /// Silent clip for warm start's test start (null: no probe).
  final Future<TrackSource> Function()? probeTrack;
  StartProbe? _probe;
  bool _probeDone = false;
  int _probeFailures = 0;

  /// EWMA of how long prepare() takes (µs), used to size late joins.
  int _prepareEstimateUs = 300000;

  /// What this phone measured about its starts (for the phone profile).
  final StartStats stats = StartStats();

  /// Local time of the last measurement that found audio playing.
  int? _lastAudibleAtUs;

  int get prepareEstimateUs => _prepareEstimateUs;

  final StreamController<EngineStatus> _statusCtl = StreamController.broadcast();

  PlaybackEngine({
    required this.backend,
    required this.resolver,
    required this.clock,
    required this.clockSource,
    required this.log,
    required this.deviceId,
    required this.send,
    this.config = const SyncConfig(),
    int startLatencyUs = 0,
    Map<String, int> learnedLeads = const {},
    this.outputCalibrationUs = 0,
    this.calibrationTracks,
    this.probeTrack,
    FeatureFlags flags = const FeatureFlags(),
  })  : _flags = flags,
        _policies = StartPolicy.forAllEngines(
          // Without a learned value, seed the start-latency compensation
          // from the platform's own output-latency estimate (if any);
          // learning refines it after the first start.
          classicLeadUs: startLatencyUs == 0 && (backend.capabilities.outputLatencyHintUs ?? 0) > 0
              ? backend.capabilities.outputLatencyHintUs!
              : startLatencyUs,
          learned: learnedLeads,
          outputCalibrationUs: outputCalibrationUs,
        ),
        _policy = ClassicStartPolicy(0) {
    _policy = _policies[SyncEngineMode.classic]!;
    _drift = DriftController(_policy.drift(config.drift), rateSupported: backend.capabilities.rateControl);
    _eventSub = backend.events.listen(_onBackendEvent);
  }

  /// Current start-latency compensation (µs): backend start calls are
  /// issued this much before the target audible time.
  int get startLatencyUs => _policy.leadUs;

  /// The learned ExoPlayer start latency (what the app persists).
  int get classicStartLatencyUs => _policies[SyncEngineMode.classic]!.leadUs;

  /// Learned leads of the other engines, by engine name (persisted too).
  Map<String, int> get learnedLeads => {
        for (final e in _policies.entries)
          if (e.key != SyncEngineMode.classic) e.key.name: e.value.leadUs,
      };

  /// The sync engine this phone is running.
  SyncEngineMode get engine => _policy.mode;

  FeatureFlags get flags => _flags;

  Stream<EngineStatus> get statusStream => _statusCtl.stream;
  EngineStatus get status => EngineStatus(
        mode: _drift.mode,
        lastErrorUs: _lastErrorUs,
        rate: _drift.rate,
        startLatencyUs: startLatencyUs,
        playerState: _playerState,
        activeGeneration: _active?.generation,
        activeTrackId: _active?.trackId,
        positionUs: _lastPositionUs,
        lastError: _lastError,
        buffering: _buffering,
        engine: _policy.mode,
      );
  DriftController get drift => _drift;

  void updateConfig(SyncConfig c) {
    config = c;
    _drift.config = _policy.drift(c.drift);
  }

  /// Applies changed feature switches; the running engine is re-selected
  /// when they affect it.
  void updateFlags(FeatureFlags f) {
    if (f == _flags) return;
    final old = _flags;
    _flags = f;
    if (old.channelRoles != f.channelRoles && _state != null) _applyVolume(_state!);
    if (_requestedEngine != SyncEngineMode.classic &&
        (old.keepAwake != f.keepAwake || old.preciseFallback != f.preciseFallback)) {
      _selectEngine(_requestedEngine, force: true);
    }
  }

  // ----------------------------------------------------------- inputs

  void onConnectionChanged(bool connected) {
    if (connected == _connected) return;
    _connected = connected;
    final now = clock.nowMicros();
    if (!connected) {
      _disconnectedAtUs = now;
      log.warn('engine.offline', 'coordinator unreachable; continuing on last known timeline');
    } else if (_disconnectedAtUs != null) {
      _awaitingRejoin = true;
      _playlistSignature = ''; // re-report availability on the next state
      _readySentGen = null; // coordinator lost our readiness with the link
      _preparingPendingGen = null;
    }
    _emit();
  }

  /// Called when the coordinator's clock domain changed (new process):
  /// every local schedule derived from the old domain is invalid.
  void onClockDomainReset() {
    log.warn('engine.clockReset', 'coordinator clock domain changed; resynchronising');
    _active = null;
    _standby = null;
    _readySentGen = null;
    _preparingPendingGen = null;
    unawaited(backend.stop());
  }

  /// Called when a better clock estimate becomes available.
  void onClockUpdated() {
    if (_state != null && _active == null) _scheduleReconcile();
  }

  void applyState(RoomState s) {
    final prev = _state;
    _state = s;
    _applyVolume(s);
    final roomCal = s.participant(deviceId)?.calibrationUs;
    if (roomCal != null && roomCal != outputCalibrationUs) {
      log.info('engine.calibration', 'room calibration offset ${outputCalibrationUs ~/ 1000} → ${roomCal ~/ 1000} ms');
      // The learned start latency aligned the *calibrated* position; a
      // calibration change of Δ means play calls must move Δ earlier.
      for (final p in _policies.values) {
        p.onCalibrationChanged(roomCal - outputCalibrationUs);
      }
      outputCalibrationUs = roomCal;
    }
    if (s.engine != _requestedEngine) _selectEngine(s.engine);
    final sig = s.playlist.map((t) => t.id).join(',');
    if (sig != _playlistSignature) {
      _playlistSignature = sig;
      unawaited(_reportAvailability(s));
    }
    if (prev != null && prev.timeline.generation != s.timeline.generation) {
      _lateJoinAttempts = 0;
    }
    if (prev == null || prev.timeline.generation != s.timeline.generation || prev.pending?.generation != s.pending?.generation) {
      log.debug('engine.state', 'v${s.version} ${s.timeline}${s.pending == null ? '' : ' pending g${s.pending!.generation}'}');
    }
    _reconcile();
  }

  // -------------------------------------------------------- reconcile

  void _scheduleReconcile([Duration delay = Duration.zero]) {
    _reconcileTimer?.cancel();
    _reconcileTimer = Timer(delay, _reconcile);
  }

  void _reconcile() {
    if (_disposed || _switchingEngine) return;
    final s = _state;
    if (s == null) return;
    if (_probe != null) {
      // The probe owns the backend; hand it back as soon as the room needs it.
      if (_roomNeedsPlayer(s)) _cancelProbe();
      return;
    }
    _maybeProbe(s);
    if (_probe != null) return;
    final pending = s.pending;
    if (pending != null && _readySentGen != pending.generation && _preparingPendingGen != pending.generation) {
      unawaited(_preparePending(pending, s));
    }
    final tl = s.timeline;
    switch (tl.status) {
      case PlaybackStatus.idle:
        if (_active != null) {
          _active = null;
          _drift.idle();
          unawaited(backend.stop());
        }
      case PlaybackStatus.paused:
        _reconcilePaused(tl);
      case PlaybackStatus.playing:
        _reconcilePlaying(tl);
    }
    _emit();
    _ensureDriftTimer();
  }

  void _reconcilePaused(PlaybackTimeline tl) {
    final a = _active;
    if (a == null) return;
    if (a.status == SegmentStatus.paused || a.status == SegmentStatus.pausing) {
      a.generation = tl.generation;
      return;
    }
    if (a.generation >= tl.generation) return;
    final est = clockSource.estimate;
    if (est == null) return;
    final at = est.toLocal(tl.anchorCoordUs);
    a
      ..status = SegmentStatus.pausing
      ..generation = tl.generation;
    _drift.idle();
    log.info('engine.pause', 'pause g${tl.generation} in ${(at - clock.nowMicros()) ~/ 1000} ms');
    unawaited(backend
        .pauseAt(segmentId: a.id, atLocalUs: at, thenSeekToUs: tl.anchorPositionUs)
        .catchError((Object e) => _fail('pause failed: $e')));
  }

  void _reconcilePlaying(PlaybackTimeline tl) {
    final a = _active;
    if (a != null && a.generation == tl.generation &&
        (a.status == SegmentStatus.playing || a.status == SegmentStatus.scheduled)) {
      return; // already following this timeline
    }
    final est = clockSource.estimate;
    if (est == null) {
      log.debug('engine.wait', 'no clock estimate yet; deferring start of g${tl.generation}');
      return;
    }
    final sb = _standby;
    if (sb != null && sb.generation == tl.generation) {
      if (sb.status == SegmentStatus.preparing) return; // continue when ready
      if (sb.status == SegmentStatus.prepared && sb.positionUs == tl.anchorPositionUs) {
        final targetOut = est.toLocal(tl.anchorCoordUs);
        final playAt = _policy.startCallAt(targetOut);
        final ahead = playAt - clock.nowMicros();
        if (ahead >= config.scheduler.minScheduleAhead.inMicroseconds) {
          _activate(sb, targetOut, playAt);
          return;
        }
        log.warn('engine.late', 'start command for g${tl.generation} arrived ${-ahead ~/ 1000} ms too late; joining mid-stream');
        send(PlaybackEventMsg(
            kind: PlaybackEventKind.lateJoin,
            generation: tl.generation,
            data: {'lateUs': -ahead}));
      }
    }
    _lateJoin(tl, resync: false);
  }

  // ----------------------------------------------------- preparation

  Future<void> _preparePending(PendingSegment p, RoomState s) async {
    _preparingPendingGen = p.generation;
    final track = s.trackById(p.trackId);
    if (track == null) {
      _sendReady(p, ok: false, error: 'missing_track');
      return;
    }
    final t0 = clock.nowMicros();
    final seg = _Segment(++_segSeq, p.generation, p.trackId, p.positionUs, SegmentStatus.preparing);
    _standby = seg;
    try {
      final src = await _resolve(track, s);
      _markAvailable(track.id);
      if (!_stillRelevant(p.generation)) {
        if (identical(_standby, seg)) _standby = null;
        return;
      }
      await backend.prepare(segmentId: seg.id, source: src, positionUs: p.positionUs);
      if (!identical(_standby, seg)) return; // superseded meanwhile
      if (!_stillRelevant(p.generation)) {
        _standby = null;
        return;
      }
      // Mark prepared even if the barrier already completed without us: the
      // playing-timeline path then starts it or joins mid-stream.
      seg.status = SegmentStatus.prepared;
      _updatePrepareEstimate(clock.nowMicros() - t0);
      _sendReady(p, ok: true);
      log.debug('engine.ready', 'prepared g${p.generation} in ${(clock.nowMicros() - t0) ~/ 1000} ms');
    } on TrackUnavailableException catch (e) {
      _fail('track unavailable: ${e.message}');
      if (identical(_standby, seg)) _standby = null;
      _sendReady(p, ok: false, error: e.code);
    } on AudioBackendException catch (e) {
      _fail('prepare failed: ${e.message}');
      if (identical(_standby, seg)) _standby = null;
      _sendReady(p, ok: false, error: e.code);
    } catch (e) {
      _fail('prepare failed: $e');
      if (identical(_standby, seg)) _standby = null;
      _sendReady(p, ok: false, error: 'prepare_error');
    }
    _reconcile();
  }

  bool _isPendingCurrent(int gen) => _state?.pending?.generation == gen;

  /// Playlist tracks come from the resolver; the calibration segment is a
  /// click track generated locally for this device's slots.
  Future<TrackSource> _resolve(TrackInfo track, RoomState s) {
    final plan = s.calibration;
    if (plan != null && plan.trackId == track.id) {
      final k = plan.order.indexOf(deviceId);
      final f = calibrationTracks;
      if (k < 0 || f == null) {
        throw const TrackUnavailableException('missing_track', 'this device is not part of the calibration');
      }
      return f.sourceFor(plan, k);
    }
    return resolver.resolve(track, s.distribution);
  }

  bool _stillRelevant(int gen) =>
      _isPendingCurrent(gen) || _state?.timeline.generation == gen;

  void _sendReady(PendingSegment p, {required bool ok, String? error}) {
    if (!_isPendingCurrent(p.generation)) return;
    _readySentGen = p.generation;
    final est = clockSource.estimate;
    send(ReadyMsg(
      generation: p.generation,
      trackId: p.trackId,
      ok: ok,
      error: error,
      startLatencyUs: _policy.leadUs,
      rttP95Us: clockSource.rttP95Us,
      uncertaintyUs: est == null ? 0 : est.uncertaintyAt(clock.nowMicros()).round(),
    ));
  }

  void _updatePrepareEstimate(int us) {
    _prepareEstimateUs = ((_prepareEstimateUs * 3 + us) / 4).round().clamp(50000, 20000000);
  }

  /// Joins a running timeline (late command, reconnect, or corrective
  /// resync): prepares a standby segment at the position that will be due
  /// once preparation finishes, then starts it exactly when due.
  void _lateJoin(PlaybackTimeline tl, {required bool resync}) {
    if (_lateJoinInFlight) return;
    final s = _state!;
    final track = s.trackById(tl.trackId);
    if (track == null) return;
    _lateJoinInFlight = true;
    final attempt = ++_lateJoinAttempts;
    final engineAtStart = _engineSwitch;
    var succeeded = false;
    () async {
      try {
        final est = clockSource.estimate!;
        final lead = config.scheduler.lateJoinLead.inMicroseconds + _prepareEstimateUs * (1 << min(attempt - 1, 3));
        final now = clock.nowMicros();
        final outLocal = now + lead + _policy.leadUs;
        final pos = tl.expectedPositionAt(est.toRemote(outLocal));
        final dur = track.durationUs;
        if (dur != null && pos >= dur) {
          log.info('engine.ended', 'timeline g${tl.generation} is past the end of the track');
          return;
        }
        final seg = _Segment(++_segSeq, tl.generation, tl.trackId!, pos, SegmentStatus.preparing, isResync: resync);
        final t0 = clock.nowMicros();
        final src = await _resolve(track, s);
        _markAvailable(track.id);
        if (_state?.timeline.generation != tl.generation) return;
        if (!resync) _standby = seg;
        await backend.prepare(segmentId: seg.id, source: src, positionUs: pos);
        _updatePrepareEstimate(clock.nowMicros() - t0);
        if (engineAtStart != _engineSwitch) return; // prepared on an engine that is gone
        if (_state?.timeline.generation != tl.generation || !_state!.timeline.isPlaying) return;
        seg.status = SegmentStatus.prepared;
        final est2 = clockSource.estimate!;
        final targetOut = est2.toLocal(tl.coordTimeForPosition(pos));
        final playAt = _policy.startCallAt(targetOut);
        if (playAt - clock.nowMicros() < config.scheduler.minScheduleAhead.inMicroseconds) {
          log.warn('engine.lateJoin.retry', 'prepare took too long (attempt $attempt); retrying further ahead');
          if (identical(_standby, seg)) _standby = null;
          if (resync) _drift.reset();
          return;
        }
        _lateJoinAttempts = 0;
        succeeded = true;
        log.info(resync ? 'engine.resync' : 'engine.lateJoin',
            '${resync ? 'resync' : 'late join'} g${tl.generation} at pos ${pos ~/ 1000} ms in ${(playAt - clock.nowMicros()) ~/ 1000} ms');
        if (resync) {
          send(PlaybackEventMsg(kind: PlaybackEventKind.resync, generation: tl.generation, data: {'posUs': pos}));
        }
        _activate(seg, targetOut, playAt);
      } on TrackUnavailableException catch (e) {
        _fail('cannot join: ${e.message}');
        send(PlaybackEventMsg(kind: PlaybackEventKind.error, generation: tl.generation, detail: e.code));
      } catch (e) {
        _fail('late join failed: $e');
        if (resync) _drift.reset();
      } finally {
        _lateJoinInFlight = false;
        if (!succeeded && !resync) {
          // Bounded retry with exponential backoff; a new timeline
          // generation resets the attempt counter.
          if (_lateJoinAttempts <= 8) {
            _scheduleReconcile(Duration(milliseconds: min(100 * (1 << _lateJoinAttempts), 10000)));
          } else {
            log.error('engine.lateJoin.giveUp', 'giving up joining g${tl.generation} after $_lateJoinAttempts attempts');
          }
        } else if (_state?.timeline.generation != tl.generation) {
          _scheduleReconcile(); // a newer generation arrived while we were busy
        }
        _emit();
      }
    }();
  }

  void _activate(_Segment seg, int targetOutLocal, int playAtLocal) {
    // A segment that replaces a playing one starts on a busy output.
    seg.audibleBeforeUs = _active?.status == SegmentStatus.playing ? targetOutLocal : _lastAudibleAtUs;
    seg
      ..status = SegmentStatus.scheduled
      ..targetOutLocalUs = targetOutLocal
      ..playCallPlannedUs = playAtLocal;
    _active = seg;
    if (identical(_standby, seg)) _standby = null;
    _drift.reset();
    log.debug('engine.schedule', 'play call for g${seg.generation} scheduled in ${(playAtLocal - clock.nowMicros()) ~/ 1000} ms (latency comp ${_policy.leadUs ~/ 1000} ms)');
    unawaited(backend
        .startAt(segmentId: seg.id, atLocalUs: playAtLocal)
        .catchError((Object e) => _fail('start failed: $e')));
    _emit();
    _ensureDriftTimer();
  }

  // ------------------------------------------------------ drift loop

  void _ensureDriftTimer() {
    if (_driftTimer != null || _disposed) return;
    _driftTimer = Timer(_nextDriftInterval(), _driftTick);
  }

  Duration _nextDriftInterval() {
    final m = _drift.mode;
    return (m == CorrectionMode.inSync || m == CorrectionMode.idle)
        ? _drift.config.reportIntervalIdle
        : _drift.config.reportIntervalActive;
  }

  Future<void> _driftTick() async {
    _driftTimer = null;
    if (_disposed) return;
    try {
      await _measure();
    } catch (e) {
      log.error('engine.drift', 'drift measurement failed: $e');
    }
    final tl = _state?.timeline;
    if (tl != null && (tl.isPlaying || _active != null)) _ensureDriftTimer();
  }

  Future<void> _measure() async {
    final s = _state;
    final a = _active;
    if (s == null || a == null) return;
    final tl = s.timeline;
    final now = clock.nowMicros();
    if (a.status == SegmentStatus.scheduled && now - (a.playCallPlannedUs ?? now) > _startWatchdogUs) {
      _startFailed(a); // the play call never happened (lost event, dropped segment)
      return;
    }
    if (!tl.isPlaying || a.generation != tl.generation || a.status != SegmentStatus.playing) {
      return;
    }
    final settleAt = (a.targetOutLocalUs ?? now) + _drift.config.settleTime.inMicroseconds;
    if (now < settleAt) return;
    final est = clockSource.estimate;
    if (est == null) return;
    final sample = await backend.samplePosition();
    if (sample == null || sample.segmentId != a.id || !identical(_active, a)) return;
    _playerState = sample.state;
    _lastPositionUs = sample.positionUs;
    final wasBuffering = _buffering;
    _buffering = sample.state == 'buffering';
    if (_buffering) {
      if (!wasBuffering) {
        send(PlaybackEventMsg(kind: PlaybackEventKind.stall, generation: tl.generation));
      }
      _report(tl, sample, est, null);
      return;
    }
    final coordT = est.toRemote(sample.atLocalUs);
    final expected = tl.expectedPositionAt(coordT);
    final rendered = sample.positionUs - outputCalibrationUs;
    final error = rendered - expected;
    _lastErrorUs = error;
    if (sample.playing) _lastAudibleAtUs = sample.atLocalUs;

    final learnAt = (a.targetOutLocalUs ?? now) + _drift.config.latencyLearnDelay.inMicroseconds;
    if (!a.firstMeasurementDone && now >= learnAt) {
      a.firstMeasurementDone = true;
      _learnStartLatency(a, error - a.rateCorrectionAt(sample.atLocalUs).round());
    }

    final unc = est.uncertaintyAt(now);
    final d = _drift.onMeasurement(errorUs: error.toDouble(), uncertaintyUs: unc, nowUs: now);
    if (d.mode == CorrectionMode.inSync) stats.addSteady(_policy.mode, error);
    if (d.newRate != null) {
      log.debug('drift.rate', 'rate → ${d.newRate!.toStringAsFixed(4)} (error ${(d.filteredErrorUs / 1000).toStringAsFixed(1)} ms)');
      a.noteRate(now, d.newRate!);
      unawaited(backend.setRate(d.newRate!).catchError((Object e) => _fail('setRate failed: $e')));
    }
    if (d.resync) {
      log.warn('drift.resync', 'error ${(d.filteredErrorUs / 1000).toStringAsFixed(1)} ms exceeds seek threshold; resynchronising');
      _lateJoin(tl, resync: true);
    }
    if (_awaitingRejoin && (d.mode == CorrectionMode.inSync || d.mode == CorrectionMode.rateCorrecting) && _connected) {
      _awaitingRejoin = false;
      final recovery = _disconnectedAtUs == null ? 0 : now - _disconnectedAtUs!;
      _disconnectedAtUs = null;
      log.info('engine.rejoined', 'rejoined synchronized playback (${recovery ~/ 1000} ms after disconnect)');
      send(PlaybackEventMsg(kind: PlaybackEventKind.rejoined, generation: tl.generation, data: {'recoveryUs': recovery, 'errorUs': error}));
    }
    _report(tl, sample, est, error);
    _emit();
  }

  /// How long a scheduled segment may wait for its play call.
  static const _startWatchdogUs = 2000000;

  /// The backend could not start the segment it was told to (e.g. a
  /// concurrent prepare replaced its standby player). Without this the
  /// engine would wait for that start forever and never correct again;
  /// instead it forgets the segment and re-joins the running timeline.
  void _startFailed(_Segment a) {
    if (!identical(_active, a)) return;
    log.warn('engine.startFailed', 'segment for g${a.generation} did not start; re-joining the timeline');
    _active = null;
    _drift.reset();
    _scheduleReconcile();
  }

  void _learnStartLatency(_Segment a, int errorUs) {
    // error < 0: audio started late → issue play calls earlier next time.
    final before = _policy.leadUs;
    if (errorUs.abs() <= 500000) {
      final idleFrom = a.audibleBeforeUs;
      stats.addStart(StartRecord(
        engine: _policy.mode,
        leadUs: before,
        calibrationUs: outputCalibrationUs,
        errorUs: errorUs,
        idleBeforeUs: idleFrom == null ? null : max(0, (a.targetOutLocalUs ?? 0) - idleFrom),
        resync: a.isResync,
      ));
    }
    if (!_policy.learn(errorUs)) return; // implausible; something else is wrong
    log.info('engine.started', 'g${a.generation} start error ${(errorUs / 1000).toStringAsFixed(1)} ms (est.); latency comp ${before ~/ 1000} → ${_policy.leadUs ~/ 1000} ms');
    send(PlaybackEventMsg(
      kind: PlaybackEventKind.started,
      generation: a.generation,
      data: {
        'startErrorUs': errorUs,
        'playCallLateUs': (a.playCallActualUs ?? 0) - (a.playCallPlannedUs ?? 0),
        'latencyCompUs': before,
        if (a.isResync) 'resync': 1,
      },
    ));
  }

  void _report(PlaybackTimeline tl, PositionSample sample, ClockEstimate est, int? error) {
    if (!_connected) return;
    final now = clock.nowMicros();
    if (now - _lastReportAtUs < _nextDriftInterval().inMicroseconds * 0.8) return;
    _lastReportAtUs = now;
    final coordT = est.toRemote(sample.atLocalUs);
    final expected = tl.expectedPositionAt(coordT);
    final rendered = sample.positionUs - outputCalibrationUs;
    send(SyncReportMsg(
      generation: tl.generation,
      coordTimeUs: coordT,
      positionUs: rendered,
      expectedUs: expected,
      errorUs: error ?? rendered - expected,
      rate: _drift.rate,
      bufferedUs: sample.bufferedUs,
      offsetUs: est.offsetAt(now).round(),
      uncertaintyUs: est.uncertaintyAt(now).round(),
      rttP95Us: clockSource.rttP95Us,
      mode: _drift.mode,
      playerState: sample.state,
      engine: _policy.mode == _requestedEngine ? null : _policy.mode,
    ));
  }

  // ---------------------------------------------------------- events

  void _onBackendEvent(AudioBackendEvent e) {
    final a = _active;
    switch (e.kind) {
      case AudioEventKind.playCalled:
        if (a != null && a.id == e.segmentId) {
          a
            ..status = SegmentStatus.playing
            ..playCallActualUs = e.atLocalUs;
          _playerState = 'playing';
        }
      case AudioEventKind.paused:
        if (a != null && a.id == e.segmentId) {
          a.status = SegmentStatus.paused;
          _playerState = 'paused';
        }
      case AudioEventKind.stalled:
        _buffering = true;
      case AudioEventKind.resumedAfterStall:
        _buffering = false;
      case AudioEventKind.ended:
        _playerState = 'ended';
      case AudioEventKind.engineFallback:
        _onEngineFallback(e.message);
      case AudioEventKind.error:
        _fail('audio backend error: ${e.message}');
        send(PlaybackEventMsg(
            kind: PlaybackEventKind.error,
            generation: a?.generation ?? 0,
            detail: e.message == null || e.message!.length <= 200 ? e.message : e.message!.substring(0, 200)));
        if (a != null && a.id == e.segmentId && a.status == SegmentStatus.scheduled) _startFailed(a);
    }
    _emit();
  }

  // ------------------------------------------------------ start probe

  bool _roomNeedsPlayer(RoomState s) => s.pending != null || s.timeline.isPlaying;

  /// Warm start: measures the start delay with a silent test start when the
  /// room is idle and nothing is prepared (see start_probe.dart).
  void _maybeProbe(RoomState s) {
    final source = probeTrack;
    if (source == null || _probeDone || _probeFailures >= 3) return;
    if (_policy.mode != SyncEngineMode.warm || !_flags.startProbe) return;
    if (_roomNeedsPlayer(s) || _active != null || _standby != null || _lateJoinInFlight) return;
    final probe = StartProbe(backend: backend, clock: clock, log: log, settle: _drift.config.latencyLearnDelay);
    _probe = probe;
    final policy = _policy;
    log.info('engine.probe', 'measuring this phone\'s start delay with a silent test start');
    () async {
      int? latency;
      try {
        latency = await probe.run(segmentId: ++_segSeq, source: await source());
      } catch (e) {
        log.warn('engine.probe', 'test start failed: $e');
      }
      if (!identical(_probe, probe)) return;
      _probe = null;
      if (latency != null && identical(_policy, policy)) {
        final before = policy.leadUs;
        // The lead aligns the *calibrated* position (see learnStartLatency).
        policy.leadUs = (latency + outputCalibrationUs).clamp(StartPolicy.minLeadUs, StartPolicy.maxLeadUs);
        _probeDone = true;
        stats.addProbe(latency);
        log.info('engine.probe', 'start delay ${latency ~/ 1000} ms; latency comp ${before ~/ 1000} → ${policy.leadUs ~/ 1000} ms');
        send(PlaybackEventMsg(
            kind: PlaybackEventKind.started, generation: 0, data: {'probeUs': latency, 'latencyCompUs': before}));
      } else if (!probe.cancelled) {
        _probeFailures++;
      }
      _emit();
      if (!_disposed) _scheduleReconcile();
    }();
  }

  void _cancelProbe() {
    final p = _probe;
    if (p == null || p.cancelled) return;
    log.debug('engine.probe', 'test start cancelled: the room needs the player');
    unawaited(p.cancel().whenComplete(() {
      if (identical(_probe, p)) _probe = null;
      _scheduleReconcile();
    }));
  }

  // ---------------------------------------------------------- engines

  /// Switches the backend to [mode]. Everything prepared on the old engine
  /// is dropped; the next reconcile re-prepares the pending segment and
  /// joins the running timeline on the new one.
  void _selectEngine(SyncEngineMode mode, {bool force = false}) {
    if (mode == _requestedEngine && !force) return;
    _requestedEngine = mode;
    final seq = ++_engineSwitch;
    _switchingEngine = true;
    _dropSegments();
    final probe = _probe;
    _probe = null;
    if (probe != null) unawaited(probe.cancel());
    _probeDone = false;
    _probeFailures = 0;
    log.info('engine.select', 'switching to the ${mode.label} engine');
    () async {
      var effective = SyncEngineMode.classic;
      try {
        effective = await backend.useEngine(mode, _flags);
      } catch (e) {
        _fail('could not start the ${mode.label} engine: $e');
      }
      if (seq != _engineSwitch || _disposed) return; // overtaken
      _usePolicy(effective);
      if (effective != mode) {
        log.warn('engine.fallback', '${mode.label} engine unavailable here; using ${effective.label}');
      }
      _switchingEngine = false;
      _reconcile();
    }();
  }

  void _onEngineFallback(String? why) {
    if (_policy.mode == SyncEngineMode.classic) return;
    log.warn('engine.fallback', '${_policy.mode.label} engine failed (${why ?? 'unknown'}); using Classic');
    _lastError = 'sync engine fell back to Classic: ${why ?? 'unknown error'}';
    _dropSegments();
    _usePolicy(SyncEngineMode.classic);
    _scheduleReconcile();
  }

  void _usePolicy(SyncEngineMode mode) {
    _policy = _policies[mode]!;
    // Rate support belongs to the engine (the precise renderer resamples
    // even where ExoPlayer cannot change speed).
    final old = _drift;
    _drift = DriftController(_policy.drift(config.drift), rateSupported: backend.capabilities.rateControl)
      ..seekCount = old.seekCount
      ..rateChangeCount = old.rateChangeCount;
    _emit();
  }

  /// Forgets every segment (the backend already stopped them).
  void _dropSegments() {
    _active = null;
    _standby = null;
    _readySentGen = null;
    _preparingPendingGen = null;
    _lateJoinAttempts = 0;
  }

  // ------------------------------------------------------------ misc

  void _applyVolume(RoomState s) {
    final me = s.participant(deviceId);
    final v = (s.masterVolume * (me?.volume ?? 1.0)).clamp(0.0, 1.0);
    unawaited(backend.setVolume(v).catchError((Object e) => _fail('setVolume failed: $e')));
    final ch = _flags.channelRoles ? (me?.channel ?? ChannelRole.stereo) : ChannelRole.stereo;
    if (ch != _channel) {
      _channel = ch;
      log.info('engine.channel', 'channel role → ${ch.name}');
      // The role is baked into newly prepared native players, so switch to a
      // fresh segment now (scheduled like a drift resync) rather than waiting
      // for the next track.
      unawaited(backend.setChannelRole(ch).then((_) {
        final tl = _state?.timeline;
        if (tl != null && tl.isPlaying && _active != null && !(_state?.isCalibrationTrack(tl.trackId) ?? false)) {
          _lateJoin(tl, resync: true);
        }
      }).catchError((Object e) => _fail('setChannelRole failed: $e')));
    }
  }

  Future<void> _reportAvailability(RoomState s) async {
    final entries = <TrackAvailabilityEntry>[];
    for (final t in s.playlist) {
      try {
        entries.add(TrackAvailabilityEntry(t.id, await resolver.availability(t)));
      } catch (e) {
        log.warn('engine.availability', 'availability check failed for ${t.title}: $e');
        entries.add(TrackAvailabilityEntry(t.id, TrackAvailability.unknown));
      }
    }
    for (final e in entries) {
      _reportedAvailability[e.trackId] = e.availability;
    }
    if (_connected) send(AvailabilityMsg(entries));
    // Prefetch the track after the current one so track changes do not wait
    // for a download.
    final idx = s.indexOfTrack(s.timeline.trackId);
    if (idx >= 0 && idx + 1 < s.playlist.length && s.distribution != DistributionMode.localOnly) {
      unawaited(resolver.prefetch(s.playlist[idx + 1], s.distribution).catchError((Object e) {
        log.debug('engine.prefetch', 'prefetch failed: $e');
      }));
    }
  }

  /// Tells the coordinator a track became playable here (e.g. after a LAN
  /// download), so the room screen's availability stays accurate.
  void _markAvailable(String trackId) {
    if (_reportedAvailability[trackId] == TrackAvailability.available) return;
    _reportedAvailability[trackId] = TrackAvailability.available;
    if (_connected) {
      send(AvailabilityMsg([TrackAvailabilityEntry(trackId, TrackAvailability.available)]));
    }
  }

  void _fail(String msg) {
    _lastError = msg;
    log.error('engine.error', msg);
    _emit();
  }

  void _emit() {
    if (!_statusCtl.isClosed) _statusCtl.add(status);
  }

  Future<void> stop() async {
    _active = null;
    _standby = null;
    _drift.idle();
    await backend.stop();
    _emit();
  }

  Future<void> dispose() async {
    _disposed = true;
    _driftTimer?.cancel();
    _reconcileTimer?.cancel();
    await _probe?.cancel();
    await _eventSub?.cancel();
    if (_requestedEngine != SyncEngineMode.classic) {
      // Leaving the party: stop warm start's keep-awake output and release
      // the precise renderer (this also stops playback).
      try {
        await backend.useEngine(SyncEngineMode.classic, _flags);
      } catch (e) {
        log.warn('engine.dispose', 'could not release the ${_requestedEngine.label} engine: $e');
      }
    }
    await backend.stop();
    await _statusCtl.close();
  }
}
