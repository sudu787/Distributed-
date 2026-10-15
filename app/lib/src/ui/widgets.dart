import 'package:flutter/material.dart';

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
