import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/models.dart';
import '../state/providers.dart';
import '../state/room_controller.dart';
import 'add_music.dart';
import 'format.dart';
import 'haptics.dart';
import 'widgets.dart';

/// Queue tab: the room's playlist. Everyone allowed to control the music
/// can pick a song and add songs (a guest's songs are sent to the host).
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
          trailing: s.canControl
              ? FilledButton.tonalIcon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add songs'),
                  onPressed: s.adding != null ? null : () => _chooseSource(context, ref),
                )
              : null,
        ),
        if (s.adding case (final done, final total))
          ListTile(
            leading: const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            title: Text(s.isHost ? 'Adding songs…' : 'Sending songs to the host… ${done + 1 > total ? total : done + 1} of $total'),
            subtitle: total == 0 ? null : LinearProgressIndicator(value: done / total),
          ),
        if (room.playlist.isEmpty)
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('The queue is empty'),
            subtitle: Text(s.canControl ? 'Tap "Add songs" to pick music from this phone.' : 'Waiting for the host to add songs.'),
          ),
        for (final t in room.playlist)
          ListTile(
            selected: t.id == current,
            leading: Stack(alignment: Alignment.center, children: [
              TrackArt(t.id, size: 44, url: t.artUrl),
              if (t.id == current)
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(44 * 0.14)),
                  child: const Icon(Icons.equalizer, color: Colors.white),
                ),
            ]),
            title: Text(t.title, overflow: TextOverflow.ellipsis),
            subtitle: Text([t.artist ?? 'Unknown artist', fmtClock(t.durationUs), if (t.credit != null) t.credit!].join(' · ')),
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
                    haptic(ref, Haptic.action);
                    final err = await ref.read(roomControllerProvider.notifier).control(ControlAction.setTrack, trackId: t.id);
                    if (err != null && context.mounted) showMessage(context, err, error: true);
                  }
                : null,
          ),
        if (!s.canControl && room.playlist.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Only the host and phones it allows to control the music can pick or add songs.',
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }

  Future<void> _chooseSource(BuildContext context, WidgetRef ref) async {
    haptic(ref, Haptic.tap);
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
          ListTile(
            leading: const Icon(Icons.travel_explore),
            title: const Text('Search Audius'),
            subtitle: const Text('Free music from independent artists'),
            onTap: () => Navigator.pop(c, 'audius'),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('From a link'),
            subtitle: const Text('Your own music server, a podcast or any audio file link'),
            onTap: () => Navigator.pop(c, 'link'),
          ),
        ]),
      ),
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'phone':
        await _addFromPhone(context, ref);
      case 'library':
        await _addTracks(context, ref);
      case 'audius':
        final added = await showAudiusSearch(context);
        if (context.mounted) await _queue(context, ref, added);
      case 'link':
        final t = await addFromLink(context, ref);
        if (t != null && context.mounted) await _queue(context, ref, [t]);
    }
  }

  /// Queues songs just added to My music (skipping ones already queued).
  Future<void> _queue(BuildContext context, WidgetRef ref, List<LibraryTrack> added) async {
    if (added.isEmpty) return;
    final inRoom = ref.read(roomControllerProvider).room?.playlist.map((t) => t.id).toSet() ?? {};
    final fresh = [for (final t in added) if (!inRoom.contains(t.id)) t];
    final err = await ref.read(roomControllerProvider.notifier).addTracks(fresh);
    if (!context.mounted) return;
    haptic(ref, err == null ? Haptic.action : Haptic.alert);
    showMessage(context, err ?? 'Added ${fresh.length} song${fresh.length == 1 ? '' : 's'} to the queue.', error: err != null);
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
    final err = await ref.read(roomControllerProvider.notifier).addTracks(fresh);
    if (err != null) errors.add(err);
    if (!context.mounted) return;
    haptic(ref, errors.isEmpty ? Haptic.action : Haptic.alert);
    showMessage(
      context,
      errors.isEmpty
          ? 'Added ${fresh.length} song${fresh.length == 1 ? '' : 's'} to the queue.'
          : 'Some songs could not be added: ${errors.join('; ')}',
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
                  secondary: TrackArt(t.id, size: 40),
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
      final err = await ref.read(roomControllerProvider.notifier).addTracks(candidates.where((t) => chosen.contains(t.id)).toList());
      if (!context.mounted) return;
      haptic(ref, err == null ? Haptic.action : Haptic.alert);
      if (err != null) showMessage(context, err, error: true);
    }
  }
}
