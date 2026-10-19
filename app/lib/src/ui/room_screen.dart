import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../state/providers.dart';
import '../state/room_controller.dart';
import 'diagnostics_screen.dart';
import 'format.dart';
import 'haptics.dart';
import 'player_screen.dart';
import 'queue_view.dart';
import 'speaker_layout.dart';
import 'widgets.dart';

/// The room: three tabs (Playing, Queue, Speakers). Technical details live
/// behind the ⋮ menu (Diagnostics).
class RoomScreen extends ConsumerStatefulWidget {
  const RoomScreen({super.key});

  @override
  ConsumerState<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends ConsumerState<RoomScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room;
    final connected = room?.participants.where((p) => p.connection != ConnectionStatus.disconnected).length ?? 0;
    final playing = room?.timeline.isPlaying ?? false;
    final (health, label) = roomSyncSummary(s.diagnostics?.maxPairwiseErrorUs, live: s.isLive, playing: playing);
    // Every phone feels it when the room changes song or starts/stops.
    ref.listen(roomControllerProvider.select((v) => (v.room?.timeline.trackId, v.room?.timeline.isPlaying)),
        (prev, next) {
      if (prev == null || prev.$1 == null && prev.$2 == null) return;
      if (next.$1 != prev.$1 && next.$1 != null) {
        haptic(ref, Haptic.songChanged);
      } else if (next.$2 != prev.$2) {
        haptic(ref, Haptic.action);
      }
    });
    // "Which phone is this?": flash and vibrate when this phone is identified.
    ref.listen(roomControllerProvider.select((v) => v.room?.identify), (prev, next) {
      if (next == null || next.seq == prev?.seq) return;
      final myId = ref.read(identityProvider).deviceId;
      if (next.deviceId != myId) return;
      final me = ref.read(roomControllerProvider).room?.participant(myId);
      unawaited(showIdentifyOverlay(context, ref, me?.channel ?? ChannelRole.stereo, me?.displayName ?? 'This phone'));
    });
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack(context, s.isHost);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(room?.roomName ?? s.info?.roomName ?? 'Room', overflow: TextOverflow.ellipsis),
            Row(children: [
              HealthDot(health, size: 8),
              const SizedBox(width: 6),
              Flexible(
                child: Text('$connected phone${connected == 1 ? '' : 's'} · $label',
                    style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
              ),
            ]),
          ]),
          actions: [
            if (s.isHost)
              IconButton(
                tooltip: 'Invite',
                icon: const Icon(Icons.qr_code_2),
                onPressed: () => showInvite(context, ref),
              ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'diag') {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen()));
                } else if (v == 'leave') {
                  _leave(context, s.isHost);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'diag',
                    child: ListTile(leading: Icon(Icons.monitor_heart_outlined), title: Text('Diagnostics'))),
                PopupMenuItem(
                  value: 'leave',
                  child:
                      ListTile(leading: const Icon(Icons.logout), title: Text(s.isHost ? 'End party' : 'Leave party')),
                ),
              ],
            ),
          ],
        ),
        body: room == null
            ? const Center(child: CircularProgressIndicator())
            : switch (_tab) {
                0 => const NowPlayingView(),
                1 => const QueueView(),
                _ => const SpeakersView(),
              },
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.play_circle_outline), selectedIcon: Icon(Icons.play_circle), label: 'Playing'),
            NavigationDestination(
                icon: Icon(Icons.queue_music_outlined), selectedIcon: Icon(Icons.queue_music), label: 'Queue'),
            NavigationDestination(
                icon: Icon(Icons.speaker_group_outlined), selectedIcon: Icon(Icons.speaker_group), label: 'Speakers'),
          ],
        ),
      ),
    );
  }

  /// Back button in a party: never drop out of the party by accident.
  Future<void> _onBack(BuildContext context, bool host) async {
    haptic(ref, Haptic.tap);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Leave the party?')),
          ListTile(
            leading: const Icon(Icons.music_note),
            title: const Text('Keep playing in the background'),
            subtitle: const Text('The music continues; open SyncSphere again any time'),
            onTap: () => Navigator.pop(c, 'background'),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(host ? 'End party' : 'Leave party'),
            subtitle: Text(host ? 'Stops the music on every phone' : 'Stops the music on this phone'),
            onTap: () => Navigator.pop(c, 'leave'),
          ),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('Cancel'),
            onTap: () => Navigator.pop(c),
          ),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (choice == 'background') {
      await ref.read(roomControllerProvider.notifier).moveToBackground();
    } else if (choice == 'leave') {
      await _leave(context, host);
    }
  }

  Future<void> _leave(BuildContext context, bool host) async {
    if (host) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('End the party?'),
          content: const Text('This phone runs the party. Leaving stops the music on every phone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('End party')),
          ],
        ),
      );
      if (ok != true) return;
    }
    haptic(ref, Haptic.action);
    await ref.read(roomControllerProvider.notifier).leave();
  }
}

/// QR code, typed code and address in one place (host only).
Future<void> showInvite(BuildContext context, WidgetRef ref) async {
  final info = ref.read(roomControllerProvider).info;
  final link = await ref.read(roomControllerProvider.notifier).joinLink();
  if (!context.mounted || info == null) return;
  final key = info.joinKey == null ? null : formatJoinKey(info.joinKey!);
  final t = Theme.of(context).textTheme;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Invite friends'),
      content: SizedBox(
        width: 300,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (link != null) ...[
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(data: link.toString(), size: 220, backgroundColor: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text('On the other phone: SyncSphere → Join → Scan QR code.', textAlign: TextAlign.center),
            ] else
              const Text('Connect to Wi-Fi or turn on a hotspot to show a QR code.', textAlign: TextAlign.center),
            if (key != null) ...[
              const Divider(height: 24),
              Text('Or type this code', style: t.labelLarge),
              SelectableText(key, style: t.headlineSmall?.copyWith(fontFamily: 'monospace', letterSpacing: 2)),
              if (link != null) Text('Address ${link.hosts.first} · port ${link.port}', style: t.bodySmall),
            ],
            const SizedBox(height: 8),
            Text('Anyone with this code can join. Share it only with people here.',
                style: t.bodySmall, textAlign: TextAlign.center),
          ]),
        ),
      ),
      actions: [
        if (link != null)
          TextButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Copy link'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link.toString()));
              showMessage(context, 'Invite link copied');
            },
          ),
        FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
      ],
    ),
  );
}

/// Speakers tab: who is connected, listening-spot calibration and per-phone
/// settings (volume, timing, channel).
class SpeakersView extends ConsumerWidget {
  const SpeakersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room!;
    final me = ref.watch(identityProvider).deviceId;
    final diag = {for (final d in s.diagnostics?.participants ?? const <ParticipantDiagnostics>[]) d.deviceId: d};
    final others =
        room.participants.where((p) => p.deviceId != me && p.connection != ConnectionStatus.disconnected).length;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (s.isHost && others == 0) const _InviteBanner(),
        if (room.preferredCoordinator != null && room.preferredCoordinator != room.coordinatorId)
          _TemporaryHostNote(
            hostName: room.participant(room.coordinatorId)?.displayName ?? 'Another phone',
            ownerName: room.participant(room.preferredCoordinator!)?.displayName,
          ),
        const SpeakerLayoutCard(),
        const _ListeningSpot(),
        const SectionHeader('Phones'),
        for (final p in room.participants) _DeviceTile(p: p, d: diag[p.deviceId], isMe: p.deviceId == me),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'Tap a phone to change its volume, timing or channel. If one phone sounds early or late, '
            'try "Calibrate to this spot" first, then fine-tune by ear.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Shown after a takeover: who is hosting now and that the original host
/// gets the role back when it returns.
class _TemporaryHostNote extends StatelessWidget {
  final String hostName;
  final String? ownerName;
  const _TemporaryHostNote({required this.hostName, required this.ownerName});

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: Text('$hostName is hosting for now'),
          subtitle: Text(ownerName == null
              ? 'The phone that started the party is away. It gets the host role back automatically when it rejoins.'
              : '$ownerName is back and will take over again in a few seconds.'),
        ),
      );
}

class _InviteBanner extends ConsumerWidget {
  const _InviteBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        color: Theme.of(context).colorScheme.primaryContainer,
        child: ListTile(
          leading: const Icon(Icons.group_add),
          title: const Text('Invite friends'),
          subtitle: const Text('Show a QR code for the other phones to scan.'),
          trailing: FilledButton(onPressed: () => showInvite(context, ref), child: const Text('Invite')),
        ),
      );
}

class _DeviceTile extends ConsumerWidget {
  final ParticipantSummary p;
  final ParticipantDiagnostics? d;
  final bool isMe;
  const _DeviceTile({required this.p, required this.d, required this.isMe});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roomControllerProvider);
    final h = healthOf(d?.errorUs, d?.mode ?? CorrectionMode.idle, connection: p.connection);
    final parts = <String>[
      if (p.role == ParticipantRole.host) 'Host',
      switch (p.connection) {
        ConnectionStatus.connected => switch (p.currentTrack) {
            TrackAvailability.fetching => 'downloading song…',
            TrackAvailability.missing => 'missing song',
            TrackAvailability.mismatch => 'different file',
            _ => switch (h) {
                SyncHealth.good => 'in sync',
                SyncHealth.fair => 'almost in sync',
                SyncHealth.poor => 'catching up',
                SyncHealth.unknown => 'connected',
              },
          },
        ConnectionStatus.suspect => 'not responding',
        ConnectionStatus.disconnected => 'disconnected',
      },
      if ((p.calibrationUs ?? 0) != 0) offsetLabel(p.calibrationUs).toLowerCase(),
    ];
    final canEdit = s.isLive && (isMe || s.canControl);
    return ListTile(
      leading: Stack(clipBehavior: Clip.none, children: [
        Icon(isMe ? Icons.smartphone : Icons.phone_android,
            color: p.connection == ConnectionStatus.disconnected ? Theme.of(context).disabledColor : null),
        Positioned(right: -2, bottom: -2, child: HealthDot(h)),
      ]),
      title: Text('${p.displayName}${isMe ? ' (this phone)' : ''}'),
      subtitle: Text(parts.join(' · ')),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        ChannelBadge(p.channel),
        if (canEdit) ...[const SizedBox(width: 8), const Icon(Icons.tune)],
      ]),
      onTap: canEdit
          ? () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => DeviceSettingsSheet(deviceId: p.deviceId),
              )
          : null,
    );
  }
}

/// Per-phone settings: volume, timing fine-tune, channel and (host) role.
class DeviceSettingsSheet extends ConsumerWidget {
  final String deviceId;
  const DeviceSettingsSheet({super.key, required this.deviceId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roomControllerProvider);
    final p = s.room?.participant(deviceId);
    if (p == null) return const SizedBox(height: 120, child: Center(child: Text('This phone left the party.')));
    final ctl = ref.read(roomControllerProvider.notifier);
    final isMe = deviceId == ref.watch(identityProvider).deviceId;
    final t = Theme.of(context).textTheme;
    Future<void> run(Future<String?> f) async {
      final err = await f;
      if (err != null && context.mounted) showMessage(context, err, error: true);
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(isMe ? '${p.displayName} (this phone)' : p.displayName, style: t.titleLarge),
          const SizedBox(height: 16),
          Text('Volume', style: t.titleSmall),
          DebouncedSlider(
            value: p.volume,
            onChanged: (v) => run(ctl.control(ControlAction.deviceVolume, value: v, targetDevice: deviceId)),
          ),
          const SizedBox(height: 8),
          Text('Timing', style: t.titleSmall),
          TimingFineTune(
            offsetUs: p.calibrationUs ?? 0,
            onChanged: (us) => run(ctl.setDeviceOffset(deviceId, us)),
          ),
          const SizedBox(height: 16),
          Text('Channel', style: t.titleSmall),
          const SizedBox(height: 6),
          SegmentedButton<ChannelRole>(
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: const [
              ButtonSegment(value: ChannelRole.stereo, label: Text('Stereo')),
              ButtonSegment(value: ChannelRole.left, label: Text('Left')),
              ButtonSegment(value: ChannelRole.right, label: Text('Right')),
              ButtonSegment(value: ChannelRole.mono, label: Text('Mono')),
            ],
            selected: {if (!p.channel.isSurroundRole) p.channel},
            onSelectionChanged: (v) {
              if (v.isNotEmpty) run(ctl.setChannelRole(v.first, deviceId: isMe ? null : deviceId));
            },
          ),
          const SizedBox(height: 6),
          SegmentedButton<ChannelRole>(
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: const [
              ButtonSegment(value: ChannelRole.center, label: Text('Center')),
              ButtonSegment(value: ChannelRole.surroundLeft, label: Text('Surround L')),
              ButtonSegment(value: ChannelRole.surroundRight, label: Text('Surround R')),
            ],
            selected: {if (p.channel.isSurroundRole) p.channel},
            onSelectionChanged: (v) {
              if (v.isNotEmpty) run(ctl.setChannelRole(v.first, deviceId: isMe ? null : deviceId));
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('For a stereo effect put the left and right phones a few metres apart, facing you.', style: t.bodySmall),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.flashlight_on_outlined),
              label: const Text('Identify this phone'),
              onPressed: () => run(ctl.identify(deviceId)),
            ),
          ),
          if (s.role == ParticipantRole.host && p.role != ParticipantRole.host) ...[
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Can control the music'),
              subtitle: const Text('Play, pause, skip and change the queue'),
              value: p.role == ParticipantRole.controller,
              onChanged: (v) => run(ctl.control(ControlAction.setRole,
                  targetDevice: deviceId, role: v ? ParticipantRole.controller : ParticipantRole.listener)),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Manual timing adjustment: −/+ 5 ms steps and a ±500 ms slider.
/// Positive offsets make the phone play earlier.
class TimingFineTune extends StatefulWidget {
  final int offsetUs;
  final ValueChanged<int> onChanged;
  const TimingFineTune({super.key, required this.offsetUs, required this.onChanged});

  @override
  State<TimingFineTune> createState() => _TimingFineTuneState();
}

class _TimingFineTuneState extends State<TimingFineTune> {
  static const _range = 500; // ms
  double? _drag;

  void _set(int ms) => widget.onChanged(ms.clamp(-1000, 1000) * 1000);

  @override
  Widget build(BuildContext context) {
    final ms = (widget.offsetUs / 1000).round();
    final shown = _drag?.round() ?? ms;
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(offsetLabel(shown * 1000), style: t.bodyLarge)),
        if (ms != 0) TextButton(onPressed: () => _set(0), child: const Text('Reset')),
      ]),
      Row(children: [
        IconButton.outlined(
          tooltip: 'Play 5 ms later',
          icon: const Icon(Icons.remove),
          onPressed: () => _set(ms - 5),
        ),
        Expanded(
          child: Slider(
            min: -_range.toDouble(),
            max: _range.toDouble(),
            divisions: _range * 2 ~/ 5,
            value: (_drag ?? ms.toDouble()).clamp(-_range.toDouble(), _range.toDouble()),
            label: '$shown ms',
            onChanged: (v) => setState(() => _drag = v),
            onChangeEnd: (v) {
              setState(() => _drag = null);
              _set(v.round());
            },
          ),
        ),
        IconButton.outlined(
          tooltip: 'Play 5 ms earlier',
          icon: const Icon(Icons.add),
          onPressed: () => _set(ms + 5),
        ),
      ]),
      Text('Sounds late? Tap +. Sounds early? Tap −. Changes apply within a few seconds.', style: t.bodySmall),
    ]);
  }
}

/// "Calibrate to this spot": aligns every phone's sound at this phone's
/// microphone, including Bluetooth and speaker delays software cannot see.
class _ListeningSpot extends ConsumerStatefulWidget {
  const _ListeningSpot();

  @override
  ConsumerState<_ListeningSpot> createState() => _ListeningSpotState();
}

/// Asks for confirmation and starts "calibrate to this spot" with this
/// phone's microphone. Returns null on success, else a user-facing error
/// (or null when the user cancelled; [started] tells them apart).
Future<({bool started, String? error})> startSpotCalibration(BuildContext context, WidgetRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Calibrate to this spot?'),
      content: const Text(
        'Stand where you will listen and hold this phone. The music pauses for 15–30 seconds while each phone '
        'clicks in turn. Keep the room quiet and the volumes as they are.\n\n'
        'The recording stays on this phone; only timing results are shared.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Start')),
      ],
    ),
  );
  if (ok != true) return (started: false, error: null);
  final err = await ref.read(roomControllerProvider.notifier).calibrateHere();
  return (started: err == null, error: err);
}

class _ListeningSpotState extends ConsumerState<_ListeningSpot> {
  bool _requested = false;

  Future<void> _calibrate() async {
    setState(() => _requested = true);
    final r = await startSpotCalibration(context, ref);
    if (!mounted) return;
    if (!r.started) setState(() => _requested = false);
    if (r.error != null) showMessage(context, r.error!, error: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomControllerProvider);
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
    final String note;
    if (running) {
      note = mine ? 'Listening… keep still and quiet.' : 'Another phone is calibrating…';
    } else if (!ctl.hasMicrophone) {
      note = 'This phone cannot record audio, so use another phone to calibrate.';
    } else if (!s.canControl) {
      note = 'Ask the host for control to calibrate.';
    } else if (outcome != null) {
      final heard = outcome.devices.length - outcome.undetected.length;
      note = 'Last time: heard $heard of ${outcome.devices.length} phones'
          '${outcome.undetected.isEmpty ? '.' : ' – turn up the others and try again.'}';
    } else {
      note = 'Lines up the sound from every phone where you stand.';
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(Icons.my_location, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Calibrate to this spot', style: t.titleSmall),
              Text(note, style: t.bodySmall),
            ]),
          ),
          const SizedBox(width: 8),
          running
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : FilledButton.tonal(onPressed: canStart && !_requested ? _calibrate : null, child: const Text('Start')),
        ]),
      ),
    );
  }
}
