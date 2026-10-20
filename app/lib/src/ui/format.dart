import 'package:flutter/material.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

/// Formats a microsecond quantity as milliseconds. Precision is capped at
/// 0.1 ms on purpose: finer digits would suggest accuracy the estimates do
/// not have.
String fmtMs(num? us, {int decimals = 1, bool signed = false}) {
  if (us == null) return '—';
  final ms = us / 1000;
  final s = ms.abs() >= 100 ? ms.toStringAsFixed(0) : ms.toStringAsFixed(decimals);
  return '${signed && ms >= 0 ? '+' : ''}$s ms';
}

String fmtClock(int? us) {
  if (us == null || us < 0) return '0:00';
  final total = us ~/ 1000000;
  final m = total ~/ 60, s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String fmtEstimate(num? valueUs, num? uncertaintyUs) {
  if (valueUs == null) return '—';
  final u = uncertaintyUs == null ? '' : ' ± ${fmtMs(uncertaintyUs)}';
  return '${fmtMs(valueUs, signed: true)}$u';
}

String modeLabel(CorrectionMode m) => switch (m) {
      CorrectionMode.idle => 'idle',
      CorrectionMode.waiting => 'measuring',
      CorrectionMode.inSync => 'in sync',
      CorrectionMode.rateCorrecting => 'adjusting rate',
      CorrectionMode.resyncing => 'resyncing',
    };

enum SyncHealth { good, fair, poor, unknown }

SyncHealth healthOf(int? errorUs, CorrectionMode mode, {ConnectionStatus connection = ConnectionStatus.connected}) {
  if (connection == ConnectionStatus.disconnected) return SyncHealth.poor;
  if (errorUs == null || mode == CorrectionMode.idle || mode == CorrectionMode.waiting) return SyncHealth.unknown;
  if (mode == CorrectionMode.resyncing) return SyncHealth.poor;
  final a = errorUs.abs();
  if (a < 20000) return SyncHealth.good;
  if (a < 50000) return SyncHealth.fair;
  return SyncHealth.poor;
}

Color healthColor(SyncHealth h, ColorScheme cs) => switch (h) {
      SyncHealth.good => const Color(0xFF2E9E5B),
      SyncHealth.fair => const Color(0xFFD99A1E),
      SyncHealth.poor => cs.error,
      SyncHealth.unknown => cs.outline,
    };

String roleLabel(ParticipantRole r) => switch (r) {
      ParticipantRole.host => 'Host',
      ParticipantRole.controller => 'Controller',
      ParticipantRole.listener => 'Listener',
    };

String availabilityLabel(TrackAvailability a) => switch (a) {
      TrackAvailability.available => 'has track',
      TrackAvailability.fetching => 'downloading',
      TrackAvailability.missing => 'missing track',
      TrackAvailability.mismatch => 'different file',
      TrackAvailability.unknown => 'checking…',
    };

String distributionLabel(DistributionMode m) => switch (m) {
      DistributionMode.localOnly => 'Matching local files only',
      DistributionMode.auto => 'Local file, else download from host',
      DistributionMode.lanOnly => 'Always download from host',
    };

String channelLabel(ChannelRole c) => switch (c) {
      ChannelRole.stereo => 'Stereo',
      ChannelRole.left => 'Left channel (experimental)',
      ChannelRole.right => 'Right channel (experimental)',
      ChannelRole.mono => 'Mono mix',
    };

/// Room-wide sync summary from the coordinator's diagnostics (estimate).
(SyncHealth, String) roomSyncSummary(int? maxPairwiseErrorUs, {required bool live, required bool playing}) {
  if (!live) return (SyncHealth.poor, 'Reconnecting…');
  if (!playing) return (SyncHealth.unknown, 'Ready');
  if (maxPairwiseErrorUs == null) return (SyncHealth.unknown, 'Syncing…');
  final a = maxPairwiseErrorUs.abs();
  if (a < 20000) return (SyncHealth.good, 'In sync');
  if (a < 50000) return (SyncHealth.fair, 'Almost in sync');
  return (SyncHealth.poor, 'Out of sync – correcting');
}

/// Human wording for an output offset: positive plays earlier.
String offsetLabel(int? offsetUs) {
  final ms = ((offsetUs ?? 0) / 1000).round();
  if (ms == 0) return 'No adjustment';
  return ms > 0 ? 'Plays $ms ms earlier' : 'Plays ${-ms} ms later';
}
