import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import '../state/providers.dart';
import '../state/room_controller.dart';
import 'haptics.dart';
import 'widgets.dart';

/// Short name, long name and colour of each channel role.
({String short, String long, Color color}) roleStyle(ChannelRole r) => switch (r) {
      ChannelRole.left => (short: 'L', long: 'Left', color: const Color(0xFF1E88E5)),
      ChannelRole.right => (short: 'R', long: 'Right', color: const Color(0xFFE53935)),
      ChannelRole.mono => (short: 'M', long: 'Mono', color: const Color(0xFF757575)),
      ChannelRole.stereo => (short: 'L+R', long: 'Stereo', color: const Color(0xFF43A047)),
      ChannelRole.center => (short: 'C', long: 'Center', color: const Color(0xFFFB8C00)),
      ChannelRole.surroundLeft => (short: 'SL', long: 'Surround left', color: const Color(0xFF8E24AA)),
      ChannelRole.surroundRight => (short: 'SR', long: 'Surround right', color: const Color(0xFFD81B60)),
    };

/// Where a role sits around the listener (degrees, 0 = straight ahead,
/// negative = left), or null for roles that play everything.
/// Angles follow ITU-R BS.775 (5.1): C 0°, L/R ±30°, surrounds ±110°.
double? roleAngle(ChannelRole r) => switch (r) {
      ChannelRole.left => -30,
      ChannelRole.right => 30,
      ChannelRole.center => 0,
      ChannelRole.surroundLeft => -110,
      ChannelRole.surroundRight => 110,
      _ => null,
    };

class ChannelBadge extends StatelessWidget {
  final ChannelRole role;
  const ChannelBadge(this.role, {super.key});

  @override
  Widget build(BuildContext context) {
    final st = roleStyle(role);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: st.color, borderRadius: BorderRadius.circular(12)),
      child: Text(st.short, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }
}

/// Top-down view of where each phone's channel belongs, seen from the
/// listener. Tap a phone to make it flash and vibrate (Identify).
class SpeakerLayoutCard extends ConsumerWidget {
  const SpeakerLayoutCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roomControllerProvider);
    final room = s.room!;
    final me = ref.watch(identityProvider).deviceId;
    final live = room.participants.where((p) => p.connection != ConnectionStatus.disconnected).toList();
    final placed = [for (final p in live) if (roleAngle(p.channel) != null) p];
    final full = [for (final p in live) if (roleAngle(p.channel) == null) p];
    final t = Theme.of(context).textTheme;
    final ctl = ref.read(roomControllerProvider.notifier);
    final lefts = live.where((p) => p.channel == ChannelRole.left).length;
    final rights = live.where((p) => p.channel == ChannelRole.right).length;

    Future<void> identify(ParticipantSummary p) async {
      haptic(ref, Haptic.tap);
      final err = await ctl.identify(p.deviceId);
      if (err != null && context.mounted) showMessage(context, err, error: true);
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.surround_sound_outlined, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text('Speaker layout', style: t.titleSmall)),
          ]),
          const SizedBox(height: 8),
          if (placed.isNotEmpty)
            SizedBox(
              height: 230,
              child: LayoutBuilder(builder: (context, c) {
                final w = c.maxWidth, h = 230.0;
                final center = Offset(w / 2, h / 2 + 6);
                final radius = min(w / 2 - 44, h / 2 - 34);
                return Stack(children: [
                  Positioned.fill(child: CustomPaint(painter: _RoomPainter(center, radius, Theme.of(context).dividerColor))),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Text('front', textAlign: TextAlign.center, style: t.labelSmall),
                  ),
                  Positioned(
                    left: center.dx - 18,
                    top: center.dy - 14,
                    child: const Column(children: [Icon(Icons.person, size: 22), Text('You', style: TextStyle(fontSize: 10))]),
                  ),
                  for (final (i, p) in placed.indexed)
                    () {
                      final sameRole = placed.where((q) => q.channel == p.channel).toList();
                      final k = sameRole.indexOf(p);
                      final a = (roleAngle(p.channel)! + (k - (sameRole.length - 1) / 2) * 14) * pi / 180;
                      final pos = center + Offset(sin(a) * radius, -cos(a) * radius);
                      return Positioned(
                        key: ValueKey('spk-$i'),
                        left: pos.dx - 40,
                        top: pos.dy - 22,
                        width: 80,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => identify(p),
                          child: Column(children: [
                            ChannelBadge(p.channel),
                            const SizedBox(height: 2),
                            Text(p.deviceId == me ? '${p.displayName} (you)' : p.displayName,
                                maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: t.bodySmall),
                          ]),
                        ),
                      );
                    }(),
                ]);
              }),
            )
          else
            Text('Every phone plays the full song (stereo). Set up a stereo pair to split left and right.', style: t.bodySmall),
          if (full.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(placed.isEmpty ? 'Playing everything:' : 'Also playing:', style: t.bodySmall),
              for (final p in full)
                ActionChip(
                  avatar: ChannelBadge(p.channel),
                  label: Text(p.deviceId == me ? '${p.displayName} (you)' : p.displayName),
                  onPressed: () => identify(p),
                ),
            ]),
          ],
          OverflowBar(alignment: MainAxisAlignment.end, spacing: 8, children: [
            if (s.canControl)
              TextButton.icon(
                icon: const Icon(Icons.graphic_eq),
                label: const Text('Test sound'),
                onPressed: () async {
                  haptic(ref, Haptic.action);
                  final err = await ctl.playSpeakerTest();
                  if (!context.mounted) return;
                  showMessage(
                    context,
                    err ?? 'Playing the speaker test: low beeps = left, high beeps = right, then center, then surround.',
                    error: err != null,
                  );
                },
              ),
            if (s.canControl && lefts > 0 && rights > 0)
              TextButton.icon(
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Swap L/R'),
                onPressed: () async {
                  haptic(ref, Haptic.action);
                  for (final p in live) {
                    if (p.channel == ChannelRole.left || p.channel == ChannelRole.right) {
                      await ctl.setChannelRole(p.channel == ChannelRole.left ? ChannelRole.right : ChannelRole.left,
                          deviceId: p.deviceId == me ? null : p.deviceId);
                    }
                  }
                },
              ),
            if (s.canControl && room.layout != null && room.layout!.listener == me)
              TextButton.icon(
                icon: const Icon(Icons.explore_outlined),
                label: const Text('Measured layout'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (_) => SurroundOrientSheet(layout: room.layout!),
                ),
              ),
            if (s.canControl && live.length >= 3)
              OutlinedButton.icon(
                icon: const Icon(Icons.surround_sound),
                label: const Text('Surround'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (_) => const SurroundSetupSheet(),
                ),
              ),
            if (s.canControl && live.length >= 2)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.speaker_group_outlined),
                label: const Text('Stereo pair'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (_) => const StereoPairSheet(),
                ),
              ),
          ]),
          Text(
            'Tap a phone to make it flash and show its channel. Each phone plays its channel on all of its own '
            'speakers. Most songs have the voice, bass and drums in both channels, so a left/right pair can sound '
            'alike: the test sound plays low beeps only on the left and high beeps only on the right.',
            style: t.bodySmall,
          ),
        ]),
      ),
    );
  }
}

/// The circle of speaker positions around the listener.
class _RoomPainter extends CustomPainter {
  final Offset center;
  final double radius;
  final Color color;
  _RoomPainter(this.center, this.radius, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, radius, p);
    // Facing direction.
    canvas.drawLine(center + Offset(0, -radius * 0.35), center + Offset(0, -radius * 0.8), p);
  }

  @override
  bool shouldRepaint(_RoomPainter old) => old.center != center || old.radius != radius || old.color != color;
}

/// Pick the left and the right phone in one go; phones previously on
/// left/right but not picked go back to stereo.
class StereoPairSheet extends ConsumerStatefulWidget {
  const StereoPairSheet({super.key});

  @override
  ConsumerState<StereoPairSheet> createState() => _StereoPairSheetState();
}

class _StereoPairSheetState extends ConsumerState<StereoPairSheet> {
  String? _left, _right;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final room = ref.watch(roomControllerProvider).room;
    final me = ref.watch(identityProvider).deviceId;
    if (room == null) return const SizedBox.shrink();
    final live = room.participants.where((p) => p.connection != ConnectionStatus.disconnected).toList();
    _left ??= live.where((p) => p.channel == ChannelRole.left).firstOrNull?.deviceId;
    _right ??= live.where((p) => p.channel == ChannelRole.right).firstOrNull?.deviceId;
    final t = Theme.of(context).textTheme;
    String name(ParticipantSummary p) => p.deviceId == me ? '${p.displayName} (you)' : p.displayName;

    Widget picker(String label, ChannelRole role, String? value, void Function(String) pick) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [ChannelBadge(role), const SizedBox(width: 8), Expanded(child: Text(label, style: t.titleSmall))]),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final p in live)
                ChoiceChip(
                  label: Text(name(p)),
                  selected: value == p.deviceId,
                  onSelected: (_) => setState(() => pick(p.deviceId)),
                ),
            ]),
          ],
        );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Stereo pair', style: t.titleLarge),
          const SizedBox(height: 4),
          Text('Put the two phones a few metres apart, facing you. Other phones keep playing the full song.',
              style: t.bodySmall),
          const SizedBox(height: 16),
          picker('Left phone', ChannelRole.left, _left, (id) {
            _left = id;
            if (_right == id) _right = null;
          }),
          const SizedBox(height: 16),
          picker('Right phone', ChannelRole.right, _right, (id) {
            _right = id;
            if (_left == id) _left = null;
          }),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy || _left == null || _right == null
                ? null
                : () async {
                    setState(() => _busy = true);
                    final ctl = ref.read(roomControllerProvider.notifier);
                    String? err;
                    for (final p in live) {
                      final want = p.deviceId == _left
                          ? ChannelRole.left
                          : p.deviceId == _right
                              ? ChannelRole.right
                              : (p.channel == ChannelRole.left || p.channel == ChannelRole.right)
                                  ? ChannelRole.stereo
                                  : p.channel;
                      if (want != p.channel) {
                        err ??= await ctl.setChannelRole(want, deviceId: p.deviceId == me ? null : p.deviceId);
                      }
                    }
                    if (!context.mounted) return;
                    haptic(ref, err == null ? Haptic.action : Haptic.alert);
                    Navigator.pop(context);
                    if (err != null) {
                      showMessage(context, err, error: true);
                    } else {
                      unawaited(ctl.identify(_left!));
                    }
                  },
            child: const Text('Use these two'),
          ),
        ]),
      ),
    );
  }
}

/// Full-screen "this is the LEFT phone" overlay, shown on the phone being
/// identified, with vibration.
Future<void> showIdentifyOverlay(BuildContext context, WidgetRef ref, ChannelRole role, String name) async {
  final st = roleStyle(role);
  for (var i = 0; i < 3; i++) {
    Timer(Duration(milliseconds: 450 * i), () => haptic(ref, Haptic.alert));
  }
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  Timer(const Duration(seconds: 3), () {
    if (open) nav.pop();
  });
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Identify',
    barrierColor: st.color.withValues(alpha: 0.92),
    pageBuilder: (c, a1, a2) => SafeArea(
      child: GestureDetector(
        onTap: () => Navigator.of(c).pop(),
        child: Material(
          type: MaterialType.transparency,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(role == ChannelRole.stereo ? 'STEREO' : st.long.toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontSize: 72, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Text(name, style: const TextStyle(color: Colors.white, fontSize: 22)),
              const SizedBox(height: 4),
              Text(
                switch (role) {
                  ChannelRole.stereo || ChannelRole.mono => 'This phone plays the full song',
                  ChannelRole.center || ChannelRole.surroundLeft || ChannelRole.surroundRight =>
                    'This phone is the ${st.long.toLowerCase()} speaker',
                  _ => 'This phone plays the ${st.long.toLowerCase()} channel',
                },
                style: const TextStyle(color: Colors.white70),
              ),
            ]),
          ),
        ),
      ),
    ),
  );
  open = false;
}

/// Assign phones to 5.1 positions (front left/right, center, surround
/// left/right). Unassigned phones keep playing the full song.
class SurroundSetupSheet extends ConsumerStatefulWidget {
  const SurroundSetupSheet({super.key});

  @override
  ConsumerState<SurroundSetupSheet> createState() => _SurroundSetupSheetState();
}

class _SurroundSetupSheetState extends ConsumerState<SurroundSetupSheet> {
  Future<void> _measure(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Measure the room?'),
        content: const Text(
          'Sit where you will listen and hold this phone. The music pauses for 15–30 seconds while each phone '
          'clicks in turn and the others listen. Keep the room quiet and the volumes as they are.\n\n'
          'Recordings stay on each phone; only click times and levels are shared.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Start')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final err = await ref.read(roomControllerProvider.notifier).calibrateSurround();
    if (!context.mounted) return;
    Navigator.pop(context);
    showMessage(context, err ?? 'Measuring… keep still and quiet.', error: err != null);
  }

  static const positions = [
    (ChannelRole.left, 'Front left'),
    (ChannelRole.right, 'Front right'),
    (ChannelRole.center, 'Center (in front of you)'),
    (ChannelRole.surroundLeft, 'Surround left (beside/behind you)'),
    (ChannelRole.surroundRight, 'Surround right (beside/behind you)'),
  ];
  Map<String, ChannelRole>? _pick;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final room = ref.watch(roomControllerProvider).room;
    final me = ref.watch(identityProvider).deviceId;
    if (room == null) return const SizedBox.shrink();
    final live = room.participants.where((p) => p.connection != ConnectionStatus.disconnected).toList();
    _pick ??= {for (final p in live) if (roleAngle(p.channel) != null) p.deviceId: p.channel};
    final t = Theme.of(context).textTheme;
    final ctl = ref.read(roomControllerProvider.notifier);
    String name(ParticipantSummary p) => p.deviceId == me ? '${p.displayName} (you)' : p.displayName;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Surround', style: t.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Place phones around where you sit: two in front (left and right), one in the middle in front, and two '
            'beside or slightly behind you. Stereo songs are spread out automatically (voices in front, room sound '
            'behind); 5.1 files play their real channels. Tap a name twice to unassign it.',
            style: t.bodySmall,
          ),
          if (ref.watch(roomControllerProvider).canControl && ctl.hasMicrophone && live.length >= 3) ...[
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.auto_awesome),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Measure automatically', style: t.titleSmall)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    'Sit in your seat with this phone. Every phone clicks in turn while the others listen, so '
                    'SyncSphere can work out where they are; then you tap the phone in front of you and the one on '
                    'your left. Each phone takes part only if "Help measure the room" is on in its settings.',
                    style: t.bodySmall,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: () => _measure(context),
                      child: const Text('Measure'),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 4),
            Text('Or assign the positions yourself:', style: t.titleSmall),
          ],
          for (final (role, label) in positions) ...[
            const SizedBox(height: 14),
            Row(children: [ChannelBadge(role), const SizedBox(width: 8), Expanded(child: Text(label, style: t.titleSmall))]),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final p in live)
                ChoiceChip(
                  label: Text(name(p)),
                  selected: _pick![p.deviceId] == role,
                  onSelected: (_) => setState(() {
                    if (_pick![p.deviceId] == role) {
                      _pick!.remove(p.deviceId);
                    } else {
                      _pick![p.deviceId] = role;
                    }
                  }),
                ),
            ]),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    String? err;
                    for (final p in live) {
                      final want = _pick![p.deviceId] ?? (roleAngle(p.channel) != null ? ChannelRole.stereo : p.channel);
                      if (want != p.channel) {
                        err ??= await ctl.setChannelRole(want, deviceId: p.deviceId == me ? null : p.deviceId);
                      }
                    }
                    if (!context.mounted) return;
                    haptic(ref, err == null ? Haptic.action : Haptic.alert);
                    Navigator.pop(context);
                    showMessage(
                      context,
                      err ?? 'Surround is set. Now stand at your seat and use "Calibrate to this spot" for the best result.',
                      error: err != null,
                    );
                  },
            child: const Text('Use this layout'),
          ),
        ]),
      ),
    );
  }
}

/// After a surround measurement, on the phone that measured: the room knows
/// the distances between phones but not which way you face. Tap the phone
/// in front of you and the one on your left; roles and volume trims follow.
class SurroundOrientSheet extends ConsumerStatefulWidget {
  final SpeakerLayout layout;
  const SurroundOrientSheet({super.key, required this.layout});

  @override
  ConsumerState<SurroundOrientSheet> createState() => _SurroundOrientSheetState();
}

class _SurroundOrientSheetState extends ConsumerState<SurroundOrientSheet> {
  final Set<String> _front = {};
  String? _left;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final room = ref.watch(roomControllerProvider).room;
    if (room == null) return const SizedBox.shrink();
    final me = ref.watch(identityProvider).deviceId;
    final layout = widget.layout;
    final t = Theme.of(context).textTheme;
    final ctl = ref.read(roomControllerProvider.notifier);
    final ids = [
      for (final id in layout.positions.keys)
        if (id != layout.listener && room.participant(id) != null) id
    ];
    String name(String id) {
      final n = room.participant(id)?.displayName ?? id;
      return id == me ? '$n (you)' : n;
    }

    Map<String, Placement>? placed;
    var roles = const <String, ChannelRole>{};
    var trims = const <String, double>{};
    // A left phone that is the only front phone gives no mirror information.
    if (_front.isNotEmpty && _left != null && !(_front.length == 1 && _front.contains(_left))) {
      placed = orientLayout(
        {for (final e in layout.positions.entries) e.key: Point(e.value.$1, e.value.$2)},
        listener: layout.listener,
        front: _front.toList(),
        left: _left!,
      )..removeWhere((id, _) => !ids.contains(id));
      roles = assignSurroundRoles(placed);
      trims = levelTrimsDb(layout.levelsDb, roles);
    }

    Widget picker(String label, bool Function(String) selected, void Function(String) toggle) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: t.titleSmall),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final id in ids)
                FilterChip(label: Text(name(id)), selected: selected(id), onSelected: (_) => setState(() => toggle(id))),
            ]),
          ],
        );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Room measured', style: t.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Found ${ids.length} phone${ids.length == 1 ? '' : 's'} around you. Now tell SyncSphere which way you face.',
            style: t.bodySmall,
          ),
          if (layout.residualM > 0.25) ...[
            const SizedBox(height: 6),
            Text(
              'Some distances did not fit well (about ${(layout.residualM * 100).round()} cm off), for example because '
              'of echoes. Check the result, measure again, or assign the positions yourself.',
              style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('Not sure which is which?', style: t.bodySmall),
            for (final id in ids)
              ActionChip(
                avatar: const Icon(Icons.flash_on, size: 16),
                label: Text(name(id)),
                onPressed: () => ctl.identify(id),
              ),
          ]),
          const SizedBox(height: 14),
          picker('1. The phone in front of you (or the two front phones, left and right)', _front.contains, (id) {
            if (!_front.remove(id)) _front.add(id);
          }),
          const SizedBox(height: 14),
          picker('2. A phone on your left', (id) => _left == id, (id) => _left = _left == id ? null : id),
          if (placed != null) ...[
            const SizedBox(height: 16),
            SizedBox(height: 200, child: _MeasuredMap(placed: placed, roles: roles, name: name)),
            for (final id in ids)
              if (placed[id] != null)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: ChannelBadge(roles[id] ?? ChannelRole.stereo),
                  title: Text(name(id)),
                  subtitle: Text('${_angleText(placed[id]!.azimuthDeg)}, ${placed[id]!.distanceM.toStringAsFixed(1)} m'
                      '${(trims[id] ?? 0) < -0.5 ? ' · volume ${trims[id]!.toStringAsFixed(0)} dB' : ''}'),
                ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      String? err;
                      for (final e in roles.entries) {
                        final p = room.participant(e.key);
                        if (p == null) continue;
                        if (p.channel != e.value) {
                          err ??= await ctl.setChannelRole(e.value, deviceId: e.key == me ? null : e.key);
                        }
                        final trim = trims[e.key] ?? 0;
                        if (trim < -0.5) {
                          err ??= await ctl.control(ControlAction.deviceVolume,
                              value: (p.volume * pow(10, trim / 20)).clamp(0.05, 1.0).toDouble(), targetDevice: e.key);
                        }
                      }
                      if (!context.mounted) return;
                      haptic(ref, err == null ? Haptic.action : Haptic.alert);
                      Navigator.pop(context);
                      showMessage(context, err ?? 'Surround is set from the measurement. Try the test sound.',
                          error: err != null);
                    },
              child: const Text('Use this layout'),
            ),
          ],
        ]),
      ),
    );
  }

  static String _angleText(double az) {
    final a = az.round();
    if (a.abs() <= 5) return 'straight ahead';
    return '${a.abs()}° ${a < 0 ? 'left' : 'right'}';
  }
}

/// Measured phone positions around the listener (front at the top).
class _MeasuredMap extends StatelessWidget {
  final Map<String, Placement> placed;
  final Map<String, ChannelRole> roles;
  final String Function(String id) name;
  const _MeasuredMap({required this.placed, required this.roles, required this.name});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final far = placed.values.map((p) => p.distanceM).fold<double>(0.5, max);
    return LayoutBuilder(builder: (context, c) {
      final center = Offset(c.maxWidth / 2, c.maxHeight / 2);
      final radius = min(c.maxWidth / 2 - 40, c.maxHeight / 2 - 22);
      return Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _RoomPainter(center, radius, Theme.of(context).dividerColor))),
        Positioned(
          left: center.dx - 12,
          top: center.dy - 12,
          child: const Icon(Icons.person, size: 24),
        ),
        for (final e in placed.entries)
          () {
            final a = e.value.azimuthDeg * pi / 180;
            final r = radius * (e.value.distanceM / far).clamp(0.2, 1.0);
            final pos = center + Offset(sin(a) * r, -cos(a) * r);
            return Positioned(
              left: pos.dx - 40,
              top: pos.dy - 18,
              width: 80,
              child: Column(children: [
                ChannelBadge(roles[e.key] ?? ChannelRole.stereo),
                Text(name(e.key), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: t.labelSmall),
              ]),
            );
          }(),
      ]);
    });
  }
}
