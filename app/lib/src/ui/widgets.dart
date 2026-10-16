import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'format.dart';

class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 6),
      child: Row(
        children: [
          Expanded(child: Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class HealthDot extends StatelessWidget {
  final SyncHealth health;
  final double size;
  const HealthDot(this.health, {super.key, this.size = 10});

  @override
  Widget build(BuildContext context) {
    final c = healthColor(health, Theme.of(context).colorScheme);
    return Semantics(
      label: 'sync ${health.name}',
      child: Container(width: size, height: size, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
    );
  }
}

class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool estimate;
  const InfoRow(this.label, this.value, {super.key, this.estimate = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: Text(label, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
          Expanded(
            flex: 6,
            child: Text(
              estimate && value != '—' ? '$value (est.)' : value,
              style: t.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color? color;
  const StatusChip(this.label, this.icon, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: 6),
        Flexible(child: Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

void showMessage(BuildContext context, String message, {bool error = false}) {
  final cs = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? cs.error : null,
    behavior: SnackBarBehavior.floating,
  ));
}

/// Album art of a track with rounded corners; a colourful placeholder
/// (picked from the track id) when the song has no picture.
class TrackArt extends ConsumerWidget {
  final String? trackId;
  final double size;
  const TrackArt(this.trackId, {super.key, this.size = 48});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = trackId;
    final art = id == null ? null : ref.watch(artworkProvider(id)).value;
    final radius = BorderRadius.circular(size * 0.14);
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox.square(
        dimension: size,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: art != null
              ? Image.file(art, key: ValueKey(art.path), fit: BoxFit.cover, gaplessPlayback: true)
              : _ArtPlaceholder(id, size: size, key: ValueKey('ph-$id')),
        ),
      ),
    );
  }
}

class _ArtPlaceholder extends StatelessWidget {
  final String? id;
  final double size;
  const _ArtPlaceholder(this.id, {super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final seed = id == null ? 0 : id!.codeUnits.take(12).fold<int>(7, (h, c) => (h * 31 + c) & 0x7fffffff);
    final hue = (seed % 360).toDouble();
    Color tone(double h, double l) => HSLColor.fromAHSL(1, h % 360, 0.55, dark ? l * 0.6 : l).toColor();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: id == null
            ? LinearGradient(colors: [cs.primaryContainer, cs.tertiaryContainer])
            : LinearGradient(
                colors: [tone(hue, 0.62), tone(hue + 40, 0.48)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
      ),
      child: Center(child: Icon(Icons.music_note, size: size * 0.45, color: Colors.white.withValues(alpha: 0.9))),
    );
  }
}
