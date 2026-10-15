import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../state/providers.dart';
import '../state/room_controller.dart';
import 'format.dart';
import 'widgets.dart';

/// Screen 3: the shared player.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  Timer? _tick;
  double? _dragPos;

  @override
  void initState() {
    super.initState();
    // Redraw the position ~5×/s; the position itself comes from the shared
    // timeline and this device's clock estimate, not from a local timer.
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _ctl(ControlAction a, {int? positionUs, double? value, String? targetDevice}) async {
    final err = await ref
        .read(roomControllerProvider.notifier)
        .control(a, positionUs: positionUs, value: value, targetDevice: targetDevice);
    if (err != null && mounted) showMessage(context, err, error: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomControllerProvider);
    if (s.status == RoomStatus.none) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      });
    }
    final room = s.room;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final tl = room?.timeline;
    final pending = room?.pending;
    final track = room?.trackById(pending?.trackId ?? tl?.trackId);
    final pos = ref.read(roomControllerProvider.notifier).expectedPositionUs() ?? 0;
    final dur = track?.durationUs;
    final playing = (tl?.isPlaying ?? false) || (pending?.autoPlay ?? false);
    final me = room?.participant(ref.watch(identityProvider).deviceId);
    final canControl = s.canControl;

    return Scaffold(
      appBar: AppBar(title: const Text('Now playing')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            AspectRatio(
              aspectRatio: 1.4,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: LinearGradient(
                    colors: [cs.primaryContainer, cs.tertiaryContainer],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Icon(Icons.music_note, size: 96, color: cs.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: 20),
            Text(track?.title ?? 'Nothing selected', style: t.headlineSmall, textAlign: TextAlign.center),
            Text(track?.artist ?? (track == null ? 'Pick a track in the room playlist' : 'Unknown artist'),
                style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Center(child: _StatusLine(s: s, positionUs: pos)),
            const SizedBox(height: 8),
            Slider(
              value: (_dragPos ?? pos.toDouble()).clamp(0, (dur ?? 1).toDouble()),
              max: (dur ?? 1).toDouble(),
              onChanged: canControl && dur != null ? (v) => setState(() => _dragPos = v) : null,
              onChangeEnd: canControl && dur != null
                  ? (v) {
                      setState(() => _dragPos = null);
                      _ctl(ControlAction.seek, positionUs: v.round());
                    }
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(fmtClock(_dragPos?.round() ?? pos), style: t.bodySmall),
                Text(fmtClock(dur), style: t.bodySmall),
              ]),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                iconSize: 40,
                tooltip: 'Previous',
                icon: const Icon(Icons.skip_previous_rounded),
                onPressed: canControl ? () => _ctl(ControlAction.previous) : null,
              ),
              const SizedBox(width: 16),
              IconButton.filled(
                iconSize: 56,
                tooltip: playing ? 'Pause' : 'Play',
                icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                onPressed: canControl ? () => _ctl(playing ? ControlAction.pause : ControlAction.play) : null,
              ),
              const SizedBox(width: 16),
              IconButton(
                iconSize: 40,
                tooltip: 'Next',
                icon: const Icon(Icons.skip_next_rounded),
                onPressed: canControl ? () => _ctl(ControlAction.next) : null,
              ),
            ]),
            if (!canControl)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  s.isLive ? 'You are a listener. The host controls playback.' : 'Controls are disabled while disconnected.',
                  textAlign: TextAlign.center,
                  style: t.bodySmall,
                ),
              ),
            const SizedBox(height: 16),
            _VolumeRow(
              label: 'Room volume',
              icon: Icons.speaker_group_outlined,
              value: room?.masterVolume ?? 1,
              onChanged: canControl ? (v) => _ctl(ControlAction.masterVolume, value: v) : null,
            ),
            _VolumeRow(
              label: 'This device',
              icon: Icons.smartphone,
              value: me?.volume ?? 1,
              onChanged: s.isLive && me != null
                  ? (v) => _ctl(ControlAction.deviceVolume, value: v, targetDevice: me.deviceId)
                  : null,
            ),
            const SizedBox(height: 12),
            _SyncCard(s: s),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final RoomViewState s;
  final int positionUs;
  const _StatusLine({required this.s, required this.positionUs});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final room = s.room;
    final e = s.engine;
    if (!s.isLive) {
      return StatusChip('Reconnecting — playing on last known timeline', Icons.sync_problem, color: const Color(0xFFD99A1E));
    }
    if (room == null) return const SizedBox.shrink();
    if (room.pending != null) return const StatusChip('Preparing on all devices…', Icons.downloading);
    final tl = room.timeline;
    if (e?.buffering ?? false) return StatusChip('Buffering', Icons.hourglass_bottom, color: cs.error);
    switch (tl.status) {
      case PlaybackStatus.idle:
        return const StatusChip('Stopped', Icons.stop_circle_outlined);
      case PlaybackStatus.paused:
        return const StatusChip('Paused', Icons.pause_circle_outline);
      case PlaybackStatus.playing:
        if (positionUs <= tl.anchorPositionUs && e?.activeGeneration != tl.generation) {
          return const StatusChip('Starting together…', Icons.timer_outlined);
        }
        final mode = e?.mode ?? CorrectionMode.waiting;
        final h = healthOf(e?.lastErrorUs, mode);
        final err = e?.lastErrorUs == null ? '' : ' · ${fmtMs(e!.lastErrorUs, signed: true)} (est.)';
        return StatusChip('Playing · ${modeLabel(mode)}$err', Icons.graphic_eq, color: healthColor(h, cs));
    }
  }
}

class _VolumeRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final double value;
  final ValueChanged<double>? onChanged;
  const _VolumeRow({required this.label, required this.icon, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 20),
      const SizedBox(width: 8),
      SizedBox(width: 92, child: Text(label)),
      Expanded(child: _DebouncedSlider(value: value, onChanged: onChanged)),
    ]);
  }
}

/// Sends a value only when the drag ends, to avoid flooding the room with
/// state versions while the user drags.
class _DebouncedSlider extends StatefulWidget {
  final double value;
  final ValueChanged<double>? onChanged;
  const _DebouncedSlider({required this.value, required this.onChanged});

  @override
  State<_DebouncedSlider> createState() => _DebouncedSliderState();
}

class _DebouncedSliderState extends State<_DebouncedSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) => Slider(
        value: _drag ?? widget.value,
        onChanged: widget.onChanged == null ? null : (v) => setState(() => _drag = v),
        onChangeEnd: widget.onChanged == null
            ? null
            : (v) {
                setState(() => _drag = null);
                widget.onChanged!(v);
              },
      );
}

class _SyncCard extends StatelessWidget {
  final RoomViewState s;
  const _SyncCard({required this.s});

  @override
  Widget build(BuildContext context) {
    final e = s.engine;
    final c = s.clock;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Synchronization', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          InfoRow('This device vs. timeline', fmtMs(e?.lastErrorUs, signed: true), estimate: true),
          InfoRow('Room spread', fmtMs(s.diagnostics?.maxPairwiseErrorUs), estimate: true),
          InfoRow('Correction', e == null ? '—' : '${modeLabel(e.mode)} · rate ${e.rate.toStringAsFixed(4)}'),
          InfoRow('Clock uncertainty', fmtMs(c?.uncertaintyMicros), estimate: true),
          const SizedBox(height: 6),
          Text(
            'Software estimates from network timing and the player\'s reported position. '
            'They cannot see Bluetooth or speaker delays; see Diagnostics.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}
