import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../state/providers.dart';
import '../state/room_controller.dart';
import 'format.dart';
import 'haptics.dart';
import 'room_screen.dart' show DeviceSettingsSheet, startSpotCalibration;
import 'speaker_layout.dart';
import 'widgets.dart';

/// Playing tab: what is playing and the shared controls.
class NowPlayingView extends ConsumerStatefulWidget {
  const NowPlayingView({super.key});

  @override
  ConsumerState<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends ConsumerState<NowPlayingView> {
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

  Future<void> _ctl(ControlAction a, {int? positionUs, double? value, String? targetDevice}) {
    if (const {ControlAction.play, ControlAction.pause, ControlAction.next, ControlAction.previous, ControlAction.seek}
        .contains(a)) {
      haptic(ref, Haptic.action);
    }
    return _result(ref.read(roomControllerProvider.notifier).control(a, positionUs: positionUs, value: value, targetDevice: targetDevice));
  }

  Future<void> _result(Future<String?> f) async {
    final err = await f;
    if (err != null && mounted) {
      haptic(ref, Haptic.alert);
      showMessage(context, err, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final tl = room?.timeline;
    final pending = room?.pending;
    final track = room?.trackById(pending?.trackId ?? tl?.trackId);
    final pos = ref.read(roomControllerProvider.notifier).expectedPositionUs() ?? 0;
    final dur = track?.durationUs;
    final playing = (tl?.isPlaying ?? false) || (pending?.autoPlay ?? false);
    final myId = ref.watch(identityProvider).deviceId;
    final me = room?.participant(myId);
    final canControl = s.canControl;
    final ctl = ref.read(roomControllerProvider.notifier);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, c) => TrackArt(track?.id, size: c.maxWidth.clamp(120.0, 300.0) * 0.8, url: track?.artUrl),
          ),
        ),
        if (room != null && room.calibration == null) const _CalibrationTip(),
        const SizedBox(height: 20),
        Text(track?.title ?? 'Nothing playing', style: t.headlineSmall, textAlign: TextAlign.center),
        Text(
            track == null
                ? 'Pick a song in the Queue tab'
                : [track.artist ?? 'Unknown artist', if (track.credit != null) track.credit!].join(' · '),
            style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Center(child: _StatusLine(s: s, positionUs: pos)),
        if (me != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ActionChip(
                avatar: ChannelBadge(me.channel),
                label: Text(switch (me.channel) {
                  ChannelRole.left => 'This phone plays the LEFT channel',
                  ChannelRole.right => 'This phone plays the RIGHT channel',
                  ChannelRole.mono => 'This phone plays a mono mix',
                  ChannelRole.stereo => 'This phone plays full stereo',
                  ChannelRole.center => 'This phone is the CENTER speaker',
                  ChannelRole.surroundLeft => 'This phone is the SURROUND LEFT speaker',
                  ChannelRole.surroundRight => 'This phone is the SURROUND RIGHT speaker',
                }),
                onPressed: () => ctl.identify(myId),
              ),
            ),
          ),
        const SizedBox(height: 4),
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
            tooltip: room?.shuffle ?? false ? 'Shuffle on' : 'Shuffle off',
            isSelected: room?.shuffle ?? false,
            icon: const Icon(Icons.shuffle_rounded),
            selectedIcon: Icon(Icons.shuffle_on_rounded, color: cs.primary),
            onPressed: canControl
                ? () {
                    haptic(ref, Haptic.tap);
                    _result(ctl.setShuffle(!(room?.shuffle ?? false)));
                  }
                : null,
          ),
          const SizedBox(width: 4),
          IconButton(
            iconSize: 40,
            tooltip: 'Previous',
            icon: const Icon(Icons.skip_previous_rounded),
            onPressed: canControl ? () => _ctl(ControlAction.previous) : null,
          ),
          const SizedBox(width: 12),
          IconButton.filled(
            iconSize: 56,
            tooltip: playing ? 'Pause' : 'Play',
            icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            onPressed: canControl ? () => _ctl(playing ? ControlAction.pause : ControlAction.play) : null,
          ),
          const SizedBox(width: 12),
          IconButton(
            iconSize: 40,
            tooltip: 'Next',
            icon: const Icon(Icons.skip_next_rounded),
            onPressed: canControl ? () => _ctl(ControlAction.next) : null,
          ),
          const SizedBox(width: 4),
          _RepeatButton(
            mode: room?.repeat ?? PlaylistRepeat.off,
            onPressed: canControl
                ? (next) {
                    haptic(ref, Haptic.tap);
                    _result(ctl.setRepeat(next));
                  }
                : null,
          ),
        ]),
        if (!canControl)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              s.isLive ? 'You are a listener. The host controls the music.' : 'Controls are disabled while disconnected.',
              textAlign: TextAlign.center,
              style: t.bodySmall,
            ),
          ),
        const SizedBox(height: 16),
        _VolumeRow(
          label: 'Everyone',
          icon: Icons.speaker_group_outlined,
          value: room?.masterVolume ?? 1,
          onChanged: canControl ? (v) => _ctl(ControlAction.masterVolume, value: v) : null,
        ),
        _VolumeRow(
          label: 'This phone',
          icon: Icons.smartphone,
          value: me?.volume ?? 1,
          onChanged: s.isLive && me != null ? (v) => _ctl(ControlAction.deviceVolume, value: v, targetDevice: myId) : null,
        ),
        const SizedBox(height: 8),
        if (s.isLive && me != null)
          Center(
            child: TextButton.icon(
              icon: const Icon(Icons.tune),
              label: const Text('This phone sounds early or late?'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => DeviceSettingsSheet(deviceId: myId),
              ),
            ),
          ),
      ],
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
      return StatusChip('Reconnecting… music keeps playing', Icons.sync_problem, color: const Color(0xFFD99A1E));
    }
    if (room == null) return const SizedBox.shrink();
    if (room.calibration != null) return const StatusChip('Calibrating…', Icons.hearing);
    if (room.pending != null) return const StatusChip('Getting every phone ready…', Icons.downloading);
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
        final (h, label) = roomSyncSummary(s.diagnostics?.maxPairwiseErrorUs, live: true, playing: true);
        return StatusChip(label, Icons.graphic_eq, color: healthColor(h, cs));
    }
  }
}

/// Cycles off → all → one.
class _RepeatButton extends StatelessWidget {
  final PlaylistRepeat mode;
  final ValueChanged<PlaylistRepeat>? onPressed;
  const _RepeatButton({required this.mode, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final next = PlaylistRepeat.values[(mode.index + 1) % PlaylistRepeat.values.length];
    return IconButton(
      tooltip: switch (mode) {
        PlaylistRepeat.off => 'Repeat off',
        PlaylistRepeat.all => 'Repeat playlist',
        PlaylistRepeat.one => 'Repeat track',
      },
      icon: Icon(
        mode == PlaylistRepeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
        color: mode == PlaylistRepeat.off ? null : cs.primary,
      ),
      onPressed: onPressed == null ? null : () => onPressed!(next),
    );
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
      Expanded(child: DebouncedSlider(value: value, onChanged: onChanged)),
    ]);
  }
}

/// Sends a value only when the drag ends, to avoid flooding the room with
/// state versions while the user drags.
class DebouncedSlider extends StatefulWidget {
  final double value;
  final ValueChanged<double>? onChanged;
  const DebouncedSlider({super.key, required this.value, required this.onChanged});

  @override
  State<DebouncedSlider> createState() => _DebouncedSliderState();
}

class _DebouncedSliderState extends State<DebouncedSlider> {
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

/// Shown until this phone has a saved calibration: a fresh install (or an
/// app reinstall) loses it, and uncalibrated phones are audibly less in sync.
class _CalibrationTip extends ConsumerWidget {
  const _CalibrationTip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calibrated = ref.watch(identityProvider.select((i) => i.outputCalibrationUs != 0));
    if (calibrated || ref.watch(calibrationTipDismissedProvider)) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final ctl = ref.read(roomControllerProvider.notifier);
    return Card(
      margin: const EdgeInsets.only(top: 16),
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.my_location, color: cs.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Calibrate for the best sync',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onSecondaryContainer)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            'This phone has not been calibrated yet. Stand where you listen and let every phone click once; the app '
            'remembers the result.',
            style: TextStyle(color: cs.onSecondaryContainer),
          ),
          OverflowBar(alignment: MainAxisAlignment.end, spacing: 8, children: [
            TextButton(
              onPressed: () => ref.read(calibrationTipDismissedProvider.notifier).dismiss(),
              child: const Text('Not now'),
            ),
            FilledButton.tonal(
              onPressed: ctl.hasMicrophone
                  ? () async {
                      final r = await startSpotCalibration(context, ref);
                      if (r.error != null && context.mounted) showMessage(context, r.error!, error: true);
                    }
                  : null,
              child: const Text('Calibrate now'),
            ),
          ]),
        ]),
      ),
    );
  }
}
