/// Selection of the scheduling lead: how far in the future a start/seek/
/// pause is placed so every participant can receive the command, convert the
/// time, and issue its native play call early enough to compensate for its
/// output start latency.
///
///     lead = max over ready participants of
///              rttP95 × rttMultiplier      (command delivery incl. tail)
///            + startLatency                 (participant plays this early)
///            + clockUncertainty             (conversion error budget)
///          + safetyMargin                   (event loop, platform channel)
///     clamped to [minLead, maxLead]
///
/// All inputs are *measured* and reported by participants; the constants
/// only shape how conservative the choice is.
library;

import 'dart:math' as math;

import '../config/sync_config.dart';

class ParticipantTiming {
  final String deviceId;
  final int rttP95Us;
  final int startLatencyUs;
  final int uncertaintyUs;
  const ParticipantTiming({
    required this.deviceId,
    required this.rttP95Us,
    required this.startLatencyUs,
    required this.uncertaintyUs,
  });
}

class LeadDecision {
  final int leadUs;

  /// Device that determined the lead (largest requirement), for diagnostics.
  final String? dominatedBy;
  final int requiredUs;
  final bool clampedToMin;
  final bool clampedToMax;
  const LeadDecision(this.leadUs, this.dominatedBy, this.requiredUs,
      {this.clampedToMin = false, this.clampedToMax = false});

  Map<String, Object?> toJson() => {
        'leadUs': leadUs,
        'requiredUs': requiredUs,
        'by': dominatedBy,
        if (clampedToMin) 'clampedMin': true,
        if (clampedToMax) 'clampedMax': true,
      };
}

LeadDecision computeLead(SchedulerConfig cfg, Iterable<ParticipantTiming> participants) {
  var worst = 0;
  String? by;
  for (final p in participants) {
    final need = (p.rttP95Us * cfg.rttMultiplier).round() + p.startLatencyUs + p.uncertaintyUs;
    if (need > worst) {
      worst = need;
      by = p.deviceId;
    }
  }
  final required = worst + cfg.safetyMargin.inMicroseconds;
  final minL = cfg.minLead.inMicroseconds;
  final maxL = math.max(cfg.maxLead.inMicroseconds, minL);
  final lead = required.clamp(minL, maxL);
  return LeadDecision(lead, by, required,
      clampedToMin: required < minL, clampedToMax: required > maxL);
}
