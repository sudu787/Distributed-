import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncsphere_audio/syncsphere_audio.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import 'src/app.dart';
import 'src/data/sqflite_store.dart';
import 'src/services/device_media.dart';
import 'src/services/artwork_service.dart';
import 'src/services/library_service.dart';
import 'src/services/room_service.dart';
import 'src/state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final cache = await getApplicationCacheDirectory();
  final store = await SqfliteAppStore.open(p.join(docs.path, 'syncsphere.db'));
  final identity = await store.loadIdentity(defaultName: _defaultName());
  final clock = SystemMonotonicClock.instance;
  final log = EventLog(clock: clock, source: 'app', capacity: 3000);
  if (kDebugMode) {
    log.printer = (src, e) {
      if (e.level.index >= EventLevel.info.index) debugPrint('$src $e');
    };
  }

  final native = Platform.isAndroid ? MethodChannelAudioApi() : null;
  final hooks = native == null ? null : _AndroidHooks(native, log);
  final library = LibraryService(
    store: store,
    libraryDir: Directory(p.join(docs.path, 'library')),
    prober: native?.probe,
    log: log,
  );
  final rooms = RoomService(
    store: store,
    cacheDir: cache,
    clock: clock,
    log: log,
    hooks: hooks ?? const NoopPlatformHooks(),
    recorderFor: (b) => b is Media3AudioBackend ? b.calibrationRecorder() : null,
    // VBR MP3 seeks are approximate in ExoPlayer; play exact PCM copies.
    converterFor: (b) => b is Media3AudioBackend ? b.exactSeekConverter(Directory(p.join(cache.path, 'pcm'))) : null,
    backendFactory: (log) async {
      if (native == null) {
        // Desktop/dev builds: follow the timeline without rendering audio.
        return NullAudioBackend(clock.nowMicros);
      }
      final b = Media3AudioBackend(api: native, clock: clock, log: log);
      await b.initialize();
      hooks!.attach(b);
      if (b.deviceInfo['bluetoothOutputPresent'] == true) {
        log.warn('audio.bluetooth',
            'Bluetooth output detected: its latency is not visible to sync estimates; calibrate acoustically.');
      }
      return b;
    },
  );

  final artwork = ArtworkService(
    extract: native?.extractArtwork,
    store: store,
    artDir: Directory(p.join(cache.path, 'art')),
    trackCacheDir: Directory(p.join(cache.path, 'tracks')),
  );

  final deviceMedia = native == null
      ? DeviceMedia.none()
      : DeviceMedia(
          requestAccess: () => native.requestPermission('audio'),
          query: native.queryAudio,
          copy: native.copyContent,
          takeShared: native.takeSharedAudio,
          artwork: native.extractArtwork,
          artDir: Directory(p.join(cache.path, 'device-art')),
          shareArrived: native.events.where((e) => e['kind'] == 'shared').map((_) {}),
        );

  runApp(ProviderScope(
    overrides: [
      artworkServiceProvider.overrideWithValue(artwork),
      appStoreProvider.overrideWithValue(store),
      libraryServiceProvider.overrideWithValue(library),
      roomServiceProvider.overrideWithValue(rooms),
      deviceMediaProvider.overrideWithValue(deviceMedia),
      if (native != null) microphonePermissionProvider.overrideWithValue(() => native.requestPermission('microphone')),
      initialIdentityProvider.overrideWithValue(identity),
    ],
    child: const SyncSphereApp(),
  ));
}

String _defaultName() {
  final host = Platform.localHostname;
  if (host.isEmpty || host == 'localhost') return Platform.isAndroid ? 'Android phone' : 'SyncSphere device';
  return host;
}

class _AndroidHooks extends PlatformHooks {
  final NativeAudioApi api;
  final EventLog log;
  final BackgroundPlayback background;
  final StreamController<String> _commands = StreamController.broadcast();
  StreamSubscription<String>? _backendCommands;

  _AndroidHooks(this.api, this.log) : background = BackgroundPlayback(api: api);

  /// Forwards notification buttons from the current backend.
  void attach(Media3AudioBackend backend) {
    _backendCommands?.cancel();
    _backendCommands = backend.notificationCommands.listen(_commands.add);
  }

  @override
  Stream<String> get commands => _commands.stream;

  @override
  Future<void> enterRoom(String roomName) async {
    try {
      final locks = await api.acquireNetworkLocks();
      log.info('platform.locks', 'network locks acquired', locks);
      await api.keepScreenOn(true);
    } catch (e) {
      log.warn('platform.locks', 'could not acquire network locks: $e');
    }
    // Foreground service: keeps the room alive with the screen off.
    await background.start(title: roomName, text: 'Connected', playing: false);
    if (!background.running) log.warn('platform.background', 'background playback service unavailable');
  }

  @override
  Future<bool> moveToBackground() async {
    try {
      return await api.moveToBack();
    } catch (e) {
      log.warn('platform.background', 'could not move to background: $e');
      return false;
    }
  }

  @override
  Future<void> nowPlaying({required String roomName, required String text, required bool playing}) =>
      background.update(title: roomName, text: text, playing: playing);

  @override
  Future<void> leaveRoom() async {
    await background.stop();
    await _backendCommands?.cancel();
    _backendCommands = null;
    try {
      await api.releaseNetworkLocks();
      await api.keepScreenOn(false);
    } catch (e) {
      log.warn('platform.locks', 'could not release network locks: $e');
    }
  }
}
