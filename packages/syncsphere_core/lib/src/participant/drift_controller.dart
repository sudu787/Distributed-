/// Three-mode drift correction with hysteresis.
///
///  * **in sync** — |e| below the rate-entry threshold: do nothing (rate 1.0).
///  * **rate correcting** — moderate error: proportional playback-rate
///    trim `rate = 1 − e / horizon`, clamped to ±maxRateDelta, so the error
///    decays with time constant ≈ horizon. Exits only when |e| falls below
///    the (lower) exit threshold — hysteresis prevents oscillation.
///  * **resync** — |e| above the seek threshold for several consecutive
///    filtered measurements and outside the seek cooldown: schedule a
///    controlled seek. Without rate control a lower seek threshold applies.
///
/// Measurements are median-filtered to reject outliers (a single late
/// position sample or clock glitch must not trigger a seek), and seek
/// decisions subtract the current clock uncertainty so an uncertain clock
/// cannot cause seeks it cannot justify.
///
/// Sign convention: `error = rendered position − expected position`;
/// positive means this device is *ahead* and must slow down.
library;

import '../config/sync_config.dart';
import '../observability/stats.dart';
import '../protocol/messages.dart' show CorrectionMode;

class DriftDecision {
  final CorrectionMode mode;

  /// New rate to apply, or null to leave the rate unchanged.
  final double? newRate;
  final bool resync;
  final double filteredErrorUs;
  const DriftDecision(this.mode, this.filteredErrorUs, {this.newRate, this.resync = false});
}

class DriftController {
  DriftConfig config;
  final bool rateSupported;

  CorrectionMode _mode = CorrectionMode.waiting;
  double _rate = 1.0;
  int? _lastSeekAtUs;
  int _consecutiveLarge = 0;
  late SlidingWindow _window;
  int seekCount = 0;
  int rateChangeCount = 0;

  DriftController(this.config, {required this.rateSupported}) {
    _window = SlidingWindow(config.medianWindow);
  }

  CorrectionMode get mode => _mode;
  double get rate => _rate;

  /// Call after a new segment starts or a resync completes.
  void reset() {
    _window = SlidingWindow(config.medianWindow);
    _mode = CorrectionMode.waiting;
    _rate = 1.0;
    _consecutiveLarge = 0;
  }

  void idle() {
    reset();
    _mode = CorrectionMode.idle;
  }

  DriftDecision onMeasurement({
    required double errorUs,
    required double uncertaintyUs,
    required int nowUs,
  }) {
    if (_mode == CorrectionMode.resyncing) {
      return DriftDecision(_mode, errorUs); // wait for reset()
    }
    _window.add(errorUs);
    final needed = config.medianWindow < 3 ? config.medianWindow : 3;
    if (_window.length < needed) {
      return DriftDecision(_mode, errorUs);
    }
    final e = _window.median;
    final abs = e.abs();

    final seekThr = (rateSupported ? config.seekThreshold : config.seekThresholdNoRate).inMicroseconds;
    if (abs - uncertaintyUs > seekThr) {
      _consecutiveLarge++;
    } else {
      _consecutiveLarge = 0;
    }
    final cooled = _lastSeekAtUs == null || nowUs - _lastSeekAtUs! >= config.seekCooldown.inMicroseconds;
    if (_consecutiveLarge >= config.seekConfirmations && cooled) {
      _lastSeekAtUs = nowUs;
      _consecutiveLarge = 0;
      _mode = CorrectionMode.resyncing;
      seekCount++;
      final changed = _rate != 1.0;
      _rate = 1.0;
      return DriftDecision(_mode, e, resync: true, newRate: changed ? 1.0 : null);
    }

    if (!rateSupported) {
      _mode = CorrectionMode.inSync;
      return DriftDecision(_mode, e);
    }

    final enter = config.rateEnterThreshold.inMicroseconds;
    final exit = config.rateExitThreshold.inMicroseconds;
    switch (_mode) {
      case CorrectionMode.rateCorrecting:
        if (abs < exit) _mode = CorrectionMode.inSync;
      default:
        _mode = abs > enter ? CorrectionMode.rateCorrecting : CorrectionMode.inSync;
    }

    double target = 1.0;
    if (_mode == CorrectionMode.rateCorrecting) {
      target = 1.0 - e / config.correctionHorizon.inMicroseconds;
      final d = config.maxRateDelta;
      target = target.clamp(1.0 - d, 1.0 + d);
      if (config.minRateStep > 0) {
        target = (target / config.minRateStep).roundToDouble() * config.minRateStep;
      }
    }
    final changed = (target - _rate).abs() >= (config.minRateStep > 0 ? config.minRateStep * 0.999 : 1e-9) ||
        (target == 1.0 && _rate != 1.0);
    if (changed) {
      _rate = target;
      rateChangeCount++;
      return DriftDecision(_mode, e, newRate: target);
    }
    return DriftDecision(_mode, e);
  }
}
