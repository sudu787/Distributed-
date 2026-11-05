/// Coordinator side of acoustic calibration and of the Sync check (which is
/// a calibration that only measures). Split out of `RoomCoordinator`, which
/// reaches it through [CalibrationHost].
///
/// Flow: [start] publishes a [CalibrationPlan] and asks every phone to
/// prepare its personalised click track as an ordinary segment; the
/// listener records, analyzes and sends its arrivals ([onResult]). A
/// calibration then shifts each phone's offset; a Sync check stores a
/// [SyncCheckResult] in the room state instead. Either way the previous
/// track is restored, paused, at its old position.
library;

import 'dart:async';

import '../calibration/calibration_analysis.dart';
import '../config/sync_config.dart';
import '../model/calibration_plan.dart';
import '../model/room_state.dart';
import '../observability/event_log.dart';
import '../protocol/messages.dart';
import 'membership.dart';

/// What the calibration coordinator needs from the room coordinator.
abstract interface class CalibrationHost {
  RoomState get state;
  MembershipManager get members;
  SchedulerConfig get scheduler;
  int nowUs();
  void mutate(RoomState next, {bool timeline = false});

  /// Prepares and starts [trackId] at [positionUs] for every phone.
  void requestSegment(String trackId, int positionUs);

  /// Next timeline generation.
  int nextGeneration();

  /// Drops a readiness barrier that is still waiting.
  void clearBarrier();
}

class CalibrationCoordinator {
  final CalibrationHost host;
  final EventLog log;

  int _seq = 0;
  final Map<String, List<(int, int)>> _reports = {};
  Timer? _timeout;
  (String, int)? _resumeAfter;

  CalibrationCoordinator(this.host, this.log);

  bool get active => host.state.calibration != null;

  /// Starts a calibration (or, with [measureOnly], a Sync check) recorded
  /// by [listener]'s microphone. Returns null on success, else a
  /// [ControlError] code.
  String? start(Member listener, {bool measureOnly = false}) {
    if (!listener.caps.microphone) {
      log.warn('calibration.reject', '${listener.displayName} has no microphone for calibration');
      return ControlError.invalid;
    }
    final order = [
      for (final m in host.members.all)
        if (m.connection == ConnectionStatus.connected) m.deviceId
    ];
    if (order.isEmpty) return ControlError.invalid;
    final s = host.state;
    final tl = s.timeline;
    final curTrack = s.pending?.trackId ?? tl.trackId;
    _resumeAfter = curTrack == null || s.isCalibrationTrack(curTrack)
        ? null
        : (curTrack, s.pending?.positionUs ?? tl.expectedPositionAt(host.nowUs()));
    final id = ++_seq;
    final plan = measureOnly
        ? CalibrationPlan.syncCheck(id: id, listener: listener.deviceId, order: order)
        : CalibrationPlan(id: id, listener: listener.deviceId, order: order);
    _reports.clear();
    final what = measureOnly ? 'sync check' : 'calibrating';
    log.info(measureOnly ? 'synccheck.start' : 'calibration.start',
        '$what ${order.length} device(s) at ${listener.displayName}\'s position (plan ${plan.id})',
        {'devices': order.length, 'durationMs': plan.durationUs ~/ 1000, 'engine': s.engine.name});
    host.mutate(s.copyWith(calibration: plan));
    host.requestSegment(plan.trackId, 0);
    final sched = host.scheduler;
    _timeout?.cancel();
    _timeout = Timer(
        Duration(microseconds: plan.durationUs) + sched.readinessTimeout + sched.maxLead + const Duration(seconds: 20),
        () {
      log.warn('calibration.timeout', 'no calibration result from the listener; cancelled');
      if (plan.measureOnly) _storeCheck(_failedCheck(plan, 'no result from the listening phone'));
      end();
    });
    return null;
  }

  /// Records a phone's own (software) playback error during the clicks.
  void onReport(Member m, SyncReportMsg r) {
    final s = host.state;
    if (s.calibration != null && s.isCalibrationTrack(s.timeline.trackId) && r.generation == s.timeline.generation) {
      (_reports[m.deviceId] ??= []).add((r.coordTimeUs, r.errorUs));
    }
  }

  void onResult(Member from, CalibrationResultMsg r) {
    final s = host.state;
    final plan = s.calibration;
    if (plan == null || r.calibrationId != plan.id || from.deviceId != plan.listener) {
      log.debug('calibration.stale', 'ignoring calibration result ${r.calibrationId} from ${from.deviceId}');
      return;
    }
    final tl = s.timeline;
    final arrivals = {
      for (final e in r.arrivals.entries)
        if (plan.order.contains(e.key)) e.key: e.value
    };
    if (r.error != null) {
      log.warn('calibration.failed', 'calibration failed on the listener: ${r.error}');
      if (plan.measureOnly) _storeCheck(_failedCheck(plan, r.error!));
    } else if (!s.isCalibrationTrack(tl.trackId) || !tl.isPlaying) {
      log.warn('calibration.failed', 'calibration result arrived without a calibration segment');
      if (plan.measureOnly) _storeCheck(_failedCheck(plan, 'the click track was not playing'));
    } else if (plan.measureOnly) {
      final check = summarizeSyncCheck(
        id: plan.id,
        plan: plan,
        engine: s.engine,
        arrivalsBySlot: arrivals,
        nameOf: (id) => host.members.byDevice(id)?.displayName ?? id,
      );
      log.info('synccheck.done',
          'sync check (${s.engine.label}): start spread ${_ms(check.startSpreadUs)}, settled ${_ms(check.settledSpreadUs)}',
          {for (final d in check.devices) d.deviceId: d.settledUs});
      _storeCheck(check);
    } else {
      final corrections = combineCalibration(
        plan: plan,
        arrivalsBySlot: arrivals,
        softwareErrorAt: (id, slot) => _softwareErrorAt(id, tl.coordTimeForPosition(plan.slotPositionUs(slot))),
      );
      corrections.forEach((id, corr) {
        final m = host.members.byDevice(id);
        if (m == null) return;
        m.calibrationUs = ((m.calibrationUs ?? 0) + corr).clamp(-kMaxCalibrationUs, kMaxCalibrationUs);
      });
      log.info('calibration.done',
          'calibration applied to ${corrections.length} device(s)${r.undetected.isEmpty ? '' : '; not heard: ${r.undetected.join(', ')}'}',
          {for (final e in corrections.entries) e.key: e.value});
    }
    end();
  }

  /// Ends the calibration and restores the previous track (paused).
  void end() {
    _timeout?.cancel();
    _timeout = null;
    final s = host.state;
    if (s.calibration == null) return;
    host.clearBarrier();
    final gen = host.nextGeneration();
    final pre = _resumeAfter;
    _resumeAfter = null;
    final now = host.nowUs();
    final tl = pre == null
        ? PlaybackTimeline(generation: gen, trackId: null, status: PlaybackStatus.idle, anchorPositionUs: 0, anchorCoordUs: now)
        : PlaybackTimeline(
            generation: gen, trackId: pre.$1, status: PlaybackStatus.paused, anchorPositionUs: pre.$2, anchorCoordUs: now);
    host.mutate(host.state.copyWith(timeline: tl, clearPending: true, clearCalibration: true), timeline: true);
  }

  void dispose() => _timeout?.cancel();

  /// A device's own software-estimated playback error at coordinator time
  /// [t], interpolated from its sync reports during the calibration (0 when
  /// unknown, i.e. assumed converged).
  int _softwareErrorAt(String deviceId, int t) {
    final reps = _reports[deviceId];
    if (reps == null || reps.isEmpty) return 0;
    reps.sort((a, b) => a.$1.compareTo(b.$1));
    if (t <= reps.first.$1) return reps.first.$2;
    if (t >= reps.last.$1) return reps.last.$2;
    for (var i = 1; i < reps.length; i++) {
      final (ta, ea) = reps[i - 1];
      final (tb, eb) = reps[i];
      if (t <= tb) return tb == ta ? eb : (ea + (eb - ea) * (t - ta) / (tb - ta)).round();
    }
    return reps.last.$2;
  }

  SyncCheckResult _failedCheck(CalibrationPlan plan, String why) => SyncCheckResult(
        id: plan.id,
        engine: host.state.engine,
        listener: plan.listener,
        error: why.length > 200 ? why.substring(0, 200) : why,
      );

  void _storeCheck(SyncCheckResult c) {
    final s = host.state;
    final checks = [...s.syncChecks, c];
    host.mutate(s.copyWith(syncChecks: checks.length > kMaxSyncChecks ? checks.sublist(checks.length - kMaxSyncChecks) : checks));
  }

  static String _ms(int? us) => us == null ? '—' : '${(us / 1000).toStringAsFixed(1)} ms';
}
