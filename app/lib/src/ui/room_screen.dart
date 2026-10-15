import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../services/network_info.dart';
import '../state/providers.dart';
import '../state/room_controller.dart';
import 'diagnostics_screen.dart';
import 'format.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// Screen 2: room overview — code/key, coordinator status, devices and
/// their sync health, playlist and track availability.
class RoomScreen extends ConsumerWidget {
  const RoomScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room;
    return Scaffold(
      appBar: AppBar(
        title: Text(room?.roomName ?? s.info?.roomName ?? 'Room'),
        actions: [
          IconButton(
            tooltip: 'Diagnostics',
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
          ),
          IconButton(
            tooltip: s.isHost ? 'Close room' : 'Leave room',
            icon: const Icon(Icons.logout),
            onPressed: () => _leave(context, ref, s.isHost),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.graphic_eq),
        label: const Text('Player'),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlayerScreen())),
      ),
      body: room == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                _RoomHeader(s),
                _ListeningSpot(s),
                _Devices(s),
                _Playlist(s),
              ],
            ),
    );
  }

  Future<void> _leave(BuildContext context, WidgetRef ref, bool host) async {
    if (host) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Close the room?'),
          content: const Text('This device is the room coordinator. Leaving closes the room for everyone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Close room')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await ref.read(roomControllerProvider.notifier).leave();
  }
}

class _RoomHeader extends ConsumerWidget {
  final RoomViewState s;
  const _RoomHeader(this.s);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final info = s.info!;
    final (label, icon, color) = switch (s.phase) {
      SessionPhase.joined when s.coordinatorSuspect => ('Coordinator not responding…', Icons.hourglass_top, const Color(0xFFD99A1E)),
      SessionPhase.joined => (info.isHost ? 'Coordinator: this device' : 'Connected to coordinator', Icons.check_circle_outline, const Color(0xFF2E9E5B)),
      SessionPhase.syncing => ('Synchronizing clocks…', Icons.sync, cs.primary),
      SessionPhase.reconnecting || SessionPhase.connecting || SessionPhase.authenticating =>
        ('Reconnecting — playing on last known timeline', Icons.sync_problem, const Color(0xFFD99A1E)),
      SessionPhase.failed => (s.error ?? 'Disconnected', Icons.error_outline, cs.error),
      _ => ('—', Icons.help_outline, cs.outline),
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          StatusChip(label, icon, color: color),
          const SizedBox(height: 12),
          InfoRow('Room code', info.roomId),
          InfoRow('Audio source', distributionLabel(s.room!.distribution)),
          if (s.role != null) InfoRow('Your role', roleLabel(s.role!)),
          if (info.isHost && info.joinKey != null) ...[
            const Divider(height: 24),
            Text('Join key', style: t.labelLarge),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: SelectableText(formatJoinKey(info.joinKey!),
                    style: t.headlineMedium?.copyWith(fontFamily: 'monospace', letterSpacing: 2)),
              ),
              IconButton(
                tooltip: 'Copy join key',
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: formatJoinKey(info.joinKey!)));
                  showMessage(context, 'Join key copied');
                },
              ),
            ]),
            FutureBuilder<NetworkSummary>(
              future: readNetworkSummary(),
              builder: (c, snap) => Text(
                snap.hasData && snap.data!.hasLan
                    ? 'Others can find this room nearby, or join by address ${snap.data!.ipv4.join(' / ')} port ${info.port}.'
                    : 'Port ${info.port}',
                style: t.bodySmall,
              ),
            ),
            const SizedBox(height: 4),
            Text('Share the key only with people in the room. Anyone with it can join.', style: t.bodySmall),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Invite with QR code'),
              onPressed: () => _showInvite(context, ref),
            ),
          ],
        ]),
      ),
    );
  }
}

Future<void> _showInvite(BuildContext context, WidgetRef ref) async {
  final link = await ref.read(roomControllerProvider.notifier).joinLink();
  if (!context.mounted) return;
  if (link == null) {
    showMessage(context, 'No local network address to share. Connect to Wi-Fi or start a hotspot.', error: true);
    return;
  }
  final text = link.toString();
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Join this room'),
      content: SizedBox(
        width: 280,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            child: QrImageView(data: text, size: 240, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 12),
          const Text(
            'Scan with SyncSphere (Join → Scan QR) or the phone camera. '
            'The code contains the join key: show it only to people in the room.',
            textAlign: TextAlign.center,
          ),
        ]),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.link),
          label: const Text('Copy link'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            showMessage(context, 'Join link copied');
          },
        ),
        FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
      ],
    ),
  );
}

/// "Calibrate to this spot": aligns every device's sound at this phone's
/// microphone, which also removes Bluetooth and speaker delays that software
/// estimates cannot see.
class _ListeningSpot extends ConsumerStatefulWidget {
  final RoomViewState s;
  const _ListeningSpot(this.s);

  @override
  ConsumerState<_ListeningSpot> createState() => _ListeningSpotState();
}

class _ListeningSpotState extends ConsumerState<_ListeningSpot> {
  bool _requested = false;

  Future<void> _calibrate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Calibrate to this spot?'),
        content: const Text(
          'Music stops for 15–30 seconds (longer with more devices) while every device plays short clicks in turn. '
          'Hold this phone where you will listen, keep the room quiet, and keep all devices at their usual volume. '
          'The microphone recording stays on this phone; only timing results are sent.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Calibrate')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _requested = true);
    final err = await ref.read(roomControllerProvider.notifier).calibrateHere();
    if (!mounted) return;
    if (err != null) {
      setState(() => _requested = false);
      showMessage(context, err, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final room = s.room!;
    final t = Theme.of(context).textTheme;
    final ctl = ref.read(roomControllerProvider.notifier);
    final running = room.calibration != null;
    final mine = running && room.calibration!.listener == ref.watch(identityProvider).deviceId;
    final outcome = ctl.lastCalibration;
    if (!running && _requested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _requested = false);
      });
    }
    final canStart = s.canControl && ctl.hasMicrophone && !running;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.hearing),
            const SizedBox(width: 8),
            Expanded(child: Text('Listening spot', style: t.titleSmall)),
            if (running) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 6),
          Text(
            running
                ? (mine ? 'Listening for clicks from each device… keep still and quiet.' : 'Another device is calibrating the room…')
                : 'Measures when each device\'s sound reaches this phone and aligns them here, '
                    'including Bluetooth and speaker delays.',
            style: t.bodySmall,
          ),
          if (!running && outcome != null) ...[
            const SizedBox(height: 6),
            Text(
              'Last calibration: heard ${outcome.devices.length - outcome.undetected.length} of ${outcome.devices.length} devices'
              '${outcome.undetected.isEmpty ? '' : ' (not heard: ${outcome.undetected.map((id) => room.participant(id)?.displayName ?? id).join(', ')})'}.',
              style: t.bodySmall,
            ),
          ],
          if (!ctl.hasMicrophone)
            Text('This device cannot record audio, so it cannot be the listening spot.', style: t.bodySmall)
          else if (!s.canControl)
            Text('Only devices with control rights can start a calibration.', style: t.bodySmall),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.my_location),
            label: const Text('Calibrate to this spot'),
            onPressed: canStart && !_requested ? _calibrate : null,
          ),
        ]),
      ),
    );
  }
}

class _Devices extends ConsumerWidget {
  final RoomViewState s;
  const _Devices(this.s);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final room = s.room!;
    final diag = {for (final d in s.diagnostics?.participants ?? const <ParticipantDiagnostics>[]) d.deviceId: d};
    final me = ref.watch(identityProvider).deviceId;
    final spread = s.diagnostics?.maxPairwiseErrorUs;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('Devices (${room.participants.where((p) => p.connection != ConnectionStatus.disconnected).length} connected)',
          trailing: spread == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('spread ${fmtMs(spread)} (est.)', style: Theme.of(context).textTheme.bodySmall),
                )),
      for (final p in room.participants)
        _DeviceTile(
          p: p,
          d: diag[p.deviceId],
          isMe: p.deviceId == me,
          canManage: s.role == ParticipantRole.host && p.role != ParticipantRole.host,
          canSetChannel: s.isLive && (p.deviceId == me || s.canControl),
        ),
    ]);
  }
}

class _DeviceTile extends ConsumerWidget {
  final ParticipantSummary p;
  final ParticipantDiagnostics? d;
  final bool isMe;
  final bool canManage;
  final bool canSetChannel;
  const _DeviceTile({
    required this.p,
    required this.d,
    required this.isMe,
    required this.canManage,
    required this.canSetChannel,
  });

  Future<void> _onAction(BuildContext context, WidgetRef ref, Object action) async {
    final ctl = ref.read(roomControllerProvider.notifier);
    final err = switch (action) {
      final ParticipantRole r => await ctl.control(ControlAction.setRole, targetDevice: p.deviceId, role: r),
      final ChannelRole c => await ctl.setChannelRole(c, deviceId: isMe ? null : p.deviceId),
      _ => null,
    };
    if (err != null && context.mounted) showMessage(context, err, error: true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = healthOf(d?.errorUs, d?.mode ?? CorrectionMode.idle, connection: p.connection);
    final conn = switch (p.connection) {
      ConnectionStatus.connected => null,
      ConnectionStatus.suspect => 'not responding',
      ConnectionStatus.disconnected => 'disconnected',
    };
    final parts = <String>[
      roleLabel(p.role),
      if (conn != null) conn,
      availabilityLabel(p.currentTrack),
      if (d?.errorUs != null) 'error ${fmtMs(d!.errorUs, signed: true)} (est.)',
      if (d != null && d!.playerState == 'buffering') 'buffering',
      if (p.channel != ChannelRole.stereo) channelLabel(p.channel),
      if (p.calibrationUs != null && p.calibrationUs != 0) 'offset ${fmtMs(p.calibrationUs, signed: true)}',
    ];
    return ListTile(
      leading: Stack(clipBehavior: Clip.none, children: [
        Icon(isMe ? Icons.smartphone : Icons.phone_android,
            color: p.connection == ConnectionStatus.disconnected ? Theme.of(context).disabledColor : null),
        Positioned(right: -2, bottom: -2, child: HealthDot(h)),
      ]),
      title: Text('${p.displayName}${isMe ? ' (you)' : ''}'),
      subtitle: Text(parts.join(' · ')),
      trailing: canManage || canSetChannel
          ? PopupMenuButton<Object>(
              tooltip: 'Device options',
              onSelected: (a) => _onAction(context, ref, a),
              itemBuilder: (_) => [
                if (canManage) ...const [
                  PopupMenuItem(value: ParticipantRole.controller, child: Text('Allow control')),
                  PopupMenuItem(value: ParticipantRole.listener, child: Text('Listener only')),
                ],
                if (canManage && canSetChannel) const PopupMenuDivider(),
                if (canSetChannel)
                  for (final c in ChannelRole.values)
                    CheckedPopupMenuItem(value: c, checked: p.channel == c, child: Text(channelLabel(c))),
              ],
            )
          : null,
    );
  }
}

class _Playlist extends ConsumerWidget {
  final RoomViewState s;
  const _Playlist(this.s);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final room = s.room!;
    final connected = room.participants.where((p) => p.connection != ConnectionStatus.disconnected).length;
    final current = room.timeline.trackId ?? room.pending?.trackId;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
        'Playlist',
        trailing: s.isHost
            ? TextButton.icon(
                icon: const Icon(Icons.playlist_add),
                label: const Text('Add'),
                onPressed: () => _addTracks(context, ref),
              )
            : null,
      ),
      if (room.playlist.isEmpty)
        ListTile(
          leading: const Icon(Icons.queue_music),
          title: const Text('No tracks in this room'),
          subtitle: Text(s.isHost ? 'Import tracks on the home screen, then add them here.' : 'Waiting for the host to add tracks.'),
        ),
      for (final t in room.playlist)
        ListTile(
          selected: t.id == current,
          leading: Icon(t.id == current ? Icons.equalizer : Icons.music_note_outlined),
          title: Text(t.title, overflow: TextOverflow.ellipsis),
          subtitle: Text('${t.artist ?? 'Unknown artist'} · ${fmtClock(t.durationUs)}'),
          trailing: Tooltip(
            message: 'Devices that have this exact file (SHA-256)',
            child: Chip(
              label: Text('${t.availableCount}/$connected'),
              avatar: Icon(t.availableCount >= connected ? Icons.check : Icons.download_outlined, size: 16),
            ),
          ),
          onTap: s.canControl
              ? () async {
                  final err = await ref.read(roomControllerProvider.notifier).control(ControlAction.setTrack, trackId: t.id);
                  if (err != null && context.mounted) showMessage(context, err, error: true);
                }
              : null,
        ),
    ]);
  }

  Future<void> _addTracks(BuildContext context, WidgetRef ref) async {
    final lib = await ref.read(libraryProvider.future);
    final inRoom = ref.read(roomControllerProvider).room?.playlist.map((t) => t.id).toSet() ?? {};
    final candidates = lib.where((t) => !inRoom.contains(t.id)).toList();
    if (!context.mounted) return;
    if (candidates.isEmpty) {
      showMessage(context, 'All library tracks are already in the room.');
      return;
    }
    final chosen = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: const Text('Add tracks'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              for (final t in candidates)
                CheckboxListTile(
                  value: chosen.contains(t.id),
                  title: Text(t.title),
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
