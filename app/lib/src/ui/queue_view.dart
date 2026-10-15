import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/models.dart';
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
                  onPressed: () => _chooseSource(context, ref),
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

  Future<void> _chooseSource(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('From this phone…'),
            subtitle: const Text('Pick audio files; they are added to My music and the queue'),
            onTap: () => Navigator.pop(c, 'phone'),
          ),
          ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: const Text('From My music'),
            onTap: () => Navigator.pop(c, 'library'),
          ),
        ]),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice == 'phone') {
      await _addFromPhone(context, ref);
    } else {
      await _addTracks(context, ref);
    }
  }

  /// Imports new files during a party and queues them right away.
  Future<void> _addFromPhone(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(type: FileType.audio, dialogTitle: 'Add songs');
    final files = [for (final f in picked) if (f.path != null) File(f.path!)];
    if (files.isEmpty) return;
    final lib = ref.read(libraryServiceProvider);
    final added = <LibraryTrack>[];
    final errors = <String>[];
    for (final f in files) {
      try {
        added.add(await lib.import(f));
      } catch (e) {
        errors.add('${f.uri.pathSegments.last}: $e');
      }
    }
    ref.invalidate(libraryProvider);
    final inRoom = ref.read(roomControllerProvider).room?.playlist.map((t) => t.id).toSet() ?? {};
    final fresh = [for (final t in added) if (!inRoom.contains(t.id)) t];
    if (fresh.isNotEmpty) ref.read(roomControllerProvider.notifier).addTracks(fresh);
    if (!context.mounted) return;
    showMessage(
      context,
      errors.isEmpty
          ? 'Added ${fresh.length} song${fresh.length == 1 ? '' : 's'} to the queue.'
          : 'Some files could not be added: ${errors.join('; ')}',
      error: errors.isNotEmpty,
    );
  }

  Future<void> _addTracks(BuildContext context, WidgetRef ref) async {
    final lib = await ref.read(libraryProvider.future);
    final inRoom = ref.read(roomControllerProvider).room?.playlist.map((t) => t.id).toSet() ?? {};
    final candidates = lib.where((t) => !inRoom.contains(t.id)).toList();
    if (!context.mounted) return;
    if (candidates.isEmpty) {
      showMessage(context, lib.isEmpty ? 'No songs in My music yet. Use "From this phone…".' : 'All your songs are already in the queue.');
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
