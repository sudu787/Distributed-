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
          Text('Tap a phone to make it flash and show its channel.', style: t.bodySmall),
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
