/// Participant-side pieces of acoustic calibration: where click tracks come
/// from, how the microphone is accessed, and the listener's control flow.
library;

import 'dart:async';
import 'dart:io';

import '../audio/audio_backend.dart';
import '../model/calibration_plan.dart';
import '../model/room_state.dart';
import '../observability/event_log.dart';
import '../protocol/messages.dart';
import '../time/clock.dart';
import '../time/clock_sync.dart';
import 'calibration_analysis.dart';
import 'click_track.dart';

/// Produces this device's personalized click track for a plan.
abstract class CalibrationTrackFactory {
  Future<TrackSource> sourceFor(CalibrationPlan plan, int deviceIndex);
}

/// Writes click tracks as WAV files into [dir].
class FileCalibrationTrackFactory implements CalibrationTrackFactory {
  final Directory dir;
  final int sampleRate;
  FileCalibrationTrackFactory(this.dir, {this.sampleRate = 48000});

  @override
  Future<TrackSource> sourceFor(CalibrationPlan plan, int deviceIndex) async {
    await dir.create(recursive: true);
    final f = File('${dir.path}/calibration-${plan.id}-$deviceIndex.wav');
    if (!await f.exists()) {
      final wav = encodeWav(calibrationSamples(plan, deviceIndex, sampleRate: sampleRate), sampleRate: sampleRate);
      await f.writeAsBytes(wav, flush: true);
    }
    return TrackSource(uri: f.uri, trackId: plan.trackId);
  }
}

/// Microphone access for the calibration listener.
abstract class CalibrationRecorder {
  /// Records mono audio starting at local time [startAtLocalUs] (or now, if
  /// already past) for [durationUs].
  Future<AudioRecording> record({required int startAtLocalUs, required int durationUs});
}

/// Drives the listener side: records the calibration segment, analyzes it
/// and reports corrections to the coordinator.
class CalibrationListener {
  final String deviceId;
  final CalibrationRecorder recorder;
  final MonotonicClock clock;
  final ClockEstimate? Function() estimate;
  final void Function(Message m) send;
  final EventLog log;
  int? _activePlan;

  /// Last outcome, for diagnostics screens.
  CalibrationOutcome? lastOutcome;

  CalibrationListener({
    required this.deviceId,
    required this.recorder,
    required this.clock,
    required this.estimate,
    required this.send,
    required this.log,
  });

  void onState(RoomState s) {
    final plan = s.calibration;
    final tl = s.timeline;
    if (plan == null || plan.listener != deviceId || _activePlan == plan.id) return;
    if (!tl.isPlaying || tl.trackId != plan.trackId) return;
    final est = estimate();
    if (est == null) return;
    _activePlan = plan.id;
    unawaited(_run(plan, tl, est));
  }

  Future<void> _run(CalibrationPlan plan, PlaybackTimeline tl, ClockEstimate est) async {
    // Margins: clicks can arrive up to a few hundred ms late (Bluetooth).
    final startLocal = est.toLocal(tl.coordTimeForPosition(plan.leadInUs)) - 500000;
    final endLocal = est.toLocal(tl.coordTimeForPosition(plan.slotPositionUs(plan.slotCount - 1))) + 800000;
    final now = clock.nowMicros();
    final start = startLocal < now ? now : startLocal;
    log.info('calibration.record', 'recording calibration clicks for ${(endLocal - start) ~/ 1000} ms');
    try {
      final rec = await recorder.record(startAtLocalUs: start, durationUs: endLocal - start);
      final e = estimate() ?? est;
      final out = analyzeCalibration(
        rec: rec,
        plan: plan,
        coordToLocal: e.toLocal,
        anchorCoordUs: tl.anchorCoordUs,
        anchorPositionUs: tl.anchorPositionUs,
      );
      lastOutcome = out;
      log.info('calibration.measured',
          'heard ${plan.order.length - out.undetected.length}/${plan.order.length} devices',
          {for (final d in out.devices) d.deviceId: d.correctionUs});
      send(CalibrationResultMsg(
        calibrationId: plan.id,
        arrivals: {for (final d in out.devices) if (d.arrivalsBySlot.isNotEmpty) d.deviceId: d.arrivalsBySlot},
        undetected: out.undetected,
      ));
    } catch (e) {
      log.error('calibration.error', 'calibration recording failed: $e');
      send(CalibrationResultMsg(calibrationId: plan.id, error: '$e'.length > 200 ? '$e'.substring(0, 200) : '$e'));
    }
  }
}
