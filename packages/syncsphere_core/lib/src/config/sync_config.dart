/// Central configuration for every timing threshold, interval and resource
/// limit in SyncSphere. Nothing in the core hardcodes these values; the
/// coordinator distributes the effective [SyncConfig] to participants so the
/// whole room runs with one consistent policy.
library;

/// Clock-offset estimation (NTP-style four-timestamp exchange).
class ClockSyncConfig {
  /// Number of rapid probes sent right after (re)connecting.
  final int burstSamples;

  /// Spacing between probes in the initial burst.
  final Duration burstSpacing;

  /// Steady-state probe interval while the estimate is still converging.
  final Duration fastInterval;

  /// Steady-state probe interval once the estimate is stable.
  final Duration slowInterval;

  /// Uncertainty (half-width) below which the slow interval is used.
  final Duration stableUncertainty;

  /// Maximum samples kept in the sliding window.
  final int windowSize;

  /// Samples older than this are discarded.
  final Duration maxSampleAge;

  /// Samples whose round-trip delay exceeds this are rejected outright.
  final Duration maxRtt;

  /// Upper bound on the relative frequency error between two device clocks.
  /// Used to widen uncertainty with sample age before skew is estimated.
  final double maxSkewPpm;

  /// Residual skew uncertainty assumed once skew has been estimated.
  final double residualSkewPpm;

  /// Minimum time span covered by samples before estimating skew.
  final Duration minSkewSpan;

  /// Minimum number of samples before estimating skew.
  final int minSkewSamples;

  /// Probe timeout; an unanswered probe is dropped (no sample).
  final Duration probeTimeout;

  const ClockSyncConfig({
    this.burstSamples = 10,
    this.burstSpacing = const Duration(milliseconds: 40),
    this.fastInterval = const Duration(seconds: 1),
    this.slowInterval = const Duration(seconds: 3),
    this.stableUncertainty = const Duration(milliseconds: 3),
    this.windowSize = 64,
    this.maxSampleAge = const Duration(minutes: 3),
    this.maxRtt = const Duration(milliseconds: 1500),
    this.maxSkewPpm = 200,
    this.residualSkewPpm = 10,
    this.minSkewSpan = const Duration(seconds: 20),
    this.minSkewSamples = 10,
    this.probeTimeout = const Duration(seconds: 2),
  });

  Map<String, Object?> toJson() => {
        'burstSamples': burstSamples,
        'burstSpacingMs': burstSpacing.inMilliseconds,
        'fastIntervalMs': fastInterval.inMilliseconds,
        'slowIntervalMs': slowInterval.inMilliseconds,
        'stableUncertaintyUs': stableUncertainty.inMicroseconds,
        'windowSize': windowSize,
        'maxSampleAgeMs': maxSampleAge.inMilliseconds,
        'maxRttMs': maxRtt.inMilliseconds,
        'maxSkewPpm': maxSkewPpm,
        'residualSkewPpm': residualSkewPpm,
        'minSkewSpanMs': minSkewSpan.inMilliseconds,
        'minSkewSamples': minSkewSamples,
        'probeTimeoutMs': probeTimeout.inMilliseconds,
      };

  factory ClockSyncConfig.fromJson(Map<String, Object?> j) {
    const d = ClockSyncConfig();
    return ClockSyncConfig(
      burstSamples: _int(j['burstSamples'], d.burstSamples, 1, 100),
      burstSpacing: _ms(j['burstSpacingMs'], d.burstSpacing, 1, 5000),
      fastInterval: _ms(j['fastIntervalMs'], d.fastInterval, 50, 60000),
      slowInterval: _ms(j['slowIntervalMs'], d.slowInterval, 50, 300000),
      stableUncertainty:
          _us(j['stableUncertaintyUs'], d.stableUncertainty, 0, 1000000),
      windowSize: _int(j['windowSize'], d.windowSize, 4, 1024),
      maxSampleAge: _ms(j['maxSampleAgeMs'], d.maxSampleAge, 1000, 3600000),
      maxRtt: _ms(j['maxRttMs'], d.maxRtt, 1, 60000),
      maxSkewPpm: _dbl(j['maxSkewPpm'], d.maxSkewPpm, 0, 10000),
      residualSkewPpm: _dbl(j['residualSkewPpm'], d.residualSkewPpm, 0, 10000),
      minSkewSpan: _ms(j['minSkewSpanMs'], d.minSkewSpan, 1000, 3600000),
      minSkewSamples: _int(j['minSkewSamples'], d.minSkewSamples, 3, 1024),
      probeTimeout: _ms(j['probeTimeoutMs'], d.probeTimeout, 10, 60000),
    );
  }
}

/// Scheduling of future playback actions (start, pause, seek, track change).
class SchedulerConfig {
  /// Lower bound on the lead between issuing a command and its execution.
  final Duration minLead;

  /// Upper bound on the computed lead.
  final Duration maxLead;

  /// Multiplier applied to the worst participant's 95th-percentile RTT to
  /// cover one-way command delivery including its tail.
  final double rttMultiplier;

  /// Fixed safety margin added on top of the measured components.
  final Duration safetyMargin;

  /// How long the coordinator waits for `ready` acknowledgements before
  /// starting with the participants that are ready.
  final Duration readinessTimeout;

  /// Lead used by a participant that joins an already-running timeline.
  final Duration lateJoinLead;

  /// A participant treats a scheduled time closer than this as "too late"
  /// and joins mid-stream instead of trying to hit it.
  final Duration minScheduleAhead;

  const SchedulerConfig({
    this.minLead = const Duration(milliseconds: 250),
    this.maxLead = const Duration(seconds: 3),
    this.rttMultiplier = 1.5,
    this.safetyMargin = const Duration(milliseconds: 120),
    this.readinessTimeout = const Duration(seconds: 8),
    this.lateJoinLead = const Duration(milliseconds: 400),
    this.minScheduleAhead = const Duration(milliseconds: 40),
  });

  Map<String, Object?> toJson() => {
        'minLeadMs': minLead.inMilliseconds,
        'maxLeadMs': maxLead.inMilliseconds,
        'rttMultiplier': rttMultiplier,
        'safetyMarginMs': safetyMargin.inMilliseconds,
        'readinessTimeoutMs': readinessTimeout.inMilliseconds,
        'lateJoinLeadMs': lateJoinLead.inMilliseconds,
        'minScheduleAheadMs': minScheduleAhead.inMilliseconds,
      };

  factory SchedulerConfig.fromJson(Map<String, Object?> j) {
    const d = SchedulerConfig();
    return SchedulerConfig(
      minLead: _ms(j['minLeadMs'], d.minLead, 10, 60000),
      maxLead: _ms(j['maxLeadMs'], d.maxLead, 10, 60000),
      rttMultiplier: _dbl(j['rttMultiplier'], d.rttMultiplier, 0, 100),
      safetyMargin: _ms(j['safetyMarginMs'], d.safetyMargin, 0, 60000),
      readinessTimeout:
          _ms(j['readinessTimeoutMs'], d.readinessTimeout, 100, 600000),
      lateJoinLead: _ms(j['lateJoinLeadMs'], d.lateJoinLead, 10, 60000),
      minScheduleAhead:
          _ms(j['minScheduleAheadMs'], d.minScheduleAhead, 0, 10000),
    );
  }
}

/// Continuous drift correction. Thresholds use hysteresis: entering a
/// correction mode needs a larger error than leaving it.
class DriftConfig {
  /// Interval between position measurements / sync reports while correcting.
  final Duration reportIntervalActive;

  /// Interval while in sync.
  final Duration reportIntervalIdle;

  /// Ignore position measurements for this long after a start or seek while
  /// the audio pipeline (and its timestamps) settle.
  final Duration settleTime;

  /// The start latency is learned from the first measurement at least this
  /// long after a start (longer than [settleTime]): ExoPlayer reports a
  /// head-position estimate until AudioTrack timestamps advance and then
  /// smooths the jump at ≤10 % of elapsed time, which on real devices takes
  /// 1.5–2.5 s. Rate corrections applied in between are subtracted.
  final Duration latencyLearnDelay;

  /// Number of measurements combined by the median filter.
  final int medianWindow;

  /// |error| above which rate correction starts.
  final Duration rateEnterThreshold;

  /// |error| below which rate correction stops (must be < enter threshold).
  final Duration rateExitThreshold;

  /// |error| above which a controlled seek/resync is scheduled.
  final Duration seekThreshold;

  /// Seek threshold used when the backend cannot change playback rate.
  final Duration seekThresholdNoRate;

  /// Consecutive filtered measurements above a seek threshold required
  /// before seeking.
  final int seekConfirmations;

  /// Minimum time between two corrective seeks.
  final Duration seekCooldown;

  /// Rate correction aims to remove the error over this horizon.
  final Duration correctionHorizon;

  /// Maximum deviation of playback rate from 1.0 (0.02 = ±2 %).
  final double maxRateDelta;

  /// Rate changes smaller than this are not sent to the backend.
  final double minRateStep;

  const DriftConfig({
    this.reportIntervalActive = const Duration(milliseconds: 500),
    this.reportIntervalIdle = const Duration(seconds: 2),
    this.settleTime = const Duration(milliseconds: 1200),
    this.latencyLearnDelay = const Duration(milliseconds: 2500),
    this.medianWindow = 5,
    this.rateEnterThreshold = const Duration(milliseconds: 8),
    this.rateExitThreshold = const Duration(milliseconds: 3),
    this.seekThreshold = const Duration(milliseconds: 150),
    this.seekThresholdNoRate = const Duration(milliseconds: 45),
    this.seekConfirmations = 2,
    this.seekCooldown = const Duration(seconds: 5),
    this.correctionHorizon = const Duration(seconds: 4),
    this.maxRateDelta = 0.015,
    this.minRateStep = 0.0005,
  });

  Map<String, Object?> toJson() => {
        'reportIntervalActiveMs': reportIntervalActive.inMilliseconds,
        'reportIntervalIdleMs': reportIntervalIdle.inMilliseconds,
        'settleTimeMs': settleTime.inMilliseconds,
        'latencyLearnDelayMs': latencyLearnDelay.inMilliseconds,
        'medianWindow': medianWindow,
        'rateEnterThresholdUs': rateEnterThreshold.inMicroseconds,
        'rateExitThresholdUs': rateExitThreshold.inMicroseconds,
        'seekThresholdUs': seekThreshold.inMicroseconds,
        'seekThresholdNoRateUs': seekThresholdNoRate.inMicroseconds,
        'seekConfirmations': seekConfirmations,
        'seekCooldownMs': seekCooldown.inMilliseconds,
        'correctionHorizonMs': correctionHorizon.inMilliseconds,
        'maxRateDelta': maxRateDelta,
        'minRateStep': minRateStep,
      };

  factory DriftConfig.fromJson(Map<String, Object?> j) {
    const d = DriftConfig();
    final enter =
        _us(j['rateEnterThresholdUs'], d.rateEnterThreshold, 100, 10000000);
    var exit = _us(j['rateExitThresholdUs'], d.rateExitThreshold, 0, 10000000);
    if (exit >= enter) exit = enter ~/ 2; // keep hysteresis meaningful
    return DriftConfig(
      reportIntervalActive:
          _ms(j['reportIntervalActiveMs'], d.reportIntervalActive, 50, 60000),
      reportIntervalIdle:
          _ms(j['reportIntervalIdleMs'], d.reportIntervalIdle, 50, 60000),
      settleTime: _ms(j['settleTimeMs'], d.settleTime, 0, 60000),
      latencyLearnDelay: _ms(j['latencyLearnDelayMs'], d.latencyLearnDelay, 0, 60000),
      medianWindow: _int(j['medianWindow'], d.medianWindow, 1, 64),
      rateEnterThreshold: enter,
      rateExitThreshold: exit,
      seekThreshold: _us(j['seekThresholdUs'], d.seekThreshold, 1000, 60000000),
      seekThresholdNoRate:
          _us(j['seekThresholdNoRateUs'], d.seekThresholdNoRate, 1000, 60000000),
      seekConfirmations:
          _int(j['seekConfirmations'], d.seekConfirmations, 1, 20),
      seekCooldown: _ms(j['seekCooldownMs'], d.seekCooldown, 0, 600000),
      correctionHorizon:
          _ms(j['correctionHorizonMs'], d.correctionHorizon, 100, 600000),
      maxRateDelta: _dbl(j['maxRateDelta'], d.maxRateDelta, 0, 0.25),
      minRateStep: _dbl(j['minRateStep'], d.minRateStep, 0, 0.1),
    );
  }
}

/// Which failure detector judges link liveness (see failure_detector.dart).
enum FailureDetectorKind { fixed, phi }

/// Membership, heartbeats and failure detection.
class MembershipConfig {
  final Duration heartbeatInterval;

  /// Detector used by the coordinator (for members) and by participants
  /// (for the coordinator).
  final FailureDetectorKind detector;

  /// Fixed detector: no traffic for this long marks a peer as suspect.
  final Duration suspectAfter;

  /// Fixed detector: no traffic for this long marks a peer as failed and
  /// closes the link.
  final Duration failAfter;

  /// φ accrual detector: suspicion levels for "suspect" and "failed".
  final double suspectPhi;
  final double failPhi;

  /// φ accrual detector: bounds on the silence before suspect / failed,
  /// whatever the learned distribution says.
  final Duration minSuspectAfter;
  final Duration minFailAfter;
  final Duration maxFailAfter;

  /// φ accrual detector: extra delay tolerated on top of the mean heartbeat
  /// interval, and the floor for the learned standard deviation.
  final Duration acceptablePause;
  final Duration minStdDev;

  /// A disconnected participant keeps its slot (role, volume) this long.
  final Duration reconnectGrace;

  /// Maximum participants per room, including the host's own player.
  final int maxParticipants;

  /// Handshake must finish within this time.
  final Duration handshakeTimeout;

  /// Failed authentication attempts per remote address per [authWindow]
  /// before the address is temporarily blocked.
  final int maxAuthFailures;
  final Duration authWindow;

  const MembershipConfig({
    this.heartbeatInterval = const Duration(seconds: 1),
    this.detector = FailureDetectorKind.phi,
    this.suspectAfter = const Duration(seconds: 3),
    this.failAfter = const Duration(seconds: 8),
    this.suspectPhi = 8,
    this.failPhi = 12,
    this.minSuspectAfter = const Duration(seconds: 2),
    this.minFailAfter = const Duration(seconds: 4),
    this.maxFailAfter = const Duration(seconds: 16),
    this.acceptablePause = const Duration(milliseconds: 500),
    this.minStdDev = const Duration(milliseconds: 200),
    this.reconnectGrace = const Duration(seconds: 90),
    this.maxParticipants = 16,
    this.handshakeTimeout = const Duration(seconds: 5),
    this.maxAuthFailures = 5,
    this.authWindow = const Duration(minutes: 1),
  });

  Map<String, Object?> toJson() => {
        'heartbeatIntervalMs': heartbeatInterval.inMilliseconds,
        'detector': detector.name,
        'suspectAfterMs': suspectAfter.inMilliseconds,
        'failAfterMs': failAfter.inMilliseconds,
        'suspectPhi': suspectPhi,
        'failPhi': failPhi,
        'minSuspectAfterMs': minSuspectAfter.inMilliseconds,
        'minFailAfterMs': minFailAfter.inMilliseconds,
        'maxFailAfterMs': maxFailAfter.inMilliseconds,
        'acceptablePauseMs': acceptablePause.inMilliseconds,
        'minStdDevMs': minStdDev.inMilliseconds,
        'reconnectGraceMs': reconnectGrace.inMilliseconds,
        'maxParticipants': maxParticipants,
        'handshakeTimeoutMs': handshakeTimeout.inMilliseconds,
        'maxAuthFailures': maxAuthFailures,
        'authWindowMs': authWindow.inMilliseconds,
      };

  factory MembershipConfig.fromJson(Map<String, Object?> j) {
    const d = MembershipConfig();
    return MembershipConfig(
      heartbeatInterval:
          _ms(j['heartbeatIntervalMs'], d.heartbeatInterval, 100, 60000),
      detector: FailureDetectorKind.values.firstWhere((k) => k.name == j['detector'], orElse: () => d.detector),
      suspectAfter: _ms(j['suspectAfterMs'], d.suspectAfter, 200, 600000),
      failAfter: _ms(j['failAfterMs'], d.failAfter, 300, 600000),
      suspectPhi: _dbl(j['suspectPhi'], d.suspectPhi, 1, 50),
      failPhi: _dbl(j['failPhi'], d.failPhi, 1, 50),
      minSuspectAfter: _ms(j['minSuspectAfterMs'], d.minSuspectAfter, 200, 600000),
      minFailAfter: _ms(j['minFailAfterMs'], d.minFailAfter, 300, 600000),
      maxFailAfter: _ms(j['maxFailAfterMs'], d.maxFailAfter, 300, 600000),
      acceptablePause: _ms(j['acceptablePauseMs'], d.acceptablePause, 0, 60000),
      minStdDev: _ms(j['minStdDevMs'], d.minStdDev, 10, 60000),
      reconnectGrace: _ms(j['reconnectGraceMs'], d.reconnectGrace, 0, 3600000),
      maxParticipants: _int(j['maxParticipants'], d.maxParticipants, 1, 256),
      handshakeTimeout:
          _ms(j['handshakeTimeoutMs'], d.handshakeTimeout, 100, 60000),
      maxAuthFailures: _int(j['maxAuthFailures'], d.maxAuthFailures, 1, 1000),
      authWindow: _ms(j['authWindowMs'], d.authWindow, 1000, 3600000),
    );
  }
}

/// Reconnection policy for participants (bounded exponential backoff).
class ReconnectConfig {
  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;

  /// Fraction of each delay randomised to avoid thundering herds.
  final double jitter;

  /// Give up after this many consecutive failed attempts (0 = never).
  final int maxAttempts;

  const ReconnectConfig({
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 8),
    this.multiplier = 2.0,
    this.jitter = 0.2,
    this.maxAttempts = 30,
  });
}

/// LAN file delivery limits.
class TransferConfig {
  final int maxFileBytes;
  final int maxConcurrentPerSession;
  final int maxConcurrentTotal;
  final int maxDownloadRetries;
  final Duration requestTimeout;
  final int cacheMaxBytes;

  /// Lifetime of a signed download authorisation header.
  final Duration authValidity;

  const TransferConfig({
    this.maxFileBytes = 512 * 1024 * 1024,
    this.maxConcurrentPerSession = 2,
    this.maxConcurrentTotal = 8,
    this.maxDownloadRetries = 5,
    this.requestTimeout = const Duration(seconds: 20),
    this.cacheMaxBytes = 2 * 1024 * 1024 * 1024,
    this.authValidity = const Duration(minutes: 5),
  });
}

/// Protocol-level limits applied to every inbound frame.
class ProtocolLimits {
  final int maxFrameBytes;
  final int maxStringLength;
  final int maxPlaylistLength;
  final int maxListLength;

  const ProtocolLimits({
    this.maxFrameBytes = 256 * 1024,
    this.maxStringLength = 512,
    this.maxPlaylistLength = 1000,
    this.maxListLength = 2000,
  });
}

/// The complete room policy. Distributed by the coordinator in `welcome`.
class SyncConfig {
  final ClockSyncConfig clock;
  final SchedulerConfig scheduler;
  final DriftConfig drift;
  final MembershipConfig membership;

  const SyncConfig({
    this.clock = const ClockSyncConfig(),
    this.scheduler = const SchedulerConfig(),
    this.drift = const DriftConfig(),
    this.membership = const MembershipConfig(),
  });

  Map<String, Object?> toJson() => {
        'clock': clock.toJson(),
        'scheduler': scheduler.toJson(),
        'drift': drift.toJson(),
        'membership': membership.toJson(),
      };

  factory SyncConfig.fromJson(Map<String, Object?> j) => SyncConfig(
        clock: ClockSyncConfig.fromJson(_map(j['clock'])),
        scheduler: SchedulerConfig.fromJson(_map(j['scheduler'])),
        drift: DriftConfig.fromJson(_map(j['drift'])),
        membership: MembershipConfig.fromJson(_map(j['membership'])),
      );
}

// ---------------------------------------------------------------------------
// Defensive parsing helpers: out-of-range or wrongly-typed values fall back to
// defaults or are clamped, so a malformed config can never disable safety
// limits.

Map<String, Object?> _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : const <String, Object?>{};

int _int(Object? v, int def, int min, int max) {
  if (v is! num || !v.isFinite) return def;
  return v.toInt().clamp(min, max);
}

double _dbl(Object? v, double def, double min, double max) {
  if (v is! num || !v.isFinite) return def;
  return v.toDouble().clamp(min, max);
}

Duration _ms(Object? v, Duration def, int min, int max) {
  if (v is! num || !v.isFinite) return def;
  return Duration(milliseconds: v.toInt().clamp(min, max));
}

Duration _us(Object? v, Duration def, int min, int max) {
  if (v is! num || !v.isFinite) return def;
  return Duration(microseconds: v.toInt().clamp(min, max));
}
