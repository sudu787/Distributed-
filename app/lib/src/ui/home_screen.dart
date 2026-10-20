import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../data/models.dart';
import '../services/room_service.dart';
import '../state/providers.dart';
import '../state/room_controller.dart';
import 'add_music.dart';
import 'catalog_browser.dart';
import 'format.dart';
import 'haptics.dart';
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
      if (next != null && next != prev) {
        haptic(ref, Haptic.alert);
        showMessage(context, next, error: true);
      }
    });

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit(context, ref);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('SyncSphere'),
          actions: [
            IconButton(
              tooltip: 'Phone name',
              icon: const Icon(Icons.badge_outlined),
              onPressed: () => _editName(context, ref),
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => _settings(context, ref),
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
                    _RejoinCard(),
                    _MainActions(),
                    _RecentParties(),
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
      ),
    );
  }

  /// Back button on the home screen: ask before closing the app.
  Future<void> _confirmExit(BuildContext context, WidgetRef ref) async {
    haptic(ref, Haptic.tap);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Exit SyncSphere?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Exit')),
        ],
      ),
    );
    if (ok == true) await SystemNavigator.pop();
  }

  Future<void> _settings(BuildContext context, WidgetRef ref) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (c) => Consumer(
          builder: (c, ref, _) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('Phone name'),
                subtitle: Text(ref.watch(identityProvider).displayName),
                onTap: () {
                  Navigator.pop(c);
                  _editName(context, ref);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.vibration),
                title: const Text('Vibration feedback'),
                subtitle: const Text('Buzz on taps and when the song changes'),
                value: ref.watch(hapticsProvider),
                onChanged: (v) => ref.read(hapticsProvider.notifier).set(v),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.mic_none),
                title: const Text('Help measure the room'),
                subtitle: const Text('For surround: let another phone in the party use this phone\'s microphone for '
                    'about 30 seconds while it measures where the phones are. The recording stays on this phone; '
                    'only click times and levels are shared.'),
                value: ref.watch(roomMeasurementProvider),
                onChanged: (v) => ref.read(roomMeasurementProvider.notifier).set(v),
              ),
            ]),
          ),
        ),
      );

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
        child: Text(
            'Play music on several phones at once, perfectly together. All phones must be on the same '
            'Wi-Fi or one phone\'s hotspot. No internet needed.',
            style: Theme.of(context).textTheme.bodyMedium),
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
          if (context.mounted) {
            showMessage(context, 'Copy the invite link first (host: QR icon → Copy link).', error: true);
          }
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
  const _BigAction(
      {required this.icon, required this.title, required this.subtitle, required this.onTap, this.filled = false});

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
            Text(title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// "Rejoin your party": shown when the party this phone created is still
/// running nearby (another phone took over while this app was closed). One
/// tap rejoins; the host role comes back automatically after ~10 s.
class _RejoinCard extends ConsumerWidget {
  const _RejoinCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosted = ref.watch(hostedRoomProvider).value;
    if (hosted == null) return const SizedBox.shrink();
    final beacons = ref.watch(discoveryProvider).value ?? const <RoomBeacon>[];
    RoomBeacon? beacon;
    for (final b in beacons) {
      if (b.roomId == hosted.roomId && b.host != null) beacon = b;
    }
    if (beacon == null) return const SizedBox.shrink();
    final b = beacon;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.celebration, color: cs.onPrimaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Your party "${hosted.roomName}" is still playing',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.onPrimaryContainer)),
            ),
          ]),
          const SizedBox(height: 4),
          Text('Another phone kept it going. Rejoin and you will be the host again in a few seconds.',
              style: TextStyle(color: cs.onPrimaryContainer)),
          OverflowBar(alignment: MainAxisAlignment.end, spacing: 8, children: [
            TextButton(
              onPressed: () => ref.read(roomControllerProvider.notifier).forgetHostedRoom(),
              child: const Text('Forget'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Rejoin your party'),
              onPressed: () => ref.read(roomControllerProvider.notifier).rejoinHostedRoom(hosted, b),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// The last parties this phone was in. A party that is running nearby
/// (found by its discovery beacon, even after another phone took over as
/// host) rejoins with one tap using the saved code.
class _RecentParties extends ConsumerWidget {
  const _RecentParties();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(roomHistoryProvider).value ?? const <RoomHistoryEntry>[];
    if (history.isEmpty) return const SizedBox.shrink();
    final hosted = ref.watch(hostedRoomProvider).value;
    final beacons = ref.watch(discoveryProvider).value ?? const <RoomBeacon>[];
    final online = {
      for (final b in beacons)
        if (b.host != null) b.roomId: b
    };
    final shown = [
      for (final e in history)
        // "Rejoin your party" above already offers this one.
        if (!(hosted != null && e.roomId == hosted.roomId && online.containsKey(e.roomId))) e,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Recent parties'),
        for (final e in shown) _RecentPartyTile(entry: e, beacon: online[e.roomId]),
      ],
    );
  }
}

class _RecentPartyTile extends ConsumerWidget {
  final RoomHistoryEntry entry;
  final RoomBeacon? beacon;
  const _RecentPartyTile({required this.entry, required this.beacon});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final b = beacon;
    final canRetry = b == null && !entry.hosted && entry.joinKey != null;
    final when = _ago(entry.at);
    return Dismissible(
      key: ValueKey('history-${entry.roomId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: cs.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
      ),
      onDismissed: (_) => ref.read(roomControllerProvider.notifier).forgetRecentParty(entry.roomId),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: b != null ? cs.primaryContainer : cs.surfaceContainerHighest,
          child: Icon(entry.hosted ? Icons.celebration_outlined : Icons.speaker_group_outlined,
              color: b != null ? cs.onPrimaryContainer : cs.onSurfaceVariant),
        ),
        title: Text(entry.roomName, overflow: TextOverflow.ellipsis),
        subtitle: Row(children: [
          if (b != null) ...[
            const HealthDot(SyncHealth.good, size: 8),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              b != null
                  ? 'Online · ${b.participants} phone${b.participants == 1 ? '' : 's'}'
                  : '${entry.hosted ? 'You hosted' : 'Joined'} $when · not found nearby',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        trailing: b != null
            ? FilledButton(
                onPressed: () => _join(context, ref, b),
                child: const Text('Join'),
              )
            : canRetry
                ? TextButton(onPressed: () => _join(context, ref, null), child: const Text('Try'))
                : null,
      ),
    );
  }

  Future<void> _join(BuildContext context, WidgetRef ref, RoomBeacon? b) async {
    haptic(ref, Haptic.action);
    final key = entry.joinKey ?? await _askCode(context);
    if (key == null || key.isEmpty) return;
    await ref.read(roomControllerProvider.notifier).joinRecentParty(entry, key, beacon: b);
  }

  Future<String?> _askCode(BuildContext context) async {
    final key = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Join "${entry.roomName}"'),
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
    return ok == true ? key.text.trim() : null;
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays == 1) return 'yesterday';
    return '${d.inDays} days ago';
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
            onPressed: () => _addMenu(context, ref),
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
                      leading: TrackArt(t.id, size: 40, url: t.artUrl),
                      title: Text(t.title, overflow: TextOverflow.ellipsis),
                      subtitle: Text([t.artist ?? 'Unknown artist', fmtClock(t.durationUs), if (t.credit != null) t.credit!]
                          .join(' · ')),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => ref.read(libraryProvider.notifier).remove(t),
                      ),
                    ),
                ]),
          loading: () => const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          error: (e, _) =>
              ListTile(leading: const Icon(Icons.error_outline), title: Text('Could not load your music: $e')),
        ),
      ],
    );
  }

  Future<void> _addMenu(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('From this phone…'),
            onTap: () => Navigator.pop(c, 'phone'),
          ),
          ListTile(
            leading: const Icon(Icons.travel_explore),
            title: const Text('Search Audius'),
            subtitle: const Text('Free music from independent artists'),
            onTap: () => Navigator.pop(c, 'audius'),
          ),
          ...catalogMenuTiles(c),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('From a link'),
            subtitle: const Text('Your own music server, a podcast or any audio file link'),
            onTap: () => Navigator.pop(c, 'link'),
          ),
        ]),
        ),
      ),
    );
    if (!context.mounted) return;
    final catalog = catalogFor(choice);
    if (catalog != null) {
      final added = await showCatalog(context, catalog);
      if (added.isNotEmpty && context.mounted) {
        showMessage(context, 'Added ${added.length} song${added.length == 1 ? '' : 's'} to My music.');
      }
      return;
    }
    switch (choice) {
      case 'phone':
        await _import(context, ref);
      case 'audius':
        final added = await showAudiusSearch(context);
        if (added.isNotEmpty && context.mounted) {
          showMessage(context, 'Added ${added.length} song${added.length == 1 ? '' : 's'} to My music.');
        }
      case 'link':
        final t = await addFromLink(context, ref);
        if (t != null && context.mounted) showMessage(context, 'Added "${t.title}" to My music.');
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(type: FileType.audio, dialogTitle: 'Add songs');
    final files = [
      for (final f in picked)
        if (f.path != null) File(f.path!)
    ];
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
