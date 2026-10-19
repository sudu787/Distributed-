import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../state/room_controller.dart';
import 'haptics.dart';
import 'widgets.dart';

/// Compact player shown above the tab bar on the Queue and Speakers tabs:
/// what is playing, its progress, and previous / play-pause / next. Tap it
/// to open the Playing tab.
class NowPlayingBar extends ConsumerStatefulWidget {
  final VoidCallback onOpen;
  const NowPlayingBar({super.key, required this.onOpen});

  @override
  ConsumerState<NowPlayingBar> createState() => _NowPlayingBarState();
}

class _NowPlayingBarState extends ConsumerState<NowPlayingBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Progress comes from the shared timeline; redraw twice a second.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _ctl(ControlAction a) async {
    haptic(ref, Haptic.action);
    final err = await ref.read(roomControllerProvider.notifier).control(a);
    if (err != null && mounted) {
      haptic(ref, Haptic.alert);
      showMessage(context, err, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room;
    final tl = room?.timeline;
    final pending = room?.pending;
    final track = room?.trackById(pending?.trackId ?? tl?.trackId);
    if (room == null || track == null || room.isCalibrationTrack(track.id)) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final playing = (tl?.isPlaying ?? false) || (pending?.autoPlay ?? false);
    final pos = ref.read(roomControllerProvider.notifier).expectedPositionUs() ?? 0;
    final dur = track.durationUs;
    final next = room.trackById(room.upNext);
    final canControl = s.canControl;

    return Material(
      color: cs.surfaceContainerHigh,
      child: InkWell(
        onTap: widget.onOpen,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(
            value: dur == null || dur <= 0 ? 0 : (pos / dur).clamp(0.0, 1.0),
            minHeight: 2,
            backgroundColor: cs.surfaceContainerHighest,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(children: [
              TrackArt(track.id, size: 44, url: track.artUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  label: 'Now playing: ${track.title}. Tap to open the player.',
                  excludeSemantics: true,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(track.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      next != null && next.id != track.id ? 'Next: ${next.title}' : (track.artist ?? 'Unknown artist'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ]),
                ),
              ),
              IconButton(
                tooltip: 'Previous',
                icon: const Icon(Icons.skip_previous_rounded),
                onPressed: canControl ? () => _ctl(ControlAction.previous) : null,
              ),
              IconButton.filledTonal(
                tooltip: playing ? 'Pause' : 'Play',
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(playing)),
                ),
                onPressed: canControl ? () => _ctl(playing ? ControlAction.pause : ControlAction.play) : null,
              ),
              IconButton(
                tooltip: 'Next',
                icon: const Icon(Icons.skip_next_rounded),
                onPressed: canControl ? () => _ctl(ControlAction.next) : null,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
