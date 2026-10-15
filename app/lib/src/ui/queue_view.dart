import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../state/providers.dart';
import '../state/room_controller.dart';
import 'format.dart';
import 'widgets.dart';

/// Queue tab: the room's playlist. Tap a song to play it (with control
/// rights); the host adds songs from its library.
class QueueView extends ConsumerWidget {
  const QueueView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room!;
    final connected = room.participants.where((p) => p.connection != ConnectionStatus.disconnected).length;
    final current = room.timeline.trackId ?? room.pending?.trackId;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        SectionHeader(
          '${room.playlist.length} song${room.playlist.length == 1 ? '' : 's'}',
          trailing: s.isHost
              ? FilledButton.tonalIcon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add songs'),
                  onPressed: () => _addTracks(context, ref),
                )
              : null,
        ),
        if (room.playlist.isEmpty)
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('The queue is empty'),
            subtitle: Text(s.isHost ? 'Tap "Add songs" to pick music from this phone.' : 'Waiting for the host to add songs.'),
          ),
        for (final t in room.playlist)
          ListTile(
            selected: t.id == current,
            leading: Icon(t.id == current ? Icons.equalizer : Icons.music_note_outlined),
            title: Text(t.title, overflow: TextOverflow.ellipsis),
            subtitle: Text('${t.artist ?? 'Unknown artist'} · ${fmtClock(t.durationUs)}'),
            trailing: t.availableCount >= connected
                ? null
                : Tooltip(
                    message: 'Phones that have this song ready',
                    child: Chip(
                      label: Text('${t.availableCount}/$connected'),
                      avatar: const Icon(Icons.download_outlined, size: 16),
                    ),
                  ),
            onTap: s.canControl
                ? () async {
                    final err = await ref.read(roomControllerProvider.notifier).control(ControlAction.setTrack, trackId: t.id);
                    if (err != null && context.mounted) showMessage(context, err, error: true);
                  }
                : null,
          ),
        if (!s.canControl && room.playlist.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Only the host (and phones it allows) can pick songs.', style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }

  Future<void> _addTracks(BuildContext context, WidgetRef ref) async {
    final lib = await ref.read(libraryProvider.future);
    final inRoom = ref.read(roomControllerProvider).room?.playlist.map((t) => t.id).toSet() ?? {};
    final candidates = lib.where((t) => !inRoom.contains(t.id)).toList();
    if (!context.mounted) return;
    if (candidates.isEmpty) {
      showMessage(context, lib.isEmpty ? 'Add music on the home screen first (My music → Add).' : 'All your songs are already in the queue.');
      return;
    }
    final chosen = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: const Text('Add songs'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              CheckboxListTile(
                value: chosen.length == candidates.length,
                title: const Text('Select all'),
                onChanged: (v) => setState(() => v == true ? chosen.addAll(candidates.map((t) => t.id)) : chosen.clear()),
              ),
              const Divider(height: 1),
              for (final t in candidates)
                CheckboxListTile(
                  value: chosen.contains(t.id),
                  title: Text(t.title),
                  subtitle: t.artist == null ? null : Text(t.artist!),
                  onChanged: (v) => setState(() => v == true ? chosen.add(t.id) : chosen.remove(t.id)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok == true && chosen.isNotEmpty) {
      ref.read(roomControllerProvider.notifier).addTracks(candidates.where((t) => chosen.contains(t.id)).toList());
    }
  }
}
