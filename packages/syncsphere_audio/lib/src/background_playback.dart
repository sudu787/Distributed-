import 'package:flutter/services.dart';

import 'native_audio_api.dart';

/// Keeps the app alive in the background while in a room, via an Android
/// foreground service with a media notification (see PlaybackService.kt).
///
/// Calls are best-effort: failing to show the notification (permission
/// denied, OEM restrictions) never affects playback in the foreground.
class BackgroundPlayback {
  final NativeAudioApi api;
  bool _running = false;
  String? _last;

  BackgroundPlayback({NativeAudioApi? api}) : api = api ?? MethodChannelAudioApi();

  bool get running => _running;

  Future<void> start({required String title, required String text, required bool playing}) async {
    try {
      // Android 13+: without this the service still runs, the notification
      // is just hidden.
      await api.requestPermission('notifications');
      await api.startService(title, text, playing);
      _running = true;
      _last = '$title|$text|$playing';
    } on PlatformException {
      _running = false;
    }
  }

  /// Updates the notification; skips identical updates.
  Future<void> update({required String title, required String text, required bool playing}) async {
    if (!_running) return;
    final key = '$title|$text|$playing';
    if (key == _last) return;
    _last = key;
    try {
      await api.updateService(title, text, playing);
    } on PlatformException {
      // Notification updates are cosmetic.
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _last = null;
    try {
      await api.stopService();
    } on PlatformException {
      // Already gone.
    }
  }
}
