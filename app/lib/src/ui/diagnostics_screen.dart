import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../state/providers.dart';
import '../state/room_controller.dart';
import 'format.dart';
import 'widgets.dart';

/// Screen 4: per-device diagnostics. Every timing value here is an
/// estimate and labelled as such.
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room;
    final me = ref.watch(identityProvider);
    final diags = s.diagnostics?.participants ?? const <ParticipantDiagnostics>[];
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'All timing values are software estimates: clock offsets come from network round trips '
                '(bounded by half the round-trip time, because one-way delays are unknown), and playback '
                'errors come from the audio framework\'s reported position. None of them measures when sound '
                'actually leaves a speaker. Acoustic alignment needs an external microphone (docs/benchmarking.md).',
                style: t.bodySmall,
              ),
            ),
          ),
          const SectionHeader('This device'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              InfoRow('Device ID', me.deviceId),
              InfoRow('Session', s.phase?.name ?? '—'),
              InfoRow('Clock offset to coordinator', fmtEstimate(s.clock?.offsetMicros, s.clock?.uncertaintyMicros), estimate: true),
              InfoRow('Relative clock skew', s.clock == null ? '—' : '${s.clock!.skewPpm.toStringAsFixed(1)} ppm', estimate: true),
              InfoRow('Clock samples (used / window)', s.clock == null ? '—' : '${s.clock!.samplesUsed} / ${s.clock!.samplesInWindow}'),
              InfoRow('Min / p95 round trip', '${fmtMs(s.clock?.minDelayMicros)} / ${fmtMs(s.rttP95Us)}'),
              InfoRow('Playback error vs timeline', fmtMs(s.engine?.lastErrorUs, signed: true), estimate: true),
              InfoRow('Correction mode', s.engine == null ? '—' : modeLabel(s.engine!.mode)),
              InfoRow('Start-latency compensation', fmtMs(s.engine?.startLatencyUs), estimate: true),
              InfoRow('Player state', s.engine?.playerState ?? '—'),
              if (s.engine?.lastError != null) InfoRow('Last error', s.engine!.lastError!),
              _CalibrationRow(current: me.outputCalibrationUs),
            ]),
          ),
          SectionHeader('Participants (${diags.length})'),
          for (final d in diags) _ParticipantCard(d: d, summary: room?.participant(d.deviceId)),
          const SectionHeader('Recent events'),
          if (s.events.isEmpty) const ListTile(title: Text('No events yet')),
          for (final e in s.events)
            ListTile(
              dense: true,
              leading: Icon(
                switch (e.level) {
                  EventLevel.error => Icons.error_outline,
                  EventLevel.warn => Icons.warning_amber,
                  _ => Icons.info_outline,
                },
                size: 18,
              ),
              title: Text(e.message, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${e.category} · ${TimeOfDay.fromDateTime(e.wallTime).format(context)}'),
            ),
        ],
      ),
    );
  }
}

class _ParticipantCard extends StatelessWidget {
  final ParticipantDiagnostics d;
  final ParticipantSummary? summary;
  const _ParticipantCard({required this.d, required this.summary});

  @override
  Widget build(BuildContext context) {
    final h = healthOf(d.errorUs, d.mode, connection: summary?.connection ?? ConnectionStatus.connected);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            HealthDot(h, size: 12),
            const SizedBox(width: 8),
            Expanded(child: Text(summary?.displayName ?? d.deviceId, style: Theme.of(context).textTheme.titleSmall)),
          ]),
          const SizedBox(height: 6),
          InfoRow('Device ID', d.deviceId),
          InfoRow('Connection', summary?.connection.name ?? 'unknown'),
          InfoRow('Clock offset', fmtEstimate(d.offsetUs, d.uncertaintyUs), estimate: true),
          InfoRow('Playback error', fmtMs(d.errorUs, signed: true), estimate: true),
          InfoRow('Correction', '${modeLabel(d.mode)} · rate ${d.rate.toStringAsFixed(4)}'),
          InfoRow('Last sync report', d.lastReportAgeMs == null ? '—' : '${(d.lastReportAgeMs! / 1000).toStringAsFixed(1)} s ago'),
          InfoRow('Buffering state', d.playerState),
          InfoRow('Audio backend', d.backend),
          InfoRow('Round trip p95', fmtMs(d.rttP95Us)),
        ]),
      ),
    );
  }
}

class _CalibrationRow extends ConsumerWidget {
  final int current;
  const _CalibrationRow({required this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Acoustic calibration offset'),
      subtitle: const Text('Extra output delay of this device measured with a microphone (e.g. Bluetooth).'),
      trailing: TextButton(
        child: Text(fmtMs(current)),
        onPressed: () async {
          final ctl = TextEditingController(text: (current / 1000).toStringAsFixed(0));
          final v = await showDialog<int>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Calibration offset (ms)'),
              content: TextField(
                controller: ctl,
                keyboardType: const TextInputType.numberWithOptions(signed: true),
                decoration: const InputDecoration(helperText: 'Positive = this device sounds later than reported'),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () {
                    final ms = int.tryParse(ctl.text.trim());
                    Navigator.pop(c, ms == null ? null : ms.clamp(-1000, 1000) * 1000);
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          );
          if (v != null) await ref.read(roomControllerProvider.notifier).setCalibration(v);
        },
      ),
    );
  }
}
