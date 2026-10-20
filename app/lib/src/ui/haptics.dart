import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

enum Haptic {
  /// Light tick for selections and toggles.
  tap,

  /// Play, pause, skip, add songs, join.
  action,

  /// The room moved to another song (felt on every phone).
  songChanged,

  /// Party ended or connection lost.
  alert,
}

/// "Vibration feedback" setting (on by default), saved on the phone.
class HapticsSetting extends Notifier<bool> {
  static const key = 'haptics';

  @override
  bool build() {
    _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final v = await ref.read(appStoreProvider).setting(key);
      if (v != null) state = v == '1';
    } catch (_) {
      // No store (tests) or unreadable: keep the default.
    }
  }

  Future<void> set(bool on) async {
    state = on;
    if (on) await HapticFeedback.selectionClick();
    await ref.read(appStoreProvider).saveSetting(key, on ? '1' : '0');
  }
}

final hapticsProvider = NotifierProvider<HapticsSetting, bool>(HapticsSetting.new);

/// Vibrates for [kind] if vibration feedback is on. Android also honours
/// the system "touch feedback" setting.
void haptic(WidgetRef ref, Haptic kind) {
  if (!ref.read(hapticsProvider)) return;
  switch (kind) {
    case Haptic.tap:
      HapticFeedback.selectionClick();
    case Haptic.action:
      HapticFeedback.lightImpact();
    case Haptic.songChanged:
      HapticFeedback.mediumImpact();
    case Haptic.alert:
      HapticFeedback.heavyImpact();
  }
}
