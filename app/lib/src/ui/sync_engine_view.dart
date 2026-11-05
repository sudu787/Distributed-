import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../state/providers.dart';
import '../state/room_controller.dart';
import '../state/sync_settings.dart';
import 'haptics.dart';
import 'widgets.dart';

String fmtSpread(int? us) => us == null ? '—' : '${(us / 1000).toStringAsFixed(us.abs() < 10000 ? 1 : 0)} ms';

/// How a measured gap between phones sounds.
String spreadVerdict(int? us) {
  if (us == null) return 'not measured';
  final ms = us / 1000;
  if (ms <= 10) return 'tight';
  if (ms <= 30) return 'slight echo';
  return 'clear echo';
}

/// Speakers tab: which sync engine the party uses (host can change it, with
/// a one-tap way back to Classic) and whether this phone fell back.
class SyncEngineCard extends ConsumerWidget {
  const SyncEngineCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room!;
    final me = ref.watch(identityProvider).deviceId;
    final mine = room.participant(me)?.engine;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final fallbacks = [
      for (final p in room.participants)
        if (p.engine != null) '${p.displayName} (${p.engine!.label})'
    ];

    Future<void> choose(SyncEngineMode m) async {
      haptic(ref, Haptic.tap);
      final err = await ref.read(roomControllerProvider.notifier).setSyncEngine(m);
      if (err != null && context.mounted) showMessage(context, err, error: true);
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.tune, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text('Sync engine: ${room.engine.label}', style: t.titleSmall)),
            if (s.isHost && room.engine != SyncEngineMode.classic)
              TextButton(onPressed: () => choose(SyncEngineMode.classic), child: const Text('Back to Classic')),
          ]),
          const SizedBox(height: 4),
          Text(room.engine.description, style: t.bodySmall),
          if (s.isHost) ...[
            const SizedBox(height: 12),
            SegmentedButton<SyncEngineMode>(
              segments: [
                for (final m in SyncEngineMode.values) ButtonSegment(value: m, label: Text(m.label)),
              ],
              selected: {room.engine},
              showSelectedIcon: false,
              onSelectionChanged: room.calibration != null ? null : (v) => choose(v.single),
            ),
          ],
          if (mine != null) ...[
            const SizedBox(height: 8),
            Text('This phone is using ${mine.label}: the ${room.engine.label} engine did not work here.',
                style: t.bodySmall?.copyWith(color: scheme.error)),
          ] else if (fallbacks.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Using another engine: ${fallbacks.join(', ')}', style: t.bodySmall?.copyWith(color: scheme.error)),
          ],
        ]),
      ),
    );
  }
}

/// Speakers tab: the Sync check (how far apart the phones really sound,
/// measured with this phone's microphone) and, for the host, a comparison
/// of all engines.
class SyncCheckCard extends ConsumerStatefulWidget {
  const SyncCheckCard({super.key});

  @override
  ConsumerState<SyncCheckCard> createState() => _SyncCheckCardState();
}

class _SyncCheckCardState extends ConsumerState<SyncCheckCard> {
  String? _progress;
  bool _requested = false;

  Future<void> _check() async {
    haptic(ref, Haptic.tap);
    setState(() => _requested = true);
    final err = await ref.read(roomControllerProvider.notifier).syncCheck();
    if (!mounted) return;
    if (err != null) {
      setState(() => _requested = false);
      showMessage(context, err, error: true);
    }
  }

  Future<void> _compare() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Compare sync engines?'),
        content: const Text(
          'Each engine plays a short click test in turn (about a minute in all). Hold this phone where you listen '
          'and keep the room quiet. Afterwards the party returns to the engine it uses now.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Start')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = await ref
        .read(roomControllerProvider.notifier)
        .compareEngines(progress: (p) => mounted ? setState(() => _progress = p.isEmpty ? null : p) : null);
    if (!mounted) return;
    setState(() => _progress = null);
    if (err != null) showMessage(context, err, error: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room!;
    final ctl = ref.read(roomControllerProvider.notifier);
    final t = Theme.of(context).textTheme;
    final running = room.calibration != null;
    if (!running && _requested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _requested = false);
      });
    }
    final busy = running || _progress != null || _requested;
    final canStart = s.canControl && ctl.hasMicrophone && !busy;
    final checks = room.syncChecks;
    final latest = checks.lastOrNull;
    final String note;
    if (_progress != null) {
      note = _progress!;
    } else if (running && room.calibration!.measureOnly) {
      note = 'Listening to the click test…';
    } else if (!ctl.hasMicrophone) {
      note = 'No microphone access on this phone; run the check from another phone.';
    } else if (!s.canControl) {
      note = 'Ask the host for control to run a sync check.';
    } else {
      note = 'Measures how far apart the phones sound where you stand.';
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.graphic_eq, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Sync check', style: t.titleSmall),
                Text(note, style: t.bodySmall),
              ]),
            ),
            const SizedBox(width: 8),
            busy
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : FilledButton.tonal(onPressed: canStart ? _check : null, child: const Text('Check')),
          ]),
          if (latest != null) ...[
            const SizedBox(height: 12),
            _CheckSummary(check: latest),
          ],
          if (checks.length > 1) ...[
            const SizedBox(height: 12),
            _CheckHistory(checks: checks),
          ],
          if (s.isHost && ctl.hasMicrophone) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: canStart ? _compare : null,
                icon: const Icon(Icons.compare_arrows),
                label: const Text('Compare engines'),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _CheckSummary extends StatelessWidget {
  final SyncCheckResult check;
  const _CheckSummary({required this.check});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (!check.ok) {
      return Text('Last check (${check.engine.label}) failed: ${check.error ?? 'fewer than two phones were heard'}.',
          style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Last check (${check.engine.label})', style: t.labelLarge),
      InfoRow('Gap at the start', '${fmtSpread(check.startSpreadUs)} · ${spreadVerdict(check.startSpreadUs)}'),
      InfoRow('Gap once settled', '${fmtSpread(check.settledSpreadUs)} · ${spreadVerdict(check.settledSpreadUs)}'),
      for (final d in check.devices)
        InfoRow(
          d.name,
          d.heard
              ? 'start ${_signed(d.startUs)} · settled ${_signed(d.settledUs)}'
              : 'not heard (turn it up and try again)',
        ),
      Text('Positive: heard later than the middle phone.', style: t.bodySmall),
    ]);
  }

  static String _signed(int? us) => us == null ? '—' : '${us >= 0 ? '+' : ''}${(us / 1000).toStringAsFixed(1)} ms';
}

/// Recent checks side by side; the best (smallest start gap) is marked.
class _CheckHistory extends StatelessWidget {
  final List<SyncCheckResult> checks;
  const _CheckHistory({required this.checks});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ok = checks.where((c) => c.ok).toList();
    SyncCheckResult? best;
    for (final c in ok) {
      final score = (c.startSpreadUs ?? 1 << 40) + (c.settledSpreadUs ?? 1 << 40);
      if (best == null || score < (best.startSpreadUs ?? 1 << 40) + (best.settledSpreadUs ?? 1 << 40)) best = c;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Recent checks (start gap / settled gap)', style: t.labelLarge),
      for (final c in checks.reversed)
        InfoRow(
          '${identical(c, best) && ok.length > 1 ? '★ ' : ''}${c.engine.label}',
          c.ok ? '${fmtSpread(c.startSpreadUs)} / ${fmtSpread(c.settledSpreadUs)}' : 'failed',
        ),
    ]);
  }
}

/// Settings → Sync engine: the engine for parties this phone hosts, and
/// the per-phone switches (to turn a misbehaving part off without a new
/// app).
class SyncOptionsSheet extends ConsumerWidget {
  const SyncOptionsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(hostEngineProvider);
    final flags = ref.watch(featureFlagsProvider);
    final setFlags = ref.read(featureFlagsProvider.notifier).set;
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const SectionHeader('Engine for parties I host'),
        RadioGroup<SyncEngineMode>(
          groupValue: engine,
          onChanged: (m) async {
            if (m == null) return;
            final err = await ref.read(hostEngineProvider.notifier).set(m);
            if (err != null && context.mounted) showMessage(context, err, error: true);
          },
          child: Column(children: [
            for (final m in SyncEngineMode.values)
              RadioListTile<SyncEngineMode>(
                value: m,
                title: Text(m.label),
                subtitle: Text(m.description),
              ),
          ]),
        ),
        const SectionHeader('Switches on this phone'),
        SwitchListTile(
          title: const Text('Keep the speaker awake'),
          subtitle: const Text('Warm start: plays silence between songs so every start takes the same time'),
          value: flags.keepAwake,
          onChanged: (v) => setFlags(flags.copyWith(keepAwake: v)),
        ),
        SwitchListTile(
          title: const Text('Silent test start'),
          subtitle: const Text('Warm start: measures this phone\'s start delay before the first song'),
          value: flags.startProbe,
          onChanged: (v) => setFlags(flags.copyWith(startProbe: v)),
        ),
        SwitchListTile(
          title: const Text('Fall back to Classic'),
          subtitle: const Text('If the Precise engine fails on this phone, use Classic instead of going silent'),
          value: flags.preciseFallback,
          onChanged: (v) => setFlags(flags.copyWith(preciseFallback: v)),
        ),
        SwitchListTile(
          title: const Text('Left/right speaker roles'),
          subtitle: const Text('Experimental; off plays full stereo on this phone'),
          value: flags.channelRoles,
          onChanged: (v) => setFlags(flags.copyWith(channelRoles: v)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text('Classic is the original engine. If anything sounds wrong, choose Classic.', style: t.bodySmall),
        ),
      ]),
    );
  }
}
