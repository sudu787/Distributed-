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
/// can pick a song, add songs (a guest's songs are sent to the host),
/// drag songs into a new order, swipe one away (with undo) or play it next.
class QueueView extends ConsumerStatefulWidget {
  const QueueView({super.key});

  @override
  ConsumerState<QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends ConsumerState<QueueView> {
  /// Edits shown before the room confirms them, so rows do not jump back.
  List<String>? _localOrder;
  final Set<String> _removing = {};

  RoomController get _ctl => ref.read(roomControllerProvider.notifier);

  Future<void> _report(Future<String?> f, {String? done}) async {
    final err = await f;
    if (!mounted) return;
    if (err != null) {
      haptic(ref, Haptic.alert);
      showMessage(context, err, error: true);
    } else if (done != null) {
      showMessage(context, done);
    }
  }

  Future<void> _playNow(TrackInfo t) async {
    haptic(ref, Haptic.action);
    await _report(_ctl.playNow(t.id));
  }

  Future<void> _remove(TrackInfo t, int index) async {
    haptic(ref, Haptic.action);
    setState(() => _removing.add(t.id));
    final err = await _ctl.removeTrack(t.id);
    if (!mounted) return;
    if (err != null) {
      setState(() => _removing.remove(t.id));
      haptic(ref, Haptic.alert);
      showMessage(context, err, error: true);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text('Removed "${t.title}"', maxLines: 1, overflow: TextOverflow.ellipsis),
      action: SnackBarAction(label: 'Undo', onPressed: () => _report(_ctl.restoreTrack(t, index))),
    ));
  }

  /// [to] is the final index (onReorderItem already accounts for the gap).
  void _reorder(List<TrackInfo> shown, int from, int to) {
    if (to == from) return;
    haptic(ref, Haptic.tap);
    final ids = [for (final t in shown) t.id];
    final id = ids.removeAt(from);
    ids.insert(to, id);
    setState(() => _localOrder = ids);
    // Index in the full playlist (rows being removed are hidden here).
    final full = ref.read(roomControllerProvider).room!.playlist.where((t) => t.id != id).toList();
    final before = to == 0 ? null : ids[to - 1];
    final target = before == null ? 0 : full.indexWhere((t) => t.id == before) + 1;
    _ctl.moveTrack(id, target).then((err) {
      if (!mounted) return;
      if (err != null) {
        setState(() => _localOrder = null);
        haptic(ref, Haptic.alert);
        showMessage(context, err, error: true);
        return;
      }
      // Normally the room's new order replaces this at once; if someone else
      // edited the queue at the same moment, show the room's order anyway.
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && identical(_localOrder, ids)) setState(() => _localOrder = null);
      });
    });
  }

  Future<void> _menu(TrackInfo t, int index, bool isCurrent) async {
    haptic(ref, Haptic.tap);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: TrackArt(t.id, size: 40, url: t.artUrl),
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(t.artist ?? 'Unknown artist', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const Divider(height: 1),
          if (!isCurrent)
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Play now'),
              onTap: () => Navigator.pop(c, 'now'),
            ),
          if (!isCurrent)
            ListTile(
              leading: const Icon(Icons.playlist_play_rounded),
              title: const Text('Play next'),
              onTap: () => Navigator.pop(c, 'next'),
            ),
          if (index > 0)
            ListTile(
              leading: const Icon(Icons.vertical_align_top_rounded),
              title: const Text('Move to the top'),
              onTap: () => Navigator.pop(c, 'top'),
            ),
          ListTile(
            leading: Icon(Icons.remove_circle_outline, color: Theme.of(c).colorScheme.error),
            title: Text(isCurrent ? 'Remove (skips to the next song)' : 'Remove from queue'),
            onTap: () => Navigator.pop(c, 'remove'),
          ),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'now':
        await _playNow(t);
      case 'next':
        haptic(ref, Haptic.action);
        await _report(_ctl.playNext(t.id), done: '"${t.title}" plays next.');
      case 'top':
        haptic(ref, Haptic.action);
        await _report(_ctl.moveTrack(t.id, 0));
      case 'remove':
        await _remove(t, index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room!;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final connected = room.participants.where((p) => p.connection != ConnectionStatus.disconnected).length;
    final current = room.pending?.trackId ?? room.timeline.trackId;
    final playlistIds = [for (final x in room.playlist) x.id];

    // Drop optimistic edits once the room shows them.
    _removing.removeWhere((id) => !playlistIds.contains(id));
    var shown = [for (final x in room.playlist) if (!_removing.contains(x.id)) x];
    final local = _localOrder;
    if (local != null) {
      final shownIds = [for (final x in shown) x.id];
      if (_sameOrder(shownIds, local) || !_sameSet(shownIds, local)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_localOrder, local)) setState(() => _localOrder = null);
        });
      } else {
        final byId = {for (final x in shown) x.id: x};
        shown = [for (final id in local) byId[id]!];
      }
    }
    final totalUs = shown.fold<int>(0, (a, x) => a + (x.durationUs ?? 0));
    final canEdit = s.canControl;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Queue', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            Text(
              shown.isEmpty
                  ? 'No songs yet'
                  : '${shown.length} song${shown.length == 1 ? '' : 's'} · ${fmtLength(totalUs)}'
                      '${room.shuffle ? ' · shuffle on' : ''}',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ]),
        ),
        if (canEdit)
          FilledButton.tonalIcon(
            icon: const Icon(Icons.add),
            label: const Text('Add songs'),
            onPressed: s.adding != null ? null : () => _chooseSource(context, ref),
          ),
      ]),
    );

    final adding = s.adding;
    final progress = adding == null
        ? null
        : ListTile(
            leading: const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            title: Text(s.isHost
                ? 'Adding songs…'
                : 'Sending songs to the host… ${adding.$1 + 1 > adding.$2 ? adding.$2 : adding.$1 + 1} of ${adding.$2}'),
            subtitle: adding.$2 == 0 ? null : LinearProgressIndicator(value: adding.$1 / adding.$2),
          );

    if (shown.isEmpty) {
      return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        header,
        if (progress != null) progress,
        _EmptyQueue(canEdit: canEdit, onAdd: s.adding != null ? null : () => _chooseSource(context, ref)),
      ]);
    }

    Widget row(int i) {
      final x = shown[i];
      final isCurrent = x.id == current;
      final index = room.indexOfTrack(x.id);
      final tile = _QueueTile(
        track: x,
        position: i + 1,
        isCurrent: isCurrent,
        playing: isCurrent && (room.timeline.isPlaying || (room.pending?.autoPlay ?? false)),
        isNext: x.id == room.upNext && !isCurrent,
        ready: x.availableCount,
        connected: connected,
        canEdit: canEdit,
        dragIndex: canEdit ? i : null,
        onTap: canEdit && !isCurrent ? () => _playNow(x) : null,
        onMenu: canEdit ? () => _menu(x, index, isCurrent) : null,
      );
      if (!canEdit) return KeyedSubtree(key: ValueKey(x.id), child: tile);
      return Dismissible(
        key: ValueKey(x.id),
        direction: DismissDirection.endToStart,
        background: Container(
          color: cs.errorContainer,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Remove', style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Icon(Icons.delete_outline, color: cs.onErrorContainer),
          ]),
        ),
        onDismissed: (_) => _remove(x, index),
        child: tile,
      );
    }

    return CustomScrollView(slivers: [
      SliverToBoxAdapter(child: header),
      if (progress != null) SliverToBoxAdapter(child: progress),
      if (canEdit)
        SliverReorderableList(
          itemCount: shown.length,
          onReorderItem: (from, to) => _reorder(shown, from, to),
          proxyDecorator: (child, i, anim) => Material(elevation: 6, borderRadius: BorderRadius.circular(12), child: child),
          itemBuilder: (context, i) => row(i),
        )
      else
        SliverList.builder(itemCount: shown.length, itemBuilder: (context, i) => row(i)),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Text(
            canEdit
                ? 'Tap a song to play it. Drag ≡ to reorder, swipe left to remove, or use ⋮ for more.'
                : 'Only the host and phones it allows to control the music can pick or add songs.',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ),
    ]);
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameSet(List<String> a, List<String> b) => a.length == b.length && a.toSet().containsAll(b);

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

class _QueueTile extends StatelessWidget {
  final TrackInfo track;
  final int position;
  final bool isCurrent;
  final bool playing;
  final bool isNext;
  final int ready;
  final int connected;
  final bool canEdit;
  final int? dragIndex;
  final VoidCallback? onTap;
  final VoidCallback? onMenu;
  const _QueueTile({
    required this.track,
    required this.position,
    required this.isCurrent,
    required this.playing,
    required this.isNext,
    required this.ready,
    required this.connected,
    required this.canEdit,
    required this.dragIndex,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final details = [
      track.artist ?? 'Unknown artist',
      fmtClock(track.durationUs),
      if (track.credit != null) track.credit!,
    ].join(' · ');
    return Material(
      color: isCurrent ? cs.primaryContainer.withValues(alpha: 0.55) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
          child: Row(children: [
            SizedBox(
              width: 28,
              child: isCurrent
                  ? Icon(playing ? Icons.graphic_eq_rounded : Icons.pause_rounded, size: 18, color: cs.primary)
                  : Text('$position', textAlign: TextAlign.center, style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            ),
            const SizedBox(width: 4),
            TrackArt(track.id, size: 48, url: track.artUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyLarge?.copyWith(
                        fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                        color: isCurrent ? cs.primary : null,
                      ),
                    ),
                  ),
                  if (isCurrent || isNext) ...[
                    const SizedBox(width: 6),
                    _Tag(isCurrent ? 'Now playing' : 'Next', color: isCurrent ? cs.primary : cs.tertiary),
                  ],
                ]),
                Text(details, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
            if (ready < connected)
              Tooltip(
                message: 'Phones that have this song ready',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.downloading_rounded, size: 16, color: cs.onSurfaceVariant),
                    const SizedBox(width: 2),
                    Text('$ready/$connected', style: t.labelSmall),
                  ]),
                ),
              ),
            if (onMenu != null)
              IconButton(tooltip: 'More', icon: const Icon(Icons.more_vert), onPressed: onMenu),
            if (dragIndex != null)
              ReorderableDragStartListener(
                index: dragIndex!,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Icon(Icons.drag_handle_rounded),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag(this.label, {required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      );
}

class _EmptyQueue extends StatelessWidget {
  final bool canEdit;
  final VoidCallback? onAdd;
  const _EmptyQueue({required this.canEdit, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
          child: Icon(Icons.queue_music_rounded, size: 40, color: cs.onPrimaryContainer),
        ),
        const SizedBox(height: 16),
        Text('The queue is empty', style: t.titleMedium),
        const SizedBox(height: 4),
        Text(
          canEdit
              ? 'Add music from this phone, Audius or a link. Every phone plays it together.'
              : 'Waiting for the host to add songs.',
          textAlign: TextAlign.center,
          style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        if (canEdit) ...[
          const SizedBox(height: 16),
          FilledButton.icon(icon: const Icon(Icons.add), label: const Text('Add songs'), onPressed: onAdd),
        ],
      ]),
    );
  }
}
