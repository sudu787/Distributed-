import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../services/room_service.dart';
import '../state/providers.dart';
import '../state/room_controller.dart';
import 'format.dart';
import 'widgets.dart';

/// Screen 1: create/join/discover rooms, manage the local library.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final room = ref.watch(roomControllerProvider);
    final starting = room.status == RoomStatus.starting;
    ref.listen(roomControllerProvider.select((s) => s.error), (prev, next) {
      if (next != null && next != prev) showMessage(context, next, error: true);
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('SyncSphere'),
        actions: [
          IconButton(
            tooltip: 'Device name',
            icon: const Icon(Icons.badge_outlined),
            onPressed: () => _editName(context, ref),
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: starting,
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(networkSummaryProvider);
                ref.invalidate(roomHistoryProvider);
              },
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: const [
                  _ConnectionCard(),
                  _PrimaryActions(),
                  _NearbyRooms(),
                  _LibrarySection(),
                  _RecentRooms(),
                ],
              ),
            ),
            if (starting) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Future<void> _editName(BuildContext context, WidgetRef ref) async {
    final id = ref.read(identityProvider);
    final ctl = TextEditingController(text: id.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(controller: ctl, maxLength: 40, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(identityProvider.notifier).update(id.copyWith(displayName: name));
    }
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(networkSummaryProvider);
    final id = ref.watch(identityProvider);
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This device: ${id.displayName}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            net.when(
              data: (n) => StatusChip(n.label, n.hasLan ? Icons.wifi : Icons.wifi_off,
                  color: n.hasLan ? cs.primary : cs.error),
              loading: () => const StatusChip('Checking network…', Icons.wifi_find),
              error: (e, _) => StatusChip('Network unavailable', Icons.wifi_off, color: cs.error),
            ),
            const SizedBox(height: 8),
            Text('Works offline on the same Wi-Fi or a phone hotspot. No internet needed.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _PrimaryActions extends ConsumerWidget {
  const _PrimaryActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Create room'),
              onPressed: () => _create(context, ref),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Join by address'),
              onPressed: () => _joinManual(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final id = ref.read(identityProvider);
    final nameCtl = TextEditingController(text: "${id.displayName}'s room");
    var mode = DistributionMode.auto;
    var open = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: const Text('Create room'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Room name'), maxLength: 40),
              DropdownButtonFormField<DistributionMode>(
                initialValue: mode,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Audio source'),
                items: [
                  for (final m in DistributionMode.values)
                    DropdownMenuItem(value: m, child: Text(distributionLabel(m), overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (m) => setState(() => mode = m ?? mode),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Everyone can control playback'),
                subtitle: const Text('Otherwise only you (and devices you promote) can.'),
                value: open,
                onChanged: (v) => setState(() => open = v),
              ),
              const SizedBox(height: 4),
              Text('Only share music you are authorized to share.', style: Theme.of(c).textTheme.bodySmall),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await ref.read(roomControllerProvider.notifier).host(
          roomName: nameCtl.text.trim().isEmpty ? 'SyncSphere room' : nameCtl.text.trim(),
          distribution: mode,
          openControl: open,
        );
  }

  Future<void> _joinManual(BuildContext context, WidgetRef ref) async {
    final host = TextEditingController();
    final port = TextEditingController(text: '$kDefaultRoomPort');
    final key = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Join room'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: host,
              decoration: const InputDecoration(labelText: 'Host address', hintText: '192.168.1.20'),
              keyboardType: TextInputType.url),
          TextField(controller: port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
          TextField(
              controller: key,
              decoration: const InputDecoration(labelText: 'Join key', hintText: 'ABCD-EFGH'),
              textCapitalization: TextCapitalization.characters),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Join')),
        ],
      ),
    );
    if (ok != true) return;
    final p = int.tryParse(port.text.trim());
    if (host.text.trim().isEmpty || p == null || p <= 0 || p > 65535 || key.text.trim().isEmpty) {
      if (context.mounted) showMessage(context, 'Enter a host, a valid port and the join key.', error: true);
      return;
    }
    await ref.read(roomControllerProvider.notifier).join(host: host.text.trim(), port: p, joinKey: key.text.trim());
  }
}

class _NearbyRooms extends ConsumerWidget {
  const _NearbyRooms();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.watch(discoveryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Nearby rooms'),
        rooms.when(
          data: (list) => list.isEmpty
              ? const ListTile(
                  leading: Icon(Icons.radar),
                  title: Text('Looking for rooms on this network…'),
                  subtitle: Text('If none appear, the network may block broadcasts. Use "Join by address".'),
                )
              : Column(children: [
                  for (final r in list)
                    ListTile(
                      leading: const Icon(Icons.speaker_group_outlined),
                      title: Text(r.roomName),
                      subtitle: Text('Room ${r.roomId} · ${r.host}:${r.port} · ${r.participants} device(s)'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _join(context, ref, r),
                    ),
                ]),
          loading: () => const ListTile(title: Text('Starting discovery…')),
          error: (e, _) => ListTile(leading: const Icon(Icons.error_outline), title: Text('$e')),
        ),
      ],
    );
  }

  Future<void> _join(BuildContext context, WidgetRef ref, RoomBeacon r) async {
    final key = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Join "${r.roomName}"'),
        content: TextField(
          controller: key,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Join key shown on the host'),
          textCapitalization: TextCapitalization.characters,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Join')),
        ],
      ),
    );
    if (ok != true || key.text.trim().isEmpty) return;
    await ref
        .read(roomControllerProvider.notifier)
        .join(host: r.host!, port: r.port, joinKey: key.text.trim(), roomId: r.roomId);
  }
}

class _LibrarySection extends ConsumerWidget {
  const _LibrarySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(libraryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Your library',
          trailing: TextButton.icon(
            icon: const Icon(Icons.library_add_outlined),
            label: const Text('Import'),
            onPressed: () => _import(context, ref),
          ),
        ),
        lib.when(
          data: (tracks) => tracks.isEmpty
              ? const ListTile(
                  leading: Icon(Icons.library_music_outlined),
                  title: Text('No tracks yet'),
                  subtitle: Text('Import audio files. Devices match tracks by content (SHA-256), not by name.'),
                )
              : Column(children: [
                  for (final t in tracks)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.music_note_outlined),
                      title: Text(t.title, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${t.artist ?? 'Unknown artist'} · ${fmtClock(t.durationUs)} · ${t.id.substring(0, 8)}…'),
                      trailing: IconButton(
                        tooltip: 'Remove from library',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => ref.read(libraryProvider.notifier).remove(t),
                      ),
                    ),
                ]),
          loading: () => const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          error: (e, _) => ListTile(leading: const Icon(Icons.error_outline), title: Text('Library error: $e')),
        ),
      ],
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(type: FileType.audio, dialogTitle: 'Import audio');
    final files = [for (final f in picked) if (f.path != null) File(f.path!)];
    if (files.isEmpty) return;
    final errors = await ref.read(libraryProvider.notifier).importFiles(files);
    if (!context.mounted) return;
    if (errors.isEmpty) {
      showMessage(context, 'Imported ${files.length} track(s).');
    } else {
      showMessage(context, 'Some files failed: ${errors.join('; ')}', error: true);
    }
  }
}

class _RecentRooms extends ConsumerWidget {
  const _RecentRooms();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hist = ref.watch(roomHistoryProvider);
    return hist.maybeWhen(
      data: (list) => list.isEmpty
          ? const SizedBox.shrink()
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionHeader('Recent rooms'),
              for (final h in list.take(5))
                ListTile(
                  dense: true,
                  leading: Icon(h.hosted ? Icons.cell_tower : Icons.history),
                  title: Text(h.roomName),
                  subtitle: Text('${h.hosted ? 'Hosted' : 'Joined ${h.host}:${h.port}'} · ${_ago(h.at)}'),
                ),
            ]),
      orElse: () => const SizedBox.shrink(),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}
