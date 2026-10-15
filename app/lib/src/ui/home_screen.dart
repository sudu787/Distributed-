import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../services/room_service.dart';
import '../state/providers.dart';
import '../state/room_controller.dart';
import 'format.dart';
import 'scan_screen.dart';
import 'widgets.dart';

/// Start screen: host or join a party, nearby parties, and this phone's music.
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
            tooltip: 'Phone name',
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
              onRefresh: () async => ref.invalidate(networkSummaryProvider),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: const [
                  _NetworkBanner(),
                  _MainActions(),
                  _NearbyRooms(),
                  _LibrarySection(),
                ],
              ),
            ),
            if (starting)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x33000000),
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 16),
                          Text('Connecting…'),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
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
        title: const Text('Phone name'),
        content: TextField(
          controller: ctl,
          maxLength: 40,
          autofocus: true,
          decoration: const InputDecoration(helperText: 'Shown to others in the party'),
        ),
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

/// Only shown when something is wrong with the network.
class _NetworkBanner extends ConsumerWidget {
  const _NetworkBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(networkSummaryProvider);
    final ok = net.maybeWhen(data: (n) => n.hasLan, orElse: () => true);
    final cs = Theme.of(context).colorScheme;
    if (ok) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Text('Play music on several phones at once, perfectly together. All phones must be on the same '
            'Wi-Fi or one phone\'s hotspot. No internet needed.', style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      color: cs.errorContainer,
      child: ListTile(
        leading: Icon(Icons.wifi_off, color: cs.onErrorContainer),
        title: Text('Not connected to Wi-Fi', style: TextStyle(color: cs.onErrorContainer)),
        subtitle: Text('Join the same Wi-Fi as the others, or turn on a hotspot on one phone.',
            style: TextStyle(color: cs.onErrorContainer)),
      ),
    );
  }
}

class _MainActions extends ConsumerWidget {
  const _MainActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(children: [
        Expanded(
          child: _BigAction(
            icon: Icons.celebration_outlined,
            title: 'Host a party',
            subtitle: 'Play your music',
            filled: true,
            onTap: () => _create(context, ref),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _BigAction(
            icon: Icons.qr_code_scanner,
            title: 'Join a party',
            subtitle: 'Scan the host\'s code',
            onTap: () => _join(context, ref),
          ),
        ),
      ]),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final id = ref.read(identityProvider);
    final nameCtl = TextEditingController(text: "${id.displayName}'s party");
    var mode = DistributionMode.auto;
    var open = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: const Text('Host a party'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Party name'), maxLength: 40),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Everyone can control the music'),
                subtitle: const Text('Otherwise only you can play, pause and skip.'),
                value: open,
                onChanged: (v) => setState(() => open = v),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Advanced'),
                children: [
                  DropdownButtonFormField<DistributionMode>(
                    initialValue: mode,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Where guests get the songs'),
                    items: [
                      for (final m in DistributionMode.values)
                        DropdownMenuItem(value: m, child: Text(distributionLabel(m), overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (m) => setState(() => mode = m ?? mode),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('Guests get the songs from your phone automatically. Only share music you are allowed to share.',
                  style: Theme.of(c).textTheme.bodySmall),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Start')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await ref.read(roomControllerProvider.notifier).host(
          roomName: nameCtl.text.trim().isEmpty ? 'SyncSphere party' : nameCtl.text.trim(),
          distribution: mode,
          openControl: open,
        );
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('Scan QR code'),
            subtitle: const Text('The host taps the QR icon in their party'),
            onTap: () => Navigator.pop(c, 'scan'),
          ),
          ListTile(
            leading: const Icon(Icons.content_paste),
            title: const Text('Paste invite link'),
            onTap: () => Navigator.pop(c, 'paste'),
          ),
          ListTile(
            leading: const Icon(Icons.keyboard_outlined),
            title: const Text('Enter address and code'),
            onTap: () => Navigator.pop(c, 'manual'),
          ),
        ]),
      ),
    );
    if (!context.mounted || choice == null) return;
    final ctl = ref.read(roomControllerProvider.notifier);
    switch (choice) {
      case 'scan':
        final link = await Navigator.of(context).push<JoinLink>(MaterialPageRoute(builder: (_) => const ScanScreen()));
        if (link != null) await ctl.joinWithLink(link);
      case 'paste':
        final clip = await Clipboard.getData(Clipboard.kTextPlain);
        final link = JoinLink.tryParse(clip?.text ?? '');
        if (link == null) {
          if (context.mounted) showMessage(context, 'Copy the invite link first (host: QR icon → Copy link).', error: true);
          return;
        }
        await ctl.joinWithLink(link);
      case 'manual':
        if (context.mounted) await _joinManual(context, ref);
    }
  }

  Future<void> _joinManual(BuildContext context, WidgetRef ref) async {
    final host = TextEditingController();
    final key = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Join a party'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: host,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Host address', hintText: '192.168.1.20'),
              keyboardType: TextInputType.url),
          TextField(
              controller: key,
              decoration: const InputDecoration(labelText: 'Code', hintText: 'ABCD-EFGH'),
              textCapitalization: TextCapitalization.characters),
          const SizedBox(height: 8),
          Text('Both are shown on the host phone under the QR icon.', style: Theme.of(c).textTheme.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Join')),
        ],
      ),
    );
    if (ok != true) return;
    // "192.168.1.20:47801" is accepted too.
    var address = host.text.trim();
    var port = kDefaultRoomPort;
    final i = address.lastIndexOf(':');
    if (i > 0 && int.tryParse(address.substring(i + 1)) != null) {
      port = int.parse(address.substring(i + 1));
      address = address.substring(0, i);
    }
    if (address.isEmpty || port <= 0 || port > 65535 || key.text.trim().isEmpty) {
      if (context.mounted) showMessage(context, 'Enter the host address and the code.', error: true);
      return;
    }
    await ref.read(roomControllerProvider.notifier).join(host: address, port: port, joinKey: key.text.trim());
  }
}

class _BigAction extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool filled;
  final VoidCallback onTap;
  const _BigAction({required this.icon, required this.title, required this.subtitle, required this.onTap, this.filled = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = filled ? cs.onPrimary : cs.onSecondaryContainer;
    return Material(
      color: filled ? cs.primary : cs.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 36, color: fg),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)),
          ]),
        ),
      ),
    );
  }
}

class _NearbyRooms extends ConsumerWidget {
  const _NearbyRooms();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.watch(discoveryProvider);
    final list = rooms.maybeWhen(data: (l) => l, orElse: () => const <RoomBeacon>[]);
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Parties nearby'),
        for (final r in list)
          ListTile(
            leading: const Icon(Icons.speaker_group_outlined),
            title: Text(r.roomName),
            subtitle: Text('${r.participants} phone${r.participants == 1 ? '' : 's'} · ${r.host}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _join(context, ref, r),
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
          decoration: const InputDecoration(labelText: 'Code shown on the host', hintText: 'ABCD-EFGH'),
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
          'My music',
          trailing: TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add'),
            onPressed: () => _import(context, ref),
          ),
        ),
        lib.when(
          data: (tracks) => tracks.isEmpty
              ? const ListTile(
                  leading: Icon(Icons.library_music_outlined),
                  title: Text('No songs yet'),
                  subtitle: Text('Hosts: tap Add to pick songs from this phone. Guests don\'t need any music.'),
                )
              : Column(children: [
                  for (final t in tracks)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.music_note_outlined),
                      title: Text(t.title, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${t.artist ?? 'Unknown artist'} · ${fmtClock(t.durationUs)}'),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => ref.read(libraryProvider.notifier).remove(t),
                      ),
                    ),
                ]),
          loading: () => const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          error: (e, _) => ListTile(leading: const Icon(Icons.error_outline), title: Text('Could not load your music: $e')),
        ),
      ],
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(type: FileType.audio, dialogTitle: 'Add songs');
    final files = [for (final f in picked) if (f.path != null) File(f.path!)];
    if (files.isEmpty) return;
    final errors = await ref.read(libraryProvider.notifier).importFiles(files);
    if (!context.mounted) return;
    if (errors.isEmpty) {
      showMessage(context, 'Added ${files.length} song${files.length == 1 ? '' : 's'}.');
    } else {
      showMessage(context, 'Some files could not be added: ${errors.join('; ')}', error: true);
    }
  }
}
